import SwiftUI
import AuthenticationServices
import RadioKit

// First-run and the sign-in gate. The radio is already playing behind all of
// this — none of it blocks sound. The landing "opens up" into the live room,
// the tour explains the instrument once, and the sign-in sheet only ever
// appears the first time someone acts.

// MARK: - Landing

/// The cover the app opens on: the RADI0 mark over a lit dial, which irises
/// open to reveal the room already playing. Instant-on — audio starts the
/// moment this appears; the cover is just the curtain lifting.
struct LandingCover: View {
    let accent: Color
    let onEnter: () -> Void

    @State private var open = false
    @State private var glow = false

    var body: some View {
        ZStack {
            HumanTheme.ink.ignoresSafeArea()

            // One broad ember behind the mark, breathing.
            RadialGradient(
                colors: [accent.opacity(glow ? 0.42 : 0.24), .clear],
                center: .init(x: 0.5, y: 0.42), startRadius: 8, endRadius: 340
            )
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: glow)

            VStack(spacing: 22) {
                Spacer()
                RadioPlusMark(size: 56, accent: accent, level: glow ? 0.5 : 0.1)
                    .scaleEffect(open ? 1.06 : 1)
                Text("FAN-VOTED LIVE RADIO")
                    .font(.custom("Archivo Black", size: 13))
                    .tracking(3)
                    .foregroundStyle(HumanTheme.bone.opacity(0.6))
                Spacer()
                Text("THE CROWD RUNS THE DIAL")
                    .font(.custom("Gasoek One", size: 26))
                    .foregroundStyle(HumanTheme.bone)
                    .multilineTextAlignment(.center)
                Button(action: enter) {
                    Text("TAP TO TUNE IN")
                        .font(.custom("Archivo Black", size: 14))
                        .tracking(2)
                        .foregroundStyle(HumanTheme.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 17)
                        .background(accent)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 40)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: enter)
        .scaleEffect(open ? 1.12 : 1)
        .opacity(open ? 0 : 1)
        .onAppear { glow = true }
    }

    private func enter() {
        Haptics.boost()
        withAnimation(.easeIn(duration: 0.55)) { open = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { onEnter() }
    }
}

// MARK: - Walkthrough tour

/// A five-beat walkthrough, shown once. Cold and quick — it teaches the dial,
/// the vote, and the one rule (listening is free; acting signs you in), then
/// gets out of the way. Swipeable, skippable.
struct TourOverlay: View {
    let accent: Color
    let onDone: () -> Void

    @State private var step = 0

    private struct Beat {
        let icon: String
        let head: String
        let body: String
    }

    private var beats: [Beat] {
        [
            Beat(icon: "dot.radiowaves.left.and.right",
                 head: "LIVE, TOGETHER",
                 body: "Everyone tuned in hears the same second you do. No pausing, no skipping — it's real radio."),
            Beat(icon: "arrow.up.arrow.down",
                 head: "YOU RUN THE DIAL",
                 body: "BOOST a record to push it up, BURY one to pull it down. The crowd's votes decide what stays on the air."),
            Beat(icon: "arrow.left.and.right",
                 head: "FOUR STATIONS",
                 body: "Swipe the dial or hit TUNE to move between stations. Each one has its own crowd and its own sound."),
            Beat(icon: "phone.fill",
                 head: "GET ON THE AIR",
                 body: "Hit THE LINE to call in like real radio. Hosts can take the whole station live from their phone."),
            Beat(icon: "checkmark.seal.fill",
                 head: "LISTEN FREE · SIGN IN TO ACT",
                 body: "Listening never needs an account. Your first boost signs you in with Apple — one person, one voter, no bots."),
        ]
    }

    var body: some View {
        ZStack {
            HumanTheme.ink.opacity(0.96).ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    RadioPlusMark(size: 22, accent: accent)
                    Spacer()
                    Button(action: onDone) {
                        Text("SKIP")
                            .font(.custom("Archivo Black", size: 12))
                            .tracking(1.5)
                            .foregroundStyle(HumanTheme.dim)
                            .frame(height: 44)
                            .padding(.horizontal, 8)
                    }
                }
                .padding(.horizontal, 26)
                .padding(.top, 8)

                TabView(selection: $step) {
                    ForEach(Array(beats.enumerated()), id: \.offset) { i, beat in
                        beatView(beat).tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                // Our own dots, in the station color.
                HStack(spacing: 8) {
                    ForEach(0..<beats.count, id: \.self) { i in
                        Capsule()
                            .fill(i == step ? accent : HumanTheme.bone.opacity(0.22))
                            .frame(width: i == step ? 20 : 7, height: 7)
                            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: step)
                    }
                }
                .padding(.bottom, 20)

                Button(action: advance) {
                    Text(step == beats.count - 1 ? "START LISTENING" : "NEXT")
                        .font(.custom("Archivo Black", size: 15))
                        .tracking(2)
                        .foregroundStyle(HumanTheme.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 17)
                        .background(accent)
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 34)
            }
        }
    }

    private func advance() {
        Haptics.detent()
        if step == beats.count - 1 { onDone() }
        else { withAnimation(.easeInOut(duration: 0.25)) { step += 1 } }
    }

    private func beatView(_ beat: Beat) -> some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: beat.icon)
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(accent)
                .frame(height: 64)
            Text(beat.head)
                .font(.custom("Gasoek One", size: 30))
                .foregroundStyle(HumanTheme.bone)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(beat.body)
                .font(.system(size: 15.5))
                .foregroundStyle(HumanTheme.dim)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300)
            Spacer()
        }
        .padding(.horizontal, 30)
    }
}

// MARK: - Sign-in gate

/// The sheet raised the first time a listener acts. Sign in with Apple, one
/// tap, no passwords — and it says plainly what it's for and that listening
/// never needed it.
struct SignInSheet: View {
    let accent: Color
    let reason: String
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            HumanTheme.ink.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    RadioPlusMark(size: 24, accent: accent)
                    Spacer()
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(HumanTheme.dim)
                            .frame(width: 40, height: 40)
                            .background(Circle().strokeBorder(HumanTheme.bone.opacity(0.2), lineWidth: 1))
                    }
                }

                Spacer()

                Text("SIGN IN\n\(reason.uppercased())")
                    .font(.custom("Gasoek One", size: 34))
                    .foregroundStyle(HumanTheme.bone)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text("One tap with Apple. No password. One Apple ID is one voter — that's how RADI0 keeps the tally honest and the bots out.")
                    .font(.system(size: 15))
                    .foregroundStyle(HumanTheme.dim)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName]
                } onCompletion: { result in
                    if case let .success(auth) = result,
                       let cred = auth.credential as? ASAuthorizationAppleIDCredential {
                        AuthService.shared.completeSignIn(userID: cred.user, fullName: cred.fullName)
                    }
                    // Failure/cancel: leave the sheet up so they can retry or
                    // close it themselves — no silent dismissal of their intent.
                }
                .signInWithAppleButtonStyle(.white)
                .frame(height: 54)

                Text("Just listening? Close this — the radio's already on.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(HumanTheme.dim.opacity(0.8))

                Spacer().frame(height: 8)
            }
            .padding(28)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
}
