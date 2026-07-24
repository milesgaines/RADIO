import SwiftUI
import RadioKit

/// RADIO+ shell: three tabs. Live is the show; Open Source is the community
/// front door; Settings connects your Navidrome server.
struct RootView: View {
    var body: some View {
        TabView {
            LiveView()
                .tabItem { Label("Live", systemImage: "dot.radiowaves.left.and.right") }
            OpenSourceView()
                .tabItem { Label("Open Source", systemImage: "chevron.left.forwardslash.chevron.right") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .tint(.pink)
        .preferredColorScheme(.dark)
    }
}
