import SceneKit
import Metal
import UIKit

/// Global cap on allocated paint tiles (memory care for older iPhones).
final class TileBudget {
    var used = 0
    let maxTiles = 10
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

    final class Tile {
        let ctx: CGContext
        let bpr: Int
        let texture: MTLTexture
        let node: SCNNode
        var dirty: CGRect?
        var mipsDirty = true          // mip chain needs regenerating after uploads

        init?(device: MTLDevice) {
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

            // wet-paint look: specular sheen ONLY on the paint (masked by its
            // alpha) and ONLY from close up (fades out past ~0.9 m)
            let material = SCNMaterial()
            material.lightingModel = .blinn
            material.diffuse.contents = tex
            material.diffuse.mipFilter = .linear          // trilinear between mips
            material.diffuse.maxAnisotropy = 4            // stays crisp at oblique views
            material.specular.contents = UIColor(white: 0.23, alpha: 1)
            material.shininess = 24
            material.isDoubleSided = false
            material.transparencyMode = .aOne
            material.shaderModifiers = [
                .surface: """
                float camDist = length(_surface.position);
                float near = clamp((1.6 - camDist) / 1.2, 0.0, 1.0);
                _surface.shininess = 4.0 + 70.0 * near * near;
                _surface.specular.rgb = _surface.specular.rgb * _surface.diffuse.a * (0.35 + 0.65 * near);
                """
            ]
            let geo = SCNPlane(width: PaintCanvas.tileMeters, height: PaintCanvas.tileMeters)
            geo.materials = [material]
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
    }

    // MARK: tile lookup / creation

    private func tile(atCol col: Int, row: Int, create: Bool) -> Tile? {
        guard col >= 0, row >= 0, col < tilesPerSide, row < tilesPerSide else { return nil }
        let key = row * tilesPerSide + col
        if let t = tiles[key] { return t }
        guard create else { return nil }
        if budget.used >= budget.maxTiles {
            if !budget.warned { budget.warned = true; onBudgetExceeded?() }
            return nil
        }
        guard let t = Tile(device: device), let parent = parent else { return nil }
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
    func flush() {
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
        contentRect = nil
        regenerateMips()
    }

    func teardown() {
        for t in tiles.values { t.node.removeFromParentNode() }
        budget.used -= tiles.count
        tiles.removeAll()
    }
}
