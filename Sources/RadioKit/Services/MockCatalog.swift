import Foundation

/// Stand-in for the OneSync opt-in catalog. In production this is replaced by
/// a service that returns only masters whose rights holders granted an
/// interactive direct license. Everything downstream — engine, UI, CarPlay —
/// is written against these models, so swapping the source changes nothing else.
public enum MockCatalog {

    public static let artists: [(id: UUID, name: String)] = [
        (UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!, "Neon Tide"),
        (UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!, "The Local Static"),
        (UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!, "Marigold Avenue"),
        (UUID(uuidString: "00000000-0000-0000-0000-0000000000A4")!, "Cassette Sun"),
        (UUID(uuidString: "00000000-0000-0000-0000-0000000000A5")!, "Ivy & Oaks"),
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
        ]
    }()

    public static let flagshipStation = Station(
        name: "Swell",
        tagline: "One station. Everyone hears the same second. You program it.",
        catalogArtistIDs: Set(artists.map(\.id))
    )
}
