import SwiftUI
import ARKit
import SceneKit

/// ARKit view: detects vertical planes and glues a paintable canvas onto each.
/// No manual wall placement needed — paint lands on the detected surface, and
/// distance to the wall is measured in real metres by ARKit.
struct ARSprayView: UIViewRepresentable {
    let state: PaintState

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.delegate = context.coordinator
        view.session.delegate = context.coordinator
        view.automaticallyUpdatesLighting = true
        view.rendersContinuously = true
        context.coordinator.arView = view

        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.vertical]
        config.environmentTexturing = .none
        view.session.run(config)

        // scanning feedback: ARKit's own tracked feature points
        view.debugOptions = [.showFeaturePoints]

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
        private var sprayPrev: (UUID, CGPoint)?    // stroke continuity per surface
        private var viewCenter = CGPoint(x: UIScreen.main.bounds.midX,
                                         y: UIScreen.main.bounds.midY)

        init(state: PaintState) { self.state = state }

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
                // once scanning works, hide the debug dots for a clean view
                self.arView?.debugOptions = []
            }
        }

        func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
            guard let plane = anchor as? ARPlaneAnchor else { return }
            surfaces[plane.identifier]?.updateTransform(plane.transform)
        }

        func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
            if let plane = anchor as? ARPlaneAnchor {
                surfaces.removeValue(forKey: plane.identifier)
                DispatchQueue.main.async { self.state.wallCount = self.surfaces.count }
            }
        }

        // MARK: per-frame tick (render thread)

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            let dt = lastTime == 0 ? 1.0 / 60.0 : min(0.05, time - lastTime)
            lastTime = time

            // UI commands
            if state.clearRequested {
                state.clearRequested = false
                for s in surfaces.values { s.clear() }
                state.showToast("Wall cleared")
            }
            if state.toggleRecordRequested {
                state.toggleRecordRequested = false
                DispatchQueue.main.async { self.toggleRecording() }
            }

            guard let view = arView, let frame = view.session.currentFrame else { return }
            let camPos = frame.camera.transform.position

            // where is the crosshair pointing?
            var hit: (surface: PaintSurface, tex: CGPoint, dist: Double)?
            if let query = view.raycastQuery(from: viewCenter,
                                             allowing: .existingPlaneGeometry,
                                             alignment: .vertical),
               let result = view.session.raycast(query).first,
               let anchor = result.anchor as? ARPlaneAnchor,
               let surface = surfaces[anchor.identifier] {
                let world = result.worldTransform.position
                let dist = Double(simd_length(world - camPos))
                if let tex = surface.texturePoint(worldPoint: world) {
                    hit = (surface, tex, dist)
                }
            }

            let aimed = hit != nil
            if aimed != state.aimedAtWall {
                DispatchQueue.main.async { self.state.aimedAtWall = aimed }
            }

            // spray
            let spraying = state.spraying || VolumeSpray.shared.holding
            if spraying, let h = hit {
                let color = PaintState.colors[state.colorIndex].ui.cgColor
                let nozzle = PaintState.nozzles[state.nozzleIndex]
                var from = h.tex
                if let prev = sprayPrev, prev.0 == h.surface.id { from = prev.1 }
                h.surface.engine.sprayStroke(from: from, to: h.tex,
                                             distance: h.dist,
                                             coneDeg: nozzle.deg,
                                             color: color, dt: dt)
                sprayPrev = (h.surface.id, h.tex)
            } else {
                sprayPrev = nil
            }

            // drips + texture upload for dirty surfaces
            for s in surfaces.values {
                s.engine.stepDrips(dt: dt)
                s.uploadIfDirty()
            }
        }

        // MARK: recording

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
                recorder.start(view: view, state: state)
                state.isRecording = true
            }
        }
    }
}

// MARK: - PaintSurface: a canvas glued to one detected wall

/// A fixed 4 m × 4 m paint canvas centred on the plane anchor. Transparent
/// where unpainted, so only the paint is visible on the real wall.
final class PaintSurface {
    static let sizeMeters: CGFloat = 4.0
    static let texSize = 2048                       // 512 px per metre
    static var ppm: CGFloat { CGFloat(texSize) / sizeMeters }

    let id: UUID
    let node: SCNNode
    let engine: SprayEngine
    private let material: SCNMaterial
    private var anchorTransform: simd_float4x4

    func updateTransform(_ t: simd_float4x4) { anchorTransform = t }

    init(anchor: ARPlaneAnchor) {
        id = anchor.identifier
        anchorTransform = anchor.transform

        let geo = SCNPlane(width: PaintSurface.sizeMeters, height: PaintSurface.sizeMeters)
        material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = false
        material.transparencyMode = .aOne
        geo.materials = [material]

        node = SCNNode(geometry: geo)
        node.eulerAngles.x = -.pi / 2               // plane anchors lie in local XZ

        // real-world DOWN expressed on the wall texture, so drips are gravity-true
        let downLocal = anchor.transform.inverse * simd_float4(0, -1, 0, 0)
        let dir = CGVector(dx: CGFloat(downLocal.x), dy: CGFloat(downLocal.z))
        engine = SprayEngine(texSize: PaintSurface.texSize,
                             ppm: PaintSurface.ppm,
                             dripDirection: dir)
        uploadIfDirty(force: true)
    }

    /// anchor-local hit → texture pixel (nil if outside the 4 m canvas)
    func texturePoint(worldPoint: simd_float3) -> CGPoint? {
        let local = anchorTransform.inverse * simd_float4(worldPoint, 1)
        let half = Float(PaintSurface.sizeMeters / 2)
        guard abs(local.x) < half, abs(local.z) < half else { return nil }
        let ppm = Float(PaintSurface.ppm)
        return CGPoint(x: CGFloat((local.x + half) * ppm),
                       y: CGFloat((local.z + half) * ppm))
    }

    func uploadIfDirty(force: Bool = false) {
        guard force || engine.takeDirty() else { return }
        if let img = engine.makeImage() {
            material.diffuse.contents = img
        }
    }

    func clear() { engine.clear() }
}

// MARK: - small helpers

extension simd_float4x4 {
    var position: simd_float3 {
        simd_float3(columns.3.x, columns.3.y, columns.3.z)
    }
}

extension simd_float4 {
    init(_ v: simd_float3, _ w: Float) { self.init(v.x, v.y, v.z, w) }
}
