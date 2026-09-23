#!/usr/bin/env python3
"""Compares `PHOTO_BENCH_CALIBRATION_FIRST=1` (Calibration before cube Q)
against today's default (Calibration after cube Q) on the real engine, with
the spatial-order candidates (RAW `pre-tone`, non-RAW `s-p1-p2`) and a fixed
`PHOTO_BENCH_SPATIAL_GAIN_SCALE` (from `gain_scale_grid.py`'s chosen best
point) held constant across both conditions -- isolating the Calibration/
cube-Q ordering as the only variable.

Cases:
  4 presets x 2 scenes (RAW P1524180.RW2, JPEG DSC02072.JPG) -- same XMPs/
    references as `gain_scale_grid.py`'s preset holdout group, including
    "night" (the coordinator's specific suspicion: Calibration fighting an
    already-graded image).
  c2-gate (`.photobench/phase2/c2-gate/`): only-calibration, only-hsl (P1013558
    only, round0 references) and GreenHue_+50, BlueSaturation_+50,
    SaturationAdjustmentOrange_+60, LuminanceAdjustmentBlue_+60 (3 scenes
    each, round1 references) -- none of these touch Highlights/Shadows, so
    the gain-scale/spatial-order settings are no-ops for them; they isolate
    Calibration x cube-Q interaction specifically.

Usage:
  python3 scripts/lr_measure/calibration_order_compare.py \
      --gain-scale 0.65,0.65,1.0,1.0 --out-dir .photobench/phase2/calibration-order-compare
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
THREE_SCENE_VARIANTS = ["GreenHue_+50", "BlueSaturation_+50", "SaturationAdjustmentOrange_+60", "LuminanceAdjustmentBlue_+60"]
SINGLE_SCENE_VARIANTS = ["only-calibration", "only-hsl"]

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


def render_one(raw_path: Path, xmp_path: Path, out_dir: Path, order: str, gain_scale: str, calibration_first: bool, engine: str | None) -> tuple[bool, str]:
    out_dir.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["PHOTO_BENCH_SPATIAL_ORDER"] = order
    env["PHOTO_BENCH_SPATIAL_GAIN_SCALE"] = gain_scale
    if calibration_first:
        env["PHOTO_BENCH_CALIBRATION_FIRST"] = "1"
    else:
        env.pop("PHOTO_BENCH_CALIBRATION_FIRST", None)
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


def run_condition(out_root: Path, gain_scale: str, calibration_first: bool) -> dict:
    tag = "cal_first" if calibration_first else "cal_default"
    jobs = []
    # c2-gate: 3-scene variants
    for variant in THREE_SCENE_VARIANTS:
        xmp = C2_GATE_DIR / f"{variant}.xmp"
        render_dir = out_root / "renders" / tag / variant
        for scene, raw_path in RAW_SCENES.items():
            jobs.append(("c2_3scene", scene, variant, raw_path, xmp, render_dir, "pre-tone", None))
    # c2-gate: single-scene (P1013558) variants
    for variant in SINGLE_SCENE_VARIANTS:
        xmp = C2_GATE_DIR / f"{variant}.xmp"
        render_dir = out_root / "renders" / tag / variant
        jobs.append(("c2_1scene", "P1013558", variant, RAW_SCENES["P1013558"], xmp, render_dir, "pre-tone", None))
    # presets: 4 x 2 scenes
    for scene, (raw_path, engine) in PRESET_SCENES.items():
        order = "pre-tone" if engine is None else "s-p1-p2"
        for preset in PRESET_NAMES:
            render_dir = out_root / "renders" / tag / "presets" / scene / preset
            jobs.append(("preset", scene, preset, raw_path, PRESET_XMP[preset], render_dir, order, engine))

    errors = []
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
        futures = [pool.submit(render_one, raw_path, xmp, render_dir, order, gain_scale, calibration_first, engine)
                   for kind, scene, variant, raw_path, xmp, render_dir, order, engine in jobs]
        for fut in futures:
            ok, err = fut.result()
            if not ok:
                errors.append(err)
    for e in errors:
        log(f"[{tag}] render error: {e}")

    result = {"calibrationFirst": calibration_first, "c2_gate": [], "presets": []}

    for variant in THREE_SCENE_VARIANTS:
        render_dir = out_root / "renders" / tag / variant
        reference_dir = out_root / "refs" / variant
        reference_dir.mkdir(parents=True, exist_ok=True)
        for scene in RAW_SCENES:
            link = reference_dir / f"{scene}.jpg"
            if not link.exists():
                ref_path = ROOT / REF_PATTERN.format(scene=scene, variant=variant)
                if ref_path.exists():
                    link.symlink_to(ref_path)
        data = compare(reference_dir, render_dir, out_root / "compare" / f"{tag}_{variant}.json")
        if data:
            for scene, r in data.get("results", {}).items():
                result["c2_gate"].append({"variant": variant, "scene": scene, "meanDeltaE00": r["meanDeltaE00"], "meanEV": r["meanEV"]})

    for variant in SINGLE_SCENE_VARIANTS:
        render_dir = out_root / "renders" / tag / variant
        reference_dir = out_root / "refs" / variant
        reference_dir.mkdir(parents=True, exist_ok=True)
        link = reference_dir / "P1013558.jpg"
        if not link.exists() and ROUND0_SINGLE_SCENE[variant].exists():
            link.symlink_to(ROUND0_SINGLE_SCENE[variant])
        data = compare(reference_dir, render_dir, out_root / "compare" / f"{tag}_{variant}.json")
        if data:
            r = data.get("results", {}).get("P1013558")
            if r:
                result["c2_gate"].append({"variant": variant, "scene": "P1013558", "meanDeltaE00": r["meanDeltaE00"], "meanEV": r["meanEV"]})

    for scene in PRESET_SCENES:
        for preset in PRESET_NAMES:
            render_dir = out_root / "renders" / tag / "presets" / scene / preset
            reference_dir = PRESET_REF_DIR / scene / preset
            data = compare(reference_dir, render_dir, out_root / "compare" / f"{tag}_preset_{scene}_{preset}.json")
            if data:
                r = data.get("results", {}).get(scene)
                if r:
                    result["presets"].append({"scene": scene, "preset": preset, "meanDeltaE00": r["meanDeltaE00"], "meanEV": r["meanEV"]})
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--gain-scale", required=True, help="kHneg,kHpos,kSneg,kSpos chosen from gain_scale_grid.py")
    parser.add_argument("--out-dir", default=".photobench/phase2/calibration-order-compare")
    args = parser.parse_args()
    out_root = ROOT / args.out_dir
    out_root.mkdir(parents=True, exist_ok=True)

    results = {}
    for calibration_first in (False, True):
        tag = "cal_first" if calibration_first else "cal_default"
        log(f"=== condition {tag} ===")
        results[tag] = run_condition(out_root, args.gain_scale, calibration_first)
        (out_root / "summary.json").write_text(json.dumps(results, indent=2))

    def mean(xs):
        return sum(xs) / len(xs) if xs else None

    lines = ["| case | scene | default dE00 | default EV | cal-first dE00 | cal-first EV |", "|---|---|---:|---:|---:|---:|"]
    default_c2 = {(c["variant"], c["scene"]): c for c in results["cal_default"]["c2_gate"]}
    first_c2 = {(c["variant"], c["scene"]): c for c in results["cal_first"]["c2_gate"]}
    for key in sorted(default_c2):
        d, f = default_c2[key], first_c2.get(key)
        if f:
            lines.append(f"| {key[0]} | {key[1]} | {d['meanDeltaE00']:.3f} | {d['meanEV']:+.3f} | {f['meanDeltaE00']:.3f} | {f['meanEV']:+.3f} |")
    default_p = {(c["scene"], c["preset"]): c for c in results["cal_default"]["presets"]}
    first_p = {(c["scene"], c["preset"]): c for c in results["cal_first"]["presets"]}
    for key in sorted(default_p):
        d, f = default_p[key], first_p.get(key)
        if f:
            lines.append(f"| preset:{key[1]} | {key[0]} | {d['meanDeltaE00']:.3f} | {d['meanEV']:+.3f} | {f['meanDeltaE00']:.3f} | {f['meanEV']:+.3f} |")

    all_default_de = [c["meanDeltaE00"] for c in results["cal_default"]["c2_gate"] + results["cal_default"]["presets"]]
    all_first_de = [c["meanDeltaE00"] for c in results["cal_first"]["c2_gate"] + results["cal_first"]["presets"]]
    lines.append("")
    lines.append(f"overall avg meanDeltaE00: default={mean(all_default_de):.3f} cal-first={mean(all_first_de):.3f}")
    (out_root / "summary.md").write_text("\n".join(lines))
    print("\n".join(lines))


if __name__ == "__main__":
    main()
