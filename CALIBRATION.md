# Photo Bench 校正記録

更新日: 2026-07-24（JST）
対象プロファイル: `panasonic-dc-s5-lightroom-9.3-edr1-v2`

状態: RAWホワイトバランス観測sourceを含むmanifest v4の正式runで、122 / 122 artifactの構造・hash検証に成功した。canonical settleは既知の2 development sceneで合格したが、Lightroom品質は4経路中1経路が不合格であり、preview parityも3,072pxで2 / 6、3,840pxで4 / 6比較が不合格である。別契約のWB観測も構造検証には合格したがproduction採用は禁止されている。したがって総合画質は未合格であり、Lightroom相当を主張しない。

機械可読な正本は`.photobench/calibration/run-manifest.json`と`.photobench/calibration/report.json`である。本書の丸め値と差がある場合はJSONを優先する。

## 目的と適用範囲

Lightroom適用後の16bit sRGB参照TIFFと、同じシーンのRAW / Lightroom書き出し前入力を比較し、次を分けて検証する。

1. 基本現像と実験的curve / color mixerが、Lightroom参照の色・明るさへどこまで近づくか。
2. 編集、縮小、最終出力までのproduction graphが、complete / near clipや共有階調のplateauを増やさないか。
3. 縮小RAW decode候補がfull-resolution decodeに対して十分なpreview parityを持つか。

現時点の校正対象は`P1524180`と`P1522877`の2シーンだけで、両方とも開発中に見ながら調整したdevelopment foldである。独立holdoutはない。回帰検知には有効だが、別カメラ、露出、照明、肌、高彩度色、逆光、ノイズ、ディテール、未知シーンへの一般化を証明しない。

## 正式 v4 証跡

現行契約の正本は`calibration/manifest-v4.json`である。

- suite: `dc-s5-lightroom-9.3-canonical-settle-2026-07-24-v4`
- calibration run ID: `1c324af0-7ec3-4c33-bc6f-3bd653794800`
- manifest SHA-256: `9da1fd58ec4ead9b921dea477319423711567de3c06f8eb39d429c89980267f6`
- source fingerprint: `b7d8c57fab4428679a4f4e7cfacf2f64e67b317e9b9f46a00093cf7b5bf1a858`
- calibration release executable SHA-256: `6f1be9b7a44529f25fb7fe8ad90b6b030bfa128e2108174bc86cab09cd775a15`
- schema: manifest `4` / calibration run manifest `2` / analyzer report `5`
- 検証対象: 7入力、26 source、122 / 122 artifact

runnerは開始前後の入力・source・binaryと、artifactのpath・stage・byte count・SHA-256を照合する。analyzerはrun manifest記載の122 artifactだけを正本として再検証する。path traversal、symlink、case-only alias、成果物名衝突、欠測、未知stage、hash・runtime・処理fingerprint不一致は品質評価前にexit `2`、正しく測れた数値不合格はexit `1`とし、欠測を合格へ倒さない。

最新runの置換前には、旧complete runをbyte countとSHA-256で検証して`.photobench/calibration-archives/<run-id>/`へ退避する。ただしこの退避・置換は単一プロセス内でatomicに実行されるだけで、複数のrunner / analyzerをまたぐcross-process lockはまだない。同じrootで校正を並行実行しないことが現行runbook上の制約である。

## 現行production graph

```text
Core Image RAW 8 decode（DC-S5 fixtureは14bit）
  → DC-S5限定RAW profile（boost 0.9 / EDR 1）
  → extended-linear sRGB working space
  → exposure / tone / encoded-sRGB curve / OKLCh mixer / vibrance / saturation
  → edge-clamped Lanczos downsample（previewまたは指定サイズ時）
  → terminal sRGB output transform
  → exact integer extentへcrop
  → sRGB preview / export
```

処理識別子は`extended-linear-srgb-edits-resize-before-final-srgb-v1`である。要点は **extended-linear-sRGB edits → edge-clamped Lanczos downsample → terminal sRGB transform** の順序である。

Core Imageは遅延評価されるため、処理ノードの順序を共通graphとして組み、最終rasterで回帰検証する。[AppleのCIImage説明](https://developer.apple.com/documentation/coreimage/ciimage?changes=_3_1___9_2&language=objc)にあるとおり、有限extent外は透明黒として扱われる。Lanczos前に[`clampedToExtent()`](https://developer.apple.com/documentation/coreimage/ciimage/clampedtoextent%28%29)でedge pixelを延長し、[Lanczos scale transform](https://developer.apple.com/documentation/coreimage/cilanczosscaletransform?changes=l_7&language=objc)後に正確なextentへcropすることで、境界で透明黒を補間するhaloを避ける。`CIContext`は[working color space](https://developer.apple.com/documentation/coreimage/cicontext/workingcolorspace)と[output color space](https://developer.apple.com/documentation/coreimage/cicontextoption/outputcolorspace?language=objc)を明示する。

terminal transformは最大channel基準の比率保持shoulderと、OKLChのL / hを固定してCだけを圧縮するgamut compressionからなる。bounded sRGBの中立画像は不要な再変換を避ける。curveとcolor mixerは品質未合格のため初期OFFを維持する。

## Lightroom品質ゲート

`basic`は基本補正まで、`full`はcurveとOKLCh 8-band mixerを加えた候補、`reference`はLightroom適用後16bit sRGB TIFFである。RAW経路とLightroom-input経路を別々に測る。

- 平均ΔE00: `full <= basic + 0.25`
- 平均EV絶対誤差: `abs(full) <= abs(basic) + 0.05 EV`
- complete / near clip: `full <= basic`
- 新規共有highlight plateau面積: `<= 0.0005`

正式v4結果は次のとおりである。

| シーン / 経路 | 平均ΔE00 basic → full | 平均EV差 basic → full | 新規共有plateau | 判定 |
|---|---:|---:|---:|---|
| P1524180 / RAW | 7.592725 → 6.796299 | +0.003839 → +0.207869 | 0.000357333 | EV不合格 |
| P1524180 / LR-input | 5.555688 → 4.835475 | -0.125767 → +0.026336 | 0.000371333 | 合格 |
| P1522877 / RAW | 5.859457 → 3.342271 | -0.180143 → +0.007103 | 0.000072667 | 合格 |
| P1522877 / LR-input | 5.468566 → 3.417358 | -0.268298 → -0.083922 | 0.000176667 | 合格 |

全4経路でΔE、clip、plateauの条件は通ったが、P1524180 / RAWのfull EVは上限`0.05384 EV`に対し`+0.20787 EV`である。目視でもこの出力はLightroom-afterより明るく、暖色・マゼンタ寄りで青の彩度が強い。P1522877はより近いが、やや暖色・高彩度に見える。これは「安全にsRGBへ収めた」ことと「Lightroomの画作りに一致した」ことが別問題である証拠である。

## Canonical settle v4

canonical settleは、full-resolution RAWを同じv4 production graphで`basic-legacy`と`full-current`へ通し、最終2,560pxに縮小した後の整数clip countと共有plateauを比較する。

| scene | complete clip pixels basic → full | near clip pixels basic → full | 新規共有plateau面積 | 上限 | 判定 |
|---|---:|---:|---:|---:|---|
| P1524180 | 0 → 0 | 0 → 0 | 0.00003592743116578793 | 0.0005 | 合格 |
| P1522877 | 0 → 0 | 0 → 0 | 0.00009839997070884592 | 0.0005 | 合格 |

正確なclaim scopeは「2つの既知development sceneにおいて、full-resolution RAWを最終2,560pxへ縮小するv4順序で、`basic-legacy`から`full-current`へのcomplete / near clip増加がなく、新規共有highlight plateauも事前登録上限内だった」である。

これはLightroom参照との色・露出一致、旧graphと新graphの同一run内比較、別シーンへの一般化、RAW WB、camera profile、ディテール、シャープ、ノイズ、全色域の妥当性を意味しない。

### 旧 v3 証跡

旧run `ceea9eb4-b490-4a1f-9984-3d294e2f50bb`は`.photobench/calibration-archives/ceea9eb4-b490-4a1f-9984-3d294e2f50bb/`へrun manifest記載122 artifactを保存している。旧graphの最終2,560px TIFFをv4と同じ定義で後追い集計すると次のとおりで、clip count非増加に失敗していた。

| scene | complete clip pixels basic → full | near clip pixels basic → full | 新規共有plateau面積 |
|---|---:|---:|---:|
| P1524180 | 2,972 → 4,013 | 3,289 → 4,598 | 0.00008444090509666081 |
| P1522877 | 13 → 1,500 | 2,927 → 4,927 | 0.00008855997363796134 |

この履歴とpipeline orderingのunit testをv4 passと併記することで、terminal transformを縮小後へ移した効果を示す。v4 canonical pass単体を旧新graphの直接比較と表現しない。

## Preview parity

full-resolution、3,072px、3,840px RAW decodeを`neutral`、`basic-legacy`、`full-current`へ通し、全経路を最終2,560pxへ揃える。full-resolutionを参照とし、候補ごとに2シーン×3段階を次で判定する。

- 平均ΔE00 `<= 1.0`
- ぼかし後ΔE00 p95 `<= 2.0`
- 絶対平均EV drift `<= 0.02`
- 正のplateau純面積増加 `<= 0.0001`
- 参照plateauのsquare-3x3、1px dilation外に生じる新規plateau面積 `<= 0.0001`

| decode → final | 最大平均ΔE00 | 最大ぼかしΔE00 p95 | 最大絶対EV | 最大plateau純増 | 最大dilation外面積 | 不合格 | 採否 |
|---:|---:|---:|---:|---:|---:|---:|---|
| 3,072 → 2,560 | 0.4884687960 | 1.5748517513 | 0.0054855016 | 0.0000549209 | 0.0001210548 | 2 / 6 | 不採用 |
| 3,840 → 2,560 | 0.4167654216 | 1.2567764521 | 0.0042452556 | 0.0000995442 | 0.0002128185 | 4 / 6 | 不採用 |

6件の失敗理由はいずれもspatially-distinct plateauだけである。3,072pxは両sceneの`full-current`、3,840pxはP1524180の3段階とP1522877の`full-current`が不合格だった。正式結果を見て閾値を緩めていない。`selectedCandidate = null`で、productionはfull-resolution RAW decodeを維持する。

## RAWホワイトバランス観測

製品へ接続する前段として、As Shotは既存production decoder delegateへ委ねて一切設定せず、custom Temperature / Tintだけをfresh Core Image RAW 8 filterで観測する独立suiteを追加した。正本、候補集合、代表値、制約、次の受け入れ条件は[`docs/WHITE_BALANCE_OBSERVATION.md`](docs/WHITE_BALANCE_OBSERVATION.md)にまとめる。

- suite: `dc-s5-lightroom-9.3-white-balance-observation-2026-07-24-v1`
- run ID: `51ba2f46-185d-4b87-8345-407d380214cd`
- manifest SHA-256: `aea4c93626b0a32259c747d2e2ca4ca82b45647d0336507bb709bc86b4e0faf3`
- source fingerprint: `413fce7eb57938b958f3e1efd7f835e6fd7cae5561e8327341e4c4faaaec8b3e`
- release executable SHA-256: `5e08849cc3d431cde4c42aad7523fd4b704591ae5aecb3f2d11404f92a0edf44`
- 2 development scene、0 holdout、各18候補、40 / 40 artifact
- validation: `passed`
- adoption status: `exploratory-observation-only`
- production adoption allowed: `false`

P1524180のCore Image As Shotは固定Lightroom参照に対してmean ΔE00 `3.6660247`、EV `+0.1050286`、P1522877は`2.1292396`、`+0.0294950`だった。fresh filterの中心Temperature / Tintを書き戻したcustom centerとAs Shotの差は、それぞれmean ΔE00 `0.0001510` / `0.0003225`と小さいがbyte exactではない。setter順序比較は両sceneでbyte exactだった。

これは記述的な2scene観測であり、候補の順位付け、Adobe値からApple値への写像、未知sceneへの一般化、またはproduction WBの採用を意味しない。Lightroom側のTemperature / Tint教師sweep、灰色基準と領域別評価、5〜10以上のdevelopment scene、最低2 sealed holdout、preview / export / persistence / Undoへの同一intent接続が先に必要である。

## EDRと色域圧縮の補助検証

DC-S5ではEDR 1がEDR 2の`> 1`領域の約96.3% / 93.8%を保持しつつ最大channelの拡大を抑えたため、DC-S5限定profileに`boost = 0.9`、`extendedDynamicRangeAmount = 1`を採用している。他機種へ一般化しない。

色域圧縮は67,368点のRGBAf gridで、運用域`C/Cmax <= 2`とstress域`<= 4`をCPU参照と比較する。非finite値とbounded sRGB違反は0件で、最大ΔEOKはそれぞれ`0.000119426`と`0.002549949`だった。[W3C CSS Color 4のΔEOK](https://www.w3.org/TR/css-color-4/#deltaEOK)を知覚尺度の参考にするが、このsynthetic passを実写のLightroom一致へ読み替えない。

## 未完了と次の品質作業

- XMPのWhite Balance値を解析でき、custom RAW decodeの開発用観測経路もあるが、製品のpreview / export / edit persistenceへは接続されていない。
- Adobe / camera-specific profileやDCP相当のprofile処理がない。Adobeも現像時のprofileとwhite balanceを別の基本制御として扱っているため、両方を教師sweepで検証する。[Adobe Lightroom Classicの画像トーンとカラー](https://helpx.adobe.com/lightroom-classic/desktop/process-and-develop-photos/image-tone-color.html)
- 2 development sceneのみで独立holdoutがない。5〜10 sceneの探索用集合と、最終候補選定後まで触らないsealed holdoutを追加する。
- crop / rotate、local adjustment、sharpening、noise reduction、lens correction、永続catalogなどは未完成である。
- cross-process calibration lockがないため、同一rootの並行runを禁止している。

## 回帰テストと再現コマンド

- Swift Testing: `119 tests / 10 suites`
- Python calibration analyzer: `61 tests`
- Python WB observation analyzer: `17 tests`

現行テストは、旧 / 新graphの識別、edge clamp + Lanczos + crop、terminal transformの順序、bounded neutral bypass、canonical settleの整数clip countと欠測時fail-closed、preview parity、manifest / hash / archive契約を含む。実画面のdisplay color management、window lifecycle、未知カメラ、holdout品質は含まない。

WB関連では、As Shot delegateの非変更、custom値域、fresh filter、setter順序、provenance、18候補の固定集合、private input / immutable output / metadata契約、source fingerprintと観測専用analyzerを検証する。2sceneの構造合格は製品品質テストではない。

formal evidenceを再生成する場合は並行校正がないことを確認し、release runnerを使う。Lightroom品質・preview parityの既知不合格を含むため、全gate enforceの期待exitは`1`である。

```sh
cd /path/to/photoedit
swift run -c release PhotoBenchCalibration .
python3 scripts/analyze-calibration.py . \
  --enforce \
  --enforce-preview-parity \
  --enforce-canonical-settle
swift run -c release PhotoBenchWhiteBalanceObservation .
python3 scripts/analyze-white-balance-observation.py . \
  --run .photobench/white-balance-observations/<run-id>/run.json
python3 -m unittest scripts/test_analyze_white_balance_observation.py
```
