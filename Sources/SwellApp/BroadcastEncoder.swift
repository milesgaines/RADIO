import Foundation
import AVFoundation
import CoreMedia
import UniformTypeIdentifiers

/// Turns the live microphone into an **Apple-HLS byte stream, on the phone**.
///
/// There is no ffmpeg on the device and no media server behind us — so the
/// segmentation happens right here: `AVCaptureSession` pulls the mic,
/// `AVAssetWriter` (in its URL-less, content-type initializer) is told to
/// author `.mpeg4AppleHLS`, and its delegate hands us each fragmented-MP4
/// segment as raw `Data` the instant it closes. We never touch the disk; the
/// bytes go straight to `BroadcastService` for upload.
///
/// The shape of what comes out:
///   • exactly one **initialization** segment (ftyp+moov) — the `EXT-X-MAP`.
///   • then a **media** segment (moof+mdat) every `segmentSeconds`, each with
///     the real duration measured off its `AVAssetSegmentReport`.
///
/// Voice only, mono AAC — a talk stream, not a music bed. Feedback is the
/// enemy, so `BroadcastService` pauses the radio and owns the session while
/// this runs.
protocol BroadcastEncoderDelegate: AnyObject {
    /// The one fMP4 initialization segment. Upload as `init.mp4`; it is the
    /// playlist's `EXT-X-MAP` and every media segment depends on it.
    func encoder(_ encoder: BroadcastEncoder, didProduceInitialization data: Data)
    /// A media segment closed. `sequence` is monotonic from 0; `duration` is
    /// the true segment length for its `#EXTINF`.
    func encoder(_ encoder: BroadcastEncoder, didProduceSegment data: Data, sequence: Int, duration: Double)
    /// Mic loudness, 0…1, ~10 Hz — drives the console's ON AIR meter.
    func encoder(_ encoder: BroadcastEncoder, micLevel level: Float)
    /// Terminal: capture never started, or the writer failed mid-show.
    func encoder(_ encoder: BroadcastEncoder, didFailWith message: String)
}

/// Audio-only HLS segmenter. Not `@MainActor`: capture and the writer live on
/// their own serial queue; only delegate hops are marshalled by the owner.
final class BroadcastEncoder: NSObject {

    weak var delegate: BroadcastEncoderDelegate?

    /// Where the audio comes from. `.microphone` is the original talk-stream
    /// path (AVCaptureSession, mono). `.mixedFeed` is DJ MODE: the caller
    /// pushes the engine's rendered program (music + mic) in as PCM via
    /// `appendMixed`, and no capture session exists — which also means the
    /// mixed path runs fine in the simulator.
    enum Source { case microphone, mixedFeed }
    private(set) var source: Source = .microphone

    /// ~4 s balances tune-in latency against segment/CDN overhead. The
    /// playlist's `TARGETDURATION` is derived from the segments we actually
    /// emit, never assumed from this.
    let segmentSeconds: Double

    private let session = AVCaptureSession()
    private let audioOut = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "radi0.broadcast.encoder")

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var sessionStartedAtSource = false
    private var nextSequence = 0
    private var failed = false
    private var lastLevelPublish = Date.distantPast
    /// Cached CMAudioFormatDescription for the mixed feed's PCM format —
    /// rebuilt only if the format changes. TOUCHED ONLY ON THE AUDIO THREAD
    /// (makeSampleBuffer); never cleared from the encoder queue.
    private var mixedFormatDescription: CMAudioFormatDescription?
    private var mixedFormatASBD = AudioStreamBasicDescription()
    /// Monotonic PTS counter in frames — immune to engine-restart clock resets.
    private var nextPTSFrames: CMTimeValue = 0

    init(segmentSeconds: Double = 4) {
        self.segmentSeconds = segmentSeconds
        super.init()
    }

    // MARK: - Lifecycle

    /// Wire the capture graph and the HLS writer, then start pulling the mic.
    /// Safe to call once; call `stop()` before starting again.
    func start() {
        queue.async { [weak self] in
            self?.source = .microphone
            self?.startOnQueue()
        }
    }

    /// DJ MODE: author the HLS stream from an externally-rendered PCM feed
    /// (the engine's main mix). Stereo AAC — this is a music bed, not a talk
    /// stream. `channels`/`sampleRate` should describe the feed.
    func startMixed(sampleRate: Double, channels: Int) {
        queue.async { [weak self] in
            guard let self, self.writer == nil else { return }
            self.source = .mixedFeed
            self.failed = false
            self.nextPTSFrames = 0   // fresh show ⇒ fresh timeline at zero
            do {
                try self.configureWriter(
                    sampleRate: sampleRate > 0 ? sampleRate : 44_100,
                    channels: max(1, min(2, channels)),
                    bitRate: 128_000)
            } catch {
                self.fail("ENCODER FAILED")
            }
        }
    }

    /// Push one rendered PCM buffer from the engine's broadcast tap. CALLED ON
    /// THE AUDIO THREAD: the conversion below copies the samples into a
    /// CMSampleBuffer (CMSampleBufferSetDataBufferFromAudioBufferList copies),
    /// so the tap's reusable buffer is never referenced after return.
    func appendMixed(_ pcm: AVAudioPCMBuffer, at when: AVAudioTime) {
        guard source == .mixedFeed, let sample = makeSampleBuffer(from: pcm) else { return }
        queue.async { [weak self] in
            guard let self, let writer = self.writer, let input = self.input else { return }
            // A writer that fails mid-show must not silently swallow the rest
            // of the broadcast — surface it so the show ends honestly.
            if writer.status == .failed {
                self.fail("ENCODER STOPPED")
                return
            }
            guard writer.status == .writing else { return }
            if !self.sessionStartedAtSource {
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sample))
                self.sessionStartedAtSource = true
            }
            if input.isReadyForMoreMediaData {
                input.append(sample)
            }
        }
    }

    /// PCM → CMSampleBuffer, copying the payload. Realtime-safe enough for a
    /// ~10 Hz tap cadence (allocation, no locks held elsewhere).
    ///
    /// TIMESTAMPS: the PTS is a MONOTONIC frame counter owned by the encoder,
    /// not the tap's `AVAudioTime.sampleTime`. An engine stop/restart mid-show
    /// (sample-rate-boundary reconnect, route change) resets the render clock
    /// to ~0, and feeding that backwards to AVAssetWriter kills the session and
    /// freezes the stream. Counting frames we actually appended keeps fMP4
    /// gapless across every restart.
    private func makeSampleBuffer(from pcm: AVAudioPCMBuffer) -> CMSampleBuffer? {
        let frames = CMItemCount(pcm.frameLength)
        guard frames > 0 else { return nil }
        let asbd = pcm.format.streamDescription.pointee
        let rate = Int32(pcm.format.sampleRate)
        guard rate > 0 else { return nil }

        // The cached format description is touched ONLY here, on the audio
        // thread — teardown no longer clears it (that was a cross-thread
        // CF store/load race); a fresh startMixed resets it on this thread
        // via the sampleRate/flags comparison below.
        if mixedFormatDescription == nil
            || mixedFormatASBD.mSampleRate != asbd.mSampleRate
            || mixedFormatASBD.mChannelsPerFrame != asbd.mChannelsPerFrame
            || mixedFormatASBD.mFormatFlags != asbd.mFormatFlags {
            var desc: CMAudioFormatDescription?
            var mutableASBD = asbd
            guard CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &mutableASBD,
                layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                extensions: nil, formatDescriptionOut: &desc) == noErr, let desc else { return nil }
            mixedFormatDescription = desc
            mixedFormatASBD = asbd
            nextPTSFrames = 0   // new format ⇒ new timeline
        }
        guard let format = mixedFormatDescription else { return nil }

        let pts = CMTime(value: nextPTSFrames, timescale: rate)
        nextPTSFrames += CMTimeValue(frames)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: rate),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid)

        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil,
            formatDescription: format, sampleCount: frames,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sample) == noErr, let sample else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sample, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: pcm.audioBufferList) == noErr else { return nil }
        return sample
    }

    private func startOnQueue() {
        guard writer == nil else { return }
        #if targetEnvironment(simulator)
        // The simulator has no capture-grade audio device; fail honestly
        // rather than pretend to broadcast silence.
        fail("BROADCASTING NEEDS A REAL DEVICE")
        return
        #else
        guard let device = AVCaptureDevice.default(for: .audio),
              let deviceInput = try? AVCaptureDeviceInput(device: device) else {
            fail("NO MIC")
            return
        }
        // BroadcastService owns the audio session (it pauses the radio and
        // sets .playAndRecord); the capture session must not stomp that.
        session.automaticallyConfiguresApplicationAudioSession = false
        session.beginConfiguration()
        guard session.canAddInput(deviceInput) else { session.commitConfiguration(); fail("MIC BUSY"); return }
        session.addInput(deviceInput)
        audioOut.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(audioOut) else { session.commitConfiguration(); fail("MIC BUSY"); return }
        session.addOutput(audioOut)
        session.commitConfiguration()

        do {
            try configureWriter(sampleRate: 44_100, channels: 1, bitRate: 96_000)
        } catch {
            fail("ENCODER FAILED")
            return
        }
        session.startRunning()
        #endif
    }

    private func configureWriter(sampleRate: Double, channels: Int, bitRate: Int) throws {
        // The URL-less initializer is the segment-authoring path: no output
        // file, segments arrive via the delegate instead.
        let writer = try AVAssetWriter(contentType: UTType.mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: segmentSeconds, preferredTimescale: 1)
        // Start media time at zero so the first segment's timing is clean.
        writer.initialSegmentStartTime = .zero
        writer.delegate = self

        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitRate,
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw EncoderError.setup }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? EncoderError.setup }

        self.writer = writer
        self.input = input
    }

    /// Stop capture and finalize. The delegate may still deliver the trailing
    /// segment; `onFinished` fires once the writer has fully drained so the
    /// caller can publish the closing playlist in the right order.
    func stop(onFinished: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { onFinished?(); return }
            if self.session.isRunning { self.session.stopRunning() }
            guard let writer = self.writer, let input = self.input, writer.status == .writing else {
                self.teardown()
                onFinished?()
                return
            }
            input.markAsFinished()
            writer.finishWriting { [weak self] in
                self?.teardown()
                onFinished?()
            }
        }
    }

    private func teardown() {
        writer = nil
        input = nil
        sessionStartedAtSource = false
        nextSequence = 0
        failed = false
        // mixedFormatDescription is owned by the audio thread — clearing it
        // here would be an unsynchronized CF store. startMixed resets the
        // PTS timeline instead; the description reconciles on first buffer.
    }

    private func fail(_ message: String) {
        guard !failed else { return }
        failed = true
        let d = delegate
        DispatchQueue.main.async { d?.encoder(self, didFailWith: message) }
    }

    enum EncoderError: Error { case setup }
}

// MARK: - Capture → writer

extension BroadcastEncoder: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let writer, let input, writer.status == .writing else { return }

        // Open the session at the first real sample's timestamp — appending
        // before startSession(atSourceTime:) drops the buffer on the floor.
        if !sessionStartedAtSource {
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            sessionStartedAtSource = true
        }
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
        publishLevel(from: connection)
    }

    /// The mic's own metering — no PCM parsing needed. dBFS → 0…1.
    private func publishLevel(from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastLevelPublish) > 0.1,
              let channel = connection.audioChannels.first else { return }
        lastLevelPublish = now
        let db = channel.averagePowerLevel                 // ~ -160…0 dBFS
        let level = max(0, min(1, (db + 50) / 50))          // floor at -50 dB
        let d = delegate
        DispatchQueue.main.async { d?.encoder(self, micLevel: level) }
    }
}

// MARK: - HLS segments out

extension BroadcastEncoder: AVAssetWriterDelegate {
    func assetWriter(_ writer: AVAssetWriter,
                     didOutputSegmentData segmentData: Data,
                     segmentType: AVAssetSegmentType,
                     segmentReport: AVAssetSegmentReport?) {
        switch segmentType {
        case .initialization:
            let d = delegate
            DispatchQueue.main.async { d?.encoder(self, didProduceInitialization: segmentData) }
        case .separable:
            let seq = nextSequence
            nextSequence += 1
            // Real duration off the report; fall back to the nominal interval
            // if the report is ever absent (it shouldn't be).
            let reported = segmentReport?.trackReports.first?.duration.seconds
            let duration = (reported.map { $0.isFinite && $0 > 0 ? $0 : segmentSeconds }) ?? segmentSeconds
            let d = delegate
            DispatchQueue.main.async { d?.encoder(self, didProduceSegment: segmentData, sequence: seq, duration: duration) }
        @unknown default:
            break
        }
    }
}
