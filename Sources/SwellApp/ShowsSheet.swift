import SwiftUI
import RadioKit

/// SHOWS — the visible face of live radio. What's on the air right now, the
/// archive of every taped broadcast, and the host door. This is the answer to
/// "where are the live features": they were all backend until this sheet.
struct ShowsSheet: View {
    @ObservedObject var stream: LiveStreamService
    @ObservedObject var player: RadioPlayer
    @StateObject private var shelf = EpisodesService()
    let accent: Color
    var onHostAccess: () -> Void = {}
    var onClose: () -> Void = {}

    private let ink = Color(red: 0.039, green: 0.039, blue: 0.047)
    private let bone = Color(red: 0.945, green: 0.925, blue: 0.878)
    private let dim = Color(red: 0.55, green: 0.53, blue: 0.50)

    var body: some View {
        ZStack {
            ink.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    Text("SHOWS")
                        .font(.custom("Gasoek One", size: 34))
                        .foregroundStyle(bone)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(bone.opacity(0.7))
                            .frame(width: 40, height: 40)
                            .background(Circle().strokeBorder(bone.opacity(0.2), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 22).padding(.top, 20)

                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        // ── ON AIR ────────────────────────────────────────
                        VStack(alignment: .leading, spacing: 10) {
                            sectionHead("ON AIR")
                            if player.isLive {
                                HStack(spacing: 10) {
                                    Circle().fill(accent).frame(width: 8, height: 8)
                                    Text(player.liveTitle.isEmpty ? "LIVE" : player.liveTitle)
                                        .font(.custom("Archivo Black", size: 15))
                                        .foregroundStyle(bone)
                                    Spacer()
                                    Text("YOU'RE TUNED IN")
                                        .font(.custom("Archivo Black", size: 9)).tracking(1.2)
                                        .foregroundStyle(accent)
                                }
                                .padding(14)
                                .background(RoundedRectangle(cornerRadius: 14)
                                    .strokeBorder(accent.opacity(0.5), lineWidth: 1))
                            } else {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("NO HOST ON AIR · THE ROTATION RUNS 24/7")
                                        .font(.custom("Archivo Black", size: 11)).tracking(0.8)
                                        .foregroundStyle(dim)
                                    Text("When a host opens the mic, every radio on this station flips to the show — nothing to install, nothing to sign into.")
                                        .font(.system(size: 12))
                                        .foregroundStyle(dim.opacity(0.8))
                                }
                            }
                        }

                        // ── THE ARCHIVE ───────────────────────────────────
                        VStack(alignment: .leading, spacing: 10) {
                            sectionHead("THE ARCHIVE")
                            if !shelf.loaded {
                                Text("PULLING THE TAPES…")
                                    .font(.custom("Archivo Black", size: 10)).tracking(1.2)
                                    .foregroundStyle(dim)
                            } else if shelf.episodes.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("NO SHOWS TAPED YET")
                                        .font(.custom("Archivo Black", size: 11)).tracking(0.8)
                                        .foregroundStyle(dim)
                                    Text("Every live broadcast tapes itself. When the mic drops, the show lands here — full length, replayable.")
                                        .font(.system(size: 12))
                                        .foregroundStyle(dim.opacity(0.8))
                                }
                            } else {
                                ForEach(shelf.episodes) { ep in
                                    episodeRow(ep)
                                }
                            }
                        }

                        // ── HOST DOOR ─────────────────────────────────────
                        Button(action: onHostAccess) {
                            HStack(spacing: 8) {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(.system(size: 11, weight: .bold))
                                Text("HOST ACCESS")
                                    .font(.custom("Archivo Black", size: 10)).tracking(1.4)
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                            }
                            .foregroundStyle(dim)
                            .padding(.horizontal, 14).padding(.vertical, 12)
                            .overlay(RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(dim.opacity(0.3), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 6)
                    }
                    .padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 30)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await shelf.refresh() }
        .onDisappear { shelf.stop() }   // never leave a replay singing offscreen
    }

    private func episodeRow(_ ep: EpisodesService.Episode) -> some View {
        let playing = shelf.playingID == ep.id
        return HStack(spacing: 12) {
            Button {
                playing ? shelf.stop() : shelf.play(ep, radio: player)
            } label: {
                Image(systemName: playing ? "stop.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(playing ? accent : bone)
                    .frame(width: 40, height: 40)
                    .background(Circle().strokeBorder(
                        (playing ? accent : bone).opacity(0.4), lineWidth: 1))
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 3) {
                Text(ep.title)
                    .font(.custom("Archivo Black", size: 13))
                    .foregroundStyle(bone)
                    .lineLimit(1)
                Text(Self.stamp(ep))
                    .font(.custom("Archivo Black", size: 9)).tracking(1)
                    .foregroundStyle(dim)
            }
            Spacer()
            if playing {
                Text("REPLAY")
                    .font(.custom("Archivo Black", size: 9)).tracking(1.2)
                    .foregroundStyle(accent)
            }
        }
        .padding(.vertical, 4)
    }

    private func sectionHead(_ title: String) -> some View {
        Text(title)
            .font(.custom("Archivo Black", size: 11)).tracking(2)
            .foregroundStyle(accent)
    }

    private static func stamp(_ ep: EpisodesService.Episode) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d · h:mm a"
        var s = f.string(from: ep.recordedAt).uppercased()
        if let d = ep.durationSeconds, d > 0 {
            s += String(format: " · %d:%02d", Int(d) / 60, Int(d) % 60)
        }
        return s
    }
}
