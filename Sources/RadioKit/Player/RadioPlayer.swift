#if canImport(AVFoundation)
import Foundation
import AVFoundation
import MediaPlayer
import Accelerate
import Combine

/// What the music is doing *right now*, measured from the actual output
/// buffers — not simulated. Every field is auto-gained to 0…1 against a
/// slow-decaying running peak, so visuals behave across quiet and loud
/// masters without hand tuning.
public struct AudioLevels: Sendable, Equatable {
    public var rms: Float
    public var bass: Float    // < 150 Hz — kicks, 808s
    public var mid: Float     // 150 Hz – 2 kHz — voice, snare body
    public var treble: Float  // > 2 kHz — hats, air

    public static let zero = AudioLevels(rms: 0, bass: 0, mid: 0, treble: 0)

    public init(rms: Float, bass: Float, mid: Float, treble: Float) {
        self.rms = rms
        self.bass = bass
        self.mid = mid
        self.treble = treble
    }
}

/// Plays the live stream through `AVAudioEngine` (not AVPlayer) so a tap on
/// the mixer feeds real per-frame loudness + band energy to the UI, and
/// keeps the system Now Playing surfaces — lock screen, Control Center, and
/// the **CarPlay Now Playing template** — in sync.
///
/// The one interactive affordance we expose in-car is the system
/// `likeCommand`, surfaced by CarPlay as a Now Playing button and reachable
/// by Siri ("I like this"). We map it to **boost current track**. All richer
/// voting stays on the phone.
@MainActor
public final class RadioPlayer: ObservableObject {

    @Published public private(set) var isPlaying = false
    /// Live measurement of the actual audio, ~30 Hz. `.zero` when paused.
    @Published public private(set) var levels: AudioLevels = .zero

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let analyzer = SpectrumAnalyzer()

    private var stream: LiveStreamService
    private var cancellables: Set<AnyCancellable> = []
    private var currentFormat: AVAudioFormat?
    private var tapInstalled = false
    private var lastPublish = Date.distantPast

    public init(stream: LiveStreamService) {
        self.stream = stream
        engine.attach(node)
        configureAudioSession()
        configureRemoteCommands()
        attach(to: stream)
    }

    /// Retune to another station's stream. Stations are always-on — the old
    /// stream keeps running for everyone else; this device just points its
    /// player (and the system Now Playing surfaces) at a different one.
    public func attach(to stream: LiveStreamService) {
        cancellables.removeAll()
        self.stream = stream

        stream.$nowPlaying
            .compactMap { $0 }
            .sink { [weak self] np in self?.load(np) }
            .store(in: &cancellables)

        if let np = stream.nowPlaying { load(np) }
    }

    public func play() {
        stream.start()
        // Radio, not a podcast: joining or resuming drops you at the *live*
        // second, never where you left off.
        isPlaying = true
        if let np = stream.nowPlaying { load(np) } else { startEngineIfNeeded() }
        refreshNowPlayingInfo()
    }

    public func pause() {
        node.pause()
        isPlaying = false
        levels = .zero
        refreshNowPlayingInfo()
    }

    public func toggle() { isPlaying ? pause() : play() }

    // MARK: - Scheduling

    /// Open the track's asset and schedule it from the live edge.
    private func load(_ np: NowPlaying) {
        guard let url = np.track.assetURL else {
            node.stop()
            refreshNowPlayingInfo()
            return
        }
        do {
            let file = try AVAudioFile(forReading: url)
            reconnectIfNeeded(format: file.processingFormat)

            let sampleRate = file.processingFormat.sampleRate
            let elapsed = np.elapsed(at: Date())
            let startFrame = AVAudioFramePosition(max(0, elapsed - 0.05) * sampleRate)
            let remaining = file.length - startFrame
            guard remaining > 0 else { return }

            node.stop()
            node.scheduleSegment(
                file,
                startingFrame: startFrame,
                frameCount: AVAudioFrameCount(remaining),
                at: nil
            )
            if isPlaying {
                startEngineIfNeeded()
                node.play()
            }
        } catch {
            // A bad asset must never kill the station — stay silent until
            // the stream advances past it.
            node.stop()
        }
        refreshNowPlayingInfo()
    }

    private func reconnectIfNeeded(format: AVAudioFormat) {
        guard currentFormat?.sampleRate != format.sampleRate
            || currentFormat?.channelCount != format.channelCount else { return }
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        currentFormat = format
    }

    private func startEngineIfNeeded() {
        installTapIfNeeded()
        guard !engine.isRunning else { return }
        engine.prepare()
        try? engine.start()
    }

    /// The tap runs on an audio thread: analysis is allocation-free, and
    /// results hop to the main actor at ~30 Hz.
    private func installTapIfNeeded() {
        guard !tapInstalled else { return }
        tapInstalled = true
        let analyzer = self.analyzer
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self,
                  let channel = buffer.floatChannelData?[0] else { return }
            let levels = analyzer.analyze(
                channel,
                count: Int(buffer.frameLength),
                sampleRate: buffer.format.sampleRate
            )
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }
                guard Date().timeIntervalSince(self.lastPublish) > 1.0 / 30 else { return }
                self.lastPublish = Date()
                self.levels = levels
            }
        }
    }

    // MARK: - System integration

    private func configureAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        #endif
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            self?.play(); return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause(); return .success
        }
        // Skip is intentionally *not* wired to a user "next" — this is radio,
        // not on-demand. We leave nextTrackCommand disabled so listeners can't
        // hand-pick the next song (which would make the stream interactive
        // under the statutory license). Boost is the lever instead.
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false

        // The in-car "boost" affordance.
        center.likeCommand.isEnabled = true
        center.likeCommand.localizedTitle = "Boost"
        center.likeCommand.addTarget { [weak self] _ in
            self?.stream.boostCurrent()
            self?.refreshNowPlayingInfo()
            return .success
        }
    }

    /// Push current-track metadata (and live boost score) to the system.
    public func refreshNowPlayingInfo() {
        guard let np = stream.nowPlaying else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: np.track.title,
            MPMediaItemPropertyArtist: np.track.artistName,
            MPMediaItemPropertyPlaybackDuration: np.track.durationSeconds,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: np.elapsed(at: Date()),
            MPNowPlayingInfoPropertyIsLiveStream: true,
        ]
        if let album = np.track.albumTitle {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }
}

// MARK: - Spectrum analysis

/// Allocation-free FFT band analysis, safe to call from the audio thread.
/// Auto-gain: each band divides by its own slow-decaying running peak, so
/// output is always a useful 0…1 regardless of master loudness.
final class SpectrumAnalyzer: @unchecked Sendable {
    private let n = 1024
    private let log2n = vDSP_Length(10)
    private let fftSetup: FFTSetup?
    private var window = [Float](repeating: 0, count: 1024)
    private var windowed = [Float](repeating: 0, count: 1024)
    private var realp = [Float](repeating: 0, count: 512)
    private var imagp = [Float](repeating: 0, count: 512)
    private var mags = [Float](repeating: 0, count: 512)

    // Running peaks for auto-gain (audio thread only — single consumer).
    private var peakRMS: Float = 0.05
    private var peakBass: Float = 1
    private var peakMid: Float = 1
    private var peakTreble: Float = 1

    init() {
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    }

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    func analyze(_ samples: UnsafePointer<Float>, count: Int, sampleRate: Double) -> AudioLevels {
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))

        guard count >= n, let fftSetup else {
            let g = gained(rms: rms)
            return AudioLevels(rms: g, bass: g, mid: g, treble: g)
        }

        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))
        windowed.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { complexPtr in
                realp.withUnsafeMutableBufferPointer { rp in
                    imagp.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(n / 2))
                        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n / 2))
                    }
                }
            }
        }

        let binHz = sampleRate / Double(n)
        let bass = bandPower(fromHz: 20, toHz: 150, binHz: binHz)
        let mid = bandPower(fromHz: 150, toHz: 2_000, binHz: binHz)
        let treble = bandPower(fromHz: 2_000, toHz: 12_000, binHz: binHz)

        peakBass = max(bass, peakBass * 0.998)
        peakMid = max(mid, peakMid * 0.998)
        peakTreble = max(treble, peakTreble * 0.998)

        return AudioLevels(
            rms: gained(rms: rms),
            bass: min(1, bass / max(peakBass, .ulpOfOne)),
            mid: min(1, mid / max(peakMid, .ulpOfOne)),
            treble: min(1, treble / max(peakTreble, .ulpOfOne))
        )
    }

    private func gained(rms: Float) -> Float {
        peakRMS = max(rms, peakRMS * 0.998)
        return min(1, rms / max(peakRMS, .ulpOfOne))
    }

    private func bandPower(fromHz lo: Double, toHz hi: Double, binHz: Double) -> Float {
        let a = max(1, Int(lo / binHz))
        let b = min(mags.count - 1, Int(hi / binHz))
        guard b >= a else { return 0 }
        var sum: Float = 0
        mags.withUnsafeBufferPointer { ptr in
            vDSP_sve(ptr.baseAddress! + a, 1, &sum, vDSP_Length(b - a + 1))
        }
        return sqrt(sum / Float(b - a + 1))
    }
}
#endif
