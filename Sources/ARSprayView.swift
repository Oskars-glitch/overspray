import SwiftUI
import ARKit
import SceneKit
import Metal
import AVFoundation

struct ARSprayView: UIViewRepresentable {
    let state: PaintState

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.delegate = context.coordinator
        view.session.delegate = context.coordinator
        view.automaticallyUpdatesLighting = false      // we drive lighting ourselves
        view.rendersContinuously = true
        context.coordinator.arView = view
        context.coordinator.setupLights()
        context.coordinator.runSession(reset: false)
        view.debugOptions = [.showFeaturePoints]

        SoundKit.shared.setup()
        VolumeSpray.shared.attach(to: view, state: state)
        UIApplication.shared.isIdleTimerDisabled = true
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    // MARK: - Coordinator

    final class Coordinator: NSObject, ARSCNViewDelegate, ARSessionDelegate {
        let state: PaintState
        weak var arView: ARSCNView?
        private var surfaces: [UUID: PaintSurface] = [:]
        private var recorder = Recorder()
        private var lastTime: TimeInterval = 0
        private var sprayPrev: (UUID, CGPoint)?
        private let device = MTLCreateSystemDefaultDevice()
        private let tileBudget = TileBudget()
        private var camLight: SCNLight?
        private var ambientLight: SCNLight?
        private var torchApplied = false
        private var wasSpraying = false
        private var viewCenter = CGPoint(x: UIScreen.main.bounds.midX,
                                         y: UIScreen.main.bounds.midY)

        init(state: PaintState) { self.state = state; super.init() }

        func runSession(reset: Bool) {
            guard let view = arView else { return }
            let config = ARWorldTrackingConfiguration()
            config.planeDetection = [.vertical]
            config.environmentTexturing = .none
            view.session.run(config, options: reset ? [.resetTracking, .removeExistingAnchors] : [])
            if state.torchOn {                        // session restarts can drop the torch
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.setTorch(true) }
            }
        }

        /// Base ambient (subtle 5–10% response to real room light) is created
        /// once; the camera spotlight powers the flashlight look on the paint.
        func setupLights() {
            guard let view = arView else { return }
            let amb = SCNLight()
            amb.type = .ambient
            amb.intensity = 1000
            amb.color = UIColor.white
            let ambNode = SCNNode()
            ambNode.light = amb
            view.scene.rootNode.addChildNode(ambNode)
            ambientLight = amb
        }

        // MARK: plane lifecycle

        func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
            guard let plane = anchor as? ARPlaneAnchor, plane.alignment == .vertical else { return }
            let surface = PaintSurface(anchor: plane)
            surfaces[plane.identifier] = surface
            node.addChildNode(surface.node)
            DispatchQueue.main.async {
                self.state.wallCount = self.surfaces.count
                if self.surfaces.count == 1 {
                    self.state.status = "Wall found — hold the cap to spray"
                    self.state.showToast("Wall detected · paint sticks to it automatically")
                }
                self.arView?.debugOptions = []
            }
        }

        func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
            guard let plane = anchor as? ARPlaneAnchor else { return }
            surfaces[plane.identifier]?.updateTransform(plane.transform)
        }

        func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
            if let plane = anchor as? ARPlaneAnchor {
                surfaces[plane.identifier]?.teardown()
                surfaces.removeValue(forKey: plane.identifier)
                DispatchQueue.main.async { self.state.wallCount = self.surfaces.count }
            }
        }

        // MARK: per-frame tick (render thread)

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            let dt = lastTime == 0 ? 1.0 / 60.0 : min(0.05, time - lastTime)
            lastTime = time

            if state.clearRequested {
                state.clearRequested = false
                for s in surfaces.values { s.engine?.clear() }
                state.showToast("Wall cleared")
            }
            if state.toggleRecordRequested {
                state.toggleRecordRequested = false
                DispatchQueue.main.async { self.toggleRecording() }
            }
            if state.rescanRequested {
                state.rescanRequested = false
                DispatchQueue.main.async { self.rescan() }
            }
            syncTorchAndLight()

            guard let view = arView, let frame = view.session.currentFrame else { return }

            // barely-there room-light response (≈ ±2%)
            if let est = frame.lightEstimate {
                let e = min(2000, max(200, est.ambientIntensity))
                let target = 985 + 0.02 * e
                if let amb = ambientLight {
                    amb.intensity += (target - amb.intensity) * 0.05
                }
            }

            let camPos = frame.camera.transform.position

            var hit: (surface: PaintSurface, tex: CGPoint, dist: Double,
                      stretch: CGFloat, sdir: CGVector)?
            if let query = view.raycastQuery(from: viewCenter,
                                             allowing: .existingPlaneGeometry,
                                             alignment: .vertical),
               let result = view.session.raycast(query).first,
               let anchor = result.anchor as? ARPlaneAnchor,
               let surface = surfaces[anchor.identifier] {
                let world = result.worldTransform.position
                let delta = world - camPos
                let dist = Double(simd_length(delta))
                if dist > 0.02, let tex = surface.texturePoint(worldPoint: world) {
                    let (stretch, sdir) = surface.obliqueness(rayDir: delta / Float(dist))
                    hit = (surface, tex, dist, stretch, sdir)
                }
            }

            let aimed = hit != nil
            if aimed != state.aimedAtWall {
                DispatchQueue.main.async { self.state.aimedAtWall = aimed }
            }

            let spraying = state.spraying || VolumeSpray.shared.holding
            if spraying != wasSpraying {
                wasSpraying = spraying
                DispatchQueue.main.async { SoundKit.shared.setSpraying(spraying) }
            }

            if spraying, let h = hit {
                if let engine = ensureEngine(h.surface) {
                    let color = PaintState.colors[state.colorIndex].ui.cgColor
                    let nozzle = PaintState.nozzles[state.nozzleIndex]
                    var from = h.tex
                    if let prev = sprayPrev, prev.0 == h.surface.id { from = prev.1 }
                    engine.sprayStroke(from: from, to: h.tex,
                                       distance: h.dist, coneDeg: nozzle.deg,
                                       color: color, dt: dt,
                                       stretch: h.stretch, stretchDir: h.sdir)
                    sprayPrev = (h.surface.id, h.tex)
                }
            } else {
                sprayPrev = nil
            }

            for s in surfaces.values {
                s.engine?.stepDrips(dt: dt)
                s.engine?.flush()
            }
        }

        private func ensureEngine(_ surface: PaintSurface) -> SprayEngine? {
            if let e = surface.engine { return e }
            guard let device = device else { return nil }
            surface.allocateEngine(device: device, budget: tileBudget) { [weak self] in
                self?.state.showToast("Paint area limit reached — Clear or Rescan")
            }
            return surface.engine
        }

        // MARK: flashlight + wet reflection

        private func syncTorchAndLight() {
            if camLight == nil, let pov = arView?.pointOfView {
                let l = SCNLight()
                l.type = .spot
                l.spotInnerAngle = 30
                l.spotOuterAngle = 70
                l.attenuationStartDistance = 0.1
                l.attenuationEndDistance = 5
                l.castsShadow = false
                l.intensity = 0
                let n = SCNNode()
                n.light = l
                pov.addChildNode(n)
                camLight = l
            }
            camLight?.intensity = state.torchOn ? 1200 : 0

            if state.torchOn != torchApplied {
                torchApplied = state.torchOn
                let on = state.torchOn
                DispatchQueue.main.async { self.setTorch(on) }
            }
        }

        private func setTorch(_ on: Bool) {
            guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else {
                if on { state.showToast("No flashlight on this device") }
                return
            }
            do {
                try device.lockForConfiguration()
                device.torchMode = on ? .on : .off
                device.unlockForConfiguration()
            } catch {
                if on { state.showToast("Flashlight unavailable right now") }
            }
        }

        // MARK: rescan

        private func rescan() {
            for s in surfaces.values { s.teardown(); s.node.removeFromParentNode() }
            surfaces.removeAll()
            tileBudget.warned = false
            sprayPrev = nil
            runSession(reset: true)
            arView?.debugOptions = [.showFeaturePoints]
            state.wallCount = 0
            state.status = "Move your phone slowly to scan for walls"
            state.showToast("Rescanning…")
        }

        // MARK: recording (mic runs on its own session — AR camera untouched)

        private func toggleRecording() {
            guard let view = arView else { return }
            if recorder.isRecording {
                recorder.stop { url in
                    DispatchQueue.main.async {
                        self.state.isRecording = false
                        if url != nil { self.state.showToast("Saved to Photos") }
                        else { self.state.showToast("Recording failed to save") }
                    }
                }
            } else {
                recorder.start(view: view, state: state) { started in
                    self.state.isRecording = started
                }
            }
        }
    }
}

// MARK: - PaintSurface: one detected wall

/// 3 m × 3 m surface whose paint lives in lazy 0.5 m tiles (4096 px/m).
final class PaintSurface {
    static let sizeMeters: CGFloat = 3.0

    let id: UUID
    let node: SCNNode                      // paint root, rotated into the wall
    private(set) var engine: SprayEngine?
    private var canvas: PaintCanvas?
    private var anchorTransform: simd_float4x4
    private let dripDirLocal: CGVector

    init(anchor: ARPlaneAnchor) {
        id = anchor.identifier
        anchorTransform = anchor.transform
        node = SCNNode()
        node.eulerAngles.x = -.pi / 2

        let downLocal = anchor.transform.inverse * simd_float4(0, -1, 0, 0)
        dripDirLocal = CGVector(dx: CGFloat(downLocal.x), dy: CGFloat(downLocal.z))
    }

    func updateTransform(_ t: simd_float4x4) { anchorTransform = t }

    func allocateEngine(device: MTLDevice, budget: TileBudget, onBudgetExceeded: @escaping () -> Void) {
        guard engine == nil else { return }
        let c = PaintCanvas(surfaceMeters: PaintSurface.sizeMeters,
                            device: device, budget: budget, parent: node)
        c.onBudgetExceeded = onBudgetExceeded
        canvas = c
        engine = SprayEngine(canvas: c, dripDirection: dripDirLocal)
    }

    func teardown() {
        canvas?.teardown()
        canvas = nil
        engine = nil
    }

    /// anchor-local hit → surface pixel (nil if outside the canvas)
    func texturePoint(worldPoint: simd_float3) -> CGPoint? {
        let local = anchorTransform.inverse * vec4(worldPoint, 1)
        let half = Float(PaintSurface.sizeMeters / 2)
        guard abs(local.x) < half, abs(local.z) < half else { return nil }
        let ppm = Float(PaintCanvas.ppm)
        return CGPoint(x: CGFloat((local.x + half) * ppm),
                       y: CGFloat((local.z + half) * ppm))
    }

    /// How obliquely the spray hits: (elongation factor, direction on texture)
    func obliqueness(rayDir: simd_float3) -> (CGFloat, CGVector) {
        let col = anchorTransform.columns.1
        let n = simd_normalize(simd_float3(col.x, col.y, col.z))
        let c = Double(abs(simd_dot(rayDir, n)))
        let stretch = CGFloat(min(3.0, 1.0 / max(0.34, c)))
        var t = rayDir - n * simd_dot(rayDir, n)
        let len = simd_length(t)
        var dir = CGVector(dx: 0, dy: 1)
        if len > 1e-4 {
            t /= len
            let local = anchorTransform.inverse * vec4(t, 0)
            let l = hypot(CGFloat(local.x), CGFloat(local.z))
            if l > 1e-4 {
                dir = CGVector(dx: CGFloat(local.x) / l, dy: CGFloat(local.z) / l)
            }
        }
        return (stretch, dir)
    }
}

// MARK: - small helpers

extension simd_float4x4 {
    var position: simd_float3 {
        simd_float3(columns.3.x, columns.3.y, columns.3.z)
    }
}

@inline(__always) func vec4(_ v: simd_float3, _ w: Float) -> simd_float4 {
    simd_float4(v.x, v.y, v.z, w)
}
