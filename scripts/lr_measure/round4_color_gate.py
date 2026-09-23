#!/usr/bin/env python3
"""round4 gate (night の色の分解、Red/Orange の HSL スイープ): 5 scene × 14 variant を
`photobench-render` で描画し、`exports/lr-measure/round4/lr-export-photos/p4_<scene>_<variant>.jpg`
と比較する（`compare_renders.py --no-align`）。

描画は元 RAW ＋ round4 のサイドカー XMP（`round4-photos/p4_<scene>_<variant>.xmp`）を `--preset` で渡す。
`--env KEY=VALUE` で実験フック（`PHOTO_BENCH_CALIBRATION_POSITION` など）を上書きできる。指定しない
`PHOTO_BENCH_*` は消してから描画する（既定の挙動を測るため）。

Usage:
  python3 scripts/lr_measure/round4_color_gate.py --out-dir .photobench/phase5/round4/baseline
  python3 scripts/lr_measure/round4_color_gate.py --out-dir .photobench/phase5/round4/cal-prelook \\
      --variants cal_only night_wb_cal --env PHOTO_BENCH_CALIBRATION_POSITION=pre-look
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
ROUND = ROOT / "exports/lr-measure/round4"
REFERENCE = ROOT / "exports/editing-mvp-20260922/lightroom-reference"
RAW_SCENES = {
    "P1013558": REFERENCE / "P1013558.RW2",
    "P1013207": REFERENCE / "P1013207.RW2",
    "P1012822": REFERENCE / "P1012822.RW2",
    "P1524180": ROOT / "P1524180.RW2",
    "P1581215": ROOT / "exports/lr-measure/round2/extra-raw/P1581215.RW2",
}


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def all_variants() -> list[str]:
    manifest = json.loads((ROUND / "manifest.json").read_text())
    seen: list[str] = []
    for entry in manifest:
        if entry["variant"] not in seen:
            seen.append(entry["variant"])
    return seen


def wait_for_other_renders(max_wait_s: float = 900.0) -> None:
    """同じ機械の別作業ツリーの photobench-render（速度計測など）が走っている間は描画を始めない。"""
    import time
    own = str(RENDER_BIN)
    waited = 0.0
    while waited < max_wait_s:
        ps = subprocess.run(["pgrep", "-fl", "photobench-render|PhotoBenchBenchmark"], capture_output=True, text=True).stdout
        others = [line for line in ps.splitlines() if own not in line and "pgrep" not in line]
        if not others:
            return
        time.sleep(2.0)
        waited += 2.0


def render_one(raw: Path, xmp: Path, out_dir: Path, env_overrides: dict[str, str]) -> str | None:
    out_dir.mkdir(parents=True, exist_ok=True)
    wait_for_other_renders()
    env = {k: v for k, v in os.environ.items() if not k.startswith("PHOTO_BENCH_")}
    env.update(env_overrides)
    proc = subprocess.run(
        [str(RENDER_BIN), str(raw), "--output-dir", str(out_dir), "--preset", str(xmp)],
        capture_output=True, text=True, env=env,
    )
    return None if proc.returncode == 0 else f"{raw.name}/{xmp.name}: {proc.stderr.strip()[-400:]}"


def compare(reference_dir: Path, renders_dir: Path, out_json: Path) -> dict | None:
    proc = subprocess.run(
        [sys.executable, str(COMPARE), "--reference", str(reference_dir), "--renders", str(renders_dir),
         "--no-align", "--out", str(out_json)],
        capture_output=True, text=True,
    )
    if proc.returncode != 0 or not out_json.exists():
        log(f"compare failed {renders_dir}: {proc.stderr.strip()[-400:]}")
        return None
    return json.loads(out_json.read_text())


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("--variants", nargs="*", default=None, help="既定は manifest の全 14 variant")
    parser.add_argument("--scenes", nargs="*", default=None, help="既定は 5 scene 全部")
    parser.add_argument("--env", action="append", default=[], help="KEY=VALUE（複数可）")
    parser.add_argument("--workers", type=int, default=2)
    args = parser.parse_args()

    env_overrides = dict(item.split("=", 1) for item in args.env)
    variants = args.variants or all_variants()
    scenes = args.scenes or list(RAW_SCENES)
    out_root = ROOT / args.out_dir
    out_root.mkdir(parents=True, exist_ok=True)

    jobs = []
    for variant in variants:
        for scene in scenes:
            xmp = ROUND / "round4-photos" / f"p4_{scene}_{variant}.xmp"
            if not xmp.exists():
                log(f"missing xmp: {xmp}")
                continue
            jobs.append((RAW_SCENES[scene], xmp, out_root / "renders" / variant))
    log(f"rendering {len(jobs)} cases, env={env_overrides}")
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        for err in pool.map(lambda j: render_one(*j, env_overrides), jobs):
            if err:
                log(f"render error: {err}")

    rows = []
    for variant in variants:
        render_dir = out_root / "renders" / variant
        if not render_dir.exists():
            continue
        ref_dir = out_root / "refs" / variant
        ref_dir.mkdir(parents=True, exist_ok=True)
        for scene in scenes:
            link = ref_dir / f"{scene}.jpg"
            src = ROUND / "lr-export-photos" / f"p4_{scene}_{variant}.jpg"
            if src.exists() and not link.exists():
                link.symlink_to(src)
        data = compare(ref_dir, render_dir, out_root / "compare" / f"{variant}.json")
        for name, r in (data or {}).get("results", {}).items():
            rows.append({
                "variant": variant, "scene": name.split("_")[0].split("-")[0].split(".")[0],
                "meanDeltaE00": r["meanDeltaE00"], "p95DeltaE00": r["p95DeltaE00"],
                "meanEV": r["meanEV"], "chromaRatio": r["chromaRatio"],
            })

    (out_root / "summary.json").write_text(json.dumps({"env": env_overrides, "rows": rows}, indent=2))
    print(f"{'variant':<34}" + "".join(f"{s:>10}" for s in scenes) + f"{'mean':>8}")
    for variant in variants:
        vals = {r["scene"]: r["meanDeltaE00"] for r in rows if r["variant"] == variant}
        if not vals:
            continue
        cells = "".join(f"{vals.get(s, float('nan')):>10.2f}" for s in scenes)
        print(f"{variant:<34}{cells}{sum(vals.values()) / len(vals):>8.2f}")


if __name__ == "__main__":
    main()
