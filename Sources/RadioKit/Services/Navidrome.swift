import Foundation
import CryptoKit

/// Client for a self-hosted Navidrome server (https://www.navidrome.org) via
/// its Subsonic-compatible REST API. This is the production-shaped player
/// backend: point RADIO+ at a Navidrome instance holding the opt-in catalog
/// and the station streams real audio with real artwork.
///
/// Auth follows the Subsonic token scheme: per-request random salt `s` and
/// token `t = md5(password + s)` — the password itself never goes on the wire.
/// Deliberately not `Codable`: nothing should be able to serialise this struct
/// wholesale, because that would put the password back into plain storage.
public struct NavidromeConfig: Equatable, Sendable {
    public var baseURL: URL
    public var username: String
    public var password: String

    public init(baseURL: URL, username: String, password: String) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
    }

    /// UserDefaults keys shared with the app's Settings screen (@AppStorage).
    /// The password is *not* one of them — it lives in the keychain under
    /// `SecretKey.password`.
    public enum StorageKey {
        public static let baseURL = "navidrome.baseURL"
        public static let username = "navidrome.username"
        /// Where builds up to 0.1.0 kept the password in plain text. Read only
        /// by `migrateLegacyPassword`, which moves it into the keychain.
        public static let legacyPassword = "navidrome.password"
    }

    /// Keychain account names (`kSecAttrAccount`) for our secrets.
    public enum SecretKey {
        public static let password = "navidrome.password"
    }

    /// Build a config from the stored server details plus the keychain-held
    /// password; nil when not (fully) configured.
    public static func fromDefaults(
        _ defaults: UserDefaults = .standard,
        secrets: any SecretStore = KeychainSecretStore.shared
    ) -> NavidromeConfig? {
        guard
            let raw = defaults.string(forKey: StorageKey.baseURL), !raw.isEmpty,
            let url = URL(string: raw),
            let user = defaults.string(forKey: StorageKey.username), !user.isEmpty,
            let pass = secrets.secret(forKey: SecretKey.password), !pass.isEmpty
        else { return nil }
        return NavidromeConfig(baseURL: url, username: user, password: pass)
    }

    /// Persist the password to the keychain. The server URL and username are
    /// ordinary preferences and are written by the Settings screen's
    /// `@AppStorage` bindings.
    public func savePassword(to secrets: any SecretStore = KeychainSecretStore.shared) throws {
        try secrets.setSecret(password, forKey: SecretKey.password)
    }

    /// Forget the stored password, leaving the server URL and username alone.
    public static func forgetPassword(
        _ secrets: any SecretStore = KeychainSecretStore.shared
    ) throws {
        try secrets.removeSecret(forKey: SecretKey.password)
    }

    /// Move a password written by an earlier build out of `UserDefaults` and
    /// into the keychain, then delete the plain-text copy. Safe to call on
    /// every launch; a no-op once there's nothing left in plain text.
    ///
    /// - Returns: `true` when a legacy password was moved into the keychain.
    @discardableResult
    public static func migrateLegacyPassword(
        _ defaults: UserDefaults = .standard,
        secrets: any SecretStore = KeychainSecretStore.shared
    ) -> Bool {
        guard
            let legacy = defaults.string(forKey: StorageKey.legacyPassword),
            !legacy.isEmpty
        else { return false }

        if let existing = secrets.secret(forKey: SecretKey.password), !existing.isEmpty {
            // The keychain is already authoritative — drop the stale copy
            // rather than letting it overwrite a newer password.
            defaults.removeObject(forKey: StorageKey.legacyPassword)
            return false
        }

        // Only clear the plain-text copy once the keychain actually has it, so
        // a failed write can't lock a listener out of their own server.
        do {
            try secrets.setSecret(legacy, forKey: SecretKey.password)
        } catch {
            return false
        }
        defaults.removeObject(forKey: StorageKey.legacyPassword)
        return true
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
