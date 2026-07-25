import XCTest
@testable import RadioKit

/// Covers the OneSync backend client: that the real `radio_now_playing` /
/// `radio_tracks` / `radio_votes` shapes decode, that the `Date` response
/// header becomes a clock sample, that a vote POSTs the right body, and that
/// `LiveStreamService` forwards votes to a server-backed source.
final class SupabaseRadioTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    private func stubbedClient(
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> SupabaseRadioClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        return SupabaseRadioClient(
            config: .init(restURL: URL(string: "https://example.supabase.co/rest/v1")!, apiKey: "anon-key"),
            session: session,
            now: now
        )
    }

    /// Serves a fixed sequence of dates from a `@Sendable` closure — a
    /// captured `var` can't be mutated there, so the state lives in a box.
    private final class DateSequence: @unchecked Sendable {
        private var remaining: [Date]
        private let fallback: Date
        init(_ dates: [Date]) {
            self.remaining = dates
            self.fallback = dates.last ?? Date()
        }
        func next() -> Date {
            remaining.isEmpty ? fallback : remaining.removeFirst()
        }
    }

    // MARK: - Timestamp parsing

    func testPostgresTimestampVariants() {
        // The same second, in every rendering PostgREST/Postgres might emit:
        // T or space separator; 6-digit, trimmed, or no fraction; Z, +00, or
        // +00:00 offset; and a naive timestamp (treated as UTC).
        let whole = 1_785_003_357.0 // 2026-07-25T18:15:57Z
        let cases = [
            "2026-07-25T18:15:57.000001+00:00",
            "2026-07-25 18:15:57.000001+00",
            "2026-07-25T18:15:57+00:00",
            "2026-07-25T18:15:57Z",
            "2026-07-25 18:15:57",
            "2026-07-25T18:15:57.5Z", // Postgres trims trailing zeros: `.5` is legal
        ]
        for raw in cases {
            let parsed = SupabaseRadioClient.parsePostgresTimestamp(raw)
            XCTAssertNotNil(parsed, "failed to parse \(raw)")
            if let parsed {
                XCTAssertEqual(parsed.timeIntervalSince1970, whole, accuracy: 0.6,
                               "wrong instant for \(raw)")
            }
        }
    }

    func testGarbageTimestampIsRejected() {
        XCTAssertNil(SupabaseRadioClient.parsePostgresTimestamp("not a date"))
        XCTAssertNil(SupabaseRadioClient.parsePostgresTimestamp(""))
    }

    // MARK: - Stable artist id

    func testStableArtistIDIsDeterministicAndNameSensitive() {
        let a1 = SupabaseRadioClient.stableArtistID(forName: "Miles Gaines")
        let a2 = SupabaseRadioClient.stableArtistID(forName: "miles gaines")
        let b = SupabaseRadioClient.stableArtistID(forName: "Blacc'Khuzzy")
        XCTAssertEqual(a1, a2, "Same name (case-insensitive) → same id")
        XCTAssertNotEqual(a1, b, "Different artists → different ids")
    }

    // MARK: - Realtime URL

    func testRealtimeURLDerivation() {
        let url = SupabaseRealtime.realtimeURL(
            fromREST: URL(string: "https://tgkgdquivdoquxamtgcr.supabase.co/rest/v1")!,
            apiKey: "the-key"
        )
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.host, "tgkgdquivdoquxamtgcr.supabase.co")
        XCTAssertEqual(url.path, "/realtime/v1/websocket")
        let query = url.query ?? ""
        XCTAssertTrue(query.contains("apikey=the-key"))
        XCTAssertTrue(query.contains("vsn=1.0.0"))
    }

    // MARK: - Now playing → slot + clock sample

    func testFetchNowPlayingDecodesSlotAndClockSample() async throws {
        let stationID = UUID()
        let trackID = UUID()
        let serverDate = "Sat, 25 Jul 2026 18:26:40 GMT" // = 1_785_004_000
        let sentAt = Date(timeIntervalSince1970: 1_785_003_999.8)
        let receivedAt = Date(timeIntervalSince1970: 1_785_004_000.2)
        let times = DateSequence([sentAt, receivedAt])

        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "anon-key")
            let body = """
            [{"station_id":"\(stationID.uuidString.lowercased())","track_id":"\(trackID.uuidString.lowercased())","title":"Ride My Wave","artist":"Miles Gaines","started_at":"2026-07-25T18:25:57.254768+00:00","duration_seconds":234.95}]
            """
            return (200, ["Date": serverDate], Data(body.utf8))
        }

        let client = stubbedClient(now: { times.next() })
        let result = try await client.fetchNowPlaying(stationID: stationID)
        let unwrapped = try XCTUnwrap(result)

        XCTAssertEqual(unwrapped.slot.trackID, trackID)
        XCTAssertEqual(unwrapped.slot.durationSeconds, 234.95, accuracy: 0.01)
        XCTAssertEqual(unwrapped.track.title, "Ride My Wave")
        XCTAssertEqual(unwrapped.track.artistName, "Miles Gaines")

        // The Date header (18:26:40Z) became a clock sample. Offset ≈
        // serverTime - receivedAt + roundTrip/2 = 0 - 0.2 + 0.2 = 0.
        let sample = try XCTUnwrap(unwrapped.clockSample)
        XCTAssertEqual(sample.offset, 0, accuracy: 0.6) // ±0.5s Date-header resolution
    }

    func testEmptyNowPlayingReturnsNil() async throws {
        StubURLProtocol.handler = { _ in (200, ["Date": "Sat, 25 Jul 2026 18:26:40 GMT"], Data("[]".utf8)) }
        let client = stubbedClient()
        let result = try await client.fetchNowPlaying(stationID: UUID())
        XCTAssertNil(result)
    }

    // MARK: - Catalog

    func testFetchCatalogJoinsMembershipThenTracks() async throws {
        let stationID = UUID()
        let t1 = UUID(), t2 = UUID()
        let artistID = UUID()

        StubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("radio_station_tracks") {
                let body = "[{\"track_id\":\"\(t1.uuidString.lowercased())\"},{\"track_id\":\"\(t2.uuidString.lowercased())\"}]"
                return (200, [:], Data(body.utf8))
            }
            // radio_tracks
            let body = """
            [{"track_id":"\(t1.uuidString.lowercased())","title":"Dancin","artist":"Miles Gaines","artist_id":"\(artistID.uuidString.lowercased())","duration_seconds":222.2,"audio_url":null},
             {"track_id":"\(t2.uuidString.lowercased())","title":"Westside","artist":"Miles Gaines","artist_id":"\(artistID.uuidString.lowercased())","duration_seconds":149.6,"audio_url":"https://cdn.example.com/westside.mp3"}]
            """
            return (200, [:], Data(body.utf8))
        }

        let client = stubbedClient()
        let tracks = try await client.fetchCatalog(stationID: stationID)
        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(tracks.map(\.title).sorted(), ["Dancin", "Westside"])
        XCTAssertNil(tracks.first(where: { $0.title == "Dancin" })?.assetURL, "null audio_url → nil assetURL")
        XCTAssertEqual(tracks.first(where: { $0.title == "Westside" })?.assetURL?.absoluteString,
                       "https://cdn.example.com/westside.mp3")
        XCTAssertTrue(tracks.allSatisfy(\.interactiveLicenseGranted), "server-curated tracks are licensed")
    }

    // MARK: - Voting

    func testCastVotePostsTextStationIdAndDirection() async throws {
        let stationID = UUID()
        let trackID = UUID()
        var captured: (method: String?, body: Data?)?

        StubURLProtocol.handler = { request in
            captured = (request.httpMethod, request.httpBodyData)
            return (201, [:], Data())
        }

        let client = stubbedClient()
        try await client.castVote(stationID: stationID, trackID: trackID,
                                  listenerKey: "listener-abcdef", direction: .bury)

        XCTAssertEqual(captured?.method, "POST")
        let json = try JSONSerialization.jsonObject(with: try XCTUnwrap(captured?.body)) as? [String: Any]
        XCTAssertEqual(json?["station_id"] as? String, stationID.uuidString.lowercased(),
                       "station_id is a text column — send the UUID string")
        XCTAssertEqual(json?["track_id"] as? String, trackID.uuidString.lowercased())
        XCTAssertEqual(json?["listener_key"] as? String, "listener-abcdef")
        XCTAssertEqual(json?["direction"] as? Int, -1, "bury encodes as -1")
    }

    func testBadStatusThrows() async {
        StubURLProtocol.handler = { _ in (500, [:], Data("boom".utf8)) }
        let client = stubbedClient()
        do {
            _ = try await client.fetchCatalog(stationID: UUID())
            XCTFail("expected a thrown error on HTTP 500")
        } catch {
            // expected
        }
    }

    // MARK: - Vote forwarding through LiveStreamService

    @MainActor
    func testLiveStreamForwardsVotesToServerBackedSource() {
        let song = Track(title: "on air", artistID: UUID(), artistName: "A", durationSeconds: 200)
        let spy = VoteSpySource(track: song)
        let service = LiveStreamService(catalog: [song], scheduleSource: spy, now: { Date(timeIntervalSince1970: 1_785_004_000) })
        service.start()
        defer { service.stop() }

        service.vote(.boost, on: song.id)
        XCTAssertEqual(spy.votes.count, 1)
        XCTAssertEqual(spy.votes.first?.direction, .boost)
        XCTAssertEqual(spy.votes.first?.trackID, song.id)
    }
}

// MARK: - Test doubles

/// A schedule source that records forwarded votes and serves one fixed slot.
@MainActor
private final class VoteSpySource: StationScheduleSource {
    var onScheduleChange: (@MainActor () -> Void)?
    var netVoteWeight: (@MainActor (UUID) -> Double)?
    var clock = StationClock()
    var liveListenerCount: Int?
    var recentPlays: [WeightedRotationEngine.PlayRecord] = []

    private let fixed: ScheduleSlot
    private let track: Track
    private(set) var votes: [(direction: VoteDirection, trackID: UUID)] = []

    init(track: Track) {
        self.track = track
        self.fixed = ScheduleSlot(trackID: track.id, startedAt: Date(timeIntervalSince1970: 1_785_004_000), durationSeconds: track.durationSeconds)
    }

    func slot(at stationNow: Date) -> ScheduleSlot? { fixed }
    func track(withID id: UUID) -> Track? { id == track.id ? track : nil }
    func updateCatalog(_ tracks: [Track]) {}
    func castVote(_ direction: VoteDirection, on trackID: UUID) {
        votes.append((direction, trackID))
    }
    func start() {}
    func stop() {}
}

/// Minimal `URLProtocol` stub: answers every request from a per-test handler,
/// so the client's parsing and headers are tested with no network.
final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (status: Int, headers: [String: String], body: Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = StubURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, headers, body) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// `URLProtocol` doesn't expose a POST body when it's set as a stream, so grab
/// the raw `httpBody` (URLSession converts small bodies to a stream otherwise).
private extension URLRequest {
    var httpBodyData: Data? {
        if let body = httpBody { return body }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
