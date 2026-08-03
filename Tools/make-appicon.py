#!/usr/bin/env python3
"""Fit artwork into the app-icon slot.

Takes any big square-ish artwork, finds the artwork's own tile (many icon
mockups sit a rounded tile on a pure-black field — shipping that whole frame
makes the real icon look like a small icon inside the tile), crops to it,
flattens any alpha onto black (App Store icons must carry NO alpha), resizes
to 1024, and drops it into the asset catalog.

Usage: python3 Tools/make-appicon.py <input-image>
"""
import sys
from PIL import Image

DEST = "Sources/SwellApp/Assets.xcassets/AppIcon.appiconset/AppIcon1024.png"
THRESHOLD = 14   # anything brighter than this counts as artwork, not field


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    im = Image.open(sys.argv[1]).convert("RGB")

    # Bounding box of everything brighter than the near-black field.
    mask = im.convert("L").point(lambda p: 255 if p > THRESHOLD else 0)
    box = mask.getbbox()
    if box:
        left, top, right, bottom = box
        # Only crop when a real outer field exists (artwork clearly inset);
        # edge-to-edge art passes through untouched.
        w, h = im.size
        if left > w * 0.02 or top > h * 0.02 or right < w * 0.98 or bottom < h * 0.98:
            # Square the crop around the tile's center so nothing distorts.
            side = max(right - left, bottom - top)
            cx, cy = (left + right) // 2, (top + bottom) // 2
            half = side // 2
            l = max(0, cx - half); t = max(0, cy - half)
            im = im.crop((l, t, min(w, l + side), min(h, t + side)))

    im = im.resize((1024, 1024), Image.LANCZOS)
    im.save(DEST, "PNG")
    print(f"wrote {DEST} ({im.size[0]}x{im.size[1]}, no alpha)")


if __name__ == "__main__":
    main()
