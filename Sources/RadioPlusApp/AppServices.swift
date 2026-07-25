import Foundation
import RadioKit

/// Single source of truth shared by the phone scene and the CarPlay scene.
/// Both connect to the *same* `LiveStreamService`, so the car mirrors the live
/// stream and a boost from the steering-wheel button lands in the same tally
/// as a tap in the phone app.
@MainActor
final class AppServices: ObservableObject {
    static let shared = AppServices()

    let stream: LiveStreamService
    let player: RadioPlayer

    enum CatalogSource: Equatable {
        case demo
        case liveRadio
        case navidrome(host: String)
    }

    @Published private(set) var catalogSource: CatalogSource = .demo

    private init() {
        // Builds up to 0.1.0 kept the Navidrome password in UserDefaults; move
        // any leftover plain-text copy into the keychain before the first read.
        NavidromeConfig.migrateLegacyPassword()

        let source = Self.configuredScheduleSource()
        let stream = LiveStreamService(scheduleSource: source)
        self.stream = stream
        self.player = RadioPlayer(stream: stream)
        // A shared station renders the server's catalog itself; the demo/
        // Navidrome swap below only applies when we're running local rotation.
        if source is SupabaseScheduleSource { catalogSource = .liveRadio }
        stream.start()
        reloadCatalog()
    }

    /// Pick where the station's *timeline* comes from. Order of precedence:
    ///
    ///  1. `-RadioBackend local` — force on-device rotation (the demo station),
    ///     handy for offline work or a UI screenshot.
    ///  2. `-StationFeedURL wss://…` — a generic self-hosted schedule feed
    ///     (`RemoteScheduleSource`), the bring-your-own-server option.
    ///  3. A configured Navidrome library — rotate *your* catalog on-device.
    ///     Local rotation, so `reloadCatalog()` can swap the pool in.
    ///  4. Default — the live OneSync shared station over Supabase, where every
    ///     listener hears the same second. Override the station with
    ///     `-RadioStationID <uuid>`.
    private static func configuredScheduleSource() -> (any StationScheduleSource)? {
        let defaults = UserDefaults.standard

        if defaults.string(forKey: "RadioBackend") == "local" { return nil }

        if let raw = defaults.string(forKey: "StationFeedURL"),
           let url = URL(string: raw),
           url.scheme == "ws" || url.scheme == "wss" {
            return RemoteScheduleSource(config: .init(url: url))
        }

        // A user who connected their own library gets local rotation over it.
        if NavidromeConfig.fromDefaults() != nil { return nil }

        let stationID = defaults.string(forKey: "RadioStationID").flatMap(UUID.init(uuidString:))
        return SupabaseScheduleSource(config: .init(stationID: stationID))
    }

    /// Connect to the configured Navidrome server (if any) and swap its
    /// library into the live rotation. Falls back to the demo catalog when
    /// unconfigured or unreachable — the station never goes dark.
    func reloadCatalog() {
        guard let config = NavidromeConfig.fromDefaults() else {
            // No personal library: keep whatever the timeline source decided
            // (the live shared station, or the demo catalog) — don't clobber
            // it. Only fall back to demo if we were previously on Navidrome.
            if case .navidrome = catalogSource { catalogSource = .demo }
            return
        }
        Task { [weak self] in
            do {
                let client = NavidromeClient(config: config)
                let tracks = try await client.fetchCatalog()
                guard let self, !tracks.isEmpty else { return }
                self.stream.updateCatalog(tracks)
                self.catalogSource = .navidrome(host: config.baseURL.host ?? config.baseURL.absoluteString)
            } catch {
                self?.catalogSource = .demo
            }
        }
    }
}
