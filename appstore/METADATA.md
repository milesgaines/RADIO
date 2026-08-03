# RADI0 — App Store submission pack

Everything App Store Connect asks for, ready to paste. ASC record: "SWELL
RADIO", Apple ID 6794523437, bundle `com.onesync.swellradio`, version 1.0
sitting in **Prepare for Submission**. Rename the listing to **RADI0** in App
Information → Name (names are unique storewide; if "RADI0" is taken, fall
back to "RADI0 — Live Radio").

## App Information

| Field | Value |
|---|---|
| Name | `RADI0` |
| Subtitle | `Fan-voted live radio` |
| Category | Music (primary), Entertainment (secondary) |
| Content rights | Contains only content you own or have licensed |
| Age rating | 12+ (infrequent/mild profanity possible in user shows; no other flags) |

## URLs

| Field | Value |
|---|---|
| Privacy Policy URL | `https://milesgaines.github.io/RADIO/privacy.html` |
| Support URL | `https://milesgaines.github.io/RADIO/support.html` |
| Marketing URL (optional) | `https://milesgaines.github.io/RADIO/` |

(Swap to the real domain when it exists — the pages are the same files.)

## Promotional Text (170 chars max — editable without review)

> One station, one second, everyone together. Boost what deserves to run,
> bury what doesn't. Live hosts on camera. This is radio with the crowd in
> the chair.

## Description

> RADI0 is live radio, not a playlist. Every station runs on one shared
> clock — everyone tuned in hears the same second, and nobody can skip.
> What plays next is decided by the room: boost a record and it climbs the
> rotation, bury it and it fades. Real votes, one person each, no bots.
>
> THE DIAL — Four stations, each with its own sound: the 24/7 flagship,
> the deep-crate vault, the underground, the wave.
>
> LIVE — Hosts take the air from their phone, camera or mic. When a show
> starts, every radio on the station flips to it. When it ends, the show
> tapes itself into the archive, full length.
>
> THE RING — Song battles. Two records, the crowd votes, the winner enters
> rotation.
>
> THE LINE — Call the station. Hold to talk; the host can put you on air
> between records.
>
> SOUND — HD, real binaural 3D, vinyl with true surface noise, cassette
> with honest flutter. Pick how your radio sounds.
>
> SLEEP — A bedside clock over a low ember, with an off-air timer.
>
> Listening is free and needs no account. Sign in with Apple only when you
> want to vote — one Apple ID, one voice.

## Keywords (100 chars max)

`radio,live radio,music,vote,hip hop,dj,live stream,station,broadcast,crowd,premiere,underground`

## What's New (1.0)

> RADI0 signs on: four stations on one shared clock, crowd-run rotation,
> live host shows with camera, self-taping replays, song battles, call-ins,
> and a sound deck from HD to cassette.

## App Privacy (the nutrition label — answer in ASC exactly like this)

Data collected, all **linked to identity only via the Apple sign-in**, none
used for tracking, no third-party advertising:

| ASC data type | What it is | Purpose |
|---|---|---|
| Identifiers → User ID | Random listener UUID; Apple user ID after sign-in | App functionality (vote integrity, listener counts) |
| User Content → Audio Data | Mic audio ONLY during call-ins / hosting; camera ONLY during camera broadcasts | App functionality (the feature itself) |
| Usage Data → Product Interaction | Votes (boost/bury), plays witnessed | App functionality (crowd rotation, THE READ) |
| Contact Info → Email | Only if the user shares it at Apple sign-in; used for staff-role verification | App functionality |

“Data not collected”: location, browsing history, purchases, financial info,
contacts, photos, health, or anything for tracking/ads.

## App Review notes (paste into the Review Notes box)

> RADI0 is a live-radio app. Listening requires no account — launch and tap
> TUNE IN. Sign in with Apple is only prompted when the reviewer votes
> (boost/bury). Host/broadcast features (GO LIVE, PD DESK, THE BOARD) are
> operator-gated by a station key and are NOT accessible to reviewers; the
> app is fully reviewable without them. All music is owned or licensed by
> the operator (OneSync Media LLC): station catalogs are the operator's own
> masters plus openly licensed tracks streamed via the Audius public API.
> Microphone is used only in the call-in and host-broadcast features;
> camera only in host camera broadcasts — both behind explicit user action
> and permission prompts.

## Submission checklist (the order that works)

1. ASC → My Apps → SWELL RADIO → App Information: set Name to RADI0,
   category Music, age rating questionnaire (12+).
2. App Privacy: enter the table above, publish.
3. Version 1.0 page: paste description/keywords/promo text; upload the six
   screenshots from `appstore/screenshots/` (6.9-inch slot — they are exact
   1320×2868); set Privacy/Support URLs.
4. Build: select the latest VALID TestFlight build.
5. Review notes: paste the block above. Export compliance: uses standard
   HTTPS only → "No" to proprietary crypto.
6. Submit. Typical first review: 24–48h.

## Screenshots in this folder (upload order)

1. `ui_02_fixed.png` — the room: PWR sign, deck, four-key bar
2. `radio_switched.png` — THE VAULT: the dial changes the whole room
3. `night_02_sleep.png` — SLEEP: bedside clock + timer
4. `shows_02.png` — SHOWS: on-air state + the archive
5. `radio_sounddeck.png` — SOUND: HD / 3D / vinyl / cassette
6. `ui_03_backstage.png` — BACKSTAGE: every door, named
