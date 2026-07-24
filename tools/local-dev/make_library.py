"""Generate a small tagged MP3 library so the local Subsonic server has real,
streamable, scannable music. Each track is a short layered-tone loop."""
import math
import os
import struct

import lameenc
from mutagen.id3 import ID3, TIT2, TPE1, TALB, TLEN

LIB = os.path.expanduser("~/radio-music")
SR = 44100
SECONDS = 20

CATALOG = [
    ("Neon Tide", "Undertow", ["Coastline Signals", "Slow Motion Ghost"], 220.0),
    ("The Local Static", "Basement Tapes", ["Parking Lot Kings", "Everyone's Asleep"], 174.6),
    ("Marigold Avenue", "Southbound", ["Golden Hour Traffic", "Paper Streetlights"], 261.6),
    ("Cassette Sun", "Warm Static", ["Analog Heart", "Fade In Slow"], 196.0),
    ("Ivy & Oaks", "Foxglove", ["Backroad Cathedral", "Porchlight"], 246.9),
]


def render(base_freq, seconds=SECONDS):
    """A gentle three-partial tone with slow tremolo — pleasant enough to loop."""
    samples = bytearray()
    n = int(SR * seconds)
    for i in range(n):
        t = i / SR
        env = min(1.0, t / 0.05, (seconds - t) / 0.5)
        trem = 0.85 + 0.15 * math.sin(2 * math.pi * 0.5 * t)
        v = (
            0.50 * math.sin(2 * math.pi * base_freq * t)
            + 0.30 * math.sin(2 * math.pi * base_freq * 1.5 * t)
            + 0.20 * math.sin(2 * math.pi * base_freq * 2.0 * t)
        )
        sample = int(28000 * env * trem * v)
        packed = struct.pack("<h", sample)
        samples += packed + packed  # stereo
    return bytes(samples)


def main():
    os.makedirs(LIB, exist_ok=True)
    made = 0
    for ai, (artist, album, titles, freq) in enumerate(CATALOG):
        folder = os.path.join(LIB, artist, album)
        os.makedirs(folder, exist_ok=True)
        for ti, title in enumerate(titles):
            enc = lameenc.Encoder()
            enc.set_bit_rate(128)
            enc.set_in_sample_rate(SR)
            enc.set_channels(2)
            enc.set_quality(5)
            pcm = render(freq * (1.0 + 0.12 * ti))
            data = enc.encode(pcm) + enc.flush()
            path = os.path.join(folder, f"{ti+1:02d} - {title}.mp3")
            with open(path, "wb") as f:
                f.write(data)
            tags = ID3()
            tags.add(TIT2(encoding=3, text=title))
            tags.add(TPE1(encoding=3, text=artist))
            tags.add(TALB(encoding=3, text=album))
            tags.add(TLEN(encoding=3, text=str(SECONDS * 1000)))
            tags.save(path)
            made += 1
    print(f"wrote {made} tagged mp3s under {LIB}")


if __name__ == "__main__":
    main()
