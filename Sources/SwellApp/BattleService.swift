import Foundation
import AVFoundation
import Supabase

/// THE RING — song battles. Two uploaded records face off on a shared
/// countdown; the crowd votes a side; the winner ENTERS ROTATION on 1200
/// THE UNDERGROUND. The server (`radio_battle_director` on pg_cron) pairs,
/// scores, and settles — this client only renders and votes, the same
/// principle as the radio itself: the server decides, the client renders.
///
/// The legal line battles must not cross: a battle vote decides which
/// record JOINS the rotation pool — it is never "play this next". Airplay
/// of the winner still flows through the vote-weighted director, so the
/// broadcast stays non-interactive (the Arista v. Launch Media rule).
@MainActor
final class BattleService: ObservableObject {

    struct Entry: Identifiable, Equatable {
        let id: UUID
        let title: String
        let artist: String
        let audioURL: URL?
        let durationSeconds: Double
    }

    struct Battle: Identifiable, Equatable {
        let id: UUID
        let a: Entry
        let b: Entry
        let startsAt: Date
        let endsAt: Date
        let aScore: Int
        let bScore: Int
        let status: String      // "open" | "settled"
        let winner: UUID?
    }

    enum SubmitState: Equatable {
        case idle, uploading, queued, failed(String)
    }

    @Published private(set) var battle: Battle?
    @Published private(set) var queueCount: Int = 0
    /// "a" | "b" once this device voted in the current battle. Persisted per
    /// battle id so a relaunch doesn't forget the vote.
    @Published private(set) var myVote: String?
    @Published var submitState: SubmitState = .idle

    // Publishable client credentials (safe to ship; RLS is the boundary).
    private static let projectURL = URL(string: "https://tgkgdquivdoquxamtgcr.supabase.co")!
    private static let publishableKey = "sb_publishable_JYYXKdhcGnEP5curdG_pLg_XVcy9-ii"
    private static let submitURL = URL(string: "https://tgkgdquivdoquxamtgcr.supabase.co/functions/v1/battle-submit")!

    private let client: SupabaseClient
    private let listenerKey: String
    private var channel: RealtimeChannelV2?
    private var realtimeTasks: [Task<Void, Never>] = []

    init(listenerKey: String) {
        self.listenerKey = listenerKey
        self.client = SupabaseClient(
            supabaseURL: Self.projectURL,
            supabaseKey: Self.publishableKey
        )
    }

    private struct BattleRow: Decodable {
        let id: UUID
        let entry_a: UUID
        let entry_b: UUID
        let starts_at: Date
        let ends_at: Date
        let status: String
        let a_score: Int
        let b_score: Int
        let winner: UUID?
    }

    private struct EntryRow: Decodable {
        let id: UUID
        let title: String
        let artist: String
        let audio_url: String
        let duration_seconds: Double
    }

    // MARK: - Reads

    func refresh() async {
        // The latest battle: open, or settled recently enough that the
        // winner moment is still worth showing (the bell just rang).
        let rows: [BattleRow]? = try? await client
            .from("radio_battles")
            .select()
            .order("created_at", ascending: false)
            .limit(1)
            .execute()
            .value
        if let row = rows?.first,
           row.status == "open" || row.ends_at > Date().addingTimeInterval(-15 * 60) {
            let ids = [row.entry_a.uuidString, row.entry_b.uuidString]
            let entries: [EntryRow]? = try? await client
                .from("radio_battle_entries")
                .select()
                .in("id", values: ids)
                .execute()
                .value
            if let entries,
               let ea = entries.first(where: { $0.id == row.entry_a }),
               let eb = entries.first(where: { $0.id == row.entry_b }) {
                battle = Battle(
                    id: row.id,
                    a: Entry(id: ea.id, title: ea.title, artist: ea.artist,
                             audioURL: URL(string: ea.audio_url),
                             durationSeconds: ea.duration_seconds),
                    b: Entry(id: eb.id, title: eb.title, artist: eb.artist,
                             audioURL: URL(string: eb.audio_url),
                             durationSeconds: eb.duration_seconds),
                    startsAt: row.starts_at, endsAt: row.ends_at,
                    aScore: row.a_score, bScore: row.b_score,
                    status: row.status, winner: row.winner
                )
                myVote = UserDefaults.standard.string(forKey: "ring.vote.\(row.id.uuidString)")
            }
        } else {
            battle = nil
            myVote = nil
        }
        let count = try? await client
            .from("radio_battle_entries")
            .select("*", head: true, count: .exact)
            .eq("status", value: "queued")
            .execute()
            .count
        queueCount = count ?? 0
    }

    // MARK: - Realtime

    /// Battles are low-traffic: any change to the battle table (a vote's
    /// score bump, a settle, a new pairing) just re-reads the whole state.
    func startRealtime() {
        guard channel == nil else { return }
        let ch = client.channel("radio:ring")
        channel = ch

        let changes = ch.postgresChange(AnyAction.self, schema: "public", table: "radio_battles")
        let changesTask = Task { [weak self] in
            for await _ in changes {
                guard let self, self.channel === ch else { return }
                await self.refresh()
            }
        }
        let statuses = ch.statusChange
        let statusTask = Task { [weak self] in
            for await status in statuses {
                guard let self, self.channel === ch else { return }
                guard status == .subscribed else { continue }
                // Rejoin recovery: realtime has no replay, so re-read.
                await self.refresh()
            }
        }
        let joinTask = Task { [weak self] in
            var backoff: UInt64 = 1_000_000_000
            while !Task.isCancelled, self?.channel === ch {
                do {
                    try await ch.subscribeWithError()
                    break
                } catch {
                    try? await Task.sleep(nanoseconds: backoff)
                    backoff = min(backoff * 2, 30_000_000_000)
                }
            }
        }
        realtimeTasks = [changesTask, statusTask, joinTask]
    }

    func stopRealtime() {
        realtimeTasks.forEach { $0.cancel() }
        realtimeTasks.removeAll()
        if let ch = channel {
            channel = nil
            Task { await ch.unsubscribe() }
        }
    }

    // MARK: - Votes

    /// One vote per listener per battle, switching sides allowed — enforced
    /// server-side by the definer function, mirrored optimistically here.
    func vote(_ side: String) {
        guard let battle, battle.status == "open", side == "a" || side == "b" else { return }
        myVote = side
        UserDefaults.standard.set(side, forKey: "ring.vote.\(battle.id.uuidString)")
        Task { [weak self] in
            struct Params: Encodable {
                let p_battle: UUID
                let p_listener: String
                let p_side: String
            }
            guard let self else { return }
            _ = try? await self.client
                .rpc("radio_cast_battle_vote",
                     params: Params(p_battle: battle.id, p_listener: self.listenerKey, p_side: side))
                .execute()
            await self.refresh()
        }
    }

    // MARK: - Entry upload

    func submit(fileURL: URL, title: String, artist: String) async {
        submitState = .uploading
        // Probe the real duration client-side — the server can't cheaply
        // decode audio, and rotation scheduling needs a truthful length.
        let asset = AVURLAsset(url: fileURL)
        let duration = (try? await asset.load(.duration).seconds) ?? 0

        guard let data = try? Data(contentsOf: fileURL) else {
            submitState = .failed("CAN'T READ THE FILE")
            return
        }
        guard data.count <= 20 * 1024 * 1024 else {
            submitState = .failed("TOO BIG — 20MB MAX")
            return
        }
        guard duration >= 30 else {
            submitState = .failed("30 SECONDS MINIMUM — SEND A REAL RECORD")
            return
        }

        let boundary = "ring-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("title", title)
        field("artist", artist)
        field("listener_key", listenerKey)
        field("duration_seconds", String(duration))
        let ext = fileURL.pathExtension.lowercased()
        let mime = ["mp3": "audio/mpeg", "m4a": "audio/mp4", "aac": "audio/aac",
                    "wav": "audio/wav"][ext] ?? "audio/mpeg"
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"track.\(ext.isEmpty ? "mp3" : ext)\"\r\nContent-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: Self.submitURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.publishableKey, forHTTPHeaderField: "apikey")

        do {
            let (respData, response) = try await URLSession.shared.upload(for: request, from: body)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200:
                submitState = .queued
                try? FileManager.default.removeItem(at: fileURL) // the tmp copy
                await refresh()
            case 429:
                submitState = .failed("DAILY LIMIT — 3 ENTRIES A DAY")
            default:
                struct Err: Decodable { let error: String? }
                let msg = (try? JSONDecoder().decode(Err.self, from: respData))?.error ?? "UPLOAD FAILED"
                submitState = .failed(msg.uppercased())
            }
        } catch {
            submitState = .failed("NO SIGNAL — TRY AGAIN")
        }
    }
}
