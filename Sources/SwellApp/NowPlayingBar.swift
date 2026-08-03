import SwiftUI
import RadioKit

/// NOW PLAYING + THE ROOM — the record on air, with a face, and the crowd's
/// push made visible. Cover art (the record's own when it has one), the title
/// big enough to read, and a live boost meter that surges as real votes land —
/// so "YOU PROGRAM THE STATION" stops being a claim and becomes something you
/// watch happen. A live show owns the band outright.
struct NowPlayingBar: View {
    @ObservedObject var stream: LiveStreamService
    @ObservedObject var player: RadioPlayer
    let cover: UIImage?
    let accent: Color
    let yourPick: Bool

    private let ink = Color(red: 0.039, green: 0.039, blue: 0.047)
    private let bone = Color(red: 0.945, green: 0.925, blue: 0.878)
    private let dim = Color(red: 0.55, green: 0.53, blue: 0.50)

    /// A strong net push from the room reads as BREAKING — the record is
    /// climbing on real votes, not a label.
    private func breaking(_ score: Int) -> Bool { score >= 6 }

    var body: some View {
        VStack(spacing: 0) {
            rule
            content.padding(.vertical, 12)
            rule
        }
    }

    @ViewBuilder private var content: some View {
        if player.isLive {
            HStack(spacing: 12) {
                cap("LIVE")
                Text(player.liveTitle.isEmpty
                     ? "LIVE ON \(stream.station.name.uppercased())"
                     : player.liveTitle.uppercased())
                    .font(.custom("Archivo Black", size: 16))
                    .foregroundStyle(bone).lineLimit(1).minimumScaleFactor(0.6)
                Spacer(minLength: 0)
                dialChip
            }
        } else if let np = stream.nowPlaying {
            let score = np.boostScore
            let hot = breaking(score)
            HStack(spacing: 12) {
                coverThumb
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        cap(yourPick ? "YOUR PICK" : "ON AIR")
                        if hot {
                            Text("BREAKING")
                                .font(.custom("Archivo Black", size: 9)).tracking(1.4)
                                .foregroundStyle(ink)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(accent))
                        }
                        Spacer(minLength: 0)
                        boostPill(score)
                    }
                    Text(np.track.title)
                        .font(.custom("Archivo Black", size: 17))
                        .foregroundStyle(bone)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text(np.track.artistName.uppercased())
                        .font(.custom("Archivo Black", size: 10)).tracking(1.4)
                        .foregroundStyle(dim)
                        .lineLimit(1)
                    BoostMeter(score: score, breaking: hot, accent: accent)
                        .padding(.top, 1)
                }
                dialChip
            }
        }
    }

    // The record's face: its own cover, or a drawn disc when it has none.
    private var coverThumb: some View {
        Group {
            if let cover {
                Image(uiImage: cover).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 11).fill(
                        LinearGradient(colors: [Color(white: 0.14), Color(white: 0.05)],
                                       startPoint: .top, endPoint: .bottom))
                    Circle().fill(.black).frame(width: 42, height: 42)
                        .overlay(Circle().strokeBorder(bone.opacity(0.10), lineWidth: 1))
                    Circle().fill(accent).frame(width: 13, height: 13)
                    Circle().fill(ink).frame(width: 4, height: 4)
                }
            }
        }
        .frame(width: 54, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(bone.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 5, y: 3)
    }

    private func boostPill(_ score: Int) -> some View {
        Text(score > 0 ? "▲\(score)" : score < 0 ? "▼\(-score)" : "—")
            .font(.custom("Archivo Black", size: 15))
            .monospacedDigit()
            .foregroundStyle(score > 0 ? accent : score < 0 ? bone.opacity(0.7) : dim)
            .contentTransition(.numericText())
            .animation(.snappy, value: score)
    }

    private func cap(_ text: String) -> some View {
        Text(text)
            .font(.custom("Archivo Black", size: 10)).tracking(1.2)
            .foregroundStyle(ink)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(accent))
            .shadow(color: accent.opacity(0.5), radius: 6)
    }

    private var dialChip: some View {
        Text("DIAL ▾")
            .font(.custom("Archivo Black", size: 10)).tracking(1.2)
            .foregroundStyle(bone.opacity(0.6))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .overlay(Capsule().strokeBorder(bone.opacity(0.25), lineWidth: 1))
    }

    private var rule: some View {
        Rectangle()
            .fill(LinearGradient(
                colors: [.clear, accent.opacity(0.55 + Double(player.levels.bass) * 0.4), .clear],
                startPoint: .leading, endPoint: .trailing))
            .frame(height: 1.5)
            .animation(.linear(duration: 0.1), value: Int(player.levels.bass * 10))
    }
}

/// The live boost meter: how hard the room is pushing this record, right now.
/// The fill surges when a vote lands (the score changes and the bar springs);
/// BREAKING lights it up. Buried records drain and go cold.
struct BoostMeter: View {
    let score: Int
    let breaking: Bool
    let accent: Color

    private let bone = Color(red: 0.945, green: 0.925, blue: 0.878)

    /// 0…1, centered near neutral so a fresh record still shows a warm ember;
    /// climbs toward full as boosts stack, drains as buries do.
    private var fill: Double {
        0.10 + 0.88 * (0.5 + 0.5 * tanh(Double(score) / 10.0))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(bone.opacity(0.10))
                Capsule()
                    .fill(LinearGradient(
                        colors: [accent.opacity(0.75), accent],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, geo.size.width * fill))
                    .shadow(color: accent.opacity(breaking ? 0.8 : 0.3),
                            radius: breaking ? 7 : 2)
            }
        }
        .frame(height: 5)
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: score)
    }
}
