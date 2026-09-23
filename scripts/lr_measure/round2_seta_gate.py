#!/usr/bin/env python3
"""round2 set A re-gate (`.photobench/phase2/spatial-adaptive/model.md`):
6 scenes x {Shadows2012_+50, Shadows2012_+100, Highlights2012_-80_Shadows2012_+40},
rendered with a **clean environment** (no `PHOTO_BENCH_*` vars) so the new
image-adaptive kS default is what actually runs, against
`exports/lr-measure/round2/lr-export-photos/p2_<scene>_<variant>.jpg`.

Usage: python3 scripts/lr_measure/round2_seta_gate.py --out-dir .photobench/phase2/regate-round2-seta
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
    "P1524180": ROOT / "P1524180.RW2",
    "P1522877": ROOT / "P1522877.RW2",
    "P1524181": ROOT / "P1524181.RW2",
    # 16-scene refit's +10 (`model.md` §8/§9): RAW lives under a different
    # directory than the original 6, XMP/reference under a sibling dir to
    # `round2-photos` (`round2-extra-photos`) but the same `p2_<scene>_
    # <variant>.{xmp,jpg}` naming, so only `RAW_SCENES`/`XMP_DIRS`/`REF_DIRS`
    # need the extra entries -- the render/compare logic below is unchanged.
    "P1581215": ROOT / "exports/lr-measure/round2/extra-raw/P1581215.RW2",
    "P1581237": ROOT / "exports/lr-measure/round2/extra-raw/P1581237.RW2",
    "P1581243": ROOT / "exports/lr-measure/round2/extra-raw/P1581243.RW2",
    "P1581255": ROOT / "exports/lr-measure/round2/extra-raw/P1581255.RW2",
    "P1581256": ROOT / "exports/lr-measure/round2/extra-raw/P1581256.RW2",
    "P1581332": ROOT / "exports/lr-measure/round2/extra-raw/P1581332.RW2",
    "P1581335": ROOT / "exports/lr-measure/round2/extra-raw/P1581335.RW2",
    "P1581346": ROOT / "exports/lr-measure/round2/extra-raw/P1581346.RW2",
    "P1581356": ROOT / "exports/lr-measure/round2/extra-raw/P1581356.RW2",
    "P1581368": ROOT / "exports/lr-measure/round2/extra-raw/P1581368.RW2",
}
EXTRA_SCENES = {
    "P1581215", "P1581237", "P1581243", "P1581255", "P1581256",
    "P1581332", "P1581335", "P1581346", "P1581356", "P1581368",
}
VARIANTS = ["Shadows2012_+50", "Shadows2012_+100", "Highlights2012_-80_Shadows2012_+40"]
XMP_DIR = ROOT / "exports/lr-measure/round2/round2-photos"
XMP_DIR_EXTRA = ROOT / "exports/lr-measure/round2/round2-extra-photos"
REF_DIR = ROOT / "exports/lr-measure/round2/lr-export-photos"


def xmp_path_for(scene: str, variant: str) -> Path:
    base_dir = XMP_DIR_EXTRA if scene in EXTRA_SCENES else XMP_DIR
    return base_dir / f"p2_{scene}_{variant}.xmp"


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def render_one(raw_path: Path, xmp_path: Path, out_dir: Path, gain_scale: str | None) -> tuple[bool, str]:
    out_dir.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    for key in ("PHOTO_BENCH_SPATIAL_ORDER", "PHOTO_BENCH_SPATIAL_GAIN_SCALE", "PHOTO_BENCH_CALIBRATION_FIRST"):
        env.pop(key, None)
    if gain_scale:
        env["PHOTO_BENCH_SPATIAL_GAIN_SCALE"] = gain_scale
    cmd = [str(RENDER_BIN), str(raw_path), "--output-dir", str(out_dir), "--preset", str(xmp_path)]
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
    parser.add_argument("--out-dir", default=".photobench/phase2/regate-round2-seta")
    parser.add_argument("--gain-scale", default=None, help="force PHOTO_BENCH_SPATIAL_GAIN_SCALE (e.g. for a fixed-kS baseline comparison)")
    args = parser.parse_args()
    out_root = ROOT / args.out_dir
    out_root.mkdir(parents=True, exist_ok=True)

    jobs = []
    for variant in VARIANTS:
        for scene, raw_path in RAW_SCENES.items():
            xmp = xmp_path_for(scene, variant)
            render_dir = out_root / "renders" / variant
            jobs.append((scene, variant, raw_path, xmp, render_dir))

    missing = [j for j in jobs if not j[3].exists()]
    for scene, variant, _, xmp, _ in missing:
        log(f"missing xmp, skipping: {scene}/{variant} ({xmp})")
    jobs = [j for j in jobs if j[3].exists()]

    log(f"rendering {len(jobs)} cases with a clean environment (no PHOTO_BENCH_* vars)")
    errors = []
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
        futures = [pool.submit(render_one, raw_path, xmp, render_dir, args.gain_scale) for _, _, raw_path, xmp, render_dir in jobs]
        for fut in futures:
            ok, err = fut.result()
            if not ok:
                errors.append(err)
    for e in errors:
        log(f"render error: {e}")

    results = []
    for variant in VARIANTS:
        render_dir = out_root / "renders" / variant
        if not render_dir.exists():
            continue
        reference_dir = out_root / "refs" / variant
        reference_dir.mkdir(parents=True, exist_ok=True)
        for scene in RAW_SCENES:
            link = reference_dir / f"{scene}.jpg"
            if not link.exists():
                ref_path = REF_DIR / f"p2_{scene}_{variant}.jpg"
                if ref_path.exists():
                    link.symlink_to(ref_path)
        data = compare(reference_dir, render_dir, out_root / "compare" / f"{variant}.json")
        if data:
            for scene, r in data.get("results", {}).items():
                results.append({"variant": variant, "scene": scene, "meanDeltaE00": r["meanDeltaE00"], "meanEV": r["meanEV"]})

    (out_root / "summary.json").write_text(json.dumps(results, indent=2))
    log("done")
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
