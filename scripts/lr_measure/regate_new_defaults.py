#!/usr/bin/env python3
"""Re-gates the 3 groups `run_gate.py` doesn't already cover (c2-gate
subset, non-RAW round0 4 cases, 4 presets x 2 scenes), with a **clean
environment** -- no `PHOTO_BENCH_*` vars set at all -- to measure the new
production defaults (RAW `pre-tone` + kH/kS 0.5/0.8 gain scale, non-RAW
`s-p1-p2`, Calibration unchanged after cube Q, piecewise Dehaze, re-fit HSL
Blue luminance). `run_gate.py` itself (unmodified) covers c3-gate's 8
variants x 3 scenes and c4-gate's 5 variants x 3 scenes, since both already
default to exactly those case sets and now need no env-var override either.

Usage: python3 scripts/lr_measure/regate_new_defaults.py --out-dir .photobench/phase2/regate-new-defaults
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

RAW_SCENES = {
    "P1013558": ROOT / "exports/editing-mvp-20260922/lightroom-reference/P1013558.RW2",
    "P1013207": ROOT / "exports/editing-mvp-20260922/lightroom-reference/P1013207.RW2",
    "P1012822": ROOT / "exports/editing-mvp-20260922/lightroom-reference/P1012822.RW2",
}
C2_GATE_DIR = ROOT / ".photobench/phase2/c2-gate"
REF_PATTERN = "exports/lr-measure/round1/lr-export-photos/p1_{scene}_{variant}.jpg"
ROUND0_SINGLE_SCENE = {
    "only-calibration": ROOT / "exports/lr-measure/round0/lr-export/r0_raw_only-calibration.jpg",
    "only-hsl": ROOT / "exports/lr-measure/round0/lr-export/r0_raw_only-hsl.jpg",
}
THREE_SCENE_VARIANTS = ["LuminanceAdjustmentBlue_+60"]
SINGLE_SCENE_VARIANTS = ["only-calibration", "only-hsl"]

NONRAW_GATE_DIR = ROOT / ".photobench/phase2/nonraw-gate"
NONRAW_INPUT = ROOT / "exports/lr-measure/round0/input/r0_jpg_neutral.jpg"
NONRAW_VARIANTS = ["only-highlights", "only-shadows", "only-blacks", "tone-all"]
NONRAW_REF = {
    "only-highlights": ROOT / ".photobench/phase2/nonraw-gate-results/ref-only-highlights",
    "only-shadows": ROOT / ".photobench/phase2/nonraw-gate-results/ref-only-shadows",
    "only-blacks": ROOT / ".photobench/phase2/nonraw-gate-results/ref-only-blacks",
    "tone-all": ROOT / ".photobench/phase2/nonraw-gate-results/ref-tone-all",
}

PRESET_SCENES = {"P1524180": (ROOT / "P1524180.RW2", None), "DSC02072": (ROOT / "DSC02072.JPG", "coreimage")}
PRESET_NAMES = ["bluesky2", "colorful", "night", "pastel"]
PRESET_XMP = {
    "bluesky2": ROOT / "niho-preset bluesky2.xmp",
    "colorful": ROOT / "niho-priset_colorful.xmp",
    "night": ROOT / "niho-preset night.xmp",
    "pastel": ROOT / "niho-preset pastel.xmp",
}
PRESET_REF_DIR = ROOT / ".photobench/phase2/c4-preset-gate/references"


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def render_one(raw_path: Path, xmp_path: Path, out_dir: Path, engine: str | None, gain_scale: str | None = None, adaptive_version: str | None = None) -> tuple[bool, str]:
    out_dir.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    for key in ("PHOTO_BENCH_SPATIAL_ORDER", "PHOTO_BENCH_SPATIAL_GAIN_SCALE", "PHOTO_BENCH_CALIBRATION_FIRST"):
        env.pop(key, None)  # clean environment by default: exercise the new *defaults*, not any override
    if gain_scale:
        env["PHOTO_BENCH_SPATIAL_GAIN_SCALE"] = gain_scale
    if adaptive_version:
        env["PHOTO_BENCH_SPATIAL_ADAPTIVE"] = adaptive_version
    cmd = [str(RENDER_BIN), str(raw_path), "--output-dir", str(out_dir), "--preset", str(xmp_path)]
    if engine:
        cmd += ["--engine", engine]
    proc = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if proc.returncode != 0:
        return False, f"{raw_path.name}/{xmp_path.name}: {proc.stderr.strip()[-400:]}"
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
    parser.add_argument("--out-dir", default=".photobench/phase2/regate-new-defaults")
    parser.add_argument("--gain-scale", default=None, help="force PHOTO_BENCH_SPATIAL_GAIN_SCALE (e.g. for a fixed-kS baseline comparison)")
    parser.add_argument("--adaptive-version", default=None, help="set PHOTO_BENCH_SPATIAL_ADAPTIVE (v2 / shift-refit / shift-v2ks)")
    args = parser.parse_args()
    out_root = ROOT / args.out_dir
    out_root.mkdir(parents=True, exist_ok=True)

    jobs = []  # (group, scene, variant, raw_path, xmp, render_dir, engine)
    for variant in THREE_SCENE_VARIANTS:
        xmp = C2_GATE_DIR / f"{variant}.xmp"
        for scene, raw_path in RAW_SCENES.items():
            jobs.append(("c2", scene, variant, raw_path, xmp, out_root / "renders" / "c2" / variant, None))
    for variant in SINGLE_SCENE_VARIANTS:
        xmp = C2_GATE_DIR / f"{variant}.xmp"
        jobs.append(("c2", "P1013558", variant, RAW_SCENES["P1013558"], xmp, out_root / "renders" / "c2" / variant, None))
    for variant in NONRAW_VARIANTS:
        xmp = NONRAW_GATE_DIR / f"{variant}.xmp"
        jobs.append(("nonraw", "r0", variant, NONRAW_INPUT, xmp, out_root / "renders" / "nonraw" / variant, "coreimage"))
    for scene, (raw_path, engine) in PRESET_SCENES.items():
        for preset in PRESET_NAMES:
            jobs.append(("preset", scene, preset, raw_path, PRESET_XMP[preset], out_root / "renders" / "presets" / scene / preset, engine))

    log(f"rendering {len(jobs)} cases with a clean environment (no PHOTO_BENCH_* vars)")
    errors = []
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
        futures = [pool.submit(render_one, raw_path, xmp, render_dir, engine, args.gain_scale, args.adaptive_version) for _, _, _, raw_path, xmp, render_dir, engine in jobs]
        for fut in futures:
            ok, err = fut.result()
            if not ok:
                errors.append(err)
    for e in errors:
        log(f"render error: {e}")

    results = {"c2": [], "nonraw": [], "presets": []}

    for variant in THREE_SCENE_VARIANTS:
        render_dir = out_root / "renders" / "c2" / variant
        reference_dir = out_root / "refs" / "c2" / variant
        reference_dir.mkdir(parents=True, exist_ok=True)
        for scene in RAW_SCENES:
            link = reference_dir / f"{scene}.jpg"
            if not link.exists():
                ref_path = ROOT / REF_PATTERN.format(scene=scene, variant=variant)
                if ref_path.exists():
                    link.symlink_to(ref_path)
        data = compare(reference_dir, render_dir, out_root / "compare" / f"c2_{variant}.json")
        if data:
            for scene, r in data.get("results", {}).items():
                results["c2"].append({"variant": variant, "scene": scene, "meanDeltaE00": r["meanDeltaE00"], "meanEV": r["meanEV"]})

    for variant in SINGLE_SCENE_VARIANTS:
        render_dir = out_root / "renders" / "c2" / variant
        reference_dir = out_root / "refs" / "c2" / variant
        reference_dir.mkdir(parents=True, exist_ok=True)
        link = reference_dir / "P1013558.jpg"
        if not link.exists() and ROUND0_SINGLE_SCENE[variant].exists():
            link.symlink_to(ROUND0_SINGLE_SCENE[variant])
        data = compare(reference_dir, render_dir, out_root / "compare" / f"c2_{variant}.json")
        if data:
            r = data.get("results", {}).get("P1013558")
            if r:
                results["c2"].append({"variant": variant, "scene": "P1013558", "meanDeltaE00": r["meanDeltaE00"], "meanEV": r["meanEV"]})

    for variant in NONRAW_VARIANTS:
        render_dir = out_root / "renders" / "nonraw" / variant
        data = compare(NONRAW_REF[variant], render_dir, out_root / "compare" / f"nonraw_{variant}.json")
        if data:
            r = data.get("results", {}).get("r0_jpg_neutral")
            if r:
                results["nonraw"].append({"variant": variant, "meanDeltaE00": r["meanDeltaE00"], "meanEV": r["meanEV"]})

    for scene in PRESET_SCENES:
        for preset in PRESET_NAMES:
            render_dir = out_root / "renders" / "presets" / scene / preset
            reference_dir = PRESET_REF_DIR / scene / preset
            data = compare(reference_dir, render_dir, out_root / "compare" / f"preset_{scene}_{preset}.json")
            if data:
                r = data.get("results", {}).get(scene)
                if r:
                    results["presets"].append({"scene": scene, "preset": preset, "meanDeltaE00": r["meanDeltaE00"], "meanEV": r["meanEV"]})

    (out_root / "summary.json").write_text(json.dumps(results, indent=2))
    log("done")
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
