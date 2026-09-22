#!/usr/bin/env python3
"""HALD チャートの LR 書き出しから 3D LUT を取り出し、操作の性質を調べる。

- extract_lut(path, level=8) -> (64,64,64,3) float32。index [r][g][b] → 出力RGB（書き出しの色空間、通常 sRGB か ProPhoto）。
- apply_lut(lut, rgb) : 三線形補間で任意画像へ適用（LUTの入力空間に画像を合わせておくこと）。
- describe(lut_ref, lut_op): 操作LUT（op）と基準LUT（ref。同条件で操作無し）を比べ、
    * 無彩色軸の応答（グレーランプがどう動いたか）
    * 各画素の HSV 色相の変化量（色相保持か）
    * 「per-channel（R,G,B 独立の1次元カーブ）で説明できる割合」
  を返す。LRが点カーブを per-channel で掛けているか、色相保持で掛けているかの切り分けに使う。

from haldlut import extract_lut, apply_lut, describe
"""
from __future__ import annotations

import colorsys
from pathlib import Path

import numpy as np

from tiff16 import read_rgb


def extract_lut(path: Path | str, level: int = 8) -> np.ndarray:
    steps = level * level
    rgb, _ = read_rgb(path) if str(path).lower().endswith((".tif", ".tiff")) else (None, None)
    if rgb is None:
        from PIL import Image

        rgb = np.asarray(Image.open(path).convert("RGB"), np.float32) / 255.0
    size = level**3
    if rgb.shape[0] != size or rgb.shape[1] != size:
        raise ValueError(f"HALD level {level} は {size}×{size} のはず: {rgb.shape}")
    flat = rgb.reshape(-1, 3)
    # 生成側と同じ並び: index = r + g*steps + b*steps*steps
    lut = np.zeros((steps, steps, steps, 3), np.float32)
    idx = np.arange(steps**3)
    lut[idx % steps, (idx // steps) % steps, idx // (steps * steps)] = flat
    return lut


def apply_lut(lut: np.ndarray, rgb: np.ndarray) -> np.ndarray:
    n = lut.shape[0]
    x = np.clip(rgb, 0.0, 1.0) * (n - 1)
    i0 = np.floor(x).astype(np.int64)
    i0 = np.clip(i0, 0, n - 2)
    f = x - i0
    r0, g0, b0 = i0[..., 0], i0[..., 1], i0[..., 2]
    fr, fg, fb = f[..., 0:1], f[..., 1:2], f[..., 2:3]
    c000 = lut[r0, g0, b0]
    c100 = lut[r0 + 1, g0, b0]
    c010 = lut[r0, g0 + 1, b0]
    c110 = lut[r0 + 1, g0 + 1, b0]
    c001 = lut[r0, g0, b0 + 1]
    c101 = lut[r0 + 1, g0, b0 + 1]
    c011 = lut[r0, g0 + 1, b0 + 1]
    c111 = lut[r0 + 1, g0 + 1, b0 + 1]
    c00 = c000 * (1 - fr) + c100 * fr
    c10 = c010 * (1 - fr) + c110 * fr
    c01 = c001 * (1 - fr) + c101 * fr
    c11 = c011 * (1 - fr) + c111 * fr
    c0 = c00 * (1 - fg) + c10 * fg
    c1 = c01 * (1 - fg) + c11 * fg
    return c0 * (1 - fb) + c1 * fb


def gray_axis(lut: np.ndarray) -> np.ndarray:
    n = lut.shape[0]
    i = np.arange(n)
    return lut[i, i, i]


def hue_shift_deg(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    def hue(x):
        flat = x.reshape(-1, 3)
        return np.array([colorsys.rgb_to_hsv(*np.clip(p, 0, 1))[0] for p in flat]) * 360.0

    d = hue(b) - hue(a)
    return (d + 180.0) % 360.0 - 180.0


def per_channel_fit(lut_ref: np.ndarray, lut_op: np.ndarray) -> tuple[np.ndarray, float]:
    """op ≈ f(ref) を、R/G/B 独立の 1D 単調カーブ f で説明できるか。
    グレー軸から f を推定し、全格子点での残差 RMS（0..1 単位）を返す。"""
    n = lut_ref.shape[0]
    ref_gray = gray_axis(lut_ref)
    op_gray = gray_axis(lut_op)
    fitted = np.empty_like(lut_op)
    for ch in range(3):
        xs = ref_gray[:, ch]
        ys = op_gray[:, ch]
        order = np.argsort(xs)
        fitted[..., ch] = np.interp(lut_ref[..., ch], xs[order], ys[order])
    resid = np.sqrt(((fitted - lut_op) ** 2).mean())
    return fitted, float(resid)


def describe(lut_ref: np.ndarray, lut_op: np.ndarray, sample: int = 4096, seed: int = 0) -> dict:
    rng = np.random.default_rng(seed)
    n = lut_ref.shape[0]
    idx = rng.integers(0, n, size=(sample, 3))
    a = lut_ref[idx[:, 0], idx[:, 1], idx[:, 2]]
    b = lut_op[idx[:, 0], idx[:, 1], idx[:, 2]]
    sat = np.array([colorsys.rgb_to_hsv(*np.clip(p, 0, 1))[1] for p in a])
    chromatic = sat > 0.15
    hue_delta = hue_shift_deg(a[chromatic], b[chromatic])
    _, per_channel_resid = per_channel_fit(lut_ref, lut_op)
    gray_ref, gray_op = gray_axis(lut_ref), gray_axis(lut_op)
    return {
        "grayResponse": np.stack([gray_ref.mean(-1), gray_op.mean(-1)], axis=1).round(4).tolist(),
        "grayNeutralityMaxDeviation": float(np.abs(gray_op - gray_op.mean(-1, keepdims=True)).max()),
        "hueShiftDegMeanAbs": float(np.abs(hue_delta).mean()),
        "hueShiftDegP95": float(np.percentile(np.abs(hue_delta), 95)),
        "perChannelFitResidualRMS": per_channel_resid,
        "meanAbsChange": float(np.abs(b - a).mean()),
    }


if __name__ == "__main__":
    import json
    import sys

    ref = extract_lut(sys.argv[1])
    op = extract_lut(sys.argv[2])
    print(json.dumps(describe(ref, op), indent=2))
