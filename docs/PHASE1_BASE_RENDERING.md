# フェーズ1 設計: RAW基準現像（DCP + Adobe Color）

更新: 2026-09-22 JST。[ENGINE_ROADMAP.md](ENGINE_ROADMAP.md) §7 フェーズ1の実装契約。事前検証（Python試作、`.photobench/engine-research-20260922/dcp-base-prototype/`）で、同じ処理順が領域平均で平均ΔE00 1.2〜1.6を達成している。

## 目的

プリセットを掛ける前の状態で、アプリのRAW表示・書き出しをLightroom既定（Adobe Standard + Adobe Color、As Shot WB）と一致させる。ここが合わないと、以降の操作別計測はすべて「土台の差」を背負う。

## 合格条件

- オーナーの3枚のRAW（P1013558 / P1013207 / P1012822）で、LR既定JPEGとの**倍率合わせ後・30×20領域平均**の平均ΔE00 ≤ 2.0、平均EV差 ≤ 0.05、彩度比 0.95〜1.05。測定は `scripts/lr_measure/compare_renders.py`。
- 中心／中間／周辺で系統的な差が無い（レンズ周辺光量補正はフェーズ4。P1012822の周辺2.6は既知）。
- Python試作（ヘッダ20バイト修正版）と Swift 実装の一致: 同じ入力色64点で各段の出力が相対1e-3以内。
- 既存テスト非回帰（既知8件の校正manifest失敗を除く）。JPEG／既存Core Image経路の出力は変わらない。
- DCPが見つからないRAWは従来のCore Image経路へ自動フォールバックし、UIにその旨を表示する。

## 処理順（DNG SDK `dng_render_task::ProcessArea` に準拠）

```text
LibRaw: RW2 → 黒引き・As Shot WB・デモザイク（AHD）・ハイライトはクリップ・**色変換なし（output_color=0）**・リニア16bit
  → [Stage M] カメラRGB → リニアProPhoto（ForwardMatrix1/2 を撮影時の相関色温度で補間。XYZ D50 → ProPhoto を畳み込んだ3×3）
  → [Stage H] DCP HueSatMap（90×30×1、光源補間、ProPhoto HSVで三線形。RefBaselineHueSatMap）
  → [Stage E] 露出ゲイン 2^(baselineEV + userEV)   ← フェーズ1では userEV = 0
  → [Stage L] DCP LookTable（36×8×16）→ Adobe Color LookTable（36×16×16）
  → [Stage T] ACR3既定トーンカーブ（1025点テーブル、RefBaselineRGBTone: 色相保持）
  → [Stage C] Adobe Color の ToneCurvePV2012（0..255の点列、DNG spline）を RGBTone で適用  ※暫定。§注1
  → リニアProPhoto → extended linear sRGB（作業空間。負値・1超は保持）
  → 既存 RenderEngine.apply（ユーザー編集）→ 既存の出力変換
```

**注1（未確定）:** Stage C の適用方法は試作の3案（a: sRGBエンコード後に各ch、b: リニア値へRGBTone、c: 適用しない）の差が0.3 ΔE以内で、位置ずれのノイズ以下。**round0の `only-pointcurve` と、次回計測の「CameraProfile=Adobe Standard（Look無し）」で確定する。** フェーズ1では b で実装し、切り替え可能にしておく。

**注2:** Stage E の baselineEV は「LibRawのホワイト正規化 → Adobeのスケール」の差で、RW2には記録が無い。試作のfit値 +0.058／+0.041／+0.071 の平均 **+0.057 EV** を `Panasonic DC-S5` の定数として持つ。未知機種は0。出典をコードコメントに残す。

**注3:** ProPhoto作業空間はACRと同じ。既存の編集チェーン（extended linear sRGB）へ渡す際に3×3で変換する。負値は保持する（既存の terminal gamut compression が処理する）。

## 実装方式

### GPU実装は「3D LUT（CIColorCube）」を段ごとに焼く

HueSatMap／LookTable／RGBTone は画素ごとの色変換なので、CPUで 64³ の3D LUTを生成し `CIColorCube` で適用する。CIKL kernel（CIColorKernel）は補助テーブルを参照できないため、この方式が現行のCore Image構成と両立する。

- **入力の符号化:** リニア値のまま 64³ に切ると暗部の分解能が足りない。cube の前後に `CIGammaAdjust`（power 1/1.8 → cube → power 1.8 相当。ProPhotoの伝達特性に合わせる）を置き、cube はガンマ符号化された値で索引する。cube の出力もガンマ符号化で持ち、後段で復号する。
- **定義域:** cube は [0,1] を clamp する。Stage M 直後の値は LibRaw のクリップにより概ね [0,1]（白 = 1.0）。負値は0へ、1超はクリップ（ACRも `RefBaselineRGBTone` で [0,1] に pin する）。この制限は将来、露出+のHDR領域を扱うときに見直す（cube の定義域を 2.0 まで広げる等）。
- **cube の分割:** 後続フェーズでユーザー操作を差し込む位置が Stage E の前後になるため、cube は **H（Stage H）／L（Stage L）／TC（Stage T+C）** の3つに分け、E は `CIExposureAdjust`（乗算）で挟む。3つの cube は生成コストが小さい（64³ = 262,144点 × 3、数十ms）ので、プロファイル読込時に生成してキャッシュする。
- **CPU参照実装:** cube 生成に使う純Swiftの関数群（`AdobeColorMath`）が正であり、Swift Testing でPython試作の出力と照合する。GPU出力は CPU 参照と ΔE 0.1 以内であることをテストする（cube の補間誤差の確認）。

### RAWデコード: LibRaw（Homebrew 0.21.4、`libraw_r`）

- SwiftPM: `systemLibrary` target `CLibRaw`（`pkgConfig: "libraw_r"`, `providers: [.brew(["libraw"])]`, `module.modulemap` は `libraw/libraw.h` を umbrella に）。Swift から巨大な `libraw_data_t` を直接読むのが不安定なら、小さなC shim target（`CLibRawShim`）に「開く→unpack→process→16bit RGB と cam_mul・make/model・black/maximum・lens/focal を返す」関数を置く。
- パラメータ: `output_color=0`（カメラ色空間）、`use_camera_wb=1`、`no_auto_bright=1`、`gamm=[1,1]`、`output_bps=16`、`highlight=0`、`user_qual=3`（AHD）。`ImageDecodeIntent` が 3000px 以下を要求する場合は `half_size=1`。
- 出力は RGB16 → RGBA16（vImage）→ `CIImage(bitmapData:format:.RGBA16, colorSpace: nil)`（= 作業空間の生の数値として扱う）。
- ライセンス: LibRaw は LGPL-2.1 / CDDL-1.0 の選択制。動的リンク。`docs/ENGINE_RESEARCH.md` の記載どおり、配布時に表示義務を満たす。

### プロファイル資産の解決（`AdobeProfileLocator`）

探索順（存在する最初のもの）:
1. `~/Library/Application Support/Adobe/CameraRaw/CameraProfiles/**/*.dcp`
2. `/Library/Application Support/Adobe/CameraRaw/CameraProfiles/**/*.dcp`
3. `/Applications/Adobe Lightroom CC/Adobe Lightroom.app/Contents/Resources/CameraProfiles/Adobe Standard/*.dcp`
4. `/Applications/Adobe Lightroom Classic/Adobe Lightroom Classic.app/Contents/Resources/CameraProfiles/**`（存在すれば）

一致条件は DCP の `UniqueCameraModel`（例 `Panasonic DC-S5`）と LibRaw の make+model の大小文字無視一致。`ProfileName == "Adobe Standard"` を優先。Adobe Color は各インストール先の `Settings/Adobe/Profiles/Adobe Raw/Adobe Color.xmp`。**資産はリポジトリへコピーしない。** 見つからない場合は `nil` を返し、呼び出し側がCore Image経路へフォールバックする。

### ファイル構成（新規）

```
Sources/CLibRaw/module.modulemap                   systemLibrary
Sources/CLibRawShim/{include/CLibRawShim.h, shim.c} 必要なら
Sources/PhotoCore/AdobeProfile/
  DCPProfile.swift          .dcp（TIFF IFD, magic "IIRC"）のタグ読取: ColorMatrix1/2, ForwardMatrix1/2, CalibrationIlluminant1/2,
                            ProfileHueSatMapDims/Data1/Data2, ProfileLookTableDims/Data, ProfileToneCurve, HueSatMapEncoding, LookTableEncoding,
                            BaselineExposureOffset, DefaultBlackRender, UniqueCameraModel, ProfileName
  AdobeLookXMP.swift        Adobe Color.xmp: crs:LookTable id, Table_<id> blob（独自base85 → zlib）, ヘッダ u32×5（type 0, version 1, hue, sat, val）+ float32×3（hueShift, satScale, valScale）+ 末尾4バイト, ToneCurvePV2012 点列
  AdobeProfileLocator.swift 上記の探索
  ColorSpec.swift           dng_color_spec / dng_temperature の移植: 中立色→xy（反復）、xy→CCT・mired補間重み、ForwardMatrix補間、XYZ D50→ProPhoto
  HueSatMap.swift           テーブル型と RefBaselineHueSatMap（HSV三線形・色相wrap・符号化テーブル対応）
  RGBTone.swift             RefBaselineRGBTone、ACR3既定テーブル（dng_render.cpp の値）、DNG spline solver
  AdobeBaseCalibration.swift 機種別 baselineEV（DC-S5 = +0.057、出典コメント）
Sources/PhotoCore/AdobeBaseRenderer.swift          Stage M〜C を CIImage graph に組む。cube 生成・キャッシュ。CPU参照 `evaluate(cameraRGB:) -> ProPhoto`
Sources/PhotoCore/LibRawDecoder.swift              ImageDecoding 準拠。DecodeInfo.backend = "LibRaw 0.21.4 + Adobe DCP"、calibrationID にプロファイル名・baselineEVを記録
Sources/PhotoCore/PhotoDecoder.swift               RAW拡張子 → LibRawDecoder（DCPあり）／無ければ CoreImageDecoder。環境変数 PHOTO_BENCH_RAW_ENGINE=coreimage で強制
Sources/PhotoBenchRender/main.swift                 CLI: photobench-render <入力> --output <path> [--preset <xmp>] [--engine libraw-dcp|coreimage] [--max-dimension N] [--stage matrix|huesat|look|tone|full]
Tests/PhotoCoreTests/AdobeProfileTests.swift        パーサ・数学・Python fixture との照合（資産が無い環境では skip）
Tests/PhotoCoreTests/AdobeBaseRendererTests.swift   cube vs CPU 参照、恒等テーブルで恒等、単調性
Tests/Fixtures/phase1/*.json                        Python試作が出力した照合値（各段64色、補間行列、テーブルのMD5）。Adobeのテーブル本体は含めない
```

### 既存コードとの接点

- `DecodedPhoto.image` は基準現像後（作業空間）の画像。`RenderEngine.apply(settings:)` はそのまま動く。`DecodeInfo.isRAW = true`、`isBoundedSRGBRaster = false`。
- `DecodedPhoto` に `adobeBase: AdobeBaseRenderer.Handle?` を追加し、Stage M直後の画像とプロファイル資産を保持する（フェーズ2/3でユーザー操作を段の間へ差し込むため。フェーズ1では未使用）。
- `EditorModel` の表示: RAW読込後に「現像: Adobe Standard + Adobe Color（LibRaw）」または「現像: Core Image（プロファイル未検出）」を1行表示する。
- 既存の `RAWCalibrationProfile`（Core Image用 boost 0.9 設定）は触らない。

## 検証手順

1. `python3 .photobench/engine-research-20260922/dcp-base-prototype/scripts/run_all.py` をヘッダ20バイト修正後に再実行し、`Tests/Fixtures/phase1/` の照合値を出力する（run_all に fixture 出力を追加）。
2. `swift test --filter 'AdobeProfile|AdobeBaseRenderer'`。
3. `swift run photobench-render` で3枚を書き出し、`python3 scripts/lr_measure/compare_renders.py --reference exports/editing-mvp-20260922/lightroom-reference --renders <dir>` で判定。
4. `scripts/build-app.sh` → アプリで3枚を開き、表示・書き出しが CLI と一致すること（同じ graph）。
5. 結果と数値は `docs/PROGRESS.md` と ENGINE_ROADMAP §7 へ主担当が記録する。

## 範囲外（後のフェーズ）

レンズ歪曲・周辺光量（フェーズ4。RW2内蔵データの適用）、シャープ／NR、絶対WB（Temperature/Tint → xy → カメラ中立。フェーズ2で `ColorSpec` を再利用）、露出のHDR定義域、プレビュー速度の最適化、DCPが無い機種の自作プロファイル。
