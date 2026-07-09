import UIKit
import CoreGraphics

/// Spray physics. Draws through a PaintCanvas (tiled, GPU-backed).
///
/// Realism model:
/// - every dot is OPAQUE, like real paint droplets; coverage comes from
///   density: compact and dense up close, sparse scattered speckle far away
/// - oblique spraying stretches the dot field into an oval
/// - drips: close + still = dripping · close + fast = nothing ·
///   far = only after long spraying in one spot; short, continuous, opaque
final class SprayEngine {
    private let canvas: PaintCanvas
    private let ppm: CGFloat
    private let sizePx: CGFloat

    private let cellPx: CGFloat = 32                 // accumulation cell ≈ 8 mm
    private let grid: Int
    private var accum: [Float]
    private var dripCount: [UInt8]
    private var drips: [Drip] = []
    private let dripDir: CGVector
    private let dripPerp: CGVector
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

    init(canvas: PaintCanvas, dripDirection: CGVector) {
        self.canvas = canvas
        ppm = PaintCanvas.ppm
        sizePx = canvas.sizePx
        grid = Int(sizePx / cellPx)
        accum = .init(repeating: 0, count: grid * grid)
        dripCount = .init(repeating: 0, count: grid * grid)
        let len = max(0.0001, hypot(dripDirection.dx, dripDirection.dy))
        dripDir = CGVector(dx: dripDirection.dx / len, dy: dripDirection.dy / len)
        dripPerp = CGVector(dx: -dripDir.dy, dy: dripDir.dx)
    }

    func clear() {
        accum = .init(repeating: 0, count: grid * grid)
        dripCount = .init(repeating: 0, count: grid * grid)
        drips.removeAll()
        canvas.clearAll()
    }

    func flush() { canvas.flush() }

    private func rnd() -> CGFloat { CGFloat.random(in: 0...1) }
    private func gaussRnd() -> CGFloat {
        (CGFloat.random(in: 0...1) + CGFloat.random(in: 0...1) + CGFloat.random(in: 0...1)) * 0.6667 - 1
    }

    // MARK: spraying

    func sprayStroke(from: CGPoint, to: CGPoint, distance: Double,
                     coneDeg: Double, color: CGColor, dt: Double,
                     stretch: CGFloat, stretchDir: CGVector) {
        let d = max(0.10, distance)
        let k = CGFloat(pow(4.5 / coneDeg, 0.5))
        let radius = max(8.0, tan(coneDeg * .pi / 180) * d * Double(ppm))
        let pathLen = hypot(to.x - from.x, to.y - from.y)
        let speedM = Double(pathLen / ppm) / max(dt, 0.001)
        let still = pow(max(0.0, 1.0 - speedM / 0.30), 1.5)
        let stamps = max(1, min(16, Int(ceil(Double(pathLen) / max(6.0, radius * 0.45)))))
        for s in 1...stamps {
            let f = CGFloat(s) / CGFloat(stamps)
            let p = CGPoint(x: from.x + (to.x - from.x) * f,
                            y: from.y + (to.y - from.y) * f)
            stamp(at: p, d: CGFloat(d), k: k, R: CGFloat(radius), color: color,
                  dtShare: dt / Double(stamps), still: CGFloat(still),
                  stretch: stretch, sd: stretchDir,
                  budgetShare: max(1, stamps))
        }
    }

    private func stamp(at c: CGPoint, d: CGFloat, k: CGFloat, R: CGFloat,
                       color: CGColor, dtShare: Double, still: CGFloat,
                       stretch: CGFloat, sd: CGVector, budgetShare: Int) {
        @inline(__always) func place(_ ox: CGFloat, _ oy: CGFloat) -> CGPoint {
            CGPoint(x: c.x + sd.dx * ox * stretch - sd.dy * oy,
                    y: c.y + sd.dy * ox * stretch + sd.dx * oy)
        }

        // OPAQUE dot field: density carries the look, never transparency.
        // Close: few but PRECISE tight dots (crisp round cluster, no strays).
        // Far: finer dots scattered wide, plus stray splatter.
        let close = min(1, max(0, (0.85 - d) / 0.85))
        let sigma = R * (0.30 + 0.50 * (1 - close))
        var count = Int((60 + 240 * close) * k * 2)      // 2× paint flow
        count = min(count, max(40, 2000 / budgetShare))  // frame budget on fast sweeps
        let mm = ppm / 1000

        for _ in 0..<count {
            let p = place(gaussRnd() * sigma, gaussRnd() * sigma)
            let r = (0.10 + rnd() * rnd() * 0.45) * (1 + d * 0.5) * mm
            canvas.fillDot(p.x, p.y, max(0.9, r), color)
        }
        // stray splatter only appears from a distance — up close the cone is tight
        if d > 0.35 {
            let spl = Int((3 * d).rounded())
            for _ in 0..<spl {
                let a = rnd() * .pi * 2, rr = R * (1.15 + rnd() * 1.4)
                let p = place(cos(a) * rr, sin(a) * rr)
                canvas.fillDot(p.x, p.y, max(0.9, (0.15 + rnd() * 0.4) * mm * (1 + d * 0.5)), color)
            }
        }
        // occasional fat spit (also not at point-blank range)
        if d > 0.3, rnd() < 0.06 {
            let p = place(gaussRnd() * R * 0.8, gaussRnd() * R * 0.8)
            canvas.fillDot(p.x, p.y, (0.5 + rnd() * 0.9) * mm * 2, color)
        }

        accumulate(at: c, d: d, k: k, R: R, color: color,
                   dtShare: dtShare, still: still, stretch: stretch, sd: sd)
    }

    // MARK: accumulation → drips

    private func accumulate(at c: CGPoint, d: CGFloat, k: CGFloat, R: CGFloat,
                            color: CGColor, dtShare: Double, still: CGFloat,
                            stretch: CGFloat, sd: CGVector) {
        guard still > 0.01 else { return }
        // drips are a CLOSE-range phenomenon: full inside ~0.3 m, gone by ~0.9 m —
        // distant mist stays dry no matter how long you spray
        let dripGate = pow(min(1.0, max(0.0, (0.9 - Double(d)) / 0.6)), 1.5)
        guard dripGate > 0.02 else { return }
        let wet = R * 0.62
        let wetEff = max(wet, cellPx * 0.75)
        let bound = wetEff * max(1, stretch)
        let localR = max(0.10 * ppm, wet * 2.3)
        let localMax = 3
        let flux = Float(min(16.0, 5.0 * Double(k) / Double(d * d)) * Double(still) * dripGate)
        let g0x = max(0, Int((c.x - bound) / cellPx))
        let g1x = min(grid - 1, Int((c.x + bound) / cellPx))
        let g0y = max(0, Int((c.y - bound) / cellPx))
        let g1y = min(grid - 1, Int((c.y + bound) / cellPx))
        guard g0x <= g1x, g0y <= g1y else { return }
        let wet2 = wetEff * wetEff

        for gy in g0y...g1y {
            for gx in g0x...g1x {
                let cx = (CGFloat(gx) + 0.5) * cellPx, cy = (CGFloat(gy) + 0.5) * cellPx
                let dx = cx - c.x, dy = cy - c.y
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
                    let bonus = 1 + 0.3 * CGFloat(min(6, Int(dripCount[idx])))
                    let vol = min(2.4, (0.3 + CGFloat(Double(nv) - 1) * 1.6 + rnd() * 0.6) * bonus)
                    if nearCount > 0 {
                        if rnd() < 0.10, let ni = near {
                            let extra = vol * (0.005 + rnd() * 0.012) * ppm
                            drips[ni].budget = min(0.30 * ppm, drips[ni].budget + extra)
                            drips[ni].vol = min(3.0, drips[ni].vol + 0.10)
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
            pos: CGPoint(x: x + gaussRnd() * 0.003 * ppm, y: y),
            vol: vol,
            budget: vol * (0.012 + rnd() * 0.030) * ppm,
            width: max(2.0, (0.0012 + vol * 0.0011) * (0.75 + rnd() * 0.5) * ppm),
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
            let wob = sin(dr.travelled * 0.012 + dr.seed) * step * dr.wobble
            let nx = dr.pos.x + dripDir.dx * step + dripPerp.dx * wob
            let ny = dr.pos.y + dripDir.dy * step + dripPerp.dy * wob
            let w = dr.width * (0.35 + 0.65 * remain)

            canvas.strokeSeg(from: dr.pos, to: CGPoint(x: nx, y: ny), width: w, color: dr.color)

            dr.pos = CGPoint(x: nx, y: ny)
            dr.travelled += step
            let off = nx < 6 || ny < 6 || nx > sizePx - 6 || ny > sizePx - 6
            if dr.travelled >= dr.budget || off {
                if dr.endBlob, !off {
                    canvas.fillBlob(dr.pos.x, dr.pos.y,
                                    w * (0.6 + rnd() * 0.4), w * (0.9 + rnd() * 0.6), dr.color)
                }
                drips.remove(at: i)
            } else {
                drips[i] = dr
            }
        }
    }
}
