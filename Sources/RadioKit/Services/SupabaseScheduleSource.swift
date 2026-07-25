import Foundation
import Combine

/// The shared timeline, backed by the live OneSync radio backend.
///
/// This is the schedule source that actually ships. Where `LocalScheduleSource`
/// runs the rotation on-device (each listener their own copy) and
/// `RemoteScheduleSource` speaks a generic self-host websocket, this one reads
/// the real `radio_now_playing` that `radio_advance_stations()` maintains, so
/// every listener on a station hears the same second.
///
/// ## How it stays in sync
///
/// Two mechanisms, and the cheap one is the source of truth:
///
///  - **Polling** is the backbone. Each read of `radio_now_playing` returns
///    the current slot *and*, via the response's `Date` header, a fresh
///    `StationClock` sample. Between reads the client renders the held slot
///    against the disciplined clock, so all devices compute the same station
///    time and land on the same track. The poll sleeps until just after the
///    current slot ends (bounded), so it costs about one request per song.
///  - **Realtime** is an optional accelerant: a Supabase Realtime subscription
///    on `radio_now_playing` that, on any change, triggers an immediate poll.
///    It only ever says "re-read now", never carries state, so a change to the
///    Phoenix payload shape can't corrupt what plays — worst case it's silent
///    and polling still catches the change within a song.
///
/// If the network is down the source keeps rendering the last slot it saw
/// rather than going quiet, and resumes on the next successful poll.
@MainActor
public final class SupabaseScheduleSource: StationScheduleSource, ObservableObject {

    public struct Config: Sendable {
        public var client: SupabaseRadioClient.Config
        /// A specific station, or `nil` to tune to whatever's most live.
        public var stationID: UUID?
        /// Never wait longer than this between polls, so a server-side change
        /// with no realtime event still surfaces within a song or so.
        public var maxPollSeconds: Double
        /// A small floor, so a zero/short slot can't spin the poll loop.
        public var minPollSeconds: Double
        /// Re-read this soon after a slot's expected end, to catch the swap.
        public var endBufferSeconds: Double
        /// Subscribe to Realtime for instant updates on top of polling.
        public var useRealtime: Bool
        /// A heartbeat counts toward "listening now" for this long. Must
        /// comfortably exceed `maxPollSeconds` (heartbeats ride the poll), or
        /// live listeners would flicker out between polls.
        public var presenceWindowSeconds: Double

        public init(
            client: SupabaseRadioClient.Config = .oneSync,
            stationID: UUID? = nil,
            maxPollSeconds: Double = 30,
            minPollSeconds: Double = 2,
            endBufferSeconds: Double = 0.75,
            useRealtime: Bool = true,
            presenceWindowSeconds: Double = 75
        ) {
            self.client = client
            self.stationID = stationID
            self.maxPollSeconds = maxPollSeconds
            self.minPollSeconds = minPollSeconds
            self.endBufferSeconds = endBufferSeconds
            self.useRealtime = useRealtime
            self.presenceWindowSeconds = presenceWindowSeconds
        }
    }

    public enum ConnectionState: Equatable, Sendable {
        case idle
        case connecting
        case live
        case offline
    }

    // MARK: StationScheduleSource

    public var onScheduleChange: (@MainActor () -> Void)?
    /// The server tallies votes, so a local weighting function is unused here.
    public var netVoteWeight: (@MainActor (UUID) -> Double)?

    public private(set) var clock = StationClock()
    public private(set) var liveListenerCount: Int?
    public private(set) var recentPlays: [WeightedRotationEngine.PlayRecord] = []

    @Published public private(set) var connectionState: ConnectionState = .idle

    // MARK: State

    private static let maxHistory = 256

    private let config: Config
    private let client: SupabaseRadioClient
    private let now: () -> Date

    /// A stable per-install identifier used as the vote `listener_key`
    /// (radio_votes requires 8–64 chars; a UUID string is 36).
    private let listenerKey: String

    private var stationID: UUID?
    private var knownTracks: [UUID: Track] = [:]
    private var current: ScheduleSlot?

    private var pollTask: Task<Void, Never>?
    private var realtime: SupabaseRealtime?
    /// Set when realtime (or a vote) asks for an out-of-band re-read; the
    /// wait loop notices it and returns early.
    private var immediatePoll = false

    public init(
        config: Config = Config(),
        session: URLSession = .shared,
        listenerKey: String? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.now = now
        self.stationID = config.stationID
        self.client = SupabaseRadioClient(config: config.client, session: session, now: now)
        self.listenerKey = listenerKey ?? Self.persistentListenerKey()
    }

    public func track(withID id: UUID) -> Track? { knownTracks[id] }

    public func slot(at stationNow: Date) -> ScheduleSlot? { current }

    public func updateCatalog(_ tracks: [Track]) {
        // The catalog is the server's, fetched in the poll loop; a caller
        // handing us tracks (e.g. Navidrome) doesn't apply to this station,
        // but we still fold them in so ids resolve.
        for track in tracks { knownTracks[track.id] = track }
    }

    // MARK: Lifecycle

    public func start() {
        guard pollTask == nil else { return }
        connectionState = .connecting
        pollTask = Task { [weak self] in
            await self?.run()
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        realtime?.disconnect()
        realtime = nil
        connectionState = .idle
    }

    /// Forwarded from `LiveStreamService.vote()` for a server-tallied station.
    public func castVote(_ direction: VoteDirection, on trackID: UUID) {
        guard let stationID else { return }
        let client = self.client
        let key = self.listenerKey
        Task { [weak self] in
            try? await client.castVote(
                stationID: stationID,
                trackID: trackID,
                listenerKey: key,
                direction: direction
            )
            // Surface the server's re-tally sooner than the next timed poll.
            self?.requestImmediatePoll()
        }
    }

    /// Ask the poll loop to re-read now instead of waiting out its timer.
    private func requestImmediatePoll() {
        immediatePoll = true
    }

    // MARK: Poll loop

    private func run() async {
        // Resolve the station once, then subscribe + poll.
        if stationID == nil {
            stationID = try? await client.resolveLiveStation()
        }
        guard let stationID else {
            connectionState = .offline
            return
        }

        try? await loadCatalog(stationID: stationID)
        connectRealtime(stationID: stationID)

        while !Task.isCancelled {
            let sleep = await pollOnce(stationID: stationID)
            await waitForNextPoll(seconds: sleep)
        }
    }

    /// One read. Returns how long to wait before the next one.
    private func pollOnce(stationID: UUID) async -> Double {
        do {
            guard let result = try await client.fetchNowPlaying(stationID: stationID) else {
                connectionState = .live
                await updatePresence(stationID: stationID)
                return config.maxPollSeconds
            }
            connectionState = .live
            if let sample = result.clockSample { clock.ingest(sample) }
            apply(result.slot, track: result.track)
            await updatePresence(stationID: stationID)
            return interval(until: result.slot)
        } catch {
            // Keep rendering the last slot; try again soon. A count from a
            // previous poll is stale news now — better no number than a
            // frozen one.
            connectionState = .offline
            liveListenerCount = nil
            return min(config.maxPollSeconds, max(config.minPollSeconds, 5))
        }
    }

    /// Heartbeat, then read back how many listeners are live. Rides the poll
    /// cadence: about one beat per song. Best-effort — a failed heartbeat
    /// only means this listener may briefly not be counted.
    private func updatePresence(stationID: UUID) async {
        try? await client.sendHeartbeat(stationID: stationID, listenerKey: listenerKey)
        // The cutoff is quoted in station time because the server stamps
        // `last_seen` with its clock, not ours.
        let cutoff = clock.stationTime(forDevice: now())
            .addingTimeInterval(-config.presenceWindowSeconds)
        guard let count = try? await client.fetchListenerCount(stationID: stationID, since: cutoff) else {
            return
        }
        if count != liveListenerCount {
            liveListenerCount = count
            onScheduleChange?()
        }
    }

    private func apply(_ slot: ScheduleSlot, track: Track) {
        knownTracks[track.id] = track
        // Don't re-record the same slot: the server re-serves the current
        // track on every poll, and counting each read as a play would feed
        // the complement rules phantom rotation.
        guard slot != current else {
            onScheduleChange?()
            return
        }
        current = slot
        recentPlays.append(.init(trackID: track.id, artistID: track.artistID, playedAt: slot.startedAt))
        if recentPlays.count > Self.maxHistory {
            recentPlays.removeFirst(recentPlays.count - Self.maxHistory)
        }
        onScheduleChange?()
    }

    /// Sleep until just past the current slot's end, in station time, clamped.
    private func interval(until slot: ScheduleSlot) -> Double {
        let stationNow = clock.stationTime(forDevice: now())
        let remaining = slot.endsAt.timeIntervalSince(stationNow) + config.endBufferSeconds
        return min(config.maxPollSeconds, max(config.minPollSeconds, remaining))
    }

    /// Wait `seconds`, but return early if realtime or a vote asked to
    /// re-read. Sliced so the wake-up is prompt without a second timer or a
    /// dependence on the injected clock advancing.
    private func waitForNextPoll(seconds: Double) async {
        // Don't clear the flag up front: a nudge that arrived during the poll
        // should end the wait immediately rather than be lost.
        var remaining = seconds
        let slice = 0.25
        while !Task.isCancelled && remaining > 0 {
            if immediatePoll { break }
            let step = min(slice, remaining)
            try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
            remaining -= step
        }
        immediatePoll = false
    }

    // MARK: Catalog + realtime

    private func loadCatalog(stationID: UUID) async throws {
        let tracks = try await client.fetchCatalog(stationID: stationID)
        for track in tracks { knownTracks[track.id] = track }
        onScheduleChange?()
    }

    private func connectRealtime(stationID: UUID) {
        guard config.useRealtime else { return }
        let realtime = SupabaseRealtime(
            config: config.client,
            table: "radio_now_playing",
            stationID: stationID
        )
        realtime.onChange = { [weak self] in
            Task { @MainActor in self?.requestImmediatePoll() }
        }
        realtime.connect()
        self.realtime = realtime
    }

    // MARK: - Listener key

    private static func persistentListenerKey() -> String {
        let key = "RadioListenerKey"
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: key), existing.count >= 8 {
            return existing
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: key)
        return fresh
    }
}
