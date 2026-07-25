import SwiftUI
import RadioKit

/// Connect RADIO+ to a self-hosted Navidrome server
/// (https://www.navidrome.org/docs/installation/). Once connected, the live
/// station draws its rotation from your library instead of the demo catalog.
struct SettingsView: View {
    @AppStorage(NavidromeConfig.StorageKey.baseURL) private var baseURL: String = ""
    @AppStorage(NavidromeConfig.StorageKey.username) private var username: String = ""
    /// The password is keychain-held, so it can't be an `@AppStorage` binding:
    /// it's loaded on appear and written back only once a server has accepted
    /// it. See `NavidromeConfig.SecretKey.password`.
    @State private var password: String = ""

    @ObservedObject private var services = AppServices.shared

    enum TestState: Equatable {
        case idle, testing, ok, failed(String)
    }
    @State private var testState: TestState = .idle

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Source") {
                        switch services.catalogSource {
                        case .demo:
                            Text("Demo catalog")
                        case .liveRadio:
                            Label("Live radio", systemImage: "dot.radiowaves.left.and.right")
                                .foregroundStyle(.pink)
                        case .navidrome(let host):
                            Label(host, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                } header: {
                    Text("Now streaming from")
                }

                Section {
                    TextField("https://music.example.com", text: $baseURL)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Username", text: $username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Password", text: $password)
                } header: {
                    Text("Navidrome server")
                } footer: {
                    Text("Self-host your catalog with Navidrome — see navidrome.org/docs/installation. RADIO+ streams via the Subsonic API; your password is kept in the device keychain and never leaves the device un-hashed.")
                }

                Section {
                    Button {
                        testConnection()
                    } label: {
                        HStack {
                            Text("Test & connect")
                            Spacer()
                            switch testState {
                            case .idle:
                                EmptyView()
                            case .testing:
                                ProgressView()
                            case .ok:
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            case .failed:
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                            }
                        }
                    }
                    .disabled(baseURL.isEmpty || username.isEmpty || password.isEmpty || testState == .testing)

                    if case .failed(let message) = testState {
                        Text(message).font(.caption).foregroundStyle(.red)
                    }

                    // Clearing the field alone no longer forgets the password
                    // now that it lives in the keychain, so say it explicitly.
                    Button("Forget saved password", role: .destructive) {
                        forgetPassword()
                    }
                    .disabled(password.isEmpty)
                }

                Section {
                    Link(destination: URL(string: "https://www.navidrome.org/docs/installation/")!) {
                        Label("Navidrome install guide", systemImage: "arrow.up.right.square")
                    }
                    Link(destination: URL(string: "https://github.com/milesgaines/RADIO")!) {
                        Label("RADIO+ on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear(perform: loadStoredPassword)
        }
    }

    /// Pull the saved password out of the keychain so the field reflects what
    /// the station is actually connecting with.
    private func loadStoredPassword() {
        guard password.isEmpty else { return }
        password = KeychainSecretStore.shared
            .secret(forKey: NavidromeConfig.SecretKey.password) ?? ""
    }

    private func forgetPassword() {
        try? NavidromeConfig.forgetPassword()
        password = ""
        testState = .idle
        AppServices.shared.reloadCatalog()
    }

    private func testConnection() {
        guard let url = URL(string: baseURL) else {
            testState = .failed("That server URL doesn't look valid.")
            return
        }
        let config = NavidromeConfig(baseURL: url, username: username, password: password)
        testState = .testing
        Task {
            do {
                try await NavidromeClient(config: config).ping()
                // Only ever persist a credential the server has accepted.
                try config.savePassword()
                testState = .ok
                AppServices.shared.reloadCatalog()
            } catch {
                testState = .failed(error.localizedDescription)
            }
        }
    }
}
