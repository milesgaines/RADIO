import SwiftUI
import RadioKit

// The two moments around a BOOST, rebuilt in the app's own language — no more
// flat color floods, no more stock system alerts. A boost is the oldest thrill
// radio has (they played your record); it should look like the marquee.

private let ink = Color(red: 0.039, green: 0.039, blue: 0.047)
private let bone = Color(red: 0.945, green: 0.925, blue: 0.878)

/// Reusable extruded type — a bone face with a top-light over a warm stacked
/// body. The same 3D sign treatment the dial uses, factored out.
struct ExtrudedText: View {
    let text: String
    var size: CGFloat
    var faceTop: Color = bone
    var faceBottom: Color = Color(red: 0.80, green: 0.77, blue: 0.68)
    var side: Color = Color(red: 0.17, green: 0.10, blue: 0.07)
    var depth: Int = 6

    var body: some View {
        ZStack {
            ForEach(1...depth, id: \.self) { i in
                Text(text)
                    .foregroundStyle(side)
                    .offset(x: CGFloat(i) * 1.3, y: CGFloat(i) * 1.9)
            }
            Text(text).foregroundStyle(
                LinearGradient(colors: [faceTop, faceBottom], startPoint: .top, endPoint: .bottom)
            )
        }
        .font(.custom("Gasoek One", size: size))
        .lineLimit(1)
        .minimumScaleFactor(0.4)
        .multilineTextAlignment(.center)
        .shadow(color: .black.opacity(0.4), radius: 12, y: 9)
    }
}

/// The payoff: your boosted record finally airs. A warm ember room, the sign
/// lit, the track named — the emotional high point, built like the app.
struct RecordIsOnView: View {
    let track: Track
    let accent: Color
    let dedication: String?
    let bass: Float

    var body: some View {
        ZStack {
            ink.ignoresSafeArea()
            RadialGradient(
                colors: [accent.opacity(0.92), accent.opacity(0.34), ink],
                center: .init(x: 0.5, y: 0.42),
                startRadius: 8, endRadius: 520 + CGFloat(bass) * 200
            )
            .ignoresSafeArea()

            VStack(spacing: 16) {
                Text("YOUR RECORD")
                    .font(.custom("Archivo Black", size: 17))
                    .tracking(5)
                    .foregroundStyle(ink.opacity(0.72))
                ExtrudedText(text: "IS ON", size: 84, depth: 7)
                    .scaleEffect(1 + CGFloat(bass) * 0.05)
                    .animation(.linear(duration: 0.08), value: Int(bass * 10))
                Text(track.title.uppercased())
                    .font(.custom("Archivo Black", size: 15))
                    .tracking(2)
                    .foregroundStyle(ink)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
                if let dedication, !dedication.isEmpty {
                    Text("THIS ONE GOES OUT TO \(dedication.uppercased())")
                        .font(.custom("Archivo Black", size: 12))
                        .tracking(1.6)
                        .foregroundStyle(ink.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 30)
        }
    }
}

/// Send-it-out: dedicate a boost. Replaces the stock iOS alert with the app's
/// own card — tracked caps, a hairline field, square bordered keys.
struct DedicationOverlay: View {
    let accent: Color
    @Binding var name: String
    let onSend: () -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            ink.opacity(0.93).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onCancel() }

            VStack(spacing: 22) {
                Text("SEND IT OUT")
                    .font(.custom("Gasoek One", size: 34))
                    .foregroundStyle(bone)
                Text("BOOST THIS RECORD AND PUT THEIR NAME ON IT WHEN IT AIRS")
                    .font(.custom("Archivo Black", size: 11))
                    .tracking(1.3)
                    .foregroundStyle(bone.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 280)

                VStack(spacing: 8) {
                    TextField("", text: $name, prompt: Text("WHO'S IT FOR")
                        .font(.custom("Archivo Black", size: 13)).foregroundStyle(bone.opacity(0.3)))
                        .font(.custom("Archivo Black", size: 14))
                        .foregroundStyle(bone)
                        .multilineTextAlignment(.center)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .submitLabel(.send)
                        .focused($focused)
                        .onSubmit(onSend)
                    Rectangle().fill(bone.opacity(0.15)).frame(height: 1)
                }
                .frame(maxWidth: 260)

                HStack(spacing: 12) {
                    key("SEND IT", tint: accent, action: onSend)
                    key("CANCEL", tint: bone.opacity(0.55), action: onCancel)
                }
            }
            .padding(28)
        }
        .preferredColorScheme(.dark)
        .onAppear { focused = true }
    }

    private func key(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.custom("Archivo Black", size: 13))
                .tracking(2)
                .foregroundStyle(tint)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .overlay(Rectangle().strokeBorder(tint, lineWidth: 1.5))
        }
    }
}
