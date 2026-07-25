# RealAudio — the station's local masters

Drop licensed audio files here and the app plays them as the live station
instead of the silent `MockCatalog` demo. This folder is bundled into the app
as a folder reference; its **contents are gitignored** so masters never enter
the repo — only this README is committed.

Rules of the folder:

- **Only opted-in, licensed masters.** Placing a file here is the MVP's
  stand-in for the OneSync interactive-license assertion; the production swap
  replaces this folder with the real opt-in feed.
- Supported formats: `m4a`, `mp3`, `wav`, `aiff`, `flac`, `caf`.
- Name files **`Artist - Title.m4a`** (embedded tags win when present).
- At least 3 tracks are needed to switch the app into real-audio mode.
- Convert big WAV masters to AAC to keep the bundle lean:

```bash
afconvert -f m4af -d aac -b 256000 "Master.wav" "RealAudio/Artist - Title.m4a"
```
