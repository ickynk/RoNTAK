"""Makes a PNG fully opaque without touching its colours (standard library only).

Ready or Not's floor plan captures (base colour) are exported with alpha 0
everywhere: viewers show them as white and browsers drop the colours. In a
PNG each colour channel is filtered on its own, so the alpha bytes of the
filtered rows can be rewritten to decode to 255 without decoding the image.
"""

import struct
import zlib

SIGNATURE = b"\x89PNG\r\n\x1a\n"
OPAQUE = 255


def _chunks(data: bytes):
    pos = len(SIGNATURE)
    while pos + 8 <= len(data):
        length, = struct.unpack(">I", data[pos:pos + 4])
        yield data[pos + 4:pos + 8], data[pos + 8:pos + 8 + length]
        pos += 12 + length


def _chunk(kind: bytes, body: bytes) -> bytes:
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)


def _paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c


def _predict(kind, a, b, c):
    """What PNG filter `kind` predicts from left (a), up (b) and up-left (c)."""
    return (0, a, b, (a + b) // 2, _paeth(a, b, c))[kind]


def make_opaque(data: bytes) -> bytes:
    """The same picture with alpha 255 everywhere. Anything but a plain 8-bit
    RGBA PNG is returned unchanged."""
    if not data.startswith(SIGNATURE):
        raise ValueError("not a PNG file")
    header, idat = None, []
    for kind, body in _chunks(data):
        if kind == b"IHDR":
            header = body
        elif kind == b"IDAT":
            idat.append(body)
    width, height, depth, colour_type, _, _, interlace = struct.unpack(">IIBBBBB", header)
    if depth != 8 or colour_type != 6 or interlace != 0:
        return data
    raw = bytearray(zlib.decompress(b"".join(idat)))
    stride = width * 4
    for y in range(height):
        row = y * (stride + 1)
        kind = raw[row]
        if kind > 4:
            raise ValueError(f"bad PNG filter type {kind}")
        up = OPAQUE if y else 0
        # Neighbours of every alpha byte once all alpha is 255; outside the picture is 0.
        first = (OPAQUE - _predict(kind, 0, up, 0)) & 0xFF
        rest = (OPAQUE - _predict(kind, OPAQUE, up, up)) & 0xFF
        raw[row + 4] = first
        raw[row + 8:row + 1 + stride:4] = bytes([rest]) * (width - 1)
    return (SIGNATURE + _chunk(b"IHDR", header) + _chunk(b"IDAT", zlib.compress(bytes(raw), 6))
            + _chunk(b"IEND", b""))
