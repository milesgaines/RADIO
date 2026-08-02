import SwiftUI
import RadioKit

/// SLEEP — the bedside face of the radio. Near-black room, the time in big
/// quiet type, the station's ember breathing low with the record. A sleep
/// timer puts the station down after 15/30/45 minutes — radio's oldest
/// night-stand ritual. Tap anywhere to wake back to the room.
///
/// The screen stays on (idle timer off) and dims the panel to a whisper while
/// visible; both are restored on the way out.
struct SleepScreen: View {
    @ObservedObject var stream: LiveStreamService
    @ObservedObject var player: RadioPlayer
    let accent: Color
    let dial: String
    var onClose: () -> Void = {}

    /// Minutes → the moment the station goes down. nil = no timer.
    @State private var offAt: Date?
    @State private var wentDark = false
    @State private var savedBrightness: CGFloat = UIScreen.main.brightness

    private let ink = Color.black
    private let bone = Color(red: 0.945, green: 0.925, blue: 0.878)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ZStack {
                ink.ignoresSafeArea()
                // The ember, barely there — the room breathing in its sleep.
                RadialGradient(
                    colors: [accent.opacity(0.05 + Double(player.levels.bass) * 0.05), .clear],
                    center: .init(x: 0.5, y: 0.62),
                    startRadius: 10, endRadius: 420
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer()

                    Text(Self.clock.string(from: context.date))
                        .font(.custom("Gasoek One", size: 92))
                        .foregroundStyle(bone.opacity(0.82))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6).lineLimit(1)
                    Text(Self.day.string(from: context.date).uppercased())
                        .font(.custom("Archivo Black", size: 13)).tracking(3)
                        .foregroundStyle(bone.opacity(0.30))
                        .padding(.top, 2)

                    Spacer()

                    // The station, still on under the dark.
                    VStack(spacing: 8) {
                        Text("\(dial) · \(stream.station.name.uppercased())")
                            .font(.custom("Archivo Black", size: 13)).tracking(2)
                            .foregroundStyle(accent.opacity(0.75))
                        if wentDark {
                            Text("OFF AIR · GOOD NIGHT")
                                .font(.custom("Archivo Black", size: 11)).tracking(1.6)
                                .foregroundStyle(bone.opacity(0.35))
                        } else if let np = stream.nowPlaying {
                            Text("\(np.track.title) — \(np.track.artistName)")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(bone.opacity(0.40))
                                .lineLimit(1)
                                .padding(.horizontal, 32)
                        }
                    }

                    // The sleep timer — pick a fuse, watch it burn down.
                    HStack(spacing: 10) {
                        if let offAt, !wentDark {
                            Text("OFF AIR IN \(Self.countdown(to: offAt, from: context.date))")
                                .font(.custom("Archivo Black", size: 12)).tracking(1.4)
                                .foregroundStyle(accent)
                                .monospacedDigit()
                            chip("CANCEL") { self.offAt = nil }
                        } else if !wentDark {
                            Text("SLEEP IN")
                                .font(.custom("Archivo Black", size: 11)).tracking(1.4)
                                .foregroundStyle(bone.opacity(0.35))
                            ForEach([15, 30, 45], id: \.self) { minutes in
                                chip("\(minutes)") {
                                    offAt = context.date.addingTimeInterval(Double(minutes) * 60)
                                }
                            }
                        }
                    }
                    .padding(.top, 26)

                    Text("TAP TO WAKE")
                        .font(.custom("Archivo Black", size: 9)).tracking(2)
                        .foregroundStyle(bone.opacity(0.18))
                        .padding(.top, 30)
                        .padding(.bottom, 24)
                }
            }
            .onChange(of: context.date) { _, now in
                if let offAt, now >= offAt, !wentDark {
                    wentDark = true
                    player.pause()
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onClose() }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .onAppear {
            savedBrightness = UIScreen.main.brightness
            UIApplication.shared.isIdleTimerDisabled = true
            withAnimation(.easeOut(duration: 1.2)) {
                UIScreen.main.brightness = max(0.10, savedBrightness * 0.25)
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            UIScreen.main.brightness = savedBrightness
        }
    }

    private func chip(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.custom("Archivo Black", size: 12)).tracking(1)
                .foregroundStyle(bone.opacity(0.7))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .overlay(Capsule().strokeBorder(bone.opacity(0.22), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private static func countdown(to end: Date, from now: Date) -> String {
        let s = max(0, Int(end.timeIntervalSince(now)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm"; return f
    }()
    private static let day: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE · MMM d"; return f
    }()
}
