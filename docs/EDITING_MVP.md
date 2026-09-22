# 日常編集の初版（2026-09-22）

## 今回の合意

オーナーの目的は、Lightroomで作成した4プリセットを登録し、写真へ適用した後に明るさと色味を微調整してJPEGを書き出すこと。まず約3時間を目安に、実際に使って比較できる初版を作る。設計・レビュー・検証はメイン担当、production実装はオーナー指定のLuna / max 1体が担当する。

NIHO Desktopへの統合は次段階。写真管理全般、アルバム、検索、クロップ、マスクは今回の完成条件に含めない。

## 初版の完成条件

1. colorful / bluesky2 / night / pastelを初期登録し、名前から選んで適用できる。追加XMPはアプリの保存領域へ取り込み、元XMPを移動しても使える。
2. 露出・基本階調・彩度に加え、色温度と緑／マゼンタ方向を微調整できる。プレビューとJPEG書き出しは同じ編集設定を使用する。
3. 写真ごとの編集と適用プリセットを自動保存し、再起動後に復元する。原本は書き換えない。読み込み不能・新しいschema・破損した保存データを無言で上書きしない。
4. プリセット適用、リセット、スライダー操作を取り消し／やり直しできる。ドラッグ中の多数の値更新を1操作へまとめる。
5. プリセットごとの比較画像と未対応項目を提示し、色の実用性をオーナーが確認できる。

## 色調整の境界

既存のRAW WB観測はAdobeのTemperature / TintとCore Imageの同名値の互換を証明していない。初版の手動微調整は撮影時WBによるdecode後の相対的な補正として設計し、Adobeの絶対Kelvin値と同じであるとは表示しない。両者の設定を別fieldに保持する。未校正のRAW WB変換を製品へ黙って昇格しない。

HSL・カーブは従来どおり比較対象にするが、過去の品質ゲートを下げたり、過去の失敗を成功に書き換えたりしない。プリセットを登録できたことと、そのプリセットのLightroom再現性の合格を別々に記録する。

## 保存・操作設計

- 保存先: sandboxに対応するApplication Support / PhotoBench。個人写真の横にアプリ固有データを書かない。
- 写真ごとにバージョン付きJSONをatomic保存。既存の標準化した写真URLと保存内部IDを照合する。
- プリセットは元XMP内容と適用snapshotを保存する。登録の削除で既存写真の編集を失わせない。
- 約400ms間隔にまとめる保存予約と、操作確定・写真切替・終了時の同期flushを組み合わせる。保存失敗は写真URL付きで保持し、別フォルダへ切り替えても再試行できる。終了直前にも再試行し、失敗が残る場合だけ未保存枚数と終了中止を提示する。
- Undo / Redoは写真ごとのセッション履歴。最大100操作程度。再起動後は編集結果を復元し、履歴の永続化は初版に含めない。
- 通常の起動は既存アプリを再利用する。Launch Services経由の多重起動を抑止し、同じ編集ファイルに複数の製品プロセスが書く状況を避ける。

## 比較資料

既存の校正資料は2026-07-24時点の2 development scene / colorfulが中心で、独立holdoutはない。新しい比較は過去のformal runを上書きせず、`.photobench/editing-mvp-20260922/`と`exports/editing-mvp-20260922/`に保存する。

Lightroomでの操作には原本のコピーを使う。生成した参照写真・書き出し・レポートはprivate localのままとし、Gitには含めない。今回の参考比較を、カメラ全般や未知の写真に対する校正合格と扱わない。

## 検証

- 保存と復元、2枚の分離、破損データ保護、重複プリセット、削除後の編集保持、Undo / Redoを一時フォルダを使って確認する。
- 色調整のゼロ設定で従来出力を保持し、正負の調整方向・有限値・設定の往復保存を確認する。
- 新しいアプリをビルドし、実UIでプリセット選択、調整、取り消し、写真切替、再起動後の復元、JPEG書き出しを確認する。
- 同じ原本・プリセットのLightroom出力とPhoto Bench出力を並べ、対応できた部分と残る差を記録する。

## 作業記録

- 2026-09-22: 既存branch `feature/raw-white-balance-observation`、HEAD `6dd2ba7`、作業開始時git cleanを確認。資料・実装・4 XMPを調査し、上記の初版仕様を確定。
- 2026-09-22: Luna / maxへ保存・プリセット・UndoのPhase Aを委任。メイン担当は色調整設計とLightroomの比較資料を準備。
- 2026-09-22: Phase Aの実装、AppSupport対象16テスト、debug build、起動script構文、Info.plist、差分の空白検査が成功。終了時flushをTask経由から同期delegateへ変更し、フォルダをまたぐ未保存データの保持をレビューで追加。
- 2026-09-22: Lightroom 9.3のLocalモードで原本のコピーへ4プリセットを適用。P1524180.RW2 / DSC02072.JPGの2scene×4で、6000×4000・sRGB・JPEG品質100・出力シャープなしの参照8枚を作成。現在のLightroomで書かれたCamera Rawは18.3 / Process Version 15.4。旧16bit TIFFによるformal gateとは別の参考資料として扱う。
- 2026-09-22: 相対色温度・色かぶりを実装し、設定の保存・復元・Undo・JPEGへ接続。ゼロ設定では今回のRAW / JPEG × 4プリセット × basic / colorの16出力が、追加前のJPEGとSHA-256で完全一致した。
- 2026-09-22: Photo Bench 0.2.0（build 2）をrelease buildし、署名検証に成功。旧アプリはprivate作業フォルダへ保存。メイン担当が終了処理・保存失敗・ドラッグ履歴をレビューし、Luna / maxが修正した。
- 2026-09-22: 実UIでRAW / JPEGのプリセット適用、4微調整、Cmd-Z / Shift-Cmd-Z、ドラッグを1回で戻す操作、写真ごとの分離、終了・再起動後の編集復元、原寸JPEG書き出しを確認。6000×4000・sRGBの出力2枚が成功した。
- 2026-09-22: 検証用RAWコピーだけに保存失敗を発生させ、未保存枚数、終了中止、フォルダ変更後も保留編集を保持する動作を確認。復旧後の再試行でUI通知が残る不具合を修正し、保存データと画面表示の両方が復旧することを再確認。障害用の一時ファイルは復元済み。
- 2026-09-22: 実UIでcolorfulのXMPを再登録し、適用されることとライブラリが4件のまま重複しないことを確認。写真原本2枚とUI検証コピー2枚は作業前後でSHA-256一致。

## 今回の確認結果

| 項目 | 結果 |
|---|---|
| AppSupport / 相対色調整の対象テスト | 最終sourceで20 / 20成功 |
| Swift全体 | 129件中121成功、8件は過去の校正manifestの実行OS不一致 |
| 過去manifestの固定OS | macOS 26.3.1 / 25D771280a |
| 今回の実行OS | macOS 27.0 / 26A428 |
| 製品release build / codesign検証 | 成功 |
| 通常操作・再起動・保存失敗復旧 | 実UIで上記の範囲を確認 |
| Lightroomとの色の実用性 | 比較資料を作成。オーナーの目視受け入れは未完了 |

OS固定の8件を通すためのmanifest書換え、過去の校正結果の上書き、画質閾値の緩和は行っていない。今回の実用比較から過去のformal品質・性能ゲートに合格したとは扱わない。

## 色の比較と残る作業

比較ページは`exports/editing-mvp-20260922/comparison.html`。Lightroom参照8枚、Photo Benchのbasic / HSL・カーブあり16枚、手動4項目を使った調整例16枚を同じ原本で比較できる。ページのローカルURLはブラウザ操作ツールの制限で自動表示できなかったため、HTMLのブラウザ確認は未実施。静止画の比較は作成・目視済み。

- `raw-manual-comparison.jpg` / `jpeg-manual-comparison.jpg`: 左からLightroom、basic適用のみ、basicへ微調整を加えた例。
- `full-color-adjusted-comparison.jpg`: RAWとJPEGについて、LightroomとHSL・カーブ＋微調整の比較。

「微調整あり」は各写真・プリセットごとに、露出・相対色温度・色かぶり・彩度だけを合わせた例である。この設定を共通プリセットとして製品に埋め込んでいない。同じ写真に対して最適化した結果なので、別の写真での再現性を証明しない。

colorful / bluesky2 / pastelは微調整で色かぶりを減らせる一方、階調・彩度・ハイライトに差が残る。nightは特にRAWで差が大きく、今回の相対温度の上限に達しても照明部分と肌の色を同時には揃えられなかった。AdobeのWB・camera profile・grading等の差を、4スライダーだけで完全には吸収できない。

したがって日常編集の初版は試用可能だが、「4プリセットの色が普段使いとして納得できる」という完了条件は保留。オーナーには比較の許容可否を確認依頼済み。厳密さを上げる場合は、優先プリセットと気になる色の差を決め、別照明・別写真でも改善する処理へ絞って次の設計を行う。

詳細な出力・調整値・hash・テストログは`.photobench/editing-mvp-20260922/`および`.photobench/tests/editing-mvp-*.log`に保持する。個人写真と生成資料はGit管理外のまま。

## 実装仕様の参照

- 相対色補正: Appleの[CITemperatureAndTint](https://developer.apple.com/documentation/coreimage/citemperatureandtint)のsource / target white pointを使用。ローカルの線形グレー画像で正負の色変化を確認したうえで、温度を`6500 + 30 × relativeTemperature`、tintを`0.5 × relativeTint`、targetを`6500 / 0`とする。Adobeの絶対WB値からの変換式ではない。
- 多重起動: Appleの[Launch Services Keys](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/LaunchServicesKeys.html)に従い`LSMultipleInstancesProhibited`を設定。CLIバイナリを直接複数起動する開発運用を保証するものではない。
