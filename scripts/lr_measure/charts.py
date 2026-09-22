#!/usr/bin/env python3
"""LR計測用の合成チャート（16bit sRGB TIFF、ICC付き）。

- hald:  HALD恒等CLUT（level 8 = 512×512、各ch 64段階）。画素単位の色操作（カーブ・HSL・Calibration・
         Color Grading・Vibrance/Saturation）を1枚で3D LUTとして取り出す。
- ramp:  横方向の16bitグレーランプ（4096段）＋各原色・補色のランプ。トーン操作の1次元応答を高分解能で見る。
- hues:  色相スイープ（横=色相、縦=彩度と明度の組合せ帯）。HSL帯域の中心と幅の可視化用。
- freq:  周波数チャート（正弦波格子の周期を横方向に変え、縦方向にコントラストを変える）＋ステップエッジ。
         Texture / Clarity / Sharpness の帯域応答用。局所処理は画像依存なので実写でも測る。

使い方: from charts import write_chart; write_chart("hald", path)  または  python3 charts.py <out-dir>
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageCms

SRGB_ICC = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()


def _save16(rgb01: np.ndarray, path: Path) -> None:
    """float [0,1] (H,W,3) → 16bit RGB TIFF。Pillowは16bit RGBを直接書けないので tifffile 無しで書く。"""
    data = np.clip(np.rint(rgb01 * 65535.0), 0, 65535).astype("<u2")
    h, w, _ = data.shape
    _write_tiff_rgb16(path, data.tobytes(), w, h, SRGB_ICC)


def _write_tiff_rgb16(path: Path, pixels: bytes, width: int, height: int, icc: bytes) -> None:
    import struct

    entries = []

    def entry(tag: int, typ: int, count: int, value: bytes):
        entries.append((tag, typ, count, value))

    # データ配置: ヘッダ(8) → IFD → 追加データ(BitsPerSample, ICC) → 画素
    ifd_count = 12
    ifd_size = 2 + ifd_count * 12 + 4
    extra_offset = 8 + ifd_size
    bits_offset = extra_offset
    icc_offset = bits_offset + 6
    pixel_offset = icc_offset + len(icc)
    pixel_offset += pixel_offset % 2

    entry(256, 4, 1, struct.pack("<I", width))
    entry(257, 4, 1, struct.pack("<I", height))
    entry(258, 3, 3, struct.pack("<I", bits_offset))
    entry(259, 3, 1, struct.pack("<HH", 1, 0))
    entry(262, 3, 1, struct.pack("<HH", 2, 0))
    entry(273, 4, 1, struct.pack("<I", pixel_offset))
    entry(274, 3, 1, struct.pack("<HH", 1, 0))
    entry(277, 3, 1, struct.pack("<HH", 3, 0))
    entry(278, 4, 1, struct.pack("<I", height))
    entry(279, 4, 1, struct.pack("<I", len(pixels)))
    entry(284, 3, 1, struct.pack("<HH", 1, 0))
    entry(34675, 7, len(icc), struct.pack("<I", icc_offset))
    assert len(entries) == ifd_count
    entries.sort(key=lambda e: e[0])

    with open(path, "wb") as f:
        f.write(b"II*\x00" + struct.pack("<I", 8))
        f.write(struct.pack("<H", ifd_count))
        for tag, typ, count, value in entries:
            f.write(struct.pack("<HHI", tag, typ, count) + value.ljust(4, b"\x00")[:4])
        f.write(struct.pack("<I", 0))
        f.write(struct.pack("<HHH", 16, 16, 16))
        f.write(icc)
        f.write(b"\x00" * (pixel_offset - (icc_offset + len(icc))))
        f.write(pixels)


def hald(level: int = 8) -> np.ndarray:
    steps = level * level  # 64
    size = level ** 3  # 512
    idx = np.arange(steps ** 3)
    r = idx % steps
    g = (idx // steps) % steps
    b = idx // (steps * steps)
    rgb = np.stack([r, g, b], axis=-1).astype(np.float64) / (steps - 1)
    return rgb.reshape(size, size, 3)


def ramp(width: int = 4096, band: int = 96) -> np.ndarray:
    x = np.linspace(0.0, 1.0, width)
    rows = []
    for color in [(1, 1, 1), (1, 0, 0), (0, 1, 0), (0, 0, 1), (0, 1, 1), (1, 0, 1), (1, 1, 0), (1, 0.5, 0.25), (0.6, 0.45, 0.35)]:
        rows.append(np.tile((x[:, None] * np.array(color))[None, :, :], (band, 1, 1)))
    return np.concatenate(rows, axis=0)


def hues(width: int = 2160, band: int = 120) -> np.ndarray:
    import colorsys

    h = np.arange(width) / width
    rows = []
    for s, v in [(1.0, 1.0), (1.0, 0.6), (1.0, 0.3), (0.6, 0.9), (0.6, 0.5), (0.3, 0.8), (0.3, 0.4), (0.15, 0.7)]:
        rgb = np.array([colorsys.hsv_to_rgb(hh, s, v) for hh in h])
        rows.append(np.tile(rgb[None, :, :], (band, 1, 1)))
    return np.concatenate(rows, axis=0)


def freq(width: int = 3000, height: int = 1200) -> np.ndarray:
    x = np.arange(width)
    # 周期を 4px（高周波）から 400px（低周波）まで対数で変化させる
    period = np.exp(np.interp(x, [0, width - 1], [np.log(4), np.log(400)]))
    phase = np.cumsum(2 * np.pi / period)
    grating = 0.5 + 0.5 * np.sin(phase)
    rows = []
    for contrast in [0.9, 0.5, 0.25, 0.1]:
        rows.append(np.tile((0.5 + (grating - 0.5) * contrast)[None, :], (height // 6, 1)))
    step = np.where((x // 300) % 2 == 0, 0.25, 0.75)
    rows.append(np.tile(step[None, :], (height // 6, 1)))
    soft = np.clip(0.5 + 0.35 * np.sin(2 * np.pi * x / 1500), 0, 1)
    rows.append(np.tile(soft[None, :], (height - 5 * (height // 6), 1)))
    gray = np.concatenate(rows, axis=0)
    return np.repeat(gray[:, :, None], 3, axis=2)


CHARTS = {"hald": hald, "ramp": ramp, "hues": hues, "freq": freq}


def write_chart(kind: str, path: Path) -> None:
    _save16(CHARTS[kind](), path)


if __name__ == "__main__":
    out = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    out.mkdir(parents=True, exist_ok=True)
    for kind in CHARTS:
        write_chart(kind, out / f"chart-{kind}.tif")
        print(kind, "->", out / f"chart-{kind}.tif")
