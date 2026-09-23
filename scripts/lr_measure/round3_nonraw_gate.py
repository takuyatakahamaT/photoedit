#!/usr/bin/env python3
"""round3 non-RAW gate (`.photobench/phase2/nonraw-hs/model.md`): 8 scene x
6 variant (neutral excluded), input is always `r3_<scene>_neutral.jpg`
(--engine coreimage + the variant's XMP), reference is
`exports/lr-measure/round3/lr-export-jpeg/r3_<scene>_<variant>.jpg`.

Usage: python3 scripts/lr_measure/round3_nonraw_gate.py --out-dir .photobench/phase2/regate-round3
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RENDER_BIN = ROOT / ".build/release/photobench-render"
COMPARE = ROOT / "scripts/lr_measure/compare_renders.py"
MAX_WORKERS = 5

SCENES = ["P1012822", "P1013207", "P1013558", "P1524180", "P1581215", "P1581237", "P1581332", "P1581335"]
VARIANTS = ["Highlights2012_-100", "Highlights2012_-50", "Shadows2012_+50", "Shadows2012_+100", "HS_-80_+40", "tone_E+0.8_H-80_S+40_W-50_B+60"]
INPUT_DIR = ROOT / "exports/lr-measure/round3/round3-jpeg"
REF_DIR = ROOT / "exports/lr-measure/round3/lr-export-jpeg"
XMP_DIR = ROOT / ".photobench/phase2/nonraw-hs/xmp"


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def render_one(input_path: Path, xmp_path: Path, out_dir: Path, gain_scale: str | None, shift: str | None, adaptive_version: str | None) -> tuple[bool, str]:
    out_dir.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    for key in ("PHOTO_BENCH_SPATIAL_ORDER", "PHOTO_BENCH_SPATIAL_GAIN_SCALE", "PHOTO_BENCH_SPATIAL_SHIFT", "PHOTO_BENCH_CALIBRATION_FIRST", "PHOTO_BENCH_SPATIAL_ADAPTIVE"):
        env.pop(key, None)
    if gain_scale:
        env["PHOTO_BENCH_SPATIAL_GAIN_SCALE"] = gain_scale
    if shift:
        env["PHOTO_BENCH_SPATIAL_SHIFT"] = shift
    if adaptive_version:
        env["PHOTO_BENCH_SPATIAL_ADAPTIVE"] = adaptive_version
    cmd = [str(RENDER_BIN), str(input_path), "--engine", "coreimage", "--output-dir", str(out_dir), "--preset", str(xmp_path)]
    proc = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if proc.returncode != 0:
        return False, f"{input_path.name}/{xmp_path.name}: {proc.stderr.strip()[-400:]}"
    return True, ""


def compare(reference_dir: Path, renders_dir: Path, out_json: Path) -> dict | None:
    cmd = [sys.executable, str(COMPARE), "--reference", str(reference_dir), "--renders", str(renders_dir), "--out", str(out_json)]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0 or not out_json.exists():
        log(f"compare failed {renders_dir} vs {reference_dir}: {proc.stderr.strip()[-400:]}")
        return None
    return json.loads(out_json.read_text())


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out-dir", default=".photobench/phase2/regate-round3")
    parser.add_argument("--gain-scale", default=None)
    parser.add_argument("--shift", default=None)
    parser.add_argument("--adaptive-version", default=None)
    args = parser.parse_args()
    out_root = ROOT / args.out_dir
    out_root.mkdir(parents=True, exist_ok=True)

    jobs = []
    for variant in VARIANTS:
        xmp = XMP_DIR / f"{variant}.xmp"
        for scene in SCENES:
            input_path = INPUT_DIR / f"r3_{scene}_neutral.jpg"
            render_dir = out_root / "renders" / variant
            jobs.append((scene, variant, input_path, xmp, render_dir))

    log(f"rendering {len(jobs)} cases ({len(SCENES)} scenes x {len(VARIANTS)} variants)")
    errors = []
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
        futures = [
            pool.submit(render_one, input_path, xmp, render_dir, args.gain_scale, args.shift, args.adaptive_version)
            for _, _, input_path, xmp, render_dir in jobs
        ]
        for fut in futures:
            ok, err = fut.result()
            if not ok:
                errors.append(err)
    for e in errors:
        log(f"render error: {e}")

    results = []
    for variant in VARIANTS:
        render_dir = out_root / "renders" / variant
        reference_dir = out_root / "refs" / variant
        reference_dir.mkdir(parents=True, exist_ok=True)
        for scene in SCENES:
            link = reference_dir / f"{scene}.jpg"
            if not link.exists():
                ref_path = REF_DIR / f"r3_{scene}_{variant}.jpg"
                if ref_path.exists():
                    link.symlink_to(ref_path)
        # render_one names its output after the *input* file
        # (r3_<scene>_neutral.jpg), not the scene alone -- rename via symlink
        # so compare_renders.py's scene-extraction regex matches "<scene>".
        for scene in SCENES:
            produced = render_dir / f"r3_{scene}_neutral.jpg"
            aliased = render_dir / f"{scene}.jpg"
            if produced.exists() and not aliased.exists():
                aliased.symlink_to(produced)
        data = compare(reference_dir, render_dir, out_root / "compare" / f"{variant}.json")
        if data:
            for scene, r in data.get("results", {}).items():
                if scene not in SCENES:
                    continue
                results.append({"variant": variant, "scene": scene, "meanDeltaE00": r["meanDeltaE00"], "meanEV": r["meanEV"]})

    (out_root / "summary.json").write_text(json.dumps(results, indent=2))
    log("done")
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
