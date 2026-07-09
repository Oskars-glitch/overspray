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
                          ? Color(PaintState.colors[state.colorIndex].ui)
                          : Color.white.opacity(0.9))
                    .frame(width: 6, height: 6)
            }

            VStack {
                // top bar: record + timer + clear
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

                // status chip
                Text(state.status)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 6)

                Spacer()

                HStack(alignment: .bottom) {
                    // colors + nozzle caps
                    VStack(spacing: 10) {
                        ForEach(PaintState.nozzles.indices.reversed(), id: \.self) { i in
                            let nz = PaintState.nozzles[i]
                            Button(action: { state.nozzleIndex = i; state.showToast(nz.name) }) {
                                ZStack {
                                    Circle().fill(.ultraThinMaterial).frame(width: 38, height: 38)
                                    Circle().fill(Color.white).frame(width: nz.dot, height: nz.dot)
                                }
                                .overlay(Circle().strokeBorder(
                                    state.nozzleIndex == i ? Color.orange : Color.white.opacity(0.2),
                                    lineWidth: 2))
                            }
                        }
                        Rectangle().fill(Color.white.opacity(0.3)).frame(width: 26, height: 1)
                        ForEach(PaintState.colors.indices.reversed(), id: \.self) { i in
                            let cc = PaintState.colors[i]
                            Button(action: { state.colorIndex = i }) {
                                Circle()
                                    .fill(Color(cc.ui))
                                    .frame(width: 38, height: 38)
                                    .overlay(Circle().strokeBorder(
                                        state.colorIndex == i ? Color.white : Color.white.opacity(0.4),
                                        lineWidth: 2))
                                    .scaleEffect(state.colorIndex == i ? 1.18 : 1)
                            }
                        }
                    }
                    Spacer()
                    // on-screen spray cap (volume-down also sprays)
                    VStack(spacing: 6) {
                        SprayCap(state: state)
                        Text("HOLD · or volume-down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
            }
            .padding(.top, 8)

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

/// The physical-feeling spray cap: press and hold to spray.
struct SprayCap: View {
    @ObservedObject var state: PaintState
    @GestureState private var pressed = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(PaintState.colors[state.colorIndex].ui))
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
