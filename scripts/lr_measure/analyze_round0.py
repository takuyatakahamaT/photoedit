#!/usr/bin/env python3
"""LR計測 round0 の判定。LRの書き出しが exports/lr-measure/round0/lr-export に揃ってから実行する。

判定:
  A. 外部生成XMPが読まれたか（sat-100 が無彩色か）。RAWサイドカー / JPEG埋め込み / TIFF埋め込みの別。
  B. サイドカーで全設定を与えた書き出しが、オーナーが手でプリセットを当てた書き出しと一致するか。
  C. 操作別の寄与（neutral比の平均ΔE00・平均EV差・平均彩度比）。
"""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
ROUND = ROOT / "exports/lr-measure/round0"
EXPORT = ROUND / "lr-export"
REFERENCE = ROOT / "exports/editing-mvp-20260922/lightroom-reference"

spec = importlib.util.spec_from_file_location("calibration", ROOT / "scripts/analyze-calibration.py")
calibration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(calibration)


def lab(path: Path, size=(1500, 1000)) -> np.ndarray:
    image = Image.open(path).convert("RGB").resize(size, Image.Resampling.BOX)
    return calibration.srgb_to_lab(np.asarray(image, np.float32) / 255)


def compare(a: np.ndarray, b: np.ndarray) -> dict[str, float]:
    delta = calibration.delta_e_2000(a, b)
    chroma_a, chroma_b = np.linalg.norm(a[..., 1:], axis=-1), np.linalg.norm(b[..., 1:], axis=-1)
    return {
        "meanDeltaE00": float(delta.mean()),
        "p95DeltaE00": float(np.percentile(delta, 95)),
        "meanLstarDiff": float((a[..., 0] - b[..., 0]).mean()),
        "chromaRatio": float(chroma_a.mean() / max(chroma_b.mean(), 1e-6)),
    }


def find(stem: str) -> Path | None:
    for suffix in (".jpg", ".jpeg", ".JPG"):
        if (EXPORT / f"{stem}{suffix}").exists():
            return EXPORT / f"{stem}{suffix}"
    return None


def main() -> None:
    report: dict[str, object] = {}
    honored = {}
    for kind in ("raw", "jpg", "tif"):
        path = find(f"r0_{kind}_sat-100")
        if path is None:
            honored[kind] = "書き出し無し"
            continue
        chroma = float(np.linalg.norm(lab(path)[..., 1:], axis=-1).mean())
        honored[kind] = {"meanChroma": chroma, "xmpHonored": chroma < 2.0}
    report["A_xmpHonored"] = honored

    full, manual = find("r0_raw_full"), REFERENCE / "P1013558-2.jpg"
    if full:
        report["B_sidecarFull_vs_manualPreset"] = compare(lab(full), lab(manual))
    neutral = find("r0_raw_neutral")
    if neutral:
        report["B_sidecarNeutral_vs_lrDefault"] = compare(lab(neutral), lab(REFERENCE / "P1013558.jpg"))
        base = lab(neutral)
        report["C_rawPerOperation_vs_neutral"] = {
            path.stem: compare(lab(path), base)
            for path in sorted(EXPORT.glob("r0_raw_*")) if path != neutral
        }
    jpeg_neutral = find("r0_jpg_neutral")
    if jpeg_neutral:
        base = lab(jpeg_neutral)
        report["C_jpegPerOperation_vs_neutral"] = {
            path.stem: compare(lab(path), base)
            for path in sorted(EXPORT.glob("r0_jpg_*")) if path != jpeg_neutral
        }
    (ROUND / "analysis.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
