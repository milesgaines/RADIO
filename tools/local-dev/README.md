# Local dev loop

Run the whole RADIO+ stack on your desk, no external services.

## 1. Local music server

```bash
./tools/local-dev/serve.sh
```

Spins up a Subsonic-API server on `http://127.0.0.1:4747` with a generated,
tagged 10-track demo library (5 artists / 5 albums), then runs
`verify_contract.py` — a checker that pins **every JSON field and auth step
`NavidromeClient` (RadioKit) depends on** against this real, independent
server implementation. All green means the Swift client's wire model is
correct.

- User: `radioplus` / password: `radio-dev-pass`
- Library: `~/radio-music` (regenerate by deleting the folder)

## 2. The app against a local server

The bundled server (supysonic) implements Subsonic API **1.12**, which
predates the salted-token auth (`t = md5(password+salt)`, API ≥ 1.13) the app
uses — great for contract checks, not for app login. For the full app loop,
run real Navidrome locally:

```bash
brew install navidrome
navidrome --musicfolder ~/radio-music
```

Then in RADIO+ ▸ Settings enter `http://<your-mac-ip>:4533` (simulator can use
`http://127.0.0.1:4533`), user + password, **Test & connect** — the live
station now rotates your local library.

## 3. What the contract verifier proves

| Check | Guards |
|---|---|
| `subsonic-response` envelope, `status`, `error.message` | `NavidromeClient` decoding + error surfacing |
| Token math (`md5(password+salt)`, 32-char hex) | The auth `NavidromeClient` sends Navidrome |
| Wrong credentials → `status: failed` + message | Settings "Test & connect" failure path |
| `randomSongs.song[].id/title/artist/artistId/album/duration/coverArt` | `Track` mapping, optional-field fallbacks |
| `stream` returns real MP3 bytes | `AVPlayer` playback via `Track.assetURL` |
| Every song maps into a `Track`; ≥3 distinct artists | Rotation engine has real choice under the artist caps |
