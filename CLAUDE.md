# CLAUDE.md

Guidance for AI assistants working in this repository.

## What this is

**RADI0** (zero, not O — the zero is a record) — a fan-voted live radio iOS
app with a planned CarPlay surface. One always-on stream, everyone hears the
same second, and listeners shape rotation by *boosting* and *burying* tracks.
Swift 5.9, iOS 17 minimum, UIKit app delegate + SwiftUI. The app target
depends on `supabase-swift` (declared in `project.yml`); `RadioKit` itself has
no third-party dependencies. App Store listing/bundle: "SWELL RADIO" /
`com.onesync.swellradio`.

Background reading, in order of usefulness: `docs/ARCHITECTURE.md` (module map,
the shared-clock design, the finding→code table), `docs/CARPLAY.md` (what Apple
allows in-car and why), `docs/RESEARCH.md` (the strategy the product implements),
`README.md` (user-facing overview).

## Build, test, run

`Package.swift` builds **RadioKit and its unit tests only** — `swift test`
is the fast loop for engine/service logic. The app itself is an Xcode project:
the `.xcodeproj` is gitignored and generated from `project.yml` by [XcodeGen]
(on this Mac, `xcodegen` lives at `~/.local/bin/xcodegen`, not Homebrew).

```bash
swift test                 # RadioKit unit suite, no simulator needed

xcodegen generate          # regenerates Swell.xcodeproj from project.yml
open Swell.xcodeproj       # ⌘R to run, ⌘U to test

xcodebuild test \
  -project Swell.xcodeproj \
  -scheme Swell \
  -destination 'platform=iOS Simulator,name=iPhone 15'
```

TestFlight uploads go through `./ship.sh` (ASC API-key cloud signing).
The `-SwellAutoPlay YES` launch argument autoplays on launch for demos.

Sources are declared as **folders** in `project.yml`, so a new `.swift` file is
picked up by re-running `xcodegen generate` — never hand-edit a `.pbxproj`, and
never commit one.

**Cloud sessions may run on Linux with no Swift toolchain.** If you cannot
compile, reason about Swift changes carefully, keep them small and
type-obvious, and say plainly in your report that the change is unverified
locally — CI (`.github/workflows/ci.yml`, `macos-15`) is what actually builds
and tests it. On the user's Mac, run `swift test` before reporting done.

CI runs two jobs on every PR: the iOS build + `RadioKitTests` on a simulator,
and a Linux job that stands up a real Subsonic server and runs
`tools/local-dev/verify_contract.py` against it.

## Layout

| Path | Role |
|---|---|
| `Sources/RadioKit/` | The framework target — all the logic, fully testable, **no UIKit** (`RadioPlayer` is `#if canImport(AVFoundation)`-guarded). |
| `Sources/RadioKit/Models/` | `Track`, `Station`/`NowPlaying`, `Vote`/`Listener`. Value types, `Codable`, `Sendable`. |
| `Sources/RadioKit/Engine/` | `WeightedRotationEngine` (what plays next), `VoteTally`, `AntiGaming`. Pure, no I/O. |
| `Sources/RadioKit/Services/` | `LiveStreamService`, `FolderCatalog`, `ListenerStore`/`ListeningMeter`, `MockCatalog` — plus the dormant RadioPlus-line services (see note below): `StationSchedule`/`StationClock`, `SupabaseRadioClient`, `NavidromeClient`, `SecretStore`. |
| `Sources/RadioKit/Player/` | `RadioPlayer` — `AVPlayer` + `MPNowPlayingInfoCenter` + remote commands. |
| `Sources/SwellApp/` | The app target: `AppDelegate` scene routing, `AppServices` (the composition root), `RootView` (THE PLATE cymatics UI), `HumanLayer`, `RadioBackend` (Supabase realtime: presence, votes, shared clock), `Shaders.metal`, `CarPlaySceneDelegate`, `Info.plist`, entitlements. |
| `Tests/RadioKitTests/` | Unit tests. They pin the design invariants — treat a failure as a product regression, not a flaky test. |
| `tools/local-dev/` | Local Subsonic server + the Swift-client contract verifier. |

## The central seam: who decides what plays

The principle both lines share: **the client renders the station; the server
decides rotation.** The OneSync Supabase backend runs
`radio_advance_stations()` (vote-weighted pick, gapless schedule) on pg_cron
and publishes `radio_now_playing`; everyone hears the same second. Local
rotation (`WeightedRotationEngine`) is the offline fallback only.

**In the active Swell app**, that seam is `RadioBackend`
(`Sources/SwellApp/RadioBackend.swift`, using `supabase-swift` realtime for
presence, votes, and now-playing) feeding `LiveStreamService.applyRemoteClock`.

**The dormant RadioPlus line** (kept in `RadioKit`, compiled but not wired
into the app) models the same seam as a `StationScheduleSource` protocol
(`Services/StationSchedule.swift`) handing back `ScheduleSlot`s in *station
time*. Its three implementations:

- **`SupabaseScheduleSource`** — that line's default. The OneSync backend runs
  `radio_advance_stations()` server-side and publishes `radio_now_playing`; the
  client polls (roughly one request per song, sleeping until just past the
  slot's end), disciplines its clock off each response's `Date` header, and uses
  a stateless `SupabaseRealtime` websocket purely as a "re-read now" nudge.
  Votes POST to `radio_votes`.
- **`LocalScheduleSource`** — runs `WeightedRotationEngine` on-device. Offline,
  demo, and personal-Navidrome listening. The only source with
  `supportsLocalPreview == true`.
- **`RemoteScheduleSource`** — generic websocket feed for self-hosters. Wire
  format is documented in the doc comment on the type; keep that comment and the
  `Envelope` decoder in sync.

`StationClock` converts between station time and device time. Schedules arrive
in station time; `NowPlaying.startedAt` is published in device time because
that's what `AVPlayer` seeks and Now Playing elapsed times are quoted against.
An unsynced clock is the identity map, deliberately — nothing special-cases
"not synced yet".

(The RadioPlus line's `-RadioBackend`/`-StationFeedURL` launch arguments died
with its app target; the Swell app's launch argument is `-SwellAutoPlay YES`.)

## Invariants you must not break

These are product/legal constraints, not preferences. Each is covered by a test
(see the list in `docs/ARCHITECTURE.md`).

- **Never dead air.** `selectNext` returns `nil` only when no licensed track
  exists at all; when the complement rules exclude everything it relaxes rather
  than going silent.
- **Votes are rotation *weight*, never literal next-track selection.** No API
  should ever let a listener pick the next song, and nothing should present the
  preview as "the next song" — it's a teaser. This is the
  *Arista v. Launch Media* predictability line.
- **`interactiveLicenseGranted == false` is never scheduled.** Weight is 0, full
  stop.
- **Anti-gaming stays on.** Trust weighting (account age, verification,
  listening time) beats bots; per-listener decay stops the "passionate few".
- **Performance complement.** ≤4 tracks/artist per 3h window, no third
  consecutive track by one artist, repeat gap.
- **CarPlay is lean-back plus exactly one action.** Templates only (List, Grid,
  Now Playing, Tab Bar, Alert). No voting grid, chat, leaderboards, or text
  content in-car. `nextTrackCommand`/`previousTrackCommand` stay disabled.
  Richer voting lives on the phone. Read `docs/CARPLAY.md` before touching
  `CarPlaySceneDelegate` or `RadioPlayer.configureRemoteCommands()`.
- **A shared station shows no up-next teaser** (`supportsLocalPreview == false`)
  — the client genuinely doesn't know, which is the point.

## Conventions

- **Injected clock and RNG.** Anything time- or randomness-dependent takes
  `now: () -> Date` and `random: () -> Double` with production defaults, so
  tests are deterministic. Do not call `Date()` or `Double.random` inline in
  `RadioKit`.
- **Concurrency.** Stateful services are `@MainActor final class`; models and
  clients are `Sendable` value types. `LiveStreamService`, `RadioPlayer`, and
  the schedule sources are `ObservableObject`.
- **Public API surface.** `RadioKit` is a framework target — anything the app or
  tests touch needs `public`. Tests use `@testable import RadioKit`, so
  internal-only helpers are fine when nothing in `Sources/SwellApp` needs
  them.
- **Comments explain *why*, at length.** This codebase carries unusually rich
  doc comments that tie code to the research and legal constraints. Match that:
  when you add a rule, say what failure mode it prevents. Don't strip existing
  rationale.
- **`AppServices.shared` is the single composition root.** The phone scene and
  the CarPlay scene share one `LiveStreamService`, so a boost from the car lands
  in the same tally as a tap on the phone. Don't construct a second stream.
- **Catalog swaps are non-destructive.** The on-air track must stay resolvable
  after `updateCatalog` so the current song can finish.

## Secrets

- The Navidrome **password lives in the keychain** via `SecretStore`
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), never `UserDefaults`.
  Server URL and username are ordinary preferences.
  `NavidromeConfig.migrateLegacyPassword()` moves a pre-0.1.0 plain-text copy
  across once, on launch. Tests use `InMemorySecretStore` because unit-test
  bundles run unsigned in CI.
- The **Supabase publishable ("anon") key in `SupabaseRadioClient.Config.oneSync`
  is public by design** — RLS allows only public reads and an anonymous vote
  insert. It is meant to be in the source. Do not "fix" it into an env var, and
  do not add any other credential to source.
- `.gitignore` already excludes `*.p12`, `*.mobileprovision`, `secrets.xcconfig`.

## Testing

- `XCTest`, all against `RadioKit`. No network, no real keychain, no
  simulator UI tests. Run with `swift test` (66 tests as of this merge).
- HTTP is stubbed with `StubURLProtocol` (in `SupabaseRadioTests.swift`) plumbed
  through an ephemeral `URLSession`; set `StubURLProtocol.handler` per test and
  clear it in `tearDown`.
- `UserDefaults` tests use a named suite (`com.radioplus.tests.navidrome`) wiped
  in `setUp`/`tearDown` — never touch `.standard`.
- Test names read as the invariant they defend
  (`testUnlicensedTrackIsNeverScheduled`, `testSkewedDeviceClockDoesNotShiftThePlayhead`).
  Keep that style, and add a test for any new invariant.

## Local dev loop

`./tools/local-dev/serve.sh` spins up supysonic on `127.0.0.1:4747` with a
generated 10-track library and runs `verify_contract.py`, which pins every JSON
field and auth step `NavidromeClient` depends on against an independent Subsonic
implementation. If you change `Navidrome.swift`'s wire model, update
`verify_contract.py` in the same commit.

Caveat: supysonic implements Subsonic API 1.12, which predates the salted-token
auth (`t = md5(password + salt)`, ≥1.13) the app uses — great for contract
checks, not for app login. For the full app loop run real Navidrome locally.

## Git workflow

Default branch is `main`; work on a feature branch and push with
`git push -u origin <branch>`. CI must be green before merge. Don't open a PR
unless asked.

[XcodeGen]: https://github.com/yonaskolb/XcodeGen
