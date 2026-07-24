# Claudeトーン実装レビューと採否

- 実施日: 2026-07-23
- 方式: `claude-review` / Claude Code CLI / Opus 4.7 / read-only / deep repository review
- Fable: 指定モデルを試したが、この環境では`model_not_found`だったためOpusへ切替
- 対象: Phase 0の基本階調、XMP、RAWデコード、書き出し安全性、校正方法、テスト

## 結論

Claudeの判定は **proceed** だった。設計へ戻すblocking issueや、確認できた原本破壊はなく、文書・コード・実測は概ね一致している。ただしこれは「Lightroom代替の画質が完成した」という判定ではない。2シーンだけの色差試験、過大なハイライトclip、未実装のXMP WBレンダーを明示したPhase 0として、次の検証へ安全に進めるという意味である。

レビュー後にこちらでも書き出し境界を再監査し、選択中とは別のライブラリ原本を保存先に指定できる穴を発見した。これはデータ損失につながるため、Claudeの指摘とは別に同じ修正バッチで塞いだ。

## 採用して修正した指摘

| 指摘 | 対応 |
|---|---|
| JPEG書き出し失敗時に一時ファイルが残り得る | JPEGもTIFFと同じ`do/catch`で全失敗経路を掃除する |
| Core Imageレンダー失敗を「未対応画像」と誤表示する | `RenderEngineError.renderFailed`を追加し、デコード失敗と分離する |
| `crs:*`を属性に持つXMPしか解析しない | `rdf:Description`配下のelement形式も解析し、属性と同じ正規化・範囲制限・未知項目判定を行う |
| RAW WB値を読み、そのまま同じ値へ書き戻すno-op | 誤解を招く4行を削除する。XMP WBの実適用は独立スライスのまま維持する |

## 独立監査で追加修正した事項

- 書き出し先を、現在選択中の写真だけでなく**走査済みライブラリ内の全原本**と比較する。別のJPEG、既存hard link、symlinkを保存先に選んでも拒否する。
- 原本同一性は大文字小文字を無視した標準化パス、symlink解決、既存ファイルのresource identifierで判定する。
- 拒否された場合に対象原本のバイトが変わらないことを回帰テストへ追加する。
- macOSの`replaceItemAt`は非空フォルダもJPEGへ置換できたため、JPEG/TIFFとも既存フォルダを入口と原子的設置直前の二段階で拒否する。
- RAW boost候補は校正実行ごとに全18枚を再生成し、過去バイナリの候補がレポートへ混ざるキャッシュ経路を削除する。

## 後続スライスへ送った指摘

- `DecodedPhoto`の`@unchecked Sendable`を介したactor境界越えは、現状のCore Image動作で実害を確認していないが、長期的にはdecode/render actorがCIImageを所有する構造へ変える。
- XMP色近似トグルを内部からOFFにしたときの二重レンダー候補は、30ms debounceとキャンセルで吸収されている。性能計測を伴うUI状態機械の整理時に扱う。
- 初期フォルダの固定値は自分用Phase 0では許容し、Phase 1でsecurity-scoped bookmarkとlast-opened folderへ移す。**レビュー後に前倒し実装済み**。初回は明示選択し、App Sandbox + app-scoped bookmarkで再起動復元、失効時再選択、SSD不在時のcapability保持まで追加した。
- 編集状態がメモリだけであること、legacy JSON schema、アプリ内TIFF書き出し、CIKLのdeprecated解消はSQLite／Metalリソース化スライスで扱う。
- `RenderEngine.apply`全体のHDR極値テスト、preview/export色一致、render cancellationの自動テストを追加する。

## 採用しなかった指摘

- 「未作成パスが原本と同じhard link inodeを指す」という状態は成立しない。hard linkは作成された時点で既存ファイルになり、現行のresource identifier比較で検出できる。文書上は誤解を避けるため「既存のhard link / symlink」と表現する。
- 2画像へ数値をさらにfitすること、プリセット専用LUTやシーン別RAW boostを作ることは、未観測シーンへの過学習になるため採用しない。

## 校正・テストへの評価

Claudeは、Lightroom参照と候補を同一のSwift/Core Image経路で1500pxへ正規化し、Python側でshape一致を強制する方法を妥当と評価した。ΔE等には同じGaussian blurを使いつつ、完全clipとnear-clipは未ぼかし画像で数える分離も正しい。CPU式、software Core Image、Metal Core Imageを別contextで実際にレンダーして比較している点も確認された。

一方、現在の2組は同一`colorful`プリセットのシーン違いにすぎず、各スライダーの応答や汎化性能は判定できない。`boost 0.90`も平均ΔE00だけの暫定最小で、Lightroomより大幅に白飛びする。この限界をREADME、校正文書、UIへ明示し続ける判断を維持する。

## 推奨する次の順序

1. HDR-safeなtoneとHSLを分離し、最後の一度だけsoft-knee色域マッピングを行う。
2. RAWに限ってXMP WBをCIRAWFilterへ渡し、JPEG/TIFFは別扱いにする。
3. 肌、青空、緑、暗部、逆光、飽和色、ColorCheckerを含む5〜10シーンと、各基本スライダー単独のLightroom TIFFを追加する。
4. 写真別編集状態をSQLiteへ自動保存する。
5. runtime CIKLをパッケージ済みMetal kernelへ移し、完成`.app`へのresource同梱までテストする。
6. Display P3と16bit成果物は、sRGB Phase 1の画質ゲート後に扱う。

数値と再現手順は`CALIBRATION.md`、調査根拠は`RESEARCH.md`に記録する。
