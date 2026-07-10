import UIKit
import ARKit
import AVFoundation
import AVKit
import MediaPlayer
import Photos

// MARK: - Recorder: camera + paint video WITH ambient microphone sound

final class Recorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private var writer: AVAssetWriter?
    private var captureSession: AVCaptureSession?
    private let audioQueue = DispatchQueue(label: "overspray.mic")
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var displayLink: CADisplayLink?
    private weak var view: ARSCNView?
    private weak var state: PaintState?
    private var startHostTime: CFTimeInterval = 0
    private var size = CGSize.zero
    private(set) var isRecording = false

    func start(view: ARSCNView, state: PaintState, completion: @escaping (Bool) -> Void) {
        guard !isRecording else { completion(false); return }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                self.begin(view: view, state: state, mic: granted)
                if !granted { state.showToast("Recording without sound — allow the microphone in Settings") }
                completion(true)
            }
        }
    }

    private func begin(view: ARSCNView, state: PaintState, mic: Bool) {
        self.view = view
        self.state = state
        SoundKit.shared.reassertSession()
        let scale = min(UIScreen.main.scale, 2)
        size = CGSize(width: (view.bounds.width * scale).rounded(.down),
                      height: (view.bounds.height * scale).rounded(.down))
        size.width -= size.width.truncatingRemainder(dividingBy: 2)
        size.height -= size.height.truncatingRemainder(dividingBy: 2)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("overspray-\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: url)
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }

        let vSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000],
        ]
        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
        vi.expectsMediaDataInRealTime = true
        let ad = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vi,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ])
        w.add(vi)

        // ambient sound from the microphone (buffers arrive via ARKit)
        let aSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ]
        let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
        ai.expectsMediaDataInRealTime = true
        if w.canAdd(ai) { w.add(ai); audioInput = ai }

        writer = w; videoInput = vi; adaptor = ad
        w.startWriting()
        // host-clock timeline so mic sample buffers line up with our video frames
        startHostTime = CACurrentMediaTime()
        w.startSession(atSourceTime: CMTime(seconds: startHostTime, preferredTimescale: 600))
        isRecording = true

        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFramesPerSecond = 30
        link.add(to: .main, forMode: .common)
        displayLink = link

        if mic { startMic() }
    }

    /// The mic runs on its OWN capture session, fully independent of ARKit —
    /// starting a recording never touches (or freezes) the AR camera.
    private func startMic() {
        let cap = AVCaptureSession()
        guard let dev = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: dev),
              cap.canAddInput(input) else { return }
        cap.addInput(input)
        let out = AVCaptureAudioDataOutput()
        out.setSampleBufferDelegate(self, queue: audioQueue)
        if cap.canAddOutput(out) { cap.addOutput(out) }
        captureSession = cap
        audioQueue.async { cap.startRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard isRecording, let ai = audioInput, ai.isReadyForMoreMediaData else { return }
        ai.append(sampleBuffer)
    }

    @objc private func tick() {
        guard isRecording, let view = view, let vi = videoInput, let adaptor = adaptor,
              vi.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
        let now = CACurrentMediaTime()
        DispatchQueue.main.async { self.state?.recordSeconds = Int(now - self.startHostTime) }

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
        adaptor.append(buffer, withPresentationTime: CMTime(seconds: now, preferredTimescale: 600))
    }

    func stop(completion: @escaping (URL?) -> Void) {
        guard isRecording, let writer = writer, let vi = videoInput else { completion(nil); return }
        isRecording = false
        displayLink?.invalidate(); displayLink = nil
        captureSession?.stopRunning()
        captureSession = nil
        vi.markAsFinished()
        audioInput?.markAsFinished()
        let url = writer.outputURL
        writer.finishWriting {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else { completion(nil); return }
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }) { ok, _ in completion(ok ? url : nil) }
            }
        }
        self.writer = nil; self.videoInput = nil; self.audioInput = nil; self.adaptor = nil
    }
}

// MARK: - VolumeSpray: hold volume-down to spray (unchanged behaviour)

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
        let vv = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))
        vv.alpha = 0.01
        view.addSubview(vv)
        volumeView = vv

        let session = AVAudioSession.sharedInstance()
        observation = session.observe(\.outputVolume, options: [.new, .old]) { [weak self] _, change in
            guard let self, !self.suppressObservation else { return }
            guard let new = change.newValue, let old = change.oldValue, new != old else { return }
            self.pulse(up: new > old)   // volume-UP sprays white, DOWN sprays black
        }
        if #available(iOS 17.2, *) {
            let interaction = AVCaptureEventInteraction(
                primary: { [weak self] event in self?.captureEvent(event) },
                secondary: { [weak self] event in self?.captureEvent(event) })
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

    private func setColor(white: Bool) {
        DispatchQueue.main.async { self.state?.colorIndex = white ? 1 : 0 }
    }

    private func pulse(up: Bool) {
        setColor(white: up)
        setHolding(true)
        releaseTimer?.invalidate()
        releaseTimer = Timer.scheduledTimer(withTimeInterval: 0.30, repeats: false) { [weak self] _ in
            self?.setHolding(false)
        }
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
        DispatchQueue.main.async {
            self.state?.spraying = on
            SoundKit.shared.setSpraying(on)   // instant audio, no frame of delay
        }
    }
}
