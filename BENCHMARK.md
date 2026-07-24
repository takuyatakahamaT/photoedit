# Photo Bench 性能基準

更新日: 2026-07-24
状態: manifest v3 / benchmark report schema 3 のsource-locked連続3 formal runsを取得済み。process-fresh、high-quality、exportは3 / 3合格したが、warm sliderは0 / 3のため、性能安定合格とは判定しない。実UIのMetal直接表示も実画面へのpresent完了を確認できていない

日付はJST基準で記載する。機械可読なUTC時刻、測定値、hash、runtime条件は`.photobench/benchmark/latest.json`と`.photobench/benchmark/runs/`を正とする。

## 結論

現行sourceとrelease binaryを固定して、同一コマンドを直列に3回実行した。3 runはすべて`gateEligibility = eligible`で、manifest、入力、source、postflight source、開始・終了binaryが一致し、coordinator / workerを含む全観測でthermal stateは`nominal`、low power modeは無効だった。

それでも4 workloadすべてが3 / 3で合格したわけではない。process-fresh preview、full-resolution JPEG export、warm high-quality previewは3 / 3合格した一方、warm slider engine budgetは0 / 3だった。最新run `f9024302-f48c-4f62-bd84-589013696861`もsliderだけが不合格であり、現段階では**性能安定性未達**と判定する。

3 runは再起動、待機時間の統制、実行順randomizeを行わず、同じshell loopで連続実行した。したがって「独立3反復」とは呼ばず、**連続3 formal runs**と記録する。run間変動、とくに最初のrunのslider / export遅延は大きいが、outlierとして削除せず正式証跡に残す。

また、このbenchmarkが測るdirect 2,560px RAW decodeは、性能構造を調べるための実験engine経路であり、production UIの経路ではない。画質契約v3では、final 2,560pxに対する3,072px / 3,840px oversampled decode候補が両方とも不合格だった。production UIはfull-resolution RAW decodeを維持し、benchmarkの速度だけを根拠にdirect 2,560px経路へ切り替えない。

## 再現性の正本

- 設定・入力・候補・性能閾値: `calibration/manifest-v3.json`
- manifest schema: `3`
- manifest SHA-256: `2867219602b7abe89ddd8994ab243c1a9f1d020eed5710dac4bb1d475eab92a8`
- benchmark report schema: `3`
- benchmark version: `photo-bench-render-benchmark-v3`
- source fingerprint: `f8333be9f764af76b5d7e96d7a2967a44581405fca335fa27b1110f517f14e6b`
- release executable SHA-256: `9b6b1594e948e3f291ea9462d24d6413f868d6b3a89c72c8f3037517cafe3579`
- 実行環境: Mac16,10 / Apple M4 / arm64 / macOS 26.3.1 (`25D771280a`) / Core Image `1592.80.2`
- 入力: manifest既定の6,000×4,000 `P1524180.RW2`
- サンプル: warm-up 5回後の各20回。process-freshは40個のworker process
- 校正suite: 2シーン×3 settings stage、合計122 artifacts
- latest JSON: `.photobench/benchmark/latest.json`
- run archive: `.photobench/benchmark/runs/<run-id>.json`

現行sourceに対応する正式runは次の3件である。

1. `44b4c41e-e18b-4cdd-9720-4c121a365fbd`
2. `9bd69010-e2e7-4a57-ac2c-bd0e3d04e18f`
3. `f9024302-f48c-4f62-bd84-589013696861`（latest）

実行前後でmanifestに記録した7入力と24 sourceのSHA-256を照合する。入力またはsourceが変わったrun、quick run、workerまたはcoordinatorのruntime条件を満たさないrunはgate合格の証拠にしない。実行binary SHA-256、decode intent、decoded / native寸法、scale factor、backendもJSONへ保存する。

以前のformal runはarchiveに履歴として残すが、現行source fingerprintと一致しないため、この3-run判定には混ぜない。

## 連続3 formal runsの結果

単位はすべてp95 wall-clock millisecondsである。

| run | process-fresh preview ≤ 1,000 ms | warm slider engine ≤ 50 ms | warm high-quality preview ≤ 300 ms | full-resolution JPEG export ≤ 3,000 ms |
|---|---:|---:|---:|---:|
| `44b4c41e` | 960.767 合格 | **396.321 不合格** | 131.204 合格 | 1,188.771 合格 |
| `9bd69010` | 369.026 合格 | **59.836 不合格** | 61.835 合格 | 234.513 合格 |
| `f9024302` | 575.269 合格 | **52.754 不合格** | 55.598 合格 | 223.044 合格 |
| pass回数 | 3 / 3 | **0 / 3** | 3 / 3 | 3 / 3 |

3値を母集団として計算した変動は次のとおりである。CVはgateではなく、run間安定性の診断値として使う。

| workload | 3-run平均 | 最小〜最大 | population CV | 判定 |
|---|---:|---:|---:|---|
| process-fresh preview | 635.021 ms | 369.026〜960.767 ms | **38.62%** | 3 / 3合格、変動大 |
| warm slider engine | 169.637 ms | 52.754〜396.321 ms | **94.51%** | 安定不合格 |
| warm high-quality preview | 82.879 ms | 55.598〜131.204 ms | **41.34%** | 3 / 3合格、変動大 |
| full-resolution JPEG export | 548.776 ms | 223.044〜1,188.771 ms | **82.47%** | 3 / 3合格、変動大 |

平均値だけでgateを判定しない。sliderは最良runでも`52.754 ms`で50 ms gateを超え、最初のrunは`396.321 ms`まで悪化した。ほか3 workloadは全runが閾値内だが、いずれもCVが38%を超え、定常性能を十分説明できたとはみなさない。

## System load証跡

report schema 3はtop-levelに12件の`systemLoadObservations`を保存する。

- `run`: start / end
- `preview-warmup`: start / end
- `warm-preview-interleaved`: start / end
- `full-resolution-export-warmup`: start / end
- `full-resolution-export`: start / end
- `process-fresh-preview`: start / end

各snapshotには次を保存する。

- `capturedAtUTC`
- 1 / 5 / 15分のload average
- `load1PerActiveProcessor`
- `thermalState`
- `lowPowerModeEnabled`
- `processCPUTimeSeconds`
- `metalCurrentAllocatedSizeBytes`

さらに40件の`processFreshWorkerSamples`を全件保存し、各workerに`systemLoadStart` / `systemLoadEnd`、`runtimeStart` / `runtimeEnd`、worker binary hash、decode provenance、phase測定、peak resident memoryを残す。つまりtop-level 12 snapshotとは別に、process-fresh worker境界の80 snapshotを保持する。

3 runの`run`境界におけるload / active processorは次のとおりだった。

| run | start → end | thermal / LPM |
|---|---:|---|
| `44b4c41e` | `1.14414 → 1.66948` | 全観測nominal / off |
| `9bd69010` | `1.66948 → 1.06729` | 全観測nominal / off |
| `f9024302` | `1.06729 → 0.83877` | 全観測nominal / off |

coordinatorのpeak resident memoryは順に`754,450,432` / `1,088,110,592` / `1,087,242,240` bytes、各runで最大だったworkerのpeak resident memoryは`876,986,368` / `877,674,496` / `877,445,120` bytesだった。現段階では値を証跡として保存するだけで、direct Metal routeを含む複数写真遷移後の定常RSS上限はまだ受け入れ契約になっていない。

system loadは**診断情報のみ**で、gate threshold、eligibility、p95 sample集合を自動変更しない。外部負荷を理由にsampleやrunを削除せず、同一runの自動retryもしない。再測定が必要な場合は新しいrun IDでarchiveへ追加し、元のrunも残す。

`loadAverage`は実行待ちを含むsystem-wideな指標で、CPU / GPU時間やPhoto Benchへの因果帰属を直接示さない。3 runすべてでprocess-freshは合格した一方、sliderは不合格であり、今回の変動をload / core単独では説明できない。CPU / GPU /同期の帰属には[AppleのMetal performance analysis](https://developer.apple.com/documentation/xcode/analyzing-the-performance-of-your-metal-app/)とInstruments signpost traceを使う。

## 測定経路とproduction境界

benchmarkのpreview workloadは[`CIRAWFilter.scaleFactor`](https://developer.apple.com/documentation/coreimage/cirawfilter/scalefactor)を使い、6,000×4,000 RAWを2,560×1,707へ直接decodeする。applied scale factorは`0.42666668`である。1つの再利用`RenderEngine`がpreview / exportで別instanceのMetal `CIContext`を保持し、現スライスでは双方`cacheIntermediates = false`で測る。

- process-fresh preview: fresh worker / fresh contextで、縮小RAW decode、tone graph、`createCGImage` materializeまで
- warm slider engine: tone-baseへ決定的な露出摂動を与えるengine proxy
- warm high-quality preview: full-current settingsを使うwarm engine preview
- full-resolution JPEG export: full-resolution decodeを維持したquality 0.92 JPEG export

これらはengine API boundaryの測定であり、次は含まない。

- 実UIのslider input-to-present latency
- main-thread schedulingとevent coalescing
- drawable presentationとdropped frame
- 画面上の100% detail表示
- 17,000枚catalogの起動、scroll、thumbnail throughput

したがってwarm sliderの50ms gateは重要なproxyではあるが、単独でLightroom相当UXを証明しない。一方、engine proxyが不安定な段階で実UI合格とみなすこともできない。

### Direct Metal表示の実装状況

`MTKView`と`CIRenderDestination`を使う実UI直接表示経路は実装済みだが、既定経路にはしていない。正確なopt-inは起動時環境変数`PHOTO_BENCH_PREVIEW_ROUTE=metal-direct`であり、未指定・別値では従来の`createCGImage` / `NSImage`経路を使う。direct routeのpreview `CIContext`も`cacheIntermediates = false`である。キャッシュ有効化は有力な次候補だが、写真切替時の回収と複数写真後の定常RSS gateを先に定義してから比較する。

最終ハードニング直前の実アプリsmokeでは、window-levelで可視になった後にdrawを開始し、GPU command completionを2回確認した。しかし1回目は`presentedTime = 0`でdropと判定され、latest requestを再描画した2回目もGPU commandは完了したもののpresented callbackが返らなかった。可視状態の10秒deadline後にdirect routeをその起動中だけ無効化し、従来表示へ一方向fallbackした。その後に`drawableSize > 0`のwatchdog条件と`allowsNextDrawableTimeout = true`を追加し、最終sourceではfallback後の画像表示と空表示がないことを再確認したが、同じ詳細traceは再取得していない。

これは「GPUへの送信が成功した」証拠ではあるが、「実画面へpresentされた」証拠ではない。したがって現時点では次を明確に未達とする。

- `presentedTime > 0`による実画面present完了
- 実UIのslider input-to-present p95
- dropped frame率とstale frame非表示の画面契約
- direct routeを複数写真で使ったときの定常RSS受け入れ値
- occlusion / minimize / callback欠落 / timeout / teardownを網羅するapp lifecycle reducerの自動テスト

native fixtureではdirect / legacyのoffscreen出力が各チャンネル1 LSB以内であることを回帰テストしている。ただしこれはMTKViewのactual presentation、画面capture、拡大縮小を含まないため、実画面画質のformal passではない。

## 画質gateとの関係

manifest v3のpreview parityでは、次の順序を固定した。

1. full-resolution、3,072px、3,840pxの各RAW decode
2. neutral / basic-legacy / full-currentの編集graph
3. 共通Lanczosでfinal 2,560pxへ縮小
4. ΔE、blurred ΔE、EV drift、highlight plateauを比較

3,072px / 3,840px候補は色差・EV関連のgateを通過したが、どちらも`spatiallyDistinctNewSharedPlateauMaximumArea = 0.0001`を超えるscene / stageがあり不合格だった。eligible candidateは空、selected candidateは`null`、fallbackはfull-resolution RAW decodeである。閾値を結果確認後に緩和せず、production UIもfull decodeを維持する。

このため、さらに小さいdirect 2,560px decode benchmarkを「高速かつ採用可能なpreview」と解釈してはならない。現行数値は不採用の実験engine経路を測った診断証跡である。

## 測定方法と限界

process-freshは新しいworker processを使うが、process起動、manifest load / 検証、fixture SHA-256照合、preset parse / validate、runtime provenance取得、settings構築はtimer外である。検証時に対象RAW全体を読み込むため、cold file-openやアプリ起動ではなく、prevalidated / normally page-cache-warmed入力に対するdecode + tone preview測定である。OS cache purgeは行わない。

値は`ContinuousClock`で測ったAPI phaseのwall-clockであり、hardware GPU execution timeそのものではない。Core Image / Metalは遅延評価されるため、GPU実行・同期・CPU readbackの費用が後段の`createCGImage`へ現れることがある。`RenderEngine`はsignpostを出すが、この3 runではInstruments traceを同時取得していない。

反復測定では、[Google Benchmarkのrepetitions / aggregate / warm-upの考え方](https://google.github.io/benchmark/user_guide.html)を参考に、単発の最良値ではなく反復全体とCVを確認する。ただし今回の3 runは外部harnessによる順序randomizeや再起動をしていないため、将来の安定性suiteではrun順、待機条件、system traceを明示して契約を強化する。結果を見た後のoutlier除外で合格を作らない。

## 次の性能改善と受け入れ順

1. **present lifecycleを根治する。** 現状はGPU completionの先でactual presentが成立していない。MTKView / drawable取得、window-level visibility、presented callback、deadlineを同一signpost traceで追い、`presentedTime > 0`を最初の受け入れ条件にする。fallbackが成功したことをdirect表示成功へ読み替えない。
2. **app lifecycleを純粋な状態機械へ抽出して試験する。** visible / occluded / minimized、drop、callback欠落、retry、timeout、teardown、request supersedeを決定的に注入できるreducerにし、stale requestが別requestのpending stateを変更しないことを自動検証する。
3. **実UI input-to-presentを測る。** positive presentが成立してから、input event、latest-only coalescing、render、drawable present、drop frameを同一traceで測る。engine slider benchmarkはMTKView actual presentationを含まないため、p95 ≤ 50msのUI gateを別workloadとして事前登録する。
4. **cacheはboundedに比較する。** 研究提案のpreview-only `cacheIntermediates = true`は有力だが、export contextは分離したまま、写真切替後の`clearCaches` / resource reclaimと複数写真後の定常RSSを同じgateに含める。RSS契約なしで既定化しない。
5. **production full-decode経路の基線を分ける。** 画質不合格のdirect 2,560px実験経路と、現在productionで使うfull-resolution decode経路を別workload IDで測り、性能値の対象を曖昧にしない。必要なら原寸settleと操作中draftの二層契約を新manifestで定義し、既存v3の不合格を上書きしない。
6. **反復安定性の原因を分離する。** 現行sourceを固定し、run順・待機条件・同時負荷を記録した新しい反復suiteを定義する。slider初回`396.321 ms`と後続runの50 ms超過を、CPU scheduling、Metal System Trace、memory / cache状態で分離する。

## 実行方法

単発の正式run:

```sh
swift run -c release PhotoBenchBenchmark /Users/takuyatakahama/Documents/app/NIHO/others/photo
```

今回の連続3 formal runsは上記を同一shellで直列に3回実行した。各runは別run IDでarchiveされる。これを「独立3反復」の代用とはみなさない。

`--enforce`を付けた場合、全gate合格はexit `0`、eligible runの性能不合格はexit `1`、ineligible / `notEvaluated`はexit `2`とする。構造・hash・runtime・provenance不整合、未知のgate status、未知のCLI引数はenforce有無にかかわらずexit `2`である。quick runは診断用として保存できるが、formal gate合格の証拠にはしない。
