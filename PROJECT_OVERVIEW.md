# Photo Bench プロジェクト概要

- 状態: Phase 0 の証跡基盤、P1 preview parity v3 の正式評価、P1-3 の Metal 直接表示実験まで完了。縮小 RAW 候補は不採用、直接表示は実画面への到達を確認できず既定 OFF のため、製品経路は full-resolution RAW decode + 従来表示を維持
- 対象: オーナー個人専用の Apple Silicon macOS アプリ
- 最終更新: 2026-07-24（JST）
- 開発ルート: `/Users/takuyatakahama/Documents/app/NIHO/others/photo`

## 0. この文書の役割

この文書は、新しい開発セッションや第三者レビューが最初に読むプロジェクト入口である。製品の目的、完成像、これまでの判断、現在の到達点、未達課題、承認済みの次の方針を一続きで示す。

詳細仕様はリンク先の文書を正とし、実測値や合否に食い違いがある場合は、hash 検証済みの次の JSON を最優先する。

- 画質と再現性: `.photobench/calibration/report.json`、`.photobench/calibration/run-manifest.json`
- 性能: 最新 run は`.photobench/benchmark/latest.json`、連続3 runの安定性は`BENCHMARK.md`と`.photobench/benchmark/runs/44b4c41e-e18b-4cdd-9720-4c121a365fbd.json`、`9bd69010-e2e7-4a57-ac2c-bd0e3d04e18f.json`、`f9024302-f48c-4f62-bd84-589013696861.json`
- 入力、処理、閾値の現行契約: `calibration/manifest-v3.json`。manifest schema は 3、校正 run manifest schema は 2、派生する analyzer report schema は 4 と区別する

`reviews/2026-07-24-claude-research-improvement-proposals.md` は、外部調査から得た次の仮説と優先順位案をまとめた助言資料である。ここにある数値、ライセンス解釈、製品比較、技術効果は未確認のものを含み、現行仕様や合格証跡ではない。本書では、目的と時限性に照らして妥当な「Lightroom 契約中にしか取得できない資産を先に確保する」「Metal 実験を timebox し、編集永続化・カタログ・選別へ移る」という優先順位だけを採用し、個別仮説は新しい契約と実測で検証してから採否を決める。

## 1. なぜ作るのか

オーナーは Lightroom を主にローカル写真の画像編集に使っている。クラウド保存、複数端末同期、共有、生成 AI などは現在必要としていない。そのため Lightroom の有料契約をやめ、日常の写真選別・現像・書き出しを、自作のローカル専用アプリへ移行することが本プロジェクトの目的である。

完成像は「Lightroom の画面を複製した小さなアプリ」ではない。自分が実際に使う編集ワークフローに範囲を絞りながら、次を同時に満たす Lightroom 代替を目指す。

- 元画像を壊さない、やり直せる非破壊編集
- RAW と JPEG の両方で、仕事や作品用途に耐える色・階調・解像感
- スライダー操作へ連続して追従する快適なプレビュー
- 17,000 枚規模でも選別、検索、整理、書き出しを待たせないローカル UX
- ネット接続、クラウド、アカウント、サブスクリプションに依存しない運用
- ブラックボックスな「なんとなく近い」補正ではなく、再現可能な画質・性能測定に基づく改善

「Lightroom と遜色ない」は、Adobe Camera Raw の非公開処理をピクセル単位で複製する意味ではない。オーナーが使う写真と編集操作について、見た目、操作感、非破壊性、整理、書き出しまでを含む実用上の完成度で置き換えられることを意味する。Lightroom 解約の最終判断は、代表画像を用いた目視受け入れと自動ゲートの両方を満たした後に行う。

Lightroom は移行期間中の比較基準と退避手段としてだけ用いる。完成後の常用併存は目標にせず、代表ワークフローの受け入れが済んだ時点で契約を終了できる状態を完成条件とする。

**現時点では Lightroom を解約できる状態ではない。** 画質gate、実画面preview、編集永続化、カタログ・選別、移行データ退避が未達であり、先に契約中限定の基準・移行資産を確保する必要がある。

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
- 写真置き場: 完成時は `hihirohub` の `/Volumes/hihirohub/pictures/edit` 相当
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

現在の RAW 処理は概ね次の流れである。

```text
Core Image RAW 8
  → DC-S5 限定 RAW profile（boost 0.9 / EDR 1）
  → extended-linear sRGB
  → 基本階調
  → 任意の encoded-sRGB tone curve
  → 任意の OKLCh 8 band color mixer
  → vibrance / saturation
  → highlight shoulder
  → L / h 固定の gamut compression
  → sRGB preview / export
```

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

- 入力、処理 fingerprint、source、binary、環境、全 artifact を hash-lock する manifest v3 契約を作成
- Lightroom の適用前 / 適用後 16 bit TIFF 2 シーンを RAW と Lightroom-input の 2 経路で比較
- CIEDE2000、EV drift、complete / near clip、新規共有 plateau を自動判定
- preview parity は full-resolution / 3,072 px / 3,840 px RAW decode を同じ編集後に共通 Lanczos で最終 2,560 px へ揃え、平均 ΔE00、ぼかし後 ΔE00 p95、EV、plateau 純面積増加、1 px dilation 外の新規 plateau を独立判定
- path traversal、symlink、case-only alias、artifact 衝突、実行途中の変更を拒否
- release benchmark schema 3 で process-fresh、warm preview、slider proxy、原寸 JPEG と system load を記録し、同一 source / binary の連続 3 正式 run を全件保存
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

## 7. 2026-07-24 時点の到達点

### 7.1 動く機能

- Lumix RW2 と JPEG を同じ画面で開ける
- DC-S5 RW2 を 6000×4000 で decode できる
- 8 基本調整と XMP 近似適用ができる
- 写真ごとの編集状態をアプリ終了まで保持できる
- 6000×4000、sRGB の原寸 JPEG を安全に書き出せる
- 同じ署名のアプリ再起動後、選択済みフォルダを bookmark から復元できる

自動検証は Swift Testing `93 tests / 7 suites`、Python `52 tests` が成功している。native 寸法・image extent の不正値拒否、preview / export context の別 instance 性、manifest v3 の固定寸法と候補行列、Lanczos 共通縮小、plateau morphology、候補なし時の full-decode fallback、system-load snapshot、benchmark の pass / performanceFailed / notEvaluated 契約に加え、direct / legacy の厳格な1 LSB parity、latest-only queue の resize・再入・順序逆転を回帰対象にした。配布形の `dist/Photo Bench.app` も release build と ad-hoc 署名を完了し、`codesign --verify --deep --strict`を通過している。ただし、ウィンドウ可視性、drawable drop、watchdog timeout、teardown といった app lifecycle 分岐は coordinator 内部にあり、自動化できていない。

### 7.2 画質の現在値

2 シーン × 2 経路のうち 3 経路が全ゲート合格、1 経路が EV のみ不合格で、formal report の quality 判定は **不合格** である。

| シーン / 経路 | 平均 ΔE basic → full | 平均 EV basic → full | 新規共有 plateau | 判定 |
|---|---:|---:|---:|---|
| P1524180 / RAW | 7.592 → 6.796 | +0.00376 → +0.20779 | 0.00036 | EV 不合格 |
| P1524180 / LR-input | 5.556 → 4.835 | -0.12585 → +0.02628 | 0.00037 | 合格 |
| P1522877 / RAW | 5.858 → 3.341 | -0.18034 → +0.00697 | 0.00007 | 合格 |
| P1522877 / LR-input | 5.468 → 3.417 | -0.26834 → -0.08396 | 0.00017 | 合格 |

全経路で平均 ΔE、complete / near clip、新規 plateau のゲートは通ったが、P1524180 / RAW の full は EV 絶対誤差上限 `0.05376 EV`に対して `0.20779 EV`である。したがって、安全な出力基盤は得たものの、Lightroom の画作りを再現した、または curve / mixer を本番既定 ON にできるとは判断しない。

P1 preview parity v3 は、この Lightroom 品質ゲートとは独立に、full-resolution、3,072 px、3,840 px の RAW decode をそれぞれ `neutral`、`basic-legacy`、`full-current`で編集し、その後すべてを共通 Lanczos で最終 2,560 px へ縮小して比較した。旧 direct 2,560 px decode の不合格結果は履歴として保持するが、現行の採否は v3 の 12 比較を正とする。

| decode → final | 最大平均 ΔE00 | 最大ぼかし ΔE00 p95 | 最大絶対 EV | 最大 plateau 純増 | 最大 1 px dilation 外面積 | 不合格比較 | 採否 |
|---:|---:|---:|---:|---:|---:|---:|---|
| 3,072 → 2,560 | 0.48950815200805664 | 1.5770659446716309 | 0.0057839141227304935 | 0.000016247437024018745 | 0.00012288554481546573 | 3 / 6 | 不採用 |
| 3,840 → 2,560 | 0.41729527711868286 | 1.256845235824585 | 0.00444698566570878 | 0.00004622510251903925 | 0.0001519478617457528 | 3 / 6 | 不採用 |

閾値は平均 ΔE00 `1.0`、ぼかし後 ΔE00 p95 `2.0`、絶対 EV `0.02`、正の plateau 純面積増加 `0.0001`、参照 plateau を square-3x3 で 1 px 拡張した外側の新規面積 `0.0001`である。両候補とも最初の4ゲートは全比較で通過し、dilation 外面積だけが各3比較で上限を超えた。旧 exact-coordinate set-difference、最大 connected component、worst 128×128 window、距離 histogram は診断値として残したが、正式結果を見た後に閾値を緩めていない。全比較を通る候補がないため formal report の preview parity 判定は **不合格**、`selectedCandidate = null`、fallback は full-resolution RAW decode であり、実 UI もこの経路を維持する。

### 7.3 性能の現在値

Mac16,10 / Apple M4 / macOS 26.3.1 の release build で、24 MP RAW を warm 各 20 回、process-fresh 40 回測定した。現行 source・manifest・release binaryを固定し、同じ shell loop で連続 3 正式 run を直列実行した。再起動等を挟む統計的に独立な反復ではない。測定する 2,560 px `interactive-preview` engine 経路は画質不合格の実験候補で、実 UI の full-resolution decode、`MTKView`提示、入力イベントから画面到達までの latency を表さない。

| workload | run 1 p95 | run 2 p95 | run 3 p95 | gate | pass回数 |
|---|---:|---:|---:|---:|---:|
| process-fresh tone engine preview | 960.767 ms | 369.026 ms | 575.269 ms | ≤ 1,000 ms | 3 / 3 |
| warm exposure-perturbation engine proxy | 396.321 ms | 59.836 ms | 52.754 ms | ≤ 50 ms | 0 / 3 |
| warm full-current-settings engine preview | 131.204 ms | 61.835 ms | 55.598 ms | ≤ 300 ms | 3 / 3 |
| full-resolution JPEG q0.92 | 1188.771 ms | 234.513 ms | 223.044 ms | ≤ 3,000 ms | 3 / 3 |

| workload | 3-run平均 | min–max | 母CV |
|---|---:|---:|---:|
| process-fresh tone engine preview | 635.021 ms | 369.026–960.767 ms | 38.62% |
| warm exposure-perturbation engine proxy | 169.637 ms | 52.754–396.321 ms | 94.51% |
| warm full-current-settings engine preview | 82.879 ms | 55.598–131.204 ms | 41.34% |
| full-resolution JPEG q0.92 | 548.776 ms | 223.044–1188.771 ms | 82.47% |

各 run は `3 / 4`合格で、slider proxy は3 runすべて50ms gateを超えた。schema 3 は run / workload境界と process-fresh workerの system-load snapshotを保持し、loadを理由に sample 削除、outlier除外、再試行をしていない。process-fresh、slider proxy、exportの変動が大きく、この結果を安定した製品性能の証明とは扱わない。とくに direct 経路は positive presentation が未確認なので、UI p95 や actual-screen parity の数値はまだ存在しない。これは単一画像 engine 測定で、17,000 枚運用の保証でもない。

### 7.4 証跡 ID

- calibration run ID: `ceea9eb4-b490-4a1f-9984-3d294e2f50bb`
- archived run manifest: `.photobench/calibration/runs/ceea9eb4-b490-4a1f-9984-3d294e2f50bb.json`
- calibration release binary SHA-256: `11009c7fa63f9a76820238b4ba462734903c381e20b4488ca5a471e60ae51b98`
- benchmark run 1: `44b4c41e-e18b-4cdd-9720-4c121a365fbd`（3 / 4合格）
- benchmark run 2: `9bd69010-e2e7-4a57-ac2c-bd0e3d04e18f`（3 / 4合格）
- benchmark run 3 / latest: `f9024302-f48c-4f62-bd84-589013696861`（3 / 4合格）
- benchmark release binary SHA-256: `9b6b1594e948e3f291ea9462d24d6413f868d6b3a89c72c8f3037517cafe3579`
- manifest v3 SHA-256: `2867219602b7abe89ddd8994ab243c1a9f1d020eed5710dac4bb1d475eab92a8`
- source fingerprint: `f8333be9f764af76b5d7e96d7a2967a44581405fca335fa27b1110f517f14e6b`
- schema: manifest `3` / calibration run `2` / analyzer report `4` / benchmark report `3`
- 検証対象: 7 入力、24 source、122 / 122 artifact の構造・hash検証合格

P1 前 calibration baseline の run ID は `d01a48c3-d87f-414a-adbd-8c944add796c` と記録されているが、run archive は保存されていない。benchmark baseline `d50876f0-9f32-4eed-b6d7-75ea51944ef9` は archive を保存している。現行 source の判断には上記 v3 calibration run と連続3 benchmark runを使い、過去の合格を継承しない。

## 8. 現在の課題

### 8.1 Lightroom 解約をまだ判断できない理由

- 画質校正が開発に使った 2 シーンだけで、独立 holdout がない
- P1524180 / RAW で実験的 full 処理の EV drift が未達
- WB は解析・保持までで、render へ未適用
- Adobe Color / DCP、レンズ補正、ディテール、ノイズ低減は未対応または未校正
- 実 UI の slider input-to-screen latency と drop frame をまだ測っていない
- preview parity v3 で 3,072 / 3,840 px の両候補が各 3 / 6 比較不合格で、実 UI は安全のため full-resolution RAW decode 経路のまま
- Metal 直接表示は GPU command completion までは到達したが、positive `presentedTime`を得られず、actual-screen 表示成功・実画面1 LSB parity・UI p95を確認できていない
- 編集の再起動後復元、SQLite カタログ、評価・選別、検索が未実装
- クロップ、回転、ブラシ部分補正が未実装
- 原寸 JPEG 以外の主要 export 契約が不足
- Lightroom 契約中にしか確保できない可能性がある教師画像、代表A/B比較出力、原本・評価・アルバム・編集メタデータの完全ローカル退避手順が未確定

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

1. **Metal drawable の実提示**: command buffer は completed になるため graph や GPU 実行の単純失敗ではない。初回の `presentedTime = 0` と再試行後の callback 欠落が残り、drawable lifecycle / presentation timing の境界で止まっている。10秒 watchdog と一方向 fallback により利用不能にはならないが、成功条件を満たしていない。
2. **縮小 RAW preview の画質契約**: 3,072 / 3,840 px は平均色差・EV等を通っても、事前登録した spatial plateau gate を各3比較で超えた。結果を見て閾値を変えず不採用にした。別の draft / settle 仮説を試す場合は既存 v3 を変更せず、新契約として扱う。
3. **画質の一般化**: 2シーンだけでは、P1524180のEV失敗が実装欠陥、camera profile差、シーン固有過学習のどれかを十分切り分けられない。Lightroom 契約中のデータ確保を先に行い、その後に独立 holdout 付きで再設計する。
4. **製品ループの未成立**: 編集値が終了時に消え、17,000枚の選別・検索・再リンクができないため、現状は日常利用から改善情報を得られる段階にない。ここは性能研究より解約への寄与が大きい。

このため、Metal は「positive presentation を得るための短い切り分け」と「app lifecycle テスト境界の抽出」までで timebox する。それで閉じなければ既定 OFF のまま保留し、Lightroom 契約資産の退避、編集永続化、SQLiteカタログ、埋め込みJPEGを用いた選別へ優先度を移す。`cacheIntermediates = true`、linear RAW 土台、DCP、SSIMULACRA2、draft / settle 等の外部提案は有望な仮説だが、RSS、ライセンス、知覚相関、画質を未実測のため、現時点では採用済み事実にしない。

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

実装と正式測定は完了した。122 artifact の構造・hash 検証は合格し、両候補とも平均 ΔE00、ぼかし後 ΔE00 p95、絶対 EV、plateau 純面積増加は全比較で合格したが、dilation 外面積が各3比較で不合格だった。`selectedCandidate = null` と失敗証跡を保存し、実 UI は full-resolution RAW decode を維持している。

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

### P1 preview parity v3 の完了結果と次の判断

最終出力 `2,560 px`と RAW decode 寸法 `3,072 / 3,840 px`を分離した v3 実験は、再現可能な artifact、手順、morphology 合成 fixture を manifest v3 へ固定して正式実行済みである。最大値と採否は次のとおり。

| decode → final | 最大平均 ΔE00 | 最大ぼかし ΔE00 p95 | 最大絶対 EV | 最大 plateau 純増 | 最大 1 px dilation 外面積 | 不合格比較 | 採否 |
|---:|---:|---:|---:|---:|---:|---:|---|
| 3,072 → 2,560 | 0.48950815200805664 | 1.5770659446716309 | 0.0057839141227304935 | 0.000016247437024018745 | 0.00012288554481546573 | 3 / 6 | 不採用 |
| 3,840 → 2,560 | 0.41729527711868286 | 1.256845235824585 | 0.00444698566570878 | 0.00004622510251903925 | 0.0001519478617457528 | 3 / 6 | 不採用 |

両候補とも、参照 plateau の固定1 px拡張外にある spatially-distinct new area だけが上限 `0.0001`を超えた。旧 direct 2,560 px decode と exact-coordinate set-difference は履歴・診断値として残すが、現行採否には使わない。正式結果を見た後に閾値を緩めず、`selectedCandidate = null`、fallback は full-resolution RAW decode とする。

この判断を受け、full-resolution decodeを保った Metal直接表示を実装した。offscreen fixtureは1 LSB以内を通ったが、実画面のpositive presentationは未確認で、UI p95も得られていない。次は presentation lifecycleの切り分けを短くtimeboxし、閉じなければ実験経路を既定OFFで保留する。縮小候補、staged render、draft / settle、detail windowを再検討する場合も、既存 v3を書き換えず、独立manifestと事前登録した知覚・settle・メモリ条件を持つ新しい仮説として扱う。

## 10. その後のロードマップ

Lightroom解約から逆算し、次の順へ更新する。

1. **Lightroom契約資産の確保（最優先・時限）**
   - 逆光、肌色、人工照明、高彩度、低照度、ISO違いを含む代表シーンと、各スライダー単独掃引・主要プリセットの16bit基準出力をローカルへ保存
   - 解約後もA/B比較できる代表workflow出力を保存
   - 17,000枚の原本、評価、フラグ、アルバム構造、編集値/XMPを何が欠けずに退避できるか確認し、hashと件数付きの移行manifestを作る
   - 利用中のLightroomエディションと取得できるメタデータ範囲は未確認なので、クラウド版ともClassicとも決めつけず、`.lrcat`の存在を前提にせず実データで検証する
2. **Metal実験の終了条件を確定**
   - positive presentationの取得とapp lifecycle test境界の抽出だけを短いtimeboxで試す
   - 未解決なら `metal-direct`を既定OFFの診断経路として保留し、legacy表示で製品機能を進める。`cacheIntermediates`は定常RSS、上限、evictionを測るまで有効化しない
3. **編集永続化とSQLiteカタログ**
   - 写真ID、編集値、評価、flag、原本参照を保存し、再起動後に復元
   - 原本と再生成可能cacheを分離し、SSD未接続を削除・破損ではなく復旧可能な状態として扱う
   - DB設定、バックアップ、部分hash、FSEvents、FTS5等は調査提案を候補にするが、採用前にmacOS実装と復旧試験で確認する
4. **選別モードと多解像度cache**
   - 埋め込みJPEGを一覧・fit表示へ使い、ズームや編集時だけRAWへ切り替える仮説を実装・実測
   - 評価、pick/reject、auto-advance、比較、サムネイル優先度制御を追加し、17,000枚で起動・送り・スクロールを測る
5. **日常編集の不足を埋める**
   - Undo / Redo、WB render、export preset、クロップ・回転、写真比較
   - その後に非AIブラシ、部分補正、アルバム、検索、フィルター、バックアップと再リンクUX
6. **画質土台の再設計**
   - 手順1で確保した多様な教師シーンと、最初から分離した独立holdoutを使う
   - P1524180 / RAWのEV driftをcurve、mixer、WB、camera profile、baseline exposure候補へ分解
   - linear RAW土台、DCP、制約付きfit、SSIMULACRA2、フリッカー試験は「有望な調査仮説」であり、新manifest、ライセンス確認、感度検証、事前登録した合否条件を通ったものだけ採用

手順1は他作業と並行できるが、契約終了後に取り戻せない可能性があるため先送りしない。手順2は製品開発全体を止めない。まず「編集して閉じても残る」「多数写真を速く選べる」という日常ループを成立させ、その実利用から次の優先度を更新する。

## 11. 再現方法

```sh
cd /Users/takuyatakahama/Documents/app/NIHO/others/photo
swift test
python3 scripts/test_analyze_calibration.py
swift run -c release PhotoBenchCalibration /Users/takuyatakahama/Documents/app/NIHO/others/photo
python3 scripts/analyze-calibration.py /Users/takuyatakahama/Documents/app/NIHO/others/photo --enforce-preview-parity
swift run -c release PhotoBenchBenchmark /Users/takuyatakahama/Documents/app/NIHO/others/photo
./scripts/build-app.sh
```

厳格モードでは、全合格を exit `0`、eligible run の数値 gate 不合格を exit `1`、構造・hash・runtime不整合およびineligible / `notEvaluated`を exit `2`とする。非enforceの正常な診断runは`notEvaluated`でもexit `0`だが、合格証跡には使わない。現校正は Lightroom 品質 1 件と preview parity v3 の 6 / 12 比較が不合格なので、現行 report を厳格評価すると exit `1`である。上記 `swift run -c release PhotoBenchCalibration` は新しい測定を開始するため、その結果の exit code は実行前に断定しない。

benchmark の現行 source 固定連続3正式runは、すべて `3 / 4`合格で、warm slider engine proxyだけが3 runとも不合格だった。これは同じ shell loop 内の直列反復で、統計的に独立な再現性試験ではない。engine proxyをUI応答として解釈せず、3 runとsystem-load診断を全件保存する。

## 12. 文書の読み分け

- `PROJECT_OVERVIEW.md`: 目的、現在地、課題、承認済み方針。この文書
- `README.md`: 起動、現在できること、日常的な検証コマンド
- `DESIGN.md`: UX、データモデル、アーキテクチャ、全ロードマップ
- `CALIBRATION.md`: RAW / Lightroom 画質契約、指標、現在値
- `BENCHMARK.md`: 性能測定の意味、baseline、P1 の詳細
- `RESEARCH.md`: Apple / Adobe / OSS の一次情報と採用判断
- `reviews/2026-07-24-claude-p1-final-review.md`: P1実装後のClaude独立レビューとS1〜S5対応記録
- `reviews/2026-07-24-claude-research-improvement-proposals.md`: 外部調査に基づく方針提案。時限タスクと優先順位の助言として参照し、未検証の技術・製品・ライセンス主張は仕様や合格証跡として扱わない
- `reviews/2026-07-24-claude-metal-direct-review.md`: P1-3 Metal直接表示のClaude実装レビュー、反映内容、実画面blocker、production判断
- `reviews/`: 設計・実装に対する Claude の独立レビュー記録

## 13. 新しいセッションへの引継ぎ手順

1. この文書、`BENCHMARK.md`、`CALIBRATION.md`、`DESIGN.md` の順に読む。
2. `.photobench/calibration/report.json`、`.photobench/benchmark/latest.json`、`BENCHMARK.md`記載の現行3 run archiveを確認し、文書やlatest単体の数値を盲信しない。
3. `calibration/manifest-v3.json` と run manifest の hash、source fingerprint、run ID を照合する。旧 direct 2,560 px decode や P1前を調べる場合だけ過去manifestを明示指定し、現行採否へ混ぜない。
4. 「Lightroom 相当」を単一の ΔE や処理式で断定せず、画質、操作感、非破壊性、整理、書き出しの不足を分けて評価する。
5. 新しい改善案には、ユーザー価値、非回帰条件、測定方法、失敗時の rollback 境界を含める。
6. source または manifest を変更したら、古い report / benchmark を現行証跡として扱わず、全 suite を再実行する。

未確定事項は `DESIGN.md` の Open questions にある。ただし本プロジェクトの根本目的、ローカル専用、クラウド不要、AI は現段階で不要、Lightroom の実用的代替を目指す、という方針は確定済みであり、再質問せず前提としてよい。
