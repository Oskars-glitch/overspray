import UIKit
import CoreGraphics
import Metal

/// Spray-paint physics + Metal-backed paint texture.
///
/// Realism model:
/// - the spray is a FIELD OF DOTS, never a solid disc: compact and dense up
///   close, scattered fine speckle from afar
/// - oblique spraying stretches the dot field into an oval along the spray
///   direction (like a real can held at an angle)
/// - drips depend on distance AND hand speed: close + still = dripping,
///   close + fast = nothing, far = only after long spraying in one spot;
///   they are short, opaque, continuous lines that grow only if you stay
/// - only the dirty region of the texture is uploaded to the GPU each frame
final class SprayEngine {
    private let texSize: Int
    private let ppm: CGFloat                       // texture px per metre
    private let ctx: CGContext
    private let bytesPerRow: Int
    let texture: MTLTexture

    private let cell = 8
    private let grid: Int
    private var accum: [Float]
    private var dripCount: [UInt8]
    private var drips: [Drip] = []
    private let dripDir: CGVector                  // gravity-down on the texture
    private let dripPerp: CGVector
    private var dirty: CGRect?
    private let dripThreshold: Float = 1.0

    struct Drip {
        var origin: CGPoint
        var pos: CGPoint
        var vol: CGFloat
        var budget: CGFloat                        // texels it may still run
        var travelled: CGFloat = 0
        var width: CGFloat
        var wobble: CGFloat
        var seed: CGFloat
        var endBlob: Bool
        var color: CGColor
    }

    init?(texSize: Int, ppm: CGFloat, dripDirection: CGVector, device: MTLDevice) {
        self.texSize = texSize
        self.ppm = ppm
        grid = texSize / cell
        accum = .init(repeating: 0, count: grid * grid)
        dripCount = .init(repeating: 0, count: grid * grid)
        let len = max(0.0001, hypot(dripDirection.dx, dripDirection.dy))
        dripDir = CGVector(dx: dripDirection.dx / len, dy: dripDirection.dy / len)
        dripPerp = CGVector(dx: -dripDir.dy, dy: dripDir.dx)

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let c = CGContext(data: nil, width: texSize, height: texSize,
                                bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx = c
        bytesPerRow = c.bytesPerRow
        // flip to top-left origin like a web canvas, so the maths ports 1:1
        ctx.translateBy(x: 0, y: CGFloat(texSize))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setLineCap(.round)

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: texSize, height: texSize, mipmapped: false)
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        texture = tex
        uploadAll()
    }

    // MARK: dirty-region GPU upload (the lag fix)

    private func mark(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
        let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
        dirty = dirty?.union(rect) ?? rect
    }

    private func uploadAll() {
        guard let data = ctx.data else { return }
        texture.replace(region: MTLRegionMake2D(0, 0, texSize, texSize),
                        mipmapLevel: 0, withBytes: data, bytesPerRow: bytesPerRow)
    }

    /// Upload only what changed. Call once per frame.
    func flush() {
        guard var r = dirty, let data = ctx.data else { return }
        dirty = nil
        r = r.intersection(CGRect(x: 0, y: 0, width: texSize, height: texSize))
        guard !r.isNull, r.width >= 1, r.height >= 1 else { return }
        let x = Int(r.minX), y = Int(r.minY)
        let w = min(texSize - x, Int(r.width.rounded(.up)) + 1)
        let h = min(texSize - y, Int(r.height.rounded(.up)) + 1)
        guard w > 0, h > 0 else { return }
        let src = data.advanced(by: y * bytesPerRow + x * 4)
        texture.replace(region: MTLRegionMake2D(x, y, w, h),
                        mipmapLevel: 0, withBytes: src, bytesPerRow: bytesPerRow)
    }

    func clear() {
        ctx.clear(CGRect(x: 0, y: 0, width: texSize, height: texSize))
        accum = .init(repeating: 0, count: grid * grid)
        dripCount = .init(repeating: 0, count: grid * grid)
        drips.removeAll()
        uploadAll()
        dirty = nil
    }

    // MARK: spraying

    private func rnd() -> CGFloat { CGFloat.random(in: 0...1) }
    private func gaussRnd() -> CGFloat {
        (CGFloat.random(in: 0...1) + CGFloat.random(in: 0...1) + CGFloat.random(in: 0...1)) * 0.6667 - 1
    }

    private func fillDot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ color: CGColor, _ alpha: CGFloat) {
        ctx.setFillColor(color)
        ctx.setAlpha(alpha)
        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        mark(x, y, r)
    }

    /// stroke-interpolated stamps → consistent lines at any hand speed.
    /// stretch/stretchDir describe the oval footprint when spraying at an angle.
    /// speed (m/s of the spray spot on the wall) gates drip accumulation.
    func sprayStroke(from: CGPoint, to: CGPoint, distance: Double,
                     coneDeg: Double, color: CGColor, dt: Double,
                     stretch: CGFloat, stretchDir: CGVector) {
        let d = max(0.10, distance)
        let k = CGFloat(pow(4.5 / coneDeg, 0.5))              // skinny cap = denser
        let radius = max(6.0, tan(coneDeg * .pi / 180) * d * Double(ppm))
        let pathLen = hypot(to.x - from.x, to.y - from.y)
        let speedM = Double(pathLen / ppm) / max(dt, 0.001)   // wall-space m/s
        // stillness: 1 when holding still, 0 when sweeping ≥ 0.30 m/s
        let still = pow(max(0.0, 1.0 - speedM / 0.30), 1.5)
        let stamps = max(1, min(16, Int(ceil(Double(pathLen) / max(3.0, radius * 0.45)))))
        for s in 1...stamps {
            let f = CGFloat(s) / CGFloat(stamps)
            let p = CGPoint(x: from.x + (to.x - from.x) * f,
                            y: from.y + (to.y - from.y) * f)
            stamp(at: p, d: CGFloat(d), k: k, R: CGFloat(radius), color: color,
                  dtShare: dt / Double(stamps), still: CGFloat(still),
                  stretch: stretch, sd: stretchDir)
        }
    }

    private func stamp(at c: CGPoint, d: CGFloat, k: CGFloat, R: CGFloat,
                       color: CGColor, dtShare: Double, still: CGFloat,
                       stretch: CGFloat, sd: CGVector) {
        // oval placement: isotropic offsets stretched along the spray direction
        @inline(__always) func place(_ ox: CGFloat, _ oy: CGFloat) -> CGPoint {
            CGPoint(x: c.x + sd.dx * ox * stretch - sd.dy * oy,
                    y: c.y + sd.dy * ox * stretch + sd.dx * oy)
        }

        let fall = pow(d, 1.6)
        let alpha = min(0.9, max(0.05, 0.55 * k / fall))
        // closeness drives compactness: tight dense dots near, wide speckle far
        let close = min(1, max(0, (0.85 - d) / 0.85))
        let sigma = R * (0.40 + 0.34 * (1 - close))
        let count = Int(30 + 55 * close)
        // dot size in real millimetres, slightly larger droplets when far
        let mm = ppm / 1000

        // a couple of soft wet patches ONLY at very close range
        if d < 0.55 {
            let wetA = min(0.55, 0.30 * k / fall) * close
            for _ in 0..<2 {
                let p = place(gaussRnd() * R * 0.25, gaussRnd() * R * 0.25)
                fillDot(p.x, p.y, R * (0.34 + rnd() * 0.22), color, wetA * (0.5 + rnd() * 0.5))
            }
        }

        // the dot field
        for _ in 0..<count {
            let ox = gaussRnd() * sigma, oy = gaussRnd() * sigma
            let p = place(ox, oy)
            let r = (0.5 + rnd() * 1.7) * (1 + d * 0.6) * mm
            fillDot(p.x, p.y, max(0.7, r), color, alpha * (0.4 + rnd() * 0.8))
        }
        // stray splatter beyond the cone — more of it when far
        let spl = 2 + Int((3 * d).rounded())
        for _ in 0..<spl {
            let a = rnd() * .pi * 2, rr = R * (1.15 + rnd() * 1.4)
            let p = place(cos(a) * rr, sin(a) * rr)
            fillDot(p.x, p.y, max(0.7, (0.5 + rnd() * 1.4) * mm * (1 + d * 0.5)),
                    color, alpha * (0.4 + rnd() * 0.7))
        }
        // occasional fat spit
        if rnd() < 0.08 {
            let p = place(gaussRnd() * R * 0.8, gaussRnd() * R * 0.8)
            fillDot(p.x, p.y, (1.2 + rnd() * 2.2) * mm * 2, color, min(0.95, alpha * 3))
        }
        ctx.setAlpha(1)

        accumulate(at: c, d: d, k: k, R: R, color: color,
                   dtShare: dtShare, still: still, stretch: stretch, sd: sd)
    }

    // MARK: accumulation → drips
    // close + still = dripping · close + fast = nothing · far = long soak needed

    private func accumulate(at c: CGPoint, d: CGFloat, k: CGFloat, R: CGFloat,
                            color: CGColor, dtShare: Double, still: CGFloat,
                            stretch: CGFloat, sd: CGVector) {
        guard still > 0.01 else { return }
        let wet = R * 0.62
        let wetEff = max(wet, CGFloat(cell) * 0.75)
        let bound = wetEff * max(1, stretch)
        let localR = max(0.10 * ppm, wet * 2.3)    // one "spot" ≈ the footprint
        let localMax = 3
        let flux = Float(min(14.0, 4.0 * Double(k) / Double(d * d)) * Double(still))
        let g0x = max(0, Int((c.x - bound) / CGFloat(cell)))
        let g1x = min(grid - 1, Int((c.x + bound) / CGFloat(cell)))
        let g0y = max(0, Int((c.y - bound) / CGFloat(cell)))
        let g1y = min(grid - 1, Int((c.y + bound) / CGFloat(cell)))
        guard g0x <= g1x, g0y <= g1y else { return }
        let wet2 = wetEff * wetEff

        for gy in g0y...g1y {
            for gx in g0x...g1x {
                let cx = CGFloat(gx * cell + cell / 2), cy = CGFloat(gy * cell + cell / 2)
                let dx = cx - c.x, dy = cy - c.y
                // elliptical wet zone matching the oval footprint
                let u = (dx * sd.dx + dy * sd.dy) / max(1, stretch)
                let v = -dx * sd.dy + dy * sd.dx
                if u * u + v * v > wet2 { continue }
                let idx = gy * grid + gx
                let nv = accum[idx] + flux * Float(dtShare)
                accum[idx] = min(Float(3), nv)
                if nv > dripThreshold, rnd() < CGFloat((Double(nv) - 1) * dtShare * 10) {
                    accum[idx] = dripThreshold * 0.5
                    var near: Int? = nil
                    var nearD = CGFloat.greatestFiniteMagnitude
                    var nearCount = 0
                    for (qi, q) in drips.enumerated() {
                        let dd = hypot(q.origin.x - cx, q.origin.y - cy)
                        if dd < localR {
                            nearCount += 1
                            if dd < nearD { nearD = dd; near = qi }
                        }
                    }
                    let bonus = 1 + 0.4 * CGFloat(min(6, Int(dripCount[idx])))
                    let vol = min(3.2, (0.3 + CGFloat(Double(nv) - 1) * 1.6 + rnd() * 0.6) * bonus)
                    if nearCount > 0 {
                        if rnd() < 0.10, let ni = near {
                            // staying in one place FEEDS the drips → they grow
                            let extra = vol * (0.010 + rnd() * 0.020) * ppm
                            drips[ni].budget = min(0.5 * ppm, drips[ni].budget + extra)
                            drips[ni].vol = min(3.6, drips[ni].vol + 0.12)
                        } else if nearCount < localMax, rnd() < 0.05, drips.count < 60 {
                            spawnDrip(x: cx, y: cy, vol: vol, color: color)
                        }
                    } else if drips.count < 60 {
                        dripCount[idx] = UInt8(min(250, Int(dripCount[idx]) + 1))
                        spawnDrip(x: cx, y: cy, vol: vol, color: color)
                    }
                }
            }
        }
    }

    private func spawnDrip(x: CGFloat, y: CGFloat, vol: CGFloat, color: CGColor) {
        // short by default (a few centimetres); only feeding makes them long
        drips.append(Drip(
            origin: CGPoint(x: x, y: y),
            pos: CGPoint(x: x + gaussRnd() * 0.003 * ppm, y: y),
            vol: vol,
            budget: vol * (0.020 + rnd() * 0.045) * ppm,
            width: max(1.0, (0.0012 + vol * 0.0011) * (0.75 + rnd() * 0.5) * ppm),
            wobble: 0.03 + rnd() * 0.15,
            seed: rnd() * 100,
            endBlob: rnd() < 0.7,
            color: color))
    }

    func stepDrips(dt: Double) {
        guard !drips.isEmpty else { return }
        for i in stride(from: drips.count - 1, through: 0, by: -1) {
            var dr = drips[i]
            let remain = 1 - dr.travelled / dr.budget
            let speed = max(0.004, (0.008 + Double(dr.vol) * 0.035) * Double(remain)) * Double(ppm)
            let step = CGFloat(speed * dt)
            let wob = sin(dr.travelled * 0.05 + dr.seed) * step * dr.wobble
            let nx = dr.pos.x + dripDir.dx * step + dripPerp.dx * wob
            let ny = dr.pos.y + dripDir.dy * step + dripPerp.dy * wob
            let w = dr.width * (0.35 + 0.65 * remain)

            // OPAQUE stroke → one continuous line, no dotted overlap artifacts
            ctx.setStrokeColor(dr.color)
            ctx.setAlpha(1.0)
            ctx.setLineWidth(w)
            ctx.move(to: dr.pos)
            ctx.addLine(to: CGPoint(x: nx, y: ny))
            ctx.strokePath()
            mark((dr.pos.x + nx) / 2, (dr.pos.y + ny) / 2,
                 max(w, hypot(nx - dr.pos.x, ny - dr.pos.y)) + 2)

            dr.pos = CGPoint(x: nx, y: ny)
            dr.travelled += step
            let off = nx < 4 || ny < 4 || nx > CGFloat(texSize) - 4 || ny > CGFloat(texSize) - 4
            if dr.travelled >= dr.budget || off {
                if dr.endBlob, !off {
                    ctx.setFillColor(dr.color)
                    let rw = w * (0.6 + rnd() * 0.4), rh = w * (0.9 + rnd() * 0.6)
                    ctx.fillEllipse(in: CGRect(x: dr.pos.x - rw, y: dr.pos.y - rh,
                                               width: rw * 2, height: rh * 2))
                    mark(dr.pos.x, dr.pos.y, max(rw, rh) + 1)
                }
                drips.remove(at: i)
            } else {
                drips[i] = dr
            }
        }
        ctx.setAlpha(1)
    }
}
