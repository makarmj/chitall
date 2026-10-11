"""Draws the 1024x1024 app icon (paper, dark wooden book, ochre ribbon) without dependencies.

Usage: python -I tools/make_app_icon.py
Writes Chitall/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
"""

import pathlib
import struct
import zlib

SIZE = 1024
ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "Chitall" / "Resources" / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon.png"

PAPER = (0xF3, 0xEA, 0xD9)
WOOD = (0x3B, 0x2A, 0x1E)
WOOD_EDGE = (0x52, 0x3B, 0x2A)
PAGES = (0xE9, 0xDD, 0xC6)
OCHRE = (0xC9, 0x93, 0x3A)


def inside_rounded(x, y, left, top, right, bottom, radius):
    if x < left or x >= right or y < top or y >= bottom:
        return False
    cx = min(max(x, left + radius), right - radius)
    cy = min(max(y, top + radius), bottom - radius)
    return (x - cx) ** 2 + (y - cy) ** 2 <= radius ** 2


def color_at(x, y):
    # Ribbon: hangs from the top of the book and ends in a V notch below it.
    ribbon_left, ribbon_right = 610, 690
    if ribbon_left <= x < ribbon_right and 170 <= y < 900:
        notch_depth = 70
        middle = (ribbon_left + ribbon_right) / 2
        bottom = 900 - notch_depth * (1 - abs(x - middle) / ((ribbon_right - ribbon_left) / 2))
        if y < bottom:
            return OCHRE
    # Page block peeking out on the right and bottom of the cover.
    if inside_rounded(x, y, 300, 196, 772, 846, 36) and not inside_rounded(x, y, 252, 170, 748, 822, 40):
        return PAGES
    if inside_rounded(x, y, 252, 170, 748, 822, 40):
        if x < 300:
            return WOOD_EDGE  # spine
        return WOOD
    return PAPER


def main():
    rows = bytearray()
    for y in range(SIZE):
        rows.append(0)  # filter type: none
        for x in range(SIZE):
            rows.extend(color_at(x, y))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(rows), 9))
    png += chunk(b"IEND", b"")
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_bytes(png)
    print(OUT, len(png), "bytes")


if __name__ == "__main__":
    main()
