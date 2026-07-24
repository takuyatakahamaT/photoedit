# Photo Bench プロジェクト概要

- 状態: Phase 0 の証跡基盤、P1 preview parity、canonical settle v4、P1-3 の Metal 直接表示実験、開発用RAWホワイトバランス観測まで完了。v4 の最終縮小順序は 2 development scene で非回帰合格したが、Lightroom 品質、production WB、縮小 RAW 候補は未達。製品経路は full-resolution RAW decode + As Shot + 従来表示を維持
- 対象: オーナー個人専用の Apple Silicon macOS アプリ
- 最終更新: 2026-07-24（JST）
- 開発ルート: このリポジトリのroot（以下の例では`/path/to/photoedit`）

## 0. この文書の役割

この文書は、新しい開発セッションや第三者レビューが最初に読むプロジェクト入口である。製品の目的、完成像、これまでの判断、現在の到達点、未達課題、承認済みの次の方針を一続きで示す。

詳細仕様はリンク先の文書を正とし、実測値や合否に食い違いがある場合は、hash 検証済みの次の JSON を最優先する。

- 画質と再現性: `.photobench/calibration/report.json`、`.photobench/calibration/run-manifest.json`
- RAW WB観測: `.photobench/white-balance-observations/51ba2f46-185d-4b87-8345-407d380214cd/run.json`と同directoryの`analysis.json`
- 性能: 最新のv4 formal archiveは`.photobench/benchmark/latest.json`とrun `bbb5bc5b-7c12-4b29-b803-c863d6059d55`。ただし現行HEADとはmanifest SHAとsource fingerprintが異なり、現行sourceの性能合否は未評価。旧v3の正本3 runは`5b2dae18` / `a13033d0` / `c2c4794f`で、いずれもv4の反復へ混ぜない
- 入力、処理、閾値の現行契約: `calibration/manifest-v4.json`。manifest schema は 4、校正 run manifest schema は 2、派生する analyzer report schema は 5 と区別する

`reviews/2026-07-24-claude-research-improvement-proposals.md` は、外部調査から得た仮説と優先順位案をまとめた助言資料である。ここにある数値、ライセンス解釈、製品比較、技術効果は未確認のものを含み、現行仕様や合格証跡ではない。Lightroom は当面継続するため、契約終了を急いで機能数だけを増やすのではなく、教師出力を活用して画像品質と日常機能を Lightroom と遜色ない水準へ近づける。個別仮説は新しい契約と実測で検証してから採否を決める。

## 1. なぜ作るのか

オーナーは Lightroom を主にローカル写真の画像編集に使っている。クラウド保存、複数端末同期、共有、生成 AI などは現在必要としていない。そのため最終的には Lightroom の有料契約をやめ、日常の写真選別・現像・書き出しを、自作のローカル専用アプリへ移行することが本プロジェクトの目的である。ただし Lightroom は当面継続し、比較基準と退避手段として使う。現在の優先事項は解約時期ではなく、画質と機能性を十分に磨くことである。

完成像は「Lightroom の画面を複製した小さなアプリ」ではない。自分が実際に使う編集ワークフローに範囲を絞りながら、次を同時に満たす Lightroom 代替を目指す。

- 元画像を壊さない、やり直せる非破壊編集
- RAW と JPEG の両方で、仕事や作品用途に耐える色・階調・解像感
- スライダー操作へ連続して追従する快適なプレビュー
- 17,000 枚規模でも選別、検索、整理、書き出しを待たせないローカル UX
- ネット接続、クラウド、アカウント、サブスクリプションに依存しない運用
- ブラックボックスな「なんとなく近い」補正ではなく、再現可能な画質・性能測定に基づく改善

「Lightroom と遜色ない」は、Adobe Camera Raw の非公開処理をピクセル単位で複製する意味ではない。オーナーが使う写真と編集操作について、見た目、操作感、非破壊性、整理、書き出しまでを含む実用上の完成度で置き換えられることを意味する。Lightroom 解約の最終判断は、代表画像を用いた目視受け入れと自動ゲートの両方を満たした後に行う。

Lightroom は移行期間中の比較基準、教師画像の生成手段、退避手段として積極的に用いる。完成後の常用併存は目標にせず、代表ワークフローの受け入れが済んだ時点で契約を終了できる状態を完成条件とする。

**現時点では Lightroom を解約できる状態ではなく、解約を急がない。** 画質gate、実画面preview、編集永続化、カタログ・選別、クロップ等が未達である。Lightroom を使える間に比較用データを増やし、品質差を分解してから移行可否を判断する。

## 2. 製品原則

判断の優先順位は次のとおり。

1. 顧客 UX。この場合はオーナー自身の編集品質、操作感、データ安全性
2. 開発・運用速度。検証可能な小さい変更を積み、早く実用へ近づける
3. コスト。ローカル個人利用の範囲では、重要な UX のための開発工数や軽微な計算コストを惜しまない

実装判断ではさらに次を守る。

- 原本は read-only とみなし、上書きしない。
- 画質や証跡の欠測を合格扱いにしない。構造・hash・環境不整合は fail closed にする。
- テストやゲートを下げて改善扱いにしない。
- プレビュー高速化と原寸書き出しの品質を分離し、片方の最適化で片方を劣化させない。
- 実験的な処理は、十分な校正データを通るまで既定 OFF にする。
- 短期的な対症療法より、測定できる処理境界と交換可能な設計を優先する。

## 3. 想定する利用環境とワークフロー

- 利用者: オーナー 1 人
- 端末: Apple Silicon Mac
- 写真置き場: 完成時はユーザーが選んだ外付けSSD上の写真フォルダ
- 規模: 約 17,000 枚、現状約 897 GB。選別後は約 500 GB が目標
- 形式: JPEG と RAW が概ね半々
- 主な RAW: Panasonic Lumix DC-S5 の RW2（検証原本は 6000×4000、14 bit）
- 主な操作: フォルダ読込、選別、基本補正、プリセット、将来のクロップ・部分補正、JPEG 等への書き出し

日常フローの目標は、写真ルートを一度選ぶだけで以後は復元でき、一覧から写真を選び、スライダーやプリセットで非破壊編集し、必要な画像だけを書き出せることである。外付け SSD が一時的に未接続でも、写真消失やカタログ破損として扱わず、再接続後に復旧できるようにする。

## 4. 目標仕様

### 4.1 Lightroom 解約に必要な中核機能

- ローカルフォルダの安全な参照と再リンク
- RAW / JPEG の高速な一覧、比較、評価、選別
- 写真ごとの永続的な非破壊編集と Undo / Redo
- 露出、コントラスト、ハイライト、シャドウ、白、黒、WB、自然な彩度、彩度
- 実用画質のトーンカーブと色別補正
- XMP プリセットの対応項目、未対応項目を明示した読込
- クロップ、回転
- 非 AI のブラシマスクと部分補正
- 原寸・指定サイズの安定した書き出し
- アルバム、評価、検索、フィルター
- 17,000 枚規模での高速起動、スクロール、サムネイル生成

### 4.2 現時点の非目標

- クラウド保存、同期、共有、共同編集
- アカウント、課金、サブスクリプション
- 生成 AI、AI 補正、AI マスク、顔・被写体認識
- Adobe Camera Raw、Adobe Color、PV2012 の非公開数式の完全複製
- Lightroom の全機能、固有アセット、名称、画面の複製
- iPhone、iPad、Windows、動画編集、App Store 公開、他ユーザー向け配布

AI は将来も禁止と決めたわけではないが、現在の目的達成には不要であり、画質、操作感、整理、非破壊性を先に完成させる。

## 5. 採用した設計

macOS ネイティブの `SwiftUI + AppKit + Core Image / Metal` を採用している。将来のカタログは SQLite を予定する。Core Image の RAW 現像を交換可能な decoder 境界の内側へ置き、画質が到達しない場合に UI 全体を捨てず LibRaw / DCP 系へ差し替えられる構造を目指す。

現在の主なモジュールは次のとおり。

- `PhotoCore`: decode、編集値、トーン、色、出力変換、書き出し
- `PhotoBenchApp`: SwiftUI 画面、編集状態、preview 調停
- `PhotoBenchAppSupport`: security-scoped bookmark とフォルダ権限
- `PhotoBenchCalibration`: 画質校正 artifact の生成
- `PhotoBenchBenchmark`: release 性能測定
- `scripts/analyze-calibration.py`: hash 検証、色差・EV・clip・plateau の fail-closed 判定
- `PhotoBenchWhiteBalanceObservation`: 開発専用のAs Shot / custom RAW WB artifact生成
- `scripts/analyze-white-balance-observation.py`: WB観測のprovenance・metadata・artifact検証と記述値生成。production採用は禁止

現在の RAW 処理は概ね次の流れである。

```text
Core Image RAW 8
  → DC-S5 限定 RAW profile（boost 0.9 / EDR 1）
  → extended-linear sRGB
  → 基本階調
  → 任意の encoded-sRGB tone curve
  → 任意の OKLCh 8 band color mixer
  → vibrance / saturation
  → edge-clamped Lanczos downsample（preview / 指定サイズ時）
  → terminal sRGB output transform
      → highlight shoulder
      → L / h 固定の gamut compression
  → sRGB preview / export
```

現行production graphの順序は、**extended-linear-sRGB edits → edge-clamped Lanczos downsample → terminal sRGB transform** である。`CIContext`のworking color spaceはextended-linear sRGB、出力はsRGBとして明示し、有限画像の外側に現れる透明黒をLanczosが拾わないよう縮小前にedge clampし、縮小後に正確な整数extentへcropする。Core Imageの遅延評価graphは保ったまま、最終ラスタで順序とalphaを回帰テストする。

原本アクセスは App Sandbox と security-scoped bookmark に限定する。JPEG 書き出しは隠し一時ファイルへ完成させてから設置し、原本、既存リンク、既存フォルダを上書きしない。

## 6. これまでに取り組んだこと

### 6.1 アプリとファイル安全性の基盤

- 3 ペインの macOS `.app` と Finder からの起動導線を作成
- ユーザーが選んだフォルダだけを非同期走査
- bookmark の正常、stale、破損、外付け未接続と access 開始・終了をテスト
- JPEG / HEIC / PNG / TIFF / RAW の読込と遅延サムネイル
- 原本非変更、上書き拒否、原子的 JPEG 書き出しを実装

### 6.2 基本現像と XMP

- 8 本の基本調整スライダーを実装
- `colorful`、`bluesky2`、`night`、`pastel` の Process Version 11 XMP を解析
- 属性形式と要素形式、WB の mode / absolute / increment / explicit zero を区別して保持
- RGB tone curve と 8 色 color mixer を実験実装
- Adobe HSL Luminance と同義でない近似処理は明記し、curve / mixer を既定 OFF に設定

### 6.3 RAW、HDR、出力品質

- DC-S5 の Make / Model 一致時だけ専用 RAW profile を適用
- extended-linear 作業空間で HDR 値を保持
- C1 接続の highlight shoulder と、明度・色相を固定した色域圧縮を導入
- bounded sRGB の neutral JPEG は不要な output transform を迂回
- CPU / software / Metal 一致、67,368 点の色域 grid、HDR 端点外挿を回帰テスト化

### 6.4 再現可能な画質・性能証跡

- 入力、処理 fingerprint、source、binary、環境、全 artifact を hash-lock する manifest v4 契約を作成
- Lightroom の適用前 / 適用後 16 bit TIFF 2 シーンを RAW と Lightroom-input の 2 経路で比較
- CIEDE2000、EV drift、complete / near clip、新規共有 plateau を自動判定
- preview parity は full-resolution / 3,072 px / 3,840 px RAW decode を同じ編集後に共通 Lanczos で最終 2,560 px へ揃え、平均 ΔE00、ぼかし後 ΔE00 p95、EV、plateau 純面積増加、1 px dilation 外の新規 plateau を独立判定
- canonical settle v4 は full-resolution RAWを `basic-legacy` / `full-current` で編集し、edge-clamped Lanczosで2,560pxへ縮小した後にterminal sRGB変換する同一production順序を固定。complete / near clipの画素数非増加と新規plateau面積を独立判定
- path traversal、symlink、case-only alias、artifact 衝突、実行途中の変更を拒否
- latest校正を置換する前に、旧complete runを全artifactのbyte count / SHA-256検証付きで`.photobench/calibration-archives/<run-id>/`へ退避
- release benchmark schema 3でprocess-fresh、warm preview、slider proxy、原寸JPEGとsystem loadを記録。archived v4はsource / binary固定のformal runを1件保存しているが現行HEADとはfingerprint不一致で、旧v3連続3 runも別履歴として分離
- 実装と証跡を Claude に設計・実装・最終レビューしてもらい、確定した指摘を文書とゲートへ反映

### 6.5 P1 preview / export 分離の安全基盤

- decoder API に `interactive-preview(maxDimension:)` と `full-resolution` の意図を追加
- RAW preview は `CIRAWFilter.scaleFactor` を decode 前に設定し、原寸 export は scale `1.0`を強制
- decode intent、要求寸法、実 decode 寸法、原寸寸法、scale、backend を校正・benchmark 証跡へ記録
- preview 解像度の画像を JPEG / 原寸 TIFF export へ渡した場合は型付きエラーで拒否
- `full-resolution` と偽装した縮小画像も、原寸寸法と実 image extent の一致を確認して拒否
- RAW native 寸法が0・非有限・不明、または image extent が非有限・非正なら整数化より前に fail closed で拒否
- 2 シーン × 3 編集段階で、full-resolution / 3,072 px / 3,840 px RAW decode を編集後に共通 Lanczos で 2,560 px 化する独立 parity gate を追加
- 校正 run を latest だけでなく run ID ごとに保存し、失敗結果も履歴として保持
- 1つの `RenderEngine` が preview / export 用の別 `CIContext` instance を保持し、現スライスでは双方 `cacheIntermediates = false`。benchmark も同じ topology と decode intent を使用
- benchmark に worker provenance、thermal / low-power、coordinator / worker 別 peak RSS と run / workload / process-fresh worker の system-load snapshot を追加
- benchmark 反復ごとに一時画像を解放し、測定 runner 自身によるメモリ累積を除去
- export 中は写真ルートを切り替えられないようにし、security-scoped access の途中切替を防止

### 6.6 P1-3 Metal 直接表示の実験経路

- full-resolution RAW の graph を準備し、`MTKView` / `CIRenderDestination` へ CPU RGBA8 readback を挟まず渡す opt-in 経路を実装
- 有効化条件を環境変数 `PHOTO_BENCH_PREVIEW_ROUTE=metal-direct` の完全一致に限定し、通常起動は従来表示のまま維持
- latest-only queue、request ID の厳密な所有権、ウィンドウ単位の可視性判定、drawable 再試行、10秒 watchdog、一方向の従来表示 fallback を実装
- direct / legacy のオフスクリーン fixture は各 channel `1 LSB`以内で合格し、上下反転を誤合格させない回帰テストへ強化
- `cacheIntermediates` は、複数写真遷移後の定常 RSS と eviction 契約がない段階では `false`を維持
- 最終ハードニング直前の支援技術経由 smoke では、可視 draw 後に GPU command が2回とも completed になった一方、初回は `presentedTime = 0`で drop、再試行は presented callback が返らず、10秒後に従来表示へ fallback した。その後に`drawableSize > 0`のwatchdog条件と`allowsNextDrawableTimeout = true`を追加し、最終sourceではfallback画像と空表示flashがないことを再確認したが、同じ詳細traceは再取得していない

したがって、ここまでで「直接描画 graph を組み、失敗を検出して安全に戻れる」ことは確認したが、「実際の画面に direct frame が提示された」ことは確認していない。オフスクリーン parity は実画面 parity の代用ではなく、この経路は製品準備完了ではない。

### 6.7 RAWホワイトバランスの開発用観測

- 既存As Shot経路を一切観測・変更せずdelegateする境界と、要求ごとにfreshな`CIRAWFilter`を作るcustom WB境界を分離
- Apple / AdobeのTemperature・Tintは値域が同じでもbackend固有とし、Lightroom値をCore Imageへ直接流用しない
- 既存delegateのAs Shot、custom用fresh filter中心点、mired軸6、Tint軸6、交差点4の計18候補をsceneごとに事前登録
- 2 development scene × 20 artifact、合計40 artifactを最大辺1,500px、RGBA16 sRGB TIFFで生成し、source metadataを除去
- setter順序、input / source / binary / ExifTool、artifact byte count / SHA-256、release provenance、private inputのGit非追跡、no-replace出力をfail-closedで検証
- 正式run `51ba2f46-185d-4b87-8345-407d380214cd`は構造検証に合格。ただし`exploratory-observation-only`、`productionAdoptionAllowed = false`をmanifestとreportに固定
- 2sceneともcustom中心点はAs Shotへ数値的に極めて近かったがbyte exactではない。候補の順位、Adobe→Apple変換、製品値は決めていない

詳細な代表値、制約、次の受け入れ条件は`docs/WHITE_BALANCE_OBSERVATION.md`を正とする。

## 7. 2026-07-24 時点の到達点

### 7.1 動く機能

- Lumix RW2 と JPEG を同じ画面で開ける
- DC-S5 RW2 を 6000×4000 で decode できる
- 8 基本調整と XMP 近似適用ができる
- 写真ごとの編集状態をアプリ終了まで保持できる
- 6000×4000、sRGB の原寸 JPEG を安全に書き出せる
- 同じ署名のアプリ再起動後、選択済みフォルダを bookmark から復元できる
- 製品挙動を変えない開発用経路で、RAW WBの固定候補を再現可能に観測できる

自動検証は Swift Testing `119 tests / 10 suites`、Python calibration analyzer `61 tests`、Python WB observation analyzer `17 tests` が成功している。従来の不正値拒否、decode intent、manifest / artifact、preview parity、Metal queue契約に加え、現行graphがextended-linear編集後にedge-clamped Lanczos縮小し、その後だけterminal sRGB変換すること、未clamp Lanczosで透明黒が境界へ混入するnegative control、旧graphとの識別、bounded neutral rasterのbypass、canonical settleの整数clip count、fresh RAW WB filter、固定18候補、private data / provenance / no-replace契約を回帰対象にした。配布形の `dist/Photo Bench.app` は以前のsourceでrelease buildとad-hoc署名を完了しているが、今回のv4 / WB observation sourceで再配布buildを承認したという意味ではない。ウィンドウ可視性、drawable drop、watchdog timeout、teardown、production WBのlatest-only decodeといったapp lifecycle分岐も未自動化である。

### 7.2 画質の現在値

2 シーン × 2 経路のうち 3 経路が全ゲート合格、1 経路が EV のみ不合格で、formal report の quality 判定は **不合格** である。

| シーン / 経路 | 平均 ΔE basic → full | 平均 EV basic → full | 新規共有 plateau | 判定 |
|---|---:|---:|---:|---|
| P1524180 / RAW | 7.5927 → 6.7963 | +0.00384 → +0.20787 | 0.000357 | EV 不合格 |
| P1524180 / LR-input | 5.5557 → 4.8355 | -0.12577 → +0.02634 | 0.000371 | 合格 |
| P1522877 / RAW | 5.8595 → 3.3423 | -0.18014 → +0.00710 | 0.000073 | 合格 |
| P1522877 / LR-input | 5.4686 → 3.4174 | -0.26830 → -0.08392 | 0.000177 | 合格 |

全経路で平均 ΔE、complete / near clip、新規 plateau のゲートは通ったが、P1524180 / RAW の full は EV 絶対誤差上限 `0.05384 EV`に対して `0.20787 EV`である。目視でもP1524180のfull-currentはLightroom-afterより全体が明るく、暖色・マゼンタと青の彩度が強い。P1522877はより近いが、やや暖色・高彩度に見える。したがって、安全な出力基盤は得たものの、Lightroom の画作りを再現した、または curve / mixer を本番既定 ON にできるとは判断しない。

preview parity v4は、このLightroom品質ゲートとは独立に、full-resolution、3,072px、3,840pxのRAW decodeを`neutral`、`basic-legacy`、`full-current`で比較する。現行の採否はmanifest v4の12比較を正とする。

| decode → final | 最大平均 ΔE00 | 最大ぼかし ΔE00 p95 | 最大絶対 EV | 最大 plateau 純増 | 最大 1 px dilation 外面積 | 不合格比較 | 採否 |
|---:|---:|---:|---:|---:|---:|---:|---|
| 3,072 → 2,560 | 0.48846879601478577 | 1.5748517513275146 | 0.005485501606017351 | 0.000054920913884007027 | 0.00012105484768599882 | 2 / 6 | 不採用 |
| 3,840 → 2,560 | 0.416765421628952 | 1.2567764520645142 | 0.00424525560811162 | 0.00009954415641476274 | 0.00021281854130052725 | 4 / 6 | 不採用 |

閾値は平均 ΔE00 `1.0`、ぼかし後 ΔE00 p95 `2.0`、絶対 EV `0.02`、正の plateau 純面積増加 `0.0001`、参照 plateau を square-3x3 で 1 px 拡張した外側の新規面積 `0.0001`である。v4では3,072px候補が2 / 6、3,840px候補が4 / 6比較でspatial plateau上限を超えた。正式結果を見た後に閾値を緩めていない。全比較を通る候補がないため formal report の preview parity 判定は **不合格**、`selectedCandidate = null`、fallback は full-resolution RAW decode であり、実 UI もこの経路を維持する。

### 7.3 canonical settle v4

現行production順序を固定するcanonical settleは、2 development sceneの両方で合格した。

| scene | complete clip pixels basic → full | near clip pixels basic → full | 新規共有plateau面積 | 上限 | 判定 |
|---|---:|---:|---:|---:|---|
| P1524180 | 0 → 0 | 0 → 0 | 0.00003592743116578793 | 0.0005 | 合格 |
| P1522877 | 0 → 0 | 0 → 0 | 0.00009839997070884592 | 0.0005 | 合格 |

これは「terminal sRGB変換を縮小後へ移した現行graphが、旧basic段階に対してclip / plateauを増やさない」ことだけを示す。Lightroom一致、別カメラ、未観測シーン、RAW WB、camera profileの品質合格ではない。

### 7.4 RAWホワイトバランス観測の現在値

正式run `51ba2f46-185d-4b87-8345-407d380214cd`は、2 development scene、0 holdout、各18候補、40 / 40 artifactの構造・hash・metadata検証に合格した。P1524180 / P1522877のCore Image As Shotは固定Lightroom参照に対してmean ΔE00 `3.6660247` / `2.1292396`、EV drift `+0.1050286` / `+0.0294950`だった。fresh filter中心値を書き戻したcustom centerとAs Shotのmean ΔE00は`0.0001510` / `0.0003225`だがbyte exactではない。setter順序は両sceneでbyte exactだった。

この結果には順位付け、採択、変換写像がなく、production adoptionは明示的にfalseである。固定Lightroom As Shot参照との差はprofile差も含み得るため、WB単独の誤差とも断定しない。

### 7.5 性能の現在値

Mac16,10 / Apple M4 / macOS 26.3.1のrelease buildで、24MP RAWをwarm各20回、process-fresh 40回測定したv4 formal archiveは1件である。ただしこれはWB観測source追加前のmanifest SHA `87a9ea...` / source fingerprint `1451c62b...`へ固定され、現行HEADと一致しない。production render graphの変更はないが、現行sourceのformal性能合否としては未評価である。測定する2,560px `interactive-preview` engine経路は画質不合格の実験候補で、実UIのfull-resolution decode、`MTKView`提示、入力イベントから画面到達までのlatencyを表さない。

| workload | p95 | gate | 判定 |
|---|---:|---:|---|
| process-fresh tone engine preview | 357.9901622 ms | ≤ 1,000 ms | 合格 |
| warm exposure-perturbation engine proxy | 55.6492479 ms | ≤ 50 ms | 不合格 |
| warm full-current-settings engine preview | 58.0226753 ms | ≤ 300 ms | 合格 |
| full-resolution JPEG q0.92 | 225.92233125 ms | ≤ 3,000 ms | 合格 |

最新v4 archiveは`3 / 4`合格で、slider proxyだけが50ms gateを超えた。1 runだけで、さらに現行HEADとfingerprintが異なるため、安定性や現行合否を証明しない。canonical v3の連続3 runは`BENCHMARK.md`に履歴として保存するが、v4へ合格を継承しない。direct経路はpositive presentationも未確認で、UI p95やactual-screen parityの数値はまだない。

### 7.6 証跡 ID

- calibration run ID: `1c324af0-7ec3-4c33-bc6f-3bd653794800`
- calibration release binary SHA-256: `6f1be9b7a44529f25fb7fe8ad90b6b030bfa128e2108174bc86cab09cd775a15`
- manifest v4 SHA-256: `9da1fd58ec4ead9b921dea477319423711567de3c06f8eb39d429c89980267f6`
- calibration source fingerprint: `b7d8c57fab4428679a4f4e7cfacf2f64e67b317e9b9f46a00093cf7b5bf1a858`
- WB observation run ID: `51ba2f46-185d-4b87-8345-407d380214cd`
- WB manifest SHA-256: `aea4c93626b0a32259c747d2e2ca4ca82b45647d0336507bb709bc86b4e0faf3`
- WB source fingerprint: `413fce7eb57938b958f3e1efd7f835e6fd7cae5561e8327341e4c4faaaec8b3e`
- WB release binary SHA-256: `5e08849cc3d431cde4c42aad7523fd4b704591ae5aecb3f2d11404f92a0edf44`
- latest v4 benchmark archive: `bbb5bc5b-7c12-4b29-b803-c863d6059d55`（3 / 4合格、現行HEADとはfingerprint不一致）
- benchmark release binary SHA-256: `7563d61a41a66dd0a8762acf2374e1aa4aceff5fffb556405eaf619b739dcec0`
- benchmark archive manifest SHA-256: `87a9ea124bb8425a8efc8ef4fe79748c54b55097bfcfe503e96ef693304bb312`
- benchmark archive source fingerprint: `1451c62b42e175814a316c1e7f8ffaaf44d17cd6ae9397ea8edd1e7eb74e3125`
- schema: manifest `4` / calibration run `2` / analyzer report `5` / benchmark report `3`
- calibration検証対象: 7入力、26 source、122 / 122 artifact
- WB観測検証対象: 4 private input、28 source、40 / 40 artifact

旧v3 run `ceea9eb4-b490-4a1f-9984-3d294e2f50bb` は `.photobench/calibration-archives/ceea9eb4-b490-4a1f-9984-3d294e2f50bb/`へ、run manifest記載の122 artifactとともに保存した。旧graphをv4閾値で後追い測定すると、P1524180はcomplete clip `2,972 → 4,013`、near clip `3,289 → 4,598`、新規plateau `0.00008444090509666081`、P1522877はcomplete clip `13 → 1,500`、near clip `2,927 → 4,927`、新規plateau `0.00008855997363796134`であり、両sceneともclip count非増加を満たさない。旧失敗を消さず、現行v4の改善証拠と対にして残す。

## 8. 現在の課題

### 8.1 Lightroom 解約をまだ判断できない理由

- 画質校正が開発に使った 2 シーンだけで、独立 holdout がない
- P1524180 / RAW で実験的 full 処理の EV drift が未達
- WB は解析・保持と開発用RAW観測までで、製品のpreview / export / persistenceへ未適用
- Adobe Color / DCP、レンズ補正、ディテール、ノイズ低減は未対応または未校正
- 実 UI の slider input-to-screen latency と drop frame をまだ測っていない
- preview parity v4で3,072pxが2 / 6、3,840pxが4 / 6比較不合格で、実UIはfull-resolution RAW decode経路のまま
- Metal 直接表示は GPU command completion までは到達したが、positive `presentedTime`を得られず、actual-screen 表示成功・実画面1 LSB parity・UI p95を確認できていない
- 編集の再起動後復元、SQLite カタログ、評価・選別、検索が未実装
- クロップ、回転、ブラシ部分補正が未実装
- 原寸 JPEG 以外の主要 export 契約が不足
- 校正runnerは単一ユーザーの直列実行を前提としており、別processの同時起動を排他するcross-process lockがない
- 教師画像、代表A/B比較出力、原本・評価・アルバム・編集メタデータの完全ローカル退避手順が未確定。ただしLightroomを当面継続するため、解約期限を想定した緊急作業ではない

### 8.2 品質上のリスク

- Adobe の非公開現像との差を、2 枚向け係数で過学習する危険
- RAW 機種ごとの色、WB、レンズ、ノイズ特性を DC-S5 の値で一般化する危険
- 縮小 preview の高速化で、原寸 export と違う判断をユーザーへ見せる危険
- Core Image の OS / RAW decoder 更新で出力が暗黙に変わる危険
- cache 導入で unified memory が増え続ける危険
- 現在の表示・書き出し契約は sRGB SDR / 8-bit JPEG が中心で、Display P3、16-bit 最終出力、EDR 表示の製品仕様は未確定
- direct 経路では、古い request の `present`登録後に新しい request が来ると、旧 frame が理論上いったん提示されうる。latest-only queue は準備前後の stale workを落とすが、「実表示した stale frame 0件」の完全保証ではない
- 可視性はウィンドウ単位であり、preview領域の遮蔽や画面外を厳密には表さない。visibility、drop、timeout、teardown の coordinator lifecycle 分岐にも app-level 自動テストがない

対策は、manifest で処理意図と出力を分離し、品質・性能・メモリをそれぞれ独立に gate することである。

### 8.3 現在つまずいている点と扱い

1. **Metal drawable の実提示と二段目の縮小**: command buffer は completed になるため graph や GPU 実行の単純失敗ではない。初回の `presentedTime = 0` と再試行後の callback 欠落が残り、drawable lifecycle / presentation timing の境界で止まっている。さらにopt-inの直接表示は、canonical settle済みの2,560px rasterをdrawableへaffine fitするため、より小さい画面では品質契約外の二段目縮小が入り得る。positive presentationと実画面品質が成立した後、drawable寸法へのLanczos生成またはfit filter契約を決めるまで製品採用しない。10秒 watchdog と一方向 fallback により利用不能にはならないが、成功条件を満たしていない。
2. **縮小 RAW preview の画質契約**: 3,072 / 3,840 px は平均色差・EV等を通っても、事前登録した spatial plateau gate をそれぞれ2 / 6、4 / 6比較で超えた。結果を見て閾値を変えず不採用にした。別のdraft仮説を試す場合は既存証跡を変更せず、新契約として扱う。
3. **画質の一般化**: 2シーンだけでは、P1524180のEV失敗が実装欠陥、camera profile差、シーン固有過学習のどれかを十分切り分けられない。Lightroom 契約中のデータ確保を先に行い、その後に独立 holdout 付きで再設計する。
4. **RAW WBのproduction接続条件**: 2sceneの観測構造は整ったが、固定Lightroom As Shot参照しかなく、Adobe profile差とWB差を分離できない。Lightroom側のTemperature / Tint sweep、gray card / ColorChecker、領域別指標、最低2 sealed holdoutを揃え、閾値を事前登録するまで候補値や変換式を選ばない。UIへ接続するときはdecode-affecting editとしてlatest-only / cancellation / stale result拒否、preview / export / persistence / Undoの同一intentを必要条件にする。
5. **製品ループの未成立**: 編集値が終了時に消え、17,000枚の選別・検索・再リンク、クロップができないため、現状は日常利用から改善情報を得られる段階にない。
6. **校正の同時実行**: 旧complete runの検証付きarchiveと不完全runの回復は実装したが、複数processを跨ぐlockは未実装である。同時runを避ける運用が必要で、将来の自動化前に排他契約を追加する。

このため、Metal は「positive presentation を得るための短い切り分け」と「app lifecycle テスト境界の抽出」まででtimeboxする。それで閉じなければ既定OFFのまま保留する。主軸はLightroom教師を用いたRAW WB・EV・camera profileの品質改善とscene拡張であり、並行して編集永続化、SQLiteカタログ、クロップ、埋め込みJPEGを用いた選別を進める。`cacheIntermediates = true`、linear RAW土台、DCP、SSIMULACRA2、draft表示等は有望な仮説だが、RSS、ライセンス、知覚相関、画質を未実測のため採用済み事実にしない。

## 9. 承認済みの P1 方針

ここでいう P1 は、現在もっとも優先する preview UX 改善スライスを指す。`DESIGN.md` の製品ロードマップ上の「Phase 1: 使える最小版」と混同しない。

### P1-0 受け入れ契約を先に作る

`CIRAWFilter.scaleFactor`による 3,072 / 3,840 px の縮小 RAW preview と full-resolution 基準を、それぞれ同じ編集後に共通 Lanczos で最終 2,560 px へ揃え、manifest 管理の artifact として比較する。通常表示だけを見て補正時の差を見逃さないよう、`neutral`、`basic-legacy`、`full-current`の3段階を2シーンで測る。preview parity は 2シーン × 3段階 ×（full-resolution 基準 + 2候補）= 18 artifact、校正全体では122 artifactである。

- 平均 ΔE00 ≤ `1.0`
- ぼかし後 ΔE00 p95 ≤ `2.0`
- 平均 ΔEV の絶対値 ≤ `0.02`
- 正の plateau 純面積増加 ≤ `0.0001`
- 参照 plateau を square-3x3 で1 px拡張した外側の新規面積 ≤ `0.0001`
- 欠測、寸法不一致、hash 不一致は構造エラーとして不合格
- 原寸 export の既存 hash / 画質 gate は非回帰

実装と正式測定は完了した。122 artifact の構造・hash 検証は合格し、両候補とも平均 ΔE00、ぼかし後 ΔE00 p95、絶対 EV、plateau 純面積増加は全比較で合格したが、dilation 外面積は3,072px候補で2 / 6比較、3,840px候補で4 / 6比較が不合格だった。`selectedCandidate = null` と失敗証跡を保存し、実 UI は full-resolution RAW decode を維持している。

### P1-1 preview / export intent を分離する

- decoder API に preview と full-resolution export の意図を明示
- decoder の preview intent は表示寸法に近い`scaleFactor`を要求できるが、これは品質gate用の実験候補であり、現行productionには接続しない
- 現行productionのRAW previewはfull-resolution decodeを維持し、表示時のrender / downscaleだけをpreview解像度へ合わせる
- export は原寸 decode を維持
- native 寸法が0・非有限・不明、または実 extent が非有限・非正なら preview / export とも整数化前に拒否
- P1-0 の gate を通った経路だけを実 UI に採用

decoder 境界、provenance、原寸 export guard までは実装済み。parity gate が未達のため、縮小 RAW decoder intent のアプリ表示経路への接続は意図的に保留している。

### P1-2 context と cache の用途を分離する

- preview / export の別 `CIContext` instance 化は実装済み
- 現段階は双方 `cacheIntermediates = false`で、export の再現性を基線として固定
- 縮小 RAW 候補が不採用の間は、その候補を前提とした cache 最適化を本番経路へ進めない。full-resolution decode を含む採用済み表示経路で profile した後、必要な場合だけ preview 側へ上限付き intermediate cache を導入し、memory limit、写真切替時の eviction、複数写真後の定常 RSS gate を追加
- export は別 instance、cache 無効を維持

### P1-3 画面への直接描画

- `MTKView` / `CIRenderDestination` へ直接描画し、CPU RGBA8 readback を外す経路を opt-in で実装済み
- sRGB / SDR / 対応 8-bit unorm pixel format を固定済み
- 非 Metal fallback と、両経路のオフスクリーン出力を厳格な 1 LSB 以内で監視する fixture を実装済み
- request IDを伴う latest-only coalescing、可視時の再試行、10秒watchdog、失敗後は再度directへ戻らない一方向fallbackを実装済み

本番採用条件は未達である。実機 smoke では GPU command が2回 completed になったが、初回は `presentedTime = 0`、再試行は presented callbackなしでtimeoutした。従来表示への復旧は成功したものの、direct frameの positive presentation は確認できていない。また、present登録後に新requestが来る競合では、旧frameが理論上提示される余地が残る。したがって通常起動は legacy のまま、directは完全一致の環境変数でのみ試せる診断経路である。

### P1-4 実 UI で合否を測る

- app-side source fingerprint は追加済み
- warm-up 5 回以上、process-fresh 40 回へ測定契約を強化
- worker ごとの thermal / low power、coordinator / worker 別 peak RSS を記録
- run / workload / process-fresh worker の開始・終了 system-load snapshot を全件記録し、loadを理由にsample削除、outlier除外、再試行をしない
- `preview-ui-path` で input event → decode → render → present と drop frame を Instruments / signpost で測定
- 実 UI input-to-screen p95 ≤ `50 ms`を維持し、engine proxy で代用しない

signpostとfallback診断は実装したが、positive presentationが得られていないため input-to-screen p95、drop frame率、actual-screen parityは未測定である。現行のengine benchmark値をこれらの代用にしない。

### P1-5 kernel の保守改善

deprecated CIKL の packaged Metal kernel 化は必要だが、現 baseline の第一ボトルネックではない。preview pipeline の profile 後に行い、CPU / software / Metal、色域 grid、全校正 artifact を非回帰にする。

### P1 preview parity / canonical settle v4 の完了結果と次の判断

最終出力 `2,560 px`と RAW decode 寸法 `3,072 / 3,840 px`を分離した実験は、再現可能なartifact、手順、morphology合成fixtureをmanifest v4へ固定して正式実行済みである。最大値と採否は次のとおり。

| decode → final | 最大平均 ΔE00 | 最大ぼかし ΔE00 p95 | 最大絶対 EV | 最大 plateau 純増 | 最大 1 px dilation 外面積 | 不合格比較 | 採否 |
|---:|---:|---:|---:|---:|---:|---:|---|
| 3,072 → 2,560 | 0.48846879601478577 | 1.5748517513275146 | 0.005485501606017351 | 0.000054920913884007027 | 0.00012105484768599882 | 2 / 6 | 不採用 |
| 3,840 → 2,560 | 0.416765421628952 | 1.2567764520645142 | 0.00424525560811162 | 0.00009954415641476274 | 0.00021281854130052725 | 4 / 6 | 不採用 |

両候補とも、参照 plateau の固定1 px拡張外にある spatially-distinct new area だけが上限 `0.0001`を超えた。旧 direct 2,560 px decode と exact-coordinate set-difference は履歴・診断値として残すが、現行採否には使わない。正式結果を見た後に閾値を緩めず、`selectedCandidate = null`、fallback は full-resolution RAW decode とする。

現行productionのsettle順序はextended-linear編集→edge-clamped Lanczos→terminal sRGBへ固定し、2sceneのclip count `0 → 0`とplateau上限を通過した。一方、縮小RAW候補は不採用で、full-resolution decodeを保ったMetal直接表示も実画面のpositive presentationは未確認である。canonical settle合格をpreview速度やLightroom品質の合格へ読み替えない。

## 10. その後のロードマップ

Lightroomは当面継続し、画質・機能性をLightroomと遜色ない水準へ近づけることから逆算して次の順へ更新する。

1. **画質データを増やし、RAW現像差を分解**
   - 逆光、肌色、人工照明、高彩度、低照度、ISO違いを含む5〜10以上の教師sceneと、最後まで調整に使わないsealed holdoutを作る
   - WBの固定18候補を観測する基盤は完了した。次はLightroom側のAs Shot / 色温度 / tint教師sweep、gray card / ColorChecker、neutral / skin / foliage / highlight ROIを同条件の16bit基準出力として保存する
   - developmentを5〜10以上、sealed holdoutを最低2 sceneへ増やし、Adobe値の直接コピーbaselineと説明可能なtransform候補をholdout前の閾値で比較する
   - P1524180のEV差をcurve、mixer、RAW WB、baseline exposure、camera profileへ分解し、Core Image RAWとDCP対応backend候補を同じ受け入れ契約で比較する
2. **Metal実験の終了条件を確定**
   - positive presentationの取得とapp lifecycle test境界の抽出だけを短いtimeboxで試す
   - 未解決なら `metal-direct`を既定OFFの診断経路として保留し、legacy表示で製品機能を進める。`cacheIntermediates`は定常RSS、上限、evictionを測るまで有効化しない
3. **Lightroom相当の日常編集機能を埋める**
   - 教師・holdout契約を通ったRAW WBを、latest-only decode、preview / export一致、永続化、Undo / Redoと一体で接続する
   - クロップ・回転、Before / After、export presetを優先する
   - 実験的curve / mixerはholdout合格まで既定OFFを維持する
4. **編集永続化とSQLiteカタログ**
   - 写真ID、編集値、評価、flag、原本参照を保存し、再起動後に復元
   - 原本と再生成可能cacheを分離し、SSD未接続を削除・破損ではなく復旧可能な状態として扱う
   - DB設定、バックアップ、部分hash、FSEvents、FTS5等は調査提案を候補にするが、採用前にmacOS実装と復旧試験で確認する
5. **選別モードと多解像度cache**
   - 埋め込みJPEGを一覧・fit表示へ使い、ズームや編集時だけRAWへ切り替える仮説を実装・実測
   - 評価、pick/reject、auto-advance、比較、サムネイル優先度制御を追加し、17,000枚で起動・送り・スクロールを測る
6. **非AIの部分補正と整理を完成**
   - ブラシ、部分補正、アルバム、検索、フィルター、バックアップと再リンクUX
7. **将来のLightroom終了に備えた移行確認**
   - 原本、評価、フラグ、アルバム構造、編集値/XMPを何が欠けずに退避できるか確認し、hashと件数付きmanifestを作る
   - 利用中のLightroomエディションと取得できるメタデータ範囲は実データで確認する。現時点では期限付き作業にしない

品質データの拡張と日常機能は並行できる。Metalの未解決だけで製品開発全体を止めない一方、Lightroom相当という最終目標に直結するRAW WB、EV、profile差を後回しにして「機能があるだけ」の完成扱いにもしない。

## 11. 再現方法

```sh
cd /path/to/photoedit
swift test
python3 scripts/test_analyze_calibration.py
python3 -m unittest scripts/test_analyze_white_balance_observation.py
swift run -c release PhotoBenchCalibration .
python3 scripts/analyze-calibration.py . --enforce-canonical-settle
python3 scripts/analyze-calibration.py . --enforce --enforce-preview-parity --enforce-canonical-settle
swift run -c release PhotoBenchWhiteBalanceObservation .
python3 scripts/analyze-white-balance-observation.py . \
  --run .photobench/white-balance-observations/<run-id>/run.json
swift run -c release PhotoBenchBenchmark .
./scripts/build-app.sh
```

厳格モードでは、全合格をexit `0`、eligible runの数値gate不合格をexit `1`、構造・hash・runtime不整合およびineligible / `notEvaluated`をexit `2`とする。現行runではcanonical settle単独は合格してexit `0`、Lightroom品質とpreview parityを含めると不合格でexit `1`になる。上記`swift run -c release PhotoBenchCalibration`は新しい測定を開始するため、その結果は新runの証跡で判断する。

benchmarkの最新v4 formal archiveは1件だけで`3 / 4`合格、warm slider engine proxyだけが不合格だった。ただしWB観測source追加前へ固定され、現行HEADとはfingerprintが異なるため、現行sourceの性能合否ではない。engine proxyをUI応答や安定性として解釈せず、現行sourceの追加runは別IDで全件保存する。

## 12. 文書の読み分け

- `PROJECT_OVERVIEW.md`: 目的、現在地、課題、承認済み方針。この文書
- `README.md`: 起動、現在できること、日常的な検証コマンド
- `DESIGN.md`: UX、データモデル、アーキテクチャ、全ロードマップ
- `CALIBRATION.md`: RAW / Lightroom 画質契約、指標、現在値
- `docs/WHITE_BALANCE_OBSERVATION.md`: RAW WB観測の契約、正式結果、production接続前の条件
- `BENCHMARK.md`: 性能測定の意味、baseline、P1 の詳細
- `RESEARCH.md`: Apple / Adobe / OSS の一次情報と採用判断
- `reviews/2026-07-24-claude-p1-final-review.md`: P1実装後のClaude独立レビューとS1〜S5対応記録
- `reviews/2026-07-24-claude-research-improvement-proposals.md`: 外部調査に基づく方針提案。時限タスクと優先順位の助言として参照し、未検証の技術・製品・ライセンス主張は仕様や合格証跡として扱わない
- `reviews/2026-07-24-claude-metal-direct-review.md`: P1-3 Metal直接表示のClaude実装レビュー、反映内容、実画面blocker、production判断
- `reviews/2026-07-24-claude-raw-wb-design-review.md`: RAW WB観測のClaude設計レビューと採否
- `reviews/2026-07-24-claude-raw-wb-implementation-review.md`: RAW WB観測のClaude実装レビューと反映記録
- `reviews/`: 設計・実装に対する Claude の独立レビュー記録

## 13. 新しいセッションへの引継ぎ手順

1. この文書、`CALIBRATION.md`、`docs/WHITE_BALANCE_OBSERVATION.md`、`BENCHMARK.md`、`DESIGN.md` の順に読む。
2. `.photobench/calibration/report.json`、WB run `51ba2f46-185d-4b87-8345-407d380214cd`の`run.json` / `analysis.json`、`.photobench/benchmark/latest.json`を確認する。benchmark latestは現行HEADとfingerprintが違うarchiveであり、現行性能合否へ読み替えない。
3. `calibration/manifest-v4.json`、`calibration/white-balance-observation-v1.json`と各runのhash、source fingerprint、run IDを照合する。旧v3は`.photobench/calibration-archives/`とcanonical benchmark run `5b2dae18` / `a13033d0` / `c2c4794f`で明示的に参照し、現行採否へ混ぜない。
4. 「Lightroom 相当」を単一の ΔE や処理式で断定せず、画質、操作感、非破壊性、整理、書き出しの不足を分けて評価する。
5. 新しい改善案には、ユーザー価値、非回帰条件、測定方法、失敗時の rollback 境界を含める。
6. source または manifest を変更したら、古い report / benchmark を現行証跡として扱わず、全 suite を再実行する。

未確定事項は `DESIGN.md` の Open questions にある。ただし本プロジェクトの根本目的、ローカル専用、クラウド不要、AI は現段階で不要、Lightroom の実用的代替を目指す、という方針は確定済みであり、再質問せず前提としてよい。
