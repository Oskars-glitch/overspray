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

/// Shared state between the SwiftUI overlay and the AR coordinator.
final class PaintState: ObservableObject {
    // controls
    @Published var colorIndex = 0                 // 0 black, 1 white
    @Published var nozzleIndex = 1                // 0 skinny, 1 standard, 2 fat
    @Published var spraying = false               // on-screen cap OR volume button
    @Published var isRecording = false
    @Published var recordSeconds = 0

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

    static let colors: [(name: String, ui: UIColor)] = [
        ("Black", UIColor(red: 0.02, green: 0.02, blue: 0.025, alpha: 1)),  // ~98% dark
        ("White", UIColor(red: 0.96, green: 0.95, blue: 0.93, alpha: 1)),
    ]
    // spray-can caps: half-angle in degrees + density factor (skinny = denser)
    static let nozzles: [(deg: Double, dot: CGFloat, name: String)] = [
        (2.2, 6, "Skinny cap"), (6.5, 10, "Standard cap"), (13.0, 16, "Fat cap"),
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
