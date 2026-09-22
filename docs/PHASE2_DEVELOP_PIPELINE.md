# フェーズ2 設計: 現像パイプライン（計測で確定した操作の実装）

更新: 2026-09-22 JST。[ENGINE_ROADMAP.md](ENGINE_ROADMAP.md) §7 フェーズ2の実装契約。計測結果の正は `.photobench/phase2/`（`raw-validated.md`、`tone/model.md`、以降 `hsl/` `color/` `spatial/`）。

## 確定した構造（RAW）

```text
LibRaw: カメラRGB（As Shot WB済み、白=1.0）
  → [WB]  XMPが WhiteBalance=Custom（Temperature/Tint）のとき: 新しい中立色で再バランス（対角行列）    ← C1
  → [M]   ForwardMatrix（新しい白色点 xy で再補間）→ リニアProPhoto
  → [H]   DCP HueSatMap（xy で再補間）
  → [E]   2^(baselineEV + Exposure2012)                                       ← Exposure は「ここ」のリニア倍率（実写で確定）
  → [S]   （フェーズ3: Highlights2012 / Shadows2012 の空間処理。位置は spatial 解析の結果で決める）
  → [L]   DCP LookTable → Adobe Color LookTable
  → [T]   ACR3 既定トーンカーブ（RGBTone）→ Adobe Color 点カーブ（sRGB符号化 RGBTone）
  → [P]   出力参照の画素操作（sRGB符号化 ProPhoto、RGBTone 色相保持）:                 ← C1
            Contrast2012 → Whites2012 → Blacks2012 → Parametric（4領域） → ToneCurvePV2012（RGB → R/G/B 各ch）
  → [Q]   （C2: HSL / Calibration / Color Grading / Vibrance / Saturation。位置と式は hsl・color 解析の結果で決める）
  → リニアProPhoto → extended linear sRGB（作業空間）
  → 既存: 未モデル化操作の暫定近似（下記）→ ユーザーの相対色温度／色かぶり → 出力変換
```

非RAW（JPEG/HEIC/PNG/TIFF）: 作業空間（ICC変換済みリニアsRGB）→ リニアProPhoto → **Exposure2012（非RAWの式: リニア空間の anchored power-ratio、`tone_model.apply_exposure`）** → [P] → [Q] → リニアsRGB。プロファイルのトーンカーブは無い（LRの非RAW入力は "Color" プロファイル＝恒等）。

根拠（`.photobench/phase2/raw-validated.md`）: Contrast / Whites / Blacks はプロファイルのトーンカーブの**後**に置くとLRと一致（前に置くとEVが±0.3ずれる）。Exposure だけがトーンカーブ**前**のリニア倍率。ポイントカーブと parametric は sRGB符号化空間で同定された（チャート）。

## C1 の範囲

1. **XMPの型付き読み込みを拡張**（`EditSettings` に追加。既存レコードは `decodeIfPresent` で既定値）:
   `parametricShadows/Darks/Lights/Highlights`（−100..100）、`parametricShadowSplit/MidtoneSplit/HighlightSplit`（既定 25/50/75）、`curveRefineSaturation`（既定 100。0 の式は未同定なので値は保持するだけ）、`texture`、`clarity`、`dehaze`（保持のみ。フェーズ3）。`whiteBalance` は既存（mode / temperature / tint / incremental）。`XMPPresetParser` の compatibility 表示を更新（下記「対応状況」）。
2. **`ToneOps`（純Swift、CPU参照）**: `.photobench/phase2/tone/tone_model.py` の忠実な移植。
   - `exposureNonRaw(ev)`: リニア空間 anchored power-ratio `m·xᵃ/(xᵃ+c(1−x)ᵃ)`、EV=−2/−1/0/+1/+2/+3 の (m,a,c) を区分線形補間、色へは sRGB符号化 RGBTone（`f_encoded = enc∘f∘dec`）。
   - `contrast(amount)`: sRGB符号化、pivot 0.5 の対称 power-ratio、`e = exp(0.419·clip(amount/100,−1,1))`。
   - `whites(amount)` / `blacks(amount)`: sRGB符号化、anchored power-ratio（Whites anchor=0、Blacks anchor=1）、`f = clip(anchor + m·(R(u;a,c) − anchor), 0, 1)`、(m,a,c) は amount −100/−50/0/50/100 の表を区分線形補間（表は tone_model.py の `_WHITES_*` / `_BLACKS_*`）。
   - `parametric(shadows, darks, lights, highlights, splits)`: sRGB符号化、非対称 raised-cosine 窓の和（`_asym_cosine_window`、ピーク位置・支持域・peak_delta は tone_model.py のとおり。Highlights のピーク位置は `hs + 0.36·(1 − hs)`）、amount は ±60 実測からの線形。
   - `pointCurve(points)`: **DNGスプライン**（既存 `DNGSpline`）＋ sRGB符号化 RGBTone（既存 `RGBTone.applyEncoded`）。R/G/B 個別カーブは各チャンネルに per-channel（符号化空間）。`ToneCurveModel`（区分線形）は廃止。
   - 合成 `applyPostOps(settings)`: 上の順（Contrast → Whites → Blacks → Parametric → Point）。
   - 各関数は `SIMD3<Double>`（リニアProPhoto）→ `SIMD3<Double>`。
3. **絶対WB（RAW）**: `ColorSpec` に `xy(fromTemperature:tint:)`（DNG SDK `dng_temperature.cpp` の `LegacyGetXY`: Robertson 等温線表、`kTintScale = −3000`。T < 2000 は 2000 にクランプ）を追加。`AdobeBaseAssets` を「as-shot 中立色」と「XMPの WB」から作る init を追加: Custom のとき xy → `cameraWhite(colorMatrix(xy), xy)` → 中立色 `neutral'`（G=1）→ 再バランス係数 `asShotNeutral / neutral'`（対角。Stage M の前に `CIColorMatrix`）→ M/H を xy で再補間。As Shot はそのまま。増分WB（非RAW）は未対応のまま保持。
4. **`AdobeBaseRenderer`**: `Handle.image(settings:)`（WB係数、userExposureEV、Stage TC の後に cube P）。cube P は `ToneOps.applyPostOps` を 64³（ガンマ1.8索引、既存方式）で焼く。キーは P に関わる設定値のハッシュ。生成は `DispatchQueue.concurrentPerform` で 100ms 以下を目標。
5. **`RenderEngine.apply`** の接続: `decoded.adobeBase` があれば新経路（WB → … → P）で作業空間画像を作り、**Exposure / Contrast / Whites / Blacks / Parametric / Point curve は旧近似（`BasicToneModel`、`toneCurveKernel`、`CIExposureAdjust`）に渡さない**。`BasicToneModel` は Highlights / Shadows だけの暫定近似として残す（フェーズ3で置換）。Vibrance / Saturation / HSL の旧近似（`CIVibrance` / `CIColorControls` / OKLCh mixer）は C2 まで残す。非RAW（`adobeBase == nil`）は「作業空間 → ProPhoto → exposureNonRaw → P → 作業空間」を同じ cube 方式で行う。ユーザーの相対色温度／色かぶりは最後（既存）。
6. **CLI** `photobench-render --preset <xmp>` はこの経路を通す（既存の `XMPPresetParser.parse(...).applying(to:)` のまま）。

## 対応状況の表示（`CompatibilityLevel`）

- supported: Exposure2012、Contrast2012、Whites2012、Blacks2012、Parametric*、ToneCurvePV2012（RGB／R／G／B）、WhiteBalance（Custom Temperature/Tint、RAWのみ）、CameraProfile "Adobe Standard"/"Adobe Color"
- approximate（暫定近似のまま）: Highlights2012、Shadows2012、Vibrance、Saturation、HSL 24項目
- unsupported（保持のみ）: Texture、Clarity2012、Dehaze、Color Grading／Split Toning、Calibration、Sharpness／NR、Lens、Grain、Vignette、CurveRefineSaturation ≠ 100、IncrementalTemperature/Tint

## テストとゲート

- fixture: `Tests/Fixtures/phase2/tone-ops.json` を `tone_model.py` から生成（入力64色 × {exposureNonRaw ±1/+2、contrast ±50/±100、whites ±50/±100、blacks ±50/±100、parametric 各領域 ±60、point S / 逆S、合成2組}）。Swift の `ToneOps` は相対 1e-4 で一致。
- `ColorSpec.xy(fromTemperature:tint:)`: 5000K/0 → xy ≈ (0.3457, 0.3585) 近傍（D50相当）、6500K/0 → (0.3127, 0.3290) 近傍（±0.003）、tint の符号で v が動く。
- cube P vs CPU: ΔE00 ≤ 0.15（64点）。
- 実写ゲート（`scripts/lr_measure/compare_renders.py`、領域平均）。P1013558 の round0 書き出し（`exports/lr-measure/round0/lr-export/r0_raw_only-*.jpg`）を参照に、同じ設定だけを含む XMP を作って `photobench-render --preset` で描画:
  | 変種 | 参照 | 合格 |
  |---|---|---|
  | only-exposure（+0.79） | r0_raw_only-exposure.jpg | 平均ΔE ≤ 2.0、EV ≤ 0.05 |
  | only-contrast（−6） | r0_raw_only-contrast.jpg | 同上 |
  | only-whites（−56） / only-blacks（+90） | r0_raw_only-whites/blacks.jpg | 平均ΔE ≤ 2.2、EV ≤ 0.12（RAWのクリップ側は要再fit。実測値を報告） |
  | only-parametric / only-pointcurve | r0_raw_only-parametric/pointcurve.jpg | 平均ΔE ≤ 2.0 |
  | Temperature 4000 / 7500、Tint +30 | exports/lr-measure/round1/lr-export-photos/p1_P1013558_Temperature_4000.jpg 等 | 平均ΔE ≤ 2.0 |
  | neutral（回帰） | LR既定 | 1.22 前後を維持 |
- 既存テスト非回帰（既知8件除く）。JPEG入力は「exposureNonRaw + P」に切り替わるので、既存の JPEG 系テストで期待値が旧近似に依存するものは新経路に合わせて更新し、理由を書く。

## 範囲外（C2 / フェーズ3）

HSL・Calibration・Color Grading・Vibrance／Saturation（hsl / color 解析の完了後）、Highlights／Shadows／Texture／Clarity／Dehaze（spatial 解析の完了後）、Refine Saturation 0、非RAWの増分WB、レンズ補正。
