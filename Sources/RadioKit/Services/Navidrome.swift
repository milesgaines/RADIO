import Foundation
import CryptoKit

/// Client for a self-hosted Navidrome server (https://www.navidrome.org) via
/// its Subsonic-compatible REST API. This is the production-shaped player
/// backend: point RADIO+ at a Navidrome instance holding the opt-in catalog
/// and the station streams real audio with real artwork.
///
/// Auth follows the Subsonic token scheme: per-request random salt `s` and
/// token `t = md5(password + s)` — the password itself never goes on the wire.
public struct NavidromeConfig: Codable, Equatable, Sendable {
    public var baseURL: URL
    public var username: String
    public var password: String

    public init(baseURL: URL, username: String, password: String) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
    }

    /// UserDefaults keys shared with the app's Settings screen (@AppStorage).
    /// Demo-grade storage — move the password to the Keychain before shipping.
    public enum StorageKey {
        public static let baseURL = "navidrome.baseURL"
        public static let username = "navidrome.username"
        public static let password = "navidrome.password"
    }

    /// Build a config from UserDefaults; nil when not (fully) configured.
    public static func fromDefaults(_ defaults: UserDefaults = .standard) -> NavidromeConfig? {
        guard
            let raw = defaults.string(forKey: StorageKey.baseURL),
            let url = URL(string: raw), !raw.isEmpty,
            let user = defaults.string(forKey: StorageKey.username), !user.isEmpty,
            let pass = defaults.string(forKey: StorageKey.password), !pass.isEmpty
        else { return nil }
        return NavidromeConfig(baseURL: url, username: user, password: pass)
    }
}

public enum NavidromeError: Error, LocalizedError {
    case badResponse
    case serverError(String)

    public var errorDescription: String? {
        switch self {
        case .badResponse: return "Unexpected response from the Navidrome server."
        case .serverError(let message): return message
        }
    }
}

public struct NavidromeClient: Sendable {
    public let config: NavidromeConfig
    private let session: URLSession
    private let clientName = "radioplus"
    private let apiVersion = "1.16.1"

    public init(config: NavidromeConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    // MARK: - Requests

    private func authItems() -> [URLQueryItem] {
        let salt = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        let token = Insecure.MD5
            .hash(data: Data((config.password + salt).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return [
            URLQueryItem(name: "u", value: config.username),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: String(salt)),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "c", value: clientName),
            URLQueryItem(name: "f", value: "json"),
        ]
    }

    private func endpoint(_ path: String, _ extra: [URLQueryItem] = []) -> URL {
        var components = URLComponents(
            url: config.baseURL.appendingPathComponent("rest/\(path)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = authItems() + extra
        return components.url!
    }

    // MARK: - API

    /// Verify the server is reachable and credentials are valid.
    public func ping() async throws {
        let (data, _) = try await session.data(from: endpoint("ping"))
        let envelope = try JSONDecoder().decode(Envelope<EmptyBody>.self, from: data)
        guard envelope.subsonicResponse.status == "ok" else {
            throw NavidromeError.serverError(envelope.subsonicResponse.error?.message ?? "Login failed.")
        }
    }

    /// Pull a randomized slice of the library and map it into `Track`s ready
    /// for the rotation engine — stream + artwork URLs included.
    public func fetchCatalog(size: Int = 200) async throws -> [Track] {
        let url = endpoint("getRandomSongs", [URLQueryItem(name: "size", value: String(size))])
        let (data, _) = try await session.data(from: url)
        let envelope = try JSONDecoder().decode(Envelope<RandomSongsBody>.self, from: data)
        guard envelope.subsonicResponse.status == "ok" else {
            throw NavidromeError.serverError(envelope.subsonicResponse.error?.message ?? "Failed to load songs.")
        }
        let songs = envelope.subsonicResponse.randomSongs?.song ?? []
        return songs.map { song in
            Track(
                id: UUID.stable(from: "navidrome.song.\(song.id)"),
                title: song.title,
                artistID: UUID.stable(from: "navidrome.artist.\(song.artistId ?? song.artist ?? "unknown")"),
                artistName: song.artist ?? "Unknown Artist",
                albumTitle: song.album,
                durationSeconds: Double(song.duration ?? 0),
                assetURL: streamURL(id: song.id),
                artworkURL: song.coverArt.map { coverArtURL(id: $0) },
                // Your self-hosted library: you control the rights that go in.
                interactiveLicenseGranted: true
            )
        }
    }

    public func streamURL(id: String) -> URL {
        endpoint("stream", [URLQueryItem(name: "id", value: id)])
    }

    public func coverArtURL(id: String, size: Int = 600) -> URL {
        endpoint("getCoverArt", [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "size", value: String(size)),
        ])
    }

    // MARK: - Wire format

    private struct Envelope<Body: Decodable>: Decodable {
        let subsonicResponse: SubsonicResponse<Body>
        enum CodingKeys: String, CodingKey { case subsonicResponse = "subsonic-response" }
    }

    private struct SubsonicResponse<Body: Decodable>: Decodable {
        let status: String
        let error: SubsonicError?
        let randomSongs: RandomSongs?

        private enum CodingKeys: String, CodingKey { case status, error, randomSongs }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try container.decode(String.self, forKey: .status)
            error = try container.decodeIfPresent(SubsonicError.self, forKey: .error)
            randomSongs = try container.decodeIfPresent(RandomSongs.self, forKey: .randomSongs)
        }
    }

    private struct EmptyBody: Decodable {}
    private struct RandomSongsBody: Decodable {}

    private struct SubsonicError: Decodable {
        let code: Int
        let message: String
    }

    private struct RandomSongs: Decodable {
        let song: [Song]?
    }

    private struct Song: Decodable {
        let id: String
        let title: String
        let artist: String?
        let artistId: String?
        let album: String?
        let duration: Int?
        let coverArt: String?
    }
}

extension UUID {
    /// Deterministic UUID derived from a string — lets external string IDs
    /// (Subsonic song/artist ids) map stably into our UUID-keyed models.
    public static func stable(from string: String) -> UUID {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        let bytes = Array(digest)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
