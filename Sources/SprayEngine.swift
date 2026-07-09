import UIKit
import CoreGraphics

/// The spray-paint physics, ported from the tuned web version:
/// - stroke-interpolated stamps → solid lines at any hand speed
/// - blobby core + rim-biased grain + clumps + stray splatter
/// - paint accumulation → 1–3 drips per spot; more spraying FEEDS the
///   existing drips so they run longer; drips fall toward real-world down
final class SprayEngine {
    private let texSize: Int
    private let ppm: CGFloat
    private let ctx: CGContext
    private let cell = 8
    private let grid: Int
    private var accum: [Float]
    private var dripCount: [UInt8]
    private var drips: [Drip] = []
    private let dripDir: CGVector          // unit, gravity-down on the texture
    private let dripPerp: CGVector
    private var dirty = false
    private let dripThreshold: Float = 1.0

    struct Drip {
        var origin: CGPoint
        var pos: CGPoint
        var vol: CGFloat
        var budget: CGFloat
        var travelled: CGFloat = 0
        var width: CGFloat
        var wobble: CGFloat
        var seed: CGFloat
        var endBlob: Bool
        var color: CGColor
    }

    init(texSize: Int, ppm: CGFloat, dripDirection: CGVector) {
        self.texSize = texSize
        self.ppm = ppm
        grid = texSize / cell
        accum = .init(repeating: 0, count: grid * grid)
        dripCount = .init(repeating: 0, count: grid * grid)
        let len = max(0.0001, hypot(dripDirection.dx, dripDirection.dy))
        dripDir = CGVector(dx: dripDirection.dx / len, dy: dripDirection.dy / len)
        dripPerp = CGVector(dx: -dripDir.dy, dy: dripDir.dx)

        let cs = CGColorSpaceCreateDeviceRGB()
        ctx = CGContext(data: nil, width: texSize, height: texSize,
                        bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // flip to top-left origin like a web canvas, so the maths ports 1:1
        ctx.translateBy(x: 0, y: CGFloat(texSize))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setLineCap(.round)
    }

    func clear() {
        ctx.clear(CGRect(x: 0, y: 0, width: texSize, height: texSize))
        accum = .init(repeating: 0, count: grid * grid)
        dripCount = .init(repeating: 0, count: grid * grid)
        drips.removeAll()
        dirty = true
    }

    func takeDirty() -> Bool { let d = dirty; dirty = false; return d }

    func makeImage() -> CGImage? { ctx.makeImage() }

    // MARK: spraying

    func sprayStroke(from: CGPoint, to: CGPoint, distance: Double,
                     coneDeg: Double, color: CGColor, dt: Double) {
        let d = max(0.15, distance)
        let k = pow(4.5 / coneDeg, 0.5)                       // skinny = denser
        let radius = max(4, tan(coneDeg * .pi / 180) * d * Double(ppm))
        let pathLen = hypot(to.x - from.x, to.y - from.y)
        let stamps = max(1, min(24, Int(ceil(Double(pathLen) / max(3, radius * 0.45)))))
        for s in 1...stamps {
            let f = CGFloat(s) / CGFloat(stamps)
            let p = CGPoint(x: from.x + (to.x - from.x) * f,
                            y: from.y + (to.y - from.y) * f)
            stamp(at: p, d: d, k: k, radius: radius, coneDeg: coneDeg,
                  color: color, dtShare: dt / Double(stamps))
        }
        dirty = true
    }

    private func rnd() -> CGFloat { CGFloat.random(in: 0...1) }
    private func gaussRnd() -> CGFloat {
        (CGFloat.random(in: 0...1) + CGFloat.random(in: 0...1) + CGFloat.random(in: 0...1)) * 0.6667 - 1
    }

    private func fillDot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ color: CGColor, _ alpha: CGFloat) {
        ctx.setFillColor(color)
        ctx.setAlpha(alpha)
        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    private func stamp(at p: CGPoint, d: Double, k: Double, radius: Double,
                       coneDeg: Double, color: CGColor, dtShare: Double) {
        let R = CGFloat(radius)
        let fall = pow(d, 1.6)                                // gentler than physical d²
        let coreA = CGFloat(min(0.7, 0.44 * k / fall))
        let alpha = CGFloat(min(0.95, max(0.08, 0.7 * k / fall)))
        let coneK = coneDeg / 4.5

        if R < 14 {
            // low texture resolution: simpler, denser stamp (sub-pixel speckle
            // would just be diluted by anti-aliasing)
            for _ in 0..<3 {
                fillDot(p.x + gaussRnd() * R * 0.2, p.y + gaussRnd() * R * 0.2,
                        max(1.2, R * (0.5 + rnd() * 0.4)), color,
                        min(0.8, coreA * 1.6) * (0.5 + rnd() * 0.5))
            }
            for _ in 0..<8 {
                let a = rnd() * .pi * 2, rr = R * (0.6 + rnd() * 0.8)
                fillDot(p.x + cos(a) * rr, p.y + sin(a) * rr,
                        max(0.8, R * 0.12), color,
                        min(0.9, alpha * 1.2) * (0.4 + rnd() * 0.6))
            }
        } else {
            // blobby core — never a clean circle
            for _ in 0..<4 {
                fillDot(p.x + gaussRnd() * R * 0.24, p.y + gaussRnd() * R * 0.24,
                        R * (0.36 + rnd() * 0.32), color,
                        coreA * (0.35 + rnd() * 0.45))
            }
            // rim-biased grain
            let gN = Int((26 * min(2, coneK)).rounded())
            let gS = CGFloat(sqrt(coneK)) * CGFloat(0.55 + d * 0.6)
            for _ in 0..<gN {
                let rr = rnd() < 0.35 ? R * (0.72 + rnd() * 0.42)
                                      : R * 0.8 * sqrt(rnd())
                let a = rnd() * .pi * 2
                fillDot(p.x + cos(a) * rr + gaussRnd() * 1.5,
                        p.y + sin(a) * rr + gaussRnd() * 1.5,
                        (0.45 + rnd() * 1.5) * gS, color,
                        alpha * (0.4 + rnd() * 0.8))
            }
            // clump on the rim → lumpy silhouette
            let ca = rnd() * .pi * 2
            let kx = p.x + cos(ca) * R * 0.9, ky = p.y + sin(ca) * R * 0.9
            for _ in 0..<4 {
                fillDot(kx + gaussRnd() * R * 0.18, ky + gaussRnd() * R * 0.18,
                        (0.5 + rnd() * 1.4) * CGFloat(0.55 + d * 0.6), color,
                        alpha * (0.5 + rnd() * 0.7))
            }
            // stray splatter outside the cone
            for _ in 0..<(2 + Int((2 * d).rounded())) {
                let sa = rnd() * .pi * 2, sr = R * (1.15 + rnd() * 1.9)
                fillDot(p.x + cos(sa) * sr, p.y + sin(sa) * sr,
                        (0.6 + rnd() * 1.6) * CGFloat(0.5 + d * 0.5), color,
                        alpha * (0.5 + rnd() * 0.9))
            }
            // occasional fat spit
            if rnd() < 0.10 {
                fillDot(p.x + gaussRnd() * R * 0.9, p.y + gaussRnd() * R * 0.9,
                        1.6 + rnd() * 2.8 * CGFloat(0.6 + d * 0.4), color,
                        min(0.95, alpha * 3))
            }
        }
        ctx.setAlpha(1)

        accumulate(at: p, d: d, k: k, radius: R, color: color, dtShare: dtShare)
    }

    // MARK: accumulation → drips (1–3 per spot; extra paint feeds them)

    private func accumulate(at p: CGPoint, d: Double, k: Double,
                            radius R: CGFloat, color: CGColor, dtShare: Double) {
        let wet = R * 0.62
        let wetEff = max(wet, CGFloat(cell) * 0.75)   // never smaller than a cell
        let localR = max(70, wet * 2.3)
        let localMax = 3
        let flux = Float(min(12, 3.2 * k / (d * d)))
        let g0x = max(0, Int((p.x - wetEff) / CGFloat(cell)))
        let g1x = min(grid - 1, Int((p.x + wetEff) / CGFloat(cell)))
        let g0y = max(0, Int((p.y - wetEff) / CGFloat(cell)))
        let g1y = min(grid - 1, Int((p.y + wetEff) / CGFloat(cell)))
        let wet2 = wetEff * wetEff

        guard g0x <= g1x, g0y <= g1y else { return }
        for gy in g0y...g1y {
            for gx in g0x...g1x {
                let cx = CGFloat(gx * cell + cell / 2), cy = CGFloat(gy * cell + cell / 2)
                let dx = cx - p.x, dy = cy - p.y
                if dx * dx + dy * dy > wet2 { continue }
                let idx = gy * grid + gx
                let v = accum[idx] + flux * Float(dtShare)
                accum[idx] = min(3, v)
                if v > dripThreshold, rnd() < CGFloat((Double(v) - 1) * dtShare * 10) {
                    accum[idx] = dripThreshold * 0.5
                    // nearby active drips?
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
                    let vol = min(3.2, (0.3 + CGFloat(Double(v) - 1) * 1.6 + rnd() * 0.6) * bonus)
                    if nearCount > 0 {
                        if rnd() < 0.10, let ni = near {          // ration the feeding
                            drips[ni].budget = min(2400, drips[ni].budget + vol * (40 + rnd() * 80))
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
        drips.append(Drip(
            origin: CGPoint(x: x, y: y),
            pos: CGPoint(x: x + gaussRnd() * 4, y: y),
            vol: vol,
            budget: vol * (90 + rnd() * 520),
            width: max(0.8, (1.1 + vol * 2.6) * (0.7 + rnd() * 0.6)),
            wobble: 0.03 + rnd() * 0.18,
            seed: rnd() * 100,
            endBlob: rnd() < 0.7,
            color: color))
    }

    func stepDrips(dt: Double) {
        guard !drips.isEmpty else { return }
        for i in stride(from: drips.count - 1, through: 0, by: -1) {
            var dr = drips[i]
            let remain = 1 - dr.travelled / dr.budget
            let speed = max(9, (20 + dr.vol * 110) * remain)
            let step = speed * CGFloat(dt)
            let wob = sin(dr.travelled * 0.05 + dr.seed) * step * dr.wobble
            let nx = dr.pos.x + dripDir.dx * step + dripPerp.dx * wob
            let ny = dr.pos.y + dripDir.dy * step + dripPerp.dy * wob
            let w = dr.width * (0.30 + 0.70 * remain)

            ctx.setStrokeColor(dr.color)
            ctx.setAlpha(0.88)
            ctx.setLineWidth(w)
            ctx.move(to: dr.pos)
            ctx.addLine(to: CGPoint(x: nx, y: ny))
            ctx.strokePath()

            dr.pos = CGPoint(x: nx, y: ny)
            dr.travelled += step
            let off = nx < 4 || ny < 4 || nx > CGFloat(texSize) - 4 || ny > CGFloat(texSize) - 4
            if dr.travelled >= dr.budget || off {
                if dr.endBlob, !off {
                    ctx.setFillColor(dr.color)
                    let rw = w * (0.6 + rnd() * 0.5), rh = w * (0.9 + rnd() * 0.7)
                    ctx.fillEllipse(in: CGRect(x: dr.pos.x - rw, y: dr.pos.y - rh,
                                               width: rw * 2, height: rh * 2))
                }
                drips.remove(at: i)
            } else {
                drips[i] = dr
            }
            dirty = true
        }
        ctx.setAlpha(1)
    }
}
