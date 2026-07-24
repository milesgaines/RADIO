# Swell — fan-voted live radio for iOS + CarPlay

The first fan-programmed radio station that lives in your car. One always-on
stream, everyone hears the same second, and the crowd shapes what plays next by
**boosting** and **burying** tracks — built on an opt-in independent-artist
catalog (OneSync) so the voting can be as interactive as we like without
tripping the licensing wire that killed everyone who tried this before.

- **Phone** — the full voting experience (boost/bury, up-next teaser, live
  listener count).
- **CarPlay** — lean-back listening plus a single "Boost current track" action
  (button or Siri). No voting grid in the car, by Apple's rules and by design.

> Why this exists — and why the last decade of social-music apps died — is in
> [`docs/RESEARCH.md`](docs/RESEARCH.md). How the findings map to code is in
> [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). CarPlay constraints are in
> [`docs/CARPLAY.md`](docs/CARPLAY.md).

## What's in the box

| Path | Role |
|---|---|
| `Sources/RadioKit/` | The testable core: models, the vote-weighted rotation engine, anti-gaming, the live-stream runtime, the crowd simulator, listener persistence, and the `AVPlayer`/Now Playing bridge. **No UIKit dependency in the logic.** |
| `Sources/SwellApp/` | The iOS app: `AppDelegate` scene routing, `PhoneSceneDelegate` (SwiftUI), `CarPlaySceneDelegate` (templates), `RootView` with the station dial. |
| `Tests/RadioKitTests/` | Unit tests pinning the design invariants (no dead air, boost-wins-more, superfans can't dominate, unlicensed never plays, identity survives relaunch…). |
| `project.yml` | XcodeGen spec — the `.xcodeproj` is generated, not committed. |
| `Package.swift` | SwiftPM manifest for `RadioKit` only, so `swift test` runs the core suite headlessly (CI, no simulator). |
| `docs/` | Research, architecture, CarPlay design. |

## Build & run

Requires macOS + Xcode 15+ (iOS 17 target). The project file is generated with
[XcodeGen](https://github.com/yonaskolb/XcodeGen) so it stays a reviewable
plain-text spec:

```bash
brew install xcodegen        # once (or build from source: clone XcodeGen, `swift build -c release`)
git clone https://github.com/milesgaines/RADIO.git && cd RADIO
xcodegen generate            # produces Swell.xcodeproj
open Swell.xcodeproj         # ⌘R to run on an iPhone simulator
```

The core logic tests need no simulator at all:

```bash
swift test
```

Or run them through Xcode with `⌘U`, or from the command line:

```bash
xcodebuild test \
  -project Swell.xcodeproj \
  -scheme Swell \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

### Trying CarPlay

You don't need the CarPlay entitlement approved to develop: launch the app in
the iOS Simulator, then **Simulator ▸ I/O ▸ External Displays ▸ CarPlay**. The
station list and Now Playing "Boost" button render against the same live stream
as the phone. See [`docs/CARPLAY.md`](docs/CARPLAY.md).

## Status

This is a working MVP **demo with real audio**: the rotation/voting/
anti-gaming logic is real and tested, always-on stations run side by side with
a **simulated live crowd** (synthetic listeners tune in and out and vote, so
the tallies, teaser, and listener counts move like the real thing), and the
device's listener identity **persists across launches** — trust accrues with
genuine listening time.

Audio comes from the local **`RealAudio/`** folder (gitignored; see
[`RealAudio/README.md`](RealAudio/README.md)): drop licensed masters in and
`FolderCatalog` turns them into stations — the full catalog, one station per
album subfolder, and the loose singles. With no local audio the app falls back
to the silent three-station `MockCatalog` demo. The stream clock is still
simulated in-app (a timer advances tracks). The production swaps — a websocket
stream client and the real OneSync opt-in catalog feed — are isolated to
`LiveStreamService` and the catalog source (`FolderCatalog`/`MockCatalog`);
the `CrowdSimulator` is simply deleted (real presence and votes use the same
API). See "Swapping the mock for production" in
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## License / legal

The rotation model is deliberately probabilistic (votes shape *weight*, never
pick the literal next song) and enforces a performance-complement guard, so the
design stays defensible even before the OneSync direct licenses are papered.
That said — **this repo is not legal advice.** Have a music-licensing attorney
paper the OneSync opt-in terms (master **and** composition rights) before launch.
