#!/usr/bin/env python3
"""LR計測 round3: JPEG 入力に対する Highlights / Shadows の応答（非RAW 経路の教師データ）。

round2 の LR 中立書き出し（p2_<scene>_neutral.jpg）をコピーし、round0 と同じ方法で設定だけの XMP パケットを
埋め込む（LR「ローカル」で開いて全選択 → JPG 100% / フルサイズ / sRGB / 出力シャープ OFF で書き出す）。
使い方: photo-edit-app 直下で python3 scripts/lr_measure/make_round3.py
"""
from __future__ import annotations
import json, shutil, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from make_round0 import embed, minimal_packet  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "exports/lr-measure/round2/lr-export-photos"
ROUND = ROOT / "exports/lr-measure/round3"
OUT = ROUND / "round3-jpeg"
SCENES = ["P1013558", "P1013207", "P1012822", "P1524180", "P1581215", "P1581335", "P1581332", "P1581237"]
VARIANTS: dict[str, dict[str, str]] = {
    "neutral": {},
    "Shadows2012_+50": {"Shadows2012": "+50"},
    "Shadows2012_+100": {"Shadows2012": "+100"},
    "Highlights2012_-50": {"Highlights2012": "-50"},
    "Highlights2012_-100": {"Highlights2012": "-100"},
    "HS_-80_+40": {"Highlights2012": "-80", "Shadows2012": "+40"},
    "tone_E+0.8_H-80_S+40_W-50_B+60": {"Exposure2012": "+0.80", "Highlights2012": "-80", "Shadows2012": "+40", "Whites2012": "-50", "Blacks2012": "+60"},
}

def main() -> None:
    if OUT.exists() and any(OUT.iterdir()):
        raise SystemExit(f"{OUT} が空でない。上書きしないので中止する。")
    OUT.mkdir(parents=True, exist_ok=True)
    (ROUND / "lr-export-jpeg").mkdir(parents=True, exist_ok=True)
    manifest = []
    for scene in SCENES:
        src = SRC / f"p2_{scene}_neutral.jpg"
        if not src.exists():
            raise SystemExit(f"中立 JPEG が無い: {src}")
        for variant, attrs in VARIANTS.items():
            dst = OUT / f"r3_{scene}_{variant}.jpg"
            shutil.copy2(src, dst)
            embed(minimal_packet(attrs, {}), dst)
            manifest.append({"file": dst.name, "scene": scene, "variant": variant, "kind": "jpeg-embedded", "settings": attrs, "source": src.name})
    (ROUND / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    (ROUND / "README.md").write_text(
        "# LR計測 round3（JPEG 入力の Highlights / Shadows）— オーナー作業手順（書き出し 1 回、5 分程度）\n\n"
        f"1. Lightroom「ローカル」で次のフォルダを開く（Finder ⇧⌘G に貼る）:\n   `{OUT}`\n"
        f"2. 全選択（⌘A）→ 書き出し（⇧⌘E）: **JPG・画質 100%・フルサイズ・sRGB・出力シャープ OFF・ファイル名そのまま**\n"
        f"   保存先: `{ROUND / 'lr-export-jpeg'}`\n"
        f"3. 写真の現像設定には触らない。終わったら「round3 終わった」と伝える。\n\n"
        f"内容: {len(SCENES)} scene × {len(VARIANTS)} variant = {len(manifest)} 枚（round2 の LR 中立 JPEG に設定だけの XMP を埋め込んだもの）。\n"
        "目的: JPEG 入力では LR のシャドウの効きが RAW より強い（round0 で −0.23 EV 不足、4 プリセットの JPEG が一様に暗い）ため、非RAW 経路の H/S を別に fit する。\n",
        encoding="utf-8",
    )
    print(f"{len(manifest)} files -> {OUT}")

if __name__ == "__main__":
    main()
