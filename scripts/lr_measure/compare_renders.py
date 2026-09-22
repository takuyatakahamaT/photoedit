#!/usr/bin/env python3
"""自前レンダーと Lightroom 書き出しの比較（フェーズ1のゲート判定）。

レンズ歪曲補正が未実装の間は倍率がわずかに違うので、輝度の相関で倍率だけ合わせてから、
画像を 30×20 の領域に分けて領域平均色の CIEDE2000 を測る。画素単位の比較は幾何補正が揃ってから。

使い方:
  python3 scripts/lr_measure/compare_renders.py \
      --reference exports/editing-mvp-20260922/lightroom-reference \
      --renders .photobench/phase1/renders [--pattern '{scene}.jpg'] [--no-align] [--out result.json]

`--renders` 内のファイル名は scene ID（例 P1013558）で始まること。参照側は `<scene>.jpg`（LR既定）を既定にし、
`--reference-suffix -2` を付けるとプリセット適用後（`<scene>-2.jpg`）と比較する。
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import re
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("calibration", ROOT / "scripts/analyze-calibration.py")
calibration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(calibration)

GRID = (30, 20)
CROP = 0.06
LUMA = np.array([0.2126, 0.7152, 0.0722], np.float32)


def srgb_to_linear(a: np.ndarray) -> np.ndarray:
    return np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(a: np.ndarray) -> np.ndarray:
    return np.where(a <= 0.0031308, a * 12.92, 1.055 * np.power(np.clip(a, 0, None), 1 / 2.4) - 0.055)


def load(path: Path) -> Image.Image:
    return Image.open(path).convert("RGB")


def grid_cells(image: Image.Image) -> tuple[np.ndarray, np.ndarray]:
    """領域平均を線形光で取り、Lab と線形RGB を返す。"""
    w, h = image.size
    cropped = image.crop((int(w * CROP), int(h * CROP), int(w * (1 - CROP)), int(h * (1 - CROP))))
    a = np.asarray(cropped.resize((GRID[0] * 20, GRID[1] * 20), Image.Resampling.BOX), np.float32) / 255
    lin = srgb_to_linear(a).reshape(GRID[1], 20, GRID[0], 20, 3).mean((1, 3))
    return calibration.srgb_to_lab(linear_to_srgb(lin).astype(np.float32)), lin


def luminance_quarter(image: Image.Image) -> np.ndarray:
    w, h = image.size
    a = np.asarray(image.resize((w // 8, h // 8), Image.Resampling.BOX), np.float32) / 255
    return srgb_to_linear(a) @ LUMA


def align_scale(reference: Image.Image, render: Image.Image) -> tuple[Image.Image, float, float]:
    """自前レンダーを一様倍率で拡大し中央を切り出して、参照と最も相関する倍率を選ぶ。"""
    W, H = reference.size
    if render.size != reference.size:
        render = render.resize((W, H), Image.Resampling.BILINEAR)
    ref_l = luminance_quarter(reference)
    ref0 = ref_l - ref_l.mean()
    best = None
    for scale in np.arange(0.98, 1.081, 0.0025):
        w2, h2 = int(round(W * scale)), int(round(H * scale))
        scaled = render.resize((w2, h2), Image.Resampling.BILINEAR)
        x0, y0 = (w2 - W) // 2, (h2 - H) // 2
        if x0 < 0 or y0 < 0:
            continue
        candidate = scaled.crop((x0, y0, x0 + W, y0 + H))
        l = luminance_quarter(candidate)
        l0 = l - l.mean()
        corr = float((ref0 * l0).sum() / np.sqrt((ref0**2).sum() * (l0**2).sum()))
        if best is None or corr > best[1]:
            best = (candidate, corr, float(scale))
    return best[0], best[2], best[1]


def region_masks() -> dict[str, np.ndarray]:
    yy, xx = np.mgrid[0 : GRID[1], 0 : GRID[0]]
    r = np.hypot((xx - (GRID[0] - 1) / 2) / ((GRID[0] - 1) / 2), (yy - (GRID[1] - 1) / 2) / ((GRID[1] - 1) / 2)) / np.sqrt(2)
    return {"center": r < 0.4, "middle": (r >= 0.4) & (r < 0.7), "edge": r >= 0.7}


def compare_pair(reference: Image.Image, render: Image.Image, align: bool) -> dict:
    scale, corr = 1.0, None
    if align:
        render, scale, corr = align_scale(reference, render)
    elif render.size != reference.size:
        render = render.resize(reference.size, Image.Resampling.BILINEAR)
    ref_lab, ref_lin = grid_cells(reference)
    out_lab, out_lin = grid_cells(render)
    delta = calibration.delta_e_2000(out_lab, ref_lab)
    ev = np.log2(np.clip(out_lin @ LUMA, 1e-4, None) / np.clip(ref_lin @ LUMA, 1e-4, None))
    chroma_ratio = np.linalg.norm(out_lab[..., 1:], axis=-1).mean() / max(np.linalg.norm(ref_lab[..., 1:], axis=-1).mean(), 1e-6)
    result = {
        "alignScale": round(scale, 4),
        "alignCorrelation": None if corr is None else round(corr, 4),
        "meanDeltaE00": round(float(delta.mean()), 3),
        "p95DeltaE00": round(float(np.percentile(delta, 95)), 3),
        "maxDeltaE00": round(float(delta.max()), 3),
        "meanEV": round(float(ev.mean()), 4),
        "meanLstarDiff": round(float((out_lab[..., 0] - ref_lab[..., 0]).mean()), 3),
        "chromaRatio": round(float(chroma_ratio), 4),
        "regions": {},
    }
    for name, mask in region_masks().items():
        result["regions"][name] = {
            "meanDeltaE00": round(float(delta[mask].mean()), 3),
            "meanEV": round(float(ev[mask].mean()), 4),
        }
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--reference", required=True, type=Path)
    parser.add_argument("--renders", required=True, type=Path)
    parser.add_argument("--reference-suffix", default="", help="例: -2（プリセット適用後のLR書き出しと比較）")
    parser.add_argument("--no-align", action="store_true", help="幾何が揃っているとき倍率合わせを省く")
    parser.add_argument("--gate-mean", type=float, default=2.0)
    parser.add_argument("--gate-ev", type=float, default=0.05)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()

    results: dict[str, dict] = {}
    for render_path in sorted(args.renders.iterdir()):
        if render_path.suffix.lower() not in {".jpg", ".jpeg", ".png", ".tif", ".tiff"}:
            continue
        match = re.match(r"([A-Za-z0-9]+?)(?:[-_.]|$)", render_path.stem)
        scene = match.group(1) if match else render_path.stem
        reference = args.reference / f"{scene}{args.reference_suffix}.jpg"
        if not reference.exists():
            print(f"skip {render_path.name}: 参照 {reference.name} が無い")
            continue
        results[render_path.stem] = compare_pair(load(reference), load(render_path), align=not args.no_align)

    passed = True
    print(f"{'render':<32}{'scale':>7}{'meanΔE':>8}{'p95ΔE':>8}{'EV':>8}{'chroma':>8}  center/middle/edge ΔE")
    for name, r in results.items():
        ok = r["meanDeltaE00"] <= args.gate_mean and abs(r["meanEV"]) <= args.gate_ev
        passed &= ok
        regions = "/".join(f"{r['regions'][k]['meanDeltaE00']:.2f}" for k in ("center", "middle", "edge"))
        print(f"{name:<32}{r['alignScale']:>7.3f}{r['meanDeltaE00']:>8.2f}{r['p95DeltaE00']:>8.2f}{r['meanEV']:>+8.3f}{r['chromaRatio']:>8.3f}  {regions}  {'OK' if ok else 'NG'}")
    print("GATE", "PASS" if passed and results else "FAIL")
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps({"gate": {"meanDeltaE00": args.gate_mean, "meanEV": args.gate_ev}, "passed": passed, "results": results}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
