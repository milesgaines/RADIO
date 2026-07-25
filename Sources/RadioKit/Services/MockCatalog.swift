import Foundation

/// Stand-in for the OneSync opt-in catalog. In production this is replaced by
/// a service that returns only masters whose rights holders granted an
/// interactive direct license. Everything downstream — engine, UI, CarPlay —
/// is written against these models, so swapping the source changes nothing else.
///
/// IDs are fixed (not random per launch) so station identity is stable across
/// launches — a persisted "last tuned station" keeps meaning something.
public enum MockCatalog {

    public static let artists: [(id: UUID, name: String)] = [
        (UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!, "Neon Tide"),
        (UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!, "The Local Static"),
        (UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!, "Marigold Avenue"),
        (UUID(uuidString: "00000000-0000-0000-0000-0000000000A4")!, "Cassette Sun"),
        (UUID(uuidString: "00000000-0000-0000-0000-0000000000A5")!, "Ivy & Oaks"),
        (UUID(uuidString: "00000000-0000-0000-0000-0000000000A6")!, "Velvet Meridian"),
        (UUID(uuidString: "00000000-0000-0000-0000-0000000000A7")!, "Static Bloom"),
        (UUID(uuidString: "00000000-0000-0000-0000-0000000000A8")!, "June Motel"),
    ]

    public static let tracks: [Track] = {
        let a = artists
        func t(_ title: String, _ i: Int, _ album: String, _ dur: Double) -> Track {
            Track(
                title: title,
                artistID: a[i].id,
                artistName: a[i].name,
                albumTitle: album,
                durationSeconds: dur,
                interactiveLicenseGranted: true
            )
        }
        return [
            t("Coastline Signals", 0, "Undertow", 214),
            t("Slow Motion Ghost", 0, "Undertow", 198),
            t("Parking Lot Kings", 1, "Basement Tapes", 176),
            t("Everyone's Asleep", 1, "Basement Tapes", 233),
            t("Golden Hour Traffic", 2, "Southbound", 251),
            t("Paper Streetlights", 2, "Southbound", 187),
            t("Analog Heart", 3, "Warm Static", 205),
            t("Fade In Slow", 3, "Warm Static", 221),
            t("Backroad Cathedral", 4, "Foxglove", 244),
            t("Porchlight", 4, "Foxglove", 168),
            t("Half-Remembered Summer", 5, "Meridian", 236),
            t("Blue Hour Balcony", 5, "Meridian", 209),
            t("Feedback Choir", 6, "Bloom", 192),
            t("Static Bouquet", 6, "Bloom", 227),
            t("Vacancy Light", 7, "Off-Season", 183),
            t("Two-Lane Lullaby", 7, "Off-Season", 248),
        ]
    }()

    // MARK: - Stations

    /// Everyone's first stop: the whole opt-in catalog.
    public static let flagshipStation = Station(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!,
        name: "Swell",
        tagline: "One station. Everyone hears the same second. You program it.",
        catalogArtistIDs: Set(artists.map(\.id))
    )

    /// Louder, later: garage rock, shoegaze, synth energy.
    public static let nightStatic = Station(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!,
        name: "Night Static",
        tagline: "Loud enough for the last hour of the drive.",
        catalogArtistIDs: Set([artists[0].id, artists[1].id, artists[3].id, artists[6].id])
    )

    /// Mellow end of the catalog: folk, dream pop, slow indie.
    public static let goldenHour = Station(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B3")!,
        name: "Golden Hour",
        tagline: "Windows down, sun low, nobody's in a hurry.",
        catalogArtistIDs: Set([artists[2].id, artists[4].id, artists[5].id, artists[7].id])
    )

    public static let stations: [Station] = [flagshipStation, nightStatic, goldenHour]

    /// The subset of the catalog a station may draw from — only artists who
    /// opted in to that station's programming.
    public static func tracks(for station: Station) -> [Track] {
        tracks.filter { station.catalogArtistIDs.contains($0.artistID) }
    }
}
