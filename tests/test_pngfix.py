"""Tests for companion/pngfix.py: making the game's alpha-0 captures opaque."""

import struct
import sys
import unittest
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "companion"))
import pngfix  # noqa: E402


def predict(kind, a, b, c):
    return pngfix._predict(kind, a, b, c)


def encode(width, height, pixels, filters):
    """A PNG of pixels[v][u] = (r, g, b, a), row v filtered with filters[v % len]."""
    rows, prev = [], bytes(width * 4)
    for v in range(height):
        line = bytes(b for p in pixels[v] for b in p)
        kind = filters[v % len(filters)]
        out = bytearray([kind])
        for i, x in enumerate(line):
            a = line[i - 4] if i >= 4 else 0
            c = prev[i - 4] if i >= 4 else 0
            out.append((x - predict(kind, a, prev[i], c)) & 0xFF)
        rows.append(bytes(out))
        prev = line

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))
    return (pngfix.SIGNATURE + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"".join(rows))) + chunk(b"IEND", b""))


def decode(data):
    header, idat = None, []
    for kind, body in pngfix._chunks(data):
        if kind == b"IHDR":
            header = body
        elif kind == b"IDAT":
            idat.append(body)
    width, height = struct.unpack(">II", header[:8])
    raw, stride, prev, out = zlib.decompress(b"".join(idat)), width * 4, bytes(width * 4), []
    for v in range(height):
        kind, line = raw[v * (stride + 1)], bytearray(raw[v * (stride + 1) + 1:(v + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - 4] if i >= 4 else 0
            c = prev[i - 4] if i >= 4 else 0
            line[i] = (line[i] + predict(kind, a, prev[i], c)) & 0xFF
        out.append([tuple(line[u * 4:u * 4 + 4]) for u in range(width)])
        prev = bytes(line)
    return out


class PngFixTest(unittest.TestCase):
    def test_alpha_255_colours_unchanged_with_every_filter(self):
        width, height = 7, 10
        pixels = [[((u * 37 + v * 11) % 256, (u * v * 5) % 256, (200 - u * 9) % 256, 0) for u in range(width)]
                  for v in range(height)]
        for filters in ([0], [1], [2], [3], [4], [4, 1, 3, 2, 0]):
            fixed = decode(pngfix.make_opaque(encode(width, height, pixels, filters)))
            self.assertEqual(fixed, [[p[:3] + (255,) for p in row] for row in pixels], filters)

    def test_other_pngs_are_left_alone(self):
        rgb = pngfix.SIGNATURE + struct.pack(">I", 13) + b"IHDR" + struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)
        self.assertEqual(pngfix.make_opaque(rgb), rgb)
        with self.assertRaises(ValueError):
            pngfix.make_opaque(b"not a png")


if __name__ == "__main__":
    unittest.main()
