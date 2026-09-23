#!/usr/bin/env python3
"""round5 gate: `make_round5.py` の 198 枚（RAW 5 scene × 21 variant、LR 由来 JPEG 5 scene × 9 variant、カメラ JPEG 3 枚 × 16 variant）を描画し、
`exports/lr-measure/round5/lr-export/` の LR 書き出しと比べる（ΔE00・EV・彩度比）。

- RAW: 元 RAW ＋ round5 のサイドカー XMP を `--preset` で渡す。比較は `--no-align`（歪曲補正済みで幾何が揃う）。
- JPEG: round2 の LR 中立 JPEG（camera はカメラ JPEG の原本）を `--engine coreimage` で読み、variant の設定だけの XMP を
  `--preset` で渡す（round3 と同じ方式）。比較は倍率合わせあり。
`--env KEY=VALUE` で実験フックを上書きできる。指定しない `PHOTO_BENCH_*` は消してから描画する。

Usage: python3 scripts/lr_measure/round5_gate.py --out-dir .photobench/phase5/round5/baseline [--kinds raw jpeg] [--variants ...]
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_round5 as R5  # noqa: E402
from make_round0 import minimal_packet  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
RENDER_BIN = ROOT / ".build/release/photobench-render"
COMPARE = ROOT / "scripts/lr_measure/compare_renders.py"


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def wait_for_other_renders(max_wait_s: float = 900.0) -> None:
    """同じ機械の別作業ツリーの photobench-render（速度計測など）が走っている間は描画を始めない。"""
    import time
    own, waited = str(RENDER_BIN), 0.0
    while waited < max_wait_s:
        ps = subprocess.run(["pgrep", "-fl", "photobench-render|PhotoBenchBenchmark"], capture_output=True, text=True).stdout
        if not [line for line in ps.splitlines() if own not in line and "pgrep" not in line]:
            return
        time.sleep(2.0)
        waited += 2.0


def render(src: Path, xmp: Path, out_dir: Path, engine: str | None, env_overrides: dict[str, str]) -> str | None:
    out_dir.mkdir(parents=True, exist_ok=True)
    wait_for_other_renders()
    env = {k: v for k, v in os.environ.items() if not k.startswith("PHOTO_BENCH_")}
    env.update(env_overrides)
    cmd = [str(RENDER_BIN), str(src), "--output-dir", str(out_dir), "--preset", str(xmp)]
    if engine:
        cmd += ["--engine", engine]
    proc = subprocess.run(cmd, capture_output=True, text=True, env=env)
    return None if proc.returncode == 0 else f"{src.name}/{xmp.name}: {proc.stderr.strip()[-300:]}"


def compare(ref_dir: Path, render_dir: Path, out_json: Path, align: bool) -> dict:
    cmd = [sys.executable, str(COMPARE), "--reference", str(ref_dir), "--renders", str(render_dir), "--out", str(out_json)]
    if not align:
        cmd.append("--no-align")
    subprocess.run(cmd, capture_output=True, text=True)
    return json.loads(out_json.read_text()).get("results", {}) if out_json.exists() else {}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("--kinds", nargs="*", default=["raw", "jpeg", "camera"])
    parser.add_argument("--variants", nargs="*", default=None)
    parser.add_argument("--env", action="append", default=[], help="KEY=VALUE（複数可）")
    parser.add_argument("--workers", type=int, default=3)
    args = parser.parse_args()
    env_overrides = dict(item.split("=", 1) for item in args.env)
    out = ROOT / args.out_dir
    manifest = json.loads((R5.ROUND / "manifest.json").read_text())
    xmp_dir = out / "jpeg-xmp"
    xmp_dir.mkdir(parents=True, exist_ok=True)

    jobs = []
    for e in manifest:
        kind = {"raw": "raw", "jpeg-embedded": "jpeg", "camera-jpeg": "camera"}[e["kind"]]
        if kind not in args.kinds or (args.variants and e["variant"] not in args.variants):
            continue
        render_dir = out / "renders" / kind / e["variant"]
        if kind == "raw":
            jobs.append((e, kind, R5.RAW_SCENES[e["scene"]], R5.OUT / e["file"].replace(".RW2", ".xmp"), render_dir, None))
        else:
            attributes, elements = R5.variant_settings(e["variant"])
            xmp = xmp_dir / f"{e['variant']}.xmp"
            if not xmp.exists():
                xmp.write_text(minimal_packet(attributes, elements), encoding="utf-8")
            src = R5.JPEG_SOURCE / e["source"] if kind == "jpeg" else R5.CAMERA_JPEGS[e["scene"]]
            jobs.append((e, kind, src, xmp, render_dir, "coreimage"))
    log(f"rendering {len(jobs)} cases, env={env_overrides}")
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        for err in pool.map(lambda j: render(j[2], j[3], j[4], j[5], env_overrides), jobs):
            if err:
                log(f"render error: {err}")

    rows = []
    for kind in args.kinds:
        variants = sorted({j[0]["variant"] for j in jobs if j[1] == kind})
        for variant in variants:
            render_dir = out / "renders" / kind / variant
            ref_dir = out / "refs" / kind / variant
            ref_dir.mkdir(parents=True, exist_ok=True)
            for e in (j[0] for j in jobs if j[1] == kind and j[0]["variant"] == variant):
                stem = e["file"].rsplit(".", 1)[0]
                link = ref_dir / f"{e['scene']}.jpg"
                src = R5.EXPORT / f"{stem}.jpg"
                if src.exists() and not link.exists():
                    link.symlink_to(src)
            # JPEG の描画ファイル名は入力（p2_<scene>_neutral）由来なので scene 名へ揃える
            if kind == "jpeg" and render_dir.exists():
                for f in render_dir.glob("p2_*_neutral.jpg"):
                    f.rename(render_dir / f"{f.name.split('_')[1]}.jpg")
            results = compare(ref_dir, render_dir, out / "compare" / kind / f"{variant}.json", align=(kind != "raw"))
            for name, r in results.items():
                rows.append({"kind": kind, "variant": variant, "scene": name.split("_")[0].split("-")[0],
                             "meanDeltaE00": r["meanDeltaE00"], "meanEV": r["meanEV"], "chromaRatio": r["chromaRatio"]})
    (out / "summary.json").write_text(json.dumps({"env": env_overrides, "rows": rows}, indent=2))
    for kind in args.kinds:
        scenes = list(R5.CAMERA_JPEGS) if kind == "camera" else list(R5.RAW_SCENES)
        print(f"\n[{kind}] variant" + " " * 22 + "".join(f"{s:>10}" for s in scenes) + f"{'mean':>8}{'EV':>8}{'chroma':>8}")
        for variant in sorted({r["variant"] for r in rows if r["kind"] == kind}):
            sub = [r for r in rows if r["kind"] == kind and r["variant"] == variant]
            vals = {r["scene"]: r["meanDeltaE00"] for r in sub}
            n = len(sub)
            print(f"{variant:<34}" + "".join(f"{vals.get(s, float('nan')):>10.2f}" for s in scenes)
                  + f"{sum(vals.values()) / n:>8.2f}{sum(r['meanEV'] for r in sub) / n:>+8.3f}{sum(r['chromaRatio'] for r in sub) / n:>8.3f}")


if __name__ == "__main__":
    main()
