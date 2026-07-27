import SwiftUI
import RadioKit

/// HIT RECORD. A big record key tapes the program off the air; below it, your
/// shelf of AIRCHECKS — each one playable, deletable, and shareable as a card.
struct AircheckSheet: View {
    @ObservedObject var service: AircheckService
    let station: Station
    let now: NowPlaying?
    let accent: Color
    var onClose: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    private let ink = Color(red: 0.039, green: 0.039, blue: 0.047)
    private let bone = Color(red: 0.945, green: 0.925, blue: 0.878)

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("AIRCHECK")
                    .font(.custom("Gasoek One", size: 30))
                    .foregroundStyle(bone)
                Spacer()
                Button { dismiss(); onClose() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(bone.opacity(0.55))
                        .frame(width: 38, height: 38)
                        .background(Circle().strokeBorder(bone.opacity(0.2), lineWidth: 1))
                }
            }

            recordPanel

            Divider().overlay(bone.opacity(0.15))

            HStack {
                Text("YOUR AIRCHECKS")
                    .font(.custom("Archivo Black", size: 12)).tracking(1.4)
                    .foregroundStyle(bone.opacity(0.55))
                Spacer()
                Text("\(service.count)")
                    .font(.custom("Archivo Black", size: 12))
                    .foregroundStyle(accent)
            }

            if service.airchecks.isEmpty {
                Text("Nothing taped yet. Hit record while a record you love is on — you'll have a keepsake of the exact moment.")
                    .font(.system(size: 13.5)).foregroundStyle(bone.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                Spacer()
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(service.airchecks) { row($0) }
                    }
                }
            }
        }
        .padding(26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ink)
        .preferredColorScheme(.dark)
    }

    // MARK: Record

    private var recordPanel: some View {
        VStack(spacing: 14) {
            Button {
                service.toggle(station: station, now: now)
            } label: {
                ZStack {
                    Circle()
                        .fill(RadialGradient(
                            colors: service.isRecording
                                ? [Color(red: 1, green: 0.42, blue: 0.36), Color(red: 0.86, green: 0.18, blue: 0.16)]
                                : [Color(red: 0.22, green: 0.2, blue: 0.2), Color(red: 0.09, green: 0.085, blue: 0.09)],
                            center: .init(x: 0.35, y: 0.3), startRadius: 4, endRadius: 70))
                        .frame(width: 92, height: 92)
                        .overlay(Circle().strokeBorder(bone.opacity(service.isRecording ? 0.5 : 0.2), lineWidth: 1.5))
                        .shadow(color: (service.isRecording ? Color.red : .black).opacity(0.45), radius: 14, y: 5)
                    if service.isRecording {
                        RoundedRectangle(cornerRadius: 5).fill(bone).frame(width: 26, height: 26)
                    } else {
                        Circle().fill(Color(red: 0.92, green: 0.24, blue: 0.2)).frame(width: 34, height: 34)
                    }
                }
            }
            .buttonStyle(PressKey())

            if service.isRecording {
                Text(timeString(service.elapsed))
                    .font(.custom("Archivo Black", size: 22)).monospacedDigit()
                    .foregroundStyle(bone)
                Text("ROLLING · \(station.name.uppercased())")
                    .font(.custom("Archivo Black", size: 10)).tracking(1.6)
                    .foregroundStyle(accent)
            } else {
                Text("HIT RECORD")
                    .font(.custom("Archivo Black", size: 13)).tracking(2)
                    .foregroundStyle(bone.opacity(0.85))
                Text("Tapes the program straight off the air.")
                    .font(.system(size: 12)).foregroundStyle(bone.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(bone.opacity(0.04))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(bone.opacity(0.12), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    // MARK: Library row

    private func row(_ a: Aircheck) -> some View {
        HStack(spacing: 12) {
            VStack(spacing: 0) {
                Text(a.dial.isEmpty ? "808" : a.dial)
                    .font(.custom("Gasoek One", size: a.dial.count > 3 ? 15 : 19))
                    .foregroundStyle(bone).lineLimit(1).minimumScaleFactor(0.5)
            }
            .frame(width: 52, height: 52)
            .background(accent.opacity(0.18))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(accent.opacity(0.5), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 2) {
                Text(a.trackTitle)
                    .font(.custom("Instrument Serif", size: 18))
                    .foregroundStyle(bone).lineLimit(1)
                Text("\(a.stationName.uppercased()) · \(dateString(a.at)) · \(timeString(a.duration))")
                    .font(.custom("Archivo Black", size: 9)).tracking(0.6)
                    .foregroundStyle(bone.opacity(0.5)).lineLimit(1)
            }
            Spacer(minLength: 4)

            if a.fileName != nil {
                Button { service.play(a) } label: {
                    Image(systemName: "play.fill").font(.system(size: 14, weight: .bold))
                        .foregroundStyle(accent).frame(width: 34, height: 34)
                }
            }
            if let img = cardImage(for: a) {
                ShareLink(item: img, preview: SharePreview("Aircheck — \(a.trackTitle)", image: img)) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(bone.opacity(0.7)).frame(width: 34, height: 34)
                }
            }
            Button { service.delete(a) } label: {
                Image(systemName: "trash").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(bone.opacity(0.4)).frame(width: 30, height: 34)
            }
        }
        .padding(10)
        .background(bone.opacity(0.04))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(bone.opacity(0.1), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Share card

    @MainActor private func cardImage(for a: Aircheck) -> Image? {
        let renderer = ImageRenderer(content: AircheckCard(aircheck: a, accent: accent))
        renderer.scale = 3
        guard let ui = renderer.uiImage else { return nil }
        return Image(uiImage: ui)
    }

    private func timeString(_ s: Double) -> String {
        let t = Int(s.rounded()); return String(format: "%d:%02d", t / 60, t % 60)
    }
    private func dateString(_ d: Date) -> String {
        d.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

/// The shareable aircheck: a lit dial card of the exact moment — dial number,
/// station, the record that was on, the time, how long you rolled. Square, so
/// it drops cleanly into a story or a DM.
struct AircheckCard: View {
    let aircheck: Aircheck
    let accent: Color
    private let ink = Color(red: 0.039, green: 0.039, blue: 0.047)
    private let bone = Color(red: 0.965, green: 0.945, blue: 0.9)

    var body: some View {
        ZStack {
            ink
            RadialGradient(colors: [accent.opacity(0.45), .clear], center: .init(x: 0.5, y: 0.38),
                           startRadius: 6, endRadius: 360)
            VStack(spacing: 0) {
                HStack {
                    Text("AIRCHECK").font(.custom("Archivo Black", size: 15)).tracking(3)
                        .foregroundStyle(bone.opacity(0.7))
                    Spacer()
                    Text("RADI0").font(.custom("Gasoek One", size: 20)).foregroundStyle(bone)
                }
                Spacer()
                Text(aircheck.dial.isEmpty ? "808" : aircheck.dial)
                    .font(.custom("Gasoek One", size: aircheck.dial.count > 3 ? 96 : 132))
                    .foregroundStyle(LinearGradient(colors: [bone, bone.opacity(0.75)],
                                                    startPoint: .top, endPoint: .bottom))
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .shadow(color: .black.opacity(0.4), radius: 14, y: 10)
                Text(aircheck.stationName.uppercased())
                    .font(.custom("Archivo Black", size: 22)).tracking(4)
                    .foregroundStyle(accent)
                Spacer()
                VStack(spacing: 4) {
                    Text(aircheck.trackTitle)
                        .font(.custom("Instrument Serif", size: 30)).foregroundStyle(bone)
                        .lineLimit(1).minimumScaleFactor(0.5)
                    if !aircheck.artistName.isEmpty {
                        Text(aircheck.artistName.uppercased())
                            .font(.custom("Archivo Black", size: 12)).tracking(1.5)
                            .foregroundStyle(bone.opacity(0.6))
                    }
                }
                Spacer()
                HStack {
                    Text(aircheck.at.formatted(.dateTime.month(.abbreviated).day().year().hour().minute()))
                        .font(.custom("Archivo Black", size: 11)).tracking(0.8)
                        .foregroundStyle(bone.opacity(0.5))
                    Spacer()
                    Text(String(format: "%d:%02d ON TAPE", Int(aircheck.duration) / 60, Int(aircheck.duration) % 60))
                        .font(.custom("Archivo Black", size: 11)).tracking(0.8)
                        .foregroundStyle(bone.opacity(0.5))
                }
            }
            .padding(40)
        }
        .frame(width: 520, height: 520)
    }
}
