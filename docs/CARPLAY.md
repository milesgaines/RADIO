# CarPlay design notes

CarPlay is the differentiator no interactive music app has attempted — and also
the most constrained surface in the product. This file records what Apple
allows, what it forbids, and the exact choices this app makes as a result.

## What Apple forbids (and we obey)

From the CarPlay App Programming Guide:

- **"Gaming and social networking features are prohibited."** → No voting grid,
  no chat, no leaderboards, no listener list in the car.
- **"Displaying message, text, or email content on the CarPlay screen is not
  permitted."** → No comment feeds in-dash.
- Audio apps **"must be designed primarily to provide audio playback
  services"** and every flow must be **"meaningful to use while driving."**
- Audio apps may use **only** the standard templates: **List, Grid, Now
  Playing, Tab Bar, Alert.** Pushing an unsupported template crashes at runtime.

## What this app does in-car

| Surface | Template | Purpose |
|---|---|---|
| Root | `CPListTemplate` | The station list (one station today; room for genre/mood/city later). |
| Playback | `CPNowPlayingTemplate` (system) | Metadata, artwork, transport — the standard lean-back radio screen. |
| The one interaction | `CPNowPlayingImageButton` "Boost" + system `likeCommand` | Boost the current track. Reachable by tap or by Siri ("I like this"). |

`nextTrackCommand` and `previousTrackCommand` are **disabled** on purpose: this
is radio, not on-demand. Letting a driver hand-pick the next song would both be
the wrong lean-back UX and push the stream toward "interactive" under the
statutory license. Boost is the only lever, and it shapes *rotation weight*, not
the literal next track.

All richer voting (boost **and** bury, up-next teaser, per-artist actions) lives
on the **phone**, where Apple permits it — see `RootView`.

## Entitlement & running it

- The app declares `com.apple.developer.carplay-audio`
  (`Swell.entitlements`). This is a **managed entitlement**: Apple grants
  it on request via the CarPlay entitlement request form. Until granted, the
  CarPlay scene will not appear on real hardware.
- For development you do **not** need the entitlement approved: use Xcode's
  **CarPlay Simulator** (Simulator ▸ I/O ▸ External Displays ▸ CarPlay), which
  renders the `CPTemplateApplicationScene` against the running app.

## Precedent worth tracking

Apple Music SharePlay and Spotify Jam allow *private-queue* contribution via
CarPlay — the only interactivity Apple has ever shipped in-car. That is the
current ceiling. "Boost the current track" sits comfortably under it; open
public voting in-dash does not, which is why voting stays on the phone.

## If Apple rejects even the Boost button

Fallback documented in the research: **drop to pure lean-back radio in-car and
keep all voting on the phone.** Do not jeopardize the CarPlay audio entitlement
over one button. The `CarPlaySceneDelegate` is structured so removing the button
is a one-line change (`updateNowPlayingButtons([])`).
