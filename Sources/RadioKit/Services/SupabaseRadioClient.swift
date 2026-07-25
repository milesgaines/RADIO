import Foundation

/// The OneSync radio backend, reached over its Supabase REST API.
///
/// The station already runs server-side: `radio_advance_stations()` rotates
/// each station and writes the current track to `radio_now_playing`, listeners
/// read it, and votes land in `radio_votes`. This is the thin client for that
/// contract — no rotation logic here, only reads of what the server decided
/// and writes of this listener's votes.
///
/// Everything the app touches is behind row-level security that allows public
/// reads and an anonymous vote insert, so the publishable ("anon") key is the
/// only credential and it's safe to ship in the client — exactly as it ships
/// in every Supabase web app. There is no password and nothing to keep in the
/// keychain here; that machinery stays with Navidrome.
public struct SupabaseRadioClient: Sendable {

    public struct Config: Sendable {
        public var restURL: URL
        public var apiKey: String

        public init(restURL: URL, apiKey: String) {
            self.restURL = restURL
            self.apiKey = apiKey
        }

        /// The live OneSync station. The URL and anon key are public by
        /// design — reads and vote inserts are all RLS allows — so they're
        /// the shipped defaults, overridable for a self-hosted mirror.
        public static let oneSync = Config(
            restURL: URL(string: "https://tgkgdquivdoquxamtgcr.supabase.co/rest/v1")!,
            apiKey: "sb_publishable_JYYXKdhcGnEP5curdG_pLg_XVcy9-ii"
        )
    }

    /// One read of the current track, paired with the server's clock at the
    /// moment it answered — the raw material for both a `ScheduleSlot` and a
    /// `StationClock.Sample`.
    public struct NowPlayingResult: Sendable {
        public let slot: ScheduleSlot
        public let track: Track
        /// Round-trip clock sample built from the response's `Date` header.
        public let clockSample: StationClock.Sample?
    }

    public enum ClientError: Error, Sendable {
        case badResponse(status: Int)
        case emptyStation
        case malformed
    }

    public let config: Config
    private let session: URLSession
    private let now: @Sendable () -> Date

    public init(
        config: Config = .oneSync,
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.session = session
        self.now = now
    }

    // MARK: - Reads

    /// The station to tune to when none is configured: whichever one the
    /// server advanced most recently, so a fresh install lands on something
    /// that's actually live.
    public func resolveLiveStation() async throws -> UUID {
        let url = endpoint(
            "radio_now_playing",
            query: [
                ("select", "station_id"),
                ("order", "updated_at.desc"),
                ("limit", "1"),
            ]
        )
        let (data, _, _) = try await get(url)
        let rows = try decode([StationIDRow].self, from: data)
        guard let id = rows.first?.station_id else { throw ClientError.emptyStation }
        return id
    }

    /// The track on air for a station, or `nil` if the server has never
    /// announced one. The paired clock sample lets the caller keep its
    /// `StationClock` disciplined off the same round trip.
    public func fetchNowPlaying(stationID: UUID) async throws -> NowPlayingResult? {
        let url = endpoint(
            "radio_now_playing",
            query: [
                ("station_id", "eq.\(stationID.uuidString.lowercased())"),
                ("select", "station_id,track_id,title,artist,started_at,duration_seconds"),
                ("limit", "1"),
            ]
        )
        let sentAt = now()
        let (data, response, receivedAt) = try await get(url)
        let rows = try decode([NowPlayingRow].self, from: data)
        guard let row = rows.first, let slot = row.slot else { return nil }

        let sample = clockSample(from: response, sentAt: sentAt, receivedAt: receivedAt)
        return NowPlayingResult(slot: slot, track: row.track, clockSample: sample)
    }

    /// The station's catalog. Two hops rather than a PostgREST embed, so the
    /// client makes no assumption about a foreign key being declared: the
    /// membership table gives the ids, then the tracks are fetched by id.
    public func fetchCatalog(stationID: UUID) async throws -> [Track] {
        let membershipURL = endpoint(
            "radio_station_tracks",
            query: [
                ("station_id", "eq.\(stationID.uuidString.lowercased())"),
                ("select", "track_id"),
            ]
        )
        let (memberData, _, _) = try await get(membershipURL)
        let ids = try decode([TrackIDRow].self, from: memberData).map(\.track_id)
        guard !ids.isEmpty else { return [] }

        // Chunk the `in.(…)` filter so a large station can't blow the URL length.
        var tracks: [Track] = []
        for chunk in stride(from: 0, to: ids.count, by: 100).map({ Array(ids[$0..<min($0 + 100, ids.count)]) }) {
            let list = chunk.map { $0.uuidString.lowercased() }.joined(separator: ",")
            let url = endpoint(
                "radio_tracks",
                query: [
                    ("track_id", "in.(\(list))"),
                    ("select", "track_id,title,artist,artist_id,duration_seconds,audio_url"),
                ]
            )
            let (data, _, _) = try await get(url)
            tracks.append(contentsOf: try decode([TrackRow].self, from: data).map(\.track))
        }
        return tracks
    }

    /// How many listeners are live on a station: distinct heartbeats seen in
    /// the trailing window. `since` is in **station time** — the server stamps
    /// `last_seen` with its own clock, so the cutoff must be quoted against
    /// that clock too, or a skewed device would over- or under-count.
    ///
    /// Uses a `Range: 0-0` + `Prefer: count=exact` read so the answer arrives
    /// in the `Content-Range` header (`0-0/N`) and the body stays one row no
    /// matter how big the audience gets.
    public func fetchListenerCount(stationID: UUID, since: Date) async throws -> Int {
        let url = endpoint(
            "radio_listeners",
            query: [
                ("station_id", "eq.\(stationID.uuidString.lowercased())"),
                ("last_seen", "gte.\(Self.postgresTimestamp(since))"),
                ("select", "listener_key"),
            ]
        )
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("count=exact", forHTTPHeaderField: "Prefer")
        request.setValue("0-0", forHTTPHeaderField: "Range")
        applyKey(to: &request)

        let (_, response) = try await session.data(for: request)
        let http = try check(response)
        guard
            let header = http.value(forHTTPHeaderField: "Content-Range"),
            let total = header.split(separator: "/").last,
            let count = Int(total)
        else { throw ClientError.malformed }
        return count
    }

    // MARK: - Writes

    /// Mark this listener present on a station. An upsert on the
    /// `(station_id, listener_key)` key — the first beat inserts, every later
    /// one refreshes. `last_seen` is stamped server-side by trigger, so the
    /// body carries no clock and a device with a wrong one can't fake
    /// freshness. Fire-and-forget cadence: once per poll is plenty, since the
    /// presence window is a couple of polls wide.
    public func sendHeartbeat(stationID: UUID, listenerKey: String) async throws {
        var request = URLRequest(url: endpoint("radio_listeners"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        applyKey(to: &request)
        let body = HeartbeatInsert(
            station_id: stationID.uuidString.lowercased(),
            listener_key: listenerKey
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await session.data(for: request)
        try check(response)
    }

    /// Cast a boost or bury. Fire-and-forget from the caller's view — the
    /// server re-tallies and the next `radio_now_playing` update reflects it.
    /// `listenerKey` must be 8–64 chars (the RLS insert check); a listener's
    /// UUID string satisfies it.
    public func castVote(
        stationID: UUID,
        trackID: UUID,
        listenerKey: String,
        direction: VoteDirection
    ) async throws {
        var request = URLRequest(url: endpoint("radio_votes"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        applyKey(to: &request)

        // station_id is a text column on radio_votes, so send the UUID string.
        let body = VoteInsert(
            station_id: stationID.uuidString.lowercased(),
            track_id: trackID.uuidString.lowercased(),
            listener_key: listenerKey,
            direction: Int(direction.rawValue)
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await session.data(for: request)
        try check(response)
    }

    // MARK: - HTTP

    private func endpoint(_ table: String, query: [(String, String)] = []) -> URL {
        var components = URLComponents(
            url: config.restURL.appendingPathComponent(table),
            resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        return components.url!
    }

    private func applyKey(to request: inout URLRequest) {
        request.setValue(config.apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
    }

    private func get(_ url: URL) async throws -> (Data, HTTPURLResponse, Date) {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyKey(to: &request)
        let (data, response) = try await session.data(for: request)
        let http = try check(response)
        return (data, http, now())
    }

    @discardableResult
    private func check(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw ClientError.malformed }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.badResponse(status: http.statusCode)
        }
        return http
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ClientError.malformed
        }
    }

    /// A `Date` response header is the server's clock when it answered, so
    /// every REST round trip doubles as a clock measurement. Its resolution
    /// is one second (the HTTP-date format has no fractional part), which
    /// bounds sync precision at about ±0.5s — inaudible for radio.
    private func clockSample(from response: HTTPURLResponse, sentAt: Date, receivedAt: Date) -> StationClock.Sample? {
        guard
            let header = response.value(forHTTPHeaderField: "Date"),
            let serverTime = Self.httpDateFormatter.date(from: header)
        else { return nil }
        return StationClock.Sample(stationTime: serverTime, sentAt: sentAt, receivedAt: receivedAt)
    }

    // MARK: - Row shapes

    private struct StationIDRow: Decodable { let station_id: UUID }
    private struct TrackIDRow: Decodable { let track_id: UUID }

    private struct NowPlayingRow: Decodable {
        let station_id: UUID
        let track_id: UUID
        let title: String
        let artist: String
        let started_at: String
        let duration_seconds: Double

        var slot: ScheduleSlot? {
            guard let startedAt = SupabaseRadioClient.parsePostgresTimestamp(started_at) else { return nil }
            return ScheduleSlot(trackID: track_id, startedAt: startedAt, durationSeconds: duration_seconds)
        }

        /// The now-playing row carries its own title/artist/duration, so the
        /// current track is renderable even before the catalog is fetched.
        /// artistID isn't in this row; a deterministic namespace UUID keeps
        /// the complement rules working until the catalog fills it in.
        var track: Track {
            Track(
                id: track_id,
                title: title,
                artistID: SupabaseRadioClient.stableArtistID(forName: artist),
                artistName: artist,
                durationSeconds: duration_seconds,
                interactiveLicenseGranted: true
            )
        }
    }

    private struct TrackRow: Decodable {
        let track_id: UUID
        let title: String
        let artist: String
        let artist_id: UUID
        let duration_seconds: Double
        let audio_url: String?

        var track: Track {
            Track(
                id: track_id,
                title: title,
                artistID: artist_id,
                artistName: artist,
                durationSeconds: duration_seconds,
                assetURL: audio_url.flatMap(URL.init(string:)),
                interactiveLicenseGranted: true
            )
        }
    }

    private struct VoteInsert: Encodable {
        let station_id: String
        let track_id: String
        let listener_key: String
        let direction: Int
    }

    private struct HeartbeatInsert: Encodable {
        let station_id: String
        let listener_key: String
    }

    // MARK: - Parsing helpers

    /// PostgREST can render `timestamptz` a few ways depending on version —
    /// `T` or space separator, microsecond or no fractional seconds, offset as
    /// `Z`, `+00`, or `+00:00`. Normalise to a form `ISO8601DateFormatter`
    /// accepts (millisecond fraction, colon in the offset) rather than trust a
    /// single shape.
    static func parsePostgresTimestamp(_ raw: String) -> Date? {
        var s = raw.trimmingCharacters(in: .whitespaces)

        // Space separator → 'T'.
        if !s.contains("T"), let space = s.firstIndex(of: " ") {
            s.replaceSubrange(space...space, with: "T")
        }
        guard let tIdx = s.firstIndex(of: "T") else { return nil }

        // Normalise fractional seconds to exactly three digits —
        // `ISO8601DateFormatter` wants `.SSS`, while Postgres emits up to six
        // digits *and* trims trailing zeros (so `.5` is a legal rendering).
        if let dot = s.firstIndex(of: "."), dot > tIdx {
            var end = s.index(after: dot)
            while end < s.endIndex, s[end].isNumber { end = s.index(after: end) }
            var digits = String(s[s.index(after: dot)..<end].prefix(3))
            while digits.count < 3 { digits.append("0") }
            s.replaceSubrange(dot..<end, with: "." + digits)
        }

        // Normalise the timezone in the part after 'T'.
        let afterT = s[s.index(after: tIdx)...]
        if let tzStart = afterT.firstIndex(where: { $0 == "+" || $0 == "-" }) {
            if s.distance(from: tzStart, to: s.endIndex) == 3 { s.append(":00") } // +00 → +00:00
        } else if !s.hasSuffix("Z") {
            s.append("Z") // naive timestamp → treat as UTC
        }

        for formatter in isoFormatters {
            if let date = formatter.date(from: s) { return date }
        }
        return nil
    }

    /// Render a `Date` the way PostgREST filters expect: ISO-8601 UTC. Whole
    /// seconds only — presence windows are tens of seconds wide, so
    /// sub-second precision buys nothing.
    static func postgresTimestamp(_ date: Date) -> String {
        plainISOFormatter.string(from: date)
    }

    private static let plainISOFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoFormatters: [ISO8601DateFormatter] = {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [withFraction, plainISOFormatter]
    }()

    private static let httpDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f
    }()

    /// Deterministic artist id from a name, for the stretch before a track's
    /// real `artist_id` arrives with the catalog. Same name → same id, so the
    /// per-artist complement still spots a run by one artist.
    static func stableArtistID(forName name: String) -> UUID {
        var hash: UInt64 = 1_469_598_103_934_665_603 // FNV-1a offset basis
        for byte in name.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 {
            bytes[i] = UInt8((hash >> (UInt64(i) * 8)) & 0xFF)
            bytes[i + 8] = UInt8((hash >> (UInt64(7 - i) * 8)) & 0xFF)
        }
        let u = (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                 bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])
        return UUID(uuid: u)
    }
}
