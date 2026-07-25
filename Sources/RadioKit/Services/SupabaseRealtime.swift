import Foundation

/// A deliberately tiny Supabase Realtime client: it subscribes to changes on a
/// table and calls `onChange` when any arrive. It carries **no state** — it
/// never parses a row, never decides what plays. That's the whole point: the
/// poll loop in `SupabaseScheduleSource` is the source of truth, and this is
/// only an accelerant that says "re-read now". If Supabase changes its Phoenix
/// payload shape, the worst case is this stays quiet and polling still catches
/// every change within a song.
///
/// Speaks the Phoenix channels protocol (`vsn=1.0.0`) Supabase Realtime uses:
/// join a topic with a `postgres_changes` config, heartbeat to stay alive, and
/// treat any inbound `postgres_changes` frame as the signal. Reads on the
/// target tables are public under RLS, so the anon key in the URL is the only
/// credential needed.
///
/// Main-actor isolated: every operation is `await`-based I/O that yields, so
/// there's no benefit to another thread and a lot of concurrency reasoning
/// saved — no locks, no shared-mutable-state races.
@MainActor
final class SupabaseRealtime {

    /// Called on the main actor whenever the subscribed table changes.
    var onChange: (() -> Void)?

    private let socketURL: URL
    private let table: String
    private let stationID: UUID
    private let session: URLSession

    private let heartbeatInterval: TimeInterval = 25
    private let reconnectDelay: TimeInterval = 3

    private var socket: URLSessionWebSocketTask?
    private var pumpTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var refCounter = 0
    private var stopped = false

    init(
        config: SupabaseRadioClient.Config,
        table: String,
        stationID: UUID,
        session: URLSession = .shared
    ) {
        self.table = table
        self.stationID = stationID
        self.session = session
        self.socketURL = Self.realtimeURL(fromREST: config.restURL, apiKey: config.apiKey)
    }

    func connect() {
        stopped = false
        openSocket()
    }

    func disconnect() {
        stopped = true
        heartbeatTask?.cancel(); heartbeatTask = nil
        pumpTask?.cancel(); pumpTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    // MARK: - Socket

    private func openSocket() {
        guard !stopped else { return }
        let task = session.webSocketTask(with: socketURL)
        socket = task
        task.resume()
        sendJoin()
        startHeartbeat()

        pumpTask = Task { [weak self] in
            await self?.receiveLoop(on: task)
        }
    }

    private func receiveLoop(on task: URLSessionWebSocketTask) async {
        while !stopped && !Task.isCancelled {
            do {
                let message = try await task.receive()
                handle(message)
            } catch {
                await reconnect()
                return
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let text: String?
        switch message {
        case .string(let s): text = s
        case .data(let d): text = String(data: d, encoding: .utf8)
        @unknown default: text = nil
        }
        guard let text, let data = text.data(using: .utf8) else { return }
        // Only the event name matters — this is a signal, not a data feed.
        if let frame = try? JSONDecoder().decode(EventFrame.self, from: data),
           frame.event == "postgres_changes" {
            onChange?()
        }
    }

    private func reconnect() async {
        guard !stopped else { return }
        heartbeatTask?.cancel(); heartbeatTask = nil
        socket?.cancel(with: .abnormalClosure, reason: nil)
        socket = nil
        try? await Task.sleep(nanoseconds: UInt64(reconnectDelay * 1_000_000_000))
        guard !stopped, !Task.isCancelled else { return }
        openSocket()
    }

    // MARK: - Phoenix messages

    private func nextRef() -> String {
        refCounter += 1
        return String(refCounter)
    }

    private func sendJoin() {
        let ref = nextRef()
        let filter = "station_id=eq.\(stationID.uuidString.lowercased())"
        let join = """
        {"topic":"realtime:\(table)","event":"phx_join","payload":{"config":{"postgres_changes":[{"event":"*","schema":"public","table":"\(table)","filter":"\(filter)"}]}},"ref":"\(ref)","join_ref":"\(ref)"}
        """
        socket?.send(.string(join)) { _ in }
    }

    private func startHeartbeat() {
        let intervalNanos = UInt64(heartbeatInterval * 1_000_000_000)
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNanos)
                guard let self, !self.stopped, !Task.isCancelled else { return }
                self.sendHeartbeat()
            }
        }
    }

    private func sendHeartbeat() {
        let ref = nextRef()
        let beat = "{\"topic\":\"phoenix\",\"event\":\"heartbeat\",\"payload\":{},\"ref\":\"\(ref)\"}"
        socket?.send(.string(beat)) { _ in }
    }

    private struct EventFrame: Decodable { let event: String }

    // MARK: - URL

    /// `https://<ref>.supabase.co/rest/v1` → `wss://<ref>.supabase.co/realtime/v1/websocket?apikey=…&vsn=1.0.0`
    nonisolated static func realtimeURL(fromREST rest: URL, apiKey: String) -> URL {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = rest.host
        components.path = "/realtime/v1/websocket"
        components.queryItems = [
            URLQueryItem(name: "apikey", value: apiKey),
            URLQueryItem(name: "vsn", value: "1.0.0"),
        ]
        return components.url!
    }
}
