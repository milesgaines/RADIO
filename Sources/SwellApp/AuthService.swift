import Foundation
import Combine
import AuthenticationServices

/// "Listen instantly, sign in to act."
///
/// The radio plays the second the app opens — no wall, no account. Sign in
/// with Apple only steps in the first time a listener *acts* on the station:
/// boost, bury, dedicate, or take the air. That Apple identity is stable per
/// Apple ID across reinstalls and devices, so one person is one voter — the
/// real Sybil boundary the device-UUID key never was.
///
/// The gate is deferred, not blocking: an action taken while signed out is
/// stashed, the sign-in sheet is raised, and the moment it succeeds the
/// original action runs. Tap BOOST, sign in, and the boost you meant lands —
/// you never have to tap it twice.
@MainActor
final class AuthService: NSObject, ObservableObject {
    static let shared = AuthService()

    /// Apple's stable user identifier (nil when signed out).
    @Published private(set) var userID: String?
    /// The name Apple returned on first sign-in (kept for the marquee/profile).
    @Published private(set) var displayName: String?

    /// A pending gated action, wrapped so a SwiftUI `.sheet(item:)` can drive
    /// the sign-in prompt and show *why* we're asking.
    struct Prompt: Identifiable {
        let id = UUID()
        let reason: String          // "to boost this record", "to go live"
        let action: () -> Void
    }
    @Published var prompt: Prompt?

    private let defaults = UserDefaults.standard
    private let userKey = "swell.auth.appleUserID"
    private let nameKey = "swell.auth.displayName"

    /// Fired once when a listener signs in — the app promotes its identity
    /// (verified listener, Apple id becomes the vote key).
    private var onSignIn: ((_ appleUserID: String, _ name: String?) -> Void)?

    var isSignedIn: Bool { userID != nil }

    private override init() {
        super.init()
        userID = defaults.string(forKey: userKey)
        displayName = defaults.string(forKey: nameKey)
    }

    /// Wire the app's identity promotion (called from AppServices).
    func configure(onSignIn: @escaping (_ appleUserID: String, _ name: String?) -> Void) {
        self.onSignIn = onSignIn
        // A returning signed-in listener re-promotes on launch so the vote key
        // is the Apple id from the first request, not the device UUID.
        if let uid = userID { onSignIn(uid, displayName) }
    }

    /// Run `action` now if signed in; otherwise stash it and raise the sheet.
    /// The one call every gated control uses.
    func requireSignIn(reason: String, then action: @escaping () -> Void) {
        if isSignedIn { action(); return }
        prompt = Prompt(reason: reason, action: action)
    }

    /// Apple returned a credential — persist it, promote identity, and run
    /// whatever the listener was trying to do when we interrupted them.
    func completeSignIn(userID: String, fullName: PersonNameComponents?) {
        self.userID = userID
        defaults.set(userID, forKey: userKey)
        if let fullName {
            let formatted = PersonNameComponentsFormatter().string(from: fullName)
            if !formatted.trimmingCharacters(in: .whitespaces).isEmpty {
                displayName = formatted
                defaults.set(formatted, forKey: nameKey)
            }
        }
        onSignIn?(userID, displayName)
        let pending = prompt
        prompt = nil
        pending?.action()   // the boost/bury/dedicate they came for
    }

    /// The listener backed out of the sheet — drop the pending action.
    func cancelPrompt() { prompt = nil }

    /// Sign out (profile screen). Local only — the Apple credential itself is
    /// revoked from Settings; here we just forget it.
    func signOut() {
        userID = nil
        displayName = nil
        defaults.removeObject(forKey: userKey)
        defaults.removeObject(forKey: nameKey)
    }
}
