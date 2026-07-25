# Architecture

The app is two thin scene delegates over one shared, testable core. Voting
happens on the phone; the car is a lean-back endpoint that mirrors the same
live stream. Everything that carries product/legal risk lives in `RadioKit` and
is covered by unit tests.

```
┌──────────────────────────────────────────────────────────────┐
│                            SwellApp                          │
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
| OneSync catalog swap | `MockCatalog` | The only place the data source lives; replace with the real opt-in feed. |
| Stations feel alive from second one | `CrowdSimulator` | Synthetic listeners tune in/out on a daypart wave and vote through the same `join`/`leave`/`castVote` API the production websocket will use. Deleted at production swap. |
| Trust is earned, and it persists | `ListenerStore`, `ListeningMeter` | One identity per device across launches; listening tenure accrues while playback runs and is banked to disk, so `AntiGaming` trust grows with real use. |
| More than one room to walk into | `MockCatalog.stations`, `AppServices.tune(to:)` | Always-on stations over subset catalogs; tuning re-points the shared player, both phone and CarPlay follow. |
| Real masters play today | `FolderCatalog`, `RealAudio/` | A local folder of licensed audio becomes the station catalog (tags → filename `Artist - Title` → de-slug fallback; album subfolders become album stations). Contents never enter git. |
| Radio joins live, resumes live | `RadioPlayer.seekToLiveEdge` | Tune in mid-track, start mid-track; resume after pause rejoins the live second — never "where you left off". |
| Small catalogs don't starve | `Config.adaptive(to:)`, LRP fallback | Repeat-gap/window scale to catalog length; single-artist catalogs relax the complement so votes keep mattering; the dead-air fallback plays least-recently-played, never a one-track loop. |

## Design invariants (enforced by tests)

- **The station never goes silent** while a licensed track exists (`testNeverReturnsNilWhenSomethingIsLicensed`).
- **A boosted track wins more often** but not always (`testBoostedTrackWinsMoreOften`) — probabilistic, not deterministic.
- **A superfan cannot dominate** (`testVoteTallyDecaysRepeatedBoostsFromOneListener`).
- **Fresh/unverified accounts barely count** (`testFreshAccountVoteIsHeavilyDiscounted`).
- **Unlicensed masters are never scheduled** (`testUnlicensedTrackIsNeverScheduled`).
- **No third consecutive track by one artist** (`testConsecutiveArtistCapEnforced`).
- **Votes from listeners who never tuned in are dropped** (`testVoteFromUnknownListenerIsDropped`).
- **The simulated crowd is deterministic under a seed** (`testSimulationReplaysIdenticallyUnderSameSeed`) — demos replay, tests don't flake.
- **Station catalogs only contain opted-in artists** (`testStationCatalogsOnlyContainOptedInArtists`).
- **Identity survives relaunch and tenure never double-counts** (`testLoadOrCreateReturnsTheSameIdentityNextLaunch`, `testListeningMeterFlushBanksMidSessionAndPersists`).

## Swapping the mock for production

> **Status: the swap happened.** As of 2026-07-25 the production
> architecture below is live: the station director runs in Supabase
> (`radio_advance_stations()` on a 7-second pg_cron heartbeat, writing
> `radio_now_playing`), clients render the server clock and seek to the
> live edge, presence and votes stream over Realtime, and the local
> engine remains only as the offline fallback so the station never dies.

1. Replace `MockCatalog` with a client that returns only masters carrying an
   interactive direct license from OneSync (`interactiveLicenseGranted == true`).
2. Replace `LiveStreamService`'s timer-driven `advance()` with a websocket
   client that renders the server's authoritative "current track + start time"
   — the same server runs `WeightedRotationEngine` so every listener is in sync.
3. Point `Track.assetURL` at real HLS stream URLs; `RadioPlayer` already drives
   `AVPlayer` + the Now Playing surfaces.
4. Delete `CrowdSimulator`. Real presence and votes arrive over the websocket
   and land on the same `LiveStreamService.join`/`leave`/`castVote` calls the
   simulator uses today — nothing downstream changes.
5. Anchor the persisted `Listener` identity to a server account;
   `UserDefaultsListenerStore` becomes a cache of the same shape.
