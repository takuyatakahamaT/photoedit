#!/usr/bin/env python3
"""round1 チャート書き出し（HALD, ProPhoto 16bit）を「リニアProPhoto → リニアProPhoto」の操作として読む。

from opmodel import Op, load_op
op = load_op("Exposure2012_+1.00")   # op.x: (N,3) 入力リニアProPhoto, op.y: 出力リニアProPhoto, op.valid: 信頼できる格子点
"""
from __future__ import annotations

import colorsys
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

import numpy as np

from haldlut import extract_lut

ROOT = Path(__file__).resolve().parents[2]
EXPORT = ROOT / "exports/lr-measure/round1/lr-export-charts"
N = 64

M_SRGB_TO_XYZ_D65 = np.array([[0.4124564, 0.3575761, 0.1804375], [0.2126729, 0.7151522, 0.0721750], [0.0193339, 0.1191920, 0.9503041]])
BRADFORD_D65_TO_D50 = np.array([[1.0478112, 0.0228866, -0.0501270], [0.0295424, 0.9904844, -0.0170491], [-0.0092345, 0.0150436, 0.7521316]])
M_PP_TO_XYZ_D50 = np.array([[0.7976749, 0.1351917, 0.0313534], [0.2880402, 0.7118741, 0.0000857], [0.0, 0.0, 0.8252100]])
M_XYZ_D50_TO_PP = np.linalg.inv(M_PP_TO_XYZ_D50)
SRGB_TO_PP = M_XYZ_D50_TO_PP @ BRADFORD_D65_TO_D50 @ M_SRGB_TO_XYZ_D65
PP_TO_SRGB = np.linalg.inv(SRGB_TO_PP)
PP_LUMA = M_PP_TO_XYZ_D50[1]  # Y row


def srgb_decode(x: np.ndarray) -> np.ndarray:
    return np.where(x <= 0.04045, x / 12.92, ((x + 0.055) / 1.055) ** 2.4)


def srgb_encode(x: np.ndarray) -> np.ndarray:
    x = np.clip(x, 0, None)
    return np.where(x <= 0.0031308, x * 12.92, 1.055 * np.power(x, 1 / 2.4) - 0.055)


def pp_decode(v: np.ndarray) -> np.ndarray:
    return np.where(v < 16 / 512, v / 16, np.power(np.clip(v, 0, None), 1.8))


def pp_encode(x: np.ndarray) -> np.ndarray:
    x = np.clip(x, 0, None)
    return np.where(x < 1 / 512, 16 * x, np.power(x, 1 / 1.8))


@dataclass
class Op:
    name: str
    chart: str
    x: np.ndarray  # (N^3, 3) input, linear ProPhoto
    y: np.ndarray  # (N^3, 3) output, linear ProPhoto
    y_ref: np.ndarray  # neutral output (should equal x up to clipping)
    valid: np.ndarray  # (N^3,) bool: neutral roundtrip within tolerance

    @property
    def grid(self) -> np.ndarray:
        g = np.arange(N) / (N - 1)
        return np.stack(np.meshgrid(g, g, g, indexing="ij"), -1).reshape(-1, 3)


@lru_cache(maxsize=None)
def _lut(chart: str, variant: str) -> np.ndarray:
    return extract_lut(EXPORT / f"c1_{chart}_{variant}.tif").reshape(-1, 3)


def load_op(variant: str, chart: str = "hald-srgb") -> Op:
    g = np.arange(N) / (N - 1)
    grid = np.stack(np.meshgrid(g, g, g, indexing="ij"), -1).reshape(-1, 3)
    if chart == "hald-srgb":
        x = srgb_decode(grid) @ SRGB_TO_PP.T
    elif chart == "hald-prophoto":
        x = pp_decode(grid)
    else:
        raise ValueError(chart)
    y_ref = pp_decode(_lut(chart, "neutral"))
    y = pp_decode(_lut(chart, variant))
    valid = np.abs(y_ref - x).max(-1) < 0.004
    return Op(variant, chart, x, y, y_ref, valid)


def luminance(rgb: np.ndarray) -> np.ndarray:
    return rgb @ PP_LUMA


def hsv(rgb: np.ndarray) -> np.ndarray:
    out = np.empty_like(rgb)
    for i, p in enumerate(np.clip(rgb, 0, 1)):
        out[i] = colorsys.rgb_to_hsv(*p)
    return out


def gray_response(op: Op) -> tuple[np.ndarray, np.ndarray]:
    """無彩色軸: 入力輝度 → 出力輝度（リニア）"""
    g = op.grid
    on_gray = (np.abs(g[:, 0] - g[:, 1]) < 1e-6) & (np.abs(g[:, 1] - g[:, 2]) < 1e-6)
    return luminance(op.x[on_gray]), luminance(op.y[on_gray])


def summarize(op: Op, sample: int = 20000, seed: int = 0) -> dict:
    rng = np.random.default_rng(seed)
    idx = rng.choice(np.flatnonzero(op.valid), size=min(sample, int(op.valid.sum())), replace=False)
    x, y = op.x[idx], op.y[idx]
    hx, hy = hsv(x), hsv(y)
    chroma_mask = hx[:, 1] > 0.15
    dh = (hy[chroma_mask, 0] - hx[chroma_mask, 0] + 0.5) % 1.0 - 0.5
    gx, gy = gray_response(op)
    ratio = gy / np.clip(gx, 1e-6, None)
    return {
        "hueShiftDegMeanAbs": float(np.abs(dh).mean() * 360),
        "hueShiftDegP95": float(np.percentile(np.abs(dh), 95) * 360),
        "grayGainMin": float(ratio[1:].min()),
        "grayGainMax": float(ratio[1:].max()),
        "grayNeutralMaxDev": float(np.abs(op.y[np.flatnonzero((np.abs(op.grid[:, 0] - op.grid[:, 1]) < 1e-6) & (np.abs(op.grid[:, 1] - op.grid[:, 2]) < 1e-6))].std(-1)).max()),
        "meanAbsDelta": float(np.abs(y - x).mean()),
        "satChangeMean": float((hy[chroma_mask, 1] - hx[chroma_mask, 1]).mean()),
    }


if __name__ == "__main__":
    import json
    import sys

    op = load_op(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "hald-srgb")
    print(json.dumps(summarize(op), indent=2))
