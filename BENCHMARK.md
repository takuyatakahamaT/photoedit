# Photo Bench 性能基準

更新日: 2026-07-24（JST）

状態: manifest v4 / benchmark report schema 3のsource-locked formal archiveを1件取得済みで、4 workload中3件が合格し、warm sliderだけが不合格だった。ただしWB観測source追加後の現行HEADとはmanifest SHA / source fingerprintが異なり、現行sourceのformal性能合否は未評価である。実UIのMetal直接表示もactual present完了を正式確認できていない。

機械可読なUTC時刻、全sample、hash、runtime条件は`.photobench/benchmark/latest.json`と`.photobench/benchmark/runs/`を正とする。

## 最新 v4 formal archiveの結論

正式run `bbb5bc5b-7c12-4b29-b803-c863d6059d55`は`gateEligibility = eligible`で、archive内のmanifest、入力、source、postflight source、開始・終了binaryが一致した。

| engine workload | p95 | gate | 判定 |
|---|---:|---:|---|
| process-fresh tone preview | 357.9901622 ms | ≤ 1,000 ms | 合格 |
| warm exposure-perturbation proxy | 55.6492479 ms | ≤ 50 ms | **不合格** |
| warm full-current preview | 58.0226753 ms | ≤ 300 ms | 合格 |
| full-resolution JPEG export | 225.92233125 ms | ≤ 3,000 ms | 合格 |

数値上は3 / 4合格だが、1回のformal runは安定性の証明ではない。とくにsliderはengine proxyの時点で50msを超えており、Lightroomと遜色ない操作感を主張できない。速いworkloadについても、反復run、実UI input-to-present、drop frame、定常RSSを確認するまでproduction performance passにはしない。

さらに、このrunはmanifest SHA `87a9ea...`、source fingerprint `1451c62b...`へ固定されている。現行HEADはmanifest SHA `9da1fd...`、calibration source fingerprint `b7d8c57f...`である。production render graphの性能変更を示す差ではないが、provenance契約上は別sourceなので、`bbb5bc5b...`を現行HEADの合否へ読み替えない。

## 再現性の正本

- archive時点の設定・入力・候補・性能閾値: run内でhash-lockされた`calibration/manifest-v4.json`
- manifest schema: `4`
- manifest SHA-256: `87a9ea124bb8425a8efc8ef4fe79748c54b55097bfcfe503e96ef693304bb312`
- benchmark report schema: `3`
- benchmark version: `photo-bench-render-benchmark-v3`
- source fingerprint: `1451c62b42e175814a316c1e7f8ffaaf44d17cd6ae9397ea8edd1e7eb74e3125`
- benchmark release executable SHA-256: `7563d61a41a66dd0a8762acf2374e1aa4aceff5fffb556405eaf619b739dcec0`
- formal run: `bbb5bc5b-7c12-4b29-b803-c863d6059d55`
- 入力: manifest既定の6,000×4,000 `P1524180.RW2`
- サンプル: warm-up後の各20回、process-freshは40 worker process

入力・source・binary、decode intent、decoded / native寸法、scale factor、backend、runtimeをJSONへ保存する。入力またはsourceが変わったrun、quick run、worker / coordinatorのruntime条件を満たさないrunは合格証拠にしない。outlierを結果確認後に削除せず、再測定は別run IDとして元runとともに残す。

## canonical v3 の連続3 formal runs

次はmanifest v3、manifest SHA `2867219602b7abe89ddd8994ab243c1a9f1d020eed5710dac4bb1d475eab92a8`、source fingerprint `c287d40e1fe913c93b7c35c0f8ad560e4f49292829897b1758919dc64e83b7a8`へ固定されたcanonical v3の履歴であり、v4の合否へ継承しない。

1. `5b2dae18-e24d-4709-a381-4fb8d8e54213`
2. `a13033d0-2782-4f50-abd6-76238c3d3340`
3. `c2c4794f-292d-4591-bc04-b0c8afae16cd`

| workload | run 1 | run 2 | run 3 | 合格回数 |
|---|---:|---:|---:|---:|
| process-fresh preview | **1,902.959 ms 不合格** | 620.723 ms 合格 | 338.650 ms 合格 | 2 / 3 |
| warm slider engine | **54.479 ms 不合格** | **52.437 ms 不合格** | 49.089 ms 合格 | 1 / 3 |
| warm high-quality preview | 58.498 ms 合格 | 53.756 ms 合格 | 52.381 ms 合格 | 3 / 3 |
| full-resolution JPEG export | 964.177 ms 合格 | 272.225 ms 合格 | 218.697 ms 合格 | 3 / 3 |

run単位では2 / 4、3 / 4、4 / 4と改善したが、process-freshは2 / 3、sliderは1 / 3しか合格していない。同じshell loopで直列に実行し、再起動、待機条件の統制、順序randomizeを行っていないため「独立3反復」とは呼ばない。この履歴は、最後の速いrunを安定性と読み替えない理由になる。

## 測定経路とproduction境界

preview workloadは[`CIRAWFilter.scaleFactor`](https://developer.apple.com/documentation/coreimage/cirawfilter/scalefactor)を使う2,560px direct RAW decodeの実験engine経路である。

- process-fresh preview: fresh worker / fresh contextでdecode、tone graph、materializeまで
- warm slider engine: tone-baseへの決定的な露出摂動を与えるengine proxy
- warm high-quality preview: `full-current` settingsを使うwarm engine preview
- full-resolution JPEG export: full-resolution decodeを維持したquality 0.92 JPEG export

これらはengine API boundaryのwall-clockであり、次を含まない。

- 実UIのslider input-to-present latency
- main-thread schedulingとevent coalescing
- drawable presentation、drop、stale frame
- 画面上の100% detail表示
- 17,000枚catalogの起動、scroll、thumbnail throughput

preview parity v4では3,072px候補が2 / 6、3,840px候補が4 / 6比較でspatial plateau gateに失敗した。eligible candidateは空、selected candidateは`null`、production fallbackはfull-resolution RAW decodeである。このため、さらに小さいdirect 2,560px benchmarkを「高速かつ採用可能なpreview」と解釈しない。production full-decode経路の速度は別workload IDで測る必要がある。

## System loadと測定限界

schema 3はrun / workload境界とprocess-fresh workerごとに、時刻、1 / 5 / 15分load average、active processorあたり1分load、thermal state、Low Power Mode、process CPU time、Metal確保量を保存する。system loadは診断情報だけで、gate、eligibility、p95 sample集合を自動変更しない。

`loadAverage`はsystem-wideな実行待ちで、CPU / GPU時間やPhoto Benchへの因果帰属を直接示さない。CPU / GPU / 同期の帰属には[AppleのMetal performance analysis](https://developer.apple.com/documentation/xcode/analyzing-the-performance-of-your-metal-app/)とInstruments signpost traceを使う。

process-freshは新worker processだが、manifest load、fixture hash、preset validate、runtime provenance取得はtimer外である。検証でRAWを先に読むため、cold file-openやアプリ起動ではなく、prevalidated / normally page-cache-warmed入力のdecode + tone測定である。Core Image / Metalは遅延評価されるため、GPU実行や同期、CPU readbackの費用が後段materializeへ現れ得る。

反復設計は[Google Benchmarkのrepetition / warm-up指針](https://google.github.io/benchmark/user_guide.html)を参考にするが、この独自runnerのformal contractを正とする。結果を見た後のoutlier除外で合格を作らない。

## Direct Metal表示の境界

`PHOTO_BENCH_PREVIEW_ROUTE=metal-direct`でopt-inする`MTKView` / `CIRenderDestination`経路は実装済みだが、既定は従来表示である。native fixtureではdirect / legacyのoffscreen出力を1 LSB以内で検証している一方、positive `presentedTime`、actual-screen parity、UI p95、drop率、複数写真後の定常RSSは未確立である。GPU command completionやfallback成功をactual presentation成功と読み替えない。

## 次の性能改善と受け入れ順

1. 現行full-resolution decode production経路を、実験2,560px decodeと別workload IDで測る。
2. direct Metalのpresent lifecycleを同一signpost traceで追い、`presentedTime > 0`を確認する。
3. input eventからactual presentまでのUI p95、drop、stale frameを事前登録gateで測る。
4. cache候補は写真切替後の回収と複数写真後の定常RSSを含めて比較する。
5. v4 sourceを固定した複数formal runを、順序・待機・同時負荷を記録して取得する。
6. まず現行HEADに対応するformal runを1件取得し、古いv4 archiveと現行合否を分離する。

## 実行方法

```sh
cd /path/to/photoedit
swift run -c release PhotoBenchBenchmark .
```

`--enforce`では全gate合格をexit `0`、eligible runの性能不合格をexit `1`、ineligible / `notEvaluated`または構造・hash・runtime・provenance不整合をexit `2`とする。既存archive `bbb5bc5b...`はslider不合格でexit `1`相当だが、上記runnerは現行sourceの新runを作るため、その新しいrun IDとfingerprintで別途判定する。
