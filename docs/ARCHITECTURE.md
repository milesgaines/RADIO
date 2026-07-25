# Architecture

The app is two thin scene delegates over one shared, testable core. Voting
happens on the phone; the car is a lean-back endpoint that mirrors the same
live stream. Everything that carries product/legal risk lives in `RadioKit` and
is covered by unit tests.

```
┌──────────────────────────────────────────────────────────────┐
│                            RadioPlusApp                          │
│                                                                │
│   AppDelegate ── configurationForConnecting(scene) ──┐         │
│                                                      │         │
│        ┌─────────────────────────┐   ┌───────────────▼──────┐  │
│        │  PhoneSceneDelegate      │   │  CarPlaySceneDelegate │  │
│        │  (SwiftUI: RootView)     │   │  (CPListTemplate +    │  │
│        │  full boost/bury voting  │   │   CPNowPlayingTemplate│  │
│        │  + up-next teaser        │   │   + one Boost button) │  │
│        └───────────┬─────────────┘   └───────────┬──────────┘  │
│                    │        AppServices.shared    │             │
│                    └──────────────┬───────────────┘             │
└───────────────────────────────────┼────────────────────────────┘
                                     │
                 ┌───────────────────▼─────────────────────┐
                 │                RadioKit                   │
                 │                                           │
                 │  LiveStreamService  ◄── the always-on     │
                 │    │  station runtime (one shared stream) │
                 │    ├── WeightedRotationEngine  (what      │
                 │    │     plays next; never nil; complement)│
                 │    ├── VoteTally ── AntiGaming  (trust +   │
                 │    │     per-listener decay)               │
                 │    └── RadioPlayer (AVPlayer + MPNowPlaying│
                 │          + MPRemoteCommand like→boost)     │
                 │                                           │
                 │  Models: Track · Station · Vote · Listener │
                 │  Catalog: MockCatalog (→ swap for OneSync) │
                 └───────────────────────────────────────────┘
```

## Where each research finding lives in code

| Research finding | Module | What it does |
|---|---|---|
| No "dead rooms" — one always-on stream | `LiveStreamService`, `WeightedRotationEngine.selectNext` | The station always programs itself; `selectNext` never returns `nil` while a licensed track exists. |
| Votes = rotation *weight*, not literal selection | `WeightedRotationEngine.weight` | Probabilistic, LAUNCHcast-style; boosts raise weight, buries lower it, nothing is hard-banned. |
| Beat the bots | `AntiGaming.trustWeight` | Weights votes by account age, verification, and real listening time. |
| Beat the "passionate few" (Jelli) | `AntiGaming.decayFactor`, `VoteTally` | Per-listener decaying vote power within a window. |
| Performance-complement balance | `WeightedRotationEngine.isEligible` | ≤4 tracks/artist per 3h window, ≤3 consecutive, repeat gap. |
| Direct-license safety | `Track.interactiveLicenseGranted` | Engine refuses to schedule any master not opted in for interactive use. |
| CarPlay = consumption + one interaction | `CarPlaySceneDelegate`, `RadioPlayer` | Templates only; `likeCommand` → boost; `nextTrackCommand` disabled (no hand-picking). |
| OneSync catalog swap | `MockCatalog` | The only place the demo data lives; replace with the real opt-in feed. |
| Real streaming backend | `NavidromeClient` (`Navidrome.swift`) | Subsonic-API client for a self-hosted Navidrome server: salted-token auth, catalog fetch → `Track`s with stream + artwork URLs. Configured in the app's Settings tab; `AppServices.reloadCatalog()` swaps it into the live rotation. |
| Credentials off plain storage | `SecretStore` (`SecretStore.swift`), `NavidromeConfig` | The Navidrome password lives in the keychain (`KeychainSecretStore`), never `UserDefaults`; server URL + username stay plain preferences. `migrateLegacyPassword()` moves a pre-0.1.0 plain-text password across on launch. `InMemorySecretStore` lets the tests cover it unsigned. |
| Joined-in-progress playback | `RadioPlayer.load` | Seeks each new asset to the stream's elapsed offset so every listener hears the same second. |

## Design invariants (enforced by tests)

- **The station never goes silent** while a licensed track exists (`testNeverReturnsNilWhenSomethingIsLicensed`).
- **A boosted track wins more often** but not always (`testBoostedTrackWinsMoreOften`) — probabilistic, not deterministic.
- **A superfan cannot dominate** (`testVoteTallyDecaysRepeatedBoostsFromOneListener`).
- **Fresh/unverified accounts barely count** (`testFreshAccountVoteIsHeavilyDiscounted`).
- **Unlicensed masters are never scheduled** (`testUnlicensedTrackIsNeverScheduled`).
- **No third consecutive track by one artist** (`testConsecutiveArtistCapEnforced`).
- **The server password never comes from `UserDefaults`** (`testConfigIsNilWhenTheSecretStoreHasNoPassword`, `testSavingAPasswordNeverTouchesUserDefaults`) and a legacy plain-text copy is migrated exactly once (`testLegacyPlainTextPasswordIsMovedIntoTheSecretStore`, `testMigrationIsIdempotent`).

## Swapping the mock for production

1. Replace `MockCatalog` with a client that returns only masters carrying an
   interactive direct license from OneSync (`interactiveLicenseGranted == true`).
2. Replace `LiveStreamService`'s timer-driven `advance()` with a websocket
   client that renders the server's authoritative "current track + start time"
   — the same server runs `WeightedRotationEngine` so every listener is in sync.
3. Point `Track.assetURL` at real HLS stream URLs; `RadioPlayer` already drives
   `AVPlayer` + the Now Playing surfaces.
