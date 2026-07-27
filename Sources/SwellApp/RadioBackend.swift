import Foundation
import Supabase
import RadioKit

/// The real numbers. Connects the app to the OFFICIAL ONESYNC Supabase
/// project: realtime presence (who is actually tuned in, per station) and
/// the live vote stream (real boosts from real devices). No fabrication —
/// when two people are listening, the number says 2.
@MainActor
final class RadioBackend {

    // Publishable client credentials (safe to ship; RLS is the boundary).
    private static let projectURL = URL(string: "https://tgkgdquivdoquxamtgcr.supabase.co")!
    private static let publishableKey = "sb_publishable_JYYXKdhcGnEP5curdG_pLg_XVcy9-ii"

    private let client: SupabaseClient
    private var channel: RealtimeChannelV2?
    private var streamTasks: [Task<Void, Never>] = []
    private var presentKeys: Set<String> = []

    /// Stable per-device identity — the persisted listener id.
    let listenerKey: String

    /// Every callback names the station it belongs to, so a slow response
    /// that lands after a station switch is routed to the *right* stream —
    /// never to "whichever stream is active at delivery time".
    var onPresenceCount: (_ count: Int, _ stationID: String) -> Void = { _, _ in }
    var onRemoteVote: (_ trackID: UUID, _ direction: Int, _ fromKey: String, _ stationID: String) -> Void = { _, _, _, _ in }
    /// The shared clock: what the SERVER says is on air for the tuned
    /// station, and exactly when it started.
    var onRemoteClock: (_ trackID: UUID, _ startedAt: Date, _ duration: Double, _ stationID: String) -> Void = { _, _, _, _ in }
    /// LIVE flips: a human takes (or leaves) the air on this station.
    var onLiveShow: (_ live: Bool, _ title: String, _ hlsURL: String, _ stationID: String) -> Void = { _, _, _, _ in }

    private struct NowRow: Decodable {
        let station_id: UUID
        let track_id: UUID
        let started_at: Date
        let duration_seconds: Double
    }

    private struct LiveRow: Decodable {
        let station_id: UUID
        let live: Bool
        let title: String
        let hls_url: String
    }

    struct TrackRow: Decodable {
        let track_id: UUID
        let title: String
        let artist: String
        let artist_id: UUID
        let duration_seconds: Double
        let audio_url: String?
    }

    /// Metadata for a track the device doesn't carry — the ALGO station's
    /// remote catalog lives server-side.
    func fetchTrack(_ trackID: UUID) async -> TrackRow? {
        try? await client
            .from("radio_tracks")
            .select()
            .eq("track_id", value: trackID.uuidString)
            .single()
            .execute()
            .value
    }

    /// Postgres timestamptz arrives with microseconds ("…08.123456+00:00"),
    /// which ISO8601DateFormatter rejects — parse the common shapes directly.
    private static let pgDateFormats: [DateFormatter] = {
        ["yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX",
         "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
         "yyyy-MM-dd'T'HH:mm:ssXXXXX"].map { pattern in
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(identifier: "UTC")
            df.dateFormat = pattern
            return df
        }
    }()

    private static func parseDate(_ raw: String) -> Date? {
        for f in pgDateFormats { if let d = f.date(from: raw) { return d } }
        return nil
    }

    init(listenerKey: String) {
        self.listenerKey = listenerKey
        self.client = SupabaseClient(
            supabaseURL: Self.projectURL,
            supabaseKey: Self.publishableKey
        )
    }

    /// Join a station's room: track presence there and follow its votes.
    func tune(toStationID stationID: String) {
        streamTasks.forEach { $0.cancel() }
        streamTasks.removeAll()
        presentKeys.removeAll()

        let oldChannel = channel
        let newChannel = client.channel("radio:\(stationID)")
        channel = newChannel

        let task = Task { [weak self] in
            if let oldChannel {
                await oldChannel.unsubscribe()
                await self?.client.removeChannel(oldChannel)
            }
            guard let self, !Task.isCancelled, self.channel === newChannel else { return }

            // Presence: the channel's live membership IS the listener count.
            let presences = newChannel.presenceChange()
            let presenceTask = Task { [weak self] in
                for await change in presences {
                    guard let self, self.channel === newChannel else { return }
                    for join in change.joins.keys { self.presentKeys.insert(join) }
                    for leave in change.leaves.keys { self.presentKeys.remove(leave) }
                    self.onPresenceCount(max(1, self.presentKeys.count), stationID)
                }
            }

            // Votes: every INSERT on radio_votes for this station, live.
            let inserts = newChannel.postgresChange(
                InsertAction.self,
                schema: "public",
                table: "radio_votes"
            )
            let votesTask = Task { [weak self] in
                for await insert in inserts {
                    guard let self, self.channel === newChannel else { return }
                    let record = insert.record
                    guard
                        case let .string(rowStation)? = record["station_id"],
                        // Votes store uppercase, but match case-insensitively
                        // like the clock/live handlers do — an exact compare
                        // silently dropped cross-cased votes from the tally.
                        rowStation.caseInsensitiveCompare(stationID) == .orderedSame,
                        case let .string(rawTrack)? = record["track_id"],
                        let trackID = UUID(uuidString: rawTrack),
                        case let .string(fromKey)? = record["listener_key"],
                        fromKey != self.listenerKey
                    else { continue }
                    let direction: Int
                    switch record["direction"] {
                    case .integer(let d)?: direction = d
                    case .double(let d)?: direction = Int(d)
                    case .string(let s)?: direction = Int(s) ?? 1
                    default: direction = 1
                    }
                    self.onRemoteVote(trackID, direction, fromKey, stationID)
                }
            }

            // The shared clock: every change to this station's now_playing
            // row, live. The server decides what's on air; we render it.
            let clockChanges = newChannel.postgresChange(
                AnyAction.self,
                schema: "public",
                table: "radio_now_playing"
            )
            let clockTask = Task { [weak self] in
                for await change in clockChanges {
                    guard let self, self.channel === newChannel else { return }
                    let record: [String: AnyJSON]
                    switch change {
                    case .insert(let a): record = a.record
                    case .update(let a): record = a.record
                    default: continue
                    }
                    guard
                        case let .string(rowStation)? = record["station_id"],
                        rowStation.caseInsensitiveCompare(stationID) == .orderedSame,
                        case let .string(rawTrack)? = record["track_id"],
                        let trackID = UUID(uuidString: rawTrack),
                        case let .string(rawStart)? = record["started_at"],
                        let startedAt = Self.parseDate(rawStart)
                    else { continue }
                    let duration: Double
                    switch record["duration_seconds"] {
                    case .double(let d)?: duration = d
                    case .integer(let i)?: duration = Double(i)
                    case .string(let s)?: duration = Double(s) ?? 0
                    default: duration = 0
                    }
                    self.onRemoteClock(trackID, startedAt, duration, stationID)
                }
            }

            // LIVE flips: when a human takes the air, every tuned device
            // swaps from the rotation clock to the HLS stream — instantly.
            let liveChanges = newChannel.postgresChange(
                AnyAction.self,
                schema: "public",
                table: "radio_live"
            )
            let liveTask = Task { [weak self] in
                for await change in liveChanges {
                    guard let self, self.channel === newChannel else { return }
                    let record: [String: AnyJSON]
                    switch change {
                    case .insert(let a): record = a.record
                    case .update(let a): record = a.record
                    default: continue
                    }
                    guard
                        case let .string(rowStation)? = record["station_id"],
                        rowStation.caseInsensitiveCompare(stationID) == .orderedSame
                    else { continue }
                    let live: Bool
                    if case let .bool(b)? = record["live"] { live = b } else { live = false }
                    let title: String
                    if case let .string(t)? = record["title"] { title = t } else { title = "" }
                    let hls: String
                    if case let .string(h)? = record["hls_url"] { hls = h } else { hls = "" }
                    self.onLiveShow(live, title, hls, stationID)
                }
            }

            // Every (re)join — first subscribe, socket auto-reconnect,
            // foreground after background — runs the same recovery: presence
            // resets to the fresh authoritative state, this device re-tracks
            // itself, and the now_playing + live rows are re-fetched
            // (Realtime has no event replay, so any flip missed while
            // offline is gone unless we ask).
            let statuses = newChannel.statusChange
            let statusTask = Task { [weak self] in
                for await status in statuses {
                    guard let self, self.channel === newChannel else { return }
                    guard status == .subscribed else { continue }
                    self.presentKeys.removeAll()
                    try? await newChannel.track(state: ["listener": .string(self.listenerKey)])
                    await self.fetchNowPlaying(stationID: stationID, on: newChannel)
                    await self.fetchLive(stationID: stationID, on: newChannel)
                }
            }

            await MainActor.run {
                self.streamTasks.append(presenceTask)
                self.streamTasks.append(votesTask)
                self.streamTasks.append(clockTask)
                self.streamTasks.append(liveTask)
                self.streamTasks.append(statusTask)
            }

            // Join failures (launch offline, mid-transition) must not kill
            // realtime for the whole session: keep retrying while this is
            // still the tuned station.
            var backoff: UInt64 = 1_000_000_000
            while !Task.isCancelled, self.channel === newChannel {
                do {
                    try await newChannel.subscribeWithError()
                    break // statusTask takes it from here (and on every rejoin)
                } catch {
                    try? await Task.sleep(nanoseconds: backoff)
                    backoff = min(backoff * 2, 30_000_000_000)
                }
            }
        }
        streamTasks.append(task)
    }

    /// Fetch the shared clock's current row, with a couple of retries — a
    /// transient failure here would otherwise mean minutes of wrong-track.
    private func fetchNowPlaying(stationID: String, on channel: RealtimeChannelV2) async {
        for attempt in 0..<3 {
            guard self.channel === channel else { return }
            if let row: NowRow = try? await client
                .from("radio_now_playing")
                .select()
                .eq("station_id", value: stationID)
                .single()
                .execute()
                .value {
                guard self.channel === channel else { return }
                onRemoteClock(row.track_id, row.started_at, row.duration_seconds, stationID)
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(1 << attempt) * 1_000_000_000)
        }
    }

    /// Live state is re-fetched on every (re)join — a flip missed while
    /// offline must not leave the device playing rotation over a live show,
    /// or stuck in a show that already ended.
    private func fetchLive(stationID: String, on channel: RealtimeChannelV2) async {
        guard self.channel === channel else { return }
        let rows: [LiveRow]? = try? await client
            .from("radio_live")
            .select()
            .eq("station_id", value: stationID)
            .execute()
            .value
        guard self.channel === channel else { return }
        if let row = rows?.first {
            onLiveShow(row.live, row.title, row.hls_url, stationID)
        } else {
            onLiveShow(false, "", "", stationID)
        }
    }

    /// Cast this device's vote through the integrity RPC — one vote per device
    /// per track, throttled and upserted server-side. Direct table inserts are
    /// revoked, so this is the only path; the local tally already applied it
    /// optimistically, so this stays fire-and-forget.
    func sendVote(stationID: String, trackID: UUID, direction: Int) {
        Task { [client, listenerKey] in
            struct Params: Encodable {
                let p_station: String
                let p_track: String
                let p_listener: String
                let p_direction: Int
            }
            _ = try? await client
                .rpc("radio_cast_vote", params: Params(
                    p_station: stationID,
                    p_track: trackID.uuidString,
                    p_listener: listenerKey,
                    p_direction: direction
                ))
                .execute()
        }
    }
}
