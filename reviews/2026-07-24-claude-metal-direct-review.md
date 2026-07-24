# P1-3 Metal 直接表示 — Claude 実装レビューと反映記録

- 実施日: 2026-07-24（JST）
- 対象: `/Users/takuyatakahama/Documents/app/NIHO/others/photo`
- レビュー方式: Claude Code Deep Repository Review（Opus、read-only）
- 対象スライス: full-resolution RAW の Core Image graph を `MTKView` / `CIRenderDestination` へ直接描画する opt-in 経路
- 最終 source fingerprint: `f8333be9f764af76b5d7e96d7a2967a44581405fca335fa27b1110f517f14e6b`
- 判定: **実装候補としては hardening 済み。production 既定化は不可**

## 1. レビューの目的

P1-3 の目的は、production が維持している full-resolution RAW decode と同じ編集 graph を使いながら、`createCGImage` → `NSImage` の CPU bitmap materialization / readback を実画面プレビューから外せるかを検証することである。

このレビューでは、単にコンパイルやオフスクリーン画像比較が通るかではなく、次を重点確認した。

- latest-only queue が古い編集を表示しないか
- drawable 不在、drop、occlusion、resize、timeout、teardown で永久 busy や二重完了が起きないか
- Metal 失敗時に写真表示を失わず従来経路へ戻れるか
- direct / legacy の色、向き、letterbox の比較契約が誤って合格しないか
- preview cache と memory 契約が文書と一致しているか
- 「GPU command 完了」と「画面へ実表示」を混同していないか

## 2. 指摘と対応

| 指摘 | 重要度 | 対応 | 現在の状態 |
|---|---|---|---|
| `currentDrawable == nil` 後に次の on-demand draw 契機がなく、永久 busy になり得る | 高 | 可視時だけ 16 / 33 / 67 / 133ms の bounded redraw retry を一つ所有し、pending を維持する | 対応済み |
| queue state の pending claim と view request 取得が分離し、別 ID を in-flight にし得る | 高 | `beginPending(expectedID)` で期待 ID を原子的に claim | 対応済み |
| fallback 開始時に route と request を先に消すため空表示が一瞬出得る | 高 | fallback materialize 完了まで `isBusy` と `hasPreviewInFlight` を維持 | 対応済み |
| native parity test が通常向きと上下反転の小さい方を採用し、反転でも合格し得る | 高 | 通常向きを直接 `<= 1 LSB`、反転版は `> 1 LSB` とする厳格 fixture に変更 | 対応済み |
| preview context が RSS gate 前に `cacheIntermediates = true` となり設計契約に反する | 高 | direct renderer を `false` に戻した。export も `false` を維持 | 対応済み |
| `presentedTime == 0` 2回だけで renderer の恒久障害と判定していた | 高 | 0は drop として数え、latest request を再queue。可視・正サイズ状態の全体10秒 deadlineでだけ一方向fallback | 対応済み |
| hidden / miniaturized 中にも retry / watchdog を消費し得る | 高 | window-level occlusion と最小化解除を監視し、非可視中は retry / deadline を停止 | 対応済み |
| watchdog Task が完了後も残る、または複数所有され得る | 中 | coordinator 所有の一つだけにし、成功・新request・非可視・teardown・fallbackで cancel | 対応済み |
| positive presentation callback と deadline の境界で誤fallbackし得る | 中 | submission completion を lock 保護で一度だけ claimし、watchdogも claim結果を確認 | 対応済み |
| drawable size 0でも可視deadlineが始まり得る | 中 | `drawableSize.width/height > 0` を watchdog 条件へ追加 | 対応済み |
| fallback後の「プレビュー生成」へdirect失敗待ち時間まで加算される | 低 | legacy bitmapを生成したgraph setup + materialize時間だけ表示し、direct失敗時間はsignpost/statusへ保持 | 対応済み |
| drawable取得が待つ可能性を隠していた | 低 | `allowsNextDrawableTimeout = true` を明示。GPU command completionをmain threadで同期waitしない、という限定した契約に整理 | 対応済み |

## 3. 自動検証

最終変更後の結果は次である。

- Swift Testing: `93 tests / 7 suites` 成功
- Python calibration analyzer tests: `52 tests` 成功
- debug / release `PhotoBench` build 成功
- `dist/Photo Bench.app` の ad-hoc 署名と `codesign --verify --deep --strict` 成功
- direct / legacy native raster: 通常向きで最大差 `<= 1 LSB`
- 上下反転版との差: `> 1 LSB`
- aspect-fit、opaque black letterbox、channel / orientation、one in-flight + latest pending、resize / reentrant submit の fixture 成功

ここでの `<= 1 LSB` は、同じ native raster へオフスクリーン materialize した自動fixtureの契約である。実ディスプレイ、ColorSync、drawable presentationまでを比較した証拠ではない。

## 4. 実画面 smoke test と根本blocker

Computer Use で `PHOTO_BENCH_PREVIEW_ROUTE=metal-direct` を明示して実アプリを前面表示し、実写真を開いた。以下は`drawableSize > 0`のwatchdog条件と`allowsNextDrawableTimeout = true`を加える直前の詳細traceである。

観測した状態遷移は次である。

1. window を前面化後、可視・drawable size `850 × 660` で draw開始
2. 1回目の GPU command は `.completed`
3. 1回目の presented handler は `presentedTime == 0` を返し、drop として latest を再queue
4. 2回目の GPU command も `.completed`
5. 2回目は positive presented callback を確認できないまま10秒 deadline到達
6. 同一起動中だけ `legacy-bitmap` へ一方向fallback
7. legacy画像は正常表示され、途中で「写真がありません」へ切り替わる空表示は発生しなかった

その後、上記2点を追加した最終sourceではfallback後のlegacy画像表示と途中の空表示がないことを再確認したが、同じ詳細traceは再取得していない。従って、**Core Image graph のGPU実行成功までは確認したが、drawable が画面へ実際に提示されたことは一度も証明できていない**。`MTLCommandBuffer.status == .completed` は画面提示成功ではなく、production acceptanceには正の `MTLDrawable.presentedTime` が必要である。

現時点で既定 route は `legacy-bitmap` のままとし、direct route は完全一致する環境変数でだけ有効になる。

```sh
PHOTO_BENCH_PREVIEW_ROUTE=metal-direct \
  "dist/Photo Bench.app/Contents/MacOS/PhotoBench" \
  /Users/takuyatakahama/Documents/app/NIHO/others/photo
```

## 5. 未解消・意図的保留

### 5.1 production昇格を止める課題

- 可視状態で `presentedTime > 0` を得られていない
- 実UIの input-to-present p50 / p95 を計測できない
- 実画面の色・向き・letterbox parityを確認していない
- drop rate、resize / occlusion / 写真切替後のsettleを正式測定していない
- direct routeの複数写真遷移後の定常RSSとeviction契約がない
- window-level visibilityしか見ておらず、preview領域そのものの露出状態までは判定できない

### 5.2 自動テストの構造課題

visibility、nil drawable retry、drop、deadline、late callback、teardownはprivateな`ContentView.Coordinator`内にあり、app lifecycleの自動状態遷移テストがない。次にMetalを掘るなら、ID・visibility・drawable availability・presentation outcomeだけを純粋なreducerへ切り出し、fake clockで次を検証する。

- hidden中はdeadlineを消費せず、visible復帰時に再開
- nil drawable反復でもpendingを失わない
- stale callbackがlatest requestを完了させない
- positive presentationとdeadlineが競合してもfallbackしない
- timeout通知はexactly once
- teardown後のretry / callbackは無効

また、古いrequestを`present(_:)`へ登録した後に新requestが到着した場合、その古いdrawableの実提示自体を取り消すことはできない。厳密な「古いフレームを一度も画面へ出さない」契約が必要なら、offscreen textureへ先に描画し、最新ID確認後にdrawableへcopyする二段構成など、別アーキテクチャとして評価する。

## 6. Claudeの外部調査提案との関係

方針レベルの別資料 [`2026-07-24-claude-research-improvement-proposals.md`](2026-07-24-claude-research-improvement-proposals.md) も参照した。そこから次を採用する。

- Lightroom契約中にしか得られない基準出力・プリセット・編集メタデータ・移行データを時限タスクとして最優先で保全する
- previewは将来、操作中draftと停止後settleの別契約として研究する
- 画質・preview研究だけに滞留せず、編集永続化、ローカルcatalog、選別、WB、cropなど解約を阻む製品機能へ進む
- direct Metalの調査はtimeboxし、positive presentationを得られなければ既定legacyを維持して次の製品スライスへ移る

一方、次は未検証仮説として保留する。

- preview contextの`cacheIntermediates = true`がこのgraphで応答を改善し、RSSも許容される
- linear RAW土台がLightroom近似を改善する
- scaled draftが編集判断を誤らせない
- SSIMULACRA2等の知覚指標をPhoto Benchの編集差分へそのまま適用できる
- 制約付きLUTが未知sceneへ一般化する
- 初回遅延の主因がPSO / kernel compileである

Appleや他製品の設計例は候補を選ぶ根拠にはなるが、Photo Benchでの性能・画質・memory合格を代わりに証明しない。各仮説は独立したmanifest、受け入れ条件、rollback境界を用意してから実装する。

## 7. 最終判断

今回のhardeningにより、direct routeが失敗しても写真を失わず、原因別のsignpostを残し、従来表示へ戻れる安全性は高まった。一方、P1-3の本来の成功条件である**正のactual presentationと実UI latency改善は未達**である。

従って次の判断とする。

1. production既定は`legacy-bitmap`を維持する
2. direct routeは診断用opt-inに限定する
3. 追加調査は状態reducer + positive presentationの短いtimeboxに限定する
4. timeboxで成立しなければ、Lightroom契約中の移行資産保全、編集永続化 / SQLite catalog、埋め込みJPEG選別へ進む
5. Lightroomの解約判断は、画質、日常編集、永続化、整理、移行の受け入れ条件が満たされるまで行わない
