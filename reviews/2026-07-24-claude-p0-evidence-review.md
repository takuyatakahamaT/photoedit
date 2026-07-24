# Photo Bench P0証跡基盤・P1方針 Claude最終レビュー

- 実施日: 2026-07-24（JST）
- reviewer: Claude Opus 4.7 / high effort / deep repository review
- job ID: `paneB-3-photo-p0-20260724-final-claude-review`
- 実行方式: `claude-review` skill、read-only（`Read` / `Grep` / `Glob`のみ）
- 対象: `/Users/takuyatakahama/Documents/app/NIHO/others/photo`

## 結論

Claudeの判定は **READY WITH SHOULD-FIX ITEMS** だった。P0のmanifest / provenance / 校正 / benchmark基盤に、gate bypass、欠測合格、結果の虚偽表示などのconfirmed defectは見つからなかった。既知の2件、P1524180 RAWのEV driftとwarm slider engine budgetは、JSON・CLI・文書のすべてでfail-closedに不合格として扱われている。

したがってP0は引継ぎ可能とする。ただしP1のpreview pipelineを変える前に、previewとexportの画質同等性、cacheのメモリ上限、表示色空間とfallback、新UI経路に対応する測定契約を先に追加する。

## Claudeの主要指摘

### Must fix

なし。

### Should fix

1. 現行`warm-slider-engine-budget`はslider専用経路ではなく、warm full previewと同じproduction APIへ小さな露出摂動を与えるproxyである。
2. process-fresh p95 `940.75 ms`は上限`1,000 ms`まで約`5.9%`しか余裕がなく、20 sampleではtailの推定が不安定である。
3. 現行`sourceFingerprintSHA256`の19 sourceはengine / evidence runnerを固定するが、app UI sourceを含まない。
4. process-fresh timerはprocess起動、manifest / hash検証、preset parse、runtime capture、settings構築を含まず、cold file-openではない。
5. `createCGImage`区間はCore ImageのGPU実行・同期とreadbackをまとめて含むため、「CPU readbackだけが支配」とは断定できない。
6. warm-up 2回は20 sample p95の安定化には少なく、次のbaselineでは5回以上が望ましい。
7. `CIRAWFilter.scaleFactor`導入前に、縮小RAW previewと原寸decode後縮小のΔE / EV / plateau同等gateが必要である。
8. `cacheIntermediates=true`のpreview contextにはメモリ上限、写真切替時eviction、複数写真でのRSS gateが必要である。
9. `MTKView`直接表示にはsRGB / SDRの固定、Metal非対応fallback、現行表示とのpixel parity testが必要である。
10. 新preview pathを導入したら、それ自体を測るworkloadへ性能gateを移し、旧full-res / `createCGImage`値だけで高速化を主張しない。
11. 文書の日付がJST、JSONがUTCであることを明記する。

### Could improve

- coordinator / workerのpeak RSSを分離する。
- cold file-openはgate外の診断workloadとして別測定する。
- benchmark workerごとにthermal stateとlow-power modeを記録する。
- manifestのwarm-up / measured iteration構造下限をgate eligibilityと揃える。
- 実表示寸法を固定`2,560 px`ではなくUIから渡し、sampleごとに記録する。
- context / kernel cacheの並行アクセス規律をP1 actor設計時に再確認する。

## Codexによる照合と採否

### その場で採用した内容

- `BENCHMARK.md`、`DESIGN.md`、`README.md`、`RESEARCH.md`で、`materialize / readback`を「GPU実行・同期・materialize / readbackをまとめたwall-clock区間」へ訂正した。
- process-fresh timerの内外、page-cache-warmed条件、約`5.9%`のpass marginを明記した。
- slider workloadを「小さな設定摂動を与えるwarm preview proxy」と明記し、50ms基準は維持した。
- 現行fingerprintがengine / evidence runnerの範囲で、実UI全体ではないことを明記した。
- JST文書日付とUTC JSON時刻の関係を明記した。
- P1実装前のpreview↔export画質gate、メモリ上限、display contract、fallback、実UI経路benchmarkを設計順へ追加した。

### 次のbenchmark schema更新で採用する内容

- `warmupIterations >= 5`、`measuredIterations >= 20`を構造契約にし、process-fresh baselineを40 workerへ増やす。
- app-side sourceをfingerprintへ追加する。
- workerごとのthermal / low-power provenance、coordinator / worker別peak RSSを記録する。
- 新preview path用`preview-ui-path` workloadを追加し、旧workloadは1 baselineだけ診断用に残す。

### 意図を採用し、具体案を修正した内容

- Claudeは`MTKView.colorPixelFormat = .rgba8Unorm`を例示したが、Apple文書では`MTKView`の標準drawable formatは`.bgra8Unorm`である。実装では対応8-bit unorm、sRGB、SDRを明示し、第一候補を`.bgra8Unorm`としてpixel parity testで確定する。
- Claudeはprocess-freshの狭い余裕を「fail-open risk」と表現したが、実装のexit semanticsはfail-closedである。採用する解釈は「少数sampleによる推定不確かさとfragile pass」であり、構造エラーや不合格を成功へ倒す問題ではない。
- cold cacheを作る具体的方法はOS依存で、ユーザー環境のcacheを完全に制御できない。特定APIを先に固定せず、page-cache-warmed baselineと別の非gate診断として設計する。

## P1開始条件

1. manifestへ`scaled-preview`候補を追加し、現行full-decode-then-scaleとの平均ΔE00 ≤ `1.0`、|平均ΔEV| ≤ `0.02`、新規共有plateau ≤ `0.0001`を暫定gateにする。
2. preview / export intentと、実表示寸法から導く`scaleFactor`を実装する。原寸exportは維持する。
3. preview contextへ[`kCIContextMemoryLimit`](https://developer.apple.com/documentation/coreimage/cicontextoption/memorytarget)を設定し、写真切替時にcacheを解放する。exportは別context instance、cacheなしにする。
4. [`MTKView`](https://developer.apple.com/documentation/metalkit/mtkview) / `CIRenderDestination`をsRGB / SDRで直接表示し、非Metal fallbackと1 LSB以内のparity testを持たせる。
5. 実UI path workloadと[`os_signpost`](https://developer.apple.com/documentation/os/logging/recording_performance_data)を追加し、input-to-screen p95 ≤ `50 ms`、drop frame、写真遷移後の定常RSSを判定する。

## Codex側で別途確認済みの事項

- `swift test`: 68 tests / 6 suites成功
- `python3 scripts/test_analyze_calibration.py`: 28 tests成功
- 校正runner / analyzer: 構造検証成功、画質gateは意図どおり3 / 4合格
- release benchmark: eligible、性能gateは意図どおり3 / 4合格
- `./scripts/build-app.sh`: release app build成功
- `codesign --verify --deep --strict`: 成功
- App Sandbox、user-selected read-write、app-scoped bookmark entitlement: 確認済み

Claudeはread-only reviewだったため、上記のlive testとcodesignはClaude自身の確認範囲外であり、Codexが実行ログと生成物を別途照合した。
