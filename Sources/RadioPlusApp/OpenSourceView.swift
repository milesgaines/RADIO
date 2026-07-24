import SwiftUI

/// Native port of the prismui "Proudly open-source" block: headline, blurb,
/// live star count + contributor avatars pulled from the GitHub API, and a
/// Star-on-GitHub button. Ships with default stats (like the web component's
/// `defaultStats`) so the screen never renders empty offline.
struct OpenSourceView: View {

    private let repository = "milesgaines/RADIO"
    private var repoURL: URL { URL(string: "https://github.com/\(repository)")! }

    struct Contributor: Identifiable, Decodable {
        var id: String { login }
        let login: String
        let avatarURL: URL?

        enum CodingKeys: String, CodingKey {
            case login
            case avatarURL = "avatar_url"
        }
    }

    @State private var stars: Int = 0
    @State private var contributors: [Contributor] = [
        Contributor(login: "milesgaines",
                    avatarURL: URL(string: "https://avatars.githubusercontent.com/u/206545222?v=4")),
    ]

    var body: some View {
        ZStack {
            AuroraBackground()
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(colors: [.pink, .orange],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )

                Text("Proudly open-source")
                    .font(.system(size: 32, weight: .black, design: .rounded))
                    .multilineTextAlignment(.center)

                Text("Our source code is available on GitHub — feel free to read, review, or contribute to it however you want!")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)

                HStack(spacing: 24) {
                    statTile(value: "\(stars)", label: "stars", symbol: "star.fill")
                    statTile(value: "\(contributors.count)", label: "contributors", symbol: "person.2.fill")
                }

                contributorRow

                Link(destination: repoURL) {
                    HStack(spacing: 8) {
                        Image(systemName: "star.fill")
                        Text("Star on GitHub").fontWeight(.bold)
                    }
                    .padding(.horizontal, 28).padding(.vertical, 14)
                    .background(
                        LinearGradient(colors: [.pink, .orange],
                                       startPoint: .leading, endPoint: .trailing),
                        in: Capsule()
                    )
                    .foregroundStyle(.white)
                    .shadow(color: .pink.opacity(0.5), radius: 16, y: 6)
                }

                Spacer()
                Text(repository)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
            .padding()
        }
        .task { await loadStats() }
    }

    private func statTile(value: String, label: String, symbol: String) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.subheadline).foregroundStyle(.yellow)
                Text(value)
                    .font(.title2.bold().monospacedDigit())
                    .contentTransition(.numericText())
            }
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: 110)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var contributorRow: some View {
        HStack(spacing: -10) {
            ForEach(contributors.prefix(8)) { contributor in
                AsyncImage(url: contributor.avatarURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Circle().fill(.gray.opacity(0.4))
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.black, lineWidth: 2))
            }
        }
    }

    // MARK: - Live GitHub stats (best-effort; defaults remain on failure)

    private func loadStats() async {
        struct Repo: Decodable {
            let stargazersCount: Int
            enum CodingKeys: String, CodingKey { case stargazersCount = "stargazers_count" }
        }
        let api = "https://api.github.com/repos/\(repository)"
        if let url = URL(string: api),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let repo = try? JSONDecoder().decode(Repo.self, from: data) {
            withAnimation(.snappy) { stars = repo.stargazersCount }
        }
        if let url = URL(string: api + "/contributors?per_page=8"),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let people = try? JSONDecoder().decode([Contributor].self, from: data),
           !people.isEmpty {
            withAnimation(.snappy) { contributors = people }
        }
    }
}
