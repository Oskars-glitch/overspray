import SwiftUI

struct ContentView: View {
    @StateObject private var state = PaintState()

    var body: some View {
        ZStack {
            ARSprayView(state: state)
                .ignoresSafeArea()

            if state.editingPlane {
                EditTouchLayer(state: state)
                    .ignoresSafeArea()
            }

            // crosshair
            if state.aimedAtWall {
                Circle()
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
                    .frame(width: 54, height: 54)
                Circle()
                    .fill(state.spraying
                          ? Color(state.colors[state.colorIndex])
                          : Color.white.opacity(0.9))
                    .frame(width: 6, height: 6)
            }

            VStack {
                HStack {
                    Button(action: { state.toggleRecordRequested = true }) {
                        ZStack {
                            Circle().fill(.ultraThinMaterial).frame(width: 52, height: 52)
                            if state.isRecording {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color.red).frame(width: 17, height: 17)
                            } else {
                                Circle().fill(Color.red).frame(width: 20, height: 20)
                            }
                        }
                    }
                    if state.isRecording {
                        Text(String(format: "%d:%02d", state.recordSeconds / 60, state.recordSeconds % 60))
                            .font(.system(.callout, design: .monospaced).weight(.semibold))
                            .foregroundColor(.red)
                    }
                    Spacer()
                    Button(action: { state.editToggleRequested = true }) {
                        Image(systemName: "square.dashed")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(state.editingPlane ? .orange : .white)
                            .frame(width: 38, height: 38)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    Button(action: { state.exportRequested = true }) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 38, height: 38)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    Button(action: { state.torchOn.toggle() }) {
                        Image(systemName: state.torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(state.torchOn ? .yellow : .white)
                            .frame(width: 38, height: 38)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    Button("Rescan") { state.rescanRequested = true }
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                    Button("Clear") { state.clearRequested = true }
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .padding(.horizontal, 12)

                Text(state.status)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 6)

                Spacer()

                HStack(alignment: .bottom) {
                    VStack(spacing: 8) {
                        ForEach(PaintState.nozzles.indices.reversed(), id: \.self) { i in
                            CapButton(state: state, index: i)
                        }
                        Rectangle().fill(Color.white.opacity(0.3)).frame(width: 24, height: 1)
                        ForEach(state.colors.indices.reversed(), id: \.self) { i in
                            ColorSwatch(state: state, index: i)
                        }
                    }
                    Spacer()
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            // pressure boost ×1 / ×5 / ×10
                            Button(action: { state.pressureBoost = (state.pressureBoost + 1) % 3 }) {
                                Text("x\([1, 5, 10][state.pressureBoost])")
                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                                    .foregroundColor(state.pressureBoost > 0 ? .orange : .white)
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(.ultraThinMaterial, in: Capsule())
                            }
                            // dotted-line attachment .0 / .1 / .2
                            Button(action: { state.dashMode = (state.dashMode + 1) % 3 }) {
                                Text(".\(state.dashMode)")
                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                                    .foregroundColor(state.dashMode > 0 ? .orange : .white)
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(.ultraThinMaterial, in: Capsule())
                            }
                        }
                        SprayCapButton(state: state)
                        Text("HOLD · or volume-down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .padding(.top, 8)

            if state.pickingColorIndex != nil, state.pickPoint != .zero {
                ZStack {
                    Circle().fill(Color(state.pickPreview)).frame(width: 46, height: 46)
                    Circle().strokeBorder(Color.white, lineWidth: 3).frame(width: 46, height: 46)
                }
                .position(x: state.pickPoint.x, y: state.pickPoint.y - 60)
                .allowsHitTesting(false)
            }

            if state.drawingShape {
                ShapeDrawOverlay(state: state)
            }

            if let t = state.toast {
                VStack {
                    Spacer()
                    Text(t)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 130)
                }
                .transition(.opacity)
            }
        }
    }
}

/// One cap button, with the right icon per cap type.
struct CapButton: View {
    @ObservedObject var state: PaintState
    let index: Int

    var body: some View {
        let cap = PaintState.nozzles[index]
        Button(action: {
            if cap.custom, state.nozzleIndex == index || state.customShape.count < 2 {
                state.drawingShape = true
            }
            state.nozzleIndex = index
            state.showToast(cap.name)
        }) {
            ZStack {
                Circle().fill(.ultraThinMaterial).frame(width: 34, height: 34)
                if cap.custom {
                    Image(systemName: "scribble")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                } else if cap.dirty {
                    // splatter icon
                    Circle().fill(Color.white).frame(width: 9, height: 9)
                    Circle().fill(Color.white).frame(width: 4, height: 4).offset(x: 9, y: -6)
                    Circle().fill(Color.white).frame(width: 3, height: 3).offset(x: -9, y: 7)
                    Circle().fill(Color.white).frame(width: 3, height: 3).offset(x: 6, y: 9)
                    Circle().fill(Color.white).frame(width: 2.5, height: 2.5).offset(x: -8, y: -8)
                } else if cap.chisel {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white).frame(width: 16, height: 5)
                } else if cap.holeFrac > 0 {
                    Circle().strokeBorder(Color.white, lineWidth: 3)
                        .frame(width: cap.icon + 6, height: cap.icon + 6)
                } else {
                    Circle().fill(Color.white)
                        .frame(width: cap.icon, height: cap.icon)
                }
            }
            .overlay(Circle().strokeBorder(
                state.nozzleIndex == index ? Color.orange : Color.white.opacity(0.2),
                lineWidth: 2))
        }
    }
}

/// Draw-your-own-cap panel: sketch a shape with one or more strokes; the
/// droplets will follow it, camera-facing like the chisel.
struct ShapeDrawOverlay: View {
    @ObservedObject var state: PaintState
    @State private var strokes: [[CGPoint]] = []
    @State private var current: [CGPoint] = []
    private let panel: CGFloat = 300

    var body: some View {
        ZStack {
            Color.black.opacity(0.65).ignoresSafeArea()
            VStack(spacing: 16) {
                Text("Draw your cap's spray shape")
                    .font(.headline).foregroundColor(.white)
                ZStack {
                    RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.12))
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
                    Image(systemName: "plus")
                        .font(.system(size: 12)).foregroundColor(.white.opacity(0.25))
                    Path { p in
                        for s in strokes + (current.isEmpty ? [] : [current]) {
                            guard let f = s.first else { continue }
                            p.move(to: f)
                            for pt in s.dropFirst() { p.addLine(to: pt) }
                        }
                    }
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
                .frame(width: panel, height: panel)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { v in
                            let p = CGPoint(x: min(max(v.location.x, 4), panel - 4),
                                            y: min(max(v.location.y, 4), panel - 4))
                            current.append(p)
                        }
                        .onEnded { _ in
                            if current.count > 1 { strokes.append(current) }
                            current = []
                        }
                )
                HStack(spacing: 12) {
                    Button("Clear") { strokes = []; current = [] }
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                    Button("Cancel") { state.drawingShape = false }
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                    Button("Done") { commit() }
                        .font(.callout.weight(.bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 22).padding(.vertical, 10)
                        .background(Color.white, in: Capsule())
                }
            }
        }
    }

    private func commit() {
        let all = strokes.flatMap { $0 }
        guard all.count >= 2 else { state.drawingShape = false; return }
        var cx: CGFloat = 0, cy: CGFloat = 0
        for p in all { cx += p.x; cy += p.y }
        cx /= CGFloat(all.count); cy /= CGFloat(all.count)
        var ext: CGFloat = 1
        for p in all { ext = max(ext, abs(p.x - cx), abs(p.y - cy)) }
        let stride = max(1, all.count / 90)
        var norm: [CGPoint] = []
        var i = 0
        while i < all.count {
            norm.append(CGPoint(x: (all[i].x - cx) / ext, y: (all[i].y - cy) / ext))
            i += stride
        }
        state.customShape = norm
        state.drawingShape = false
        if let idx = PaintState.nozzles.firstIndex(where: { $0.custom }) {
            state.nozzleIndex = idx
        }
        state.showToast("Custom cap ready")
    }
}

/// Full-screen layer that forwards touches to the plane editor while editing.
struct EditTouchLayer: View {
    @ObservedObject var state: PaintState
    @State private var began = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { v in
                        state.editTouch = (v.location, began ? 2 : 1)
                        began = true
                    }
                    .onEnded { v in
                        state.editTouch = (v.location, 3)
                        began = false
                    }
            )
    }
}

/// A color swatch: tap selects; long-press then drag picks the colour of the
/// camera image under your finger (session-only — restart resets).
struct ColorSwatch: View {
    @ObservedObject var state: PaintState
    let index: Int

    var body: some View {
        let picking = state.pickingColorIndex == index
        Circle()
            .fill(Color(picking ? state.pickPreview : state.colors[index]))
            .frame(width: 34, height: 34)
            .overlay(Circle().strokeBorder(
                state.colorIndex == index ? Color.white : Color.white.opacity(0.4),
                lineWidth: 2))
            .scaleEffect(state.colorIndex == index ? 1.15 : 1)
            .onTapGesture { state.colorIndex = index }
            .gesture(
                LongPressGesture(minimumDuration: 0.35)
                    .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
                    .onChanged { value in
                        if case .second(true, let drag) = value {
                            if state.pickingColorIndex == nil {
                                state.pickingColorIndex = index
                                state.pickPoint = .zero
                            }
                            if let d = drag { state.pickPoint = d.location }
                        }
                    }
                    .onEnded { value in
                        if case .second = value, state.pickingColorIndex == index,
                           state.pickPoint != .zero {
                            state.colors[index] = state.pickPreview
                            state.colorIndex = index
                        }
                        state.pickingColorIndex = nil
                        state.pickPoint = .zero
                    }
            )
    }
}

/// The physical-feeling spray cap: press and hold to spray.
struct SprayCapButton: View {
    @ObservedObject var state: PaintState
    @GestureState private var pressed = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(state.colors[state.colorIndex]))
                .frame(width: 92, height: 92)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 3))
                .shadow(radius: 8)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.92))
                .frame(width: 14, height: 20)
        }
        .scaleEffect(pressed ? 0.93 : 1)
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($pressed) { _, s, _ in s = true }
        )
        .onChange(of: pressed) { down in
            state.spraying = down || VolumeSpray.shared.holding
        }
    }
}
