# Photo Bench（仮称）

自分専用のmacOS向けローカル写真現像・整理アプリです。目的は、クラウドやAI機能を必要としないオーナーがLightroomの有料契約を終了し、ローカルだけで同等の実用画質・操作感・非破壊編集へ移行できることです。現在は**Phase 0の証跡基盤、P1 preview parity v3評価、原寸decode graphのMetal直接表示とpresentation lifecycle検証まで実装した段階**です。縮小RAW decode候補は品質未達で不採用です。Metal直接表示は実画像の正の`presentedTime`まで確認できましたが、正式な実画面parity・p95・定常RSSが未承認なので起動時に明示した場合だけ有効で、既定は従来表示です。JPEGとLumix RW2の読込み、8つの基本調整、XMPプリセット解析、HDR値を保持したカラー処理、原寸JPEG書き出し、Lightroom基準TIFFとの比較までは動きますが、**Lightroomを解約できる完成度にはまだ達していません**。

公開Gitリポジトリにはsource・tests・docs・契約manifestだけを置き、個人写真、Lightroom基準画像、生成render、署名済みappは含めません。詳細は[Repository and local data policy](./DATA_POLICY.md)を参照してください。

このプロジェクトの目的、Lightroomから移行するための完成条件、これまでの取り組み、現在の到達点、残課題、承認済みP1方針は、まず[プロジェクト概要](./PROJECT_OVERVIEW.md)を参照してください。

## 起動

Finderから`open-photo.command`をダブルクリックします。ターミナルからなら次でも起動できます。

```sh
./open-photo.command
```

ビルド済みアプリは`dist/Photo Bench.app`です。`open-photo.command`はソースがアプリより新しければ自動で再ビルドします。初回起動時は「フォルダを開く」から写真ルートを選び、以後はmacOSのsecurity-scoped bookmarkで同じフォルダを復元します。起動直後にDocumentsや外付けSSDを勝手に走査しません。手動ビルドは次で行えます。

```sh
./scripts/build-app.sh
```

既定は個人ローカル利用向けのad-hoc署名です。アプリ本体を再ビルドするとmacOSから写真フォルダの再選択を求められる場合があります。自分のコード署名証明書を用意した場合だけ、`PHOTO_BENCH_CODESIGN_IDENTITY`へそのidentityを指定します。別組織の証明書は流用しません。

## 現在できること

- ユーザーが選んだフォルダ以下にあるJPEG / HEIC / PNG / TIFF / RAWを非同期走査し、選択権限を次回起動へ安全に保存
- Lumix DC-S5の`.RW2`をCore Image RAW 8で6000×4000の原寸デコード。Make/Model一致時だけ`boost=0.9`・Apple default EDRの`extendedDynamicRangeAmount=1`を使う`panasonic-dc-s5-lightroom-9.3-edr1-v2`を選択し、ほかの機種へ流用しない
- 露出、コントラスト、ハイライト、シャドウ、白レベル、黒レベル、自然な彩度、彩度をスライダー調整
- 写真ごとの編集状態を、アプリを閉じるまでメモリ内に保持
- `colorful` / `bluesky2` / `night` / `pastel`のProcess Version 11 XMPを解析
- XMPの属性形式と要素形式を解析し、基本8項目を近似適用。WBはモード・絶対値・増分値・明示的な0を区別して保持
- RGBトーンカーブをencoded-sRGBの1D区分線形曲線で適用し、0〜1外は正の端点傾きで外挿。8色カラーミキサーはOKLChで色相・クロマを補間し、XMP Luminanceを効果量100%の色で`+100 = +1 EV`となる色域別局所露光として扱い、低彩度色を保護する。Adobe HSL Luminanceと同義ではない実験的近似なので、curveとmixerは初期OFF
- RAWとカラー編集途中はextended linear sRGBを保持し、出力直前だけmax-channel highlight shoulderと固定lightness / hueのOKLCh色域圧縮を適用。既にbounded sRGBで、かつカラー編集がneutralなJPEG等はこの変換をbypassする
- 原寸sRGB JPEGを書き出し。選択中だけでなく走査済みの全原本、既存のsymlink / hard link、既存フォルダは上書きしない
- 17,000枚を想定し、フォルダ走査を画面外で実行、フィルムストリップを遅延生成
- `PHOTO_BENCH_PREVIEW_ROUTE=metal-direct`の完全一致の起動環境変数を指定した場合だけ、原寸decode graphを`CIRenderDestination`からsRGB / SDRの`MTKView`へ直接描画する実験経路を使用。表示に失敗したらその起動中は従来表示へ一方向fallbackする

## 画質校正の現在地

DC-S5の2組の「Lightroom適用前 / `colorful`適用後」16bit TIFFを基準に、RAW直結とLightroom適用前TIFF入力の2経路を測定します。`basic`はXMP HSL／カーブを除く既定経路、`full`は実験的なencoded-sRGB 1DカーブとOKLCh 8バンド・ミキサーまで有効にした経路です。

校正は平均・中央値・p95のCIEDE2000に加え、未ぼかし16bit TIFFのcomplete clip、near-clip、basic/fullで共有したハイライト領域に新たに生じるplateau、linear-sRGB輝度の平均EV driftをfail-closedで判定します。C1 shoulder修正後の最終結果は次のとおりです。

| シーン / 経路 | 平均 ΔE basic → full | 平均 EV差 basic → full | 新規共有 plateau |
|---|---:|---:|---:|
| P1524180 / RAW | 7.592 → 6.796 | +0.00376 → +0.20779 | 0.00036 |
| P1524180 / LR-input | 5.556 → 4.835 | -0.12585 → +0.02628 | 0.00037 |
| P1522877 / RAW | 5.858 → 3.341 | -0.18034 → +0.00697 | 0.00007 |
| P1522877 / LR-input | 5.468 → 3.417 | -0.26834 → -0.08396 | 0.00017 |

4経路すべてで平均ΔEゲート、complete / near clip非回帰、新規共有plateau上限`0.0005`を通過しました。唯一の不合格はP1524180 / RAWの平均EV差で、許容上限`0.05376 EV`に対して`+0.20779 EV`です。そのためレポート全体は不合格であり、安全ゲートの大半を通ったことをLightroomの画作りの再現とはみなしません。2シーンだけでは事業品質も承認できないため、実験的XMP HSL／カーブは既定OFFのままです。正確な定義と判定は[CALIBRATION.md](./CALIBRATION.md)および`.photobench/calibration/report.json`を正とします。

P1のmanifest v2では、原寸decode後に2,560pxへ縮小した基準と、直接2,560px decodeした候補を比較し、旧pixelwise plateau指標の過敏さと実際のhighlight ceiling増加を分離できなかったため不採用にしました。この結果は履歴として残し、現行判断にはmanifest v3を使います。

現行v3は、原寸・3,072px・3,840pxの各RAW decodeへ同じ編集を適用し、すべてを共通Lanczosで最終2,560pxへ揃えます。平均ΔE00、ぼかし後ΔE00 p95、絶対EV drift、共有plateau純面積増加、参照plateauをfinal画像上でsquare-3x3に1px拡張した外側の新規plateau面積を、2シーン×3編集段階で事前登録した閾値により判定しました。

| RAW decode候補 | 最大平均ΔE00 | 最大ぼかし後p95 | 最大絶対EV | 最大plateau純増 | 最大1px許容外面積 | 不合格比較 | 採否 |
|---:|---:|---:|---:|---:|---:|---:|---|
| 3,072px | 0.48951 | 1.57707 | 0.00578 | 0.00001625 | 0.00012289 | 3 / 6 | 不採用 |
| 3,840px | 0.41730 | 1.25685 | 0.00445 | 0.00004623 | 0.00015195 | 3 / 6 | 不採用 |

両候補とも色差、EV、plateau純増は全比較で合格し、不合格は上限`0.0001`の1px許容外面積だけでした。正式結果を見た後に閾値は緩めず、選択候補なし・原寸RAW decodeへのfallbackとしています。

## 性能基準の現在地

2026-07-24（JST）にMac16,10 / Apple M4 / macOS 26.3.1で、manifest既定の24MP `P1524180.RW2`をrelease build、warm各20回・process-fresh 40回として、tagged baselineのsourceとbinaryを固定した正式runを直列に3回実行しました。benchmark schema v3はrun・workload・40 workerの開始／終了時にsystem loadも保存しますが、負荷値によるsample削除、再試行、合否の除外は行いません。

| engine workload | run 1 p95 | run 2 p95 | run 3 p95 | gate | 合格回数 |
|---|---:|---:|---:|---:|---:|
| process-fresh tone preview | 960.77 ms | 369.03 ms | 575.27 ms | ≤ 1,000 ms | 3 / 3 |
| warm exposure-perturbation proxy | 396.32 ms | 59.84 ms | 52.75 ms | ≤ 50 ms | 0 / 3 |
| warm full-current preview | 131.20 ms | 61.84 ms | 55.60 ms | ≤ 300 ms | 3 / 3 |
| 原寸JPEG quality 0.92 | 1188.77 ms | 234.51 ms | 223.04 ms | ≤ 3,000 ms | 3 / 3 |

最新runを含めslider proxyは3回すべて不合格で、ほかの3 workloadは3 / 3合格です。ただしこれは画質不採用の直接2,560px実験engine経路であり、実UIの原寸decodeやinput-to-screen latencyではありません。正式run IDは`44b4c41e-e18b-4cdd-9720-4c121a365fbd`、`9bd69010-e2e7-4a57-ac2c-bd0e3d04e18f`、`f9024302-f48c-4f62-bd84-589013696861`、source fingerprintは`f8333be9f764af76b5d7e96d7a2967a44581405fca335fa27b1110f517f14e6b`です。

process-freshは新しいworker processですが、timer前のmanifest検証がRAW全体をSHA-256読込するため、cold file-openではなくprevalidated / page-cache-warmed入力です。また現行値はengine wall-clockで、実UIのinput-to-screen latency、drop frame、hardware GPU timeではありません。この正式証跡は24 sourceのtagged baselineに対応し、26 source契約の現在branchではformal rerunしていません。定義、全分布、未計測項目、次の改善順は[BENCHMARK.md](./BENCHMARK.md)を正とします。

## Metal直接表示の現在地

原寸decode graphのCPU bitmap round-tripを外すための`MTKView` / `CIRenderDestination`経路は実装済みです。表示はsRGB / SDR、pixel formatは`.bgra8Unorm`、黒レターボックス付きaspect fitとし、1件のin-flightと最新pendingだけを保持します。presentation状態を純粋な`DirectPreviewLifecycle` reducerへ分離し、request ID、retry / deadline token、window-level可視性、zero-size / nil drawable、`presentedTime == 0`、GPU error、10秒deadline、hide/show、resize、teardownを決定的に扱います。GPU完了とpresented callbackはlock保護したsubmission arbiterで両方を観測し、GPU errorを優先してcallback順序に依存せず1回だけ確定します。deadlineとteardownも同じarbiterを終端化し、失敗後は同一起動中に従来表示へ一方向fallbackします。previewの`cacheIntermediates`は、RSS上限と回収契約がない現段階では`false`です。

2026-07-24の正規`.app`起動による無操作smokeでは、描画内容だけを段階的に替えた3モードすべてで正の`presentedTime`を取得しました。native Metal clearは`117623.155870`、productionと同じCore Image destinationを使う単色は`117681.371117`、実画像productionは`117709.778156`です。各初回の`presentedTime == 0`は1回dropとして数え、16 / 33 / 67 / 133 ms上限付きbackoffの最初の再試行で回復しました。写真切替、露出の連続変更、`1330×854`へのresize、11.9秒の最小化と復帰でもpositive callbackを確認し、最小化中にdeadline fallbackは発生していません。submission arbiter修正後にも配布形アプリを再ビルドし、実画像の初期表示で`present 1`、別写真への切替後に`present 2`へ進むことを画面上で確認しました。

診断はLaunchServicesを通る実利用相当の起動で行います。実行ファイルを直接起動すると通常のforeground activation / occlusion契約を通らないため、presentation合否には使いません。

```sh
open -n -F -a "$PWD/dist/Photo Bench.app" \
  --env PHOTO_BENCH_PREVIEW_ROUTE=metal-direct \
  --env PHOTO_BENCH_METAL_PRESENTATION_PROBE=production/on-demand \
  --args "$PWD"
```

診断値は`metal-clear/on-demand`、`metal-clear/continuous`、`ci-solid/on-demand`、`production/on-demand`の完全一致だけを受け付け、未指定・不正値はproduction/on-demandへfail closedします。**正のpresentationは成立しましたが、実画面の1 LSB parity、代表操作40回以上のinput-to-screen p95、drop率の正式分布、複数写真後の定常RSSは未確立**です。また、commit済みの古いdrawableは後着の新requestから物理的に取り消せないため、「stale frameを一瞬も提示しない」完全保証は別のUX契約として残ります。したがって現ブランチでも既定経路はlegacyです。

## 重要な制限

- Adobe Color、Adobe PV2012の非公開数式、DCP、レンズプロファイルは再現していません。
- WBはXMPから正確に解析・保持しますが、レンダーへの適用は未実装です。未知のCamera Raw画像処理項目と埋め込みAdobe Lookは「未対応」として表示します。
- クロップ、ブラシマスク、SQLiteカタログ、評価・選別、アルバム、再起動後の編集復元は未実装です。
- DC-S5以外のRAWは読めても機種別の色校正はされません。
- 2シーンではスライダーごとの効果を分離できません。最終判定には5〜10以上の独立シーンと、各スライダー単独の基準書き出しが必要です。
- 編集永続化、SQLiteカタログ、評価・選別、WBレンダー、クロップがなく、毎日の編集ループは成立しません。Lightroom契約中に教師書き出しと移行データを保全することが最優先です。

## データの扱い

- 読み取り元の写真は変更しません。
- App Sandboxを有効にし、写真はユーザーが選んだフォルダのsecurity-scoped URL経由でだけ読み書きします。初回は自動走査せず、保存した権限が無効なら再選択を求めます。
- NSOpenPanel / NSSavePanelと復元bookmarkのアクセス開始・終了を対応させます。外付けSSDが一時的に外れている場合はbookmarkを削除せず、再接続後に復元できる状態を保ちます。
- JPEGは指定先へ隠し一時ファイルを作り、完成後だけ置き換えます。失敗時は一時ファイルを除去します。
- RAW固有のMakerNote等はレンダリング済みJPEGへコピーしません。
- 初回はユーザーが任意の写真ルートを選びます。外付けストレージもsecurity-scoped bookmarkで再接続できる設計です。

## 検証

```sh
export PHOTO_BENCH_ROOT=/path/to/photoedit
swift test
swift run -c release PhotoBenchCalibration "$PHOTO_BENCH_ROOT"
python3 scripts/analyze-calibration.py "$PHOTO_BENCH_ROOT"
python3 scripts/test_analyze_calibration.py
swift run -c release PhotoBenchBenchmark "$PHOTO_BENCH_ROOT"
```

現在の開発ルートではSwift Testing **130 tests / 10 suites**とPython **52 tests**が成功しています。従来のRAW decode intent、原寸export guard、DC-S5 profile、XMP解析、HDR階調・色域、原本不変、hash-locked校正・benchmark契約に加え、Metal直接表示のaspect-fit幾何、latest-only queue、従来表示とのnative raster全channel `<= 1 LSB`、presentation lifecycle reducer 24件、GPU / presented callback arbiter 6件、probe設定4件、診断renderer 3件を検証しています。callback順序、GPU error、deadline、hidden / zero-size、nil drawable retry、resize、stale token / callback、payload解放、teardownはreducerとarbiterで自動化しました。AppKit / WindowServerそのもののactual presentationは上記の実機smokeで別に確認しています。

厳格モードでは、単一run内の全ゲート合格をexit `0`、eligible runの数値ゲート不合格をexit `1`、構造・hash・runtime不整合およびineligible / `notEvaluated`をexit `2`にします。校正run `ceea9eb4-b490-4a1f-9984-3d294e2f50bb`はLightroom品質とpreview parityの両方が不合格で、両方をenforceするanalyzerは意図どおりexit `1`です。benchmark latestもslider gate不合格のためexit `1`です。一方、このengine benchmarkはMetal直接表示の実UI性能を評価していません。

```sh
python3 scripts/analyze-calibration.py "$PHOTO_BENCH_ROOT" --enforce --enforce-preview-parity
swift run -c release PhotoBenchBenchmark "$PHOTO_BENCH_ROOT" --enforce
```

2026-07-23の実UI監査では、`P1524180.RW2`へ`niho-priset_colorful.xmp`を読み込み、`exports/ui-audit-P1524180.jpg`へ6000×4000・sRGB IEC61966-2.1のJPEGを書き出しました。書き出し後もRAWとXMPのSHA-256は事前値と一致し、同じ`.app`の再起動では選択ダイアログなしで10枚を復元しました。

## 文書

- [プロジェクト概要・別セッション向け引継ぎ](./PROJECT_OVERVIEW.md)
- [全体設計](./DESIGN.md)
- [DC-S5 / Lightroom色校正](./CALIBRATION.md)
- [再現可能な性能基準とP1判断](./BENCHMARK.md)
- [OSS・公式仕様の調査と採用判断](./RESEARCH.md)
- [Claude外部調査に基づく改善提案（方針レベルの参考資料）](./reviews/2026-07-24-claude-research-improvement-proposals.md)
- [Metal presentation lifecycleの実機証跡](./reviews/2026-07-24-metal-presentation-lifecycle-evidence.md)
- [Metal presentation lifecycleのClaudeレビューと対応記録](./reviews/2026-07-24-claude-metal-lifecycle-review.md)
- [P1-3 Metal直接表示のClaudeレビューと反映記録](./reviews/2026-07-24-claude-metal-direct-review.md)
- [P0証跡基盤とP1方針のClaude最終レビュー](./reviews/2026-07-24-claude-p0-evidence-review.md)
- [P1実装後のClaude最終レビューと対応記録](./reviews/2026-07-24-claude-p1-final-review.md)
- [初期Claude設計レビュー](./reviews/2026-07-23-claude-design-review.md)
- [初期Claude実装レビュー](./reviews/2026-07-23-claude-implementation-review.md)
- [トーン設計Claudeレビュー](./reviews/2026-07-23-claude-tone-design-review.md)
- [トーン実装Claudeレビュー](./reviews/2026-07-23-claude-tone-implementation-review.md)
