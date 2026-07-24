# Claude実装レビューと対応

実施日: 2026-07-23
対象: Photo Bench Phase 0縦切りプロトタイプ
方法: Claude Opusによるread-onlyの全実装レビュー

## 結論

PhotoCoreとSwiftUIを分け、`ImageDecoding`境界でRAW backendを交換可能にした方向は妥当。一方、Phase 0のままでもデータ誤認・大量写真での停止・色の誤認につながる項目があり、公開や本運用へ進む前の修正が必要と判定された。

## Blocking指摘と対応

| 指摘 | 対応 |
|---|---|
| XMP内`crs:Look`の入れ子`rdf:Description`がプリセット本体へ混入 | トップレベルDescriptionだけを属性として採用し、回帰テスト追加 |
| 17,000枚のフィルムストリップが全Viewを即時生成 | `LazyHStack`へ変更 |
| フォルダ走査がMain Actorを停止 | `Task.detached`で走査し、走査中表示を追加 |
| RAWメタデータをJPEGへ丸ごと転記 | EXIF / GPSと安全なTIFF項目だけへ限定。Orientationを1に正規化 |
| 写真切替中に前写真が表示されたまま | 選択時にpreview/decode情報を即時クリアし、ProgressViewを表示 |
| 連続レンダがGPUキューへ蓄積 | `RenderCoordinator` actorで同時実行を1件に制限し、待機中キャンセルを確認 |

## 色に関する重要指摘と判断

- Core Image RAWの既定tone boostへ依存すると、OS差が入り、Adobe Color比較の基準が不安定になる。
- AdobeのトーンカーブはPhoto BenchのsRGB LUT近似と処理空間・順序が異なる。
- HSLも8色バンド近似であり、Lightroom互換とは呼べない。
- Lightroom reference exportとColorCheckerがないため、ΔE00はまだ計測できない。

対応として、RAWのglobal tone boostを明示的に0へ固定し、撮影時WBを起点とする校正用baselineにした。また、XMPのHSL・カーブ近似は解析結果を保持しつつ初期OFFとし、UIで明示的に有効化した場合だけ適用する。プレビューと書き出しはsRGBであること、Lightroom色差が未校正であることを常時表示する。

## 後続へ送った項目

- Lightroom基準画像を使ったΔE00・肌色・ハイライト・解像感ゲート
- Core Image RAWがゲート不合格の場合のLibRaw + DCP backend比較
- Display P3対応と画面プロファイル追従
- HSL/curve LUTキャッシュ、広色域・ハイライト保持の再設計
- SQLiteページング、永続サムネイル、17,000枚実データ負荷試験
- decoder / OS versionの編集記録への保存

## レビュー後の検証

- 実物`P1524180.RW2`の6000×4000原寸デコード
- 原寸6000×4000 sRGB JPEG書き出し
- 元RW2のバイト列不変
- JPEGのtop-level / TIFF Orientationが1
- RAW固有辞書をJPEGへ転記しない
- XMPのAdobe Color / Amount / Copyrightがトッププリセットへ混入しない
