# Metal presentation lifecycle 実機証跡

- 実施日: 2026-07-24 JST
- 対象branch: `experiment/metal-presentation-lifecycle`
- 対象経路: opt-in `metal-direct`
- 判定範囲: presentation成立の原因切り分けとライフサイクルsmoke
- 判定範囲外: 正式な画面画質、反復性能、メモリ、製品既定化

## 1. 目的

原寸RAW decode graphを`CIRenderDestination`から`MTKView`へ直接描画する経路について、GPU commandの完了だけでなく、`CAMetalDrawable`のpresented callbackが正の`presentedTime`を返すところまで成立するかを確認した。

描画内容以外の条件を揃えて失敗段階を分けるため、次のon-demand probeを使用した。

1. `metal-clear/on-demand`: native Metal clearだけをcommit / present
2. `ci-solid/on-demand`: productionと同じCore Image render destinationへ単色を描画
3. `production/on-demand`: 実画像のproduction graphを描画

`metal-clear/continuous`も診断値として実装したが、3つのon-demand経路がすべて成立したため、今回の採否確認では実行していない。probe指定がない場合と不正値の場合は`production/on-demand`へfail closedする。

## 2. 正しい起動条件

presentationの受入確認は、LaunchServicesを通す正規`.app`起動で行う。

```sh
./scripts/build-app.sh

open -n -F -a "$PWD/dist/Photo Bench.app" \
  --env PHOTO_BENCH_PREVIEW_ROUTE=metal-direct \
  --env PHOTO_BENCH_METAL_PRESENTATION_PROBE=production/on-demand \
  --args "$PWD"
```

app bundle内の実行ファイルをshellから直接起動する方法は、通常のforeground activation、window attachment、occlusion publicationという実利用条件を通らない。そのため、buildやログ切り分けには使えてもactual presentationの合否証跡には使わない。

## 3. 実測結果

| probe / 操作 | run ID | 観測結果 |
|---|---|---|
| `metal-clear/on-demand` | `140C10B0-2EFE-453D-BF65-342DC8617608` | 初回callbackは`presentedTime = 0`、bounded retry後にpositive |
| `ci-solid/on-demand` | `A5B53BEC-216F-490B-8B1F-613FE68D3865` | 初回callbackは`presentedTime = 0`、bounded retry後にpositive |
| `production/on-demand` 初期表示 | `DAC965C1…` | 実画像でpositive presentation |
| production操作列 | `1918C69C-0904-49F3-9B84-35D0F216E7B3` | 写真選択、連続露出変更、resize、minimize / resumeでpositive |
| submission arbiter修正後 | UI counter | 実画像の初期表示で`present 1`、別写真選択後に`present 2` |

production操作列では次を確認した。

- 写真選択後の最新requestがpositive
- 露出を連続変更した後のlatest requestがpositive
- previewを`1330 × 854`へresizeした後のcallbackがpositive
- 11.9秒minimize中はsurfaceが不可視となりdeadline fallbackせず、resume後の最新requestがpositive
- 同じrequest IDについてdeadlineとpresent callbackが二重に結果通知しない

複数のfresh launchで、最初のpresented callbackが`presentedTime = 0`となり、16 / 33 / 67 / 133 msのbounded backoffによる再試行でpositiveとなる挙動を観測した。`presentedTime`はOSが返す絶対時刻であり、その数値自体をinput-to-present latencyとして解釈しない。

Claudeレビュー後にGPU完了とpresented callbackを相関するsubmission arbiterを追加し、release appを再ビルド・ad-hoc署名した。LaunchServicesから`production/on-demand`で起動し、画面上の実画像と`present 1 / coalesce 0 / drawable nil 0 / drop 1`を確認した後、別のJPEGを選択して`present 2`へ進むことを再確認した。これはcallback競合修正後の実アプリsmokeであり、従来runの成功を修正後へそのまま転用したものではない。

画面上ではnative clearとCore Image solidの診断色、およびproduction実画像を目視した。ただし、private写真を含むscreenshotや画面収録は公開Gitへ保存していない。

## 4. 実装上の境界

`DirectPreviewLifecycle`は次を純粋reducerとして扱う。

- surface visibilityとdrawable size
- latest-only requestと1件のin-flight
- zero-size / nil drawable待機
- drop後のbounded retry
- 10秒deadline
- stale token / stale callbackの無視
- reducer側のdeadline / callback raceと、submission arbiter側のGPU完了 / presented callback両観測・GPU error優先・exactly-once解決
- hide / resume、resize、payload解放、teardown

AppKit bridgeはapplication active、window key、occlusion、minimize / deminiaturize、viewのwindow attachmentをsurface eventへ変換する。window attachment直後はocclusion状態のpublicationが同一turnで揃わない可能性があるため、即時評価に加えて16 ms後に一度だけ再照合する。

submission arbiterはpresentation通知だけでは確定せず、GPU成功とpresentationの両方が揃った時だけreducerへ渡す。GPU errorはpresentationの有無にかかわらず即時終端とし、deadline / teardownが先に終端化した場合はlate callbackを無視する。これにより、`presentedTime == 0`が先着して後着のGPU errorを隠す競合を防ぐ。

今回のログと修正前後の挙動からは、view attachment時の初期occlusion publication競合が、ユーザー操作までsurface-readyへ進まなかった主因だった可能性が高い。ただしこれは実測に基づく推定であり、Appleが保証する原因として断定しない。

## 5. この証跡が証明しないこと

これはmanual smokeであり、formal calibration / benchmarkや製品既定化の合格証跡ではない。次は未承認である。

- actual-screen pixel / color parity
- 代表操作のinput-to-present p95
- fresh launch、選択、resize、resumeを反復したdrop率の分布
- rapid supersede時にtransient stale frameを目視しない契約
- 複数写真を操作した後のsteady RSSと回収

reducerは古いcallbackが最新stateを破壊することを防ぐ。一方、すでにpresent登録した古いdrawableを後着requestから物理的に取り消すことはできず、「stale frameが一瞬も表示されない」ことまではこのテストで保証しない。

## 6. 現時点の判断

positive presentationとpure lifecycleの自動テスト境界は成立したため、「Metal drawableが実画面へ提示できない」という技術blockerは解消した。残るactual UI acceptanceを短い別sliceで測るまでは、通常起動をlegacy表示、`metal-direct`をopt-in診断経路のまま維持する。
