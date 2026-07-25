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

            await MainActor.run {
                self.streamTasks.append(presenceTask)
                self.streamTasks.append(votesTask)
            }

            await newChannel.subscribe()
            try? await newChannel.track(state: ["listener": .string(self.listenerKey)])
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
