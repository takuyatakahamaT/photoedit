# HDR-safe creative pipeline: Claude 実装後レビューと採否

- 実施日: 2026-07-23
- 方式: `claude-review` / Claude Code CLI / Claude Opus 4.7 / high effort / deep repository review
- 権限: read-only（repositoryへの編集、外部ツール、Web検索なし）
- 対象: HDR-safe curve / mixer / output transform、RAW profile、校正器、テスト、設計・校正文書
- Claude判定: **APPROVE WITH CHANGES**

Claude CLI側ではplan file用の`Write`と`ExitPlanMode`が無効だったため、最終レビュー本文を標準出力で受け取り、この文書へ記録した。repositoryへの書き込みは発生していない。

## 総評

Claudeは次のコア設計が実装前レビューの方針どおりであり、P0の数式・色管理・alpha・処理順のバグは検出しなかったと判定した。

- extended-linear sRGB working space
- encoded-sRGB 1D curveと端点外挿
- near-neutral guard付きOKLCh 8-band mixer
- max-channel shoulderとfixed-L/h chroma compressionの責務分離
- translucent入力のunpremultiply → map → premultiply
- bounded sRGB neutral rasterだけのoutput transform bypass
- RAWを常にoutput transformへ通す分岐
- RGBAf / CIKL単精度を運用域とstress域へ分けたΔEOK契約

blockingは**なし**。P1524180 / RAWの平均EV不合格はclip、plateau、色域収容のP0ではなく、初期OFFの実験的curve / mixerをAdobeの応答へ校正し切れていない品質ゲートとして扱う判断を支持した。

## Claudeの should 指摘

1. XMP `LuminanceAdjustment`を局所露光として実装した意味論を明記し、スライダー単独fixtureを追加する。
2. `ToneCurveModel.normalizedPoints`がauthor yも0〜1へ制限する不変条件をコメントする。
3. generic RAW（EDR 0）でもY>1の合成入力をfinal output transformへ通す構造テストを追加する。
4. curveの重複xを暗黙・sort依存の後勝ちにせず、上流または評価境界で決定的に扱う。
5. `CIVibrance` / `CIColorControls`のHDR域はAppleの内部実装が非公開であり、ブラックボックスとして文書化するか後続の独自kernelへ送る。

## Claudeの EV gate 判断

Claudeは、OKLabのL/a/bを`2^(adjustment/300)`倍する実装が、linear RGBでは`2^(adjustment/100)`のゲイン、すなわち`+100 = +1 EV`になることを再確認した。一方、これはAdobe HSL Luminanceと同義ではないため、2実写へ合わせて係数を弱めるべきではないとした。

提案された診断は次のとおり。

- band中心の単色swatchでLuminance `+25`のEV、Saturation `+100`のchroma比を単独測定する。
- S字curveだけを通し、encoded-sRGB shapeを独立測定する。
- HSL / curveは追加sceneとスライダー別Lightroom基準が揃うまで初期OFFにする。
- 画像EV gateを意味論に合わせて再分類する案を検討する。

## こちらで採用・実装した項目

| 指摘 | 対応 |
|---|---|
| HSL Luminanceの意味論 | DESIGN / CALIBRATION / README / RESEARCHへ、バンド中心・near-neutral guard 100%時に`+100 = +1 EV`となる局所露光でありAdobe HSLと非同義と明記 |
| per-slider fixture | 全8 bandのLuminance `+25 = +0.25 EV`、Saturation `+100 = 2x chroma`、S字curveの制御点・中間点・HDR端点外挿をCPUで固定 |
| author point clamp | 0〜1はXMP author domainの不変条件で、HDR外挿は画像入力に対するものとコードコメントへ明記 |
| curve重複x | authored orderを保持し、正規化時に元indexで決定的なlast-authored-winsとした。異なるyの重複x fixtureも追加 |
| generic RAW構造テスト | EDR 0のgeneric profileとY>1の合成RGBAfを実際の`RenderEngine.applyForOutput`へ通し、CPU参照一致・boundedness・ceilingを検証 |
| Apple標準filterのHDR限界 | `CIVibrance` / `CIColorControls`は公開契約のないブラックボックスと文書化し、独自Metal化まで残余リスクとして保持 |

## 独立検算で採用しなかった項目

Claudeは画像レベルEV gateを`Σ(hue_area_fraction × luminance/100)`で補正する案も示したが、採用しない。

第一に、画像平均EVは画素数だけの線形和ではなく、linear luminanceで重み付けされたgainの平均を取ってから対数化するため、この式は厳密ではない。第二に、段別監査ではP1524180のEV上昇はHSL Luminanceだけでなくpoint curveの寄与が大きく、HSLだけを既知offsetとして差し引くと未校正のcurve応答を隠す。第三に、現行の2sceneはAdobeの非公開処理順を同定できない。

したがって、control単独fixtureは「Photo Bench自身の意味論が変わっていないこと」の回帰に使い、Lightroomとの差を合格へ補正する用途には使わない。画像レベルの`abs(full) <= abs(basic) + 0.05 EV`はfail-closedのまま維持し、P1524180 / RAWを唯一の不合格として残す。

## consider / 後続リスク

- gamut compressionの極端L縮退fallbackを、L=`1e-4` / `1 - 1e-4`でも追加検証する余地がある。
- 8 bandのperceptual hueは静的値なのでcache可能。
- Panasonic make/model表記を追加profile前に再確認する。
- tone curve / mixer kernel cacheは直近1件だけで、設定の高頻度切替時のコンパイル負荷は未計測。
- generic RAWはEDR 0のため、実機種によって実写Y>1 headroomが少ない。合成構造テストはoutput pathを守るが、他機種RAWの実測を代替しない。
- CIKLのLMSゼロ近傍は運用`ΔEOK < 0.001`、stress`< 0.005`で監視し、packaged Metal kernel移行まで既知残差とする。
- Python `gate_fixture`は将来RAW / LR-inputで非対称な仕様を導入するとき、fixture自体も分離する必要がある。

## レビュー後の検証契約

- Swift Testing: `52 tests / 5 suites`
- Python unittest: `14 tests`
- 実写校正: clip / near clip / shared plateau /平均ΔEは全4経路合格
- 既知不合格: P1524180 / RAWの平均EV `+0.20779`（上限`0.05376`）
- 運用判断: HDR-safe output基盤は採用、実験的HSL / curveは初期OFFを維持

このレビューは「Lightroom互換が完成した」という承認ではない。現sliceを、HDR値の早期clampを除き、最終出力で安全にbounded sRGBへ収める基盤として受け入れる判定である。
