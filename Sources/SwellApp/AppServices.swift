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
        let stationCatalogs: [(Station, [Track])]
        if realTracks.count >= 3 {
            stationCatalogs = Self.realStations(from: realTracks)
        } else {
            stationCatalogs = MockCatalog.stations.map { ($0, MockCatalog.tracks(for: $0)) }
        }

        let streams = stationCatalogs.map { station, catalog in
            LiveStreamService(
                station: station,
                catalog: catalog,
                engine: WeightedRotationEngine(config: .adaptive(to: catalog)),
                currentListener: listener
            )
        }
        self.streams = streams

        // Each station gets its own crowd with a different size, so flipping
        // between them feels like flipping between real rooms of people.
        let crowdSizes = [38, 17, 26]
        self.crowds = streams.enumerated().map { i, stream in
            CrowdSimulator(stream: stream, config: .init(targetSize: crowdSizes[i % crowdSizes.count]))
        }

        let active = streams[0]
        self.activeStream = active
        self.player = RadioPlayer(stream: active)

        streams.forEach { $0.start() }
        crowds.forEach { $0.start() }

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

    /// Point the player (and both UIs) at another always-on station.
    func tune(to station: Station) {
        guard let stream = streams.first(where: { $0.station.id == station.id }),
              stream !== activeStream else { return }
        activeStream = stream
        player.attach(to: stream)
        player.refreshNowPlayingInfo()
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
