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

    var onPresenceCount: (Int) -> Void = { _ in }
    var onRemoteVote: (_ trackID: UUID, _ direction: Int, _ fromKey: String) -> Void = { _, _, _ in }
    /// The shared clock: what the SERVER says is on air for the tuned
    /// station, and exactly when it started.
    var onRemoteClock: (_ trackID: UUID, _ startedAt: Date, _ duration: Double) -> Void = { _, _, _ in }

    private struct NowRow: Decodable {
        let station_id: UUID
        let track_id: UUID
        let started_at: Date
        let duration_seconds: Double
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
            guard let self, !Task.isCancelled else { return }

            // Presence: the channel's live membership IS the listener count.
            let presences = newChannel.presenceChange()
            let presenceTask = Task { [weak self] in
                for await change in presences {
                    guard let self else { return }
                    for join in change.joins.keys { self.presentKeys.insert(join) }
                    for leave in change.leaves.keys { self.presentKeys.remove(leave) }
                    self.onPresenceCount(max(1, self.presentKeys.count))
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
                    guard let self else { return }
                    let record = insert.record
                    guard
                        case let .string(rowStation)? = record["station_id"],
                        rowStation == stationID,
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
                    self.onRemoteVote(trackID, direction, fromKey)
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
                    guard let self else { return }
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
                    self.onRemoteClock(trackID, startedAt, duration)
                }
            }

            await MainActor.run {
                self.streamTasks.append(presenceTask)
                self.streamTasks.append(votesTask)
                self.streamTasks.append(clockTask)
            }

            await newChannel.subscribe()
            try? await newChannel.track(state: ["listener": .string(self.listenerKey)])

            // Join mid-song correctly: fetch what's on air right now.
            if let row: NowRow = try? await self.client
                .from("radio_now_playing")
                .select()
                .eq("station_id", value: stationID)
                .single()
                .execute()
                .value {
                self.onRemoteClock(row.track_id, row.started_at, row.duration_seconds)
            }
        }
        streamTasks.append(task)
    }

    /// Cast this device's vote into the shared stream. Fire-and-forget;
    /// the local tally already applied it optimistically.
    func sendVote(stationID: String, trackID: UUID, direction: Int) {
        Task { [client] in
            struct Row: Encodable {
                let station_id: String
                let track_id: String
                let listener_key: String
                let direction: Int
            }
            _ = try? await client
                .from("radio_votes")
                .insert(Row(
                    station_id: stationID,
                    track_id: trackID.uuidString,
                    listener_key: listenerKey,
                    direction: direction
                ))
                .execute()
        }
    }
}
