import UIKit
import ARKit
import AVFoundation
import MediaPlayer
import Photos

// MARK: - Recorder: captures camera + paint (no UI) into a video in Photos

final class Recorder {
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var displayLink: CADisplayLink?
    private weak var view: ARSCNView?
    private weak var state: PaintState?
    private var startTime: CFTimeInterval = 0
    private var size = CGSize.zero
    private(set) var isRecording = false

    func start(view: ARSCNView, state: PaintState) {
        guard !isRecording else { return }
        self.view = view
        self.state = state
        let scale = min(UIScreen.main.scale, 2)
        size = CGSize(width: (view.bounds.width * scale).rounded(.down),
                      height: (view.bounds.height * scale).rounded(.down))
        // even dimensions for H.264
        size.width -= size.width.truncatingRemainder(dividingBy: 2)
        size.height -= size.height.truncatingRemainder(dividingBy: 2)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("overspray-\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: url)
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000],
        ]
        let inp = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        inp.expectsMediaDataInRealTime = true
        let ad = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: inp,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ])
        w.add(inp)
        writer = w; input = inp; adaptor = ad
        w.startWriting()
        w.startSession(atSourceTime: .zero)
        startTime = CACurrentMediaTime()
        isRecording = true

        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFramesPerSecond = 30
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick() {
        guard isRecording, let view = view, let input = input, let adaptor = adaptor,
              input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
        let elapsed = CACurrentMediaTime() - startTime
        DispatchQueue.main.async { self.state?.recordSeconds = Int(elapsed) }

        // snapshot renders camera feed + SceneKit paint, but NOT the UIKit/SwiftUI overlay
        let image = view.snapshot()
        guard let cg = image.cgImage else { return }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let buffer = pb else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                               width: Int(size.width), height: Int(size.height),
                               bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                                   | CGImageAlphaInfo.premultipliedFirst.rawValue) {
            ctx.draw(cg, in: CGRect(origin: .zero, size: size))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let t = CMTime(seconds: elapsed, preferredTimescale: 600)
        adaptor.append(buffer, withPresentationTime: t)
    }

    func stop(completion: @escaping (URL?) -> Void) {
        guard isRecording, let writer = writer, let input = input else { completion(nil); return }
        isRecording = false
        displayLink?.invalidate(); displayLink = nil
        input.markAsFinished()
        let url = writer.outputURL
        writer.finishWriting {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else { completion(nil); return }
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }) { ok, _ in completion(ok ? url : nil) }
            }
        }
        self.writer = nil; self.input = nil; self.adaptor = nil
    }
}

// MARK: - VolumeSpray: hold volume-down to spray

/// Two mechanisms, best available wins:
/// 1. iOS 17.2+ AVCaptureEventInteraction (Apple's official camera-button API)
/// 2. Classic fallback: observe system volume changes; holding volume-down
///    fires repeated changes → treated as "holding". A hidden MPVolumeView
///    suppresses the system volume HUD and lets us reset the level so the
///    button never bottoms out.
final class VolumeSpray: NSObject {
    static let shared = VolumeSpray()
    private(set) var holding = false
    private weak var state: PaintState?
    private var volumeView: MPVolumeView?
    private var observation: NSKeyValueObservation?
    private var resetWorkItem: DispatchWorkItem?
    private var releaseTimer: Timer?
    private var suppressObservation = false

    func attach(to view: UIView, state: PaintState) {
        self.state = state

        // hidden volume view keeps the system HUD away
        let vv = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))
        vv.alpha = 0.01
        view.addSubview(vv)
        volumeView = vv

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, options: [.mixWithOthers])
        try? session.setActive(true)
        observation = session.observe(\.outputVolume, options: [.new, .old]) { [weak self] _, change in
            guard let self, !self.suppressObservation else { return }
            guard let new = change.newValue, let old = change.oldValue, new <= old else { return }
            self.pulse()
        }

        // official camera-button API where available
        if #available(iOS 17.2, *) {
            let interaction = AVCaptureEventInteraction(
                primary: { [weak self] event in self?.captureEvent(event) },
                secondary: { [weak self] event in self?.captureEvent(event) })
            interaction.isEnabled = true
            view.addInteraction(interaction)
        }
    }

    @available(iOS 17.2, *)
    private func captureEvent(_ event: AVCaptureEvent) {
        switch event.phase {
        case .began: setHolding(true)
        case .ended, .cancelled: setHolding(false)
        @unknown default: break
        }
    }

    /// A volume-down change arrived: hold spraying until changes stop coming.
    private func pulse() {
        setHolding(true)
        releaseTimer?.invalidate()
        releaseTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            self?.setHolding(false)
        }
        // nudge the volume back up so holding the button keeps producing events
        resetWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let slider = self.volumeView?.subviews
                .compactMap({ $0 as? UISlider }).first else { return }
            self.suppressObservation = true
            slider.value = 0.5
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self.suppressObservation = false }
        }
        resetWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func setHolding(_ on: Bool) {
        guard holding != on else { return }
        holding = on
        DispatchQueue.main.async { self.state?.spraying = on }
    }
}
