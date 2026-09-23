#!/usr/bin/env python3
"""LR計測 round2: 画像適応・複数スライダー合成・Texture系線形性・HSL青の教師データ。

round0/round1で「機械生成したXMPをLRが読み、手動適用と完全一致する」ことを確認済み。
ここでは4つの目的別セット（manifest.jsonの`set`キーで判別）を、RAWのAPFSクローン+
サイドカーXMPとして生成する。RAWの読み込み・現像処理はしない（クローンとテキスト生成のみ）。

  set A: Highlights/Shadowsの画像適応（全scene: 既存3 + 新規3 + extra） x 6 variant
  set B: 複数スライダーの合成（3scene） x 14 variant
  set C: Texture/Clarity/Dehazeの線形性（3scene） x 15 variant
  set D: HSLの青の色相・輝度（3scene） x 10 variant

既存3シーン（P1013558/P1013207/P1012822）は exports/editing-mvp-20260922/lightroom-reference/
にLRが書いた基準サイドカーがあるので、そこから設定属性だけ差し替える（sidecar_with）。
新規3シーン（repo直下のP1522877/P1524180/P1524181）と--extra-raw-dirで足すRAWには基準サイド
カーが無いので、round0のminimal_packet相当の最小サイドカーを使う（LRが既定値で補完する）。

使い方: photo-edit-app 直下で
  python3 scripts/lr_measure/make_round2.py [--extra-raw-dir DIR] [--dry-run]
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from make_round0 import REFERENCE, minimal_packet, sidecar_with  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
ROUND = ROOT / "exports/lr-measure/round2"
PHOTOS = ROUND / "round2-photos"
EXPORT_DIR = ROUND / "lr-export-photos"

# set B/C/D はこの3シーン固定（既存の基準サイドカーがあり、round1と揃えるため）。
CORE_SCENES = ["P1013558", "P1013207", "P1012822"]
# set A はこれに加えて新規3シーン（基準サイドカー無し）と --extra-raw-dir を足す。
NEW_SCENES = ["P1522877", "P1524180", "P1524181"]

Attrs = dict[str, str]
Variant = tuple[str, Attrs]


def set_a_variants() -> list[Variant]:
    """Highlights/Shadowsの画像適応。scene毎に効き方が変わる法則を取るための共通6点。"""
    return [
        ("neutral", {}),
        ("Highlights2012_-50", {"Highlights2012": "-50"}),
        ("Highlights2012_-100", {"Highlights2012": "-100"}),
        ("Shadows2012_+50", {"Shadows2012": "+50"}),
        ("Shadows2012_+100", {"Shadows2012": "+100"}),
        ("Highlights2012_-80_Shadows2012_+40", {"Highlights2012": "-80", "Shadows2012": "+40"}),
    ]


def set_b_variants() -> list[Variant]:
    """複数スライダーの合成。H x S x B の8組 + Exposure2012+0.8を足した4組 + Whites2012-50を足した2組。"""
    v: list[Variant] = []
    for h in ["-80", "-40"]:
        for s in ["+40", "+80"]:
            for b in [None, "+60"]:
                attrs: Attrs = {"Highlights2012": h, "Shadows2012": s}
                label_b = "0"
                if b is not None:
                    attrs["Blacks2012"] = b
                    label_b = b
                v.append((f"H{h}_S{s}_B{label_b}", attrs))
    exposure_combos = [
        ("-80", "+40", "+60"),
        ("-80", "+80", "+60"),
        ("-40", "+40", None),
        ("-80", "+40", None),
    ]
    for h, s, b in exposure_combos:
        attrs = {"Highlights2012": h, "Shadows2012": s, "Exposure2012": "+0.80"}
        label_b = "0"
        if b is not None:
            attrs["Blacks2012"] = b
            label_b = b
        v.append((f"H{h}_S{s}_B{label_b}_E+0.80", attrs))
    v.append(("H-80_S+40_W-50", {"Highlights2012": "-80", "Shadows2012": "+40", "Whites2012": "-50"}))
    v.append((
        "H-80_S+40_W-50_B+60",
        {"Highlights2012": "-80", "Shadows2012": "+40", "Whites2012": "-50", "Blacks2012": "+60"},
    ))
    return v


def set_c_variants() -> list[Variant]:
    """Texture/Clarity/Dehazeの線形性。Texture・Clarity2012は同じ6点、Dehazeは3点。"""
    six = ["-80", "-40", "-20", "+20", "+40", "+80"]
    v: list[Variant] = [(f"Texture_{val}", {"Texture": val}) for val in six]
    v += [(f"Clarity2012_{val}", {"Clarity2012": val}) for val in six]
    v += [(f"Dehaze_{val}", {"Dehaze": val}) for val in ["-40", "+20", "+80"]]
    return v


def set_d_variants() -> list[Variant]:
    """HSLの青の色相・輝度。LuminanceAdjustmentBlue4点 + HueAdjustmentBlue4点 + HueAdjustmentAqua2点。"""
    v: list[Variant] = [
        (f"LuminanceAdjustmentBlue_{val}", {"LuminanceAdjustmentBlue": val})
        for val in ["-60", "-30", "+30", "+60"]
    ]
    v += [(f"HueAdjustmentBlue_{val}", {"HueAdjustmentBlue": val}) for val in ["-30", "-15", "+15", "+30"]]
    v += [(f"HueAdjustmentAqua_{val}", {"HueAdjustmentAqua": val}) for val in ["-20", "+20"]]
    return v


def collect_scenes(extra_raw_dir: Path | None) -> dict[str, dict]:
    """scene ID -> {raw, kind, base_sidecar, origin}。kindは reference(基準サイドカーあり) / minimal。"""
    scenes: dict[str, dict] = {}
    for scene in CORE_SCENES:
        raw = REFERENCE / f"{scene}.RW2"
        xmp = REFERENCE / f"{scene}.xmp"
        if not raw.exists() or not xmp.exists():
            raise SystemExit(f"基準RAW/サイドカーが無い: {raw} / {xmp}")
        scenes[scene] = {
            "raw": raw,
            "kind": "reference",
            "base_sidecar": xmp.read_text(encoding="utf-8"),
            "origin": "existing",
        }
    for scene in NEW_SCENES:
        raw = ROOT / f"{scene}.RW2"
        if not raw.exists():
            raise SystemExit(f"新規RAWが無い: {raw}")
        scenes[scene] = {"raw": raw, "kind": "minimal", "base_sidecar": None, "origin": "new"}
    if extra_raw_dir is not None:
        if not extra_raw_dir.is_dir():
            raise SystemExit(f"--extra-raw-dir が見つからない: {extra_raw_dir}")
        for raw in sorted(extra_raw_dir.glob("*.RW2")):
            scene = raw.stem
            if scene in scenes:
                print(f"警告: extra-raw-dir の {raw.name} は既存sceneと同じID。スキップする。")
                continue
            scenes[scene] = {"raw": raw, "kind": "minimal", "base_sidecar": None, "origin": "extra"}
    return scenes


def build_plan(scenes: dict[str, dict]) -> list[tuple[str, str, str, Attrs]]:
    """(set, scene, variant, attrs) のリスト。"""
    plan: list[tuple[str, str, str, Attrs]] = []
    for scene in scenes:  # 全scene: 既存3 + 新規3 + extra
        for name, attrs in set_a_variants():
            plan.append(("A", scene, name, attrs))
    core = [s for s in CORE_SCENES if s in scenes]
    for set_id, variants in [("B", set_b_variants()), ("C", set_c_variants()), ("D", set_d_variants())]:
        for scene in core:
            for name, attrs in variants:
                plan.append((set_id, scene, name, attrs))
    return plan


def clone(src: Path, dst: Path) -> None:
    result = subprocess.run(["cp", "-c", str(src), str(dst)], capture_output=True)
    if result.returncode != 0:
        stderr = result.stderr.decode(errors="replace").strip()
        print(f"警告: APFSクローン失敗 ({src.name}) -> 通常コピーにフォールバック: {stderr}")
        shutil.copyfile(src, dst)


def sidecar_for(info: dict, attrs: Attrs) -> str:
    if info["kind"] == "reference":
        return sidecar_with(info["base_sidecar"], attrs, {})
    return minimal_packet(attrs, {})


def summarize(plan: list[tuple[str, str, str, Attrs]], scenes: dict[str, dict]) -> None:
    by_set = Counter(item[0] for item in plan)
    by_set_scene: dict[str, set[str]] = {}
    for set_id, scene, _, _ in plan:
        by_set_scene.setdefault(set_id, set()).add(scene)
    total_bytes = sum(scenes[scene]["raw"].stat().st_size for _, scene, _, _ in plan)
    print(f"variants: {len(plan)}")
    for set_id in "ABCD":
        n_scenes = len(by_set_scene.get(set_id, set()))
        print(f"  set {set_id}: {by_set.get(set_id, 0)} variant x {n_scenes} scene")
    print(f"files: RAW {len(plan)} + XMP {len(plan)} = {len(plan) * 2}")
    print(f"見かけ容量: {total_bytes / 1e9:.2f} GB (APFSクローンのため実容量は増えない)")


def main() -> None:
    parser = argparse.ArgumentParser(description="LR計測round2の教師データ入力セットを生成する")
    parser.add_argument("--extra-raw-dir", type=Path, default=None, help="追加RAW(*.RW2)を置いたフォルダ")
    parser.add_argument("--dry-run", action="store_true", help="ファイルを書かず件数だけ確認する")
    parser.add_argument(
        "--out-name", default="round2-photos",
        help="出力フォルダ名（exports/lr-measure/round2/ 配下）。追加分を別フォルダに出すときに変える（例: round2-extra-photos）",
    )
    parser.add_argument(
        "--only-extra", action="store_true",
        help="--extra-raw-dir の scene だけを生成する（既存 6 scene を出し直さない）",
    )
    args = parser.parse_args()

    global PHOTOS
    PHOTOS = ROUND / args.out_name
    scenes = collect_scenes(args.extra_raw_dir)
    if args.only_extra:
        keep = set(scenes) - set(CORE_SCENES) - set(NEW_SCENES)
        scenes = {k: v for k, v in scenes.items() if k in keep}
    plan = build_plan(scenes)

    if args.dry_run:
        summarize(plan, scenes)
        return

    if PHOTOS.exists() and any(PHOTOS.iterdir()):
        raise SystemExit(f"{PHOTOS} が空でない。上書きしないので中止する（--out-name を変えるか中身を消してから再実行）。")
    PHOTOS.mkdir(parents=True, exist_ok=True)
    EXPORT_DIR.mkdir(parents=True, exist_ok=True)

    manifest = []
    for set_id, scene, name, attrs in plan:
        info = scenes[scene]
        stem = f"p2_{scene}_{name}"
        raw = PHOTOS / f"{stem}.RW2"
        clone(info["raw"], raw)
        (PHOTOS / f"{stem}.xmp").write_text(sidecar_for(info, attrs), encoding="utf-8")
        manifest.append({
            "file": raw.name,
            "scene": scene,
            "variant": name,
            "set": set_id,
            "settings": attrs,
            "curves": [],
            "special": None,
        })

    manifest_path = ROUND / ("manifest.json" if args.out_name == "round2-photos" else f"manifest-{args.out_name}.json")
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    summarize(plan, scenes)
    print(f"-> {PHOTOS}")


if __name__ == "__main__":
    main()
