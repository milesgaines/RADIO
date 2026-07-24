import Foundation

/// A single audio recording available to the station.
///
/// In production a `Track` maps to one master recording that an artist has
/// **opted in** to via OneSync's direct-license flow. Because the license is
/// direct (not the DMCA §§112/114 statutory webcasting license), the station
/// is free to be as interactive as it likes — fans may vote, boost and replay
/// without tripping the "interactive service" line drawn in
/// *Arista Records v. Launch Media*, 578 F.3d 148 (2d Cir. 2009).
public struct Track: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let title: String
    public let artistID: UUID
    public let artistName: String
    public let albumTitle: String?
    public let durationSeconds: Double
    /// URL of the streamable asset. `nil` in mock/preview data.
    public let assetURL: URL?
    public let artworkURL: URL?
    /// Confirms the rights holder opted this master in for interactive use.
    /// The rotation engine refuses to schedule a track without it.
    public let interactiveLicenseGranted: Bool

    public init(
        id: UUID = UUID(),
        title: String,
        artistID: UUID,
        artistName: String,
        albumTitle: String? = nil,
        durationSeconds: Double,
        assetURL: URL? = nil,
        artworkURL: URL? = nil,
        interactiveLicenseGranted: Bool = true
    ) {
        self.id = id
        self.title = title
        self.artistID = artistID
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.durationSeconds = durationSeconds
        self.assetURL = assetURL
        self.artworkURL = artworkURL
        self.interactiveLicenseGranted = interactiveLicenseGranted
    }
}
