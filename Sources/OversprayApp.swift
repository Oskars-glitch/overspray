import SwiftUI

@main
struct OversprayApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
    }
}

/// One spray-can cap and how it behaves.
struct SprayCap {
    let name: String
    let deg: Double            // cone half-angle
    let dotScale: CGFloat      // droplet size multiplier
    let countScale: CGFloat    // droplet count multiplier
    let scatterScale: CGFloat  // how loose the cone is (also gates splatter)
    let holeFrac: CGFloat      // >0 → ring pattern with a clean hole in the middle
    let chisel: Bool           // flat line footprint that rotates with the phone
    let dripMaxM: Double       // drips only closer than this (0 = never drips)
    let icon: CGFloat          // UI dot size (0 = bar icon)
}

/// Shared state between the SwiftUI overlay and the AR coordinator.
final class PaintState: ObservableObject {
    // controls
    @Published var colorIndex = 0
    @Published var nozzleIndex = 0
    @Published var spraying = false
    @Published var isRecording = false
    @Published var recordSeconds = 0

    // colors are session-only: long-press a swatch to pick from the camera,
    // restart the app to reset to defaults
    @Published var colors: [UIColor] = [
        UIColor(red: 0.012, green: 0.012, blue: 0.016, alpha: 1),   // deep (not true) black
        UIColor(red: 0.90, green: 0.89, blue: 0.87, alpha: 1),      // off-white
    ]
    @Published var pickingColorIndex: Int? = nil
    @Published var pickPoint: CGPoint = .zero
    @Published var pickPreview: UIColor = .gray

    // feedback
    @Published var status = "Move your phone slowly to scan for walls"
    @Published var wallCount = 0
    @Published var aimedAtWall = false
    @Published var toast: String? = nil
    @Published var torchOn = false

    // commands consumed by the AR coordinator
    var clearRequested = false
    var toggleRecordRequested = false
    var rescanRequested = false

    static let nozzles: [SprayCap] = [
        SprayCap(name: "Pink dot", deg: 2.2, dotScale: 0.15, countScale: 4.5,
                 scatterScale: 0.5, holeFrac: 0, chisel: false, dripMaxM: 0.6, icon: 5),
        SprayCap(name: "Cyclops", deg: 6.5, dotScale: 0.5, countScale: 1.6,
                 scatterScale: 0.6, holeFrac: 0.45, chisel: false, dripMaxM: 0, icon: 11),
        SprayCap(name: "Beef", deg: 13.0, dotScale: 1.0, countScale: 1.0,
                 scatterScale: 1.0, holeFrac: 0, chisel: false, dripMaxM: 0.35, icon: 17),
        SprayCap(name: "Chisel", deg: 8.0, dotScale: 0.6, countScale: 1.4,
                 scatterScale: 0.3, holeFrac: 0, chisel: true, dripMaxM: 0.30, icon: 0),
    ]

    func showToast(_ msg: String) {
        DispatchQueue.main.async {
            self.toast = msg
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                if self.toast == msg { self.toast = nil }
            }
        }
    }
}
