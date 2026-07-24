# Photo Bench（仮称）

自分専用のmacOS向けローカル写真現像・整理アプリです。クラウドやAI機能を持たず、最終的にLightroomの有料契約を終了して、ローカルだけで遜色ない実用画質・操作感・非破壊編集へ移行することを目指します。Lightroomは当面継続し、教師出力と退避手段として活用します。現在は**Phase 0の証跡基盤、preview parity、canonical settle v4、原寸decode graphのMetal直接表示プロトタイプ、開発用RAWホワイトバランス観測基盤まで実装した段階**です。現行graphは2つの既知sceneで縮小後clip非回帰を通りましたが、Lightroom品質、製品のRAW WB、縮小RAW preview、日常編集機能は未達であり、**まだ解約できる完成度ではありません**。

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
- 既存delegateのAs Shot出力と、fresh Core Image RAW 8 filterへ設定したcustom Temperature・Tintを、製品未接続の開発用経路で観測。個人RAWと生成artifactをGit管理外に置き、2scene×18候補をhash-lockする
- RGBトーンカーブをencoded-sRGBの1D区分線形曲線で適用し、0〜1外は正の端点傾きで外挿。8色カラーミキサーはOKLChで色相・クロマを補間し、XMP Luminanceを効果量100%の色で`+100 = +1 EV`となる色域別局所露光として扱い、低彩度色を保護する。Adobe HSL Luminanceと同義ではない実験的近似なので、curveとmixerは初期OFF
- RAWとカラー編集途中はextended-linear sRGBを保持し、preview / 指定サイズ時はedge-clamped Lanczosで縮小した後にterminal sRGB transformを適用。既にbounded sRGBで、かつカラー編集がneutralなJPEG等は変換をbypassする
- 原寸sRGB JPEGを書き出し。選択中だけでなく走査済みの全原本、既存のsymlink / hard link、既存フォルダは上書きしない
- 17,000枚を想定し、フォルダ走査を画面外で実行、フィルムストリップを遅延生成
- `PHOTO_BENCH_PREVIEW_ROUTE=metal-direct`の完全一致の起動環境変数を指定した場合だけ、原寸decode graphを`CIRenderDestination`からsRGB / SDRの`MTKView`へ直接描画する実験経路を使用。表示に失敗したらその起動中は従来表示へ一方向fallbackする

## 画質校正の現在地

DC-S5の2組の「Lightroom適用前 / `colorful`適用後」16bit TIFFを基準に、RAW直結とLightroom適用前TIFF入力の2経路を測定します。`basic`はXMP HSL／カーブを除く既定経路、`full`は実験的なencoded-sRGB 1DカーブとOKLCh 8バンド・ミキサーまで有効にした経路です。

校正は平均・中央値・p95のCIEDE2000に加え、未ぼかし16bit TIFFのcomplete clip、near-clip、basic/fullで共有したハイライト領域に新たに生じるplateau、linear-sRGB輝度の平均EV driftをfail-closedで判定します。C1 shoulder修正後の最終結果は次のとおりです。

| シーン / 経路 | 平均 ΔE basic → full | 平均 EV差 basic → full | 新規共有 plateau |
|---|---:|---:|---:|
| P1524180 / RAW | 7.5927 → 6.7963 | +0.00384 → +0.20787 | 0.000357 |
| P1524180 / LR-input | 5.5557 → 4.8355 | -0.12577 → +0.02634 | 0.000371 |
| P1522877 / RAW | 5.8595 → 3.3423 | -0.18014 → +0.00710 | 0.000073 |
| P1522877 / LR-input | 5.4686 → 3.4174 | -0.26830 → -0.08392 | 0.000177 |

4経路すべてで平均ΔE、complete / near clip、新規共有plateauの条件を通過しました。唯一の不合格はP1524180 / RAWの平均EV差で、許容上限`0.05384 EV`に対して`+0.20787 EV`です。目視でも同sceneはLightroom-afterより明るく、暖色・マゼンタと青の彩度が強く見えます。そのため総合品質は不合格で、実験的XMP HSL／curveは既定OFFのままです。正確な定義と判定は[CALIBRATION.md](./CALIBRATION.md)と`.photobench/calibration/report.json`を正とします。

manifest v4ではproduction graphを **extended-linear-sRGB edits → edge-clamped Lanczos downsample → terminal sRGB transform** に固定しました。canonical settleは2 development sceneともcomplete clip `0 → 0`、near clip `0 → 0`で、新規共有plateauも`0.00003593 / 0.00009840`と上限`0.0005`以内でした。旧v3 archiveでは同じ2sceneでcomplete clipが`2,972 → 4,013`、`13 → 1,500`へ増えていたため、旧失敗を消さず改善証拠と対にして保存しています。これは2sceneの縮小後安全性だけを示し、Lightroom一致や未知sceneへの一般化ではありません。

preview parityは、原寸・3,072px・3,840pxの各RAW decodeへ同じ編集を適用し、最終2,560pxへ揃えて2シーン×3編集段階で判定します。

| RAW decode候補 | 最大平均ΔE00 | 最大ぼかし後p95 | 最大絶対EV | 最大plateau純増 | 最大1px許容外面積 | 不合格比較 | 採否 |
|---:|---:|---:|---:|---:|---:|---:|---|
| 3,072px | 0.48847 | 1.57485 | 0.00549 | 0.00005492 | 0.00012105 | 2 / 6 | 不採用 |
| 3,840px | 0.41677 | 1.25678 | 0.00425 | 0.00009954 | 0.00021282 | 4 / 6 | 不採用 |

全6件の失敗理由は上限`0.0001`の1px dilation外にあるspatial plateauだけです。正式結果を見た後に閾値は緩めず、選択候補なし・full-resolution RAW decodeへのfallbackとしています。

## RAWホワイトバランスの現在地

製品へ接続する前に、As Shotは既存production decoder delegateへ委ねたまま、custom Temperature / Tintだけをfresh Core Image RAW 8 filterで観測する独立suiteを追加しました。正式run `51ba2f46-185d-4b87-8345-407d380214cd`は、2 development scene、各18候補、40 / 40 artifactの構造・hash・metadata検証に合格しました。custom中心点のsetter順序は両sceneでbyte exactでした。

ただし採用状態は`exploratory-observation-only`、`productionAdoptionAllowed = false`です。Lightroom側のTemperature / Tint教師sweep、灰色基準と領域別評価、5〜10以上のdevelopment scene、最低2 sealed holdoutがないため、候補の順位やAdobe→Apple変換は決めていません。製品のpreview / export / persistence / Undoにも未接続です。正確な結果と次の受け入れ条件は[RAWホワイトバランス観測記録](./docs/WHITE_BALANCE_OBSERVATION.md)を参照してください。

## 性能基準の現在地

manifest v4の最新正式benchmark archive `bbb5bc5b-7c12-4b29-b803-c863d6059d55`はeligibleで、4 workload中3件が合格しました。ただしWB観測source追加前のmanifest / sourceへ固定され、現行HEADとはfingerprintが異なります。production render graphの変更を示す差ではありませんが、現行sourceのformal性能合否としては未評価です。

| engine workload | p95 | gate | 判定 |
|---|---:|---:|---|
| process-fresh tone preview | 357.9902 ms | ≤ 1,000 ms | 合格 |
| warm exposure-perturbation proxy | 55.6492 ms | ≤ 50 ms | 不合格 |
| warm full-current preview | 58.0227 ms | ≤ 300 ms | 合格 |
| 原寸JPEG quality 0.92 | 225.9223 ms | ≤ 3,000 ms | 合格 |

slider proxyだけが50ms gateを超えました。これは1回のengine runで、安定性や実UIのinput-to-screen latencyを証明しません。canonical v3の連続3 runは履歴として残しますが、v4の合否へ継承しません。詳しくは[BENCHMARK.md](./BENCHMARK.md)を参照してください。

process-freshは新しいworker processですが、timer前のmanifest検証がRAW全体をSHA-256読込するため、cold file-openではなくprevalidated / page-cache-warmed入力です。また現行値はengine wall-clockで、実UIのinput-to-screen latency、drop frame、hardware GPU timeではありません。定義、全分布、未計測項目、次の改善順は[BENCHMARK.md](./BENCHMARK.md)を正とします。

## Metal直接表示の現在地

原寸decode graphのCPU bitmap round-tripを外すための`MTKView` / `CIRenderDestination`経路は実装済みです。表示はsRGB / SDR、pixel formatは`.bgra8Unorm`、黒レターボックス付きaspect fitとし、1件のin-flightと最新pendingだけを保持します。expected request IDの原子的claim、window-levelの可視性判定、上限付き再描画、可視状態の10秒deadline、signpost / counter、その起動中の一方向fallbackを持ちます。previewの`cacheIntermediates`は、RSS上限と回収契約がない現段階では`false`です。

自動テストでは直接経路と従来経路のnative raster差が全channel 1 LSB以内であることと、aspect fit、queueの順序・不正ID拒否を確認しました。最終ハードニング直前の実アプリsmokeでは、可視状態のdraw後にGPU commandが2回`completed`になった一方、1回目は`presentedTime == 0`でdrop、2回目は提示callbackが返らず、10秒deadlineで従来表示へfallbackしました。その後に`drawableSize > 0`のwatchdog条件と`allowsNextDrawableTimeout = true`を追加し、最終sourceではfallback後の写真表示と空表示がないことを再確認しましたが、同じ詳細traceは再取得していません。**正の`presentedTime`、実画面の1 LSB parity、input-to-screen p95、drop率、定常RSSは未確立**です。古いdrawableのpresent登録後により新しいrequestが来た場合の完全なstale-present防止と、可視性・drop・timeout・teardownのapp lifecycle分岐の自動テストも残っています。

## 重要な制限

- Adobe Color、Adobe PV2012の非公開数式、camera profile / DCP、レンズプロファイルは再現していません。
- WBはXMPのモード・絶対値・増分値・明示的な0を区別して解析・保持し、開発用のRAW観測経路もありますが、製品のpreview / export / persistenceへは未接続です。未知のCamera Raw画像処理項目と埋め込みAdobe Lookは「未対応」として表示します。
- クロップ、ブラシマスク、SQLiteカタログ、評価・選別、アルバム、再起動後の編集復元は未実装です。
- DC-S5以外のRAWは読めても機種別の色校正はされません。
- 2つのdevelopment sceneだけで独立holdoutがありません。最終判定には5〜10以上の探索sceneとsealed holdout、各スライダー単独の教師書き出しが必要です。
- 編集永続化、SQLiteカタログ、評価・選別、WBレンダー、クロップがなく、毎日の編集ループは成立しません。
- WB観測は2 development scene、1 camera model、0 holdoutで、Lightroomの固定As Shot参照だけです。構造検証の合格を画質やproduction採用の合格に読み替えません。
- 校正archiveの置換はatomicですがcross-process lockがなく、同じrootの並行校正は禁止です。

## データの扱い

- 読み取り元の写真は変更しません。
- App Sandboxを有効にし、写真はユーザーが選んだフォルダのsecurity-scoped URL経由でだけ読み書きします。初回は自動走査せず、保存した権限が無効なら再選択を求めます。
- NSOpenPanel / NSSavePanelと復元bookmarkのアクセス開始・終了を対応させます。外付けSSDが一時的に外れている場合はbookmarkを削除せず、再接続後に復元できる状態を保ちます。
- JPEGは指定先へ隠し一時ファイルを作り、完成後だけ置き換えます。失敗時は一時ファイルを除去します。
- RAW固有のMakerNote等はレンダリング済みJPEGへコピーしません。
- 現在の開発用ルートはこのフォルダです。完成時はユーザーが選んだ外付けSSD上の写真フォルダを復元できる設計です。

## 検証

```sh
cd /path/to/photoedit
swift test
swift run -c release PhotoBenchCalibration .
python3 scripts/analyze-calibration.py .
python3 scripts/test_analyze_calibration.py
swift run -c release PhotoBenchWhiteBalanceObservation .
python3 scripts/analyze-white-balance-observation.py . \
  --run .photobench/white-balance-observations/<run-id>/run.json
python3 -m unittest scripts/test_analyze_white_balance_observation.py
swift run -c release PhotoBenchBenchmark .
```

現在はSwift Testing **119 tests / 10 suites**、Python calibration analyzer **61 tests**、Python WB observation analyzer **17 tests**が成功しています。旧 / 新graphの識別、edge-clamped Lanczos後のterminal transform、未clamp縮小との境界alpha比較、canonical settleの整数clip count、fresh RAW WB filter、18候補の固定集合、private data / provenance / no-replace契約を検証しています。これは2sceneの生成rasterと観測構造の契約であり、実画面のpresent lifecycle、production WB、holdout品質をテストしたものではありません。

厳格モードでは、全gate合格をexit `0`、eligible runの数値不合格をexit `1`、構造・hash・runtime不整合をexit `2`にします。校正run `1c324af0-7ec3-4c33-bc6f-3bd653794800`はcanonical settleに合格しますが、Lightroom品質とpreview parityが不合格なので、全gate enforceの期待exitは`1`です。WB analyzerは正式runの構造検証に成功してexit `0`ですが、production adoptionは契約上falseです。既存benchmarkもslider gate不合格のためexit `1`です。

```sh
python3 scripts/analyze-calibration.py . \
  --enforce \
  --enforce-preview-parity \
  --enforce-canonical-settle
swift run -c release PhotoBenchBenchmark . --enforce
```

2026-07-23の実UI監査では、`P1524180.RW2`へ`niho-priset_colorful.xmp`を読み込み、`exports/ui-audit-P1524180.jpg`へ6000×4000・sRGB IEC61966-2.1のJPEGを書き出しました。書き出し後もRAWとXMPのSHA-256は事前値と一致し、同じ`.app`の再起動では選択ダイアログなしで10枚を復元しました。

## 文書

- [プロジェクト概要・別セッション向け引継ぎ](./PROJECT_OVERVIEW.md)
- [全体設計](./DESIGN.md)
- [DC-S5 / Lightroom色校正](./CALIBRATION.md)
- [RAWホワイトバランス観測記録](./docs/WHITE_BALANCE_OBSERVATION.md)
- [再現可能な性能基準とP1判断](./BENCHMARK.md)
- [OSS・公式仕様の調査と採用判断](./RESEARCH.md)
- [Claude外部調査に基づく改善提案（方針レベルの参考資料）](./reviews/2026-07-24-claude-research-improvement-proposals.md)
- [RAW WB観測のClaude設計レビューと反映記録](./reviews/2026-07-24-claude-raw-wb-design-review.md)
- [RAW WB観測のClaude実装レビューと反映記録](./reviews/2026-07-24-claude-raw-wb-implementation-review.md)
- [P1-3 Metal直接表示のClaudeレビューと反映記録](./reviews/2026-07-24-claude-metal-direct-review.md)
- [P0証跡基盤とP1方針のClaude最終レビュー](./reviews/2026-07-24-claude-p0-evidence-review.md)
- [P1実装後のClaude最終レビューと対応記録](./reviews/2026-07-24-claude-p1-final-review.md)
- [初期Claude設計レビュー](./reviews/2026-07-23-claude-design-review.md)
- [初期Claude実装レビュー](./reviews/2026-07-23-claude-implementation-review.md)
- [トーン設計Claudeレビュー](./reviews/2026-07-23-claude-tone-design-review.md)
- [トーン実装Claudeレビュー](./reviews/2026-07-23-claude-tone-implementation-review.md)
