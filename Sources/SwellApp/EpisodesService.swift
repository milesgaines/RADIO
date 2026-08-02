import Foundation
import AVFoundation
import Combine
import Supabase
import RadioKit

/// THE ARCHIVE — finished broadcasts, straight off the replay shelf
/// (`radio_episodes`, filed automatically when a host's stream ends).
/// Replays are private listening: playing one pauses the radio (one audible
/// source is a hard rule), and the radio's play button brings the live
/// second back.
@MainActor
final class EpisodesService: ObservableObject {

    struct Episode: Identifiable {
        let id: UUID
        let stationID: UUID
        let title: String
        let host: String?
        let hlsURL: URL
        let durationSeconds: Double?
        let recordedAt: Date
    }

    @Published private(set) var episodes: [Episode] = []
    @Published private(set) var playingID: UUID?
    @Published private(set) var loaded = false

    private static let projectURL = URL(string: "https://tgkgdquivdoquxamtgcr.supabase.co")!
    private static let publishableKey = "sb_publishable_JYYXKdhcGnEP5curdG_pLg_XVcy9-ii"
    private let client = SupabaseClient(supabaseURL: EpisodesService.projectURL,
                                        supabaseKey: EpisodesService.publishableKey)

    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?

    private struct Row: Decodable {
        let id: UUID
        let station_id: UUID
        let title: String
        let host: String?
        let hls_url: String
        let duration_seconds: Double?
        let recorded_at: Date
    }

    func refresh() async {
        defer { loaded = true }
        do {
            let rows: [Row] = try await client
                .from("radio_episodes")
                .select("id,station_id,title,host,hls_url,duration_seconds,recorded_at")
                .order("recorded_at", ascending: false)
                .limit(50)
                .execute().value
            episodes = rows.compactMap { r in
                guard let url = URL(string: r.hls_url) else { return nil }
                return Episode(id: r.id, stationID: r.station_id, title: r.title,
                               host: r.host, hlsURL: url,
                               durationSeconds: r.duration_seconds,
                               recordedAt: r.recorded_at)
            }
        } catch {
            // Shelf unreachable: keep whatever we had; the UI stays honest
            // via `loaded` + empty state.
        }
    }

    /// One audible source: the station goes quiet while a replay rolls.
    func play(_ episode: Episode, radio: RadioPlayer) {
        stop()
        radio.pause()
        let p = AVPlayer(url: episode.hlsURL)
        player = p
        playingID = episode.id
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: p.currentItem, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        p.play()
    }

    func stop() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player?.pause()
        player = nil
        playingID = nil
    }
}
