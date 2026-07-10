import SwiftUI
import UIKit
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
        private var lastPatchSpawn: TimeInterval = 0
        private var patchToastShown = false
        private var editingSurface: PaintSurface?
        private var grabbedVertex: Int?
        private var lastHitSurfaceID: UUID?
        private var lastAudible = true
        private let viewSize = UIScreen.main.bounds.size
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
            var surface: PaintSurface?
            if let plane = anchor as? ARPlaneAnchor, plane.alignment == .vertical {
                surface = PaintSurface(id: plane.identifier, transform: plane.transform)
            } else if anchor.name == "patch" {
                // freestyle patch: planted where you sprayed on an ESTIMATED
                // surface (uneven facades ARKit couldn't turn into a plane)
                surface = PaintSurface(id: anchor.identifier, transform: anchor.transform)
            }
            guard let surface = surface else { return }
            surfaces[surface.id] = surface
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
            surfaces[plane.identifier]?.captureBoundary(plane)
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
            if state.editToggleRequested {
                state.editToggleRequested = false
                toggleEditing()
            }
            if state.exportRequested {
                state.exportRequested = false
                DispatchQueue.main.async { self.exportPNG() }
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

            let camTransform = frame.camera.transform
            let camPos = camTransform.position
            let camFwd = -simd_normalize(simd_float3(camTransform.columns.2.x,
                                                     camTransform.columns.2.y,
                                                     camTransform.columns.2.z))
            let camRight = simd_normalize(simd_float3(camTransform.columns.0.x,
                                                      camTransform.columns.0.y,
                                                      camTransform.columns.0.z))

            var hit: (surface: PaintSurface, tex: CGPoint, dist: Double,
                      stretch: CGFloat, sdir: CGVector, roll: CGVector)?

            // ONLY a real detected plane counts — tight, consistent, glued to
            // the wall. One correct wall, exactly like the reliable behaviour.
            if let query = view.raycastQuery(from: viewCenter,
                                             allowing: .existingPlaneGeometry,
                                             alignment: .vertical),
               let result = view.session.raycast(query).first,
               let anchor = result.anchor as? ARPlaneAnchor,
               let surface = surfaces[anchor.identifier] {
                let world = result.worldTransform.position
                let dist = Double(simd_length(world - camPos))
                if dist > 0.02, let tex = surface.texturePoint(worldPoint: world) {
                    let (stretch, sdir) = surface.obliqueness(rayDir: camFwd)
                    hit = (surface, tex, dist, stretch, sdir,
                           surface.rollDirection(cameraRight: camRight))
                }
            }

            lastHitSurfaceID = hit?.surface.id
            let aimed = hit != nil
            if aimed != state.aimedAtWall {
                DispatchQueue.main.async { self.state.aimedAtWall = aimed }
            }

            let spraying = (state.spraying || VolumeSpray.shared.holding) && !state.editingPlane
            let cap = PaintState.nozzles[state.nozzleIndex]
            let shape = cap.custom ? state.customShape : []
            let capReady = !(cap.custom && shape.count < 2)
            CanPhysics.shared.tick(spraying: spraying && hit != nil, dt: dt)
            handleEditTouch(renderer: renderer)
            if spraying != wasSpraying {
                wasSpraying = spraying
                if spraying {
                    CanPhysics.shared.dashReset()
                    if !capReady { state.showToast("Draw your cap first — tap the blank cap again") }
                }
                DispatchQueue.main.async { SoundKit.shared.setSpraying(spraying) }
            }

            if spraying, capReady, let h = hit, h.surface.contains(h.tex) {
                if let engine = ensureEngine(h.surface) {
                    let color = state.colors[state.colorIndex].cgColor
                    let boost: CGFloat = [1, 5, 10][state.pressureBoost]
                    var from = h.tex
                    if let prev = sprayPrev, prev.0 == h.surface.id { from = prev.1 }
                    engine.sprayStroke(from: from, to: h.tex,
                                       distance: h.dist, cap: cap,
                                       color: color, dt: dt,
                                       stretch: h.stretch, stretchDir: h.sdir,
                                       rollDir: h.roll,
                                       boost: boost, dashMode: state.dashMode,
                                       shape: shape)
                    sprayPrev = (h.surface.id, h.tex)
                }
                // dotted-line attachment: spray audio only on painted segments
                let audible = state.dashMode == 0 || CanPhysics.shared.dashOn
                if audible != lastAudible {
                    lastAudible = audible
                    DispatchQueue.main.async { SoundKit.shared.setSprayMuted(!audible) }
                }
            } else {
                if !lastAudible {
                    lastAudible = true
                    DispatchQueue.main.async { SoundKit.shared.setSprayMuted(false) }
                }
                sprayPrev = nil
            }

            // live color picking: long-press a swatch, drag over the camera view
            if state.pickingColorIndex != nil {
                let ui = sampleCameraColor(frame: frame, at: state.pickPoint)
                if let ui = ui {
                    DispatchQueue.main.async { self.state.pickPreview = ui }
                }
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

        // MARK: plane editing — drag dots, tap to add one (away from others)

        private func toggleEditing() {
            if let s = editingSurface {
                s.hideEditor()
                editingSurface = nil
                grabbedVertex = nil
                DispatchQueue.main.async { self.state.editingPlane = false }
                return
            }
            guard let id = lastHitSurfaceID, let s = surfaces[id] else {
                state.showToast("Aim at a wall first, then edit its shape")
                DispatchQueue.main.async { self.state.editingPlane = false }
                return
            }
            if s.polygon.count < 3 {
                if s.detectedBoundary.count >= 3 {
                    s.polygon = s.detectedBoundary        // start from the SCANNED shape
                } else {
                    // freestyle patch: start from a simple centred square
                    let c = PaintSurface.sizeMeters * PaintCanvas.ppm / 2
                    let half = PaintCanvas.ppm * 0.7
                    s.polygon = [CGPoint(x: c - half, y: c - half),
                                 CGPoint(x: c + half, y: c - half),
                                 CGPoint(x: c + half, y: c + half),
                                 CGPoint(x: c - half, y: c + half)]
                }
            }
            s.rebuildEditor()
            editingSurface = s
            DispatchQueue.main.async { self.state.editingPlane = true }
            state.showToast("Drag dots to reshape · tap empty spot to add a dot")
        }

        private func handleEditTouch(renderer: SCNSceneRenderer) {
            guard let s = editingSurface, let touch = state.editTouch else { return }
            state.editTouch = nil
            guard let view = arView,
                  let world = view.unprojectPoint(touch.point, ontoPlane: s.anchorTransform),
                  let tex = texClamped(s, world: world) else {
                if touch.phase == 3 { grabbedVertex = nil }
                return
            }
            switch touch.phase {
            case 1:
                // nearest vertex on SCREEN: <34 pt grabs · 34–60 dead zone · >60 adds
                var best = -1
                var bestD = CGFloat.greatestFiniteMagnitude
                for (i, p) in s.polygon.enumerated() {
                    let w = s.worldPoint(tex: p)
                    let pr = renderer.projectPoint(SCNVector3(w.x, w.y, w.z))
                    let dd = hypot(CGFloat(pr.x) - touch.point.x, CGFloat(pr.y) - touch.point.y)
                    if dd < bestD { bestD = dd; best = i }
                }
                if bestD < 34 {
                    grabbedVertex = best
                } else if bestD > 60 {
                    grabbedVertex = insertVertex(into: s, at: tex)
                    s.rebuildEditor()
                }
            case 2:
                if let g = grabbedVertex, g < s.polygon.count {
                    s.polygon[g] = tex
                    s.rebuildEditor()
                }
            default:
                grabbedVertex = nil
            }
        }

        private func texClamped(_ s: PaintSurface, world: simd_float3) -> CGPoint? {
            guard var t = s.texturePoint(worldPoint: world) else { return nil }
            let m = CGFloat(20)
            let size = PaintSurface.sizeMeters * PaintCanvas.ppm
            t.x = min(max(t.x, m), size - m)
            t.y = min(max(t.y, m), size - m)
            return t
        }

        /// insert a new vertex into the edge closest to the tapped point
        private func insertVertex(into s: PaintSurface, at p: CGPoint) -> Int {
            guard s.polygon.count >= 3 else { s.polygon.append(p); return s.polygon.count - 1 }
            var bestEdge = 0
            var bestD = CGFloat.greatestFiniteMagnitude
            for i in 0..<s.polygon.count {
                let a = s.polygon[i], b = s.polygon[(i + 1) % s.polygon.count]
                let abx = b.x - a.x, aby = b.y - a.y
                let len2 = max(1, abx * abx + aby * aby)
                let t = min(1, max(0, ((p.x - a.x) * abx + (p.y - a.y) * aby) / len2))
                let qx = a.x + abx * t, qy = a.y + aby * t
                let dd = hypot(p.x - qx, p.y - qy)
                if dd < bestD { bestD = dd; bestEdge = i }
            }
            s.polygon.insert(p, at: bestEdge + 1)
            return bestEdge + 1
        }

        // MARK: PNG export — full resolution, transparent background

        private func exportPNG() {
            var surface: PaintSurface?
            if let id = lastHitSurfaceID { surface = surfaces[id] }
            if surface?.engine == nil {
                surface = surfaces.values.first(where: { $0.engine != nil })
            }
            guard let s = surface, let canvas = s.exportCanvas() else {
                state.showToast("Nothing painted yet")
                return
            }
            state.showToast("Preparing PNG…")
            DispatchQueue.global(qos: .userInitiated).async {
                guard let cg = canvas.exportImage(),
                      let data = UIImage(cgImage: cg).pngData() else {
                    self.state.showToast("Export failed")
                    return
                }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("overspray-art-\(Int(Date().timeIntervalSince1970)).png")
                do { try data.write(to: url) } catch {
                    self.state.showToast("Export failed")
                    return
                }
                DispatchQueue.main.async {
                    let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                    UIApplication.shared.connectedScenes
                        .compactMap { $0 as? UIWindowScene }
                        .first?.keyWindow?.rootViewController?
                        .present(sheet, animated: true)
                }
            }
        }

        // MARK: camera color sampling (for the long-press eyedropper)

        private func sampleCameraColor(frame: ARFrame, at pt: CGPoint) -> UIColor? {
            let buf = frame.capturedImage
            guard CVPixelBufferGetPlaneCount(buf) >= 2 else { return nil }
            let inv = frame.displayTransform(for: .portrait, viewportSize: viewSize).inverted()
            var norm = CGPoint(x: pt.x / viewSize.width, y: pt.y / viewSize.height).applying(inv)
            norm.x = min(1, max(0, norm.x)); norm.y = min(1, max(0, norm.y))
            CVPixelBufferLockBaseAddress(buf, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
            let w = CVPixelBufferGetWidthOfPlane(buf, 0), h = CVPixelBufferGetHeightOfPlane(buf, 0)
            let px = min(w - 1, Int(norm.x * CGFloat(w))), py = min(h - 1, Int(norm.y * CGFloat(h)))
            guard let base0 = CVPixelBufferGetBaseAddressOfPlane(buf, 0),
                  let base1 = CVPixelBufferGetBaseAddressOfPlane(buf, 1) else { return nil }
            let rb0 = CVPixelBufferGetBytesPerRowOfPlane(buf, 0)
            let rb1 = CVPixelBufferGetBytesPerRowOfPlane(buf, 1)
            let yv = Double(base0.assumingMemoryBound(to: UInt8.self)[py * rb0 + px])
            let cIdx = (py / 2) * rb1 + (px / 2) * 2
            let cb = Double(base1.assumingMemoryBound(to: UInt8.self)[cIdx])
            let cr = Double(base1.assumingMemoryBound(to: UInt8.self)[cIdx + 1])
            let yy = (yv - 16) * 1.164
            let r = max(0, min(255, yy + 1.793 * (cr - 128)))
            let g = max(0, min(255, yy - 0.213 * (cb - 128) - 0.533 * (cr - 128)))
            let b = max(0, min(255, yy + 2.112 * (cb - 128)))
            return UIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1)
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
    private(set) var anchorTransform: simd_float4x4
    private let dripDirLocal: CGVector

    init(id: UUID, transform: simd_float4x4) {
        self.id = id
        anchorTransform = transform
        node = SCNNode()
        node.eulerAngles.x = -.pi / 2

        let downLocal = transform.inverse * simd_float4(0, -1, 0, 0)
        dripDirLocal = CGVector(dx: CGFloat(downLocal.x), dy: CGFloat(downLocal.z))
    }

    /// Intersect a world-space ray with this surface's plane (nil if it misses
    /// the plane or lands outside the 3 m canvas).
    func rayHit(origin: simd_float3, dir: simd_float3) -> Float? {
        let col = anchorTransform.columns.1
        let n = simd_normalize(simd_float3(col.x, col.y, col.z))
        let denom = simd_dot(dir, n)
        guard abs(denom) > 1e-4 else { return nil }
        let p0 = anchorTransform.position
        let t = simd_dot(p0 - origin, n) / denom
        guard t > 0.02 else { return nil }
        guard texturePoint(worldPoint: origin + dir * t) != nil else { return nil }
        return t
    }

    /// The camera's right-axis projected onto the wall — the CHISEL cap's
    /// line direction, so rotating the phone visibly rotates the stroke.
    func rollDirection(cameraRight: simd_float3) -> CGVector {
        let col = anchorTransform.columns.1
        let n = simd_normalize(simd_float3(col.x, col.y, col.z))
        var t = cameraRight - n * simd_dot(cameraRight, n)
        let len = simd_length(t)
        guard len > 1e-4 else { return CGVector(dx: 1, dy: 0) }
        t /= len
        let local = anchorTransform.inverse * vec4(t, 0)
        let l = hypot(CGFloat(local.x), CGFloat(local.z))
        guard l > 1e-4 else { return CGVector(dx: 1, dy: 0) }
        return CGVector(dx: CGFloat(local.x) / l, dy: CGFloat(local.z) / l)
    }

    func updateTransform(_ t: simd_float4x4) { anchorTransform = t }

    // MARK: editable paint boundary (polygon in surface-px)

    var polygon: [CGPoint] = []                 // empty = whole canvas paintable
    var detectedBoundary: [CGPoint] = []        // from ARKit's scanned plane shape
    private var editorNode: SCNNode?

    func captureBoundary(_ plane: ARPlaneAnchor) {
        let verts = plane.geometry.boundaryVertices
        guard verts.count >= 3 else { return }
        let stride = max(1, verts.count / 10)
        let half = Float(PaintSurface.sizeMeters / 2)
        let ppm = CGFloat(PaintCanvas.ppm)
        var pts: [CGPoint] = []
        var i = 0
        while i < verts.count {
            let v = verts[i]
            let x = min(max(v.x, -half + 0.02), half - 0.02)
            let z = min(max(v.z, -half + 0.02), half - 0.02)
            pts.append(CGPoint(x: CGFloat(x + half) * ppm / 1,
                               y: CGFloat(z + half) * ppm / 1))
            i += stride
        }
        if pts.count >= 3 { detectedBoundary = pts }
    }

    func contains(_ p: CGPoint) -> Bool {
        guard polygon.count >= 3 else { return true }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y),
               p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// surface-px → world position on the plane
    func worldPoint(tex: CGPoint) -> simd_float3 {
        let half = Float(PaintSurface.sizeMeters / 2)
        let ppm = Float(PaintCanvas.ppm)
        let lx = Float(tex.x) / ppm - half
        let lz = Float(tex.y) / ppm - half
        let w = anchorTransform * simd_float4(lx, 0, lz, 1)
        return simd_float3(w.x, w.y, w.z)
    }

    private func localXY(_ p: CGPoint) -> CGPoint {
        let half = PaintSurface.sizeMeters / 2
        let ppm = PaintCanvas.ppm
        return CGPoint(x: p.x / ppm - half, y: half - p.y / ppm)
    }

    func rebuildEditor() {
        editorNode?.removeFromParentNode()
        editorNode = nil
        guard polygon.count >= 3 else { return }
        let root = SCNNode()
        // translucent pane matching the polygon shape
        let path = UIBezierPath()
        for (i, p) in polygon.enumerated() {
            let l = localXY(p)
            if i == 0 { path.move(to: l) } else { path.addLine(to: l) }
        }
        path.close()
        let shape = SCNShape(path: path, extrusionDepth: 0)
        let m = SCNMaterial()
        m.diffuse.contents = UIColor(red: 0.35, green: 1.0, blue: 0.45, alpha: 0.14)
        m.lightingModel = .constant
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        shape.materials = [m]
        let shapeNode = SCNNode(geometry: shape)
        shapeNode.position.z = 0.002
        root.addChildNode(shapeNode)
        // draggable vertex dots
        for p in polygon {
            let s = SCNSphere(radius: 0.016)
            let dm = SCNMaterial()
            dm.diffuse.contents = UIColor.white
            dm.emission.contents = UIColor.orange
            dm.lightingModel = .constant
            s.materials = [dm]
            let n = SCNNode(geometry: s)
            let l = localXY(p)
            n.position = SCNVector3(Float(l.x), Float(l.y), 0.004)
            root.addChildNode(n)
        }
        node.addChildNode(root)
        editorNode = root
    }

    func hideEditor() {
        editorNode?.removeFromParentNode()
        editorNode = nil
    }

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

    func exportCanvas() -> PaintCanvas? { canvas }

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
