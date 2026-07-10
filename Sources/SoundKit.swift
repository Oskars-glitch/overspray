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

    func setup() {
        reassertSession()
        sprayURLs = urls(for: ["spray_01", "spray_02", "spray_03", "spray"])
        shakeURLs = urls(for: ["shake_01", "shake_02", "shake_03", "shake", "skahe"])
        echoURLs = urls(for: ["shake_echo_01", "shake_echo_02", "shake_echo_03", "shake_echo"])
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

    /// Dotted-line mode: mute in the gaps without restarting the loop,
    /// so the sound resumes seamlessly on each sprayed segment.
    func setSprayMuted(_ muted: Bool) {
        sprayPlayer?.volume = muted ? 0 : 0.9
    }

    // MARK: shake detection (CoreMotion — works even mid-spray)
    // Two tiers: hard shakes play full volume, gentle rattles play at 50%.
    // While shaking continues, a new random variant chains on immediately —
    // so continuous shaking sounds like a continuous rattle, never a loop.

    private var strongHits: [TimeInterval] = []
    private var softHits: [TimeInterval] = []
    private var currentShake: AVAudioPlayer?
    private var echoURLs: [URL] = []
    private var shakingWasActive = false
    private var lastShakeVolume: Float = 1.0

    private func startShakeDetection() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] dm, _ in
            guard let self, let dm = dm else { return }
            let a = dm.userAcceleration
            let mag = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
            let now = ProcessInfo.processInfo.systemUptime
            if mag > 1.5 { self.strongHits.append(now) }
            else if mag > 0.7 { self.softHits.append(now) }
            self.strongHits.removeAll { now - $0 > 0.5 }
            self.softHits.removeAll { now - $0 > 0.5 }
            let strong = self.strongHits.count >= 2
            let soft = self.softHits.count >= 2
            let active = strong || soft
            if active, self.currentShake?.isPlaying != true {
                self.playShake(volume: strong ? 1.0 : 0.5)
                CanPhysics.shared.shaken(strong: strong)
            }
            // shaking just STOPPED → play a fading echo tail so it never cuts flat
            if self.shakingWasActive, !active, self.currentShake?.isPlaying != true {
                self.playEcho()
            }
            self.shakingWasActive = active || self.currentShake?.isPlaying == true
        }
    }

    private func playEcho() {
        guard shakingWasActive else { return }
        shakingWasActive = false
        guard let url = echoURLs.randomElement() else { return }
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.volume = lastShakeVolume
        p.play()
        oneShots.append(p)
        oneShots.removeAll { !$0.isPlaying && $0 !== p }
    }

    private var lastShakeIndex = -1

    private func playShake(volume: Float) {
        guard !shakeURLs.isEmpty else { return }
        // always switch to a DIFFERENT variant, even mid continuous shaking
        var idx = Int.random(in: 0..<shakeURLs.count)
        if shakeURLs.count > 1, idx == lastShakeIndex {
            idx = (idx + 1 + Int.random(in: 0..<(shakeURLs.count - 1))) % shakeURLs.count
        }
        lastShakeIndex = idx
        lastShakeVolume = volume
        guard let p = try? AVAudioPlayer(contentsOf: shakeURLs[idx]) else { return }
        p.volume = volume
        p.play()
        currentShake = p
        oneShots.append(p)
        oneShots.removeAll { !$0.isPlaying && $0 !== p }
    }
}
