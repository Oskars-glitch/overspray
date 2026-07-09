import SwiftUI

struct ContentView: View {
    @StateObject private var state = PaintState()

    var body: some View {
        ZStack {
            ARSprayView(state: state)
                .ignoresSafeArea()

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
                    Button(action: { state.torchOn.toggle() }) {
                        Image(systemName: state.torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(state.torchOn ? .yellow : .white)
                            .frame(width: 38, height: 38)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    Button("Rescan") { state.rescanRequested = true }
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                    Button("Clear") { state.clearRequested = true }
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .padding(.horizontal, 14)

                Text(state.status)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 6)

                Spacer()

                HStack(alignment: .bottom) {
                    VStack(spacing: 10) {
                        // caps: pink dot · cyclops (ring) · beef · chisel (bar)
                        ForEach(PaintState.nozzles.indices.reversed(), id: \.self) { i in
                            let cap = PaintState.nozzles[i]
                            Button(action: { state.nozzleIndex = i; state.showToast(cap.name) }) {
                                ZStack {
                                    Circle().fill(.ultraThinMaterial).frame(width: 38, height: 38)
                                    if cap.chisel {
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(Color.white).frame(width: 18, height: 5)
                                    } else if cap.holeFrac > 0 {
                                        Circle().strokeBorder(Color.white, lineWidth: 3)
                                            .frame(width: cap.icon + 6, height: cap.icon + 6)
                                    } else {
                                        Circle().fill(Color.white)
                                            .frame(width: cap.icon, height: cap.icon)
                                    }
                                }
                                .overlay(Circle().strokeBorder(
                                    state.nozzleIndex == i ? Color.orange : Color.white.opacity(0.2),
                                    lineWidth: 2))
                            }
                        }
                        Rectangle().fill(Color.white.opacity(0.3)).frame(width: 26, height: 1)
                        // colors: tap = select · HOLD + drag = pick from the camera
                        ForEach(state.colors.indices.reversed(), id: \.self) { i in
                            ColorSwatch(state: state, index: i)
                        }
                    }
                    Spacer()
                    VStack(spacing: 6) {
                        SprayCapButton(state: state)
                        Text("HOLD · or volume-down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
            }
            .padding(.top, 8)

            // eyedropper: floating preview follows the finger
            if state.pickingColorIndex != nil, state.pickPoint != .zero {
                ZStack {
                    Circle().fill(Color(state.pickPreview)).frame(width: 46, height: 46)
                    Circle().strokeBorder(Color.white, lineWidth: 3).frame(width: 46, height: 46)
                }
                .position(x: state.pickPoint.x, y: state.pickPoint.y - 60)
                .allowsHitTesting(false)
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

/// A color swatch: tap selects; long-press then drag picks the colour of the
/// camera image under your finger (session-only — restart resets).
struct ColorSwatch: View {
    @ObservedObject var state: PaintState
    let index: Int

    var body: some View {
        let picking = state.pickingColorIndex == index
        Circle()
            .fill(Color(picking ? state.pickPreview : state.colors[index]))
            .frame(width: 38, height: 38)
            .overlay(Circle().strokeBorder(
                state.colorIndex == index ? Color.white : Color.white.opacity(0.4),
                lineWidth: 2))
            .scaleEffect(state.colorIndex == index ? 1.18 : 1)
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
