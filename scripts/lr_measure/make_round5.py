#!/usr/bin/env python3
"""LR計測 round5: 極端なトーン（night / colorful の Whites・Blacks・Contrast）、4 プリセット全体の 5 scene 検証、
Split Toning の Blending、Calibration の未検証スライダー。

RAW は round4 と同じ 5 scene（APFS クローン＋サイドカー）、JPEG は round3 と同じ方式（round2 の LR 中立 JPEG に
設定だけの XMP を埋め込む）。すべて 1 つのフォルダに置き、LR で 1 回書き出せば済むようにする。
プリセット全体はプロファイル（CameraProfile / Look）を書き換えず、基準サイドカーの Adobe Standard + Adobe Color の
まま適用する（旧 LR の "Default Color" は Adobe Color 相当）。
使い方: photo-edit-app 直下で python3 scripts/lr_measure/make_round5.py
"""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from make_round0 import REFERENCE, embed, minimal_packet, preset_settings, sidecar_with  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
ROUND = ROOT / "exports/lr-measure/round5"
OUT = ROUND / "round5-photos"
EXPORT = ROUND / "lr-export"
RAW_SCENES = {
    "P1013558": REFERENCE / "P1013558.RW2", "P1013207": REFERENCE / "P1013207.RW2", "P1012822": REFERENCE / "P1012822.RW2",
    "P1524180": ROOT / "P1524180.RW2", "P1581215": ROOT / "exports/lr-measure/round2/extra-raw/P1581215.RW2",
}
JPEG_SOURCE = ROOT / "exports/lr-measure/round2/lr-export-photos"
PRESETS = {
    "night": ROOT / "niho-preset night.xmp",
    "bluesky2": ROOT / "niho-preset bluesky2.xmp",
    "pastel": ROOT / "niho-preset pastel.xmp",
    "colorful": ROOT / "niho-priset_colorful.xmp",
}
PROFILE_KEYS = {"CameraProfile", "CameraProfileDigest", "LookTable", "Look"}


def preset(name: str) -> tuple[dict[str, str], dict[str, str]]:
    attributes, elements = preset_settings(PRESETS[name])
    return {k: v for k, v in attributes.items() if k not in PROFILE_KEYS}, elements


def tone_of(name: str, drop: tuple[str, ...] = ()) -> tuple[dict[str, str], dict[str, str]]:
    """プリセットのトーン系だけ（露出・コントラスト・H/S・白黒・Texture/Clarity/Dehaze・parametric・点カーブ）。"""
    attributes, elements = preset(name)
    keep = ("Exposure2012", "Contrast2012", "Highlights2012", "Shadows2012", "Whites2012", "Blacks2012",
            "Texture", "Clarity2012", "Dehaze", "ToneCurveName2012")
    tone = {k: v for k, v in attributes.items() if (k in keep or k.startswith("Parametric")) and k not in drop}
    return tone, dict(elements)


def only(**attributes: str) -> tuple[dict[str, str], dict[str, str]]:
    return dict(attributes), {}


def curve_only(name: str) -> tuple[dict[str, str], dict[str, str]]:
    attributes, elements = preset(name)
    return {"ToneCurveName2012": attributes.get("ToneCurveName2012", "Custom")}, dict(elements)


NIGHT_SPLIT = {"SplitToningShadowHue": "66", "SplitToningShadowSaturation": "13", "SplitToningHighlightHue": "186",
               "SplitToningHighlightSaturation": "10", "SplitToningBalance": "0"}

RAW_VARIANTS = {
    "night_tone": lambda: tone_of("night"),
    "night_tone_noHS": lambda: tone_of("night", ("Highlights2012", "Shadows2012")),
    "night_tone_noWB": lambda: tone_of("night", ("Whites2012", "Blacks2012")),
    "Whites2012_-83": lambda: only(Whites2012="-83"),
    "Blacks2012_+89": lambda: only(Blacks2012="+89"),
    "W-83_B+89": lambda: only(Whites2012="-83", Blacks2012="+89"),
    "Contrast2012_-43": lambda: only(Contrast2012="-43"),
    "night_curve": lambda: curve_only("night"),
    "colorful_tone": lambda: tone_of("colorful"),
    "full_night": lambda: preset("night"),
    "full_bluesky2": lambda: preset("bluesky2"),
    "full_pastel": lambda: preset("pastel"),
    "full_colorful": lambda: preset("colorful"),
    "split_sh250_s25_b50": lambda: only(SplitToningShadowHue="250", SplitToningShadowSaturation="25", ColorGradeBlending="50"),
    "split_hi60_s25_b50": lambda: only(SplitToningHighlightHue="60", SplitToningHighlightSaturation="25", ColorGradeBlending="50"),
    "split_night_b100": lambda: ({**NIGHT_SPLIT, "ColorGradeBlending": "100"}, {}),
    "split_night_b0": lambda: ({**NIGHT_SPLIT, "ColorGradeBlending": "0"}, {}),
    "RedHue_+50": lambda: only(RedHue="+50"),
    "RedSaturation_+50": lambda: only(RedSaturation="+50"),
    "GreenSaturation_-50": lambda: only(GreenSaturation="-50"),
    "BlueHue_-50": lambda: only(BlueHue="-50"),
}
JPEG_VARIANTS = ["night_tone", "Whites2012_-83", "Blacks2012_+89", "W-83_B+89", "colorful_tone",
                 "full_night", "full_bluesky2", "full_pastel", "full_colorful"]


def clone(src: Path, dst: Path) -> None:
    if subprocess.run(["cp", "-c", str(src), str(dst)], capture_output=True).returncode != 0:
        shutil.copy2(src, dst)
        print("warning: 通常コピー", dst.name)


def main() -> None:
    if OUT.exists() and any(OUT.iterdir()):
        raise SystemExit(f"{OUT} が空でない。上書きしないので中止する。")
    OUT.mkdir(parents=True, exist_ok=True)
    EXPORT.mkdir(parents=True, exist_ok=True)
    manifest = []
    for scene, raw in RAW_SCENES.items():
        base_path = REFERENCE / f"{scene}.xmp"
        base = base_path.read_text(encoding="utf-8") if base_path.exists() else None
        for variant, make in RAW_VARIANTS.items():
            attributes, elements = make()
            stem = f"p5_{scene}_{variant}"
            clone(raw, OUT / f"{stem}.RW2")
            sidecar = sidecar_with(base, attributes, elements) if base else minimal_packet(attributes, elements)
            (OUT / f"{stem}.xmp").write_text(sidecar, encoding="utf-8")
            manifest.append({"file": f"{stem}.RW2", "scene": scene, "variant": variant, "kind": "raw",
                             "settings": attributes, "curves": sorted(elements)})
    for scene in RAW_SCENES:
        src = JPEG_SOURCE / f"p2_{scene}_neutral.jpg"
        if not src.exists():
            raise SystemExit(f"中立 JPEG が無い: {src}")
        for variant in JPEG_VARIANTS:
            attributes, elements = RAW_VARIANTS[variant]()
            dst = OUT / f"p5j_{scene}_{variant}.jpg"
            shutil.copy2(src, dst)
            embed(minimal_packet(attributes, elements), dst)
            manifest.append({"file": dst.name, "scene": scene, "variant": variant, "kind": "jpeg-embedded",
                             "settings": attributes, "curves": sorted(elements), "source": src.name})
    (ROUND / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    n_raw = sum(1 for e in manifest if e["kind"] == "raw")
    (ROUND / "README.md").write_text(
        "# LR計測 round5（極端なトーン・4 プリセット全体・Split Toning の Blending・Calibration）— 書き出し 1 回、10〜15 分\n\n"
        f"1. Lightroom「ローカル」で次のフォルダを開く（Finder ⇧⌘G に貼る）:\n   `{OUT}`\n"
        "2. 全選択（⌘A）→ 書き出し（⇧⌘E）: **JPG・画質 100%・フルサイズ・sRGB・出力シャープ OFF・ファイル名そのまま**\n"
        f"   保存先: `{EXPORT}`\n"
        "3. 写真の現像設定には触らない。終わったら「round5 終わった」と伝える。\n\n"
        f"内容: RAW {n_raw} 枚（{len(RAW_SCENES)} scene × {len(RAW_VARIANTS)} variant、APFS クローンなので実容量は増えない）＋ "
        f"JPEG {len(manifest) - n_raw} 枚（{len(RAW_SCENES)} scene × {len(JPEG_VARIANTS)} variant、round2 の LR 中立 JPEG に設定を埋め込んだもの）。\n"
        "目的: night・colorful で残っている差（強い Whites / Blacks / Contrast で自前の彩度が LR より落ちる）を、"
        "極端な値の実写で直接測る。あわせて 4 プリセット全体を 5 枚の写真で確かめ、Split Toning の Blending と、"
        "まだ実写で確かめていない Calibration のスライダーを測る。\n",
        encoding="utf-8",
    )
    print(f"{len(manifest)} files -> {OUT}")


if __name__ == "__main__":
    main()
