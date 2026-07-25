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
                 │  LiveStreamService  ◄── renders whatever   │
                 │    │  is on air (one shared stream)        │
                 │    ├── StationScheduleSource ── what plays │
                 │    │    ├── SupabaseScheduleSource (the    │
                 │    │    │     live OneSync station: poll + │
                 │    │    │     realtime nudge + REST votes) │
                 │    │    ├── LocalScheduleSource  (engine   │
                 │    │    │     on-device: offline/demo)     │
                 │    │    └── RemoteScheduleSource (generic  │
                 │    │          self-host websocket feed)    │
                 │    │         └── StationClock (skew)       │
                 │    ├── WeightedRotationEngine  (what       │
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

## The shared clock

"Everyone hears the same second" is a claim about a timeline, so the timeline
is the thing that got factored out. `LiveStreamService` no longer decides what
plays — it renders whatever `StationScheduleSource` says is on air:

- **`ScheduleSlot`** — a track id, the instant it started, and its duration,
  all in *station time*. Enough to join a stream in progress; deliberately not
  enough to tell anyone what's coming next.
- **`LocalScheduleSource`** — runs `WeightedRotationEngine` on-device. A real
  station (contiguous slots, catch-up after the screen was off), but this
  listener's own copy of it. The offline and demo path.
- **`RemoteScheduleSource`** — a websocket client for the server timeline. The
  server runs the same engine, tallies every listener's votes, and pushes
  "current track + start time"; this class holds the latest push and nothing
  else.
- **`StationClock`** — the conversion between the two clocks. Phones drift and
  users set the time by hand, so the server stamps each message and the client
  estimates the offset from the round trip (`offset = stationTime - receivedAt
  + roundTrip / 2`), keeping the lowest-latency sample in a sliding window
  because a slow reply is exactly the one whose symmetry assumption is worst.
  Schedules arrive in station time; `NowPlaying.startedAt` is published in
  device time, which is what `AVPlayer` seeks against.

The wire format is documented on `RemoteScheduleSource` — JSON text frames,
timestamps as epoch seconds, `trackId` resolved against the catalog the client
already fetched. Set a feed URL to switch a build over:

```
-StationFeedURL wss://live.example.com/station
```

## The live station (Supabase)

The production timeline is the OneSync backend, and it runs today. Server
side, `radio_advance_stations()` executes the rotation for every station and
maintains one row per station in `radio_now_playing` (`track_id`,
`started_at`, `duration_seconds` — a `ScheduleSlot`, verbatim). The client
side is two small types:

- **`SupabaseRadioClient`** — the REST contract: read `radio_now_playing`
  (each response's `Date` header doubles as a `StationClock` sample, so every
  poll re-disciplines the clock), read the catalog via
  `radio_station_tracks` → `radio_tracks`, and POST votes to `radio_votes`
  (anonymous inserts allowed under RLS with a `listener_key`; a per-install
  UUID). The anon key ships in the client by design — public reads and vote
  inserts are all it can do.
- **`SupabaseScheduleSource`** — polling is the source of truth (one request
  per song: it sleeps until just past the current slot's end), and a
  deliberately *stateless* `SupabaseRealtime` subscription is the accelerant:
  any `postgres_changes` frame just means "re-read now". A payload-shape
  change can silence the accelerant but can never corrupt what plays.

Because votes are tallied server-side, the app shows no local "up next"
teaser on the shared station (`supportsLocalPreview == false`) — the client
genuinely doesn't know what's next, which is exactly the non-interactive
property the licensing design wants.

Listener counts ride the same poll. Each poll upserts a heartbeat into
`radio_listeners` (`(station_id, listener_key)` primary key; `last_seen` is
stamped server-side by trigger, so a wrong device clock can't fake
freshness) and reads back the count of heartbeats in the trailing 75-second
window — via `Prefer: count=exact` + `Range: 0-0`, so the answer is a
`Content-Range` header and the payload stays one row at any audience size.
The window is a couple of poll intervals wide, so a live listener never
flickers out between beats, and the cutoff is quoted in *station* time
because that's the clock that stamped the rows.

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
| One shared timeline | `StationScheduleSource`, `ScheduleSlot` | Splits "what plays" from "render what's playing"; `LiveStreamService` keeps no rotation state, so the server swap is a different object behind one protocol. |
| Same second on every device | `StationClock` | Round-trip offset estimate against the server's clock, so a phone whose own clock is a minute off still joins the track at the right second. |

## Design invariants (enforced by tests)

- **The station never goes silent** while a licensed track exists (`testNeverReturnsNilWhenSomethingIsLicensed`).
- **A boosted track wins more often** but not always (`testBoostedTrackWinsMoreOften`) — probabilistic, not deterministic.
- **A superfan cannot dominate** (`testVoteTallyDecaysRepeatedBoostsFromOneListener`).
- **Fresh/unverified accounts barely count** (`testFreshAccountVoteIsHeavilyDiscounted`).
- **Unlicensed masters are never scheduled** (`testUnlicensedTrackIsNeverScheduled`).
- **No third consecutive track by one artist** (`testConsecutiveArtistCapEnforced`).
- **The timeline has no gaps or overlaps** — each slot starts exactly where the last ended (`testTimelineIsContiguous`), and a listener who was away rejoins where the station *is* rather than replaying the backlog (`testTuningBackInLandsOnTheCurrentSlotNotTheBacklog`).
- **A skewed device clock doesn't move the playhead** (`testSkewedDeviceClockDoesNotShiftThePlayhead`), and a listener tuning in mid-track lands on the right second (`testJoinsATrackAlreadyInProgress`).
- **A slow round trip never displaces a better clock sample** (`testSlowRoundTripDoesNotDisplaceABetterSample`) but a stale one always gets replaced (`testStaleSampleIsReplacedEvenByASlowerOne`).
- **The server password never comes from `UserDefaults`** (`testConfigIsNilWhenTheSecretStoreHasNoPassword`, `testSavingAPasswordNeverTouchesUserDefaults`) and a legacy plain-text copy is migrated exactly once (`testLegacyPlainTextPasswordIsMovedIntoTheSecretStore`, `testMigrationIsIdempotent`).

## Swapping the mock for production

1. Replace `MockCatalog` with a client that returns only masters carrying an
   interactive direct license from OneSync (`interactiveLicenseGranted == true`).
2. Stand up the schedule feed and hand the app its URL. The client half is
   done — `RemoteScheduleSource` speaks the format documented on the type, and
   `LiveStreamService` already renders a timeline it doesn't own. The server
   runs the same `WeightedRotationEngine` over every listener's votes and
   pushes "current track + start time" stamped with its own clock.
3. Point `Track.assetURL` at real HLS stream URLs; `RadioPlayer` already drives
   `AVPlayer` + the Now Playing surfaces.
