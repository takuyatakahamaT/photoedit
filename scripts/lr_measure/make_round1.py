#!/usr/bin/env python3
"""LR計測 round1: フェーズ2（画素単位の色操作）とフェーズ3（空間操作）の教師データ。

round0で「機械生成XMP → LR書き出し」が手動適用と完全一致することを確認済み。ここでは
  round1-charts/ : 合成チャート（16bit TIFF）に1操作ずつ埋め込み → LRで TIF 16bit ProPhoto に書き出す
  round1-photos/ : 3枚のRAW（APFSクローン）にサイドカーで1操作ずつ → LRで JPG sRGB に書き出す
を生成する。使い方: photo-edit-app 直下で python3 scripts/lr_measure/make_round1.py
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import charts  # noqa: E402
from make_round0 import (  # noqa: E402
    REFERENCE,
    embed,
    minimal_packet,
    preset_settings,
    sidecar_with,
    split_look,
)

ROOT = Path(__file__).resolve().parents[2]
ROUND = ROOT / "exports/lr-measure/round1"
CHARTS = ROUND / "round1-charts"
PHOTOS = ROUND / "round1-photos"
ROMM_ICC = Path("/System/Library/ColorSync/Profiles/ROMM RGB.icc")
SCENES = ["P1013558", "P1013207", "P1012822"]

S_CURVE = "<crs:ToneCurvePV2012><rdf:Seq><rdf:li>0, 0</rdf:li><rdf:li>64, 40</rdf:li><rdf:li>128, 128</rdf:li><rdf:li>192, 215</rdf:li><rdf:li>255, 255</rdf:li></rdf:Seq></crs:ToneCurvePV2012>"
INV_S_CURVE = "<crs:ToneCurvePV2012><rdf:Seq><rdf:li>0, 0</rdf:li><rdf:li>64, 88</rdf:li><rdf:li>128, 128</rdf:li><rdf:li>192, 168</rdf:li><rdf:li>255, 255</rdf:li></rdf:Seq></crs:ToneCurvePV2012>"
RED_CURVE = "<crs:ToneCurvePV2012Red><rdf:Seq><rdf:li>0, 0</rdf:li><rdf:li>128, 160</rdf:li><rdf:li>255, 255</rdf:li></rdf:Seq></crs:ToneCurvePV2012Red>"
BLUE_CURVE = "<crs:ToneCurvePV2012Blue><rdf:Seq><rdf:li>0, 0</rdf:li><rdf:li>128, 96</rdf:li><rdf:li>255, 255</rdf:li></rdf:Seq></crs:ToneCurvePV2012Blue>"
BANDS = ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"]


def chart_variants() -> list[tuple[str, list[str], dict[str, str], dict[str, str]]]:
    """(name, charts, attributes, curve elements)"""
    v: list[tuple[str, list[str], dict[str, str], dict[str, str]]] = []
    all_charts = ["hald-srgb", "hald-prophoto", "ramp", "hues", "freq"]
    v.append(("neutral", all_charts, {}, {}))
    tone = ["hald-srgb", "ramp"]
    for key, values in [
        ("Exposure2012", ["-2.00", "-1.00", "+1.00", "+2.00", "+3.00"]),
        ("Contrast2012", ["-100", "-50", "+50", "+100"]),
        ("Highlights2012", ["-100", "-50", "+50", "+100"]),
        ("Shadows2012", ["-100", "-50", "+50", "+100"]),
        ("Whites2012", ["-100", "-50", "+50", "+100"]),
        ("Blacks2012", ["-100", "-50", "+50", "+100"]),
    ]:
        for value in values:
            v.append((f"{key}_{value}", tone, {key: value}, {}))
    curve_charts = ["hald-srgb", "hald-prophoto"]
    v.append(("pointcurve_S_refine100", curve_charts, {"ToneCurveName2012": "Custom", "CurveRefineSaturation": "100"}, {"ToneCurvePV2012": S_CURVE}))
    v.append(("pointcurve_S_refine0", curve_charts, {"ToneCurveName2012": "Custom", "CurveRefineSaturation": "0"}, {"ToneCurvePV2012": S_CURVE}))
    v.append(("pointcurve_invS_refine100", curve_charts, {"ToneCurveName2012": "Custom", "CurveRefineSaturation": "100"}, {"ToneCurvePV2012": INV_S_CURVE}))
    v.append(("pointcurve_red", curve_charts, {"ToneCurveName2012": "Custom", "CurveRefineSaturation": "100"}, {"ToneCurvePV2012Red": RED_CURVE}))
    v.append(("pointcurve_blue", curve_charts, {"ToneCurveName2012": "Custom", "CurveRefineSaturation": "100"}, {"ToneCurvePV2012Blue": BLUE_CURVE}))
    for key in ["ParametricShadows", "ParametricDarks", "ParametricLights", "ParametricHighlights"]:
        for value in ["-60", "+60"]:
            v.append((f"{key}_{value}", tone, {key: value}, {}))
    v.append(("ParametricDarks_+60_splits10-40-90", tone, {"ParametricDarks": "+60", "ParametricShadowSplit": "10", "ParametricMidtoneSplit": "40", "ParametricHighlightSplit": "90"}, {}))
    for band in BANDS:
        for kind in ["HueAdjustment", "SaturationAdjustment", "LuminanceAdjustment"]:
            for value in ["-60", "+60"]:
                v.append((f"{kind}{band}_{value}", ["hald-srgb"], {f"{kind}{band}": value}, {}))
    v.append(("HueAdjustmentOrange_+60_hues", ["hues"], {"HueAdjustmentOrange": "+60"}, {}))
    v.append(("SaturationAdjustmentGreen_+60_hues", ["hues"], {"SaturationAdjustmentGreen": "+60"}, {}))
    v.append(("LuminanceAdjustmentBlue_+60_hues", ["hues"], {"LuminanceAdjustmentBlue": "+60"}, {}))
    for key in ["Vibrance", "Saturation"]:
        for value in ["-100", "-50", "+50", "+100"]:
            v.append((f"{key}_{value}", ["hald-srgb"], {key: value}, {}))
    for key in ["RedHue", "RedSaturation", "GreenHue", "GreenSaturation", "BlueHue", "BlueSaturation", "ShadowTint"]:
        for value in ["-50", "+50"]:
            v.append((f"Calib{key}_{value}", ["hald-srgb"], {key: value}, {}))
    grading = [
        ("SplitToningShadow_h250_s30", {"SplitToningShadowHue": "250", "SplitToningShadowSaturation": "30"}),
        ("SplitToningHighlight_h60_s30", {"SplitToningHighlightHue": "60", "SplitToningHighlightSaturation": "30"}),
        ("ColorGradeMidtone_h120_s30", {"ColorGradeMidtoneHue": "120", "ColorGradeMidtoneSat": "30"}),
        ("ColorGradeGlobal_h300_s30", {"ColorGradeGlobalHue": "300", "ColorGradeGlobalSat": "30"}),
        ("Grading_sh250_hi60_blend0", {"SplitToningShadowHue": "250", "SplitToningShadowSaturation": "30", "SplitToningHighlightHue": "60", "SplitToningHighlightSaturation": "30", "ColorGradeBlending": "0"}),
        ("Grading_sh250_hi60_blend100", {"SplitToningShadowHue": "250", "SplitToningShadowSaturation": "30", "SplitToningHighlightHue": "60", "SplitToningHighlightSaturation": "30", "ColorGradeBlending": "100"}),
        ("Grading_sh250_hi60_balance-50", {"SplitToningShadowHue": "250", "SplitToningShadowSaturation": "30", "SplitToningHighlightHue": "60", "SplitToningHighlightSaturation": "30", "SplitToningBalance": "-50"}),
        ("Grading_sh250_hi60_balance+50", {"SplitToningShadowHue": "250", "SplitToningShadowSaturation": "30", "SplitToningHighlightHue": "60", "SplitToningHighlightSaturation": "30", "SplitToningBalance": "+50"}),
        ("ColorGradeShadowLum_-50", {"ColorGradeShadowLum": "-50"}),
        ("ColorGradeHighlightLum_+50", {"ColorGradeHighlightLum": "+50"}),
    ]
    for name, attrs in grading:
        v.append((name, ["hald-srgb"], attrs, {}))
    for key, values in [("IncrementalTemperature", ["-80", "-30", "+30", "+80"]), ("IncrementalTint", ["-30", "+30"])]:
        for value in values:
            v.append((f"{key}_{value}", ["hald-srgb"], {"WhiteBalance": "Custom", key: value}, {}))
    detail = [
        ("Texture_-100", {"Texture": "-100"}), ("Texture_+100", {"Texture": "+100"}),
        ("Clarity2012_-100", {"Clarity2012": "-100"}), ("Clarity2012_+100", {"Clarity2012": "+100"}),
        ("Dehaze_-50", {"Dehaze": "-50"}), ("Dehaze_+50", {"Dehaze": "+50"}),
        ("Sharpness_0", {"Sharpness": "0"}), ("Sharpness_40", {"Sharpness": "40", "SharpenRadius": "+1.0", "SharpenDetail": "25", "SharpenEdgeMasking": "0"}),
        ("Sharpness_100", {"Sharpness": "100", "SharpenRadius": "+1.0", "SharpenDetail": "25", "SharpenEdgeMasking": "0"}),
        ("LuminanceSmoothing_50", {"LuminanceSmoothing": "50"}),
    ]
    for name, attrs in detail:
        v.append((name, ["freq"], attrs, {}))
    pairs = [
        ("pair_pointcurveS+hslOrangeSat60", {"ToneCurveName2012": "Custom", "SaturationAdjustmentOrange": "+60"}, {"ToneCurvePV2012": S_CURVE}),
        ("pair_hslOrangeSat60+splitShadow250", {"SaturationAdjustmentOrange": "+60", "SplitToningShadowHue": "250", "SplitToningShadowSaturation": "30"}, {}),
        ("pair_calibRedHue50+hslRedHue60", {"RedHue": "+50", "HueAdjustmentRed": "+60"}, {}),
        ("pair_saturation100+pointcurveS", {"Saturation": "+100", "ToneCurveName2012": "Custom"}, {"ToneCurvePV2012": S_CURVE}),
        ("pair_exposure+1+pointcurveS", {"Exposure2012": "+1.00", "ToneCurveName2012": "Custom"}, {"ToneCurvePV2012": S_CURVE}),
        ("pair_contrast50+pointcurveS", {"Contrast2012": "+50", "ToneCurveName2012": "Custom"}, {"ToneCurvePV2012": S_CURVE}),
        ("pair_vibrance50+saturation50", {"Vibrance": "+50", "Saturation": "+50"}, {}),
        ("pair_paramDarks60+pointcurveS", {"ParametricDarks": "+60", "ToneCurveName2012": "Custom"}, {"ToneCurvePV2012": S_CURVE}),
        ("pair_wbTemp50+hslBlueHue60", {"WhiteBalance": "Custom", "IncrementalTemperature": "+50", "HueAdjustmentBlue": "+60"}, {}),
        ("pair_calibBlueSat50+pointcurveS", {"BlueSaturation": "+50", "ToneCurveName2012": "Custom"}, {"ToneCurvePV2012": S_CURVE}),
        ("pair_exposure+1+highlights-100", {"Exposure2012": "+1.00", "Highlights2012": "-100"}, {}),
        ("pair_shadows100+blacks-100", {"Shadows2012": "+100", "Blacks2012": "-100"}, {}),
    ]
    for name, attrs, elems in pairs:
        v.append((name, ["hald-srgb"], attrs, elems))
    return v


def photo_variants() -> list[tuple[str, dict[str, str], dict[str, str], str | None]]:
    """(name, attributes, curve elements, special)  special: 'adobe-standard' | 'pv11' | None"""
    v: list[tuple[str, dict[str, str], dict[str, str], str | None]] = []
    v.append(("profile_AdobeStandard", {"CameraProfile": "Adobe Standard"}, {}, "adobe-standard"))
    for key, values in [
        ("Exposure2012", ["-1.00", "+1.00", "+2.00"]),
        ("Contrast2012", ["-50", "+50"]),
        ("Highlights2012", ["-100", "-50", "+50"]),
        ("Shadows2012", ["-50", "+50", "+100"]),
        ("Whites2012", ["-60", "+60"]),
        ("Blacks2012", ["-60", "+60"]),
        ("Texture", ["-60", "+60"]),
        ("Clarity2012", ["-60", "+60"]),
        ("Dehaze", ["+40"]),
        ("GreenHue", ["+50"]),
        ("BlueSaturation", ["+50"]),
        ("SaturationAdjustmentOrange", ["+60"]),
        ("LuminanceAdjustmentBlue", ["+60"]),
    ]:
        for value in values:
            v.append((f"{key}_{value}", {key: value}, {}, None))
    v.append(("Temperature_4000", {"WhiteBalance": "Custom", "Temperature": "4000", "Tint": "0"}, {}, None))
    v.append(("Temperature_7500", {"WhiteBalance": "Custom", "Temperature": "7500", "Tint": "0"}, {}, None))
    v.append(("Tint_+30", {"WhiteBalance": "Custom", "Temperature": "5500", "Tint": "+30"}, {}, None))
    v.append(("tone-all_bluesky2", {"Exposure2012": "+0.79", "Contrast2012": "-6", "Highlights2012": "-79", "Shadows2012": "+46", "Whites2012": "-56", "Blacks2012": "+90"}, {}, None))
    return v


def remove_look(sidecar: str) -> str:
    head, look, tail = split_look(sidecar)
    text = head + tail
    text = re.sub(r'\bcrs:CameraProfileDigest="[^"]*"\n?', "", text)
    return text


def main() -> None:
    if ROUND.exists():
        raise SystemExit(f"{ROUND} が既にある。別名にするか消してから実行する。")
    CHARTS.mkdir(parents=True)
    PHOTOS.mkdir(parents=True)
    (ROUND / "lr-export-charts").mkdir()
    (ROUND / "lr-export-photos").mkdir()

    # --- charts ---
    base_images: dict[str, Path] = {}
    generators = {
        "hald-srgb": lambda p: charts._save16(charts.hald(), p),
        "hald-prophoto": lambda p: charts._write_tiff_rgb16(
            p, (charts.hald() * 65535 + 0.5).astype("<u2").tobytes(), 512, 512, ROMM_ICC.read_bytes()
        ),
        "ramp": lambda p: charts._save16(charts.ramp(width=2048, band=48), p),
        "hues": lambda p: charts._save16(charts.hues(width=1440, band=80), p),
        "freq": lambda p: charts._save16(charts.freq(width=2000, height=800), p),
    }
    scratch = ROUND / ".base-charts"
    scratch.mkdir()
    for kind, generate in generators.items():
        base_images[kind] = scratch / f"{kind}.tif"
        generate(base_images[kind])

    manifest = {"charts": [], "photos": []}
    for name, kinds, attrs, elems in chart_variants():
        for kind in kinds:
            target = CHARTS / f"c1_{kind}_{name}.tif"
            subprocess.run(["cp", str(base_images[kind]), str(target)], check=True)
            embed(minimal_packet(attrs, elems), target)
            manifest["charts"].append({"file": target.name, "chart": kind, "variant": name, "settings": attrs, "curves": sorted(elems)})

    # --- photos ---
    preset_attrs, preset_elems = preset_settings(ROOT / "bluesky2-updated.xmp")
    for scene in SCENES:
        base_sidecar = (REFERENCE / f"{scene}.xmp").read_text(encoding="utf-8")
        variants = photo_variants()
        variants.append(("pv11_full_bluesky2", {k: v for k, v in preset_attrs.items() if not re.match(r"^(WhiteBalance|Incremental\w+|Temperature|Tint)$", k)} | {"ProcessVersion": "11.0"}, preset_elems, "pv11"))
        if scene != "P1013558":
            variants.append(("full_bluesky2", {k: v for k, v in preset_attrs.items() if not re.match(r"^(WhiteBalance|Incremental\w+|Temperature|Tint)$", k)}, preset_elems, None))
            variants.append(("neutral", {}, {}, None))
        for name, attrs, elems, special in variants:
            stem = f"p1_{scene}_{name}"
            raw = PHOTOS / f"{stem}.RW2"
            subprocess.run(["cp", "-c", str(REFERENCE / f"{scene}.RW2"), str(raw)], check=True)
            sidecar = sidecar_with(base_sidecar, attrs, elems)
            if special == "adobe-standard":
                sidecar = remove_look(sidecar)
            (PHOTOS / f"{stem}.xmp").write_text(sidecar, encoding="utf-8")
            manifest["photos"].append({"file": raw.name, "scene": scene, "variant": name, "settings": attrs, "curves": sorted(elems), "special": special})

    (ROUND / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"charts: {len(manifest['charts'])} files, photos: {len(manifest['photos'])} RAW variants")


if __name__ == "__main__":
    main()
