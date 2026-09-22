#!/usr/bin/env python3
"""LR計測 round0: 往復確認と、更新版bluesky2の操作別分解。

目的:
  1. Lightroom(9.x, ローカルタブ)が、外部で生成したXMP（RAWはサイドカー、JPEG/TIFFは埋め込み）の
     現像設定を読むかを確認する。
  2. サイドカーで全設定を与えた書き出しが、オーナーが手でプリセットを当てた書き出しと一致するかを確認する。
  3. プリセットを「1操作ずつ」に分解した教師画像を得る（どの操作がどれだけ効くかの最初の実測）。

入力の写真・LR書き出しは個人データなのでGit管理外（exports/ 以下）に置く。原本は変更しない。
使い方: photo-edit-app 直下で  python3 scripts/lr_measure/make_round0.py
"""
from __future__ import annotations

import json
import re
import shutil
import subprocess
from pathlib import Path

from PIL import Image, ImageCms

ROOT = Path(__file__).resolve().parents[2]
REFERENCE = ROOT / "exports/editing-mvp-20260922/lightroom-reference"
ROUND = ROOT / "exports/lr-measure/round0"
INPUT = ROUND / "input"
PRESET = ROOT / "bluesky2-updated.xmp"
SCENE = "P1013558"

# プリセットXMPのうち、現像設定ではない管理用の属性。
NON_SETTING = re.compile(
    r"^(PresetType|Cluster|UUID|Supports\w+|RequiresRGBTables|ShowInPresets|ShowInQuickActions|"
    r"CameraModelRestriction|Copyright|ContactInfo|Version|ProcessVersion|HasSettings)$"
)
# RAWでは増分WBが意味を持たず、Customだけ渡すと色温度が未定義になるため、RAWのサイドカーにはWBを書かない。
WHITE_BALANCE = re.compile(r"^(WhiteBalance|IncrementalTemperature|IncrementalTint|Temperature|Tint)$")
CURVE_ELEMENTS = ["ToneCurvePV2012", "ToneCurvePV2012Red", "ToneCurvePV2012Green", "ToneCurvePV2012Blue"]

GROUPS: dict[str, re.Pattern[str]] = {
    "exposure": re.compile(r"^Exposure2012$"),
    "contrast": re.compile(r"^Contrast2012$"),
    "highlights": re.compile(r"^Highlights2012$"),
    "shadows": re.compile(r"^Shadows2012$"),
    "whites": re.compile(r"^Whites2012$"),
    "blacks": re.compile(r"^Blacks2012$"),
    "texture": re.compile(r"^Texture$"),
    "vibrance": re.compile(r"^Vibrance$"),
    "saturation": re.compile(r"^Saturation$"),
    "parametric": re.compile(r"^Parametric\w+$"),
    "pointcurve": re.compile(r"^(ToneCurveName2012|CurveRefineSaturation)$"),
    "hsl": re.compile(r"^(HueAdjustment|SaturationAdjustment|LuminanceAdjustment)\w+$"),
    "splittoning": re.compile(r"^(SplitToning\w+|ColorGrade\w+)$"),
    "calibration": re.compile(r"^(ShadowTint|(Red|Green|Blue)(Hue|Saturation))$"),
    # プリセットはシャープとカラーNRを明示的に0へ落としている（LR既定は40 / 25）。
    "detail": re.compile(r"^(Sharp\w+|LuminanceSmoothing|LuminanceNoiseReduction\w+|ColorNoiseReduction\w*)$"),
}
TONE = ["exposure", "contrast", "highlights", "shadows", "whites", "blacks"]


def split_look(text: str) -> tuple[str, str, str]:
    """ネストしたLookブロックは独自のcrs属性とカーブを持つので、置換対象から外す。"""
    start, end = text.find("<crs:Look>"), text.find("</crs:Look>")
    if start < 0 or end < 0:
        return text, "", ""
    end += len("</crs:Look>")
    return text[:start], text[start:end], text[end:]


def preset_settings(path: Path) -> tuple[dict[str, str], dict[str, str]]:
    head, _, tail = split_look(path.read_text(encoding="utf-8"))
    body = head + tail
    attributes = {
        key: value
        for key, value in re.findall(r'\bcrs:(\w+)="([^"]*)"', body)
        if not NON_SETTING.match(key)
    }
    elements = {}
    for name in CURVE_ELEMENTS:
        match = re.search(rf"<crs:{name}>.*?</crs:{name}>", body, re.S)
        if match:
            elements[name] = match.group(0)
    return attributes, elements


def select(attributes: dict[str, str], groups: list[str]) -> dict[str, str]:
    return {k: v for k, v in attributes.items() if any(GROUPS[g].match(k) for g in groups)}


def sidecar_with(base: str, attributes: dict[str, str], elements: dict[str, str]) -> str:
    head, look, tail = split_look(base)
    for key, value in attributes.items():
        pattern = re.compile(rf'(\bcrs:{key}=")[^"]*(")')
        if pattern.search(head):
            head = pattern.sub(lambda m: m.group(1) + value + m.group(2), head, count=1)
        else:
            head = head.replace('crs:HasSettings="', f'crs:{key}="{value}"\n   crs:HasSettings="', 1)
    for name, block in elements.items():
        pattern = re.compile(rf"<crs:{name}>.*?</crs:{name}>", re.S)
        if not pattern.search(head):
            raise SystemExit(f"基準サイドカーに {name} が無い")
        head = pattern.sub(lambda m: block, head, count=1)
    return head + look + tail


def minimal_packet(attributes: dict[str, str], elements: dict[str, str]) -> str:
    """JPEG/TIFF埋め込み用。未指定の項目はCamera Raw側の既定値に任せる。"""
    merged = {"Version": "18.3", "ProcessVersion": "15.4", "HasSettings": "True", "AlreadyApplied": "False"}
    merged.update(attributes)
    attribute_text = "\n".join(f'   crs:{k}="{v}"' for k, v in merged.items())
    element_text = "\n".join(f"   {block}" for block in elements.values())
    return (
        '<x:xmpmeta xmlns:x="adobe:ns:meta/">\n'
        ' <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n'
        '  <rdf:Description rdf:about=""\n'
        '   xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"\n'
        f"{attribute_text}>\n{element_text}\n"
        "  </rdf:Description>\n </rdf:RDF>\n</x:xmpmeta>\n"
    )


def embed(packet: str, image: Path) -> None:
    packet_file = image.with_suffix(".packet.xmp")
    packet_file.write_text(packet, encoding="utf-8")
    subprocess.run(
        ["exiftool", "-q", "-overwrite_original", "-xmp:all=", f"-xmp<={packet_file}", str(image)],
        check=True,
    )
    packet_file.unlink()


def chart(path: Path) -> None:
    """往復確認用の小さな合成チャート（グレーランプ＋色相スイープ）。"""
    import colorsys

    width, height = 1200, 800
    image = Image.new("RGB", (width, height), (118, 118, 118))
    pixels = image.load()
    for x in range(width):
        gray = round(255 * x / (width - 1))
        for y in range(0, 200):
            pixels[x, y] = (gray, gray, gray)
        for row, (s, v) in enumerate([(1.0, 1.0), (0.6, 0.9), (0.35, 0.7), (0.8, 0.45)]):
            r, g, b = colorsys.hsv_to_rgb(x / width, s, v)
            for y in range(240 + row * 140, 240 + row * 140 + 120):
                pixels[x, y] = (round(r * 255), round(g * 255), round(b * 255))
    profile = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    image.save(path, format="TIFF", icc_profile=profile)


def main() -> None:
    if ROUND.exists():
        raise SystemExit(f"{ROUND} が既にある。LRのキャッシュと混ざるため、消すか別のround名にする。")
    INPUT.mkdir(parents=True)
    (ROUND / "lr-export").mkdir()

    attributes, elements = preset_settings(PRESET)
    raw_attributes = {k: v for k, v in attributes.items() if not WHITE_BALANCE.match(k)}
    base_sidecar = (REFERENCE / f"{SCENE}.xmp").read_text(encoding="utf-8")

    variants: dict[str, tuple[dict[str, str], dict[str, str]]] = {"neutral": ({}, {})}
    variants["sat-100"] = ({"Saturation": "-100"}, {})
    for group in GROUPS:
        chosen = select(raw_attributes, [group])
        if chosen:
            variants[f"only-{group}"] = (chosen, elements if group == "pointcurve" else {})
    variants["tone-all"] = (select(raw_attributes, TONE), {})
    variants["color-all"] = (
        select(raw_attributes, [g for g in GROUPS if g not in TONE and g not in ("texture", "detail")]),
        elements,
    )
    variants["full"] = (raw_attributes, elements)

    manifest = []
    for name, (attrs, elems) in variants.items():
        stem = f"r0_raw_{name}"
        raw = INPUT / f"{stem}.RW2"
        subprocess.run(["cp", "-c", str(REFERENCE / f"{SCENE}.RW2"), str(raw)], check=True)  # APFSクローン
        (INPUT / f"{stem}.xmp").write_text(sidecar_with(base_sidecar, attrs, elems), encoding="utf-8")
        manifest.append({"file": raw.name, "kind": "raw-sidecar", "settings": attrs, "curves": sorted(elems)})

    jpeg_variants = {
        "neutral": ({}, {}),
        "sat-100": ({"Saturation": "-100"}, {}),
        "only-highlights": (select(attributes, ["highlights"]), {}),
        "only-shadows": (select(attributes, ["shadows"]), {}),
        "only-blacks": (select(attributes, ["blacks"]), {}),
        "tone-all": (select(attributes, TONE), {}),
        "full": (attributes, elements),
    }
    for name, (attrs, elems) in jpeg_variants.items():
        jpeg = INPUT / f"r0_jpg_{name}.jpg"
        shutil.copyfile(REFERENCE / f"{SCENE}.jpg", jpeg)
        embed(minimal_packet(attrs, elems), jpeg)
        manifest.append({"file": jpeg.name, "kind": "jpeg-embedded", "settings": attrs, "curves": sorted(elems)})

    for name, attrs in {"neutral": {}, "sat-100": {"Saturation": "-100"}, "exposure+1": {"Exposure2012": "+1.00"}}.items():
        tiff = INPUT / f"r0_tif_{name}.tif"
        chart(tiff)
        embed(minimal_packet(attrs, {}), tiff)
        manifest.append({"file": tiff.name, "kind": "tiff-embedded", "settings": attrs, "curves": []})

    (ROUND / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"{len(manifest)} files -> {INPUT}")


if __name__ == "__main__":
    main()
