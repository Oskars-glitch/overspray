import AVFoundation
import CoreMotion
import UIKit

/// Can sounds + shake detection.
/// - spray_01…03.mp3 (or spray.mp3): a random one LOOPS while spraying
/// - shake_01…03.mp3 (or shake.mp3 / skahe.mp3): a random one plays when the
///   phone is physically shaken (works while painting too)
/// Missing files fail silently — the app just stays quiet.
final class SoundKit {
    static let shared = SoundKit()

    private var sprayURLs: [URL] = []
    private var shakeURLs: [URL] = []
    private var sprayPlayer: AVAudioPlayer?
    private var oneShots: [AVAudioPlayer] = []
    private let motion = CMMotionManager()
    private var shakeHits: [TimeInterval] = []
    private var lastShakePlay: TimeInterval = 0

    func setup() {
        reassertSession()
        sprayURLs = urls(for: ["spray_01", "spray_02", "spray_03", "spray"])
        shakeURLs = urls(for: ["shake_01", "shake_02", "shake_03", "shake", "skahe"])
        startShakeDetection()
    }

    /// (Re)apply our audio session — call again after AR session restarts.
    func reassertSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default,
                                 options: [.defaultToSpeaker, .mixWithOthers])
        try? session.setActive(true)
    }

    private func urls(for names: [String]) -> [URL] {
        names.compactMap { Bundle.main.url(forResource: $0, withExtension: "mp3") }
    }

    // MARK: spray loop

    func setSpraying(_ on: Bool) {
        if on {
            guard sprayPlayer?.isPlaying != true, let url = sprayURLs.randomElement() else { return }
            sprayPlayer = try? AVAudioPlayer(contentsOf: url)
            sprayPlayer?.numberOfLoops = -1
            sprayPlayer?.volume = 0.9
            sprayPlayer?.play()
        } else {
            sprayPlayer?.stop()
            sprayPlayer = nil
        }
    }

    // MARK: shake detection (CoreMotion — works even mid-spray)

    private func startShakeDetection() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] dm, _ in
            guard let self, let dm = dm else { return }
            let a = dm.userAcceleration
            let mag = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
            let now = ProcessInfo.processInfo.systemUptime
            if mag > 1.6 {
                self.shakeHits.append(now)
                self.shakeHits.removeAll { now - $0 > 0.7 }
                if self.shakeHits.count >= 3, now - self.lastShakePlay > 1.1 {
                    self.lastShakePlay = now
                    self.shakeHits.removeAll()
                    self.playShake()
                }
            }
        }
    }

    private func playShake() {
        guard let url = shakeURLs.randomElement() else { return }
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.volume = 1.0
        p.play()
        oneShots.append(p)
        oneShots.removeAll { !$0.isPlaying && $0 !== p }
    }
}
