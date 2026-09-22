#!/usr/bin/env python3
"""Phase2 C3 実写ゲート: `photobench-render` でゲートXMPごとに描画し、
`compare_renders.py` でLightroom参照JPEGと比較して結果をJSON/Markdown表に
まとめる（再利用できるよう scene/variant のマッピングは引数で差し替え可能）。

使い方（既定値はC3のゲート一式: P1013558/P1013207/P1012822 x
Highlights2012{-100,-50,+50}/Shadows2012{-50,+50,+100}/tone-all_bluesky2/
full_bluesky2）:
  python3 scripts/lr_measure/run_gate.py --release

引数で差し替える場合:
  python3 scripts/lr_measure/run_gate.py \
      --gate-dir .photobench/phase2/c3-gate \
      --raw P1013558=exports/editing-mvp-20260922/lightroom-reference/P1013558.RW2 \
      --reference P1013558:Highlights2012_-100=exports/.../p1_P1013558_Highlights2012_-100.jpg \
      --out-dir .photobench/phase2/c3-gate-results
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# --- C3 既定のゲート一式 (ブリーフどおり) -----------------------------------

DEFAULT_SCENES = {
    "P1013558": "exports/editing-mvp-20260922/lightroom-reference/P1013558.RW2",
    "P1013207": "exports/editing-mvp-20260922/lightroom-reference/P1013207.RW2",
    "P1012822": "exports/editing-mvp-20260922/lightroom-reference/P1012822.RW2",
}

# H/S単体ゲート12ケース由来の元4variant（model.mdの実測対象そのもの）と、
# ゲートXMP一式に追加された2variant（H+50, S-50）を分けておく -- 「12ケース」
# 表記と実際に用意された6variant(18ケース)の食い違いをレポートで両方出す。
HS_CORE_VARIANTS = ["Highlights2012_-100", "Highlights2012_-50", "Shadows2012_+50", "Shadows2012_+100"]
HS_EXTRA_VARIANTS = ["Highlights2012_+50", "Shadows2012_-50"]
HS_VARIANTS = HS_CORE_VARIANTS + HS_EXTRA_VARIANTS
COMPOSITE_VARIANTS = ["tone-all_bluesky2", "full_bluesky2"]
ALL_VARIANTS = HS_VARIANTS + COMPOSITE_VARIANTS

DEFAULT_REFERENCE_PATTERN = "exports/lr-measure/round1/lr-export-photos/p1_{scene}_{variant}.jpg"
# full_bluesky2 は round1 に P1013558 分が無い (ブリーフの指示どおり round0 の
# 素の RAW フル書き出しを使う)。
DEFAULT_REFERENCE_OVERRIDES = {
    ("P1013558", "full_bluesky2"): "exports/lr-measure/round0/lr-export/r0_raw_full.jpg",
}

GATE_MEAN_THRESHOLD = 2.3  # H/S単体ケースの領域平均ΔEの平均、ブリーフの合格条件


def parse_kv(pairs: list[str], sep: str = "=") -> dict[str, str]:
    result = {}
    for pair in pairs:
        key, _, value = pair.partition(sep)
        result[key] = value
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--gate-dir", type=Path, default=ROOT / ".photobench/phase2/c3-gate")
    parser.add_argument("--raw", action="append", default=[], help="scene=path (ROOT相対か絶対)。省略時は既定3シーン。")
    parser.add_argument(
        "--reference", action="append", default=[],
        help="scene:variant=path 形式で既定パターンを上書き。"
    )
    parser.add_argument("--reference-pattern", default=DEFAULT_REFERENCE_PATTERN)
    parser.add_argument("--variants", nargs="*", default=None, help="省略時はゲート一式8種類すべて。")
    parser.add_argument("--out-dir", type=Path, default=ROOT / ".photobench/phase2/c3-gate-results")
    parser.add_argument(
        "--render-binary", type=Path,
        default=ROOT / ".build/release/photobench-render"
    )
    parser.add_argument("--no-align", action="store_true")
    parser.add_argument("--skip-render", action="store_true", help="既に描画済みの--out-dirを再利用して比較だけやり直す。")
    args = parser.parse_args()

    scenes = dict(DEFAULT_SCENES)
    scenes.update(parse_kv(args.raw))
    scene_paths = {scene: (ROOT / path if not Path(path).is_absolute() else Path(path)) for scene, path in scenes.items()}

    reference_overrides = dict(DEFAULT_REFERENCE_OVERRIDES)
    for raw_pair in args.reference:
        key, _, path = raw_pair.partition("=")
        scene, _, variant = key.partition(":")
        reference_overrides[(scene, variant)] = path

    variants = args.variants or ALL_VARIANTS
    render_binary = args.render_binary if args.render_binary.is_absolute() else ROOT / args.render_binary
    if not render_binary.exists() and not args.skip_render:
        sys.exit(f"エラー: {render_binary} がありません。先に `swift build -c release --product photobench-render` を実行してください。")

    args.out_dir.mkdir(parents=True, exist_ok=True)
    compare_script = ROOT / "scripts/lr_measure/compare_renders.py"

    render_log: list[str] = []
    variant_results: dict[str, dict] = {}

    for variant in variants:
        xmp_path = args.gate_dir / f"{variant}.xmp"
        if not xmp_path.exists():
            print(f"skip {variant}: {xmp_path} が無い", file=sys.stderr)
            continue

        render_dir = args.out_dir / "renders" / variant
        reference_dir = args.out_dir / "references" / variant
        render_dir.mkdir(parents=True, exist_ok=True)
        reference_dir.mkdir(parents=True, exist_ok=True)

        for scene, raw_path in scene_paths.items():
            reference_relative = reference_overrides.get(
                (scene, variant), args.reference_pattern.format(scene=scene, variant=variant)
            )
            reference_path = ROOT / reference_relative if not Path(reference_relative).is_absolute() else Path(reference_relative)
            if not reference_path.exists():
                print(f"skip {scene}/{variant}: 参照 {reference_path} が無い", file=sys.stderr)
                continue
            link_path = reference_dir / f"{scene}.jpg"
            if link_path.exists() or link_path.is_symlink():
                link_path.unlink()
            link_path.symlink_to(reference_path)

            if not args.skip_render:
                cmd = [
                    str(render_binary), str(raw_path),
                    "--output-dir", str(render_dir),
                    "--preset", str(xmp_path),
                ]
                proc = subprocess.run(cmd, capture_output=True, text=True)
                render_log.append(f"$ {' '.join(cmd)}\n{proc.stdout}{proc.stderr}")
                if proc.returncode != 0:
                    print(f"エラー: {scene}/{variant} の描画に失敗\n{proc.stderr}", file=sys.stderr)
                    continue

        out_json = args.out_dir / f"{variant}.json"
        cmd = [
            sys.executable, str(compare_script),
            "--reference", str(reference_dir),
            "--renders", str(render_dir),
            "--out", str(out_json),
        ]
        if args.no_align:
            cmd.append("--no-align")
        proc = subprocess.run(cmd, capture_output=True, text=True)
        print(proc.stdout)
        if proc.returncode != 0:
            print(f"エラー: {variant} の比較に失敗\n{proc.stderr}", file=sys.stderr)
            continue
        if out_json.exists():
            variant_results[variant] = json.loads(out_json.read_text())

    (args.out_dir / "render-log.txt").write_text("\n\n".join(render_log))

    # --- 集計 ---------------------------------------------------------------
    def mean_delta_e_for(variant: str, scene: str) -> float | None:
        data = variant_results.get(variant)
        if not data:
            return None
        result = data.get("results", {}).get(scene)
        if not result:
            return None
        return result["meanDeltaE00"]

    summary_rows = []
    core_values = []
    all_hs_values = []
    for variant in HS_VARIANTS:
        for scene in scene_paths:
            value = mean_delta_e_for(variant, scene)
            if value is None:
                continue
            summary_rows.append((scene, variant, value))
            all_hs_values.append(value)
            if variant in HS_CORE_VARIANTS:
                core_values.append(value)

    composite_rows = []
    for variant in COMPOSITE_VARIANTS:
        for scene in scene_paths:
            value = mean_delta_e_for(variant, scene)
            if value is None:
                continue
            composite_rows.append((scene, variant, value))

    core_average = sum(core_values) / len(core_values) if core_values else None
    all_hs_average = sum(all_hs_values) / len(all_hs_values) if all_hs_values else None

    summary = {
        "gateMeanThreshold": GATE_MEAN_THRESHOLD,
        "hsCoreCasesAverageMeanDeltaE00 (4 variants x 3 scenes = 12 cases, per brief text)": core_average,
        "hsCoreCasesCount": len(core_values),
        "hsAllVariantsAverageMeanDeltaE00 (6 variants x 3 scenes = 18 cases, per actual gate XMP set)": all_hs_average,
        "hsAllVariantsCount": len(all_hs_values),
        "hsCorePassed": core_average is not None and core_average <= GATE_MEAN_THRESHOLD,
        "hsAllVariantsPassed": all_hs_average is not None and all_hs_average <= GATE_MEAN_THRESHOLD,
        "rows": [{"scene": s, "variant": v, "meanDeltaE00": val} for s, v, val in summary_rows],
        "composite": [{"scene": s, "variant": v, "meanDeltaE00": val} for s, v, val in composite_rows],
    }
    (args.out_dir / "summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False))

    lines = ["| scene | variant | meanΔE00 |", "|---|---|---:|"]
    for s, v, val in summary_rows:
        lines.append(f"| {s} | {v} | {val:.3f} |")
    lines.append("")
    lines.append(f"H/S core (4 variants x 3 scenes = {len(core_values)} cases) average meanΔE00: "
                  f"{core_average:.3f} ({'PASS' if summary['hsCorePassed'] else 'FAIL'} <= {GATE_MEAN_THRESHOLD})" if core_average is not None else "H/S core: no data")
    lines.append(f"H/S all gate variants (6 variants x 3 scenes = {len(all_hs_values)} cases) average meanΔE00: "
                  f"{all_hs_average:.3f} ({'PASS' if summary['hsAllVariantsPassed'] else 'FAIL'} <= {GATE_MEAN_THRESHOLD})" if all_hs_average is not None else "H/S all: no data")
    lines.append("")
    lines.append("| scene | variant (composite, no gate) | meanΔE00 |")
    lines.append("|---|---|---:|")
    for s, v, val in composite_rows:
        lines.append(f"| {s} | {v} | {val:.3f} |")
    (args.out_dir / "summary.md").write_text("\n".join(lines))
    print("\n".join(lines))


if __name__ == "__main__":
    main()
