import SwiftUI
import UIKit
import ARKit
import SceneKit
import Metal
import AVFoundation
import CoreImage
import QuartzCore

/// ONE user-designated wall. ARKit's plane detection only helps you AIM;
/// tapping SET WALL freezes that plane as yours. Painting raycasts against
/// the infinite plane directly — no fragmenting, no strobing, no phantom
/// walls, and the paintable area (lasso-editable mask) can grow as large as
/// the 12 m canvas.
struct ARSprayView: UIViewRepresentable {
    let state: PaintState

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.delegate = context.coordinator
        view.session.delegate = context.coordinator
        view.automaticallyUpdatesLighting = false
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
        private var wall: PaintSurface?
        private var recorder = Recorder()
        private var lastTime: TimeInterval = 0
        private var sprayPrev: CGPoint?
        private let device = MTLCreateSystemDefaultDevice()
        private let tileBudget = TileBudget()
        private var camLight: SCNLight?
        private var ambientLight: SCNLight?
        private var torchApplied = false
        private var wasSpraying = false
        private var lastAudible = true
        private var planeSeen = false
        // lasso editing
        private var lassoStroke: [CGPoint] = []      // texture px
        // point-based wall setting
        private var setPoints: [simd_float3] = []
        private var setPointNodes: [SCNNode] = []
        private var firstHitTransform: simd_float4x4?
        private var lastNudge: Double = 0
        private var motionBlurSet = false
        private var viewCenter = CGPoint(x: UIScreen.main.bounds.midX,
                                         y: UIScreen.main.bounds.midY)
        private let viewSize = UIScreen.main.bounds.size

        init(state: PaintState) { self.state = state; super.init() }

        func runSession(reset: Bool) {
            guard let view = arView else { return }
            let config = ARWorldTrackingConfiguration()
            config.planeDetection = [.vertical]
            config.environmentTexturing = .none
            view.session.run(config, options: reset ? [.resetTracking, .removeExistingAnchors] : [])
            if state.torchOn {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.setTorch(true) }
            }
        }

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

        // MARK: plane lifecycle — detection only helps aiming / follows the wall

        func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
            guard let plane = anchor as? ARPlaneAnchor, plane.alignment == .vertical else { return }
            if !planeSeen {
                planeSeen = true
                DispatchQueue.main.async {
                    if !self.state.wallSet {
                        self.state.status = "Plane found — aim at it and tap SET WALL"
                    }
                }
            }
        }

        func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
            guard let plane = anchor as? ARPlaneAnchor else { return }
            // our wall follows ARKit's refinements of the anchor it came from
            if let w = wall, w.followsAnchor == plane.identifier {
                w.updateTransform(plane.transform)
            }
        }

        func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
            // if ARKit merges away our source anchor, the wall simply stays
            // frozen at its last (good) transform — paint never disappears
        }

        // MARK: per-frame tick (render thread)

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            let dt = lastTime == 0 ? 1.0 / 60.0 : min(0.05, time - lastTime)
            lastTime = time

            if state.clearRequested {
                state.clearRequested = false
                wall?.engine?.clear()
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
                toggleLasso()
            }
            if state.exportRequested {
                state.exportRequested = false
                DispatchQueue.main.async { self.exportPNG() }
            }
            syncTorchAndLight()

            if !motionBlurSet, let cam = arView?.pointOfView?.camera {
                motionBlurSet = true
                cam.motionBlurIntensity = 1.0   // paint smears on fast pans
                cam.wantsDepthOfField = false   // pinned off — DOF flickers on grain
            }

            guard let view = arView, let frame = view.session.currentFrame else { return }

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

            if state.resetPointsRequested {
                state.resetPointsRequested = false
                clearSetPoints()
            }
            if let tp = state.setPointTouch {
                state.setPointTouch = nil
                if wall == nil { placeSetPoint(view: view, at: tp) }
            }
            if state.wallNudge != lastNudge {
                lastNudge = state.wallNudge
                wall?.setNudge(Float(state.wallNudge))
            }
            if state.setWallRequested {
                state.setWallRequested = false
                setWall(view: view, camPos: camPos, camFwd: camFwd)
            }
            if state.scanReflectionRequested {
                state.scanReflectionRequested = false
                scanReflection(frame: frame)
            }

            // painting hits OUR wall's infinite plane — steady, no strobing
            var hit: (tex: CGPoint, dist: Double, stretch: CGFloat,
                      sdir: CGVector, roll: CGVector)?
            if let w = wall, let t = w.rayHit(origin: camPos, dir: camFwd), t < 8 {
                let world = camPos + camFwd * t
                if let tex = w.texturePoint(worldPoint: world) {
                    let (stretch, sdir) = w.obliqueness(rayDir: camFwd)
                    hit = (tex, Double(t), stretch, sdir,
                           w.rollDirection(cameraRight: camRight))
                }
            }

            // before a wall is set, the crosshair shows where SET WALL would land
            var aimed = hit != nil
            if wall == nil {
                if let query = view.raycastQuery(from: viewCenter,
                                                 allowing: .existingPlaneGeometry,
                                                 alignment: .vertical) {
                    aimed = !view.session.raycast(query).isEmpty
                }
            }
            if aimed != state.aimedAtWall {
                DispatchQueue.main.async { self.state.aimedAtWall = aimed }
            }

            let spraying = (state.spraying || VolumeSpray.shared.holding) && !state.editingPlane
            var cap = PaintState.nozzles[state.nozzleIndex]
            if cap.custom {
                // the four sliders shape the drawn cap live
                cap = SprayCap(name: cap.name,
                               deg: cap.deg * max(0.3, state.customScale),
                               dotScale: CGFloat(max(0.05, state.customDotSize)),
                               countScale: CGFloat(max(0.1, state.customCount)),
                               scatterScale: CGFloat(min(1.0, max(0.0, state.customScatter))),
                               holeFrac: 0, chisel: false,
                               dripMaxM: cap.dripMaxM, icon: cap.icon,
                               dirty: false, custom: true)
            }
            let shape = cap.custom ? state.customShape : []
            let capReady = !(cap.custom && shape.count < 2)
            CanPhysics.shared.tick(spraying: spraying && hit != nil, dt: dt)
            handleLassoTouch(view: view)
            if spraying != wasSpraying {
                wasSpraying = spraying
                if spraying {
                    CanPhysics.shared.dashReset()
                    if wall == nil { state.showToast("Tap SET WALL first") }
                    else if !capReady { state.showToast("Draw your cap first — tap the blank cap again") }
                }
                DispatchQueue.main.async { SoundKit.shared.setSpraying(spraying) }
            }

            if spraying, capReady, let w = wall, let h = hit, w.contains(h.tex) {
                if let engine = ensureEngine(w) {
                    let color = state.colors[state.colorIndex].cgColor
                    let boost: CGFloat = [1, 5, 10][state.pressureBoost]
                    let from = sprayPrev ?? h.tex
                    engine.sprayStroke(from: from, to: h.tex,
                                       distance: h.dist, cap: cap,
                                       color: color, dt: dt,
                                       stretch: h.stretch, stretchDir: h.sdir,
                                       rollDir: h.roll,
                                       boost: boost, dashMode: state.dashMode,
                                       shape: shape)
                    sprayPrev = h.tex
                }
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

            if state.pickingColorIndex != nil {
                if let ui = sampleCameraColor(frame: frame, at: state.pickPoint) {
                    DispatchQueue.main.async { self.state.pickPreview = ui }
                }
            }

            // per-frame, not on the edge: the canvas is born lazily on the
            // first painted tile, possibly mid-hold, and must still learn
            // that a stroke is running
            wall?.canvasRef()?.setStroking(spraying)
            wall?.engine?.stepDrips(dt: dt)
            wall?.engine?.flush(dt: dt)
        }

        // MARK: wall points — tap the FLAT spots; the wall passes through them

        private func placeSetPoint(view: ARSCNView, at pt: CGPoint) {
            var world: simd_float3?
            var orient: simd_float4x4?
            if let q = view.raycastQuery(from: pt, allowing: .existingPlaneGeometry,
                                         alignment: .vertical),
               let r = view.session.raycast(q).first {
                world = r.worldTransform.position
                orient = (r.anchor as? ARPlaneAnchor)?.transform ?? r.worldTransform
            } else if let q = view.raycastQuery(from: pt, allowing: .estimatedPlane,
                                                alignment: .any),
                      let r = view.session.raycast(q).first {
                world = r.worldTransform.position
                orient = r.worldTransform
            }
            guard let w = world else {
                state.showToast("No surface there — try another spot")
                return
            }
            if firstHitTransform == nil { firstHitTransform = orient }
            setPoints.append(w)
            let sph = SCNSphere(radius: 0.011)
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = UIColor.white
            m.emission.contents = UIColor.orange
            sph.materials = [m]
            let n = SCNNode(geometry: sph)
            n.simdPosition = w
            view.scene.rootNode.addChildNode(n)
            setPointNodes.append(n)
            DispatchQueue.main.async { self.state.setPointCount = self.setPoints.count }
        }

        private func clearSetPoints() {
            setPoints = []
            firstHitTransform = nil
            for n in setPointNodes { n.removeFromParentNode() }
            setPointNodes = []
            DispatchQueue.main.async { self.state.setPointCount = 0 }
        }

        /// plane with the given normal through the given origin, facing the camera
        private func planeTransform(normal nIn: simd_float3, origin: simd_float3,
                                    towards cam: simd_float3) -> simd_float4x4 {
            var n = simd_normalize(nIn)
            if simd_dot(n, cam - origin) < 0 { n = -n }
            var x = simd_cross(simd_float3(0, 1, 0), n)
            if simd_length(x) < 1e-3 { x = simd_cross(simd_float3(1, 0, 0), n) }
            x = simd_normalize(x)
            let z = simd_cross(x, n)
            var t = matrix_identity_float4x4
            t.columns.0 = vec4(x, 0)
            t.columns.1 = vec4(n, 0)
            t.columns.2 = vec4(z, 0)
            t.columns.3 = vec4(origin, 1)
            return t
        }

        // MARK: SET WALL — the one deliberate designation

        private func setWall(view: ARSCNView, camPos: simd_float3, camFwd: simd_float3) {
            guard wall == nil else { return }
            var transform: simd_float4x4?
            var follow: UUID?
            var boundaryTex: [CGPoint] = []
            var hitWorld: simd_float3?

            // YOUR points win: the plane passes through the average of the flat
            // spots you tapped — protruding clutter can no longer pull it away
            if setPoints.count >= 1, let src = firstHitTransform {
                var c = simd_float3(0, 0, 0)
                for p in setPoints { c += p }
                c /= Float(setPoints.count)
                let col = src.columns.1
                transform = planeTransform(normal: simd_float3(col.x, col.y, col.z),
                                           origin: c, towards: camPos)
                hitWorld = c
            }
            // otherwise: ARKit's detected plane under the crosshair
            else if let query = view.raycastQuery(from: viewCenter,
                                             allowing: .existingPlaneGeometry,
                                             alignment: .vertical),
               let result = view.session.raycast(query).first,
               let plane = result.anchor as? ARPlaneAnchor {
                transform = plane.transform
                follow = plane.identifier
                hitWorld = result.worldTransform.position
                boundaryTex = PaintSurface.boundaryTexPoints(of: plane)
            } else if let query = view.raycastQuery(from: viewCenter,
                                                    allowing: .estimatedPlane,
                                                    alignment: .vertical),
                      let result = view.session.raycast(query).first {
                transform = result.worldTransform
                hitWorld = result.worldTransform.position
                state.showToast("Using estimated surface — scan more for precision")
            }

            guard let t = transform else {
                state.showToast("No wall under the crosshair — scan a bit more")
                return
            }
            let w = PaintSurface(transform: t, followsAnchor: follow)
            view.scene.rootNode.addChildNode(w.rootNode)
            if boundaryTex.count >= 3 {
                w.applyLasso(boundaryTex, tool: .add)
            } else if let hw = hitWorld, let tex = w.texturePoint(worldPoint: hw) {
                w.seedSquare(center: tex, halfMeters: 1.2)
            } else {
                w.seedSquare(center: CGPoint(x: w.canvasPx / 2, y: w.canvasPx / 2), halfMeters: 1.2)
            }
            wall = w
            sprayPrev = nil
            clearSetPoints()
            lastNudge = 0
            arView?.debugOptions = []
            DispatchQueue.main.async {
                self.state.wallSet = true
                self.state.wallNudge = 0
                self.state.status = "Wall set — spray away · lasso to reshape"
            }
        }

        // MARK: lasso editing — inside adds, outside cuts

        private func toggleLasso() {
            if state.editingPlane {
                wall?.hideEditor()
                lassoStroke = []
                DispatchQueue.main.async { self.state.editingPlane = false }
                return
            }
            guard let w = wall else {
                state.showToast("Set the wall first")
                return
            }
            w.showEditor()
            DispatchQueue.main.async { self.state.editingPlane = true }
            state.showToast("Pick a tool: + adds · − cuts · or lasso a wall material")
        }

        private func handleLassoTouch(view: ARSCNView) {
            guard state.editingPlane, let w = wall, let touch = state.editTouch else { return }
            state.editTouch = nil
            let tool = state.editTool
            guard let world = view.unprojectPoint(touch.point, ontoPlane: w.anchorTransform),
                  let tex = w.texturePointClamped(worldPoint: world) else {
                if touch.phase == 3, lassoStroke.count >= 3 {
                    w.applyLasso(lassoStroke, tool: tool)
                    lassoStroke = []
                }
                return
            }
            switch touch.phase {
            case 1:
                lassoStroke = [tex]
                w.previewLasso(lassoStroke, tool: tool)
            case 2:
                lassoStroke.append(tex)
                w.previewLasso(lassoStroke, tool: tool)
            default:
                lassoStroke.append(tex)
                if lassoStroke.count >= 3 {
                    w.applyLasso(lassoStroke, tool: tool)
                }
                lassoStroke = []
            }
        }

        // MARK: engine allocation

        private func ensureEngine(_ surface: PaintSurface) -> SprayEngine? {
            if let e = surface.engine { return e }
            guard let device = device else { return nil }
            surface.allocateEngine(device: device, budget: tileBudget) { [weak self] in
                self?.state.showToast("Painted-area limit (~3.5 m²) — Clear frees it")
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
            wall?.canvasRef()?.setTorchBoost(state.torchOn ? 1 : 0)

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
            wall?.teardown()
            wall = nil
            tileBudget.warned = false
            sprayPrev = nil
            lassoStroke = []
            planeSeen = false
            clearSetPoints()
            lastNudge = 0
            DispatchQueue.main.async { self.state.wallNudge = 0 }
            runSession(reset: true)
            arView?.debugOptions = [.showFeaturePoints]
            state.wallSet = false
            state.editingPlane = false
            state.status = "Scan slowly · then aim at the wall and tap SET WALL"
            state.showToast("Rescanning…")
        }

        // MARK: PNG export — full resolution, transparent background

        private func exportPNG() {
            guard let w = wall, let canvas = w.exportCanvas() else {
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

        // MARK: reflection scan — snapshot the room, blur it, mirror on wet paint

        private func scanReflection(frame: ARFrame) {
            let buf = frame.capturedImage
            let ci = CIImage(cvPixelBuffer: buf)
            // downscale hard + blur → the low-res, dreamy reflection you asked for
            let ctx = CIContext()
            // 160 px, no gaussian: the downscale + texture filtering supply
            // all the blur needed, and skipping the blur pass saves memory
            let scale: CGFloat = 160 / max(ci.extent.width, ci.extent.height)
            let small = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let cg = ctx.createCGImage(small, from: small.extent) else {
                state.showToast("Reflection scan failed — try again")
                return
            }
            wall?.canvasRef()?.setReflection(cg)
            state.showToast("Reflection captured · wet paint now mirrors it")
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

// MARK: - PaintSurface: THE wall — one frozen plane with a lasso-editable mask

final class PaintSurface {
    static let sizeMeters: CGFloat = 12.0        // huge canvas, tiles stay lazy

    let rootNode = SCNNode()                     // world-placed
    let node = SCNNode()                         // paint root, rotated into the wall
    private(set) var engine: SprayEngine?
    private var canvas: PaintCanvas?
    private(set) var anchorTransform: simd_float4x4
    private var baseTransform: simd_float4x4
    private(set) var nudge: Float = 0
    let followsAnchor: UUID?
    private let dripDirLocal: CGVector
    var canvasPx: CGFloat { PaintSurface.sizeMeters * PaintCanvas.ppm }

    // paintable-area mask: 5400² one-bit lattice (0.22 cm cells) — fine
    // enough that a clipped spray edge reads as a taped line, affordable
    // (3.7 MB) because it is bits, not bytes
    static let maskN = 5400
    private static let maskWords = (maskN + 63) / 64
    private var maskBits: [UInt64]
    // wall materials stay on the coarser 1800 lattice — sheen regions don't
    // need edge precision and the shader samples them linearly anyway
    private var mat: [UInt8]                     // 0 glossy · 1 rough · 2 bumpy
    private var maskAny = false
    // every lasso ever applied, replayed as vector paths by the editor viz —
    // the overlay draws smooth curves, never grid cells
    private var ops: [(poly: [CGPoint], tool: EditTool)] = []
    private var maskCellPx: CGFloat { canvasPx / CGFloat(PaintSurface.maskN) }
    private var matCellPx: CGFloat { canvasPx / CGFloat(PaintCanvas.matN) }

    // lasso editor visualisation
    private var vizCtx: CGContext?
    private var matVizCtx: CGContext?
    private var vizMaterial: SCNMaterial?
    private var vizNode: SCNNode?
    private let vizPx = 1024                     // vector fills — smooth at any res

    init(transform: simd_float4x4, followsAnchor: UUID?) {
        anchorTransform = transform
        baseTransform = transform
        self.followsAnchor = followsAnchor
        rootNode.simdTransform = transform
        node.eulerAngles.x = -.pi / 2
        rootNode.addChildNode(node)
        maskBits = .init(repeating: 0, count: PaintSurface.maskN * PaintSurface.maskWords)
        // walls default to ROUGH (matte) — glossy is the opt-in, per Oskars
        mat = .init(repeating: 1, count: PaintCanvas.matN * PaintCanvas.matN)

        let downLocal = transform.inverse * simd_float4(0, -1, 0, 0)
        dripDirLocal = CGVector(dx: CGFloat(downLocal.x), dy: CGFloat(downLocal.z))
    }

    func updateTransform(_ t: simd_float4x4) {
        baseTransform = t
        applyNudge()
    }

    /// depth adjustment along the wall's normal (the edit-mode slider)
    func setNudge(_ n: Float) {
        nudge = n
        applyNudge()
    }

    private func applyNudge() {
        var t = baseTransform
        let col = t.columns.1
        let n3 = simd_normalize(simd_float3(col.x, col.y, col.z))
        let o = t.columns.3
        t.columns.3 = simd_float4(o.x + n3.x * nudge, o.y + n3.y * nudge,
                                  o.z + n3.z * nudge, 1)
        anchorTransform = t
        rootNode.simdTransform = t
    }

    func allocateEngine(device: MTLDevice, budget: TileBudget, onBudgetExceeded: @escaping () -> Void) {
        guard engine == nil else { return }
        let c = PaintCanvas(surfaceMeters: PaintSurface.sizeMeters,
                            device: device, budget: budget, parent: node)
        c.onBudgetExceeded = onBudgetExceeded
        canvas = c
        // tilt = how vertical the surface is (wall normal vs world up).
        // 1 on a wall → full drips · 0 on a floor/ceiling → no drips
        let col = anchorTransform.columns.1
        let n = simd_normalize(simd_float3(col.x, col.y, col.z))
        let tilt = CGFloat(sqrt(max(0, 1 - n.y * n.y)))
        c.setMaterialGrid(mat)          // regions may have been lassoed pre-paint
        engine = SprayEngine(canvas: c, dripDirection: dripDirLocal, tilt: tilt,
                             allowed: { [weak self] p in self?.contains(p) ?? false },
                             materialAt: { [weak self] p in self?.materialAt(p) ?? 0 })
    }

    func canvasRef() -> PaintCanvas? { canvas }

    func teardown() {
        canvas?.teardown()
        canvas = nil
        engine = nil
        rootNode.removeFromParentNode()
    }

    func exportCanvas() -> PaintCanvas? { canvas }

    // MARK: geometry

    func texturePoint(worldPoint: simd_float3) -> CGPoint? {
        let local = anchorTransform.inverse * vec4(worldPoint, 1)
        let half = Float(PaintSurface.sizeMeters / 2)
        guard abs(local.x) < half, abs(local.z) < half else { return nil }
        let ppm = Float(PaintCanvas.ppm)
        return CGPoint(x: CGFloat((local.x + half) * ppm),
                       y: CGFloat((local.z + half) * ppm))
    }

    /// like texturePoint but clamps to the canvas instead of failing
    func texturePointClamped(worldPoint: simd_float3) -> CGPoint? {
        let local = anchorTransform.inverse * vec4(worldPoint, 1)
        let half = Float(PaintSurface.sizeMeters / 2)
        let ppm = Float(PaintCanvas.ppm)
        let x = min(max(local.x, -half + 0.01), half - 0.01)
        let z = min(max(local.z, -half + 0.01), half - 0.01)
        return CGPoint(x: CGFloat((x + half) * ppm), y: CGFloat((z + half) * ppm))
    }

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

    static func boundaryTexPoints(of plane: ARPlaneAnchor) -> [CGPoint] {
        let verts = plane.geometry.boundaryVertices
        guard verts.count >= 3 else { return [] }
        let step = max(1, verts.count / 12)
        let half = Float(sizeMeters / 2)
        let ppm = CGFloat(PaintCanvas.ppm)
        var pts: [CGPoint] = []
        var i = 0
        while i < verts.count {
            let v = verts[i]
            let x = min(max(v.x, -half + 0.02), half - 0.02)
            let z = min(max(v.z, -half + 0.02), half - 0.02)
            pts.append(CGPoint(x: CGFloat(x + half) * ppm, y: CGFloat(z + half) * ppm))
            i += step
        }
        return pts.count >= 3 ? pts : []
    }

    // MARK: paintable-area mask

    var maskIsEmpty: Bool { !maskAny }

    func contains(_ p: CGPoint) -> Bool {
        let n = PaintSurface.maskN
        let cx = Int(p.x / maskCellPx), cy = Int(p.y / maskCellPx)
        guard cx >= 0, cy >= 0, cx < n, cy < n else { return false }
        return maskBits[cy * PaintSurface.maskWords + (cx >> 6)]
            & (UInt64(1) << UInt64(cx & 63)) != 0
    }

    /// Wall material under a canvas point: 0 glossy · 1 rough · 2 bumpy.
    func materialAt(_ p: CGPoint) -> UInt8 {
        let n = PaintCanvas.matN
        let cx = Int(p.x / matCellPx), cy = Int(p.y / matCellPx)
        guard cx >= 0, cy >= 0, cx < n, cy < n else { return 0 }
        return mat[cy * n + cx]
    }

    func seedSquare(center: CGPoint, halfMeters: CGFloat) {
        let h = halfMeters * PaintCanvas.ppm
        applyLasso([CGPoint(x: center.x - h, y: center.y - h),
                    CGPoint(x: center.x + h, y: center.y - h),
                    CGPoint(x: center.x + h, y: center.y + h),
                    CGPoint(x: center.x - h, y: center.y + h)], tool: .add)
    }

    /// Photoshop-style lasso: recorded as a vector op (for the smooth editor
    /// overlay) and rasterised into the mask bitset (+/−) or the material
    /// grid (glossy/rough/bumpy) per the active tool.
    func applyLasso(_ texPts: [CGPoint], tool: EditTool) {
        guard texPts.count >= 3 else { return }
        ops.append((texPts, tool))
        switch tool {
        case .add, .cut:
            rasterizeMask(texPts, set: tool == .add)
        case .glossy, .rough, .bumpy:
            rasterizeMat(texPts, value: tool == .glossy ? 0 : (tool == .rough ? 1 : 2))
            canvas?.setMaterialGrid(mat)
        }
        redrawViz(stroke: nil, tool: tool)
    }

    /// Scanline crossings of a polygon row — shared by both rasterisers.
    private func rowCrossings(_ poly: [CGPoint], _ yc: CGFloat) -> [CGFloat] {
        var xs: [CGFloat] = []
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > yc) != (b.y > yc) {
                xs.append(a.x + (yc - a.y) / (b.y - a.y) * (b.x - a.x))
            }
            j = i
        }
        xs.sort()
        return xs
    }

    private func rasterizeMask(_ texPts: [CGPoint], set: Bool) {
        let n = PaintSurface.maskN
        let poly = texPts.map { CGPoint(x: $0.x / maskCellPx, y: $0.y / maskCellPx) }
        for cy in 0..<n {
            let xs = rowCrossings(poly, CGFloat(cy) + 0.5)
            var k = 0
            while k + 1 < xs.count {
                let x0 = max(0, Int(xs[k].rounded(.down)))
                let x1 = min(n - 1, Int(xs[k + 1].rounded(.up)))
                if x0 <= x1 { fillBits(row: cy, x0: x0, x1: x1, set: set) }
                k += 2
            }
        }
        if set { maskAny = true }
        else { maskAny = maskBits.contains { $0 != 0 } }
    }

    /// Set/clear a run of mask bits word-wise — a 5400-cell row is 85 ops,
    /// not 5400.
    private func fillBits(row: Int, x0: Int, x1: Int, set: Bool) {
        let base = row * PaintSurface.maskWords
        var i = x0
        while i <= x1 {
            let w = i >> 6
            let bit = i & 63
            let span = min(64 - bit, x1 - i + 1)
            let word: UInt64 = span == 64
                ? ~UInt64(0)
                : ((UInt64(1) << UInt64(span)) - 1) << UInt64(bit)
            if set { maskBits[base + w] |= word } else { maskBits[base + w] &= ~word }
            i += span
        }
    }

    private func rasterizeMat(_ texPts: [CGPoint], value: UInt8) {
        let n = PaintCanvas.matN
        let poly = texPts.map { CGPoint(x: $0.x / matCellPx, y: $0.y / matCellPx) }
        for cy in 0..<n {
            let xs = rowCrossings(poly, CGFloat(cy) + 0.5)
            var k = 0
            while k + 1 < xs.count {
                let x0 = max(0, Int(xs[k].rounded(.down)))
                let x1 = min(n - 1, Int(xs[k + 1].rounded(.up)))
                if x0 <= x1 {
                    for cx in x0...x1 { mat[cy * n + cx] = value }
                }
                k += 2
            }
        }
    }

    // MARK: lasso editor visuals

    func showEditor() {
        if vizNode == nil {
            let cs = CGColorSpaceCreateDeviceRGB()
            vizCtx = CGContext(data: nil, width: vizPx, height: vizPx,
                               bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            vizCtx?.translateBy(x: 0, y: CGFloat(vizPx))
            vizCtx?.scaleBy(x: 1, y: -1)
            // material tints get their own layer so a glossy lasso can erase
            // them without touching the green mask underneath
            matVizCtx = CGContext(data: nil, width: vizPx, height: vizPx,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            matVizCtx?.translateBy(x: 0, y: CGFloat(vizPx))
            matVizCtx?.scaleBy(x: 1, y: -1)
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.isDoubleSided = true
            m.transparencyMode = .aOne
            m.writesToDepthBuffer = false
            let geo = SCNPlane(width: PaintSurface.sizeMeters, height: PaintSurface.sizeMeters)
            geo.materials = [m]
            let n = SCNNode(geometry: geo)
            n.position.z = 0.003
            vizMaterial = m
            vizNode = n
        }
        if let n = vizNode, n.parent == nil { node.addChildNode(n) }
        redrawViz(stroke: nil, tool: .add)
    }

    func hideEditor() {
        vizNode?.removeFromParentNode()
    }

    func previewLasso(_ texPts: [CGPoint], tool: EditTool) {
        redrawViz(stroke: texPts, tool: tool)
    }

    private static func strokeColor(_ tool: EditTool) -> UIColor {
        switch tool {
        case .add:    return .white
        case .cut:    return .systemRed
        case .glossy: return .systemTeal
        case .rough:  return .systemYellow
        case .bumpy:  return .systemBlue
        }
    }

    /// The editor overlay is VECTOR: it replays every lasso op as a smooth
    /// anti-aliased path fill (cut and glossy erase with .clear), so the
    /// on-wall display shows curves, never grid cells — whatever the mask
    /// resolution underneath.
    private func redrawViz(stroke: [CGPoint]?, tool: EditTool) {
        guard let ctx = vizCtx, vizNode?.parent != nil else { return }
        let full = CGRect(x: 0, y: 0, width: vizPx, height: vizPx)
        ctx.clear(full)
        let vscale = CGFloat(vizPx) / canvasPx

        func path(_ poly: [CGPoint]) -> CGPath {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: poly[0].x * vscale, y: poly[0].y * vscale))
            for pt in poly.dropFirst() {
                p.addLine(to: CGPoint(x: pt.x * vscale, y: pt.y * vscale))
            }
            p.closeSubpath()
            return p
        }

        // paintable area: + fills green, − erases
        for op in ops where op.tool == .add || op.tool == .cut {
            ctx.addPath(path(op.poly))
            ctx.setBlendMode(op.tool == .add ? .normal : .clear)
            ctx.setFillColor(UIColor(red: 0.35, green: 1.0, blue: 0.45, alpha: 0.18).cgColor)
            ctx.fillPath()
        }
        ctx.setBlendMode(.normal)

        // material tints on their own layer: rough yellow, bumpy blue,
        // glossy erases — composited over the mask
        if let mctx = matVizCtx {
            mctx.clear(full)
            for op in ops {
                switch op.tool {
                case .add, .cut: continue
                case .glossy: mctx.setBlendMode(.clear)
                case .rough:
                    mctx.setBlendMode(.normal)
                    mctx.setFillColor(UIColor(red: 1.00, green: 0.85, blue: 0.20, alpha: 0.16).cgColor)
                case .bumpy:
                    mctx.setBlendMode(.normal)
                    mctx.setFillColor(UIColor(red: 0.30, green: 0.60, blue: 1.00, alpha: 0.18).cgColor)
                }
                mctx.addPath(path(op.poly))
                mctx.fillPath()
            }
            mctx.setBlendMode(.normal)
            if let img = mctx.makeImage() {
                ctx.saveGState()
                ctx.concatenate(ctx.ctm.inverted())     // device space: no double flip
                ctx.draw(img, in: full)
                ctx.restoreGState()
            }
        }

        // the live lasso stroke, coloured by the active tool
        if let stroke = stroke, stroke.count >= 2 {
            ctx.setStrokeColor(PaintSurface.strokeColor(tool).cgColor)
            ctx.setLineWidth(2.5)
            ctx.setLineCap(.round)
            let scale = CGFloat(vizPx) / canvasPx
            ctx.move(to: CGPoint(x: stroke[0].x * scale, y: stroke[0].y * scale))
            for p in stroke.dropFirst() {
                ctx.addLine(to: CGPoint(x: p.x * scale, y: p.y * scale))
            }
            ctx.strokePath()
        }
        if let img = ctx.makeImage() {
            vizMaterial?.diffuse.contents = img
        }
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
