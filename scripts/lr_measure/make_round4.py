#!/usr/bin/env python3
"""LR計測 round4: night プリセットの色（Calibration / Split Toning / HSL の同時掛け）と Red/Orange の HSL スイープ。

round2 と同じ方式（RAW の APFS クローン＋サイドカー）。使い方: photo-edit-app 直下で python3 scripts/lr_measure/make_round4.py
"""
from __future__ import annotations
import json, subprocess, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from make_round0 import REFERENCE, minimal_packet, sidecar_with  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
ROUND = ROOT / "exports/lr-measure/round4"
OUT = ROUND / "round4-photos"
SCENES = {
    "P1013558": REFERENCE / "P1013558.RW2", "P1013207": REFERENCE / "P1013207.RW2", "P1012822": REFERENCE / "P1012822.RW2",
    "P1524180": ROOT / "P1524180.RW2", "P1581215": ROOT / "exports/lr-measure/round2/extra-raw/P1581215.RW2",
}
NIGHT_WB = {"WhiteBalance": "Custom", "Temperature": "6214", "Tint": "+13"}
NIGHT_CAL = {"GreenHue": "+19", "GreenSaturation": "-26", "BlueHue": "-11", "BlueSaturation": "+19"}
NIGHT_SPLIT = {"SplitToningShadowHue": "66", "SplitToningShadowSaturation": "13", "SplitToningHighlightHue": "186", "SplitToningHighlightSaturation": "10", "SplitToningBalance": "0", "ColorGradeBlending": "50"}
NIGHT_HSL = {}
import re
night_xmp = (ROOT / "niho-preset night.xmp").read_text(encoding="utf-8")
for m in re.finditer(r'crs:((?:Hue|Saturation|Luminance)Adjustment[A-Za-z]+)="([^"]*)"', night_xmp):
    NIGHT_HSL[m.group(1)] = m.group(2)
VARIANTS: dict[str, dict[str, str]] = {
    "neutral": {},
    "night_wb": dict(NIGHT_WB),
    "night_wb_cal": {**NIGHT_WB, **NIGHT_CAL},
    "night_wb_split": {**NIGHT_WB, **NIGHT_SPLIT},
    "night_wb_hsl": {**NIGHT_WB, **NIGHT_HSL},
    "night_wb_cal_hsl": {**NIGHT_WB, **NIGHT_CAL, **NIGHT_HSL},
    "night_color_all": {**NIGHT_WB, **NIGHT_CAL, **NIGHT_SPLIT, **NIGHT_HSL},
    "cal_only": dict(NIGHT_CAL),
    "SaturationAdjustmentOrange_-40": {"SaturationAdjustmentOrange": "-40"},
    "SaturationAdjustmentRed_+40": {"SaturationAdjustmentRed": "+40"},
    "LuminanceAdjustmentOrange_+40": {"LuminanceAdjustmentOrange": "+40"},
    "LuminanceAdjustmentOrange_-40": {"LuminanceAdjustmentOrange": "-40"},
    "HueAdjustmentOrange_-20": {"HueAdjustmentOrange": "-20"},
    "HueAdjustmentRed_+20": {"HueAdjustmentRed": "+20"},
}

def clone(src: Path, dst: Path) -> None:
    r = subprocess.run(["cp", "-c", str(src), str(dst)], capture_output=True)
    if r.returncode != 0:
        subprocess.run(["cp", str(src), str(dst)], check=True); print("warning: 通常コピー", dst.name)

def main() -> None:
    if OUT.exists() and any(OUT.iterdir()):
        raise SystemExit(f"{OUT} が空でない。上書きしないので中止する。")
    OUT.mkdir(parents=True, exist_ok=True); (ROUND / "lr-export-photos").mkdir(parents=True, exist_ok=True)
    manifest = []
    for scene, raw in SCENES.items():
        base = (REFERENCE / f"{scene}.xmp")
        base_sidecar = base.read_text(encoding="utf-8") if base.exists() else None
        for variant, attrs in VARIANTS.items():
            stem = f"p4_{scene}_{variant}"
            clone(raw, OUT / f"{stem}.RW2")
            sidecar = sidecar_with(base_sidecar, attrs, {}) if base_sidecar else minimal_packet(attrs, {})
            (OUT / f"{stem}.xmp").write_text(sidecar, encoding="utf-8")
            manifest.append({"file": f"{stem}.RW2", "scene": scene, "variant": variant, "settings": attrs})
    (ROUND / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    (ROUND / "README.md").write_text(
        "# LR計測 round4（night の色の分解と Red/Orange の HSL）— 書き出し 1 回、5〜10 分\n\n"
        f"1. Lightroom「ローカル」で `{OUT}` を開く\n2. 全選択 → 書き出し（JPG 100%・フルサイズ・sRGB・出力シャープ OFF・ファイル名そのまま）→ `{ROUND / 'lr-export-photos'}`\n"
        f"3. 写真には触らない。終わったら「round4 終わった」と伝える。\n\n{len(SCENES)} scene × {len(VARIANTS)} variant = {len(manifest)} 枚（APFS クローン、実容量は増えない）。\n", encoding="utf-8")
    print(f"{len(manifest)} files -> {OUT}")

if __name__ == "__main__":
    main()
