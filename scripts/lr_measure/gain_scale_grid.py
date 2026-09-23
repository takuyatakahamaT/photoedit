#!/usr/bin/env python3
"""Gain-scale grid search for `PHOTO_BENCH_SPATIAL_GAIN_SCALE` (kHneg,kHpos,
kSneg,kSpos), run with `PHOTO_BENCH_SPATIAL_ORDER=pre-tone` for RAW inputs
and `s-p1-p2` for non-RAW inputs (the coordinator's new default *candidates*
-- this script never touches Swift defaults, it only sets env vars per
subprocess).

Why: the H/S gain tables (`SpatialToneOps.gainTable*`) were fit with [S] at
its old post-tone-curve position (`p1-s-p2`). Moving [S] to `pre-tone` (RAW)
/ `s-p1-p2` (non-RAW, unchanged) changes what pixel values the remap sees,
so the *shape* of the curve should still be right (same measured model) but
the *amplitude* may need a per-sign scalar correction. This script measures
that on the real engine (`photobench-render` + `compare_renders.py`), not a
Python simulation.

Case inventory (paths confirmed to exist on Studio 2026-09-23):
  H/S-alone training (6 variants x 3 scenes = 18): `.photobench/phase2/
    c3-gate/{Highlights2012_-100,-50,+50, Shadows2012_-50,+50,+100}.xmp` x
    {P1013558,P1013207,P1012822}. NOTE the coordinator's brief calls this
    "12 cases" but enumerates all 6 signed variants (matching `run_gate.py`'s
    own long-standing "12 (brief wording) vs 18 (actual gate set)" footnote)
    -- using all 6 (mixed sign) is what lets this script fit kHneg/kHpos and
    kSneg/kSpos independently in the fine-tune round, so that is what this
    script does; both are reported.
  RAW composite training (3): `tone-all_bluesky2.xmp` x 3 scenes.
  non-RAW training (3): `.photobench/phase2/nonraw-gate/{only-highlights,
    only-shadows,tone-all}.xmp` on `exports/lr-measure/round0/input/
    r0_jpg_neutral.jpg` (--engine coreimage).
  RAW holdout (3): `full_bluesky2.xmp` x 3 scenes.
  preset holdout (8): 4 presets (`niho-preset bluesky2.xmp`, `niho-priset_
    colorful.xmp`, `niho-preset night.xmp`, `niho-preset pastel.xmp`) x 2
    scenes (RAW P1524180.RW2, JPEG DSC02072.JPG via --engine coreimage).

Independence shortcut: H-alone cases have shadows=0 (kS has zero effect on
them) and vice versa, so this script renders the kH sweep and kS sweep once
each (not once per (kH,kS) pair) and only renders the full outer product for
cases where both are simultaneously active (tone-all/full/presets) -- 40 +
40 + 15*16 = 320 renders total for the initial 4x4 grid, instead of a naive
4*4*(18+3+3) = 384 (before even counting holdout, which must be per-combo
either way since it also mixes both).

Usage:
  python3 scripts/lr_measure/gain_scale_grid.py grid \
      --out-dir .photobench/phase2/gain-scale-grid
  python3 scripts/lr_measure/gain_scale_grid.py finetune \
      --center 0.65,0.65,1.0,1.0 --out-dir .photobench/phase2/gain-scale-grid
  python3 scripts/lr_measure/gain_scale_grid.py report \
      --out-dir .photobench/phase2/gain-scale-grid
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
H_VARIANTS = ["Highlights2012_-100", "Highlights2012_-50", "Highlights2012_+50"]
S_VARIANTS = ["Shadows2012_-50", "Shadows2012_+50", "Shadows2012_+100"]
GATE_DIR = ROOT / ".photobench/phase2/c3-gate"
REF_PATTERN = "exports/lr-measure/round1/lr-export-photos/p1_{scene}_{variant}.jpg"
REF_OVERRIDES = {("P1013558", "full_bluesky2"): ROOT / "exports/lr-measure/round0/lr-export/r0_raw_full.jpg"}

NONRAW_GATE_DIR = ROOT / ".photobench/phase2/nonraw-gate"
NONRAW_INPUT = ROOT / "exports/lr-measure/round0/input/r0_jpg_neutral.jpg"
NONRAW_REF = {
    "only-highlights": ROOT / ".photobench/phase2/nonraw-gate-results/ref-only-highlights",
    "only-shadows": ROOT / ".photobench/phase2/nonraw-gate-results/ref-only-shadows",
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

KH_VALUES = [0.5, 0.65, 0.8, 1.0]
KS_VALUES = [0.6, 0.8, 1.0, 1.2]


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def render_one(raw_path: Path, xmp_path: Path, out_dir: Path, order: str, gain_scale: str, engine: str | None) -> tuple[bool, str]:
    out_dir.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["PHOTO_BENCH_SPATIAL_ORDER"] = order
    env["PHOTO_BENCH_SPATIAL_GAIN_SCALE"] = gain_scale
    cmd = [str(RENDER_BIN), str(raw_path), "--output-dir", str(out_dir), "--preset", str(xmp_path)]
    if engine:
        cmd += ["--engine", engine]
    proc = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if proc.returncode != 0:
        return False, f"{raw_path.name}/{xmp_path.name}: {proc.stderr.strip()[-400:]}"
    return True, ""


def compare(reference_dir: Path, renders_dir: Path, out_json: Path) -> dict | None:
    if not reference_dir.exists() or not any(renders_dir.iterdir()) if renders_dir.exists() else True:
        pass
    cmd = [sys.executable, str(COMPARE), "--reference", str(reference_dir), "--renders", str(renders_dir), "--out", str(out_json)]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0 or not out_json.exists():
        log(f"compare failed {renders_dir} vs {reference_dir}: {proc.stderr.strip()[-400:]}")
        return None
    return json.loads(out_json.read_text())


def gain_scale_str(kh_neg: float, kh_pos: float, ks_neg: float, ks_pos: float) -> str:
    return f"{kh_neg},{kh_pos},{ks_neg},{ks_pos}"


def run_h_sweep(out_root: Path, kh: float) -> dict:
    """Renders H_VARIANTS x 3 RAW scenes + non-RAW only-highlights at this kh
    (kS pinned at 1.0, irrelevant since shadows=0 in every one of these
    cases). Returns {"cases": [{scene,variant,meanDeltaE00,meanEV}], "raw_avg":
    ..., "nonraw": {...}}."""
    tag = f"kh_{kh}"
    gs = gain_scale_str(kh, kh, 1.0, 1.0)
    jobs = []
    for variant in H_VARIANTS:
        xmp = GATE_DIR / f"{variant}.xmp"
        render_dir = out_root / "renders" / tag / variant
        for scene, raw_path in RAW_SCENES.items():
            jobs.append(("raw", scene, variant, raw_path, xmp, render_dir, "pre-tone", None))
    nonraw_xmp = NONRAW_GATE_DIR / "only-highlights.xmp"
    nonraw_render_dir = out_root / "renders" / tag / "nonraw-only-highlights"
    jobs.append(("nonraw", "r0", "only-highlights", NONRAW_INPUT, nonraw_xmp, nonraw_render_dir, "s-p1-p2", "coreimage"))

    errors = []
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
        futures = {pool.submit(render_one, raw_path, xmp, render_dir, order, gs, engine): (kind, scene, variant)
                   for kind, scene, variant, raw_path, xmp, render_dir, order, engine in jobs}
        for fut in futures:
            ok, err = fut.result()
            if not ok:
                errors.append(err)
    for e in errors:
        log(f"[h_sweep kh={kh}] render error: {e}")

    cases = []
    for variant in H_VARIANTS:
        render_dir = out_root / "renders" / tag / variant
        reference_dir = out_root / "refs" / variant
        reference_dir.mkdir(parents=True, exist_ok=True)
        for scene in RAW_SCENES:
            link = reference_dir / f"{scene}.jpg"
            if not link.exists():
                ref_rel = REF_OVERRIDES.get((scene, variant), ROOT / REF_PATTERN.format(scene=scene, variant=variant))
                if Path(ref_rel).exists():
                    link.symlink_to(ref_rel)
        data = compare(reference_dir, render_dir, out_root / "compare" / f"{tag}_{variant}.json")
        if data:
            for scene, r in data.get("results", {}).items():
                cases.append({"scene": scene, "variant": variant, "meanDeltaE00": r["meanDeltaE00"], "meanEV": r["meanEV"]})

    nonraw_ref = NONRAW_REF["only-highlights"]
    nonraw_data = compare(nonraw_ref, nonraw_render_dir, out_root / "compare" / f"{tag}_nonraw_only-highlights.json")
    nonraw_case = None
    if nonraw_data:
        r = nonraw_data.get("results", {}).get("r0_jpg_neutral")
        if r:
            nonraw_case = {"meanDeltaE00": r["meanDeltaE00"], "meanEV": r["meanEV"]}

    return {"kh": kh, "cases": cases, "nonraw_only_highlights": nonraw_case}


def run_s_sweep(out_root: Path, ks: float) -> dict:
    tag = f"ks_{ks}"
    gs = gain_scale_str(1.0, 1.0, ks, ks)
    jobs = []
    for variant in S_VARIANTS:
        xmp = GATE_DIR / f"{variant}.xmp"
        render_dir = out_root / "renders" / tag / variant
        for scene, raw_path in RAW_SCENES.items():
            jobs.append((scene, variant, raw_path, xmp, render_dir, "pre-tone", None))
    nonraw_xmp = NONRAW_GATE_DIR / "only-shadows.xmp"
    nonraw_render_dir = out_root / "renders" / tag / "nonraw-only-shadows"
    jobs.append(("r0", "only-shadows", NONRAW_INPUT, nonraw_xmp, nonraw_render_dir, "s-p1-p2", "coreimage"))

    errors = []
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
        futures = []
        for scene, variant, raw_path, xmp, render_dir, order, engine in jobs:
            futures.append(pool.submit(render_one, raw_path, xmp, render_dir, order, gs, engine))
        for fut in futures:
            ok, err = fut.result()
            if not ok:
                errors.append(err)
    for e in errors:
        log(f"[s_sweep ks={ks}] render error: {e}")

    cases = []
    for variant in S_VARIANTS:
        render_dir = out_root / "renders" / tag / variant
        reference_dir = out_root / "refs" / variant
        reference_dir.mkdir(parents=True, exist_ok=True)
        for scene in RAW_SCENES:
            link = reference_dir / f"{scene}.jpg"
            if not link.exists():
                ref_rel = REF_OVERRIDES.get((scene, variant), ROOT / REF_PATTERN.format(scene=scene, variant=variant))
                if Path(ref_rel).exists():
                    link.symlink_to(ref_rel)
        data = compare(reference_dir, render_dir, out_root / "compare" / f"{tag}_{variant}.json")
        if data:
            for scene, r in data.get("results", {}).items():
                cases.append({"scene": scene, "variant": variant, "meanDeltaE00": r["meanDeltaE00"], "meanEV": r["meanEV"]})

    nonraw_ref = NONRAW_REF["only-shadows"]
    nonraw_data = compare(nonraw_ref, nonraw_render_dir, out_root / "compare" / f"{tag}_nonraw_only-shadows.json")
    nonraw_case = None
    if nonraw_data:
        r = nonraw_data.get("results", {}).get("r0_jpg_neutral")
        if r:
            nonraw_case = {"meanDeltaE00": r["meanDeltaE00"], "meanEV": r["meanEV"]}

    return {"ks": ks, "cases": cases, "nonraw_only_shadows": nonraw_case}


def run_joint(out_root: Path, kh: float, ks: float) -> dict:
    """tone-all_bluesky2 (RAW training, 3 scenes) + nonraw tone-all (training,
    1) + full_bluesky2 (RAW holdout, 3) + 4 presets x 2 scenes (holdout, 8)."""
    tag = f"kh_{kh}_ks_{ks}"
    gs = gain_scale_str(kh, kh, ks, ks)
    jobs = []
    for variant in ("tone-all_bluesky2", "full_bluesky2"):
        xmp = GATE_DIR / f"{variant}.xmp"
        render_dir = out_root / "renders" / tag / variant
        for scene, raw_path in RAW_SCENES.items():
            jobs.append((raw_path, xmp, render_dir, "pre-tone", None))
    nonraw_xmp = NONRAW_GATE_DIR / "tone-all.xmp"
    nonraw_render_dir = out_root / "renders" / tag / "nonraw-tone-all"
    jobs.append((NONRAW_INPUT, nonraw_xmp, nonraw_render_dir, "s-p1-p2", "coreimage"))
    for scene, (raw_path, engine) in PRESET_SCENES.items():
        order = "pre-tone" if engine is None else "s-p1-p2"
        for preset in PRESET_NAMES:
            render_dir = out_root / "renders" / tag / "presets" / scene / preset
            jobs.append((raw_path, PRESET_XMP[preset], render_dir, order, engine))

    errors = []
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
        futures = [pool.submit(render_one, raw_path, xmp, render_dir, order, gs, engine)
                   for raw_path, xmp, render_dir, order, engine in jobs]
        for fut in futures:
            ok, err = fut.result()
            if not ok:
                errors.append(err)
    for e in errors:
        log(f"[joint kh={kh} ks={ks}] render error: {e}")

    result = {"kh": kh, "ks": ks, "tone_all_raw": [], "nonraw_tone_all": None, "full_bluesky2": [], "presets": []}
    for variant, bucket in (("tone-all_bluesky2", "tone_all_raw"), ("full_bluesky2", "full_bluesky2")):
        render_dir = out_root / "renders" / tag / variant
        reference_dir = out_root / "refs" / variant
        reference_dir.mkdir(parents=True, exist_ok=True)
        for scene in RAW_SCENES:
            link = reference_dir / f"{scene}.jpg"
            if not link.exists():
                ref_rel = REF_OVERRIDES.get((scene, variant), ROOT / REF_PATTERN.format(scene=scene, variant=variant))
                if Path(ref_rel).exists():
                    link.symlink_to(ref_rel)
        data = compare(reference_dir, render_dir, out_root / "compare" / f"{tag}_{variant}.json")
        if data:
            for scene, r in data.get("results", {}).items():
                result[bucket].append({"scene": scene, "meanDeltaE00": r["meanDeltaE00"], "meanEV": r["meanEV"]})

    nonraw_data = compare(NONRAW_REF["tone-all"], nonraw_render_dir, out_root / "compare" / f"{tag}_nonraw_tone-all.json")
    if nonraw_data:
        r = nonraw_data.get("results", {}).get("r0_jpg_neutral")
        if r:
            result["nonraw_tone_all"] = {"meanDeltaE00": r["meanDeltaE00"], "meanEV": r["meanEV"]}

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


def mean(values: list[float]) -> float | None:
    return sum(values) / len(values) if values else None


def summarize_combo(h_data: dict, s_data: dict, joint: dict) -> dict:
    h_cases = [c["meanDeltaE00"] for c in h_data["cases"]]
    h_ev = [c["meanEV"] for c in h_data["cases"]]
    s_cases = [c["meanDeltaE00"] for c in s_data["cases"]]
    s_ev = [c["meanEV"] for c in s_data["cases"]]
    tone_all_de = [c["meanDeltaE00"] for c in joint["tone_all_raw"]]
    tone_all_ev = [c["meanEV"] for c in joint["tone_all_raw"]]
    nonraw_train_de = [x["meanDeltaE00"] for x in (h_data["nonraw_only_highlights"], s_data["nonraw_only_shadows"], joint["nonraw_tone_all"]) if x]
    nonraw_train_ev = [x["meanEV"] for x in (h_data["nonraw_only_highlights"], s_data["nonraw_only_shadows"], joint["nonraw_tone_all"]) if x]

    train_de_all = h_cases + s_cases + tone_all_de + nonraw_train_de
    train_ev_all = h_ev + s_ev + tone_all_ev + nonraw_train_ev

    full_de = [c["meanDeltaE00"] for c in joint["full_bluesky2"]]
    full_ev = [c["meanEV"] for c in joint["full_bluesky2"]]
    preset_de = [c["meanDeltaE00"] for c in joint["presets"]]
    preset_ev = [c["meanEV"] for c in joint["presets"]]
    holdout_de_all = full_de + preset_de
    holdout_ev_all = full_ev + preset_ev

    return {
        "kh": joint["kh"], "ks": joint["ks"],
        "trainAvgMeanDeltaE00": mean(train_de_all), "trainAvgMeanEV": mean(train_ev_all), "trainCaseCount": len(train_de_all),
        "holdoutAvgMeanDeltaE00": mean(holdout_de_all), "holdoutAvgMeanEV": mean(holdout_ev_all), "holdoutCaseCount": len(holdout_de_all),
        "breakdown": {
            "hAloneAvgMeanDeltaE00": mean(h_cases), "hAloneAvgMeanEV": mean(h_ev),
            "sAloneAvgMeanDeltaE00": mean(s_cases), "sAloneAvgMeanEV": mean(s_ev),
            "toneAllRawAvgMeanDeltaE00": mean(tone_all_de), "toneAllRawAvgMeanEV": mean(tone_all_ev),
            "nonrawTrainAvgMeanDeltaE00": mean(nonraw_train_de), "nonrawTrainAvgMeanEV": mean(nonraw_train_ev),
            "fullBluesky2AvgMeanDeltaE00": mean(full_de), "fullBluesky2AvgMeanEV": mean(full_ev),
            "presetsAvgMeanDeltaE00": mean(preset_de), "presetsAvgMeanEV": mean(preset_ev),
        },
    }


def cmd_grid(args: argparse.Namespace) -> None:
    kh_values = [float(x) for x in args.kh_values.split(",")] if args.kh_values else KH_VALUES
    ks_values = [float(x) for x in args.ks_values.split(",")] if args.ks_values else KS_VALUES
    out_root = ROOT / args.out_dir
    out_root.mkdir(parents=True, exist_ok=True)
    h_results = {}
    for kh in kh_values:
        log(f"=== H sweep kh={kh} ===")
        h_results[kh] = run_h_sweep(out_root, kh)
        (out_root / "h_sweep.json").write_text(json.dumps({str(k): v for k, v in h_results.items()}, indent=2))
    s_results = {}
    for ks in ks_values:
        log(f"=== S sweep ks={ks} ===")
        s_results[ks] = run_s_sweep(out_root, ks)
        (out_root / "s_sweep.json").write_text(json.dumps({str(k): v for k, v in s_results.items()}, indent=2))

    combos = []
    for kh in kh_values:
        for ks in ks_values:
            log(f"=== joint kh={kh} ks={ks} ===")
            joint = run_joint(out_root, kh, ks)
            summary = summarize_combo(h_results[kh], s_results[ks], joint)
            combos.append(summary)
            (out_root / "grid_summary.json").write_text(json.dumps(combos, indent=2))
    log("grid search done")


def cmd_finetune(args: argparse.Namespace) -> None:
    center = [float(x) for x in args.center.split(",")]
    assert len(center) == 4, "--center must be kHneg,kHpos,kSneg,kSpos"
    kh_neg0, kh_pos0, ks_neg0, ks_pos0 = center
    out_root = ROOT / args.out_dir
    out_root.mkdir(parents=True, exist_ok=True)
    delta = 0.1
    axes = {
        "kHneg": [kh_neg0 - delta, kh_neg0, kh_neg0 + delta],
        "kHpos": [kh_pos0 - delta, kh_pos0, kh_pos0 + delta],
        "kSneg": [ks_neg0 - delta, ks_neg0, ks_neg0 + delta],
        "kSpos": [ks_pos0 - delta, ks_pos0, ks_pos0 + delta],
    }
    results = []
    for axis_name, values in axes.items():
        for v in values:
            kh_neg, kh_pos, ks_neg, ks_pos = kh_neg0, kh_pos0, ks_neg0, ks_pos0
            if axis_name == "kHneg":
                kh_neg = v
            elif axis_name == "kHpos":
                kh_pos = v
            elif axis_name == "kSneg":
                ks_neg = v
            else:
                ks_pos = v
            tag = f"ft_{axis_name}_{v}"
            gs = gain_scale_str(kh_neg, kh_pos, ks_neg, ks_pos)
            log(f"=== finetune {axis_name}={v} ({gs}) ===")

            jobs = []
            for variant in H_VARIANTS + S_VARIANTS:
                xmp = GATE_DIR / f"{variant}.xmp"
                render_dir = out_root / "renders" / tag / variant
                for scene, raw_path in RAW_SCENES.items():
                    jobs.append((raw_path, xmp, render_dir, "pre-tone", None))
            for variant in ("tone-all_bluesky2",):
                xmp = GATE_DIR / f"{variant}.xmp"
                render_dir = out_root / "renders" / tag / variant
                for scene, raw_path in RAW_SCENES.items():
                    jobs.append((raw_path, xmp, render_dir, "pre-tone", None))
            nonraw_dirs = {}
            for variant in ("only-highlights", "only-shadows", "tone-all"):
                xmp = NONRAW_GATE_DIR / f"{variant}.xmp"
                render_dir = out_root / "renders" / tag / f"nonraw-{variant}"
                nonraw_dirs[variant] = render_dir
                jobs.append((NONRAW_INPUT, xmp, render_dir, "s-p1-p2", "coreimage"))

            with ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
                futures = [pool.submit(render_one, raw_path, xmp, render_dir, order, gs, engine)
                           for raw_path, xmp, render_dir, order, engine in jobs]
                for fut in futures:
                    ok, err = fut.result()
                    if not ok:
                        log(f"render error: {err}")

            case_de, case_ev = [], []
            for variant in H_VARIANTS + S_VARIANTS + ["tone-all_bluesky2"]:
                render_dir = out_root / "renders" / tag / variant
                reference_dir = out_root / "refs" / variant
                reference_dir.mkdir(parents=True, exist_ok=True)
                for scene in RAW_SCENES:
                    link = reference_dir / f"{scene}.jpg"
                    if not link.exists():
                        ref_rel = REF_OVERRIDES.get((scene, variant), ROOT / REF_PATTERN.format(scene=scene, variant=variant))
                        if Path(ref_rel).exists():
                            link.symlink_to(ref_rel)
                data = compare(reference_dir, render_dir, out_root / "compare" / f"{tag}_{variant}.json")
                if data:
                    for scene, r in data.get("results", {}).items():
                        case_de.append(r["meanDeltaE00"])
                        case_ev.append(r["meanEV"])
            for variant, render_dir in nonraw_dirs.items():
                data = compare(NONRAW_REF[variant], render_dir, out_root / "compare" / f"{tag}_nonraw_{variant}.json")
                if data:
                    r = data.get("results", {}).get("r0_jpg_neutral")
                    if r:
                        case_de.append(r["meanDeltaE00"])
                        case_ev.append(r["meanEV"])

            results.append({
                "axis": axis_name, "value": v,
                "kHneg": kh_neg, "kHpos": kh_pos, "kSneg": ks_neg, "kSpos": ks_pos,
                "trainAvgMeanDeltaE00": mean(case_de), "trainAvgMeanEV": mean(case_ev), "trainCaseCount": len(case_de),
            })
            (out_root / "finetune_summary.json").write_text(json.dumps(results, indent=2))
    log("finetune done")


def cmd_report(args: argparse.Namespace) -> None:
    out_root = ROOT / args.out_dir
    grid_path = out_root / "grid_summary.json"
    if grid_path.exists():
        combos = json.loads(grid_path.read_text())
        lines = ["| kH | kS | train avg dE00 | train avg EV | holdout avg dE00 | holdout avg EV | n_train | n_holdout |",
                 "|---:|---:|---:|---:|---:|---:|---:|---:|"]
        for c in sorted(combos, key=lambda c: (c["kh"], c["ks"])):
            lines.append(f"| {c['kh']} | {c['ks']} | {c['trainAvgMeanDeltaE00']:.3f} | {c['trainAvgMeanEV']:+.3f} | "
                         f"{c['holdoutAvgMeanDeltaE00']:.3f} | {c['holdoutAvgMeanEV']:+.3f} | {c['trainCaseCount']} | {c['holdoutCaseCount']} |")
        print("\n".join(lines))
    ft_path = out_root / "finetune_summary.json"
    if ft_path.exists():
        ft = json.loads(ft_path.read_text())
        print("\n\n| axis | value | train avg dE00 | train avg EV |")
        print("|---|---:|---:|---:|")
        for r in ft:
            print(f"| {r['axis']} | {r['value']} | {r['trainAvgMeanDeltaE00']:.3f} | {r['trainAvgMeanEV']:+.3f} |")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    p_grid = sub.add_parser("grid")
    p_grid.add_argument("--out-dir", default=".photobench/phase2/gain-scale-grid")
    p_grid.add_argument("--kh-values", default=None, help="comma-separated override of KH_VALUES (smoke testing)")
    p_grid.add_argument("--ks-values", default=None, help="comma-separated override of KS_VALUES (smoke testing)")
    p_grid.set_defaults(func=cmd_grid)
    p_ft = sub.add_parser("finetune")
    p_ft.add_argument("--out-dir", default=".photobench/phase2/gain-scale-grid")
    p_ft.add_argument("--center", required=True, help="kHneg,kHpos,kSneg,kSpos")
    p_ft.set_defaults(func=cmd_finetune)
    p_report = sub.add_parser("report")
    p_report.add_argument("--out-dir", default=".photobench/phase2/gain-scale-grid")
    p_report.set_defaults(func=cmd_report)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
