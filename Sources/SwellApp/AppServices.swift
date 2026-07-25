import Foundation
import Combine
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
        let realTracks = Self.loadRealAudio()
        var stationCatalogs: [(Station, [Track])]
        if realTracks.count >= 3 {
            stationCatalogs = Self.realStations(from: realTracks)
        } else {
            stationCatalogs = MockCatalog.stations.map { ($0, MockCatalog.tracks(for: $0)) }
        }
        // THE UNDERGROUND: the public station — the whole OneSync roster,
        // hydrating over the air. The ALGORITHM (trust-weighted crowd votes,
        // never industry numbers) decides who breaks.
        // (id keeps its original derivation string; server rows are seeded
        // under it.)
        stationCatalogs.append((Station(
            id: FolderCatalog.stableID("station:the algo"),
            name: "The Underground",
            tagline: "The crowd breaks records here.",
            catalogArtistIDs: []
        ), []))
        // THE WAVE: what's trending across the open web right now (Audius) —
        // full-length, legal, hydrated over the air. Music that's actually out.
        stationCatalogs.append((Station(
            id: FolderCatalog.stableID("station:the wave"),
            name: "The Wave",
            tagline: "What's hot right now.",
            catalogArtistIDs: []
        ), []))

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
        self.backend = RadioBackend(listenerKey: listener.id.uuidString)

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
        backend.tune(toStationID: active.station.id.uuidString)

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
        backend.tune(toStationID: stream.station.id.uuidString)
    }

    /// All of this listener's votes flow through here: local tally first
    /// (instant), the wager ledger, then out to every other device.
    func castMyVote(_ direction: VoteDirection, on trackID: UUID, dedication: String? = nil) {
        activeStream.vote(direction, on: trackID)
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

    /// The full catalog is always station one; album subfolders and the
    /// loose singles become their own stations when big enough to rotate.
    private static func realStations(from realTracks: [Track]) -> [(Station, [Track])] {
        func station(_ name: String, _ tagline: String, _ tracks: [Track]) -> (Station, [Track]) {
            (Station(
                id: FolderCatalog.stableID("station:\(name.lowercased())"),
                name: name,
                tagline: tagline,
                catalogArtistIDs: Set(tracks.map(\.artistID))
            ), tracks)
        }

        var catalogs = [station("Swell", "Live from the OneSync catalog.", realTracks)]

        let albums = Dictionary(grouping: realTracks.filter { $0.albumTitle != nil },
                                by: { $0.albumTitle! })
        for (album, tracks) in albums.sorted(by: { $0.key < $1.key }) where tracks.count >= 3 {
            catalogs.append(station(album, "The album — sequenced by the crowd.", tracks))
        }

        let singles = realTracks.filter { $0.albumTitle == nil }
        if singles.count >= 3 {
            catalogs.append(station("Singles", "Every drop that stands alone.", singles))
        }
        return catalogs
    }
}
