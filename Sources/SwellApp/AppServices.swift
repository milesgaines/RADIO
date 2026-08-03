import Foundation
import AVFoundation
import Combine
import UIKit
import RadioKit

/// Single source of truth shared by the phone scene and the CarPlay scene.
/// Both connect to the *same* per-station `LiveStreamService`s, so the car
/// mirrors the live stream and a boost from the steering-wheel button lands
/// in the same tally as a tap in the phone app.
///
/// Every station runs always-on — exactly like production, where the streams
/// exist server-side whether or not this device is listening. Tuning just
/// points the player at a different one.
@MainActor
final class AppServices: ObservableObject {
    static let shared = AppServices()

    /// One always-on stream per station.
    let streams: [LiveStreamService]
    let player: RadioPlayer
    let meter: ListeningMeter
    /// The station's memory: airplays witnessed, boosts wagered.
    let airLog = AirLog()
    /// THE RING — song battles (upload, vote, winner enters rotation).
    let battles: BattleService
    /// THE LINE — call-ins (hold to talk, moderated, aired between songs).
    let callIn: CallInService
    /// GO LIVE — a host takes the air (mic → HLS on the phone). Dormant unless
    /// a host key sits in the Keychain.
    let broadcast = BroadcastService()
    /// HIT RECORD — tape the moment off the air into a keepable AIRCHECK.
    let aircheck: AircheckService
    /// THE READ — live audience research ("PPM for music"): per-record
    /// resonance, per-market, that also drops records in and out of rotation.
    let theRead: TheReadService
    /// Artwork for the away surfaces — lock screen / StandBy / CarPlay.
    let artwork = ArtworkService()
    /// The on-air record's real cover, for the main screen's now-playing card.
    /// nil while unknown / for a record that carries no art (the card draws a
    /// disc placeholder). Set on the main actor by observeArtwork.
    @Published private(set) var nowPlayingCover: UIImage?
    /// The real numbers: presence + votes over Supabase realtime.
    private let backend: RadioBackend

    @Published private(set) var activeStream: LiveStreamService

    private let crowds: [CrowdSimulator]
    private let listenerStore = UserDefaultsListenerStore()
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        // The same identity comes back every launch, so trust (account age +
        // listening tenure) actually accrues. `verifiedByOnboarding` stands in
        // for the sign-in/human check a real onboarding flow would do.
        var listener = ListenerIdentity.loadOrCreate(
            store: listenerStore,
            verifiedByOnboarding: true
        )
        // Gift build: the Program Director's voice counts in full from the
        // first second — founding tenure, no cold start. Radio royalty does
        // not wait in line at their own station.
        if listener.lifetimeListeningSeconds == 0 {
            listener.lifetimeListeningSeconds = 60 * 60 * 20
            listenerStore.save(listener)
        }
        self.meter = ListeningMeter(listener: listener, store: listenerStore)

        // Real mode: if the bundled RealAudio folder holds actual licensed
        // masters, the stations play them — one for everything, one per
        // album subfolder, one for the loose singles (each needs ≥3 tracks
        // so rotation has room to breathe). Otherwise fall back to the
        // silent three-station MockCatalog demo.
        // THE DIAL — a fixed four-station lineup, always in this order:
        //   PWR  · PWR DAMIZZA    the rhythmic flagship, on 24/7
        //   78   · THE VAULT      unreleased mixes from the crates
        //   1200 · THE UNDERGROUND the OneSync roster the crowd breaks
        //   247  · THE WAVE       what's trending across the open web, right now
        // Licensed masters hydrate the lineup when the RealAudio folder is
        // bundled; otherwise the silent demo catalog stands in so the dial is
        // never dead. THE UNDERGROUND and THE WAVE also hydrate over the air
        // (roster feed / web trending) and keep their original server ids so
        // seeded rows still resolve.
        let stationCatalogs = Self.dialLineup(realTracks: Self.loadRealAudio())

        let streams = stationCatalogs.map { station, catalog in
            LiveStreamService(
                station: station,
                catalog: catalog,
                engine: WeightedRotationEngine(config: .adaptive(to: catalog)),
                currentListener: listener
            )
        }
        self.streams = streams

        // The fake crowd is retired: presence and votes are real now. The
        // simulator class stays only for the test suite.
        self.crowds = []

        let active = streams[0]
        self.activeStream = active
        self.player = RadioPlayer(stream: active)
        self.aircheck = AircheckService(player: player)
        self.theRead = TheReadService(stream: active)
        self.backend = RadioBackend(listenerKey: listener.id.uuidString)
        self.battles = BattleService(listenerKey: listener.id.uuidString)
        self.callIn = CallInService(listenerKey: listener.id.uuidString)

        streams.forEach { $0.start() }

        // Real numbers in: presence → the listener count, remote votes →
        // the live tally. Every event names its station, and is routed to
        // THAT station's stream — a slow response arriving after a station
        // switch must never leak into the newly tuned station.
        backend.onPresenceCount = { [weak self] count, stationID in
            self?.stream(for: stationID)?.setLiveListenerCount(count)
        }
        backend.onRemoteVote = { [weak self] trackID, direction, fromKey, stationID in
            self?.stream(for: stationID)?.ingestRemoteVote(
                direction > 0 ? .boost : .bury, on: trackID, fromKey: fromKey
            )
        }
        // The shared clock: the server says what's on air and when it
        // started; every device renders the same second.
        backend.onRemoteClock = { [weak self] trackID, startedAt, duration, stationID in
            guard let self, let stream = self.stream(for: stationID) else { return }
            stream.applyRemoteClock(trackID: trackID, startedAt: startedAt)
            // Unknown track (the remote stations' server-side catalog):
            // learn it, then apply the clock for real. Retried — one
            // transient fetch failure must not silence the whole song.
            if stream.nowPlaying?.track.id != trackID {
                Task { @MainActor in
                    for attempt in 0..<3 {
                        if let row = await self.backend.fetchTrack(trackID) {
                            // A row with no audio is unplayable by design —
                            // skip it; the director moves on next tick.
                            guard let raw = row.audio_url, !raw.isEmpty,
                                  let url = URL(string: raw) else { return }
                            stream.upsertRemoteTrack(Track(
                                id: row.track_id, title: row.title,
                                artistID: row.artist_id, artistName: row.artist,
                                durationSeconds: row.duration_seconds > 0 ? row.duration_seconds : duration,
                                assetURL: url
                            ))
                            stream.applyRemoteClock(trackID: trackID, startedAt: startedAt)
                            return
                        }
                        try? await Task.sleep(nanoseconds: UInt64(1 << attempt) * 2_000_000_000)
                    }
                }
            }
        }
        // LIVE flips: a human on the air overrides the rotation clock — but
        // only for the station this device is tuned to; a flip on another
        // station must never grab this player.
        backend.onLiveShow = { [weak self] live, title, hls, stationID in
            guard let self,
                  self.activeStream.station.id.uuidString
                      .caseInsensitiveCompare(stationID) == .orderedSame
            else { return }
            // The host's OWN broadcast must never loop back into their speaker
            // (mic → HLS → mic feedback, plus ~15 s of latency). When this
            // device is the one on air for this station, ignore the flip — the
            // console is the host's monitor.
            if self.broadcast.isBroadcasting,
               let broadcasting = self.broadcast.stationID,
               broadcasting.caseInsensitiveCompare(stationID) == .orderedSame {
                return
            }
            if live, !hls.isEmpty, let url = URL(string: hls) {
                self.player.goLive(url: url, title: title.isEmpty ? "LIVE" : title)
            } else if self.player.isLive {
                self.player.endLive()
            }
        }
        backend.tune(toStationID: active.station.id.uuidString)

        // The broadcaster borrows the audio output: pause the radio when a
        // host goes live, resume it when the show ends.
        broadcast.attach(stationID: active.station.id.uuidString)
        broadcast.pauseRadio = { [weak self] in
            guard let self, self.player.isPlaying else { return }
            self.player.pause()
        }
        broadcast.resumeRadio = { [weak self] in self?.player.play() }

        // DJ MODE wiring: the broadcast borrows the player's engine — mic in,
        // music ducked under the voice, and the rendered program (music + mic)
        // streams out as the show. The buffer path runs on the audio thread
        // (nonisolated seam), everything else on the main actor.
        broadcast.startDJAudio = { [weak self] in self?.player.startDJMode() ?? false }
        broadcast.stopDJAudio = { [weak self] in self?.player.stopDJMode() }
        broadcast.djFeedFormat = { [weak self] in
            self?.player.broadcastFormat
                ?? AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        }
        player.onBroadcastBuffer = { [weak broadcast] buffer, when in
            broadcast?.forwardMixed(buffer, at: when)
        }
        player.onMicLevel = { [weak self] level in self?.broadcast.setMicLevel(level) }
        player.onDJInterrupted = { [weak self] in self?.broadcast.djAudioLost() }

        // Lock-screen / Siri "Boost" casts a REAL server vote (same path as the
        // CarPlay button), not a local-only bump — "real numbers only".
        player.onBoostCommand = { [weak self] in
            guard let self, let id = self.activeStream.nowPlaying?.track.id else { return }
            self.castMyVote(.boost, on: id)
        }

        // Listening tenure accrues while playback runs...
        player.$isPlaying
            .removeDuplicates()
            .sink { [weak self] playing in
                guard let self else { return }
                playing ? self.meter.playbackStarted() : self.meter.playbackStopped()
                self.pushListenerToTallies()
            }
            .store(in: &cancellables)

        // ...and banks once a minute so a force-quit can't erase a session.
        Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.meter.flush()
                self?.pushListenerToTallies()
            }
            .store(in: &cancellables)

        // THE READ lives on its own cadence; surface its changes (e.g. a record
        // starts BREAKING) through AppServices so the top-bar glyph re-tints.
        theRead.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Sign in with Apple: listening never needs it, but the first time a
        // listener acts, their Apple id becomes the vote identity — one person,
        // one voter, stable across reinstalls. Re-promotes on launch for a
        // returning signed-in listener.
        AuthService.shared.configure { [weak self] appleUserID, _ in
            self?.backend.adoptIdentity(appleUserID)
        }

        observeArtwork()
    }

    /// Keep the system "away" surfaces (lock screen, StandBy, CarPlay) dressed:
    /// the station's branded plate lands INSTANTLY on every tune/track change,
    /// then upgrades to the record's real cover art when one can be found.
    private func observeArtwork() {
        $activeStream
            .map { stream in stream.$nowPlaying.map { np in (stream, np?.track) } }
            .switchToLatest()
            .removeDuplicates(by: { $0.1?.id == $1.1?.id && $0.0 === $1.0 })
            .receive(on: RunLoop.main)
            .sink { [weak self] stream, track in
                guard let self else { return }
                let station = stream.station
                let index = self.streams.firstIndex(where: { $0 === stream }) ?? 0
                // 1) The plate, immediately — the lock screen is never bare.
                self.push(self.artwork.plate(for: station, accentIndex: index))
                self.nowPlayingCover = nil   // reset for the new record
                // 2) The record's own cover, if one can be found and we're
                // still on the same song by the time it arrives.
                guard let track else { return }
                Task { @MainActor [weak self] in
                    guard let self, let cover = await self.artwork.cover(for: track) else { return }
                    guard self.activeStream === stream,
                          self.activeStream.nowPlaying?.track.id == track.id else { return }
                    self.push(cover)
                    self.nowPlayingCover = cover
                }
            }
            .store(in: &cancellables)
    }

    private func push(_ image: UIImage) {
        guard let cg = image.cgImage else { return }
        player.setNowPlayingArtwork(image: cg, size: image.size)
    }

    /// The stream owning a backend event, matched case-insensitively — the
    /// app sends uppercase ids while Postgres row payloads arrive lowercase.
    private func stream(for stationID: String) -> LiveStreamService? {
        streams.first {
            $0.station.id.uuidString.caseInsensitiveCompare(stationID) == .orderedSame
        }
    }

    /// Point the player (and both UIs) at another always-on station.
    func tune(to station: Station) {
        guard let stream = streams.first(where: { $0.station.id == station.id }),
              stream !== activeStream else { return }
        activeStream = stream
        player.attach(to: stream)
        player.refreshNowPlayingInfo()
        theRead.retarget(to: stream)   // research + rotation gate follow the tune
        backend.tune(toStationID: stream.station.id.uuidString)
    }

    /// All of this listener's votes flow through here: local tally first
    /// (instant), the wager ledger, then out to every other device.
    func castMyVote(_ direction: VoteDirection, on trackID: UUID, dedication: String? = nil) {
        activeStream.vote(direction, on: trackID)
        theRead.noteLocalVote()   // the readout reacts to your vote now, not next tick
        if direction == .boost { airLog.logBoost(trackID: trackID, dedication: dedication) }
        backend.sendVote(
            stationID: activeStream.station.id.uuidString,
            trackID: trackID,
            direction: direction.rawValue
        )
    }

    /// Bank accrued tenure now (scene background, termination).
    func persistListeningProgress() {
        meter.flush()
        pushListenerToTallies()
    }

    private func pushListenerToTallies() {
        let updated = meter.listener
        streams.forEach { $0.refreshCurrentListener(updated) }
    }

    /// Licensed masters bundled as the app's `RealAudio` folder reference.
    /// The folder's *contents* are gitignored — masters never enter the repo;
    /// see RealAudio/README.md.
    private static func loadRealAudio() -> [Track] {
        guard let folder = Bundle.main.resourceURL?
            .appendingPathComponent("RealAudio", isDirectory: true) else { return [] }
        return FolderCatalog.load(from: folder)
    }

    /// The fixed four-station dial. Every launch shows exactly these four in
    /// this order; only their catalogs vary (licensed masters when the RealAudio
    /// folder is present, the demo catalog otherwise). The two web/roster
    /// stations keep their original derivation strings as ids so server-seeded
    /// rows still resolve. All four are seeded locally so nothing is a silent
    /// shell in the demo — real roster/trending rows hydrate over the air.
    private static func dialLineup(realTracks: [Track]) -> [(Station, [Track])] {
        let haveReal = realTracks.count >= 3
        let pool = haveReal ? realTracks : MockCatalog.tracks

        // Give each station its own rotation off the shared pool so they feel
        // distinct even from one catalog. PWR DAMIZZA gets the whole thing; the
        // others take thematic slices, never fewer than three so rotation breathes.
        func slice(_ keep: (Int) -> Bool) -> [Track] {
            let s = pool.enumerated().filter { keep($0.offset) }.map(\.element)
            return s.count >= 3 ? s : pool
        }
        let power = pool
        let vault = slice { $0 % 3 == 0 }        // every third cut — the deep crates
        let underground = slice { $0 % 2 == 1 }  // the odd rows — roster seed
        let wave = slice { $0 % 2 == 0 }         // the even rows — trending seed

        func station(_ id: UUID, _ name: String, _ tagline: String,
                     dial: String, unit: String = "", flagship: Bool = false,
                     _ tracks: [Track]) -> (Station, [Track]) {
            (Station(id: id, name: name, tagline: tagline, dial: dial,
                     dialUnit: unit, isFlagship: flagship,
                     catalogArtistIDs: Set(tracks.map(\.artistID))), tracks)
        }

        return [
            station(FolderCatalog.stableID("station:pwr damizza"), "PWR DAMIZZA",
                    "Damizza's rhythmic flagship — on 24/7.",
                    dial: "PWR", flagship: true, power),
            station(FolderCatalog.stableID("station:the vault"), "The Vault",
                    "Unreleased mixes, straight from the crates.",
                    dial: "78", unit: "RPM", vault),
            station(FolderCatalog.stableID("station:the algo"), "The Underground",
                    "Deep in the crates — the crowd breaks records here.",
                    dial: "1200", underground),
            station(FolderCatalog.stableID("station:the wave"), "The Wave",
                    "Rising with the room, right now.",
                    dial: "247", wave),
        ]
    }
}
