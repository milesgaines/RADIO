import UIKit
import RadioKit

/// The look of RADI0, rendered as an image — the extruded call number over the
/// room's ember glow. One renderer feeds every "away" surface: the lock-screen
/// / StandBy artwork, CarPlay's station tiles, and the car's Now Playing art.
/// Everything is drawn (no assets), so it stays crisp at any size and always
/// matches the room's accent.
enum StationArt {

    static let ink = UIColor(red: 0.039, green: 0.039, blue: 0.047, alpha: 1)
    static let bone = UIColor(red: 0.945, green: 0.925, blue: 0.878, alpha: 1)

    /// The four room colors, in dial order — kept in step with CymaticPlate.accents.
    static let accents: [UIColor] = [
        UIColor(red: 1.00, green: 0.36, blue: 0.18, alpha: 1), // ember  — PWR DAMIZZA
        UIColor(red: 0.30, green: 0.72, blue: 1.00, alpha: 1), // ice    — THE VAULT
        UIColor(red: 0.36, green: 0.92, blue: 0.53, alpha: 1), // acid   — THE UNDERGROUND
        UIColor(red: 0.86, green: 0.44, blue: 1.00, alpha: 1), // orchid — THE WAVE
    ]

    /// The square station plate: ember room, extruded call number, name band.
    /// This is the lock-screen artwork when a record carries no cover of its
    /// own, and the base the car's Now Playing falls back to.
    static func plate(dial: String, name: String, accent: UIColor, size: CGFloat = 600) -> UIImage {
        let s = CGSize(width: size, height: size)
        return UIGraphicsImageRenderer(size: s).image { ctx in
            let cg = ctx.cgContext
            // The room: ink base + the accent burning up from below center.
            ink.setFill(); cg.fill(CGRect(origin: .zero, size: s))
            drawGlow(cg, in: s, accent: accent,
                     center: CGPoint(x: s.width / 2, y: s.height * 0.44),
                     radius: s.width * 0.78, alpha: 0.42)
            // The call number, extruded like the SIGN — stacked warm copies
            // falling down-right, then the bone face on top.
            let text = dial.isEmpty ? "RADI0" : dial
            let font = gasoek(size: size * (text.count > 3 ? 0.30 : 0.40))
            let face = NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: bone,
            ])
            let bounds = face.size()
            let origin = CGPoint(x: (s.width - bounds.width) / 2,
                                 y: (s.height - bounds.height) / 2 - size * 0.06)
            let depth = max(2, size * 0.016)
            for i in stride(from: 7, through: 1, by: -1) {
                let d = CGFloat(i) * depth / 2
                let layer = NSAttributedString(string: text, attributes: [
                    .font: font,
                    .foregroundColor: shade(accent, mix: 0.72 - CGFloat(i) * 0.05),
                ])
                layer.draw(at: CGPoint(x: origin.x + d, y: origin.y + d))
            }
            face.draw(at: origin)
            // The name band — cold caps in the room color.
            let nameAttr = NSAttributedString(string: name.uppercased(), attributes: [
                .font: archivo(size: size * 0.052),
                .foregroundColor: accent,
                .kern: size * 0.012,
            ])
            let nb = nameAttr.size()
            nameAttr.draw(at: CGPoint(x: (s.width - nb.width) / 2, y: s.height * 0.76))
            // The wordmark, small and quiet, up top.
            let mark = NSAttributedString(string: "RADI0", attributes: [
                .font: archivo(size: size * 0.036),
                .foregroundColor: bone.withAlphaComponent(0.5),
                .kern: size * 0.008,
            ])
            let mb = mark.size()
            mark.draw(at: CGPoint(x: (s.width - mb.width) / 2, y: s.height * 0.085))
        }
    }

    /// The car list tile — the plate compressed to a rounded chip. Bigger
    /// number, no wordmark; it has to read from the driver's seat.
    static func carTile(dial: String, accent: UIColor, size: CGFloat = 120) -> UIImage {
        let s = CGSize(width: size, height: size)
        return UIGraphicsImageRenderer(size: s).image { ctx in
            let cg = ctx.cgContext
            let rect = CGRect(origin: .zero, size: s)
            let clip = UIBezierPath(roundedRect: rect, cornerRadius: size * 0.22)
            clip.addClip()
            ink.setFill(); cg.fill(rect)
            drawGlow(cg, in: s, accent: accent,
                     center: CGPoint(x: s.width / 2, y: s.height * 0.42),
                     radius: s.width * 0.85, alpha: 0.5)
            let text = dial.isEmpty ? "?" : dial
            let font = gasoek(size: size * (text.count > 3 ? 0.30 : text.count > 2 ? 0.36 : 0.46))
            let face = NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: bone,
            ])
            let b = face.size()
            let origin = CGPoint(x: (s.width - b.width) / 2, y: (s.height - b.height) / 2)
            let depth = max(1.5, size * 0.02)
            for i in stride(from: 4, through: 1, by: -1) {
                let d = CGFloat(i) * depth / 2
                NSAttributedString(string: text, attributes: [
                    .font: font,
                    .foregroundColor: shade(accent, mix: 0.68 - CGFloat(i) * 0.06),
                ]).draw(at: CGPoint(x: origin.x + d, y: origin.y + d))
            }
            face.draw(at: origin)
            // Accent baseline — the tuner light.
            accent.setFill()
            cg.fill(CGRect(x: size * 0.2, y: size * 0.87, width: size * 0.6, height: max(2, size * 0.03)))
        }
    }

    // MARK: - Drawing helpers

    private static func drawGlow(_ cg: CGContext, in s: CGSize, accent: UIColor,
                                 center: CGPoint, radius: CGFloat, alpha: CGFloat) {
        let colors = [accent.withAlphaComponent(alpha).cgColor,
                      accent.withAlphaComponent(0).cgColor] as CFArray
        guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                    colors: colors, locations: [0, 1]) else { return }
        cg.drawRadialGradient(grad, startCenter: center, startRadius: 0,
                              endCenter: center, endRadius: radius, options: [])
    }

    /// A darker, warmer cut of the accent for the extrusion body.
    private static func shade(_ color: UIColor, mix: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let m = max(0.12, min(1, mix)) * 0.5
        return UIColor(red: r * m, green: g * m, blue: b * m, alpha: 1)
    }

    private static func gasoek(size: CGFloat) -> UIFont {
        UIFont(name: "Gasoek One", size: size) ?? .systemFont(ofSize: size, weight: .black)
    }

    private static func archivo(size: CGFloat) -> UIFont {
        UIFont(name: "Archivo Black", size: size) ?? .systemFont(ofSize: size, weight: .heavy)
    }
}

/// Resolves what the system Now Playing surfaces should SHOW for what's on
/// air: the record's real cover when it has one (Audius records do), the
/// station's branded plate otherwise. Cached both ways, so the lock screen
/// never waits and never refetches.
@MainActor
final class ArtworkService {
    private var plates: [UUID: UIImage] = [:]          // station id → plate
    private var covers: [String: UIImage] = [:]        // remote key → cover
    private var failedCovers: Set<String> = []         // don't re-fetch known misses

    /// The instant answer — the station plate, generated once per station.
    func plate(for station: Station, accentIndex: Int) -> UIImage {
        if let cached = plates[station.id] { return cached }
        let accent = StationArt.accents[accentIndex % StationArt.accents.count]
        let img = StationArt.plate(dial: station.dial, name: station.name, accent: accent)
        plates[station.id] = img
        return img
    }

    /// The full answer — the record's own cover if it can be found, else nil
    /// (caller keeps the plate). Audius stream URLs carry the track id, and
    /// the discovery API returns per-track artwork; anything else uses the
    /// track's own artworkURL when present.
    func cover(for track: Track) async -> UIImage? {
        // 1) A directly attached cover wins.
        if let url = track.artworkURL {
            return await fetchImage(key: url.absoluteString, from: url)
        }
        // 2) An Audius record: /v1/tracks/<id>/stream → ask the API for art.
        guard let asset = track.assetURL,
              asset.host?.contains("audius") == true else { return nil }
        let parts = asset.pathComponents
        guard let i = parts.firstIndex(of: "tracks"), i + 1 < parts.count else { return nil }
        let audiusID = parts[i + 1]
        let key = "audius:\(audiusID)"
        if let cached = covers[key] { return cached }
        if failedCovers.contains(key) { return nil }
        guard let meta = URL(string:
            "https://discoveryprovider.audius.co/v1/tracks/\(audiusID)?app_name=RADI0"
        ) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: meta)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let trackData = json?["data"] as? [String: Any]
            let artwork = trackData?["artwork"] as? [String: Any]
            let urlString = (artwork?["480x480"] ?? artwork?["1000x1000"] ?? artwork?["150x150"]) as? String
            guard let urlString, let artURL = URL(string: urlString) else {
                failedCovers.insert(key); return nil
            }
            return await fetchImage(key: key, from: artURL)
        } catch {
            // Transient network failure: no cover this time, but leave the
            // door open — do NOT mark failed.
            return nil
        }
    }

    private func fetchImage(key: String, from url: URL) async -> UIImage? {
        if let cached = covers[key] { return cached }
        if failedCovers.contains(key) { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let img = UIImage(data: data) else {
                failedCovers.insert(key); return nil
            }
            covers[key] = img
            // Covers are transient decoration — cap the cache so a long
            // listening session doesn't hoard memory.
            if covers.count > 40, let evict = covers.keys.first(where: { $0 != key }) {
                covers.removeValue(forKey: evict)
            }
            return img
        } catch {
            return nil
        }
    }
}
