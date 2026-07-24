# HDR-safe creative pipeline / SDR output transform 設計レビュー入力

## 目的

Photo Bench は macOS 14+ のローカル写真編集アプリで、Core Image RAW 8 と通常画像を
`extendedLinearSRGB` の working space で処理し、preview/JPEG/16-bit TIFF を sRGB へ出力する。
現在の XMP full preset は、BasicTone の後に置いた 64³ `CIColorCubeWithColorSpace` が
入力と LUT node を 0...1 に閉じ込めるため、RAW で complete clip が basic の
4.747%→8.743% / 1.062%→5.215% に悪化している。

今回の slice は、既存の UI と XMP 互換の意味を保ちながら、編集途中の HDR / gamut 外情報を
保持し、SDR sRGB 出力直前で tone と gamut を一度だけ滑らかに収容することを目的とする。
2 scene の Lightroom 比較値へ係数を過適合させず、まず構造的な hard clip をなくす。

## 現状の責務

1. RAW または ImageIO decode
2. `CIExposureAdjust`
3. `BasicToneModel`: extended-linear luminance を RGB 共通 gain で処理し、1超を保持
4. 64³ sRGB cube: tone curve + HSL。`inputExtrapolate` 未指定、node 出力を clamped01
5. `CIVibrance` / `CIColorControls`
6. CIContext が RGBA8/RGBA16 sRGB へ直接出力（ここで hard clip）

監査では identity cube の `[2.0, 0.5, 0.25]` が現状 `[1.0, ...]` に落ちる一方、
`CIVibrance` と `CIColorControls` は float 中間値の 1超/負値を維持することを確認した。

## 提案する今回の責務分離

```text
decode
  → applyWorkingEdits(exposure, BasicTone, curve/color mixer, vibrance/saturation)
       extended-linear、途中 clamp なし
  → prepareForSRGBOutput(toneMapHDR: Bool)
       luminance soft shoulder
       → OKLab/OKLCh soft gamut compression
       → 数値誤差だけ最終 clamp
  → Core Image が sRGB encoding / RGBA8 or RGBA16 quantization
```

`RenderEngine.apply(settings:to:)` は working edits のまま残して synthetic float test から検査可能にし、
preview/JPEG/TIFF の3経路だけが共通の `prepareForSRGBOutput` をちょうど一度呼ぶ。

### 出力 transform の適用ポリシー

- RAW: neutral を含め `toneMapHDR = true`。RAW developer 出力の highlight headroom を収容する。
- JPEG/TIFF: `settings == .neutral` なら出力 transform 全体を bypass し、既存の bounded sRGB を
  pixel identity で維持する。編集が1つでも active なら `toneMapHDR = true`。
- Lightroom reference TIFF の比較用 neutral normalization も bypass されるため、参照画像自体を
  再 tone-map しない。
- 将来 Display P3 等を入力する場合は、neutral raster の destination gamut mapping を別途扱う。
  今回は既存ターゲットの sRGB JPEG/TIFF と DC-S5 RAW に限定する。

このポリシーにより、in-gamut 境界手前から圧縮する perceptual gamut mapper が neutral JPEG の
原色まで微妙に変える副作用を避ける。

## Curve / color mixer

### 今回採用する案

1. `CIColorCubeWithColorSpace` の typed filter を使い `extrapolate = true` を明示する。
   Apple が SDR cube を EDR input/output へ外挿する用途として提供している API を利用する。
2. LUT node の `clamped01` を削除する。curve/HSL luminance の結果が負値または1超でも float で保持する。
3. tone curve は既存 XMP 順序（channel curve → global curve）と sRGB-encoded-domain の意味を維持する。
   cube の境界 slope が 0/1 外を外挿する。少なくとも identity curve で HDR ramp が identity、
   実 preset で異なる HDR 値が同じ1へ潰れないことを hard test にする。
4. HSL 数学は cube 上の HSL/HSV から OKLab/OKLCh へ変更する。
   - cube node の encoded sRGB を extended-linear sRGB へ decode
   - signed cube root を使い OKLab へ変換
   - 現在の8 band center と隣接 band interpolation は UI semantics として再利用
   - neutral protection は `C / max(abs(L), epsilon)` の relative chroma に smoothstep を掛ける
   - hue ±100 = ±30°
   - saturation は `C *= max(0, 1 + adjustment/100)`（-100で無彩色、+100で2倍）
   - luminance は L/a/b を `2^(adjustment/300)` 倍する。OKLab の scale invariance により
     ±100 が RGB の ±1EV 相当になり、hue/chromaticity を保つ
   - linear sRGB へ戻して extended sRGB encode。途中 clamp なし

`extrapolate=true` は恒久的な任意 curve engine より近似的である。identity / plateau / colored HDR ray の
test と実画像 gate を通らなければ、この slice で採用せず、1D curve texture を読む custom kernel へ
切り替える。CIKL→packaged Metal 移行は画質責務と混ぜず後続 slice とする。

## SDR output transform

新しい `SRGBOutputTransform` に CPU model と同式の `CIColorKernel` を置く。
写真は opaque が基本だが、kernel は unpremultiply → mapping → premultiply で alpha edge を壊さない。

### 1. luminance soft shoulder

extended-linear sRGB の `Y = dot(rgb, [0.2126, 0.7152, 0.0722])` を使い、`Y > k` のみ
RGB 共通 gain で圧縮する。

```text
d = Y - k
T(Y) = k + (1-k) * d / (d + 1-k)
rgb *= T(Y) / Y
```

- `Y <= k` は identity
- knee で value と一次微分が連続
- 単調で、無限遠から1へ漸近
- channel ratio / neutral を保持

初期値 `k = 0.90` は規格値ではなく versioned model constant。2 scene の最適化結果ではなく、
0.75...0.9 という一次資料/実装例の保守的な端を採用する。採用前に ramp と実画像で検証する。

### 2. OKLCh soft gamut compression

tone 後 RGB を OKLab へ変換し、各 `(L, h)` の target linear-sRGB `Cmax` を 12回の二分探索で求める。
探索は `C=0...1`、in-gamut 条件は各 channel が epsilon 内で 0...1。L は数値安全のため0...1へ収め、
L が範囲外へ来た pathological input は neutral endpoint へ収束させる。

`q = C / (0.995 * Cmax)` とし、zone-of-trust `t = 0.90` までは identity、以降は C1 soft-knee:

```text
qout = q                                           (q <= t)
d = q - t
qout = t + (1-t) * d / (d + 1-t)                  (q > t)
Cout = qout * (0.995 * Cmax)
```

L と hue を保ち、target white へ近づくほど利用可能な C が自然にゼロへ縮む。逆変換後は
浮動小数点の残差だけ 0...1 に clamp する。CIContext に sRGB OETF を一度だけ担当させ、kernel では
gamma encode しない。将来は `(L,h)→Cmax` 2D LUT または解析境界へ高速化できるが、今回はまず
24MP export / 2560 preview を測定し、画質の正しさを優先する。

## decoder policy

今回の比較変数を増やさないため、Core Image RAW の既定 gamut mapping は無効化しない。
ただし `isGamutMappingEnabled = true` を明示し、現行 calibration profile/version の構成要素として
文書化する。`boost=0` / EDR / upstream gamut mapping off の比較は次の独立 calibration slice にする。

## calibration / gate

今回の最小必須変更:

1. analyzer に unblurred 16-bit candidate/reference の `upper_plateau_fraction` を追加。
   `max-channel >= 0.999` かつ同じ channel が右または下の隣接 pixel と同一 code の pixel を数え、
   大きな upper-bound flat region を complete/near clip と別に追う。
2. 必須8 candidate が1つでも欠けたら黙って省略せず fail-closed。
3. scene/input ごとに full と basic を比較する stage gate を report へ出す。
   - complete: `full <= basic + 0.0005`
   - near: `full <= basic + 0.002`
   - plateau: `full <= basic + 0.002`（実写母集団が増えるまで暫定）
   - ΔE00 median: `full <= basic + 0.5`
   - ΔE00 p95: `full <= basic + 1.0`
4. report に status / threshold / violation を残す。default analyze は測定結果を必ず保存し、
   `--enforce` 時だけ nonzero exit として探索を妨げない。
5. Python test: upper plateau、missing candidate、gate pass/fail。Swift test: 下記 synthetic invariants。

fixture manifest / SHA-256 / ROI / 5〜10 scene の leave-one-scene-out は production-ready calibration の
必須後続。ただし今 slice で2枚のファイル名を manifest 化しても統計的妥当性は増えないため、
色処理修正より先に大規模化しない。原本は一切変更せず、生成物だけ `.photobench/` に書く。

## hard tests

- working pipeline: gray 0...4、6原色方向、負値/OOG vector が finite。curve/HSL 後も異なる1超値が
  1へ plateau せず、identity curve なら最大誤差 < 2e-5。
- OKLCh mixer: neutral 0...4 の channel spread < 5e-4、red wrap 連続、全 band/±100 で finite。
- output tone: 0...16 ramp が finite/単調、knee 左右で C0/C1、neutral 保持。
- gamut: zone 内 identity、全 hue/L の OOG ray が最終 [0,1]、C が単調、C>=0.02 で hue drift
  p95 <=2° / max <=5°。
- CPU / software Core Image / Metal 最大 abs error < 2e-5。
- alpha: translucent input で unpremultiply/premultiply の fringe がない。
- preview/JPEG/TIFF が出力 transform を exactly once 共有。neutral raster は bypass。
- `swift test`、Python test、calibration CLI/analyzer、app build、codesign を実行。

## Claude に判断してほしい点

1. この slice で `CIColorCubeWithColorSpace.extrapolate=true` を acceptance test 付きで使う判断は、
   根本解決として許容できるか。今すぐ custom 1D curve kernel に分離すべきか。
2. neutral raster bypass / RAWまたはactive editだけ tone map という source-policy に見落としはないか。
3. luminance knee 0.90、OKLCh zone 0.90、12回探索、0.995 safety margin の数式に
   continuity / hue / boundedness / pathological input の欠陥はないか。
4. HSL UI を OKLCh の上記意味へ写す方法、とくに luminance の `/300` scale は妥当か。
5. 2 scene に対する相対 gate は暗く/低彩度にして clip を良く見せる実装を十分に防ぐか。
6. 今回必須で直すべき P0/P1 が他にあるか。過剰スコープも指摘してほしい。

回答は、最初に `PROCEED` / `PROCEED WITH CHANGES` / `DO NOT PROCEED` の verdict を置き、
重大度順に指摘し、最後に具体的な修正版 pipeline と acceptance criteria を提示してほしい。
