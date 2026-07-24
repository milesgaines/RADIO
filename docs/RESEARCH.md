# Live, Fan-Voted Radio for iOS + CarPlay: What's Been Done, What Killed It, and Where the White Space Is

> This is the strategy research that motivates the product in this repo. The
> code is a direct implementation of its recommendations — see
> [`ARCHITECTURE.md`](ARCHITECTURE.md) for the mapping from each finding to the
> module that embodies it.

## TL;DR

- **The single most valuable finding:** the core concept "fans vote on the next track in one shared live stream" has been tried at mass scale exactly once (Jelli, which put crowd-voting on real FM stations 2009–2014) and many times in room-based apps (Turntable.fm, Dubtrack, JQBX, Hangout) — nearly all collapsed from licensing cost, vote-gaming by bots, "dead room" cold-start problems, and retention decay, NOT from lack of demand. The genuine, unclaimed white space is the **combination** of (a) crowd-voted live programming built on (b) an *opt-in independent-artist catalog controlled through OneSync* — which sidesteps the licensing trap that killed the others — delivered (c) as a first-class CarPlay radio experience, which no interactive music app has ever attempted.
- **Licensing reality check:** listener voting does NOT automatically make a stream legally "interactive." In *Arista Records, LLC v. Launch Media, Inc.*, 578 F.3d 148 (2d Cir. 2009), the court held that user influence via ratings is fine as long as listeners can't *predict/select* the specific next song on demand. Real-time "vote the exact next track" mechanics push hard toward interactive, which forfeits the statutory webcasting license. Building on an **opt-in OneSync artist catalog (direct licenses) removes this problem entirely.**
- **CarPlay constraint is decisive:** Apple's CarPlay App Programming Guide prohibits gaming and social-networking features and requires audio apps be "designed primarily to provide audio playback services." Audio apps are restricted to a fixed set of templates (List, Grid, Now Playing, Tab Bar, Alert). The winning design uses the **phone for voting and CarPlay for lean-back listening + a single "boost current track" action** via a Now Playing button or Siri.

## Key findings

1. **Almost every social/live music app died from three causes, not weak demand:** licensing cost (Turntable.fm, Dec 2013), retention collapse / attention burden, and cold-start "dead rooms." Amazon Amp had all three majors, celebrity hosts, and deep pockets and still shut in ~18 months (Oct 2023) — money and licenses alone don't win this category.
2. **Large-scale crowd-voting on one simultaneous stream has real precedent: Jelli** (2009–2014, real FM takeovers, "Rockometer" up/down votes). Documented flaw: a "passionate few" dominated votes and there were no programming controls to balance era/tempo/daypart.
3. **The "voting = interactive" fear is real but navigable — and OneSync makes it moot.** Direct opt-in licenses mean the interactive/non-interactive distinction is irrelevant; royalties route straight back to the artists.
4. **No CarPlay app has ever done live voting or interactivity.** Templates only; gaming/social UI prohibited. The one place interactivity reached CarPlay is private-queue contribution (Apple Music SharePlay, Spotify Jam) — never open public voting.

## The design consequences that shaped this codebase

- **One always-on stream, never a room.** Everyone hears the same second; when live participation is low the station falls back to weighted-algorithmic programming, so it is never a "dead room." → `LiveStreamService`, `WeightedRotationEngine.selectNext` never returns nil while a licensed track exists.
- **Votes are rotation *weight*, not literal next-track selection.** Probabilistic, LAUNCHcast-style, keeps it lean-back-listenable and legally defensible. → `WeightedRotationEngine.weight`.
- **Engineered against the two documented failure modes.** Trust-weighted votes (account age, verification, listening time) beat bots; per-listener decaying vote power stops the "passionate few." → `AntiGaming`, `VoteTally`.
- **A performance-complement guard** (≤4 tracks/artist per window, ≤3 consecutive, repeat gap) keeps the stream balanced regardless of license. → `WeightedRotationEngine.isEligible`.
- **CarPlay is a consumption endpoint** with exactly one interaction — "boost current track" via a Now Playing button / the system Like command / Siri. → `CarPlaySceneDelegate`, `RadioPlayer` (maps `likeCommand` → boost, disables `nextTrackCommand`).

## Caveats

- Several user/traffic figures cited in the full research are third-party estimates, not audited company data.
- The *Arista v. Launch Media* precedent is persuasive but fact-specific; a literal "vote the exact next track" feature has not been litigated. The OneSync direct-license route is the safe path — but each artist's opt-in grant must actually cover interactive/on-demand use.
- Statutory/direct sound-recording licenses cover only the master. Musical-composition rights (PRO performance licenses; mechanical for reproduction/interactive uses) are still required — OneSync's publishing-admin capability should cover these.
- **This is not legal advice.** A music-licensing attorney should paper the OneSync opt-in terms before launch.
