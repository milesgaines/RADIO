import Foundation

/// Persists the device's listener identity across launches.
///
/// Anti-gaming trust is *earned* — account age and real listening time — so
/// it only works if the same identity comes back tomorrow. A fresh listener
/// every launch would mean every vote from this device is forever discounted
/// as a newbie's.
public protocol ListenerStore: Sendable {
    func load() -> Listener?
    func save(_ listener: Listener)
}

/// `UserDefaults`-backed store. In production the identity would be anchored
/// to an account server-side; the local copy is a cache of the same shape.
///
/// `@unchecked` because `UserDefaults` predates `Sendable` but is documented
/// thread-safe.
public struct UserDefaultsListenerStore: ListenerStore, @unchecked Sendable {
    private let key = "fm.swell.listener"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> Listener? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Listener.self, from: data)
    }

    public func save(_ listener: Listener) {
        guard let data = try? JSONEncoder().encode(listener) else { return }
        defaults.set(data, forKey: key)
    }
}

public enum ListenerIdentity {
    /// Return the persisted listener, or mint (and persist) a brand-new one.
    /// A new identity starts with zero tenure and earns its way up by
    /// actually listening — no shortcuts. `verifiedByOnboarding` is the one
    /// exception: pass `true` when a real onboarding step (sign-in, human
    /// check) vouched for the account, which grants the verified bonus so a
    /// first-day listener's boost still visibly counts for something.
    public static func loadOrCreate(
        store: ListenerStore,
        verifiedByOnboarding: Bool = false,
        now: () -> Date = { Date() }
    ) -> Listener {
        if let existing = store.load() { return existing }
        let fresh = Listener(
            createdAt: now(),
            isVerified: verifiedByOnboarding,
            lifetimeListeningSeconds: 0
        )
        store.save(fresh)
        return fresh
    }
}

/// Accrues listening tenure while playback runs and persists it, so a
/// listener's vote weight grows with genuine time spent listening.
///
/// Call `playbackStarted()` / `playbackStopped()` from the player, and
/// `flush()` opportunistically (scene background, periodic timer) so a force-
/// quit can't erase a long session.
@MainActor
public final class ListeningMeter {

    public private(set) var listener: Listener

    private let store: ListenerStore
    private let now: () -> Date
    private var playingSince: Date?

    public init(
        listener: Listener,
        store: ListenerStore,
        now: @escaping () -> Date = { Date() }
    ) {
        self.listener = listener
        self.store = store
        self.now = now
    }

    public func playbackStarted() {
        guard playingSince == nil else { return }
        playingSince = now()
    }

    public func playbackStopped() {
        flush()
        playingSince = nil
    }

    /// Bank whatever has accrued so far without interrupting the session.
    /// Returns the up-to-date listener so callers can push it to the tally.
    @discardableResult
    public func flush() -> Listener {
        if let since = playingSince {
            let n = now()
            let accrued = max(0, n.timeIntervalSince(since))
            listener.lifetimeListeningSeconds += accrued
            playingSince = n // restart the meter from here; already banked
            store.save(listener)
        }
        return listener
    }
}
