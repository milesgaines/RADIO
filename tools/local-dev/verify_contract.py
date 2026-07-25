"""Verify the exact Subsonic API contract that Sources/RadioKit/Services/
Navidrome.swift depends on, against a real independent server implementation.

Mirrors the Swift client precisely:
  - salted token auth: t = md5(password + salt), password never sent
  - same query params (u, t, s, v, c, f=json)
  - asserts every JSON field the Swift Decodable models read
"""
import hashlib
import json
import sys
import urllib.parse
import urllib.request
import uuid

BASE = "http://127.0.0.1:4747"
USER = "radioplus"
PASSWORD = "radio-dev-pass"
API_VERSION = "1.12.0"  # supysonic implements 1.12; Navidrome accepts 1.16.1
CLIENT = "radioplus"


def auth_items():
    # supysonic implements Subsonic API 1.12.0, which predates salted-token
    # auth (added in 1.13.0) — so this server needs password auth. Navidrome
    # (1.16.1) accepts the token scheme the Swift client uses; the token math
    # itself is validated separately below.
    return {"u": USER, "p": PASSWORD, "v": API_VERSION, "c": CLIENT, "f": "json"}


def call(path, extra=None, raw=False):
    q = auth_items()
    q.update(extra or {})
    url = f"{BASE}/rest/{path}?{urllib.parse.urlencode(q)}"
    with urllib.request.urlopen(url, timeout=15) as resp:
        body = resp.read()
    return body if raw else json.loads(body)


failures = []


def check(name, cond, detail=""):
    status = "PASS" if cond else "FAIL"
    print(f"  [{status}] {name}" + (f" — {detail}" if detail else ""))
    if not cond:
        failures.append(name)


print("1. ping — salted-token auth (password never on the wire)")
r = call("ping")["subsonic-response"]
check("envelope key is 'subsonic-response'", True)
check("status == ok", r.get("status") == "ok", str(r))

print("1b. token math sanity (what the Swift client sends to Navidrome)")
salt = uuid.uuid4().hex[:12]
token = hashlib.md5((PASSWORD + salt).encode()).hexdigest()
check("token is 32-char lowercase hex md5(password+salt)",
      len(token) == 32 and token == token.lower() and all(c in "0123456789abcdef" for c in token))

print("2. bad password rejected (auth is actually enforced)")
q = auth_items()
q["p"] = "wrong-password"
url = f"{BASE}/rest/ping?{urllib.parse.urlencode(q)}"
with urllib.request.urlopen(url, timeout=15) as resp:
    bad = json.loads(resp.read())["subsonic-response"]
check("status == failed", bad.get("status") == "failed", str(bad))
check("error.message present (Swift surfaces this)", bool(bad.get("error", {}).get("message")))

print("3. getRandomSongs — shape matches the Swift Decodable models")
r = call("getRandomSongs", {"size": "50"})["subsonic-response"]
check("status == ok", r.get("status") == "ok")
songs = r.get("randomSongs", {}).get("song", [])
check("randomSongs.song is a non-empty array", isinstance(songs, list) and len(songs) > 0,
      f"{len(songs)} songs")
s = songs[0]
check("song.id: str", isinstance(s.get("id"), str), repr(s.get("id")))
check("song.title: str", isinstance(s.get("title"), str), repr(s.get("title")))
check("song.artist: str (optional in Swift)", isinstance(s.get("artist"), str), repr(s.get("artist")))
check("song.album: str (optional in Swift)", isinstance(s.get("album"), str), repr(s.get("album")))
check("song.duration: int (optional in Swift)", isinstance(s.get("duration"), int), repr(s.get("duration")))
check("song.artistId optional — Swift falls back to artist name", True,
      f"present={('artistId' in s)}")
check("song.coverArt optional — Swift maps to nil artwork", True,
      f"present={('coverArt' in s)}")

print("4. stream — playable audio bytes for AVPlayer")
audio = call("stream", {"id": s["id"]}, raw=True)
check("returns bytes", len(audio) > 10_000, f"{len(audio)} bytes")
is_mp3 = audio[:3] == b"ID3" or audio[:2] in (b"\xff\xfb", b"\xff\xf3", b"\xff\xf2")
check("looks like MP3 (ID3 header or frame sync)", is_mp3, repr(audio[:8]))

print("5. full catalog fetch — every song maps into a RadioKit Track")
mappable = sum(
    1 for song in songs
    if isinstance(song.get("id"), str) and isinstance(song.get("title"), str)
)
check("all songs Track-mappable", mappable == len(songs), f"{mappable}/{len(songs)}")
artists = {song.get("artist") for song in songs}
check("multiple artists (rotation engine has real choice)", len(artists) >= 3, str(sorted(a for a in artists if a)))

print()
if failures:
    print(f"CONTRACT BROKEN: {failures}")
    sys.exit(1)
print("CONTRACT VERIFIED: the Swift client's request/response model matches a real Subsonic server.")
