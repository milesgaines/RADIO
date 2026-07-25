import Foundation
import Combine

/// The server-backed timeline: a websocket client that renders the station
/// every other listener is hearing.
///
/// The server runs the same `WeightedRotationEngine` this app ships, tallies
/// votes from every listener, and pushes "what's on air and when it started"
/// stamped with its own clock. This class holds the latest push and keeps a
/// `StationClock` disciplined against that stamp; `LiveStreamService` turns the
/// pair into a `NowPlaying` in device time. No rotation decisions happen here.
///
/// ## Wire format
///
/// Text frames of JSON, timestamps as epoch seconds (a number, so no date
/// format has to agree across a Swift client and whatever the server is
/// written in). Server → client:
///
/// ```json
/// {"type":"nowPlaying","trackId":"3F2504E0-4F89-11D3-9A0C-0305E82C3301",
///  "startedAt":1785000000.0,"durationSeconds":214.0,
///  "serverTime":1785000042.5,"listeners":128}
///
/// {"type":"sync","clientSentAt":1785000040.0,"serverTime":1785000040.06}
/// ```
///
/// Client → server:
///
/// ```json
/// {"type":"sync","clientSentAt":1785000040.0}
/// ```
///
/// `trackId` is resolved against the catalog this client already fetched
/// (Navidrome, or the demo set) — the schedule carries ids, not metadata, so a
/// push stays small enough to send on every track change.
///
/// Only the `sync` round trip feeds the clock. The `serverTime` on a push is a
/// one-way stamp with no measured latency, so treating it as a sample would
/// mean recording an unknowably-optimistic round trip and locking out the
/// honest measurements that follow.
@MainActor
public final class RemoteScheduleSource: StationScheduleSource, ObservableObject {

    public struct Config: Sendable {
        /// `wss://…` endpoint for the station's schedule feed.
        public var url: URL
        /// How often to re-measure the clock offset.
        public var syncIntervalSeconds: Double
        /// First reconnect delay; doubles up to `maxReconnectDelaySeconds`.
        public var initialReconnectDelaySeconds: Double
        public var maxReconnectDelaySeconds: Double

        public init(
            url: URL,
            syncIntervalSeconds: Double = 30,
            initialReconnectDelaySeconds: Double = 1,
            maxReconnectDelaySeconds: Double = 30
        ) {
            self.url = url
            self.syncIntervalSeconds = syncIntervalSeconds
            self.initialReconnectDelaySeconds = initialReconnectDelaySeconds
            self.maxReconnectDelaySeconds = maxReconnectDelaySeconds
        }
    }

    public enum ConnectionState: Equatable, Sendable {
        case idle
        case connecting
        case live
        /// Disconnected; retrying in `retryingInSeconds`.
        case offline(retryingInSeconds: Double)
    }

    public var onScheduleChange: (@MainActor () -> Void)?
    /// The server tallies votes itself, so a local weighting function has
    /// nothing to do here.
    public var netVoteWeight: (@MainActor (UUID) -> Double)?

    @Published public private(set) var connectionState: ConnectionState = .idle

    public private(set) var clock: StationClock
    public private(set) var liveListenerCount: Int?
    public private(set) var recentPlays: [WeightedRotationEngine.PlayRecord] = []

    private static let maxHistory = 256

    private let config: Config
    private let session: URLSession
    private let now: () -> Date

    private var knownTracks: [UUID: Track] = [:]
    private var current: ScheduleSlot?

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var reconnectDelay: Double

    public init(
        config: Config,
        catalog: [Track] = [],
        session: URLSession = .shared,
        clock: StationClock = StationClock(),
        now: @escaping () -> Date = { Date() }
    ) {
        self.config = config
        self.session = session
        self.clock = clock
        self.now = now
        self.reconnectDelay = config.initialReconnectDelaySeconds
        self.knownTracks = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - StationScheduleSource

    public func track(withID id: UUID) -> Track? { knownTracks[id] }

    public func updateCatalog(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        var known = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Keep the on-air track resolvable even if the swap dropped it.
        if let id = current?.trackID, let playing = knownTracks[id] {
            known[id] = playing
        }
        knownTracks = known
        onScheduleChange?()
    }

    /// The last slot the server pushed. Returned even once it has run past its
    /// end: if the socket stalls, the honest state is "this is the last thing
    /// the station told us", and the service renders that rather than silence.
    public func slot(at stationNow: Date) -> ScheduleSlot? { current }

    // MARK: - Connection

    public func start() {
        guard socket == nil else { return }
        connect()
    }

    public func stop() {
        receiveTask?.cancel()
        receiveTask = nil
        syncTask?.cancel()
        syncTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        connectionState = .idle
    }

    private func connect() {
        connectionState = .connecting
        let task = session.webSocketTask(with: config.url)
        socket = task
        task.resume()

        receiveTask = Task { [weak self] in
            await self?.receiveLoop(on: task)
        }
        syncTask = Task { [weak self] in
            await self?.syncLoop(on: task)
        }
    }

    private func receiveLoop(on task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                guard !Task.isCancelled else { return }
                if connectionState != .live {
                    connectionState = .live
                    reconnectDelay = config.initialReconnectDelaySeconds
                }
                handle(message)
            } catch {
                guard !Task.isCancelled else { return }
                await scheduleReconnect()
                return
            }
        }
    }

    /// Re-measure the offset periodically: a device that slept, changed time
    /// zone, or picked up a new network is exactly where a stale offset hurts.
    private func syncLoop(on task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            await sendSyncRequest(on: task)
            let interval = UInt64(config.syncIntervalSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: interval)
        }
    }

    private func sendSyncRequest(on task: URLSessionWebSocketTask) async {
        let sentAt = now()
        let payload = "{\"type\":\"sync\",\"clientSentAt\":\(sentAt.timeIntervalSince1970)}"
        do {
            try await task.send(.string(payload))
        } catch {
            // The receive loop owns reconnection; a failed send just means
            // this measurement is lost.
        }
    }

    private func scheduleReconnect() async {
        let delay = reconnectDelay
        connectionState = .offline(retryingInSeconds: delay)
        socket?.cancel(with: .abnormalClosure, reason: nil)
        socket = nil
        syncTask?.cancel()
        syncTask = nil

        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        guard !Task.isCancelled else { return }
        reconnectDelay = min(delay * 2, config.maxReconnectDelaySeconds)
        connect()
    }

    // MARK: - Messages

    private struct Envelope: Decodable {
        let type: String
        let trackId: UUID?
        let startedAt: Double?
        let durationSeconds: Double?
        let serverTime: Double?
        let listeners: Int?
        let clientSentAt: Double?
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .string(let text): data = text.data(using: .utf8)
        case .data(let raw): data = raw
        @unknown default: data = nil
        }
        guard let data, let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return }

        switch envelope.type {
        case "sync":
            applySync(envelope)
        case "nowPlaying":
            applyNowPlaying(envelope)
        default:
            break
        }
    }

    private func applySync(_ envelope: Envelope) {
        guard let serverTime = envelope.serverTime, let clientSentAt = envelope.clientSentAt else { return }
        let sample = StationClock.Sample(
            stationTime: Date(timeIntervalSince1970: serverTime),
            sentAt: Date(timeIntervalSince1970: clientSentAt),
            receivedAt: now()
        )
        guard clock.ingest(sample) else { return }
        // The offset moved, so every start time we're holding now maps to a
        // different instant on this device — re-render.
        onScheduleChange?()
    }

    private func applyNowPlaying(_ envelope: Envelope) {
        guard
            let trackID = envelope.trackId,
            let startedAt = envelope.startedAt,
            let duration = envelope.durationSeconds
        else { return }

        if let listeners = envelope.listeners { liveListenerCount = listeners }

        let slot = ScheduleSlot(
            trackID: trackID,
            startedAt: Date(timeIntervalSince1970: startedAt),
            durationSeconds: duration
        )
        // Servers re-announce the current track on reconnect; don't record
        // that as a second play or the complement rules see phantom rotation.
        guard slot != current else { return }
        current = slot

        if let track = knownTracks[trackID] {
            recentPlays.append(.init(trackID: trackID, artistID: track.artistID, playedAt: slot.startedAt))
            if recentPlays.count > Self.maxHistory {
                recentPlays.removeFirst(recentPlays.count - Self.maxHistory)
            }
        }
        onScheduleChange?()
    }
}
