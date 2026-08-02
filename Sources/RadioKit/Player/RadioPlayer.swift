#if canImport(AVFoundation)
import Foundation
import AVFoundation
import MediaPlayer
import MediaToolbox
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

    // var, not let: a media-services reset kills the engine and it must be
    // rebuilt from scratch (Apple's documented recovery path).
    private var engine = AVAudioEngine()
    private var node = AVAudioPlayerNode()
    private let analyzer = SpectrumAnalyzer()

    // MARK: Sound modes
    //
    // The local chain gets real tonal DSP: node → eq → musicMixer → main.
    // The analysis tap lives on musicMixer (music only), so the ambience node
    // — a second player looping crackle/hiss straight into the main mixer —
    // colours every path (local, stream, live) without polluting the meter.
    private var eq = AVAudioUnitEQ(numberOfBands: 4)
    private var musicMixer = AVAudioMixerNode()
    /// Wow & flutter — the pitch instability that separates tape and vinyl from
    /// clean digital, and the single most "real" cue the modes were missing. A
    /// TimePitch node on the music mix, its `pitch` nudged a few cents by a slow
    /// LFO. Pitch only, so the track's length (and the shared clock) never move.
    /// SPATIAL holds it dead flat.
    private var wowFlutter = AVAudioUnitTimePitch()
    private var wowTimer: Timer?
    private var wowStart = Date()
    // MARK: Spatial (real 3D)
    //
    // SPATIAL is genuine HRTF binaural rendering, not a marketing label. The
    // environment node is the renderer; `spatialSource` is a plain mixer that
    // sits directly on its input BECAUSE the 3D properties (sourceMode,
    // renderingAlgorithm, position, reverbBlend) are read from the node feeding
    // the environment, and that node must conform to `AVAudio3DMixing` —
    // AVAudioMixerNode does, AVAudioUnitTimePitch (wowFlutter) does not. Both
    // stay wired in for every mode; switching modes flips PROPERTIES only
    // (never re-routes a live graph), and `.bypass` makes the pair a
    // transparent wire so vinyl/cassette pass through untouched.
    private var spatialSource = AVAudioMixerNode()
    private var environment = AVAudioEnvironmentNode()
    private var ambience = AVAudioPlayerNode()
    private let ambienceFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    private var ambienceBuffers: [SoundMode: AVAudioPCMBuffer] = [:]
    private static let modeKey = "swell.soundMode"

    /// The current listening mode. Persists across launches.
    @Published public private(set) var mode: SoundMode =
        SoundMode(rawValue: UserDefaults.standard.string(forKey: RadioPlayer.modeKey) ?? "") ?? .hd

    private var stream: LiveStreamService
    private var cancellables: Set<AnyCancellable> = []
    private var currentFormat: AVAudioFormat?
    private var tapInstalled = false
    private var lastPublish = Date.distantPast

    /// Identity of the segment currently scheduled on the node. Votes and
    /// audience churn republish `nowPlaying` without moving the broadcast;
    /// only a new (track, startedAt) pair may touch the audio graph.
    private struct LoadKey: Equatable {
        let trackID: UUID
        let startedAt: Date
    }
    private var loadedKey: LoadKey?

    // MARK: Streaming backend
    //
    // Local files play through AVAudioEngine (sample-accurate seek, mixer
    // tap). Remote tracks STREAM through AVPlayer — audio starts in about a
    // second instead of after a full-file download, which is what makes
    // tune-in feel like turning on a radio — and an audio-mix tap
    // (StreamTapContext) feeds the same live analysis, so the plate
    // breathes identically for both. Live shows are HLS on the same player.
    private var avPlayer: AVPlayer?
    private var driftObserver: Any?
    private var itemStatusObservation: NSKeyValueObservation?
    /// True while a human owns the air (an HLS live show). Rotation clock
    /// updates are ignored until the show ends.
    @Published public private(set) var isLive = false
    public private(set) var liveTitle: String = ""
    private var liveURL: URL?
    private var syntheticLevelsTask: Task<Void, Never>?
    /// AVPlayer currently owns the air (a remote track or a live show).
    private var streamActive: Bool { avPlayer?.currentItem != nil }

    public init(stream: LiveStreamService) {
        self.stream = stream
        attachAudioNodes()
        configureAudioSession()
        configureRemoteCommands()
        observeSystemAudioEvents()
        attach(to: stream)
    }

    /// Attach the music node, the effect chain, the submix, and the ambience
    /// node, and wire the two fixed edges (submix→main, ambience→main). The
    /// music node→eq→submix edge is (re)built per file in reconnectIfNeeded.
    private func attachAudioNodes() {
        engine.attach(node)
        engine.attach(eq)
        engine.attach(musicMixer)
        engine.attach(wowFlutter)
        engine.attach(spatialSource)
        engine.attach(environment)
        engine.attach(ambience)
        // Music runs through the wow/flutter node, then the spatial pair, on its
        // way to the main mix. The analysis tap stays on musicMixer (pre-wobble,
        // pre-spatial), so the plate reads clean levels while the ear hears the
        // waver and the room. The two spatial nodes stay in circuit for every
        // mode; applySpatialMode() bypasses them for vinyl/cassette.
        engine.connect(musicMixer, to: wowFlutter, format: nil)
        engine.connect(wowFlutter, to: spatialSource, format: nil)
        engine.connect(spatialSource, to: environment, format: nil)
        engine.connect(environment, to: engine.mainMixerNode, format: nil)
        engine.connect(ambience, to: engine.mainMixerNode, format: ambienceFormat)
        applyModeEQ()
        applySpatialMode()
    }

    /// Retune to another station's stream. Stations are always-on — the old
    /// stream keeps running for everyone else; this device just points its
    /// player (and the system Now Playing surfaces) at a different one.
    public func attach(to stream: LiveStreamService) {
        cancellables.removeAll()
        self.stream = stream
        // Tuning always releases a live show's grip on the player — the new
        // station's own live state (if any) re-asserts itself via the backend.
        if isLive { isLive = false; liveURL = nil; liveTitle = "" }
        syntheticLevelsTask?.cancel()

        stream.$nowPlaying
            .compactMap { $0 }
            .sink { [weak self] np in
                guard let self, !self.isLive else { return }
                // Reschedule audio only when the broadcast actually moved —
                // every vote and every listener join/leave republishes this
                // struct, and a stop/reschedule per vote is an audible glitch.
                let key = LoadKey(trackID: np.track.id, startedAt: np.startedAt)
                if key != self.loadedKey {
                    self.load(np)
                } else {
                    self.refreshNowPlayingInfo()
                }
            }
            .store(in: &cancellables)

        if let np = stream.nowPlaying { load(np) }
    }

    public func play() {
        stream.start()
        // Radio, not a podcast: joining or resuming drops you at the *live*
        // second, never where you left off.
        isPlaying = true
        if isLive, let url = liveURL {
            goLive(url: url, title: liveTitle) // rejoin the live edge
        } else if let np = stream.nowPlaying {
            load(np)
        } else if !startEngineIfNeeded() {
            isPlaying = false // stay truthful if the session won't activate
        }
        ensureAmbience() // crackle/hiss over whatever path is now live
        startWowFlutter() // and the tape/vinyl waver
        refreshNowPlayingInfo()
    }

    public func pause() {
        node.pause()
        avPlayer?.pause()
        ambience.stop()
        stopWowFlutter()
        isPlaying = false
        levels = .zero
        refreshNowPlayingInfo()
        #if os(iOS)
        // DJ MODE: the engine IS the transmitter. Pausing it (or handing the
        // session back) would kill the live broadcast while the console still
        // read ON AIR. The host stopping the music is not the host going off
        // the air — keep the engine running and keep transmitting.
        guard !djModeActive else { return }
        // Hand the audio session back so Music/podcasts can resume.
        engine.pause()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    public func toggle() { isPlaying ? pause() : play() }

    // MARK: - Scheduling

    /// Open the track's asset and join it at the live edge. Remote assets
    /// STREAM (AVPlayer, progressive HTTP) — tune-in is ~a second; local
    /// bundled files go through the engine (AVAudioFile only reads local).
    private func load(_ np: NowPlaying) {
        loadedKey = LoadKey(trackID: np.track.id, startedAt: np.startedAt)
        guard let url = np.track.assetURL else {
            node.stop()
            avPlayer?.pause()
            refreshNowPlayingInfo()
            return
        }
        if url.scheme == "https" || url.scheme == "http" {
            loadStream(np, from: url)
            refreshDJFeedTruth()   // remote record: it can't reach the feed
            return
        }
        // Back to the engine: the stream player must not keep singing
        // underneath the local file.
        avPlayer?.pause()
        avPlayer?.replaceCurrentItem(with: nil)
        loadLocal(np, from: url)
        refreshDJFeedTruth()       // engine record: music is in the feed again
    }

    /// Stream a remote track from the shared second. An audio-mix tap feeds
    /// the same spectrum analysis local playback gets, so the plate breathes
    /// the actual music either way.
    private func loadStream(_ np: NowPlaying, from url: URL) {
        node.stop() // the engine goes silent; AVPlayer owns the air now
        let key = loadedKey
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let player = avPlayer ?? AVPlayer()
        avPlayer = player
        installDriftCorrector(on: player)

        // A dead stream must never kill the station: reopen the load key
        // after a beat so the next publish (or our own nudge) retries while
        // the song is still on air.
        itemStatusObservation?.invalidate()
        itemStatusObservation = item.observe(\.status) { [weak self] observed, _ in
            guard observed.status == .failed else { return }
            Task { @MainActor [weak self] in
                guard let self, self.loadedKey == key else { return }
                self.loadedKey = nil
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard self.loadedKey == nil,
                      let np2 = self.stream.nowPlaying,
                      np2.track.id == np.track.id else { return }
                self.load(np2)
            }
        }

        Task { @MainActor [weak self] in
            // Attach the FFT tap BEFORE the item goes live — swapping an
            // audioMix mid-playback glitches. (Progressive files only; HLS
            // never vends tap buffers, which goLive covers separately.)
            if let tracks = try? await asset.loadTracks(withMediaType: .audio),
               let track = tracks.first {
                let params = AVMutableAudioMixInputParameters(track: track)
                params.audioTapProcessor = StreamTapContext.makeTap { [weak self] levels in
                    Task { @MainActor [weak self] in
                        guard let self, self.isPlaying else { return }
                        guard Date().timeIntervalSince(self.lastPublish) > 1.0 / 30 else { return }
                        self.lastPublish = Date()
                        self.levels = levels
                    }
                }
                let mix = AVMutableAudioMix()
                mix.inputParameters = [params]
                item.audioMix = mix
            }
            guard let self, self.loadedKey == key else { return } // stale: retuned
            player.replaceCurrentItem(with: item)
            let elapsed = np.elapsed(at: Date())
            if elapsed > 0.05 {
                await item.seek(
                    to: CMTime(seconds: elapsed, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: CMTime(seconds: 0.5, preferredTimescale: 600)
                )
            }
            guard self.loadedKey == key else { return }
            if self.isPlaying {
                if self.activateSession() {
                    player.play()
                } else {
                    // Session refused (phone call, etc.) — the UI must not
                    // claim "playing" over silence.
                    self.isPlaying = false
                    self.levels = .zero
                }
            }
        }
        refreshNowPlayingInfo()
    }

    /// Streams drift: buffering delays the start, stalls pause the playhead.
    /// Every 5s, snap back to the shared second when off by >2s — listeners
    /// must never diverge from "everyone hears the same second".
    private func installDriftCorrector(on player: AVPlayer) {
        guard driftObserver == nil else { return }
        driftObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.correctDrift() }
        }
    }

    private func correctDrift() {
        guard !isLive, isPlaying,
              let player = avPlayer, let item = player.currentItem,
              item.status == .readyToPlay,
              let np = stream.nowPlaying,
              np.track.assetURL?.scheme?.hasPrefix("http") == true else { return }
        let expected = np.elapsed(at: Date())
        guard expected < np.track.durationSeconds - 1 else { return }
        let actual = item.currentTime().seconds
        guard actual.isFinite, abs(actual - expected) > 2 else { return }
        item.seek(
            to: CMTime(seconds: expected, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: CMTime(seconds: 0.5, preferredTimescale: 600),
            completionHandler: nil
        )
    }

    // MARK: - Live shows

    /// A human takes the air: play the HLS stream and freeze rotation
    /// handling until the show ends. HLS never vends audio-mix tap buffers
    /// (an Apple limitation), so the plate breathes on a synthetic low-key
    /// pulse — ambiance, clearly generic, never presented as measurement.
    public func goLive(url: URL, title: String) {
        isLive = true
        liveTitle = title
        liveURL = url
        loadedKey = nil
        node.stop()
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        let player = avPlayer ?? AVPlayer()
        avPlayer = player
        installDriftCorrector(on: player)
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        if isPlaying {
            if activateSession() {
                player.play()
                startSyntheticLiveLevels()
            } else {
                isPlaying = false
                levels = .zero
            }
        }
        refreshNowPlayingInfo()
    }

    /// The show ended: fall back to the rotation clock.
    public func endLive() {
        guard isLive else { return }
        isLive = false
        liveURL = nil
        liveTitle = ""
        syntheticLevelsTask?.cancel()
        syntheticLevelsTask = nil
        avPlayer?.pause()
        avPlayer?.replaceCurrentItem(with: nil)
        if let np = stream.nowPlaying { load(np) }
        refreshNowPlayingInfo()
    }

    private func startSyntheticLiveLevels() {
        syntheticLevelsTask?.cancel()
        syntheticLevelsTask = Task { @MainActor [weak self] in
            let t0 = Date()
            while !Task.isCancelled {
                if let self, self.isLive, self.isPlaying {
                    let t = Date().timeIntervalSince(t0)
                    let breathe = Float(0.5 + 0.5 * sin(t * 1.9))
                    let flutter = Float.random(in: 0...0.15)
                    self.levels = AudioLevels(
                        rms: 0.25 + 0.25 * breathe + flutter,
                        bass: 0.2 + 0.3 * breathe,
                        mid: 0.25 + 0.2 * Float(0.5 + 0.5 * sin(t * 3.7)),
                        treble: 0.15 + flutter
                    )
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    private func loadLocal(_ np: NowPlaying, from url: URL) {
        do {
            let file = try AVAudioFile(forReading: url)
            // Stop the player node BEFORE touching the graph. A station switch
            // whose incoming track has a different sample rate/channel count
            // makes reconnectIfNeeded rewire node→eq→musicMixer; disconnecting
            // a node that is still rendering the previous station's track is an
            // uncatchable crash (intermittent — only fires on a format change).
            // Silencing the node first makes the reconnect safe.
            node.stop()
            reconnectIfNeeded(format: file.processingFormat)

            let sampleRate = file.processingFormat.sampleRate
            let elapsed = np.elapsed(at: Date())
            let startFrame = AVAudioFramePosition(max(0, elapsed - 0.05) * sampleRate)
            let remaining = file.length - startFrame
            guard remaining > 0 else { return }

            node.scheduleSegment(
                file,
                startingFrame: startFrame,
                frameCount: AVAudioFrameCount(remaining),
                at: nil
            )
            // node.play() on a non-running engine raises an uncatchable
            // NSException — only play once the engine is genuinely up.
            if isPlaying {
                if startEngineIfNeeded() {
                    node.play()
                } else {
                    // Session refused (phone call, etc.) — the UI must not
                    // claim "playing" over silence.
                    isPlaying = false
                    levels = .zero
                }
            }
        } catch {
            // A bad asset must never kill the station — stay silent until
            // the stream advances past it. A poisoned *cached* download is
            // deleted (and the load key reopened) so the next airing retries
            // instead of replaying the bad file forever.
            node.stop()
            let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            if url.path.hasPrefix(cachesDir.path) {
                try? FileManager.default.removeItem(at: url)
                loadedKey = nil
            }
        }
        refreshNowPlayingInfo()
    }

    /// Rebuild the WHOLE local chain at the new file format — node → eq →
    /// musicMixer. (musicMixer → main and ambience → main are fixed edges from
    /// init.) Rebuilding the full chain, not just node→main, is what keeps the
    /// effect units in circuit across a mid-session format change.
    private func reconnectIfNeeded(format: AVAudioFormat) {
        guard currentFormat?.sampleRate != format.sampleRate
            || currentFormat?.channelCount != format.channelCount else { return }
        // THE station/track-switch crash (hit whenever rotation crosses a
        // sample-rate boundary, e.g. the one 44.1 kHz master in a 48 kHz
        // catalog): calling `engine.connect` on an initialized engine — even a
        // PAUSED one — triggers AVAudioEngineGraph::UpdateGraphAfterReconfig,
        // which re-propagates the new rate down the live spatial tail
        // (wowFlutter → spatialSource → environment) and throws an uncatchable
        // NSException. The only safe rewire is on a fully STOPPED engine:
        // connects then defer graph building to the next start().
        node.stop()
        let hadTap = tapInstalled
        if hadTap { musicMixer.removeTap(onBus: 0); tapInstalled = false }
        let wasRunning = engine.isRunning
        ambience.stop()          // its schedule dies with the stop; re-armed below
        engine.stop()
        engine.disconnectNodeOutput(node)
        engine.disconnectNodeOutput(eq)
        engine.connect(node, to: eq, format: format)
        engine.connect(eq, to: musicMixer, format: format)
        currentFormat = format
        if wasRunning {
            engine.prepare()
            try? engine.start()
            ensureAmbience()     // reschedule the surface-noise loop if this mode has one
        }
        if hadTap { installTapIfNeeded() }
    }

    /// Activate only when playback genuinely begins — activating at init
    /// silences whatever the user was listening to before pressing play.
    private func activateSession() -> Bool {
        #if os(iOS)
        do { try AVAudioSession.sharedInstance().setActive(true) } catch { return false }
        #endif
        return true
    }

    @discardableResult
    private func startEngineIfNeeded() -> Bool {
        installTapIfNeeded()
        if engine.isRunning { return true }
        guard activateSession() else { return false }
        engine.prepare()
        do {
            try engine.start()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Sound modes

    /// Switch listening mode: retune the EQ, reschedule (or clear) the
    /// ambience loop, and remember the choice.
    public func setMode(_ newMode: SoundMode) {
        guard newMode != mode else { return }
        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: Self.modeKey)
        applyModeEQ()
        applySpatialMode()       // 3D on for SPATIAL, transparent for vinyl/cassette
        ambience.stop()          // clears the old loop
        ensureAmbience()         // schedules the new one if this mode has it
        startWowFlutter()        // and retune the wow/flutter depth (0 for SPATIAL)
    }

    /// Drive the wow/flutter pitch wobble for the current mode — pitch only, a
    /// few cents deep, so tape and vinyl waver like the real thing while the
    /// track length (and the shared radio clock) never budge. SPATIAL stays flat.
    private func startWowFlutter() {
        wowTimer?.invalidate(); wowTimer = nil
        // Only tape/vinyl wobble; HD and 3D stay dead pitch-flat.
        guard isPlaying, mode == .vinyl || mode == .cassette else { wowFlutter.pitch = 0; return }
        wowStart = Date()
        let timer = Timer(timeInterval: 1.0 / 50, repeats: true) { [weak self] _ in
            guard let self else { return }
            let t = Date().timeIntervalSince(self.wowStart)
            let cents: Double
            switch self.mode {
            case .vinyl:
                // A 33⅓ platter: a subtle once-around wow with a whisper of
                // flutter — felt, not seasick (the old 7-cent wow was too much).
                cents = 3.0 * sin(2 * .pi * 0.55 * t) + 1.0 * sin(2 * .pi * 5.5 * t)
            case .cassette:
                // Capstan flutter is the cassette signature — a faster wobble
                // with a slow bias drift riding underneath. Present, musical.
                cents = 3.5 * sin(2 * .pi * 1.4 * t)
                      + 2.5 * sin(2 * .pi * 8.0 * t)
                      + 1.5 * sin(2 * .pi * 0.3 * t)
            case .hd, .spatial:
                cents = 0
            }
            self.wowFlutter.pitch = Float(cents)
        }
        RunLoop.main.add(timer, forMode: .common)
        wowTimer = timer
    }

    private func stopWowFlutter() {
        wowTimer?.invalidate(); wowTimer = nil
        wowFlutter.pitch = 0
    }

    /// Shape the local music chain per mode. All bands stay in circuit; SPATIAL
    /// just runs them near-flat (a touch of air), so the graph never changes.
    private func applyModeEQ() {
        func set(_ i: Int, _ type: AVAudioUnitEQFilterType, _ freq: Float, _ bw: Float, _ gain: Float) {
            guard i < eq.bands.count else { return }
            let b = eq.bands[i]
            b.filterType = type; b.frequency = freq; b.bandwidth = bw
            b.gain = gain; b.bypass = false
        }
        switch mode {
        case .hd:        // true to the master — flat, full-range, no coloring
            set(0, .lowShelf,   100, 0.5, 0)
            set(1, .parametric, 1_000, 1.0, 0)
            set(2, .parametric, 4_000, 1.0, 0)
            set(3, .highShelf,  12_000, 0.5, 0)
            eq.globalGain = 0
        case .spatial:   // 3D carries the width; tone stays flat with a hair of air
            set(0, .lowShelf,   100, 0.5, 0)
            set(1, .parametric, 1_000, 1.0, 0)
            set(2, .parametric, 4_000, 1.0, 0.5)
            set(3, .highShelf,  11_000, 0.5, 1.5)
            eq.globalGain = 0
        case .vinyl:     // warm, bodied, GENTLE air rolloff — not a blanket over the top
            set(0, .lowShelf,   110, 0.6, 2.5)   // warm low end
            set(1, .parametric, 260, 1.0, 1.0)   // low-mid body
            set(2, .parametric, 3_000, 1.2, 0.5) // keep presence alive
            set(3, .highShelf,  11_000, 0.5, -4) // gentle air rolloff, still open
            eq.globalGain = 1
        case .cassette:  // band-limited, boxy mids, dull top — a real tape curve
            set(0, .lowShelf,   90, 0.6, -3.5)   // thin lows
            set(1, .parametric, 240, 1.1, 1.5)   // boxy low-mid body
            set(2, .parametric, 3_500, 1.2, -2)  // presence dip
            set(3, .highShelf,  6_500, 0.5, -10) // dull cassette top
            eq.globalGain = 1
        }
    }

    /// Configure the SPATIAL renderer for the current mode — property flips
    /// ONLY, never a graph re-route (that is the classic mid-playback crash).
    /// `.ambienceBed` renders the finished STEREO mix as a bed placed around the
    /// listener's head (binaural via HRTF) instead of collapsing it to a mono
    /// point; `.bypass` turns the environment into a transparent wire so the
    /// vinyl/cassette signal reaches the main mix untouched. `outputType = .auto`
    /// is the graceful-degradation lever: HRTF on headphones, a clean stereo
    /// downmix on a phone/car speaker rather than a phasey binaural artifact.
    private func applySpatialMode() {
        environment.outputType = .auto
        switch mode {
        case .spatial:
            // Real HRTF width for a stereo master — and NO room reverb. The old
            // mediumRoom reverb was the "fake": it made every record sound like
            // it was playing in a tiled room. Width only. On headphones this is
            // a genuine wide binaural bed; on a speaker `.auto` downmixes it to
            // clean stereo instead of a phasey artifact.
            spatialSource.sourceMode = .ambienceBed
            spatialSource.renderingAlgorithm = .auto
            spatialSource.position = AVAudio3DPoint(x: 0, y: 0, z: 0)
            spatialSource.reverbBlend = 0
            environment.reverbParameters.enable = false
        case .hd, .vinyl, .cassette:
            // Transparent wire — HD passes the master untouched; vinyl/cassette
            // get their character from the EQ + wow/flutter + surface noise, not
            // from the spatial renderer.
            spatialSource.sourceMode = .bypass
            spatialSource.reverbBlend = 0
            environment.reverbParameters.enable = false
        }
    }

    /// Start (or keep) the surface-noise loop for the current mode. Runs the
    /// engine even under a remote stream so crackle/hiss reaches every path.
    private func ensureAmbience() {
        guard mode.hasAmbience, isPlaying else { stopAmbience(); return }
        guard startEngineIfNeeded() else { return }
        if ambienceBuffers[mode] == nil {
            ambienceBuffers[mode] = makeAmbienceBuffer(for: mode)
        }
        guard let buf = ambienceBuffers[mode] else { return }
        ambience.volume = mode == .vinyl ? 0.55 : 0.5
        if !ambience.isPlaying {
            ambience.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)
            ambience.play()
        }
    }

    private func stopAmbience() {
        if ambience.isPlaying { ambience.stop() }
    }

    // MARK: - Aircheck tap (HIT RECORD)

    /// Tap the whole program off the main mix so an AIRCHECK can be written to
    /// disk. Returns the tap format (feed it to AVAudioFile), or nil if the
    /// engine can't run — a remote stream on a clean route plays through
    /// AVPlayer, not the engine, so there's nothing here to tape (the aircheck
    /// keeps its card either way). Only one tap per bus; nothing else taps the
    /// main mix (the FFT meter sits on `musicMixer`).
    public func installAircheckTap(_ handler: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) -> AVAudioFormat? {
        // One tap per bus: taping the main mix now would tear out the live
        // broadcast feed and silently freeze every listener's playlist. The
        // show wins; TAPE reports honestly that it can't roll.
        guard !djModeActive else { return nil }
        guard startEngineIfNeeded() else { return nil }
        let mixer = engine.mainMixerNode
        let format = mixer.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { return nil }
        mixer.removeTap(onBus: 0) // defensive: never stack taps
        mixer.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
            handler(buffer, when)
        }
        return format
    }

    public func removeAircheckTap() {
        // Never touch the main-mix tap while DJ MODE owns it.
        guard !djModeActive else { return }
        engine.mainMixerNode.removeTap(onBus: 0)
    }

    // MARK: - DJ MODE (GO LIVE with the music bed)
    //
    // The host's mic joins THIS engine: inputNode (voice-processing AEC so a
    // speaker monitor can't howl) → a real DynamicsProcessor compressor → a
    // gated mic mixer → the main mix. The music DUCKS under the voice via an
    // envelope follower, and the broadcast feed is a tap on the main mix —
    // music + voice exactly as the host hears it, handed to the HLS encoder
    // as PCM. Music never pauses; the host monitors their own show live.

    /// True while the mic is mixed over the music for broadcast.
    public private(set) var djModeActive = false

    /// TRUE when the record currently on air is a REMOTE stream, which plays
    /// through AVPlayer — outside this engine — and therefore CANNOT be in the
    /// broadcast feed. The host still hears it; listeners would get voice
    /// only. The console surfaces this rather than quietly airing a mic-only
    /// show that claims to be a DJ set. (Bundled masters — PWR, the Vault —
    /// run through the engine and DO carry music.)
    @Published public private(set) var djMusicMissingFromFeed = false

    private func refreshDJFeedTruth() {
        let missing = djModeActive && streamActive
        if djMusicMissingFromFeed != missing { djMusicMissingFromFeed = missing }
    }

    private var micGain = AVAudioMixerNode()          // the gate rides this volume
    private lazy var micCompressor: AVAudioUnitEffect = Self.makeCompressor()
    private var djNodesAttached = false

    // Duck + gate state, touched only on the mic-tap audio thread.
    private let djState = DJAudioState()

    /// The full program (music + mic) as rendered to the main mix, ~43 Hz.
    /// CALLED ON THE AUDIO THREAD — the receiver must be realtime-safe.
    public var onBroadcastBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    /// Mic loudness 0…1 (post-compressor), ~10 Hz on the main actor.
    public var onMicLevel: ((Float) -> Void)?
    /// The DJ audio path died mid-show (media reset, interruption) — the
    /// broadcast must end rather than stream silence.
    public var onDJInterrupted: (() -> Void)?

    private static func makeCompressor() -> AVAudioUnitEffect {
        let desc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        return AVAudioUnitEffect(audioComponentDescription: desc)
    }

    /// Broadcast-voice compressor: tame peaks, lift the floor — radio voice.
    private func configureCompressor() {
        let unit = micCompressor.audioUnit
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, -22, 0)
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, 8, 0)
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_AttackTime, kAudioUnitScope_Global, 0, 0.004, 0)
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0, 0.18, 0)
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_OverallGain, kAudioUnitScope_Global, 0, 4, 0)
    }

    /// Bring the mic into the graph and start feeding the broadcast tap.
    /// Returns false if the session or engine refuses — the caller falls back
    /// to the mic-only (radio-paused) broadcast path.
    @discardableResult
    public func startDJMode() -> Bool {
        guard !djModeActive else { return true }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch { return false }
        #endif

        let wasPlaying = isPlaying
        // The input path and voice processing can only change on a stopped
        // engine; scheduled audio dies with the stop and is re-joined below.
        node.stop()
        ambience.stop()
        engine.stop()

        if !djNodesAttached {
            engine.attach(micCompressor)
            engine.attach(micGain)
            djNodesAttached = true
        }
        // AEC + noise suppression: keeps a speaker monitor from howling and
        // cleans the mic. Failure is non-fatal (headphone hosts don't need it).
        // NOTE: taps the OUTPUT node into voice processing too — that colors
        // the host's local monitor only; the broadcast tap sits upstream.
        try? engine.inputNode.setVoiceProcessingEnabled(true)

        // A 0-Hz / 0-channel input format means the session never gave us a
        // real mic (no route, permission race). Connecting that raises an
        // uncatchable exception — bail to the mic-only path instead.
        let micFormat = engine.inputNode.outputFormat(forBus: 0)
        guard micFormat.channelCount > 0, micFormat.sampleRate > 0 else {
            tearDownDJGraph()
            return false
        }
        engine.connect(engine.inputNode, to: micCompressor, format: micFormat)
        engine.connect(micCompressor, to: micGain, format: micFormat)
        // micGain is a mixer: it converts the (possibly 24/48 kHz mono) voice
        // path to the main mix's format on its own.
        engine.connect(micGain, to: engine.mainMixerNode, format: nil)
        configureCompressor()
        micGain.outputVolume = 1

        installDJTaps()

        engine.prepare()
        do { try engine.start() } catch {
            tearDownDJGraph()
            return false
        }
        djModeActive = true
        djState.remoteDuck = { [weak self] level in self?.avPlayer?.volume = level }
        // Re-join the shared second — the engine restart dropped the schedule.
        if wasPlaying {
            if let np = stream.nowPlaying { load(np) }
            ensureAmbience()
            startWowFlutter()
        }
        refreshDJFeedTruth()
        return true
    }

    /// Tear the mic out of the graph and hand the session back to playback.
    public func stopDJMode() {
        guard djModeActive else { return }
        djModeActive = false
        djState.remoteDuck = nil
        avPlayer?.volume = 1
        refreshDJFeedTruth()
        engine.mainMixerNode.removeTap(onBus: 0)
        micCompressor.removeTap(onBus: 0)

        let wasPlaying = isPlaying
        node.stop()
        ambience.stop()
        engine.stop()
        tearDownDJGraph()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        #endif
        // Restore the music: the deck plays on after the show.
        if wasPlaying {
            if startEngineIfNeeded() {
                if let np = stream.nowPlaying { load(np) }
                ensureAmbience()
                startWowFlutter()
            }
        }
        // Music comes back up from wherever the duck left it.
        musicMixer.outputVolume = 1
        ambience.volume = mode == .vinyl ? 0.55 : 0.5
    }

    private func tearDownDJGraph() {
        // Taps SURVIVE engine.stop() and disconnection. Leaving one behind
        // means the next installTap on that bus raises an uncatchable
        // "nullptr == Tap()" exception, and a stale main-mix tap would keep
        // firing onBroadcastBuffer during ordinary playback.
        if djNodesAttached {
            micCompressor.removeTap(onBus: 0)
            engine.mainMixerNode.removeTap(onBus: 0)
            engine.disconnectNodeOutput(engine.inputNode)
            engine.disconnectNodeOutput(micCompressor)
            engine.disconnectNodeOutput(micGain)
        }
        try? engine.inputNode.setVoiceProcessingEnabled(false)
    }

    /// Two taps: the voice tap (level → gate + duck) and the program tap
    /// (main mix → broadcast). Different nodes, so both are legal.
    private func installDJTaps() {
        let state = djState
        // Voice: measure post-compressor RMS, drive the gate and the duck.
        let micMixer = self.micGain
        let music = self.musicMixer
        let amb = self.ambience
        let ambBase: Float = mode == .vinyl ? 0.55 : (mode == .cassette ? 0.5 : 0)
        micCompressor.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            var rms: Float = 0
            vDSP_rmsqv(channel, 1, &rms, vDSP_Length(buffer.frameLength))
            let voice = rms > 0.015                       // the gate threshold
            // Fast attack, slow release — words open instantly, tails breathe.
            state.duck = voice
                ? min(1, state.duck + 0.35)
                : max(0, state.duck - 0.03)
            state.gate = voice
                ? min(1, state.gate + 0.5)
                : max(0, state.gate - 0.02)
            // Mixer volumes are AU parameters — safe to set off-main.
            micMixer.outputVolume = 0.15 + 0.85 * state.gate   // floor, not a hard cut
            let musicLevel = 1 - 0.72 * state.duck             // duck to ~28%
            music.outputVolume = musicLevel
            if ambBase > 0 { amb.volume = ambBase * (1 - 0.85 * state.duck) }
            // A remote record plays through AVPlayer, not this graph — duck it
            // too so the host's own monitor ducks under their voice like the
            // engine path does. (It still can't reach the broadcast feed.)
            state.remoteDuck?(musicLevel)
            // ~10 Hz level to the console meter.
            let now = Date()
            if now.timeIntervalSince(state.lastLevelPublish) > 0.1 {
                state.lastLevelPublish = now
                let level = max(0, min(1, rms * 6))
                Task { @MainActor [weak self] in self?.onMicLevel?(level) }
            }
        }
        // Program: the full mix, straight to the encoder.
        engine.mainMixerNode.removeTap(onBus: 0)   // defensive: never stack
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, when in
            self?.onBroadcastBuffer?(buffer, when)
        }
    }

    /// The main mix's live render format — the encoder configures itself to it.
    public var broadcastFormat: AVAudioFormat {
        engine.mainMixerNode.outputFormat(forBus: 0)
    }

    /// Synthesize a seamless surface-noise loop — no shipped assets. VINYL lays
    /// low-passed "fry" under sparse, decaying needle-clicks (each a real
    /// multi-sample pop with a tail, not a lone spike) plus a touch of platter
    /// rumble; CASSETTE is high-frequency-weighted tape hiss over a faint motor
    /// hum — shaped, not flat white, so it reads as a machine and not static.
    private func makeAmbienceBuffer(for mode: SoundMode) -> AVAudioPCMBuffer? {
        let sr = ambienceFormat.sampleRate
        let frames = AVAudioFrameCount(sr * 6) // 6-second loop — less obvious cycling
        guard let buf = AVAudioPCMBuffer(pcmFormat: ambienceFormat, frameCapacity: frames),
              let data = buf.floatChannelData else { return nil }
        buf.frameLength = frames
        let n = Int(frames)
        let channels = Int(ambienceFormat.channelCount)

        var lpPrev: Float = 0      // one-pole low-pass state (vinyl fry)
        var hpPrev: Float = 0      // differentiator state (cassette hiss shaping)
        var click: Float = 0       // current needle-click amplitude
        var clickDecay: Float = 0.7
        var phase = 0.0
        let rumbleInc = 2 * Double.pi * 33.0 / sr   // ~33 Hz turntable rumble
        let humInc = 2 * Double.pi * 62.0 / sr      // ~62 Hz cassette motor hum

        for i in 0..<n {
            let w = Float.random(in: -1...1)
            var s: Float
            switch mode {
            case .vinyl:
                lpPrev += (w - lpPrev) * 0.08
                let fry = lpPrev * 0.20 + w * 0.003
                if Float.random(in: 0..<1) < 0.00006 {           // ~2–3 pops/sec, a bed not a machine-gun
                    click = Float.random(in: 0.05...0.28) * (Bool.random() ? 1 : -1)
                    clickDecay = Float.random(in: 0.55...0.85)
                }
                click *= clickDecay
                phase += rumbleInc
                s = fry + click + Float(sin(phase)) * 0.010
            case .cassette:
                let hp = w - hpPrev; hpPrev = w                  // 6 dB/oct HP → bright tape hiss
                phase += humInc
                s = hp * 0.9 * 0.028 + Float(sin(phase)) * 0.005
            case .hd, .spatial:
                s = 0
            }
            // A hair of per-channel dither so the loop isn't dead-mono.
            for c in 0..<channels {
                data[c][i] = s + (mode.hasAmbience ? Float.random(in: -1...1) * 0.0015 : 0)
            }
        }
        return buf
    }

    /// Interruptions (calls, Siri) and route/config changes (headphones,
    /// CarPlay) stop the engine out from under us. Without handling, the UI
    /// claims "playing" over silence and the next reschedule can crash.
    private func observeSystemAudioEvents() {
        #if os(iOS)
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let info = note.userInfo
            Task { @MainActor [weak self] in self?.handleInterruption(info) }
        }
        // Headphones yanked / AirPods died: the platform convention is to
        // PAUSE, never to blast the open speaker. This must win over the
        // engine-config handler below, which would otherwise resume on the
        // new (loudspeaker) route.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            guard reason == .oldDeviceUnavailable else { return }
            Task { @MainActor [weak self] in self?.pause() }
        }
        // The media daemon can crash and reset out from under us; the old
        // engine is dead at that point and must be rebuilt.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.recoverFromMediaServicesReset() }
        }
        #endif
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // DJ MODE: the mic feed must survive a route/config change —
                // restart the engine if the change stopped it, then rejoin.
                if self.djModeActive {
                    if !self.engine.isRunning {
                        self.engine.prepare()
                        try? self.engine.start()
                    }
                    if self.isPlaying, !self.streamActive,
                       let np = self.stream.nowPlaying { self.load(np) }
                    return
                }
                guard self.isPlaying else { return }
                // Engine graph changes only matter to engine playback —
                // reloading here would needlessly restart an AVPlayer stream.
                guard !self.streamActive else { return }
                // Rejoin the live edge on the new route/graph.
                if let np = self.stream.nowPlaying { self.load(np) }
            }
        }
    }

    #if os(iOS)
    /// After a media-daemon reset the old engine object is unusable: build a
    /// fresh graph, reassert the session category, and rejoin the live edge.
    private func recoverFromMediaServicesReset() {
        let wasPlaying = isPlaying
        if djModeActive {
            // The DJ graph died with the daemon; the show cannot survive it.
            djModeActive = false
            onDJInterrupted?()
        }
        engine = AVAudioEngine()
        node = AVAudioPlayerNode()
        eq = AVAudioUnitEQ(numberOfBands: 4)
        musicMixer = AVAudioMixerNode()
        wowFlutter = AVAudioUnitTimePitch()
        // The spatial pair died with the daemon too — recreate both, or
        // attachAudioNodes rebuilds the tail onto dead objects and the graph
        // goes silent after any interruption/route change/media reset.
        spatialSource = AVAudioMixerNode()
        environment = AVAudioEnvironmentNode()
        ambience = AVAudioPlayerNode()
        micGain = AVAudioMixerNode()
        micCompressor = Self.makeCompressor()
        djNodesAttached = false
        attachAudioNodes() // re-applies applySpatialMode() for the current mode
        tapInstalled = false
        currentFormat = nil
        loadedKey = nil
        // The stream player died with the daemon too.
        if let driftObserver { avPlayer?.removeTimeObserver(driftObserver) }
        driftObserver = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        avPlayer = nil
        configureAudioSession()
        if wasPlaying {
            if isLive, let url = liveURL {
                goLive(url: url, title: liveTitle)
            } else if let np = stream.nowPlaying {
                load(np)
            }
            startWowFlutter()
        }
    }

    private func handleInterruption(_ info: [AnyHashable: Any]?) {
        guard let raw = info?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            if djModeActive {
                // A call/Siri seized the mic mid-show — end the broadcast
                // cleanly rather than stream silence to every listener.
                onDJInterrupted?()
            }
            pause() // UI stays truthful: we are not playing
        case .ended:
            let options = (info?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            if options.contains(.shouldResume) {
                try? AVAudioSession.sharedInstance().setActive(true)
                play() // rejoins at the live edge by design
            }
        @unknown default:
            break
        }
    }
    #endif

    /// The tap runs on an audio thread: analysis is allocation-free, and
    /// results hop to the main actor at ~30 Hz.
    private func installTapIfNeeded() {
        guard !tapInstalled else { return }
        tapInstalled = true
        let analyzer = self.analyzer
        // Tap the MUSIC submix, not the main mixer — the plate must breathe on
        // the song, never on the ambience crackle mixed in after it.
        musicMixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
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
        // Category only — activation waits for actual playback
        // (startEngineIfNeeded), so launching the app never interrupts
        // another app's audio.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        #endif
    }

    /// System-surface boost (lock screen / Siri / "I like this"). AppServices
    /// wires this to cast a real, server-recorded vote for the current track.
    public var onBoostCommand: (() -> Void)?

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

        // The in-car / lock-screen / Siri "boost" affordance. Routes through
        // onBoostCommand (wired by AppServices) so it casts a REAL server vote
        // like every other boost — not a local-only vanity bump. Falls back to
        // the local tally only if nothing is wired.
        center.likeCommand.isEnabled = true
        center.likeCommand.localizedTitle = "Boost"
        center.likeCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if let hook = self.onBoostCommand { hook() } else { self.stream.boostCurrent() }
            self.refreshNowPlayingInfo()
            return .success
        }
    }

    /// Push current-track metadata (and live boost score) to the system.
    public func refreshNowPlayingInfo() {
        if isLive {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = [
                MPMediaItemPropertyTitle: liveTitle.isEmpty ? "LIVE" : liveTitle,
                MPMediaItemPropertyArtist: stream.station.name,
                MPNowPlayingInfoPropertyIsLiveStream: true,
            ]
            MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
            return
        }
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

/// Mutable duck/gate envelopes touched only on the mic-tap audio thread.
/// A reference box so the @MainActor player never crosses into it.
final class DJAudioState: @unchecked Sendable {
    var duck: Float = 0
    var gate: Float = 0
    var lastLevelPublish = Date.distantPast
    /// Set while DJ mode runs: ducks the AVPlayer bed (remote records live
    /// outside the engine). AVPlayer.volume is safe to set off the main thread.
    var remoteDuck: ((Float) -> Void)?
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

// MARK: - Stream tap

/// Feeds STREAMED audio through the same spectrum analysis local playback
/// gets, via an `MTAudioProcessingTap` on the player item's audio mix.
///
/// Lifetime: the context is retained BY the tap (`passRetained` at create,
/// released in `finalize`) and holds no reference back to the player. The
/// tap itself is retained by the audio mix, which is retained by the item —
/// so everything dies exactly when the item does. No cycles, and no
/// dangling audio-thread pointer, because finalize runs only after the last
/// process callback has drained.
final class StreamTapContext {
    private let analyzer = SpectrumAnalyzer()
    private let onLevels: (AudioLevels) -> Void
    private var sampleRate: Double = 44_100
    private var channels: Int = 2
    private var interleaved = false
    private var scratch = [Float](repeating: 0, count: 4096)

    private init(onLevels: @escaping (AudioLevels) -> Void) {
        self.onLevels = onLevels
    }

    /// Build a tap ready to assign to `AVMutableAudioMixInputParameters
    /// .audioTapProcessor`. Returns nil if MediaToolbox refuses (playback
    /// then simply runs without live analysis — never blocked on visuals).
    static func makeTap(onLevels: @escaping (AudioLevels) -> Void) -> MTAudioProcessingTap? {
        let context = StreamTapContext(onLevels: onLevels)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(context).toOpaque()),
            init: { _, clientInfo, tapStorageOut in
                tapStorageOut.pointee = clientInfo!
            },
            finalize: { tap in
                Unmanaged<StreamTapContext>
                    .fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let ctx = Unmanaged<StreamTapContext>
                    .fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let asbd = format.pointee
                ctx.sampleRate = asbd.mSampleRate
                ctx.channels = max(1, Int(asbd.mChannelsPerFrame))
                ctx.interleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
            },
            unprepare: nil,
            process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(
                    tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut
                ) == noErr else { return }
                let ctx = Unmanaged<StreamTapContext>
                    .fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                ctx.process(bufferList: bufferListInOut)
            }
        )
        var tapOut: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects, &tapOut
        ) == noErr, let tap = tapOut else { return nil }
        return tap
    }

    /// Audio-thread hot path — allocation-free (scratch is preallocated).
    private func process(bufferList: UnsafeMutablePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(bufferList)
        guard let first = abl.first, let data = first.mData else { return }
        let floats = data.assumingMemoryBound(to: Float.self)
        let totalFloats = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        guard totalFloats > 0 else { return }
        let levels: AudioLevels
        if interleaved, channels > 1 {
            // Deinterleave channel 0 — an interleaved LRLR series through
            // the FFT smears the spectrum with mirror images.
            let frames = min(totalFloats / channels, scratch.count)
            guard frames > 0 else { return }
            for i in 0..<frames { scratch[i] = floats[i * channels] }
            levels = scratch.withUnsafeBufferPointer { buf in
                analyzer.analyze(buf.baseAddress!, count: frames, sampleRate: sampleRate)
            }
        } else {
            levels = analyzer.analyze(floats, count: totalFloats, sampleRate: sampleRate)
        }
        onLevels(levels)
    }
}
#endif
