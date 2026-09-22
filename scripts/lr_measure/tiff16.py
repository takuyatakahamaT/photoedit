#!/usr/bin/env python3
"""16bit RGB TIFF を float32 [0,1] の numpy 配列で読む（Pillow は 16bit RGB TIFF を 8bit に落とすため自前で読む）。

対応: 非圧縮 / Deflate(8, 32946) / PackBits(32773)、ストリップ形式、RGB(+alpha無視)、Little/Big endian。
LZW 等の未対応圧縮は Pillow で読んで 8bit 精度で返し、`precision_bits` に 8 を入れる。

from tiff16 import read_rgb
rgb, info = read_rgb(path)   # rgb: (H, W, 3) float32、info: {"bits": 16, "icc": bytes|None, "compression": int}
"""
from __future__ import annotations

import struct
import zlib
from pathlib import Path

import numpy as np

TYPE_SIZE = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 16: 8}


def _read_ifd(data: bytes, offset: int, endian: str) -> dict[int, tuple[int, int, bytes]]:
    count = struct.unpack(endian + "H", data[offset : offset + 2])[0]
    tags = {}
    for i in range(count):
        base = offset + 2 + i * 12
        tag, typ, n = struct.unpack(endian + "HHI", data[base : base + 8])
        size = TYPE_SIZE.get(typ, 1) * n
        if size <= 4:
            raw = data[base + 8 : base + 8 + size]
        else:
            ptr = struct.unpack(endian + "I", data[base + 8 : base + 12])[0]
            raw = data[ptr : ptr + size]
        tags[tag] = (typ, n, raw)
    return tags


def _ints(entry: tuple[int, int, bytes], endian: str) -> list[int]:
    typ, n, raw = entry
    fmt = {1: "B", 3: "H", 4: "I", 16: "Q"}[typ]
    return list(struct.unpack(endian + fmt * n, raw[: TYPE_SIZE[typ] * n]))


def _packbits(src: bytes, expected: int) -> bytes:
    out = bytearray()
    i = 0
    while len(out) < expected and i < len(src):
        n = src[i]
        i += 1
        if n < 128:
            out += src[i : i + n + 1]
            i += n + 1
        elif n > 128:
            out += bytes([src[i]]) * (257 - n)
            i += 1
    return bytes(out)


def read_rgb(path: Path | str) -> tuple[np.ndarray, dict]:
    data = Path(path).read_bytes()
    endian = "<" if data[:2] == b"II" else ">"
    if struct.unpack(endian + "H", data[2:4])[0] != 42:
        raise ValueError("BigTIFF や非TIFFは未対応")
    ifd = _read_ifd(data, struct.unpack(endian + "I", data[4:8])[0], endian)
    width = _ints(ifd[256], endian)[0]
    height = _ints(ifd[257], endian)[0]
    bits = _ints(ifd[258], endian)
    spp = _ints(ifd[277], endian)[0] if 277 in ifd else 1
    compression = _ints(ifd[259], endian)[0] if 259 in ifd else 1
    planar = _ints(ifd[284], endian)[0] if 284 in ifd else 1
    photometric = _ints(ifd[262], endian)[0] if 262 in ifd else 2
    icc = ifd[34675][2] if 34675 in ifd else None
    predictor = _ints(ifd[317], endian)[0] if 317 in ifd else 1

    if compression not in (1, 8, 32946, 32773) or planar != 1 or photometric != 2 or 273 not in ifd:
        from PIL import Image

        image = Image.open(path).convert("RGB")
        arr = np.asarray(image, np.float32) / 255.0
        return arr, {"bits": 8, "icc": icc, "compression": compression, "note": "Pillow fallback (8bit)"}

    offsets = _ints(ifd[273], endian)
    counts = _ints(ifd[279], endian)
    rows_per_strip = _ints(ifd[278], endian)[0] if 278 in ifd else height
    bps = bits[0]
    dtype = np.dtype((endian if bps == 16 else "|") + ("u2" if bps == 16 else "u1"))
    row_bytes = width * spp * (bps // 8)

    chunks = []
    for index, (offset, count) in enumerate(zip(offsets, counts)):
        strip = data[offset : offset + count]
        rows = min(rows_per_strip, height - index * rows_per_strip)
        if compression in (8, 32946):
            strip = zlib.decompress(strip)
        elif compression == 32773:
            strip = _packbits(strip, rows * row_bytes)
        arr = np.frombuffer(strip[: rows * row_bytes], dtype=dtype).reshape(rows, width, spp)
        if predictor == 2:
            arr = np.cumsum(arr.astype(np.uint32), axis=1).astype(dtype.type) if bps == 8 else (
                np.cumsum(arr.astype(np.uint32), axis=1) & 0xFFFF
            ).astype(dtype.type)
        chunks.append(arr)
    pixels = np.concatenate(chunks, axis=0)[:, :, :3]
    scale = 65535.0 if bps == 16 else 255.0
    return pixels.astype(np.float32) / scale, {"bits": bps, "icc": icc, "compression": compression, "width": width, "height": height}


if __name__ == "__main__":
    import sys

    rgb, info = read_rgb(sys.argv[1])
    print(rgb.shape, rgb.dtype, rgb.min(), rgb.max(), {k: v for k, v in info.items() if k != "icc"}, "icc" if info["icc"] else "no-icc")
