# RADIO+ — fan-voted live radio for iOS + CarPlay

**RADIO+™** — the first fan-programmed radio station that lives in your car.
One always-on stream, everyone hears the same second, and the crowd shapes what
plays next by **boosting** and **burying** tracks — built on an opt-in
independent-artist catalog so the voting can be as interactive as we like
without tripping the licensing wire that killed everyone who tried this before.

- **Phone** — the full experience: animated live stage, boost/bury with
  haptics, up-next teaser, live listener count.
- **CarPlay** — lean-back listening plus a single "Boost current track" action
  (button or Siri). No voting grid in the car, by Apple's rules and by design.
- **Your music server** — connect a self-hosted
  [Navidrome](https://www.navidrome.org) library in Settings and the station
  streams *your* catalog (Subsonic API, salted-token auth, artwork included).

> Why this exists — and why the last decade of social-music apps died — is in
> [`docs/RESEARCH.md`](docs/RESEARCH.md). How the findings map to code is in
> [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). CarPlay constraints are in
> [`docs/CARPLAY.md`](docs/CARPLAY.md).

## Proudly open-source

The source is right here — read it, review it, contribute to it however you
want. The app's **Open Source** tab shows live stars + contributors for this
repo, straight from the GitHub API.

## What's in the box

| Path | Role |
|---|---|
| `Sources/RadioKit/` | The testable core: models, the vote-weighted rotation engine, anti-gaming, the live-stream runtime, the station schedule + shared clock, the Navidrome/Subsonic client, and the `AVPlayer`/Now Playing bridge. **No UIKit dependency in the logic.** |
| `Sources/RadioPlusApp/` | The iOS app: scene routing, `LiveView` (the stage), `OpenSourceView`, `SettingsView` (Navidrome), `CarPlaySceneDelegate` (templates). |
| `Tests/RadioKitTests/` | Unit tests pinning the design invariants (no dead air, boost-wins-more, superfans can't dominate, unlicensed never plays…). |
| `project.yml` | XcodeGen spec — the `.xcodeproj` is generated, not committed. |
| `docs/` | Research, architecture, CarPlay design. |

## Build & run

Requires macOS + Xcode 15+ (iOS 17 target). The project file is generated with
[XcodeGen](https://github.com/yonsm/XcodeGen) so it stays a reviewable plain-text
spec:

```bash
brew install xcodegen        # once
git clone https://github.com/milesgaines/RADIO.git && cd RADIO
xcodegen generate            # produces RadioPlus.xcodeproj
open RadioPlus.xcodeproj     # ⌘R to run on an iPhone simulator
```

Then run the tests with `⌘U`, or from the command line:

```bash
xcodebuild test \
  -project RadioPlus.xcodeproj \
  -scheme RadioPlus \
  -destination 'platform=iOS Simulator,name=iPhone 15'
```

### Streaming your own catalog (Navidrome)

1. Self-host [Navidrome](https://www.navidrome.org/docs/installation/) — a
   single binary or Docker container pointed at your music folder.
2. In RADIO+ ▸ **Settings**, enter the server URL, username, and password, then
   **Test & connect**.
3. The live station swaps its rotation to your library — stream URLs, artwork,
   the lot. Votes and anti-gaming work exactly the same.

Auth uses the Subsonic salted-token scheme (`t = md5(password + salt)`), so the
password never goes over the wire. On the device it's held in the **keychain**
(`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so the station can refresh
its catalog on a locked phone but the credential never lands in a backup) and
is only written once a server has accepted it. The server URL and username are
ordinary `UserDefaults` preferences. A password left in `UserDefaults` by an
earlier build is migrated into the keychain on first launch and the plain-text
copy deleted.

### Trying CarPlay

You don't need the CarPlay entitlement approved to develop: launch the app in
the iOS Simulator, then **Simulator ▸ I/O ▸ External Displays ▸ CarPlay**. The
station list and Now Playing "Boost" button render against the same live stream
as the phone. See [`docs/CARPLAY.md`](docs/CARPLAY.md).

## Status

The rotation/voting/anti-gaming logic is real and tested, the player can
stream a real Navidrome library — and **the shared clock is live**.

`LiveStreamService` no longer decides what plays: it renders a timeline handed
to it by a `StationScheduleSource`, and `StationClock` converts the station's
clock to this device's so a phone that's a minute fast still joins the track
at the right second. Three sources ship:

- **`SupabaseScheduleSource`** — *the default.* Tunes to the live OneSync
  station: the backend's `radio_advance_stations()` rotates every station
  server-side and publishes `radio_now_playing`; the app polls it (about one
  request per song), disciplines its clock off each response's `Date` header,
  and rides a Supabase Realtime nudge for instant track changes. Votes POST to
  `radio_votes`. Every listener hears the same second.
- **`LocalScheduleSource`** — the rotation engine on-device: offline, demo,
  and Navidrome listening (each listener their own copy of the station).
- **`RemoteScheduleSource`** — a generic websocket schedule feed for
  self-hosters, wire format documented on the type
  (`-StationFeedURL wss://…`).

Launch arguments: `-RadioBackend local` forces on-device rotation,
`-RadioStationID <uuid>` picks a specific live station. Most of the live
catalog streams (47 of 58 tracks carry an `audio_url` — Supabase storage and
Audius); a track without one plays as synced metadata until the backend fills
it in. The listener count is live too: each device heartbeats
`radio_listeners` once a poll and shows the count of beats in the trailing
window. See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Trademark / legal

**RADIO+** is a trademark of its owner. The rotation model is deliberately
probabilistic (votes shape *weight*, never pick the literal next song) and
enforces a performance-complement guard, so the design stays defensible even
before direct licenses are papered. That said — **this repo is not legal
advice.** Have a music-licensing attorney paper the catalog opt-in terms
(master **and** composition rights) before launch.
