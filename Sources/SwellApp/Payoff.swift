import SwiftUI

// Send-it-out: dedicate a boost, in the app's own language — no stock system
// alert. (The airing payoff itself is now a cold YOUR PICK flip in the
// marquee cap, handled in RootView — no full-screen victory lap.)

private let ink = Color(red: 0.039, green: 0.039, blue: 0.047)
private let bone = Color(red: 0.945, green: 0.925, blue: 0.878)

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
