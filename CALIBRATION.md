# Photo Bench 校正記録

更新日: 2026-07-24
対象プロファイル: `panasonic-dc-s5-lightroom-9.3-edr1-v2`

状態: tag `prototype-p1-2026-07-24`（commit `3a0169d`）のtagged baselineでは、24 sourceを固定した122 / 122 artifactの構造・hash検証に成功した。Lightroom品質は4経路中3経路合格だがP1524180 / RAWのEV gateが不合格、preview parityは3,072 / 3,840 px候補が各3 / 6不合格であり、いずれも総合判定は`false`。現在の実験branchは26 source契約へ進んでいるがformal calibrationを再実行していないため、このbaseline証跡をcurrent passには用いない

日付はJST基準で記載する。機械可読なUTC時刻は`.photobench/calibration/run-manifest.json`と`.photobench/calibration/report.json`を正とする。

## 目的

Photo Bench の校正は、Lightroom適用後の16bit sRGB参照TIFFと、同じシーンの RAW / Lightroom 書き出し前入力を比較し、次の2点を分けて検証する。

1. 基本現像が、参照の明るさ・色へどこまで近づくか。
2. カーブやカラーミキサーを有効にしても、ハイライト破綻や共有階調の平坦化を増やさないか。

現在の校正ペアは次の2組である。

- `P1524180`: 高輝度域を含むシーン
- `P1522877`: 暗部から中間調の色差を含むシーン

2シーンは回帰検知には使えるが、機種・露出・照明・肌色・飽和色を網羅する事業品質の代表標本ではない。

## 再現性とfail-closed契約

校正条件の正本は`calibration/manifest-v3.json`である。比較入力、source、処理profile、候補行列、共通Lanczosによる最終2,560 px化、出力stage、品質閾値に加え、preview / export decode intentの同等性契約を固定し、runnerとanalyzerが同じmanifestだけを読む。以下はtag `prototype-p1-2026-07-24`（commit `3a0169d`）で取得したP1 preview parity v3 formal runの同一性であり、現在の実験branchの証跡ではない。

- suite: `dc-s5-lightroom-9.3-preview-parity-2026-07-24-v3`
- calibration run ID: `ceea9eb4-b490-4a1f-9984-3d294e2f50bb`
- archived run manifest: `.photobench/calibration/runs/ceea9eb4-b490-4a1f-9984-3d294e2f50bb.json`
- tagged baseline manifest SHA-256: `2867219602b7abe89ddd8994ab243c1a9f1d020eed5710dac4bb1d475eab92a8`
- tagged baseline source fingerprint: `f8333be9f764af76b5d7e96d7a2967a44581405fca335fa27b1110f517f14e6b`
- release executable SHA-256: `11009c7fa63f9a76820238b4ba462734903c381e20b4488ca5a471e60ae51b98`
- 実行環境: Mac16,10 / Apple M4 / arm64 / macOS 26.3.1 (`25D771280a`) / Core Image `1592.80.2` / RAW 8
- schema: manifest `3` / calibration run manifest `2` / analyzer report `4`
- 検証対象: 7入力、24 source、122 / 122生成artifactを検証済み

tagged baselineの24 sourceには画像処理engine、校正・benchmark evidence runner、`Sources/PhotoBenchApp`、`Sources/PhotoBenchAppSupport`を含める。したがってMetal直接表示やexport中のフォルダ切替防止を含むapp-side変更もfingerprintを無効化する。現在の実験branchではlifecycle reducerとdiagnostic rendererを加えた26 sourceをmanifest契約に含めたが、formal calibrationは未再実行である。実画面へのMetal presentation経路はopt-in実装済みだが、この校正suiteは生成artifactを比較するもので、MTKViewへのactual presentationや画面captureを測定したものではない。

`.photobench/calibration/run-manifest.json`は、開始前に照合した全入力、source、実行binary、decode intent / 寸法 / scale / backendと、各artifactのpath / stage / SHA-256を記録する。終了時にも入力とsourceを再照合し、実行途中の変更を拒否する。同じ内容をrun IDごとのarchiveへ保存し、失敗runも上書きで失わない。`.photobench/calibration/report.json`はこのrun manifestと122 artifactを検証してから作るschema 4の派生品質レポートである。path traversal、symlink、case-only alias、正規化後の出力名衝突、未知または欠落したstage / candidate / comparison、hash不一致、環境・binary契約不一致は品質評価へ進まずexit `2`とする。正しく検証できた品質不合格だけをexit `1`とし、欠測を合格へ倒さない。

## 現在の処理系

```text
Core Image RAW 8 デコード（検証DC-S5原本は14bit）
  → DC-S5 限定 RAW プロファイル（boost 0.9 / EDR 1）
  → extended-linear sRGB
  → 露出・コントラスト・ハイライト・シャドウ等の基本補正
  → encoded-sRGB 1D カーブ（任意、端点外は端点傾きで外挿）
  → OKLCh 8バンド・カラーミキサー（任意）
  → 自然な彩度・彩度
  → 最大チャンネル基準の比率保持 shoulder
  → OKLCh の L / h を固定した gamut compression
  → sRGB 出力
```

実装識別子は次のとおり。

- トーンカーブ: `encoded-srgb-endpoint-extrapolation-v1`
- カラーミキサー: `oklch-eight-band-mixer-v1`
- 最終出力変換: `extended-linear-to-srgb-soft-output-v2`
- RAW decode intent: `core-image-raw8-intent-v2`

最終 shoulder は `knee = 0.99`、`ceiling = 0.998`、`softness = 0.008` とし、接続点で値と一次微分が連続する C1 接続にしている。まず最大チャンネルだけから圧縮率を求め、RGB 比率を保ったまま全チャンネルへ適用する。その後も色域外なら、OKLCh の明度 L と色相 h を保ち、彩度 C だけを圧縮する。gamut compression は `knee = 0.90`、境界係数 `0.999`、境界探索 `12` 回である。

RAW、extended sRGB の範囲外入力、または色編集が有効な入力だけを最終出力変換へ通す。すでに bounded sRGB 内にあり、色編集もない通常画像は変換を迂回するため、中立操作での不要な再量子化や色変化を避けられる。

カーブとカラーミキサーは初期状態では OFF である。後述のとおり、安全性ゲートは通過している一方、実験機能全体としての事業品質はまだ達成していない。

カラーミキサーのXMP `LuminanceAdjustment`は、OKLabのL/a/bを同率で拡大し、効果量100%ではlinear RGBで`2^(adjustment/100)`となる色域別の局所露光として定義する。したがってバンド中心かつ相対chroma `>= 0.08`では`+25 = +0.25 EV`、`+100 = +1 EV`である。near-neutralではguardが効果量を下げる。これはAdobe HSL Luminanceと同義ではなく、Lightroom一致の係数とはみなさない。Saturation `+100 = 2x chroma`、S字curveのencoded出力と併せて独立CPU fixtureで監視する。author curve pointは0〜1へ正規化し、重複xはXMP配列で後に書かれた点を採用する。

自然な彩度`CIVibrance`と全体彩度`CIColorControls`はextended-linear作業空間で適用するが、Appleは両フィルターのHDR域の内部応答を公開契約にしていない。現段階ではブラックボックスとして扱い、追加実写と将来の独自Metal kernelで暗黙clipを検証する。

### 色域圧縮の数値ゲート

最終色域圧縮は、`L = 0.05 / 0.10 / 0.25 / 0.50 / 0.75 / 0.90 / 0.95`、色相15度刻み、`C / Cmax = 0...4`を0.01刻みで走査した67,368点のRGBAf gridでも検証する。CPU参照と固定L/hの比較は、名目上の倍精度OKLCh値ではなく、Core Imageが実際に受け取るRGBAf量子化後の同一RGBから開始する。

| 領域 | 仕様からの根拠 | 観測max ΔEOK | 観測max彩度逆行 | 観測max L drift | 観測max色相差 | gate |
|---|---|---:|---:|---:|---:|---|
| 運用 `C/Cmax <= 2` | mixerのSaturation +100で到達する最大 | 0.000119426 | 0.000115946 | 0.000000224 | 0.001277° | ΔEOK < 0.001、逆行 < 0.0002、L < 0.00001、色相 < 0.05° |
| stress `C/Cmax <= 4` | 上記へglobal Saturation +100を重ねる最悪組合せ | 0.002549949 | 0.002052134 | 0.000028018 | 0.431203° | ΔEOK < 0.005、逆行 < 0.003、L < 0.0001、色相 < 1° |

両領域とも非finite値とbounded sRGB違反は0件である。[W3C CSS Color 4のΔEOK定義](https://www.w3.org/TR/css-color-4/#deltaEOK)が示す1 JND約0.02に対し、gateは運用域0.05 JND、stress域0.25 JND相当である。CIKLの単精度OKLab変換は、LMS成分がゼロ近傍を横切る概ね2倍超の極端な色域外入力で条件が悪化するため、倍精度CPUの厳格な単調性テストを維持しつつ、実レンダーは知覚色差と最大逆行量でfail-closedに監視する。正則化で色相を歪める変更は採用せず、packaged Metal kernelへの移行時に精密演算を再評価する。

## 測定方法

### 比較候補

- `basic`: RAW プロファイルと基本補正まで。カーブとカラーミキサーは無効。
- `full`: `basic` に校正候補のカーブと OKLCh 8バンド・ミキサーを加えた実験候補。
- `reference`: Lightroom適用後の16bit sRGB参照TIFF。

各シーンについて次の2経路を測る。

- `RAW`: RAW から Photo Bench の処理系で現像する経路。
- `LR-input`: Lightroom 書き出し前入力を Photo Bench へ渡す経路。

### 指標とゲート

- 色差: 参照との平均 ΔE。`full <= basic + 0.25` を満たすこと。
- 明るさ: 参照との平均 EV 差。`abs(full) <= abs(basic) + 0.05 EV` を満たすこと。
- 完全クリップ / near clip: `full` で `basic` より増えないこと。
- 新規共有 plateau: `full` によって新しく生じる共有階調の平坦化率が `0.0005` 以下であること。

plateau は単一チャンネルの局所的な同値ではなく、RGB が同時に平坦化する領域を検出する。これにより、色変換に伴う通常の量子化と、ハイライト階調の実質的な消失を区別する。

### P1 preview parity 契約と結果

Lightroom品質ゲートとは独立に、full-resolution、3,072 px、3,840 pxのRAW decodeを各シーンの`neutral`、`basic-legacy`、`full-current`へ同じ順序で通し、編集後に共通Lanczosで最終2,560 pxへ揃えて比較する。full-resolutionを参照とし、2候補の計12比較を次の5条件で独立判定する。

- 平均 ΔE00 `<= 1.0`
- ぼかし後 ΔE00 p95 `<= 2.0`
- 絶対平均 EV drift `<= 0.02`
- `max(0, candidate plateau area - reference plateau area) <= 0.0001`
- final 2,560 px上で参照plateauをsquare-3x3により固定1 px拡張した外側のspatially-distinct new area `<= 0.0001`
- 2シーン×3段階×3 decode経路の欠測、shape、16bit、sRGB ICC、hash、provenance不一致はexit `2`
- 数値だけが閾値を超えた正式runはexit `1`

正式v3 runでは122 artifactの構造・hash検証を通過した。候補ごとの最大値は次のとおりである。

| decode → final | 最大平均 ΔE00 | 最大ぼかし ΔE00 p95 | 最大絶対 EV | 最大 plateau 純増 | 最大 1 px dilation 外面積 | 不合格比較 | 採否 |
|---:|---:|---:|---:|---:|---:|---:|---|
| 3,072 → 2,560 | 0.48950815200805664 | 1.5770659446716309 | 0.0057839141227304935 | 0.000016247437024018745 | 0.00012288554481546573 | 3 / 6 | 不採用 |
| 3,840 → 2,560 | 0.41729527711868286 | 1.256845235824585 | 0.00444698566570878 | 0.00004622510251903925 | 0.0001519478617457528 | 3 / 6 | 不採用 |

12比較の値は次のとおりである。判定は上記5条件すべてを満たす場合だけ合格とする。

| decode | シーン / 段階 | 平均 ΔE00 | ぼかし ΔE00 p95 | 絶対 EV | plateau 純増 | 1 px dilation 外面積 | 判定 |
|---:|---|---:|---:|---:|---:|---:|---|
| 3,072 | P1524180 / neutral | 0.33547478914260864 | 0.9453787207603455 | 0.004804658237844706 | 0.0 | 0.00008741578793204452 | 合格 |
| 3,072 | P1524180 / basic-legacy | 0.41447943449020386 | 1.2090030908584595 | 0.004050333518534899 | 0.0 | 0.00003958882542472173 | 合格 |
| 3,072 | P1524180 / full-current | 0.48950815200805664 | 1.5317068099975586 | 0.005034229718148708 | 0.000016247437024018745 | 0.000083296719390744 | 合格 |
| 3,072 | P1522877 / neutral | 0.3468784987926483 | 1.3262600898742676 | 0.0057839141227304935 | 0.000008009299941417692 | 0.00012288554481546573 | 不合格 |
| 3,072 | P1522877 / basic-legacy | 0.4118720591068268 | 1.5770659446716309 | 0.00427408330142498 | 0.000015103251318101933 | 0.00010206136496777974 | 不合格 |
| 3,072 | P1522877 / full-current | 0.34059417247772217 | 1.3295499086380005 | 0.0046658567152917385 | 0.000013272554188635032 | 0.00011281671060339778 | 不合格 |
| 3,840 | P1524180 / neutral | 0.28628039360046387 | 0.777256190776825 | 0.003557615913450718 | 0.000045309753954305797 | 0.00012174135910954891 | 不合格 |
| 3,840 | P1524180 / basic-legacy | 0.3548063337802887 | 0.9928775429725647 | 0.0031291248742491007 | 0.0 | 0.00003546975688342121 | 合格 |
| 3,840 | P1524180 / full-current | 0.41729527711868286 | 1.256845235824585 | 0.0037089409306645393 | 0.00001739162272993556 | 0.00006453207381370826 | 合格 |
| 3,840 | P1522877 / neutral | 0.24590587615966797 | 0.8926499485969543 | 0.00444698566570878 | 0.00004622510251903925 | 0.0001519478617457528 | 不合格 |
| 3,840 | P1522877 / basic-legacy | 0.29344820976257324 | 1.0677764415740967 | 0.0034729798790067434 | 0.00001807813415348565 | 0.00009107718219097832 | 合格 |
| 3,840 | P1522877 / full-current | 0.244581401348114 | 0.913719117641449 | 0.003685911186039448 | 0.00002608743409490334 | 0.00011830880199179847 | 不合格 |

両候補とも平均 ΔE00、ぼかし後 ΔE00 p95、絶対EV、正のplateau純面積増加は全比較で合格し、1 px dilation外面積だけが各3比較で上限を超えた。旧exact-coordinate set-difference、最大connected component、worst 128×128 window、距離histogramは原因分析の診断値であり、正式採否を置き換えない。旧direct 2,560 px decodeの不合格も履歴として保持するが、現行v3の候補行列には含めない。

正式結果を見た後に閾値を緩めていない。全比較を通る候補がないため`selectedCandidate = null`、fallbackはfull-resolution RAW decodeであり、実UIもこの経路を維持する。縮小候補を再検討する場合は現行v3を書き換えず、別の処理変更と独立manifestで新たに評価する。

### Direct Metal表示との境界

実UIには`PHOTO_BENCH_PREVIEW_ROUTE=metal-direct`を正確に指定した場合だけ有効になるMTKView直接表示経路がある。未指定・別値では従来表示が既定であり、direct routeのpreview contextも現時点では`cacheIntermediates = false`である。

native fixtureでは、同じprepared frameをdirect / legacyへmaterializeしたoffscreen出力について、各チャンネル最大差`<= 1 LSB`を回帰テストする。これはorientationを逆にした比較を合格へ倒さない厳格なfixtureである。一方、次はこの校正契約の対象外である。

- drawableが実画面へpresentされた後のピクセル
- SwiftUI / MTKViewのaspect-fit、display scaling、画面色管理を含むactual-screen差
- input-to-present latency、drop frame、stale frame
- occlusion / minimize / timeout / teardownを含むapp lifecycle

現在の実験branchでは、native Metal clear / Core Image solid / production renderの各on-demand probeで`presentedTime > 0`のpositive presentationを確認した。production renderでは写真選択、編集更新、resize、minimizeからのresume後も最新requestのpositive presentationをmanual smokeで確認している。`presentedTime`は絶対時刻であり、input-to-present latencyとして解釈しない。

一方、これはLaunchServicesで起動した実アプリに対するmanual smokeであり、actual-screen pixel parity、反復input-to-present p95、反復drop率、rapid supersede時のstale frame非表示、複数写真後のsteady RSSは未承認である。pure lifecycle reducerは24件の決定的テストを持つが、AppKit / WindowServer統合は自動化されていない。したがってpositive presentation成立を画質または性能のformal passへ読み替えず、既定をlegacyのまま維持して画面契約を別suiteとして追加する。

## EDR 選定

Apple の `extendedDynamicRangeAmount` は `0` が EDR なし、`1` が既定の EDR、`2` が最大 EDR である。DC-S5 の2 RAW で A/B した結果は次のとおり。

| シーン | EDR | 最大値 | `> 1` の画素率 |
|---|---:|---:|---:|
| P1524180 | 0 | 1.09082 | 3.51333% |
| P1524180 | 1 | 2.75977 | 9.36917% |
| P1524180 | 2 | 4.16016 | 9.73042% |
| P1522877 | 0 | 1.10449 | 4.07792% |
| P1522877 | 1 | 2.43164 | 30.98250% |
| P1522877 | 2 | 3.58008 | 33.04500% |

EDR 1 は EDR 2 が回収する `> 1` 領域の約 96.3% / 93.8% を確保しつつ、最大値の拡大を抑えられた。Apple が EDR 1 を既定値と定義していることも踏まえ、DC-S5 に限って `boost = 0.9`、`extendedDynamicRangeAmount = 1` を採用した。他機種へこの値を一般化せず、従来の汎用経路へフォールバックする。

EDR 0 の boost sweep は診断用の旧ベースラインとして残している。`boost = 0.90` の平均 ΔE は P1524180 が `3.055`、P1522877 が `1.655` だったが、これは現在配備する EDR 1 v2 プロファイルの最終品質値ではない。

## 最終レポート

品質判定の正本は `.photobench/calibration/report.json` である。以下はtagged baseline formal runで得た値であり、Lightroom品質の数値はP1前baselineから非回帰だった。C1 shoulder修正後の結果は次のとおり。

| シーン / 経路 | 平均 ΔE basic → full | 平均 EV差 basic → full | complete / near clip | 新規共有 plateau | 判定 |
|---|---:|---:|---:|---:|---|
| P1524180 / RAW | 7.592 → 6.796 | +0.00376 → +0.20779 | 0 / 0 | 0.00036 | EVのみ不合格 |
| P1524180 / LR-input | 5.556 → 4.835 | -0.12585 → +0.02628 | 0 / 0 | 0.00037 | 合格 |
| P1522877 / RAW | 5.858 → 3.341 | -0.18034 → +0.00697 | 0 / 0 | 0.00007 | 合格 |
| P1522877 / LR-input | 5.468 → 3.417 | -0.26834 → -0.08396 | 0 / 0 | 0.00017 | 合格 |

4経路すべてで平均 ΔE は改善し、`full <= basic + 0.25` を満たした。complete clip と near clip は basic / full ともに全経路で 0、新規共有 plateau も上限 `0.0005` を下回った。

唯一の不合格は P1524180 / RAW の平均 EV ドリフトである。許容上限は `abs(+0.00376) + 0.05 = 0.05376 EV` だが、full は `+0.20779 EV` だった。他3経路の EV は次の上限内に収まった。

| 経路 | full の絶対 EV差 | 許容上限 |
|---|---:|---:|
| P1524180 / LR-input | 0.02628 | 0.17585 |
| P1522877 / RAW | 0.00697 | 0.23034 |
| P1522877 / LR-input | 0.08396 | 0.31834 |

したがって、安全性に関する clip / plateau / ΔE ゲートはすべて通過したが、レポート全体の合否は `false` である。P1524180 / RAW では full が basic より `+0.20403 EV` 明るくなり、実験的なカーブとカラーミキサーを初期 ON にできる品質には達していない。段別CPU fixtureは各controlの実装意味を固定するものであり、2実写のfull差をAdobe相当として正当化するものではない。curveとmixerの寄与を期待EVとして差し引く補正は採用せず、現行の画像レベルEV gateをfail-closedで維持する。

## 品質判断

現時点で採用できる判断は次のとおり。

- DC-S5 限定 EDR 1 v2 と最終出力変換は、拡張輝度を保持しながら bounded sRGB へ安全に収める基盤として採用する。
- 最大チャンネル基準 shoulder と固定 L / h gamut compression により、完全クリップ、near clip、新規共有 plateau の回帰は検出されなかった。
- `full` は全4経路で平均 ΔE を改善した。
- ただし P1524180 / RAW の平均 EV ドリフトがゲートを超えるため、カーブと OKLCh 8バンド・ミキサーは実験扱いを維持し、既定 OFF とする。
- preview parity v3 は3,072 / 3,840 px候補とも各3 / 6比較不合格で、採用候補はない。閾値を緩めず、実UIはfull-resolution RAW decodeを維持する。
- 2シーンだけでは事業品質を主張できない。異なる露出、逆光、肌色、人工照明、高彩度色、複数カメラ機種のペアを増やして再評価する。

## 回帰テスト

- Swift tagged baseline: `93 tests / 7 suites`
- Swift current branch: `130 tests / 10 suites`
- Python: `52 tests`

Swift 側では 1D カーブの端点外挿、重複x規則、OKLCh 8バンド境界、Luminance / Saturation / curveの段別CPU fixture、RAW プロファイル選択、generic RAWのY>1合成出力経路、bounded-sRGB neutral bypass、shoulder の C1 連続性、固定 L / h gamut compression、67,368点の運用／stress色域gridを検証する。さらにpreview / full-resolution intent、RAW scale provenance、preview画像と偽装full-resolution画像の原寸export拒否、native寸法の0・非有限・不明と非有限extentの整数化前拒否、同一`RenderEngine`内のpreview / export contextの別instance性、候補なし時のfull-decode fallback、direct / legacy native fixtureの1 LSB parity、latest-only queueのwrong-ID非変更・resize・reentrant・out-of-order挙動、benchmarkのpass / performanceFailed / notEvaluatedとsystem-load snapshot、manifest v3の固定寸法・候補行列、入力・source・binary・122 artifactのhash、path traversal、symlink、case-only alias、正規化後の成果物名衝突を検証する。current branchでは加えて、window visibility、presented callback欠落、10秒deadline、bounded retry、fallback、teardown、request supersedeを純粋状態機械へ抽出したlifecycle reducerを24件、GPU完了とpresented callbackの両順序、GPU error優先、deadline / invalidate後のlate callback抑止をsubmission arbiter 6件で検証する。Python 側ではmanifest / run manifestを再検証したうえで、レポート生成、ΔE / EV、clip / near clip、新規共有 plateau、共通Lanczos preview parity、square-3x3のplateau morphologyと境界・離隔・collapse合成fixture、入力不変性、固定比較行列をfail-closedで検証する。AppKit / WindowServer統合はmanual smokeに留まり、current branchの130件にもactual-screen presentationの自動試験は含まれない。

校正画像は原本を上書きせず、生成物とレポートを `.photobench/` 配下へ分離する。結果を更新する場合はmanifestを明示更新し、run manifestの入力・source・binary・全artifact hashとruntimeを残して、同じ契約から再現できることを確認する。以下はtagged baselineのpreview parity不合格を同じtagから再現する厳格実行で、exit `1`が期待値である。current branchでは26 source契約に対する新しいrun IDとfingerprintが必要になる。

```sh
export PHOTO_BENCH_ROOT=/path/to/photoedit
swift run -c release PhotoBenchCalibration "$PHOTO_BENCH_ROOT"
python3 scripts/analyze-calibration.py "$PHOTO_BENCH_ROOT" --enforce-preview-parity
```
