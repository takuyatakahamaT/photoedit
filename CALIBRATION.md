# Photo Bench 校正記録

更新日: 2026-09-24（JST）
対象プロファイル: `panasonic-dc-s5-lightroom-9.3-edr1-v2`
校正機: Mac Studio（`Mac13,1` / Apple M1 Max / macOS `26.5.2` build `25F84`）

状態: manifest v4を現行PhotoCore契約（Highlights / Shadowsの`SpatialToneOps`、HSL等の`ColorOps`）と校正機Mac Studioへ再固定し、正式runを2回実行した。2回とも7入力・42 source・122 / 122 artifactの構造・hash・provenance検証に合格した。正本とした2回目は、Lightroom品質ゲートが4 / 4経路、canonical settleが2 / 2 sceneで合格し、preview parityは3,072px・3,840pxとも1 / 6比較が不合格で不採用のままである。一方、Lightroom書き出し前TIFFを入力にする経路で、描画の下側が256pxのタイル行ごと透明な黒になる非決定的な欠損を検出した（各118描画中、1回目7件、2回目5件）。また、このsuiteのRAW経路はCore Image RAW 8で現像しており、アプリのRAW基準現像（LibRaw + Adobe DCP）を通らない。したがって総合画質は未合格であり、Lightroom相当を主張しない。

機械可読な正本は、Mac Studioの`~/Documents/app/photo-edit-app-calibration/.photobench/calibration/run-manifest.json`と`report.json`である（Git管理外）。本書の丸め値と差がある場合はJSONを優先する。2026-07-24に旧エンジンで測った正式runは、末尾の履歴節に残す。

## 目的と適用範囲

Lightroom適用後の16bit sRGB参照TIFFと、同じシーンのRAW / Lightroom書き出し前入力を比較し、次を分けて検証する。

1. presetの基本補正と全設定が、Lightroom参照の色・明るさへどこまで近づくか。
2. 編集、縮小、最終出力までのproduction graphが、complete / near clipや共有階調のplateauを増やさないか。
3. 縮小RAW decode候補がfull-resolution decodeに対して十分なpreview parityを持つか。

現時点の校正対象は`P1524180`と`P1522877`の2シーンだけで、両方とも開発中に見ながら調整したdevelopment foldである。独立holdoutはない。回帰検知には有効だが、別カメラ、露出、照明、肌、高彩度色、逆光、ノイズ、ディテール、未知シーンへの一般化を証明しない。

2026-09-24時点で、このsuiteが測る範囲は次のとおりである。

- RAW経路では、runnerが`CoreImageDecoder`を直接使う。Core Image RAW 8とDC-S5限定profile（boost 0.9 / EDR 1）の上に、現行の編集処理を載せた結果になる。アプリは`PhotoDecoder`でLibRaw + Adobe DCPを優先し、Core Imageはfallbackなので、製品のRAW基準現像はこのsuiteでは測れない。
- LR-input経路（Lightroom書き出し前TIFF）は、アプリがJPEG / TIFFを開くときと同じ`CoreImageDecoder`（ImageIO）経路である。
- 現行エンジンのLightroom一致度の正本は、`docs/ENGINE_ROADMAP.md`の実写ゲートである。本suiteは処理順序、clip、plateau、preview parityの回帰検知として使う。

## 正式 v4 証跡

現行契約の正本は`calibration/manifest-v4.json`である。2026-09-23〜24に次の3点を更新した（commit `4a963b9`、`ffad370`、`8ee1648`）。

- `processing.fingerprint`: `basicTone`を`spatial-v2-local-laplacian-highlights-shadows-v1`、`colorMixer`を`measured-color-ops-cube-q-v1`へ更新した。フェーズ2 C2 / C3で実装を置き換えた後も、旧`BasicToneModel` / `PerceptualColorMixer`の識別子のままだった。
- `processing.sourceFiles`: 削除済みの2 fileを外し、`Sources/PhotoCore`配下をsubdirectoryまで網羅した（26 → 42 file）。
- `expectedEnvironment`: 校正機をMac mini（`Mac16,10` / Apple M4）からMac Studioへ変更した。Mac miniは16GBで、原寸描画と他の作業が重なるとwatchdogで再起動するためである。

閾値、scene、stage matrix、候補labelは変更していない。これらは実測値ではなく事前登録した判定条件であり、結果を見て動かさない。suite IDも据え置いた。

- suite: `dc-s5-lightroom-9.3-canonical-settle-2026-07-24-v4`
- manifest SHA-256: `1ce9fec683aa89d1d00e7876bad6349dd1e71e8241b9e26accb35327c87fc637`
- calibration release executable SHA-256: `0d00b5c335bbd56466b6101a31599c49c84300875b96fc3e71c5e9d4ecf5c925`（2回とも同一）
- runtime: macOS `26.5.2` build `25F84`、`Mac13,1`、Apple M1 Max、arm64、Core Image `1592.120.2`、release
- schema: manifest `4` / calibration run manifest `2` / analyzer report `5`
- 検証対象: 7入力、42 source、122 / 122 artifact
- 2回目（正本）: run `e8d7318b-dc35-439c-af7d-b5a498b9e827`、source commit `8ee1648`、source fingerprint `2729638deb32cbdd86272fae5515c744c4daae059e2b111585b0715b2f827525`
- 1回目: run `529e6d88-6c9a-4222-8c3e-2686001a7267`、source commit `ffad370`、source fingerprint `29afe6806b9859490def788d1b49dfe5885b0c86793132f0ed51d137124b0e47`。`.photobench/calibration-archives/529e6d88-6c9a-4222-8c3e-2686001a7267/`へ退避済みで、118描画のSHA-256はrun manifestと一致する。

2回のsourceの差はアプリの`EditorModel.swift`だけで、校正の描画経路は同じである。analyzerは`--enforce --enforce-preview-parity --enforce-canonical-settle`で2回ともexit `1`だった。構造検証は合格し、数値不合格はpreview parityだけである。

runnerは開始前後の入力・source・binaryと、artifactのpath・stage・byte count・SHA-256を照合する。analyzerはrun manifest記載の122 artifactだけを正本として再検証する。path traversal、symlink、case-only alias、成果物名衝突、欠測、未知stage、hash・runtime・処理fingerprint不一致は品質評価前にexit `2`、正しく測れた数値不合格はexit `1`とし、欠測を合格へ倒さない。

最新runの置換前には、旧complete runをbyte countとSHA-256で検証して`.photobench/calibration-archives/<run-id>/`へ退避する。ただしこの退避・置換は単一プロセス内でatomicに実行されるだけで、複数のrunner / analyzerをまたぐcross-process lockはまだない。同じrootで校正を並行実行しないことが現行runbook上の制約である。

## 描画graph

```text
Core Image RAW 8 decode（DC-S5 fixtureは14bit。アプリではLibRaw + Adobe DCPのfallback）
  → DC-S5限定RAW profile（boost 0.9 / EDR 1）
  → extended-linear sRGB working space
  → 計測モデルの編集（Highlights / ShadowsはSpatialToneOps、HSL・Vibrance・Saturation・Color Grading・CalibrationはColorOps）
  → edge-clamped Lanczos downsample（previewまたは指定サイズ時）
  → terminal sRGB output transform
  → exact integer extentへcrop
  → sRGB preview / export
```

LR-input経路は、先頭のRAW decodeとRAW profileの代わりに、ImageIOで16bit TIFFを読む。処理識別子は`extended-linear-srgb-edits-resize-before-final-srgb-v1`である。要点は **extended-linear-sRGB edits → edge-clamped Lanczos downsample → terminal sRGB transform** の順序で、この部分はアプリと共通である。

Core Imageは遅延評価されるため、処理ノードの順序を共通graphとして組み、最終rasterで回帰検証する。[AppleのCIImage説明](https://developer.apple.com/documentation/coreimage/ciimage?changes=_3_1___9_2&language=objc)にあるとおり、有限extent外は透明黒として扱われる。Lanczos前に[`clampedToExtent()`](https://developer.apple.com/documentation/coreimage/ciimage/clampedtoextent%28%29)でedge pixelを延長し、[Lanczos scale transform](https://developer.apple.com/documentation/coreimage/cilanczosscaletransform?changes=l_7&language=objc)後に正確なextentへcropすることで、境界で透明黒を補間するhaloを避ける。`CIContext`は[working color space](https://developer.apple.com/documentation/coreimage/cicontext/workingcolorspace)と[output color space](https://developer.apple.com/documentation/coreimage/cicontextoption/outputcolorspace?language=objc)を明示する。

terminal transformは最大channel基準の比率保持shoulderと、OKLChのL / hを固定してCだけを圧縮するgamut compressionからなる。bounded sRGBの中立画像は不要な再変換を避ける。

## Lightroom品質ゲート

`basic`はpresetからtone curveとHSLを除いた設定（`basic-legacy`）、`full`はpresetの全設定（`full-current`）、`reference`はLightroom適用後16bit sRGB TIFFである。RAW経路とLR-input経路を別々に測り、`basic`に対する相対条件で判定する。

- 平均ΔE00: `full <= basic + 0.25`
- 平均EV絶対誤差: `abs(full) <= abs(basic) + 0.05 EV`
- complete / near clip: `full <= basic`
- 新規共有highlight plateau面積: `<= 0.0005`

2回目（正本）の結果は次のとおりである。

| シーン / 経路 | 平均ΔE00 basic → full | 平均EV差 basic → full | 新規共有plateau | 判定 |
|---|---:|---:|---:|---|
| P1524180 / RAW | 10.598053 → 4.178458 | -0.371865 → -0.170974 | 0.000070000 | 合格 |
| P1524180 / LR-input | 10.126773 → 4.798444 | -0.507459 → -0.321301 | 0.000106667 | 合格 |
| P1522877 / RAW | 8.247626 → 3.265962 | -0.389496 → -0.106495 | 0.000312667 | 合格 |
| P1522877 / LR-input | 8.748667 → 3.551687 | -0.515498 → -0.210761 | 0.000071333 | 合格 |

4経路ともcomplete / near clipは`0 → 0`だった。1回目も`full`と3経路の`basic`は同値だった。ただしP1522877 / LR-inputの`basic`描画は下側232行が欠損しており（後述）、`basic`がΔE00 `23.232931`、EV `-28.192543`になった。相対ゲートは壊れた基準に対して自動的に通るので、1回目のこの行は判定に使わない。

合格の意味は次の範囲に限る。

- 合格は、`full`が`basic`より悪化していないことだけを示す。現行エンジンでは`basic`自体が7月より大きくずれており（P1524180 / RAWのΔE00は`7.59`から`10.60`）、相対条件は緩く働く。
- `full`の絶対値はΔE00 `3.27〜4.80`で、EV差は4経路とも負（`-0.11〜-0.32 EV`、Lightroomより暗い）だった。7月の旧エンジンの`full`は、ΔE00 `3.34〜6.80`、EV差 `-0.08〜+0.21`である。
- RAW経路の土台はアプリと異なるCore Image RAW 8なので、この表を現行エンジンのLightroom一致度として読まない。

## Canonical settle v4

canonical settleは、full-resolution RAWを同じv4 production graphで`basic-legacy`と`full-current`へ通し、最終2,560pxに縮小した後の整数clip countと共有plateauを比較する。2回の結果は同値だった。

| scene | complete clip pixels basic → full | near clip pixels basic → full | 新規共有plateau面積 | 上限 | 判定 |
|---|---:|---:|---:|---:|---|
| P1524180 | 0 → 0 | 0 → 0 | 0.00006659160808435853 | 0.0005 | 合格 |
| P1522877 | 0 → 0 | 0 → 0 | 0.00010412089923842999 | 0.0005 | 合格 |

正確なclaim scopeは「2つの既知development sceneにおいて、full-resolution RAWを最終2,560pxへ縮小するv4順序で、`basic-legacy`から`full-current`へのcomplete / near clip増加がなく、新規共有highlight plateauも事前登録上限内だった」である。

これはLightroom参照との色・露出一致、旧graphと新graphの同一run内比較、別シーンへの一般化、RAW WB、camera profile、ディテール、シャープ、ノイズ、全色域の妥当性を意味しない。

### 旧 v3 証跡

旧run `ceea9eb4-b490-4a1f-9984-3d294e2f50bb`は、Mac miniの`.photobench/calibration-archives/ceea9eb4-b490-4a1f-9984-3d294e2f50bb/`へrun manifest記載122 artifactを保存している。旧graphの最終2,560px TIFFをv4と同じ定義で後追い集計すると次のとおりで、clip count非増加に失敗していた。

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

2回の結果は同値だった。

| decode → final | 最大平均ΔE00 | 最大ぼかしΔE00 p95 | 最大絶対EV | 最大plateau純増 | 最大dilation外面積 | 不合格 | 採否 |
|---:|---:|---:|---:|---:|---:|---:|---|
| 3,072 → 2,560 | 0.4529227912 | 1.3187301159 | 0.0054838131 | 0.0000363851 | 0.0001151051 | 1 / 6 | 不採用 |
| 3,840 → 2,560 | 0.4420555532 | 1.1139123440 | 0.0049841921 | 0.0000363851 | 0.0001183088 | 1 / 6 | 不採用 |

失敗はどちらもP1522877の`full-current`で、参照plateauの1px dilation外に生じた新規plateau面積が上限`0.0001`を超えた。7月の旧エンジン（2 / 6、4 / 6不合格）より失敗は減ったが、全比較を通る候補はない。正式結果を見て閾値を緩めていない。`selectedCandidate = null`で、縮小RAW decodeは採用しない。

## 非決定的な描画欠損（2026-09-24検出、未修正）

LR-input経路の描画で、下側の256pxタイル行が丸ごとRGBA `0`（透明な黒）になる欠損を検出した。RAW経路の描画は2回とも全件正常だった。

| run | 欠損した描画 / 描画数 | 内訳 |
|---|---:|---|
| 1回目 `529e6d88…` | 7 / 118 | P1524180のlegacy tone-base、mixer hue / saturation / luminance / all-mixer。P1522877のbasic-legacy、tone-plus-rgb-curves |
| 2回目 `e8d7318b…` | 5 / 118 | P1524180の上記5件。欠損範囲の一部は1回目と異なる |

- 同じ設定（settings SHA-256 `2b88ddb7…`）・同じ入力でも、legacyのtone-baseは95.6%が欠損し、stage matrixのtone-baseは正常だった。非決定的である。
- 欠損範囲はy ≥ 512、y ≥ 768、または左上256×256以外のすべてで、常にタイル行単位である。
- 中断したMac mini（M4 / macOS 27.0）のrunでは、LR-input描画9件に欠損はなかった。件数が少なく、機種に依存するかは判断できない。
- アプリがJPEG / TIFFを開く経路と同じなので、Highlights / Shadows / Texture / Clarityを使う非RAW編集のpreviewとexportにも出うる。
- 疑わしい箇所は`Sources/PhotoCore/Spatial/SpatialToneProcessor.swift`の`applyGPU`である。CPU側に実体があるCIImageを、`CIContext.render(_:to:commandBuffer:bounds:colorSpace:)`でpoolのtextureへ描く部分にあたる。出力側は`waitUntilCompleted()`で同期しており、原因は未確定である。

2回目を正本にしたのは、品質ゲート、canonical settle、preview parityに使う描画がすべて正常だったためである。欠損した描画は、stage matrixとlegacy候補の診断値だけに影響する。修正と回帰テストは別作業として切り出した。

## RAWホワイトバランス観測

製品へ接続する前段として、As Shotは既存production decoder delegateへ委ねて一切設定せず、custom Temperature / Tintだけをfresh Core Image RAW 8 filterで観測する独立suiteを追加した。正本、候補集合、代表値、制約、次の受け入れ条件は[`docs/WHITE_BALANCE_OBSERVATION.md`](docs/WHITE_BALANCE_OBSERVATION.md)にまとめる。2026-09-24に校正manifestの再固定へ追従させ、Mac Studioで再実行した。

- suite: `dc-s5-lightroom-9.3-white-balance-observation-2026-07-24-v1`
- run ID: `efed3014-786a-420e-a6d3-74398e8722e4`
- manifest SHA-256: `d7efa286acfefa60cc01155073c24486530bbbe009e710f7dc31c740cb19031b`
- source fingerprint: `c0fd4120c8438b74c0f335d1f32fcf624111741d8e798a5ac06b94300c3bd019`
- release executable SHA-256: `e024be2f0030b497fd688edfe4896593682a9f0115593292cb3f97e03d45e4b6`
- ExifTool: `13.55`（Homebrew）
- 2 development scene、0 holdout、各18候補、44 source、40 / 40 artifact
- validation: `passed`
- adoption status: `exploratory-observation-only`
- production adoption allowed: `false`

P1524180のCore Image As Shotは固定Lightroom参照に対してmean ΔE00 `3.6660254`、EV `+0.1050280`、P1522877は`2.1292410`、`+0.0294952`だった。fresh filterの中心Temperature / Tintを書き戻したcustom centerとAs Shotの差は、それぞれmean ΔE00 `0.0001513` / `0.0003225`と小さいがbyte exactではない。setter順序比較は両sceneでbyte exactだった。7月のMac mini runとの差は各値とも`3e-6`未満である。

これは記述的な2scene観測であり、候補の順位付け、Adobe値からApple値への写像、未知sceneへの一般化、またはproduction WBの採用を意味しない。Lightroom側のTemperature / Tint教師sweep、灰色基準と領域別評価、5〜10以上のdevelopment scene、最低2 sealed holdout、preview / export / persistence / Undoへの同一intent接続が先に必要である。

## EDRと色域圧縮の補助検証

DC-S5ではEDR 1がEDR 2の`> 1`領域の約96.3% / 93.8%を保持しつつ最大channelの拡大を抑えたため、DC-S5限定profileに`boost = 0.9`、`extendedDynamicRangeAmount = 1`を採用している。2026-09-24のMac Studio runでも同じ比率だった。他機種へ一般化しない。

色域圧縮は67,368点のRGBAf gridで、運用域`C/Cmax <= 2`とstress域`<= 4`をCPU参照と比較する。非finite値とbounded sRGB違反は0件で、最大ΔEOKはそれぞれ`0.000119426`と`0.002549949`だった。[W3C CSS Color 4のΔEOK](https://www.w3.org/TR/css-color-4/#deltaEOK)を知覚尺度の参考にするが、このsynthetic passを実写のLightroom一致へ読み替えない。

## 未完了と次の品質作業

- LR-input経路の非決定的な描画欠損を修正し、CPU側に実体がある入力を繰り返し描画しても欠損しない回帰テストを追加する。
- 校正runnerのRAW経路は旧土台のCore Image RAW 8である。アプリと同じLibRaw + Adobe DCPへ揃えるか、現行エンジン用の校正suiteを別に定義する。`rawDecode`識別子、`rawProfile`、EDR診断の扱いを含む設計判断が要る。
- 性能基準（`BENCHMARK.md`）は、旧manifestとMac miniに固定した2026-07-24のrunのままで、再固定後は未実行である。benchmark runnerも同じmanifestを読むため、今後はMac Studioでしか実行できない。
- Core Image RAW 8のcustom WB観測経路は製品へ接続していない。製品のRAW WBはLibRaw経路の絶対WBである。
- 2 development sceneのみで独立holdoutがない。5〜10 sceneの探索用集合と、最終候補選定後まで触らないsealed holdoutを追加する。
- crop / rotate、local adjustment、sharpening、noise reduction、永続catalogなどは未完成である。
- cross-process calibration lockがないため、同一rootの並行runを禁止している。

## 回帰テストと再現コマンド

2026-09-24にcommit `8ee1648`をMac Studioで実行した結果は次のとおりである。

- Swift Testing: `202 tests / 21 suites`、全件成功
- Python calibration analyzer: `61 tests`、全件成功
- Python WB observation analyzer: `17 tests`、全件成功

校正manifestはMac Studioに固定しているため、manifestを読み込むテストはMac miniでは実行環境不一致でfail-closedする。設計どおりの挙動で、校正契約の破損ではない。

現行テストは、旧 / 新graphの識別、edge clamp + Lanczos + crop、terminal transformの順序、bounded neutral bypass、canonical settleの整数clip countと欠測時fail-closed、preview parity、manifest / hash / archive契約を含む。実画面のdisplay color management、window lifecycle、未知カメラ、holdout品質は含まない。

WB関連では、As Shot delegateの非変更、custom値域、fresh filter、setter順序、provenance、18候補の固定集合、private input / immutable output / metadata契約、source fingerprintと観測専用analyzerを検証する。2sceneの構造合格は製品品質テストではない。

formal evidenceを再生成する場合は、並行校正がないことを確認し、Mac Studioの校正用ディレクトリでrelease runnerを使う。作業ツリーの未commit変更を混ぜないよう、Mac mini側でcommit済みのtreeをworktreeに展開してから同期する。preview parityの既知不合格を含むため、全gate enforceの期待exitは`1`である。

```sh
# Mac mini: commit済みのtreeを同期する（.git・.build・.photobench・private写真は送らない）
git worktree add --detach .photobench/worktrees/calibration HEAD
rsync -a --delete --exclude .build --exclude .git --exclude dist --exclude exports \
  --exclude .photobench --exclude '*.tif' --exclude 'P152*' --exclude 'DSC020*' \
  --exclude 'DSC021*' --exclude .DS_Store \
  .photobench/worktrees/calibration/ \
  takuya-mac-studio:Documents/app/photo-edit-app-calibration/
git worktree remove .photobench/worktrees/calibration

# 初回だけ: private入力を送り、Studio側をGit管理下にする（WB runnerが未追跡とignoreをGitで確認する）
rsync -a P1524180.RW2 P1522877.RW2 P1524180.tif P1524180-2.tif P1522877.tif \
  P1522877-2.tif DSC02072.JPG takuya-mac-studio:Documents/app/photo-edit-app-calibration/
ssh takuya-mac-studio 'cd ~/Documents/app/photo-edit-app-calibration && git init -q'

# Mac Studio（ExifToolはHomebrewで導入済み）
cd ~/Documents/app/photo-edit-app-calibration
export PATH=$HOME/.venvs/photobench/bin:/opt/homebrew/bin:$PATH
swift test
swift run -c release PhotoBenchCalibration .
python3 scripts/analyze-calibration.py . \
  --enforce \
  --enforce-preview-parity \
  --enforce-canonical-settle
swift run -c release PhotoBenchWhiteBalanceObservation .
python3 scripts/analyze-white-balance-observation.py . \
  --run .photobench/white-balance-observations/<run-id>/run.json
python3 -m unittest scripts/test_analyze_calibration.py \
  scripts/test_analyze_white_balance_observation.py
```

## 履歴: 2026-07-24 正式 v4（旧エンジン、Mac mini）

旧エンジン（`BasicToneModel` / `PerceptualColorMixer`）を、Mac mini（`Mac16,10` / Apple M4 / macOS `26.3.1` build `25D771280a`）で測った正式runである。証跡はMac miniの`.photobench/calibration/`に残っている。

- calibration run ID: `1c324af0-7ec3-4c33-bc6f-3bd653794800`
- manifest SHA-256: `9da1fd58ec4ead9b921dea477319423711567de3c06f8eb39d429c89980267f6`
- source fingerprint: `b7d8c57fab4428679a4f4e7cfacf2f64e67b317e9b9f46a00093cf7b5bf1a858`
- calibration release executable SHA-256: `6f1be9b7a44529f25fb7fe8ad90b6b030bfa128e2108174bc86cab09cd775a15`
- 検証対象: 7入力、26 source、122 / 122 artifact
- WB観測run: `51ba2f46-185d-4b87-8345-407d380214cd`（manifest SHA-256 `aea4c93626b0a32259c747d2e2ca4ca82b45647d0336507bb709bc86b4e0faf3`、source fingerprint `413fce7eb57938b958f3e1efd7f835e6fd7cae5561e8327341e4c4faaaec8b3e`）

当時の`full`はcurveとOKLCh 8-band mixerを加えた実験候補で、curveとcolor mixerは品質未合格のため初期OFFだった。

| シーン / 経路 | 平均ΔE00 basic → full | 平均EV差 basic → full | 新規共有plateau | 判定 |
|---|---:|---:|---:|---|
| P1524180 / RAW | 7.592725 → 6.796299 | +0.003839 → +0.207869 | 0.000357333 | EV不合格 |
| P1524180 / LR-input | 5.555688 → 4.835475 | -0.125767 → +0.026336 | 0.000371333 | 合格 |
| P1522877 / RAW | 5.859457 → 3.342271 | -0.180143 → +0.007103 | 0.000072667 | 合格 |
| P1522877 / LR-input | 5.468566 → 3.417358 | -0.268298 → -0.083922 | 0.000176667 | 合格 |

全4経路でΔE、clip、plateauの条件は通ったが、P1524180 / RAWのfull EVは上限`0.05384 EV`に対し`+0.20787 EV`だった。目視でもこの出力はLightroom-afterより明るく、暖色・マゼンタ寄りで青の彩度が強かった。P1522877はより近いが、やや暖色・高彩度に見えた。

| scene | complete clip pixels basic → full | near clip pixels basic → full | 新規共有plateau面積 | 判定 |
|---|---:|---:|---:|---|
| P1524180 | 0 → 0 | 0 → 0 | 0.00003592743116578793 | 合格 |
| P1522877 | 0 → 0 | 0 → 0 | 0.00009839997070884592 | 合格 |

| decode → final | 最大平均ΔE00 | 最大ぼかしΔE00 p95 | 最大絶対EV | 最大plateau純増 | 最大dilation外面積 | 不合格 | 採否 |
|---:|---:|---:|---:|---:|---:|---:|---|
| 3,072 → 2,560 | 0.4884687960 | 1.5748517513 | 0.0054855016 | 0.0000549209 | 0.0001210548 | 2 / 6 | 不採用 |
| 3,840 → 2,560 | 0.4167654216 | 1.2567764521 | 0.0042452556 | 0.0000995442 | 0.0002128185 | 4 / 6 | 不採用 |

preview parityの6件の失敗理由はいずれもspatially-distinct plateauだけで、3,072pxは両sceneの`full-current`、3,840pxはP1524180の3段階とP1522877の`full-current`が不合格だった。WB観測のAs Shot → 固定LR参照は、P1524180でmean ΔE00 `3.6660247`、EV `+0.1050286`、P1522877で`2.1292396`、`+0.0294950`だった。
