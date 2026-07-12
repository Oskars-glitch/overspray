import SceneKit
import Metal
import UIKit

/// Global cap on allocated paint tiles (memory care for older iPhones).
final class TileBudget {
    var used = 0
    let maxTiles = 16
    var warned = false
}

/// The wall's paint canvas, split into lazy 0.5 m tiles at 2048 px each
/// (4096 px per metre — 3× finer). A tile only allocates its texture the
/// first time paint touches it, and only its dirty region uploads to the GPU.
final class PaintCanvas {
    static let tileMeters: CGFloat = 0.5
    static let tilePx = 2048
    static var ppm: CGFloat { CGFloat(tilePx) / tileMeters }        // 4096 px/m

    let surfaceMeters: CGFloat
    let tilesPerSide: Int
    let sizePx: CGFloat                                             // whole surface, px
    private let device: MTLDevice
    private let queue: MTLCommandQueue?
    private let budget: TileBudget
    private weak var parent: SCNNode?
    var onBudgetExceeded: (() -> Void)?

    private var tiles: [Int: Tile] = [:]
    private(set) var contentRect: CGRect?          // union of everything painted

    // wetness map: one grid over the whole surface. 1 = just sprayed (fully
    // reflective), fading to 0 (dry, dim reflection). Cells touched while the
    // trigger is held are PINNED fully wet — the whole stroke starts drying
    // together on release, never while it is still being painted. 2048 cells
    // = 6 mm at 12 m, wetten() writes soft discs from the float centre, and
    // the sampler is linear — gradients, not steps. (The reflection itself is
    // masked by the paint alpha at full 4096 px/m: every splatter dot carries
    // its own sheen; this grid only says how WET each spot is.)
    static let wetN = 2048                  // grid cells per side (6 mm)
    static let dryEndSeconds = 25.0         // trigger release → fully matte
    static let matN = 1800                  // mask + material lattice (0.67 cm cells)
    private var wet: [Float]
    private var pinned: [Bool]              // wet-locked until trigger release
    private var pinnedIdx: [Int] = []       // what to unpin, without a grid walk
    private var stroking = false
    // coarse occupancy: stepWet only walks 32×32-cell blocks holding wetness —
    // the grid is a million cells and this runs on the render thread
    private let blockN = PaintCanvas.wetN / 32
    private var liveBlocks: Set<Int> = []
    private var blockStage = [UInt8](repeating: 0, count: 32 * 32)
    private var wetTex: MTLTexture?
    private var wetProp: SCNMaterialProperty?
    // wall material per region: 0 glossy · ½ rough · 1 bumpy, sampled by the
    // tile shader with the same offsets as the wet map
    private var matTex: MTLTexture?
    private var matProp: SCNMaterialProperty?
    private var reflectionCG: CGImage?
    private var wetDirty = false

    final class Tile {
        let ctx: CGContext
        let bpr: Int
        let texture: MTLTexture
        let node: SCNNode
        let material: SCNMaterial
        var dirty: CGRect?
        var mipsDirty = true          // mip chain needs regenerating after uploads

        init?(device: MTLDevice, wetProp: SCNMaterialProperty?,
              matProp: SCNMaterialProperty?,
              wetOff: CGPoint, wetScale: CGFloat, reflection: CGImage?,
              torch: Float) {
            let size = PaintCanvas.tilePx
            let cs = CGColorSpaceCreateDeviceRGB()
            guard let c = CGContext(data: nil, width: size, height: size,
                                    bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            ctx = c
            bpr = c.bytesPerRow
            ctx.translateBy(x: 0, y: CGFloat(size))                 // top-left origin
            ctx.scaleBy(x: 1, y: -1)
            ctx.setLineCap(.round)

            // mipmapped: at distance the GPU samples pre-filtered smaller
            // versions → a barely visible softness that removes the moiré
            // shimmer, while close-up stays perfectly sharp
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: true)
            desc.usage = [.shaderRead]
            guard let tex = device.makeTexture(descriptor: desc) else { return nil }
            texture = tex
            if let data = ctx.data {
                tex.replace(region: MTLRegionMake2D(0, 0, size, size),
                            mipmapLevel: 0, withBytes: data, bytesPerRow: bpr)
            }

            // wet-paint look: sheen masked by paint alpha; the scanned
            // reflection mirrors on FRESH paint (95%) and fades to 30% as it
            // dries (driven by the wetMap texture, 25 s after release)
            let m = SCNMaterial()
            m.lightingModel = .blinn
            m.diffuse.contents = tex
            m.diffuse.mipFilter = .linear
            // anisotropy 1, deliberately: aniso keeps fine spray grain sharp
            // at distance and grazing angles, and sub-pixel grain SHIMMERS.
            // Plain trilinear blurs gradually with distance instead — the
            // slight far softness is wanted (matches what the camera sees)
            m.diffuse.maxAnisotropy = 1
            m.specular.contents = UIColor(white: 0.23, alpha: 1)
            m.shininess = 24
            m.isDoubleSided = false
            m.transparencyMode = .aOne
            if let r = reflection {
                m.reflective.contents = r
                m.reflective.intensity = 1.0
                // mips supply the distance blur: sharp base image close up,
                // minification blurs it as you step back
                m.reflective.mipFilter = .linear
            }
            m.shaderModifiers = [
                .surface: """
                #pragma arguments
                texture2d<float> wetMap;
                texture2d<float> matMap;
                float2 wetOff;
                float wetScale;
                float torchBoost;
                #pragma body
                float camDist = length(_surface.position);
                float near = clamp((1.6 - camDist) / 1.2, 0.0, 1.0);
                constexpr sampler wetSmp(filter::linear);
                float2 wuv = wetOff + _surface.diffuseTexcoord * wetScale;
                float wet = wetMap.sample(wetSmp, wuv).r;
                float mat = matMap.sample(wetSmp, wuv).r * 2.0;
                float rough = clamp(mat, 0.0, 1.0);
                float bumpy = clamp(mat - 1.0, 0.0, 1.0);
                if (bumpy > 0.01) {
                    // rough-stone micro-normals from hash-based value noise —
                    // genuinely aperiodic, no lattice, no carbon-fibre repeat.
                    // ~6 mm grain, tiny amplitude, distance-damped.
                    float2 bp = wuv * 2000.0;
                    float2 ip = fmod(floor(bp), 787.0);
                    float2 fp = fract(bp);
                    float2 uu = fp * fp * (3.0 - 2.0 * fp);
                    float h00 = fract(sin(dot(ip, float2(127.1, 311.7))) * 43758.5453);
                    float h10 = fract(sin(dot(ip + float2(1.0, 0.0), float2(127.1, 311.7))) * 43758.5453);
                    float h01 = fract(sin(dot(ip + float2(0.0, 1.0), float2(127.1, 311.7))) * 43758.5453);
                    float h11 = fract(sin(dot(ip + float2(1.0, 1.0), float2(127.1, 311.7))) * 43758.5453);
                    float bx = mix(mix(h00, h10, uu.x), mix(h01, h11, uu.x), uu.y) * 2.0 - 1.0;
                    float g00 = fract(sin(dot(ip, float2(269.5, 183.3))) * 43758.5453);
                    float g10 = fract(sin(dot(ip + float2(1.0, 0.0), float2(269.5, 183.3))) * 43758.5453);
                    float g01 = fract(sin(dot(ip + float2(0.0, 1.0), float2(269.5, 183.3))) * 43758.5453);
                    float g11 = fract(sin(dot(ip + float2(1.0, 1.0), float2(269.5, 183.3))) * 43758.5453);
                    float by = mix(mix(g00, g10, uu.x), mix(g01, g11, uu.x), uu.y) * 2.0 - 1.0;
                    float3 bref = abs(_surface.normal.y) > 0.8 ? float3(1.0, 0.0, 0.0) : float3(0.0, 1.0, 0.0);
                    float3 bt = normalize(cross(_surface.normal, bref));
                    float3 bb = cross(_surface.normal, bt);
                    float amp = 0.012 * bumpy * (0.35 + 0.65 * near);
                    _surface.normal = normalize(_surface.normal + (bt * bx + bb * by) * amp);
                }
                // torch: brighter AND tighter — on WET paint the highlight
                // collapses to a hard hotspot (~16x exponent = ~4x smaller
                // spot); dry paint gets only the mild boost
                float torchSharp = 1.0 + torchBoost * (1.5 + 14.5 * wet);
                _surface.shininess = (4.0 + 70.0 * near * near) * (1.0 - 0.75 * rough) * torchSharp;
                // dry paint is near-pure diffuse so the sprayed colour matches
                // the picked colour exactly — the old dry sheen greyed blacks
                // and dimmed whites. Wet keeps the full effect.
                _surface.specular.rgb = _surface.specular.rgb * _surface.diffuse.a * (0.35 + 0.65 * near) * (0.12 + 0.88 * wet) * (1.0 - 0.45 * rough) * (1.0 + (0.6 + 1.2 * wet) * torchBoost);
                float refK = (0.05 + 0.83 * wet) * (1.0 + 0.5 * torchBoost) * (1.0 - 0.55 * rough);
                _surface.reflective.rgb = _surface.reflective.rgb * _surface.diffuse.a * min(refK, 1.0);
                """
            ]
            if let wp = wetProp { m.setValue(wp, forKey: "wetMap") }
            if let mp = matProp { m.setValue(mp, forKey: "matMap") }
            m.setValue(NSNumber(value: torch), forKey: "torchBoost")
            m.setValue(NSValue(cgPoint: wetOff), forKey: "wetOff")
            m.setValue(NSNumber(value: Double(wetScale)), forKey: "wetScale")
            material = m
            let geo = SCNPlane(width: PaintCanvas.tileMeters, height: PaintCanvas.tileMeters)
            geo.materials = [m]
            node = SCNNode(geometry: geo)
        }
    }

    init(surfaceMeters: CGFloat, device: MTLDevice, budget: TileBudget, parent: SCNNode) {
        self.surfaceMeters = surfaceMeters
        self.device = device
        self.queue = device.makeCommandQueue()
        self.budget = budget
        self.parent = parent
        tilesPerSide = Int((surfaceMeters / PaintCanvas.tileMeters).rounded())
        sizePx = CGFloat(tilesPerSide) * CGFloat(PaintCanvas.tilePx)
        let n = PaintCanvas.wetN
        wet = .init(repeating: 0, count: n * n)
        pinned = .init(repeating: false, count: n * n)
        let wd = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: n, height: n, mipmapped: false)
        wd.usage = [.shaderRead]
        if let wt = device.makeTexture(descriptor: wd) {
            let zero = [UInt8](repeating: 0, count: n * n)
            wt.replace(region: MTLRegionMake2D(0, 0, n, n),
                       mipmapLevel: 0, withBytes: zero, bytesPerRow: n)
            wetTex = wt
            wetProp = SCNMaterialProperty(contents: wt)
        }
        let mn = PaintCanvas.matN
        let md = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: mn, height: mn, mipmapped: false)
        md.usage = [.shaderRead]
        if let mt = device.makeTexture(descriptor: md) {
            let zero = [UInt8](repeating: 0, count: mn * mn)
            mt.replace(region: MTLRegionMake2D(0, 0, mn, mn),
                       mipmapLevel: 0, withBytes: zero, bytesPerRow: mn)
            matTex = mt
            matProp = SCNMaterialProperty(contents: mt)
        }
    }

    /// Push the surface's material grid (values 0/1/2 per cell) to the GPU.
    func setMaterialGrid(_ g: [UInt8]) {
        let mn = PaintCanvas.matN
        guard g.count == mn * mn, let mt = matTex else { return }
        var bytes = [UInt8](repeating: 0, count: g.count)
        for i in 0..<g.count { bytes[i] = g[i] == 0 ? 0 : (g[i] == 1 ? 128 : 255) }
        mt.replace(region: MTLRegionMake2D(0, 0, mn, mn),
                   mipmapLevel: 0, withBytes: bytes, bytesPerRow: mn)
    }

    /// The reflection image (scanned from the opposite direction) shared by
    /// all tiles; enables the mirror-on-wet-paint look.
    func setReflection(_ cg: CGImage) {
        reflectionCG = cg
        for t in tiles.values {
            t.material.reflective.contents = cg
            t.material.reflective.intensity = 1.0
            t.material.reflective.mipFilter = .linear
        }
    }

    /// Flashlight state → the sheen brightens on wet paint (shader uniform).
    func setTorchBoost(_ v: Float) {
        guard torchBoost != v else { return }
        torchBoost = v
        for t in tiles.values {
            t.material.setValue(NSNumber(value: v), forKey: "torchBoost")
        }
    }
    private var torchBoost: Float = 0

    /// Mark a soft wet disc, canvas px. Falloff is computed from the float
    /// centre — no grid snapping — so the sheen never shows a square edge.
    /// Callers own the footprint: the spray passes its real landing radius,
    /// drips their stroke width. Overshoot is harmless (the shader masks
    /// wetness by paint alpha) but keep it honest or old strokes re-wet.
    func wetten(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
        let n = PaintCanvas.wetN
        let s = CGFloat(n) / sizePx
        let cx = x * s, cy = y * s
        let cr = max(r * s, 0.75)           // thin drips still register a cell
        let gx0 = max(0, Int(cx - cr)), gx1 = min(n - 1, Int(cx + cr))
        let gy0 = max(0, Int(cy - cr)), gy1 = min(n - 1, Int(cy + cr))
        guard gx0 <= gx1, gy0 <= gy1 else { return }
        let inv = 1 / (cr * cr)
        for gy in gy0...gy1 {
            let dy = (CGFloat(gy) + 0.5) - cy
            for gx in gx0...gx1 {
                let dx = (CGFloat(gx) + 0.5) - cx
                let d2 = (dx * dx + dy * dy) * inv
                guard d2 < 1 else { continue }
                let q = 1 - d2
                let k = Float(q * q)                    // 1 centre → 0 rim
                let idx = gy * n + gx
                if k > wet[idx] { wet[idx] = k }
                if stroking, !pinned[idx] { pinned[idx] = true; pinnedIdx.append(idx) }
            }
        }
        for by in (gy0 >> 5)...(gy1 >> 5) {
            for bx in (gx0 >> 5)...(gx1 >> 5) { liveBlocks.insert(by * blockN + bx) }
        }
        wetDirty = true
    }

    /// Trigger edge from the AR view. Release unpins the whole stroke so it
    /// starts drying as one piece — the start of a long line stays as glossy
    /// as its end until you let go.
    func setStroking(_ on: Bool) {
        guard stroking != on else { return }
        stroking = on
        if !on {
            for i in pinnedIdx { pinned[i] = false }
            pinnedIdx.removeAll(keepingCapacity: true)
        }
    }

    /// Decay unpinned wetness toward dry and upload what changed — walking
    /// and uploading live blocks only, never the whole million-cell grid.
    func stepWet(dt: Double) {
        guard !liveBlocks.isEmpty else { wetDirty = false; return }
        let n = PaintCanvas.wetN
        let dec = Float(dt / PaintCanvas.dryEndSeconds)
        var changed = wetDirty
        var dead: [Int] = []
        for b in liveBlocks {
            let bx = (b % blockN) << 5, by = (b / blockN) << 5
            var alive = false
            for gy in by..<(by + 32) {
                let row = gy * n
                for gx in bx..<(bx + 32) {
                    let i = row + gx
                    if pinned[i] { alive = true; continue }
                    let v = wet[i]
                    if v > 0 {
                        wet[i] = max(0, v - dec)
                        changed = true
                        if wet[i] > 0 { alive = true }
                    }
                }
            }
            if !alive { dead.append(b) }
        }
        if changed, let wt = wetTex {
            // dead blocks upload their final zeros before they are culled
            for b in liveBlocks {
                let bx = (b % blockN) << 5, by = (b / blockN) << 5
                var o = 0
                for gy in by..<(by + 32) {
                    let row = gy * n
                    for gx in bx..<(bx + 32) {
                        blockStage[o] = UInt8(wet[row + gx] * 255); o += 1
                    }
                }
                wt.replace(region: MTLRegionMake2D(bx, by, 32, 32),
                           mipmapLevel: 0, withBytes: blockStage, bytesPerRow: 32)
            }
        }
        for b in dead { liveBlocks.remove(b) }
        wetDirty = false
    }

    // MARK: tile lookup / creation

    private func tile(atCol col: Int, row: Int, create: Bool) -> Tile? {
        guard col >= 0, row >= 0, col < tilesPerSide, row < tilesPerSide else { return nil }
        let key = row * tilesPerSide + col
        if let t = tiles[key] { return t }
        guard create else { return nil }
        if budget.used >= budget.maxTiles {
            onBudgetExceeded?()          // fire every time so gaps are never silent
            return nil
        }
        let wetOff = CGPoint(x: CGFloat(col) / CGFloat(tilesPerSide),
                             y: CGFloat(row) / CGFloat(tilesPerSide))
        let wetScale = 1.0 / CGFloat(tilesPerSide)
        guard let t = Tile(device: device, wetProp: wetProp, matProp: matProp,
                           wetOff: wetOff, wetScale: wetScale,
                           reflection: reflectionCG, torch: torchBoost),
              let parent = parent else { return nil }
        budget.used += 1
        tiles[key] = t
        // position the tile plane inside the rotated paint root (its XY space)
        let half = surfaceMeters / 2
        let cxM = (CGFloat(col) + 0.5) * PaintCanvas.tileMeters - half
        let cyM = (CGFloat(row) + 0.5) * PaintCanvas.tileMeters - half
        t.node.position = SCNVector3(Float(cxM), Float(-cyM), 0)    // canvas y-down → local -Y
        parent.addChildNode(t.node)
        return t
    }

    /// Run a drawing block on every tile a rect overlaps (translated locally).
    private func withTiles(_ rect: CGRect, _ body: (Tile, CGFloat, CGFloat) -> Void) {
        let tp = CGFloat(PaintCanvas.tilePx)
        let c0 = max(0, Int(rect.minX / tp)), c1 = min(tilesPerSide - 1, Int(rect.maxX / tp))
        let r0 = max(0, Int(rect.minY / tp)), r1 = min(tilesPerSide - 1, Int(rect.maxY / tp))
        guard c0 <= c1, r0 <= r1 else { return }
        for row in r0...r1 {
            for col in c0...c1 {
                guard let t = tile(atCol: col, row: row, create: true) else { continue }
                let ox = CGFloat(col) * tp, oy = CGFloat(row) * tp
                body(t, ox, oy)
                let local = rect.offsetBy(dx: -ox, dy: -oy)
                t.dirty = t.dirty?.union(local) ?? local
                contentRect = contentRect?.union(rect) ?? rect
            }
        }
    }

    // MARK: draw primitives (surface-px coordinates)

    func fillDot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ color: CGColor, _ alpha: CGFloat = 1) {
        let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
        withTiles(rect) { t, ox, oy in
            t.ctx.setFillColor(color)
            t.ctx.setAlpha(alpha)
            t.ctx.fillEllipse(in: rect.offsetBy(dx: -ox, dy: -oy))
            t.ctx.setAlpha(1)
        }
    }

    func strokeSeg(from: CGPoint, to: CGPoint, width: CGFloat, color: CGColor) {
        let pad = width + 2
        let rect = CGRect(x: min(from.x, to.x) - pad, y: min(from.y, to.y) - pad,
                          width: abs(to.x - from.x) + pad * 2,
                          height: abs(to.y - from.y) + pad * 2)
        withTiles(rect) { t, ox, oy in
            t.ctx.setStrokeColor(color)
            t.ctx.setAlpha(1)
            t.ctx.setLineWidth(width)
            t.ctx.move(to: CGPoint(x: from.x - ox, y: from.y - oy))
            t.ctx.addLine(to: CGPoint(x: to.x - ox, y: to.y - oy))
            t.ctx.strokePath()
        }
    }

    func fillBlob(_ x: CGFloat, _ y: CGFloat, _ rw: CGFloat, _ rh: CGFloat, _ color: CGColor) {
        let rect = CGRect(x: x - rw, y: y - rh, width: rw * 2, height: rh * 2)
        withTiles(rect) { t, ox, oy in
            t.ctx.setFillColor(color)
            t.ctx.setAlpha(1)
            t.ctx.fillEllipse(in: rect.offsetBy(dx: -ox, dy: -oy))
        }
    }

    // MARK: maintenance

    /// Upload only what changed on each touched tile. Call once per frame.
    func flush(dt: Double = 0) {
        if dt > 0 { stepWet(dt: dt) }
        let size = PaintCanvas.tilePx
        for t in tiles.values {
            guard var r = t.dirty, let data = t.ctx.data else { continue }
            t.dirty = nil
            r = r.intersection(CGRect(x: 0, y: 0, width: size, height: size))
            guard !r.isNull, r.width >= 1, r.height >= 1 else { continue }
            let x = Int(r.minX), y = Int(r.minY)
            let w = min(size - x, Int(r.width.rounded(.up)) + 1)
            let h = min(size - y, Int(r.height.rounded(.up)) + 1)
            guard w > 0, h > 0 else { continue }
            let src = data.advanced(by: y * t.bpr + x * 4)
            t.texture.replace(region: MTLRegionMake2D(x, y, w, h),
                              mipmapLevel: 0, withBytes: src, bytesPerRow: t.bpr)
            t.mipsDirty = true
        }
        regenerateMips()
    }

    /// Rebuild the mip chains of any freshly painted tiles (one GPU blit pass)
    /// — this is what gives the distance softness that removes moiré.
    private func regenerateMips() {
        let stale = tiles.values.filter { $0.mipsDirty }
        guard !stale.isEmpty, let queue = queue,
              let buf = queue.makeCommandBuffer(),
              let blit = buf.makeBlitCommandEncoder() else { return }
        for t in stale {
            blit.generateMipmaps(for: t.texture)
            t.mipsDirty = false
        }
        blit.endEncoding()
        buf.commit()
    }

    /// Full-resolution composite of everything painted, transparent background.
    func exportImage() -> CGImage? {
        guard var box = contentRect, !tiles.isEmpty else { return nil }
        box = box.insetBy(dx: -16, dy: -16)
            .intersection(CGRect(x: 0, y: 0, width: sizePx, height: sizePx))
        guard box.width > 4, box.height > 4 else { return nil }
        // cap the output so a huge painted area cannot exhaust memory
        let scale = min(1, 8192 / max(box.width, box.height))
        let w = Int(box.width * scale), h = Int(box.height * scale)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let out = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let tp = CGFloat(PaintCanvas.tilePx)
        for (key, t) in tiles {
            guard let img = t.ctx.makeImage() else { continue }
            let col = key % tilesPerSide, row = key / tilesPerSide
            let ox = CGFloat(col) * tp - box.minX
            let oy = CGFloat(row) * tp - box.minY
            // CG places images bottom-up: convert the tile's top-left origin
            out.draw(img, in: CGRect(x: ox * scale,
                                     y: (box.height - oy - tp) * scale,
                                     width: tp * scale, height: tp * scale))
        }
        return out.makeImage()
    }

    func clearAll() {
        let size = PaintCanvas.tilePx
        for t in tiles.values {
            t.ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
            if let data = t.ctx.data {
                t.texture.replace(region: MTLRegionMake2D(0, 0, size, size),
                                  mipmapLevel: 0, withBytes: data, bytesPerRow: t.bpr)
            }
            t.dirty = nil
            t.mipsDirty = true
        }
        // a cleared wall is a dry wall — zero the live blocks and let stepWet
        // upload the zeros and cull them
        for i in pinnedIdx { pinned[i] = false }
        pinnedIdx.removeAll(keepingCapacity: true)
        for b in liveBlocks {
            let bx = (b % blockN) << 5, by = (b / blockN) << 5
            for gy in by..<(by + 32) {
                let row = gy * PaintCanvas.wetN
                for gx in bx..<(bx + 32) { wet[row + gx] = 0 }
            }
        }
        wetDirty = !liveBlocks.isEmpty
        contentRect = nil
        regenerateMips()
    }

    func teardown() {
        for t in tiles.values { t.node.removeFromParentNode() }
        budget.used -= tiles.count
        tiles.removeAll()
    }
}
