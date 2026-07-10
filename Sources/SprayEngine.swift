import UIKit
import CoreGraphics

/// The can itself: output pressure drops the longer you spray (paint gets
/// lighter) and shaking restores it. Shakes also build CHARGE, which throws
/// big splashy droplets at the beginning of the next spray — more shakes,
/// more splashes.
final class CanPhysics {
    static let shared = CanPhysics()
    private(set) var pressure: Double = 1.0
    private(set) var charge: Double = 0

    func tick(spraying: Bool, dt: Double) {
        if spraying {
            pressure = max(0.45, pressure - dt * 0.05)   // noticeably lighter after ~10 s
            charge = max(0, charge - dt * 0.9)           // splashes fade over ~2 s of spraying
        } else {
            pressure = min(1.0, pressure + dt * 0.008)   // barely recovers on its own
        }
    }

    func shaken(strong: Bool) {
        pressure = min(1.0, pressure + (strong ? 0.16 : 0.07))
        charge = min(3.0, charge + (strong ? 0.8 : 0.35))
    }
}

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
                     cap: SprayCap, color: CGColor, dt: Double,
                     stretch: CGFloat, stretchDir: CGVector, rollDir: CGVector) {
        let d = max(0.10, distance)
        let k = CGFloat(pow(4.5 / cap.deg, 0.5))
        let radius = max(8.0, tan(cap.deg * .pi / 180) * d * Double(ppm))
        let pathLen = hypot(to.x - from.x, to.y - from.y)
        let speedM = Double(pathLen / ppm) / max(dt, 0.001)
        let still = pow(max(0.0, 1.0 - speedM / 0.30), 1.5)
        let stamps = max(1, min(28, Int(ceil(Double(pathLen) / max(4.0, radius * 0.22)))))
        let pressure = CGFloat(0.5 + 0.5 * CanPhysics.shared.pressure)
        let charge = CGFloat(CanPhysics.shared.charge)
        for s in 1...stamps {
            let f = CGFloat(s) / CGFloat(stamps)
            let p = CGPoint(x: from.x + (to.x - from.x) * f,
                            y: from.y + (to.y - from.y) * f)
            stamp(at: p, d: CGFloat(d), k: k, R: CGFloat(radius), color: color,
                  dtShare: dt / Double(stamps), still: CGFloat(still),
                  stretch: stretch, sd: stretchDir, roll: rollDir,
                  budgetShare: max(1, stamps), cap: cap,
                  pressure: pressure, charge: charge)
        }
    }

    private func stamp(at c: CGPoint, d: CGFloat, k: CGFloat, R: CGFloat,
                       color: CGColor, dtShare: Double, still: CGFloat,
                       stretch: CGFloat, sd: CGVector, roll: CGVector,
                       budgetShare: Int, cap: SprayCap,
                       pressure: CGFloat, charge: CGFloat) {
        @inline(__always) func place(_ ox: CGFloat, _ oy: CGFloat) -> CGPoint {
            CGPoint(x: c.x + sd.dx * ox * stretch - sd.dy * oy,
                    y: c.y + sd.dy * ox * stretch + sd.dx * oy)
        }
        // an offset in plain texture space, run through the oblique stretch
        @inline(__always) func placeWorld(_ offx: CGFloat, _ offy: CGFloat) -> CGPoint {
            place(offx * sd.dx + offy * sd.dy, -offx * sd.dy + offy * sd.dx)
        }

        // OPAQUE dot field: density carries the look, never transparency.
        let close = min(1, max(0, (0.85 - d) / 0.85))
        let sigma = R * (0.30 + 0.50 * (1 - close)) * cap.scatterScale
        // fine caps (pink dot) fade toward invisibility with distance instead
        // of staying razor-sharp: fewer dots land the farther you are
        let fineFade = cap.dotScale < 0.3 ? pow(close, 0.7) : 1.0
        var count = Int((60 + 240 * close) * k * 5 * cap.countScale * fineFade * pressure)
        count = min(count, max(80, 5500 / budgetShare))  // frame budget on fast sweeps
        let mm = ppm / 1000

        for _ in 0..<count {
            let p: CGPoint
            if cap.chisel {
                // flat line footprint, rotating with the phone (roll axis)
                let u = gaussRnd() * R
                let v = gaussRnd() * R * 0.14
                p = placeWorld(roll.dx * u - roll.dy * v, roll.dy * u + roll.dx * v)
            } else if cap.holeFrac > 0 {
                // ring with a clean hole in the middle (cyclops)
                let rr = R * (cap.holeFrac + (1 - cap.holeFrac) * sqrt(rnd()))
                let a = rnd() * .pi * 2
                p = placeWorld(cos(a) * rr + gaussRnd() * R * 0.04,
                               sin(a) * rr + gaussRnd() * R * 0.04)
            } else if cap.dotScale < 0.3 {
                // pink dot: tight core BUT ~22% of droplets stray into a soft
                // halo so the line has organic scatter, never a hard contour
                if rnd() < 0.22 {
                    p = place(gaussRnd() * sigma * 2.6, gaussRnd() * sigma * 2.6)
                } else {
                    p = place(gaussRnd() * sigma, gaussRnd() * sigma)
                }
            } else {
                p = place(gaussRnd() * sigma, gaussRnd() * sigma)
            }
            let r = (0.10 + rnd() * rnd() * 0.45) * (1 + d * 0.5) * mm * cap.dotScale
            canvas.fillDot(p.x, p.y, max(0.9, r), color)
        }
        // stray splatter only from a distance, and only from loose caps
        if d > 0.35, cap.scatterScale > 0.35 {
            let spl = Int((3 * d * Double(cap.scatterScale)).rounded())
            for _ in 0..<spl {
                let a = rnd() * .pi * 2, rr = R * (1.15 + rnd() * 1.4)
                let p = placeWorld(cos(a) * rr, sin(a) * rr)
                canvas.fillDot(p.x, p.y,
                               max(0.9, (0.15 + rnd() * 0.4) * mm * (1 + d * 0.5) * cap.dotScale), color)
            }
        }
        // occasional fat spit
        if !cap.chisel, d > 0.3, rnd() < 0.06 * Double(cap.scatterScale) {
            let p = place(gaussRnd() * R * 0.8, gaussRnd() * R * 0.8)
            canvas.fillDot(p.x, p.y, (0.5 + rnd() * 0.9) * mm * 2, color)
        }

        // freshly shaken can: big splashy droplets at the start of the spray
        if charge > 0.05, rnd() < 0.12 * charge {
            let p = place(gaussRnd() * sigma * 0.9, gaussRnd() * sigma * 0.9)
            canvas.fillDot(p.x, p.y, (1.5 + rnd() * 3.0) * mm * (1 + 0.5 * charge), color)
        }

        accumulate(at: c, d: d, k: k, R: R, color: color,
                   dtShare: dtShare, still: still, stretch: stretch, sd: sd, cap: cap)
    }

    // MARK: accumulation → drips

    private func accumulate(at c: CGPoint, d: CGFloat, k: CGFloat, R: CGFloat,
                            color: CGColor, dtShare: Double, still: CGFloat,
                            stretch: CGFloat, sd: CGVector, cap: SprayCap) {
        guard still > 0.01 else { return }
        // per-cap drip rules: each cap has its own maximum drip distance
        // (0 = that cap never drips, e.g. cyclops)
        guard cap.dripMaxM > 0 else { return }
        let dripGate = pow(min(1.0, max(0.0, (cap.dripMaxM - Double(d)) / cap.dripMaxM)), 1.8)
        guard dripGate > 0.02 else { return }
        let wet = cap.chisel ? R * 0.30 : R * 0.62
        let wetEff = max(wet, cellPx * 0.75)
        let bound = wetEff * max(1, stretch)
        let localR = max(0.10 * ppm, wet * 2.3)
        let localMax = 2
        let flux = Float(min(16.0, 5.0 * Double(k) / Double(d * d)) * Double(still) * dripGate * 0.5)
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
                            drips[ni].budget = min(0.18 * ppm, drips[ni].budget + extra)
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
            budget: vol * (0.008 + rnd() * 0.020) * ppm,
            width: max(2.0, (0.0012 + vol * 0.0011) * (0.75 + rnd() * 0.5) * ppm),
            wobble: 0.008 + rnd() * 0.045,
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
