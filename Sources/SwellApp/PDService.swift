import Foundation
import Combine
import Supabase
import RadioKit

/// The Program Director's levers, backed by the key-gated PD RPCs. Reads come
/// from the public tables (the real server catalog, not the local seed);
/// writes ride the operator key already sitting in the Keychain — the same
/// credential that unlocks GO LIVE, so the desk simply appears for staff.
@MainActor
final class PDService: ObservableObject {

    struct CatalogTrack: Identifiable, Hashable {
        let id: UUID
        let title: String
        let artist: String
    }
    struct Pending: Identifiable {
        let id: Int64
        let trackID: UUID
        let title: String
        let artist: String
    }
    struct Drop: Identifiable {
        let id: UUID
        let title: String
        let active: Bool
    }

    @Published private(set) var catalog: [CatalogTrack] = []
    @Published private(set) var pending: [Pending] = []
    @Published private(set) var drops: [Drop] = []
    @Published private(set) var loaded = false
    @Published private(set) var note: String?

    private static let projectURL = URL(string: "https://tgkgdquivdoquxamtgcr.supabase.co")!
    private static let publishableKey = "sb_publishable_JYYXKdhcGnEP5curdG_pLg_XVcy9-ii"
    private let client = SupabaseClient(supabaseURL: PDService.projectURL,
                                        supabaseKey: PDService.publishableKey)

    private var hostKey: String { BroadcastService.hostKey() ?? "" }

    func refresh(stationID: UUID) async {
        defer { loaded = true }
        async let cat: Void = loadCatalog(stationID: stationID)
        async let pen: Void = loadPending(stationID: stationID)
        async let dro: Void = loadDrops(stationID: stationID)
        _ = await (cat, pen, dro)
    }

    private struct MemberRow: Decodable { let track_id: UUID }
    private struct TrackRow: Decodable { let track_id: UUID; let title: String; let artist: String }
    private struct PendingRow: Decodable {
        let id: Int64; let track_id: UUID; let title: String; let artist: String
    }
    private struct DropRow: Decodable { let id: UUID; let track_id: UUID; let active: Bool }

    private func loadCatalog(stationID: UUID) async {
        do {
            let members: [MemberRow] = try await client.from("radio_station_tracks")
                .select("track_id").eq("station_id", value: stationID)
                .execute().value
            let ids = members.map(\.track_id)
            guard !ids.isEmpty else { catalog = []; return }
            let rows: [TrackRow] = try await client.from("radio_tracks")
                .select("track_id,title,artist")
                .in("track_id", values: ids)
                .order("title")
                .execute().value
            catalog = rows.map { CatalogTrack(id: $0.track_id, title: $0.title, artist: $0.artist) }
        } catch { /* panel shows the honest empty state */ }
    }

    private func loadPending(stationID: UUID) async {
        do {
            let rows: [PendingRow] = try await client
                .rpc("radio_pending_queue", params: ["p_station": stationID.uuidString])
                .execute().value
            pending = rows.map { Pending(id: $0.id, trackID: $0.track_id,
                                         title: $0.title, artist: $0.artist) }
        } catch { pending = [] }
    }

    private func loadDrops(stationID: UUID) async {
        do {
            let rows: [DropRow] = try await client.from("radio_drops")
                .select("id,track_id,active")
                .or("station_id.eq.\(stationID.uuidString),station_id.is.null")
                .execute().value
            guard !rows.isEmpty else { drops = []; return }
            let titles: [TrackRow] = try await client.from("radio_tracks")
                .select("track_id,title,artist")
                .in("track_id", values: rows.map(\.track_id))
                .execute().value
            let byID = Dictionary(uniqueKeysWithValues: titles.map { ($0.track_id, $0.title) })
            drops = rows.map { Drop(id: $0.id, title: byID[$0.track_id] ?? "DROP", active: $0.active) }
        } catch { drops = [] }
    }

    /// First spin, scheduled: the record jumps the crowd and airs next.
    func premiere(_ track: CatalogTrack, stationID: UUID) async {
        struct P: Encodable { let p_station: String; let p_track: String; let p_key: String }
        do {
            let ok: Bool = try await client.rpc("radio_queue_premiere", params: P(
                p_station: stationID.uuidString, p_track: track.id.uuidString, p_key: hostKey
            )).execute().value
            note = ok ? "PREMIERE SET — \(track.title.uppercased()) AIRS NEXT"
                      : "REFUSED — ALREADY ON DECK OR KEY REJECTED"
            await loadPending(stationID: stationID)
        } catch { note = "NO SIGNAL — TRY AGAIN" }
    }

    func cancel(_ item: Pending, stationID: UUID) async {
        struct P: Encodable { let p_id: Int64; let p_key: String }
        do {
            _ = try await client.rpc("radio_cancel_premiere",
                                     params: P(p_id: item.id, p_key: hostKey)).execute()
            await loadPending(stationID: stationID)
        } catch { note = "NO SIGNAL — TRY AGAIN" }
    }

    func setDrop(_ drop: Drop, active: Bool, stationID: UUID) async {
        struct P: Encodable { let p_id: String; let p_active: Bool; let p_key: String }
        do {
            _ = try await client.rpc("radio_set_drop_active", params: P(
                p_id: drop.id.uuidString, p_active: active, p_key: hostKey
            )).execute()
            await loadDrops(stationID: stationID)
        } catch { note = "NO SIGNAL — TRY AGAIN" }
    }
}
