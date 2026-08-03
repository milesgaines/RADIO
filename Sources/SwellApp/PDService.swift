import Foundation
import AVFoundation
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

    // MARK: - Loading the library

    private struct AddParams: Encodable {
        let p_key: String; let p_station: String; let p_title: String
        let p_artist: String; let p_duration: Double; let p_url: String
    }

    /// A readable title out of a URL or filename — "my_track-final.mp3" →
    /// "my track final". The PD sees exactly what will air.
    private static func titleGuess(from name: String) -> String {
        var base = name
        if let q = base.firstIndex(of: "?") { base = String(base[..<q]) }
        base = (base as NSString).lastPathComponent
        base = (base as NSString).deletingPathExtension
        base = base.removingPercentEncoding ?? base
        base = base.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return base.isEmpty ? "UNTITLED" : base
    }

    /// The shared clock NEEDS a real duration — probe the asset before filing.
    private static func probeDuration(_ url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let d = try? await asset.load(.duration) else { return nil }
        let secs = d.seconds
        return (secs.isFinite && secs > 0) ? secs : nil
    }

    /// Bulk add-by-URL: one line per record. Each URL is probed for a real
    /// duration (the shared clock depends on it), then filed key-gated.
    func addByURLs(_ text: String, stationID: UUID) async {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("http") }
        guard !lines.isEmpty else { note = "NO URLS — ONE PER LINE"; return }
        var added = 0, failed = 0
        for line in lines {
            guard let url = URL(string: line),
                  let duration = await Self.probeDuration(url) else { failed += 1; continue }
            do {
                let tid: UUID? = try await client.rpc("radio_add_track", params: AddParams(
                    p_key: hostKey, p_station: stationID.uuidString,
                    p_title: Self.titleGuess(from: line), p_artist: "",
                    p_duration: duration, p_url: line
                )).execute().value
                tid != nil ? (added += 1) : (failed += 1)
            } catch { failed += 1 }
            note = "LOADING… \(added) IN · \(failed) REFUSED"
        }
        note = "LIBRARY: \(added) ADDED" + (failed > 0 ? " · \(failed) REFUSED (BAD URL OR NO DURATION)" : "")
        await loadCatalog(stationID: stationID)
    }

    /// Upload masters from the phone (Files app): each file is probed for
    /// duration locally, shipped to the key-gated upload function, then filed.
    func uploadFiles(_ files: [URL], stationID: UUID) async {
        var added = 0, failed = 0
        for file in files {
            let scoped = file.startAccessingSecurityScopedResource()
            defer { if scoped { file.stopAccessingSecurityScopedResource() } }
            guard let duration = await Self.probeDuration(file),
                  let data = try? Data(contentsOf: file),
                  data.count <= 25 * 1024 * 1024 else { failed += 1; continue }
            guard let publicURL = await upload(data: data, filename: file.lastPathComponent)
            else { failed += 1; continue }
            do {
                let tid: UUID? = try await client.rpc("radio_add_track", params: AddParams(
                    p_key: hostKey, p_station: stationID.uuidString,
                    p_title: Self.titleGuess(from: file.lastPathComponent), p_artist: "",
                    p_duration: duration, p_url: publicURL
                )).execute().value
                tid != nil ? (added += 1) : (failed += 1)
            } catch { failed += 1 }
            note = "UPLOADING… \(added) IN · \(failed) REFUSED"
        }
        note = "LIBRARY: \(added) UPLOADED" + (failed > 0 ? " · \(failed) REFUSED (FORMAT, SIZE, OR SIGNAL)" : "")
        await loadCatalog(stationID: stationID)
    }

    private func upload(data: Data, filename: String) async -> String? {
        guard let endpoint = URL(string:
            "https://tgkgdquivdoquxamtgcr.supabase.co/functions/v1/track-upload")
        else { return nil }
        let boundary = "radi0-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("key", hostKey)
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.publishableKey, forHTTPHeaderField: "apikey")
        req.httpBody = body
        guard let (respData, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        struct Reply: Decodable { let ok: Bool?; let url: String? }
        return (try? JSONDecoder().decode(Reply.self, from: respData))?.url
    }

    /// Pull a record from this station's rotation (unlink — history and other
    /// stations keep it; the server refuses to empty a station entirely).
    func removeFromRotation(_ track: CatalogTrack, stationID: UUID) async {
        struct P: Encodable { let p_key: String; let p_station: String; let p_track: String }
        do {
            let ok: Bool = try await client.rpc("radio_remove_station_track", params: P(
                p_key: hostKey, p_station: stationID.uuidString, p_track: track.id.uuidString
            )).execute().value
            note = ok ? "PULLED — \(track.title.uppercased())"
                      : "REFUSED — LAST RECORD OR KEY REJECTED"
            await loadCatalog(stationID: stationID)
        } catch { note = "NO SIGNAL — TRY AGAIN" }
    }
}
