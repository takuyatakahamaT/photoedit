# Photo Bench 進捗・目標・次の作業

更新日: 2026-09-22 JST

## 現在の目標

**Lightroomで作ったXMPプリセットを登録すると、写真やプリセットごとの専用調整をせずに、共通の現像エンジンでLightroomと同様の仕上がりを得られるようにする。** その後に明るさ・色温度・色かぶり・彩度を少し調整し、JPEGを書き出す。最終的にNIHO Desktopの写真編集機能へ統合する。

- Adobeの現像機能が無料で使えるなら採用可能。
- 月額費用が必要な方式は採用せず、無料の部品を使う独自ローカルエンジンを優先する。
- 2026-09-22に担当を引き継いだ。設計・調査・計測設計・レビュー・文書は主担当（Claude）、production実装はSonnet 5のサブエージェント。実装writerは1体。

**現行方針と実行計画の正は[ENGINE_ROADMAP.md](ENGINE_ROADMAP.md)。** 要点は「Lightroomを教師にして操作ごとの応答を計測し、プリセット非依存の共通モデルへ落とす」「エンジンを基準現像／画素単位の色操作／空間操作の3層に分ける」。

## できたこと

| 項目 | 状態 |
|---|---|
| プリセット登録・ライブラリ | 日常編集初版で実装。元の4つと更新XMPを保持 |
| 明るさ・相対色温度・色かぶり・彩度 | 実装。LRの絶対WB値と同義ではない |
| 写真ごとのUndo / Redo | 実装・対象検証済み。履歴は起動中のみ |
| 編集の自動保存・再起動復元 | 実装・対象検証済み。失敗時の未保存表示・再試行あり |
| 原寸JPEG書き出し | 実装。元写真は別ファイルとして保護 |
| 3組のRAW / JPEG / LR基準画像の整理 | 完了。元データのhash・設定差を記録 |
| 更新版bluesky2 XMPの確認 | 完了。以前のXMPと値・digestが違うことを確認 |

**日常操作が揃ったことと、Lightroomの汎用プリセット互換が完成したことは別。後者は未達。**

## 中止した進め方

3組に合わせたbluesky2専用変換と、その後段のorange補正を試した。色差は小さくなったが、他のpresetへ一般化できる方式ではなかった。オーナーの指摘により、この設計を中止した。

- v2: 専用の色変換。0.3.0の試作bundleに反映した。
- v3: 専用変換の後にorange補正。sourceとテストに追加したが、単独版としてbundle配布していない。
- v4候補: 木目・髪等の局所コントラスト試作。専用fit方針の中止によりproduction採用しない。
- これらの比較画像・数値は研究履歴として保存し、汎用モデルの画質合格には数えない。

## 現在地（2026-09-22 引き継ぎ時点）

- 専用fitの新規自動適用は0.3.2で停止済み。新しいpreset選択はすべて同じXMP設定適用経路を通る。保存済みv2/v3編集だけが「過去の実験補正」として再現される。専用補正のコード自体は次の整理で撤去する。
- チェックポイントcommit `5054bdf`（`feature/raw-white-balance-observation`）を切り、以降は `feature/generic-xmp-engine` で作業。フェーズ0の撤去は `0c12dc8` で完了（`ReferenceLook` 一式を削除。旧レコードの `referenceLook` キーは無視して読む）。
- 汎用XMP経路は、更新版bluesky2の値でLRと平均ΔE00が17〜22離れている。原因は3つに分解できた: (1) ハイライト／シャドウ等を画面全体の1本のカーブで処理しており、LRが残している局所ディテール（全体カーブの1.3〜1.8倍）が出ない、(2) 土台がAppleの絵作りで、Adobe Standard＋Adobe Colorと違う、(3) XMPの大半の項目（parametric curve、Calibration、Color Grading、Texture、絶対WB等）が未描画。
- 追加調査の結論: Adobeの現像数式はほぼ非公開で、任意XMPの完全互換を達成した他製品も無い。一方、カメラプロファイルの数式は公開仕様で、このMacのLightroom内にDC-S5用DCPとAdobe Color定義があり、ルックテーブルのデコードも確認できた。

- フェーズ1の事前検証（Python試作）: 公開仕様＋Lightroom同梱のDC-S5用DCP＋Adobe Colorだけで、LRのプリセット無し現像を領域平均で平均ΔE00 1.2〜1.6まで再現できた（現行Core Image土台は2.4〜3.0で、LRより明るく彩度が8〜22%高い）。基準露出はカメラ定数として扱える。レンズ補正の一致が残課題。
- **フェーズ1完了:** RAWの基準現像を LibRaw + Adobe Standard DCP + Adobe Color（Lightroom同梱の資産を実行時に読む）へ切り替え、プリセット無しでLR既定と平均ΔE00 1.2〜1.9（旧: 2.4〜3.0、明るく高彩度）。アプリの写真情報に「現像: Adobe Standard + Adobe Color（LibRaw）」が出る。`photobench-render` CLI で GUI 無しに書き出せる。
- **round0 / round1 の計測完了（2026-09-22）。** 機械生成XMPはLRが読み、手動適用と完全一致。チャート194枚・実写94枚から操作ごとの式を同定した（`.photobench/phase2/{tone,hsl,color,spatial}/model.md`）。RAW実写で確定: 露出＝トーンカーブ前のリニア倍率、絶対WB＝DNG SDKの式、基準露出 −0.135 EV、Adobe Colorの点カーブ＝sRGB符号化RGBTone、コントラスト／白／黒／parametric／点カーブ＝トーンカーブ後のsRGB符号化空間、HSLとCalibration＝出力参照。
- ハイライト／シャドウは空間処理（HALDでは測れない）。同定した「大域カーブ＋ディテール保持」モデルの到達点は実写15ケース平均ΔE 3.1（大域のみと同程度）で、ここが最後まで残る残差。
- 実装は3段: C1（露出・絶対WB・コントラスト・白黒・parametric・点カーブ、[PHASE2_DEVELOP_PIPELINE.md](PHASE2_DEVELOP_PIPELINE.md)）→ C2（HSL・Calibration・Color Grading・Vibrance／Saturation）→ C3（ハイライト／シャドウ）、[PHASE2_C2_C3.md](PHASE2_C2_C3.md)。C1 は `2df8f6a` で完了（単一操作ゲート 1.2〜2.1。bluesky2全体は 5.0〜7.1 まで改善、開始時 17〜22）。C2 を実装中。

根拠・方式比較・出典は[ENGINE_ROADMAP.md](ENGINE_ROADMAP.md)。過去の調査は[汎用XMPエンジン設計](GENERIC_XMP_ENGINE.md)、[エンジン比較・根拠](ENGINE_RESEARCH.md)。

## 次の作業順

| フェーズ | 作業 | 合格条件 |
|---|---|---|
| 0 | ~~チェックポイントcommit、bluesky2専用補正の撤去~~（完了）、計測リグ（round0生成・判定は済み）、LRローカルタブのXMP往復確認（オーナーの書き出し待ち） | 往復が確認でき、リグが再現可能 |
| 1 | ~~RAW基準現像（DCP＋Adobe Color＋ACR既定カーブ＋基準露出）~~ **完了（`ce91bfc`）。** 設計は[PHASE1_BASE_RENDERING.md](PHASE1_BASE_RENDERING.md)。3枚とも平均ΔE00 1.2〜1.9、EV差 ±0.03 で合格。旧土台は 2.4〜3.0 | プリセット無しでLR既定と平均ΔE00 ≤ 2、平均EV差 ≤ 0.05（`compare_renders.py`） |
| 2 | 画素単位の色操作。計測・同定は完了。実装 C1（進行中）→ C2 | 実写（round0/1の参照）で操作ごとに平均ΔE00 ≤ 2（基準現像 1.2〜1.4 と同水準） |
| 3 | 空間操作（ハイライト／シャドウ→Texture／Clarity／Dehaze）。同定 v1 完了（大域＋ディテール保持、平均3.1）。実装 C3 | v1: 実写15ケース平均 ≤ 3.1。以降、局所モデルの改良で 2 以下を目指す |
| 4 | 既定シャープ／NR、レンズ補正、周辺光量・粒子、速度 | 100%表示の解像感がLRと同等 |
| 5 | 未使用プリセット×未使用写真の総合検証 | オーナーが普段使いできると判断 |
| 6 | NIHO Desktop統合 | — |

各フェーズの所要は前フェーズの実測後に見積もり直す。現時点の見立てはAI作業で延べ25〜45時間規模・複数セッション。完全一致は約束せず、ゲートの数値とオーナーの目視で到達点を判断する。

## オーナーにお願いする作業

1. ~~Lightroomでの一括書き出し~~ round0 / round1 は完了。C1〜C3 の実装後、追加計測（スライダー値の細かい刻み、未使用プリセット）を依頼する可能性がある。
2. **新エンジンの目視確認。** `dist/Photo Bench.app` でRAWを開き、写真情報に「現像: Adobe Standard + Adobe Color（LibRaw）」が出ること、プリセット無しの見た目がLRの既定に近いことを確認する。
3. 教師データを作れるのはLR契約中だけ。フェーズ2〜3の書き出しが済むまで契約を継続する。

## 成果物・履歴

- [現行方針・調査結果・実行計画](ENGINE_ROADMAP.md)
- [日常編集の実装・検証](EDITING_MVP.md)
- [汎用モデルの設計](GENERIC_XMP_ENGINE.md)
- [無料エンジンの調査と採用候補](ENGINE_RESEARCH.md)
- [不採用となった専用補正の履歴](BLUESKY2_REFERENCE.md)
- private入力・比較履歴: `.photobench/bluesky2-20260922/`、`exports/bluesky2-20260922/`
- SDK・調査証跡: `.photobench/engine-research-20260922/`

過去の2026-07-24 formal校正・性能結果と、その既知不合格は履歴として維持する。今回のエンジン候補の合格証拠として流用しない。
