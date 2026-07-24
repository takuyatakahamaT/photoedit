# Metal presentation lifecycle — Claude独立レビューと対応記録

- 実施日: 2026-07-24（JST）
- 対象branch: `experiment/metal-presentation-lifecycle`
- レビュー方式: `claude-review` skill / Claude Code Deep Repository Review（Claude Opus 4.7、read-only）
- 対象: `DirectPreviewLifecycle`、SwiftUI / AppKit bridge、Metal callback、deadline、teardown、fallback、診断probe
- 判定: **P0なし。callback競合のP1を修正し、opt-in実験として継続可能。製品既定化はactual UI gate未達のため保留**

## 1. レビューの目的

positive presentationへ到達した実装について、成功ログだけで判断せず、次の境界がcallback順序やSwiftUI lifecycleに依存していないかを独立に確認した。

- GPU完了、presented callback、10秒deadlineが競合しても結果が1回だけ確定するか
- `presentedTime == 0`とGPU errorを取り違えないか
- hidden / miniaturized / resize / window再attachでtimerやobserverが漏れないか
- teardown後のTaskとMetal callbackがstateを再変更しないか
- stale request、payload、renderer cacheが残らないか
- sRGB / SDR、alpha、向き、letterboxの色パス契約が閉じているか

Claudeは、純粋reducer、terminal state guard、latest-only queue、deadline token、teardown、payload解放、一方向fallback、色パスと診断probeの分離を妥当と評価し、P0はないと判定した。一方、単一のone-shot completion claimには、presented callbackが先にclaimを取ると後着のGPU errorを隠す競合があると指摘した。

## 2. 指摘の採否

| 指摘 | Claude重要度 | 採否 | 対応と理由 |
|---|---:|---|---|
| presented callbackがone-shot claimを先取りし、後着GPU errorがdrop扱いに隠れる | P1 | 採用・修正済み | `DirectPreviewSubmissionArbiter`を追加。presentation単独では確定せず、GPU成功とpresentationの両方が揃った時だけ成功／dropをreducerへ渡す。GPU errorは即時終端で常に優先する |
| application active observerがCoordinator生存期間中残る | P1 | 現状維持 | application再活性化時にocclusion publicationを再評価するため必要。Coordinatorごとにobserverとviewを所有し、`tearDown`で全解除する。独立監査でも現時点のblockerではないと確認した |
| weakな旧windowがnilになった状態で`removeObserver(... object:nil)`がワイルドカード解除になり得る | P1 | 採用・修正済み | `if let previousWindow = observedWindow`の時だけ、4通知をそのwindow指定で解除する。nil時は名前単位の全解除をしない |
| `viewDidMoveToWindow`後の16ms再照合Taskが別window attach後にも動く | P1 | 保留 | Taskは同一viewの「現在のwindow」を読み直し、reducerも同一surfaceをno-opにするためstale stateは注入しない。現状の影響は重複評価とログnoiseに限られ、世代tokenは必要性が実測された時に追加する |
| reducerとcompletion ownerがdesyncしたdeadline分岐が黙ってfallbackする | P1 | 採用・修正済み | releaseでも常に`fault` logを残し、debugでは`assertionFailure`する。ユーザー表示はfail closedを維持する |
| resize再presentを製品counterへ別通知しない | P2 | 保留 | 同一requestの二重成功報告を防ぐ現契約を維持。resize UXと正式計測のevent設計時に別counterを検討する |
| rendererがCoordinator単位、counterが単調増加、Coordinator統合試験がない | P2 | 記録・保留 | opt-in一方向fallbackでは直ちに支障なし。route切替UI、長時間診断、公開CIを作るsliceで扱う |

## 3. callback競合の修正契約

修正後のarbiterは`NSLock`で次を線形化する。

1. presented callbackが先着した場合は時刻だけを保存し、GPU終端を待つ。
2. GPU `.completed`が先着した場合は成功だけを保存し、presentationを待つ。
3. GPU成功とpresentationが両方揃った時だけ`.presentation(time)`を1回返す。
4. GPU `.error`はpresentationの有無にかかわらず`.gpuFailure`で即時終端にする。
5. deadlineまたはteardown / invalidationが先に終端化した場合、後着callbackはすべてno-opにする。
6. lock内では観測stateだけを更新し、MainActor reducerへの送信はlock外で行う。

この契約により、`presentedTime == 0`はGPU成功を確認してから既存reducerのdrop / bounded retryへ渡り、GPU errorを最大10秒のdrop retryへ誤分類しない。

## 4. 追加した回帰テスト

`DirectPreviewSubmissionArbiter`について6件を追加した。

- GPU成功とpositive presentationの両callback順序
- GPU成功とzero presentationの両callback順序
- presentation先着／GPU error先着のどちらでもGPU errorが1件だけになること
- deadline勝利後のsuccess / error callback抑止
- invalidation後と解決後のduplicate callback抑止
- presentationとGPU errorの並行実行でGPU failureだけが1件になること

既存のpure lifecycle reducer 24件と合わせ、Metal lifecycle / arbiter境界は30件である。通常実行に加えてThread Sanitizer付きでもこの30件が警告なしで成功した。全体ではSwift Testing `130 tests / 10 suites`、Python analyzer `52 tests`が成功した。

## 5. 実アプリでの修正後確認

修正後に`./scripts/build-app.sh`でrelease appを再生成し、ad-hoc署名を`codesign --verify --deep --strict`で検証した。LaunchServicesから次のopt-in条件で起動した。

```sh
open -n -F -a "$PWD/dist/Photo Bench.app" \
  --env PHOTO_BENCH_PREVIEW_ROUTE=metal-direct \
  --env PHOTO_BENCH_METAL_PRESENTATION_PROBE=production/on-demand \
  --args "$PWD"
```

画面上で実画像が表示され、初期表示は`present 1 / coalesce 0 / drawable nil 0 / drop 1`となった。別のJPEGを選択すると写真と選択状態が更新され、counterは`present 2`へ進んだ。従って、callback arbiter修正後もproduction graphのactual presentationは成立している。

このsmokeはactual-screen pixel parity、反復p95、drop率、rapid supersede時の一過性stale frame、定常RSSを承認するものではない。`metal-direct`は引き続きopt-in、既定は`legacy-bitmap`とする。

## 6. 外部仕様との照合

独立監査でもAppleの契約を照合した。

- [`MTLDrawable.presentedTime`](https://developer.apple.com/documentation/metal/mtldrawable/presentedtime): 0は画面提示が成立しなかった場合を含むため、正値だけをpresentation成功とする
- [`MTLCommandBuffer.addCompletedHandler`](https://developer.apple.com/documentation/metal/mtlcommandbuffer/addcompletedhandler%28_%3A%29): GPU commandの終端観測であり、drawableの画面提示とは別に扱う
- [`MTLCommandBuffer.status`](https://developer.apple.com/documentation/metal/mtlcommandbuffer/status): `.error`をdropへ格下げせずterminal failureとして扱う
- [`MTKView.currentDrawable`](https://developer.apple.com/documentation/metalkit/mtkview/currentdrawable): drawable不在を通常の一時状態としてbounded retryする

Apple資料からpresented handlerとcommand-buffer completed handlerの相互実行順を前提にできる根拠は確認できなかったため、順序非依存arbiterを採用した。これは仕様の空白を都合よく推測せず、どちらの順序でも同じ結果になるようにした防御的設計である。

## 7. 最終判断と残課題

今回のレビューで、GPU errorをdropとして最大10秒遅延させ得る競合は解消した。window observerの将来リスクと内部desyncの観測性も改善し、全自動テストと修正後実アプリsmokeを通過した。よって「Metal直接表示のlifecycle実装を実験branchで継続できない」というblockerはない。

ただし、製品既定化の判断は次を正式に測るまで保留する。

1. actual-screen color / orientation / letterbox parity
2. 代表操作40回以上のinput-to-present p50 / p95
3. fresh launch、写真切替、resize、resume別のdrop率
4. rapid supersede時に古いframeを視認しないUX契約
5. 複数写真切替後のsteady RSSとcache回収
6. 26 source契約に対応する新しいformal calibration / benchmark fingerprint

この短い受入計測の後は、結果にかかわらずLightroom契約中の移行資産保全、編集永続化、SQLiteカタログ、埋め込みJPEG選別へ主軸を移す。
