# フェーズ2/3 設計: C2（色操作）と C3（ハイライト／シャドウの空間処理）

更新: 2026-09-22 JST。[PHASE2_DEVELOP_PIPELINE.md](PHASE2_DEVELOP_PIPELINE.md)（C1）の続き。同定結果の正は `.photobench/phase2/{hsl,color,spatial}/model.md` と各 `*_model.py`（動作実証済みの Python 参照実装）。Swift は **参照実装の忠実な移植**とし、式や定数を独自に変えない。

## 全体の順序（確定分と v1 の仮置き）

```text
[WB] → [M] → [H] → [E: Exposure] → [L] → [T]                            （C1、RAW）
  → [P1] Contrast                                                         （C1）
  → [S ] Highlights2012 / Shadows2012（空間処理: ベース／ディテール分離）    （C3）  ※位置は v1 仮置き（Contrast の後、Whites/Blacks の前。LR の基本パネル順）
  → [P2] Whites → Blacks → Parametric → Point curve                        （C1）
  → [Q ] Vibrance → Saturation → HSL → Color Grading                        （C2）  ※Vibrance⇔Saturation の順は未決着。Vibrance→Saturation を採用
  → [Cal] Camera Calibration（v1: 出力参照の 3×3 行列。RAW 実写では彩度がやや不足するため要再fit）（C2）
  → リニアProPhoto → 作業空間
```

根拠: `.photobench/phase2/raw-validated.md`（Calibration は「行列直後」より「出力参照」の方が良い。HSL はどちらでも同水準）、`color/model.md §6`（Calibration→…→{Vibrance,Saturation}→HSL→Grading）、`spatial/model.md §4`（トーンカーブ後がやや良い）。Calibration の位置は色系解析（Calibration が最初）と RAW 実写（出力参照が良い）で食い違うため、**v1 は出力参照の最後**に置き、C1/C2 完了後の実写ゲートで再判断する。

## C2: 色操作（すべて画素単位 → cube Q として焼く）

1. `EditSettings` 追加: `vibrance` / `saturation`（既存）、`hsl`（既存）、`calibration`（ShadowTint, Red/Green/Blue Hue/Saturation）、`colorGrading`（shadow/midtone/highlight/global の hue/sat/lum、`blending`、`balance`。旧 `SplitToning*` は同じ値へ写す: ShadowHue/Sat → shadow、HighlightHue/Sat → highlight、`SplitToningBalance` → balance）。`XMPPresetParser` で読む。
2. `Sources/PhotoCore/AdobeProfile/ColorOps.swift`: `color_model.py` の移植（`saturation`、`vibrance`、`calibration`、`colorGrading`）と `hsl_model.py` の移植（`hsl`: cos² クロスフェードの帯重み、Hue の境界予算、Sat の ±非対称式、Lum の帯別 (K,P,Q) 表）。関数は `SIMD3<Double>`（リニアProPhoto）→ `SIMD3<Double>`。`applyColorOps(settings)` で Q の順に合成。
3. `AdobeBaseRenderer.Handle.image(settings:)`: cube P の後に cube Q（`applyColorOps`）、その後に Calibration の `CIColorMatrix`（3×3。負値のクリップは cube と同じ扱い）。非RAW経路も同じ。
4. **旧近似の撤去**: `CIVibrance` / `CIColorControls`（彩度）/ OKLCh `PerceptualColorMixer` の描画は新経路では使わない（`PerceptualColorMixer.swift` と `mixerKernel` は削除して良い。校正 manifest 系の参照があれば残骸を最小化して説明）。
5. compatibility: supported に Vibrance / Saturation / HSL 24項目 / ColorGrade* / SplitToning* / Calibration 6項目（ShadowTint は「効果なし」として supported 扱い）。

### C2 テスト・ゲート
- fixture `Tests/Fixtures/phase2/color-ops.json`（`color_model.py` / `hsl_model.py` から生成: 64色 × {saturation ±50/±100, vibrance ±50/±100, hsl 各帯 sat+60 / hue+60 / lum+60 の代表 6 個, calibration 6 スライダー +50, grading 4 バンド代表 4 個}）を相対 1e-4 で照合。
- 実写ゲート（`compare_renders.py`、P1013558 / P1013207）: `SaturationAdjustmentOrange_+60`、`LuminanceAdjustmentBlue_+60`（参照 `exports/lr-measure/round1/lr-export-photos/p1_<scene>_<variant>.jpg`）平均ΔE ≤ 2.0、`GreenHue_+50` / `BlueSaturation_+50` ≤ 2.6（現状の到達点 1.9〜2.5。実測値を報告）。round0 の `r0_raw_only-hsl` / `only-saturation` / `only-vibrance` / `only-splittoning` / `only-calibration`（P1013558）≤ 2.0（splittoning は ≤ 2.5）。

## C3: Highlights2012 / Shadows2012（空間処理、v1）

参照: **`spatial-v2/model.md`、`spatial-v2/spatial_model_v2.py`**（`apply_highlights_shadows(rgb_linear, highlights, shadows, scale_px=32, order="highlights_first")`。Burt–Adelson ピラミッド＋高速局所ラプラシアン（Paris–Hasinoff–Kautz の remapping、Aubry の離散化）。大域ゲイン表は最終ベース段にだけ加算。Highlights: α=β=1、5段。Shadows: α=1、β=0.85、σr=0.5段、2段。H→S の順）。v1（`spatial/`、単一スケールのぼかし＋適応ゲイン）は比較用。H/S 単体12ケースの画素ΔE00 2.37（v1 2.55）、領域平均 2.08。Whites / Blacks は C1 の P2 で扱うので C3 では **Highlights / Shadows だけ**。

構造（log2 輝度 `l = log2 Y`、Y = ProPhoto の Y。参照実装 `spatial_model_v2.py` のとおり）:
1. ガウシアンピラミッド G0..Gn（Burt–Adelson 5×5、段数は操作ごと: Highlights 5、Shadows 2。`scale_px` は 1500×1000 解析時の基準で、原寸では画像の長辺比で換算する）
2. 各段・各画素で局所平均 g0 に対する remapping `r(i; g0)`（|i−g0| ≤ σr: `g0 + sign·σr·(|i−g0|/σr)^α`、> σr: `g0 + sign·(β·(|i−g0|−σr)+σr)`）からラプラシアン係数を作る高速局所ラプラシアン（Aubry の離散化: g0 を σr 刻みでサンプルし補間）
3. 最粗段のベースに大域ゲイン `gain(op, value, base)`（`GAIN_TABLE_100/50` の区分線形、0→50 比例、50→100 表間補間）を加算し、ピラミッドを再構成
4. `Y' = 2^l'`、RGB を `Y'/Y` でスケール（色相・彩度比を保持）。Highlights → Shadows の順

Core Image / Metal 実装: ピラミッド（`CILanczosScaleTransform` ではなく 5×5 ガウシアン＋2倍縮小の `CIKernel`、または `MPSImageGaussianPyramid`）と remapping の合成を Metal compute（`MTLComputePipelineState`）で書き、CIImage との受け渡しは `CIImage(mtlTexture:)` / `CIRenderDestination` を使う。CIKL では配列（ゲイン表）とマルチスケールの合成が書きにくいので、C3 は **Metal compute を PhotoCore に導入する最初の箇所**とする（既存 `MetalPreviewRenderer` に MTLDevice/command queue の流儀がある）。プレビュー（縮小 decode）と原寸で半径がずれないよう、段数・σ は **原寸換算**で決めて `appliedScaleFactor` を反映する。処理時間の目安（参照実装、1500×1000 の numpy）は `spatial-v2/model.md` を参照。

位置: P1（Contrast）の後、P2（Whites…）の前（v1 仮置き）。cube 間に挟むため、cube P は P1 と P2 の2つに分ける（P2 のキャッシュキーに Contrast は含めない）。

### C3 テスト・ゲート
- CPU 参照（純Swift、縮小画像で）と CI 実装の一致（ΔE00 ≤ 0.3、1500×1000 で）。
- 実写ゲート（P1013558 / P1013207 / P1012822、参照は round1 の `Highlights2012_-100/-50/+50`、`Shadows2012_-50/+50/+100`。ゲート用 XMP は `.photobench/phase2/c3-gate/`）: H/S 単体 12 ケースの **領域平均ΔE ≤ 2.3、画素ΔE（1500×1000）≤ 2.6**（参照実装 v2 の到達点 2.08 / 2.37）、ハローの目視（比較画像を `exports/phase3/` へ）。
- `tone-all_bluesky2`（3枚）: 参照 `p1_<scene>_tone-all_bluesky2.jpg`（P1013558 は round0 の `r0_raw_tone-all.jpg`）で平均ΔE を報告（合格条件は置かない。C1〜C3 を通した到達点の記録）。

## 完了後の総合確認（フェーズ2/3 の出口）

- 更新版 bluesky2 全体: `r0_raw_full.jpg`（P1013558）、`p1_P1013207_full_bluesky2.jpg`、`p1_P1012822_full_bluesky2.jpg` と比較。開始時点の 17〜22 に対し、到達値を記録。
- 未使用プリセット（night / pastel / colorful）と JPEG 入力（`r0_jpg_*`）でも数値を出す（合格条件は §7 フェーズ5 で）。
