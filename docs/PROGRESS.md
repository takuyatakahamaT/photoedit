# Photo Bench 進捗・目標・次の作業

更新日: 2026-09-23 JST

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
- 実装は3段: C1（露出・絶対WB・コントラスト・白黒・parametric・点カーブ、[PHASE2_DEVELOP_PIPELINE.md](PHASE2_DEVELOP_PIPELINE.md)）→ C2（HSL・Calibration・Color Grading・Vibrance／Saturation）→ C3（ハイライト／シャドウ）、[PHASE2_C2_C3.md](PHASE2_C2_C3.md)。C1 は `2df8f6a` で完了（単一操作ゲート 1.2〜2.1。bluesky2全体は 5.0〜7.1 まで改善、開始時 17〜22）。C2 は `c1d274d` で完了（実写ゲート: HSL 1.38 / Saturation 1.27 / Vibrance 1.30 / SplitToning 1.33 / Calibration 2.24 / GreenHue+50 2.0〜2.2 / BlueSat+50 2.6〜2.7。bluesky2全体は **4.16 / 5.55 / 5.62**、彩度比 0.93〜1.07。残りは旧近似のハイライト／シャドウで EV +0.18〜+0.33）。**C3（ハイライト／シャドウの局所ラプラシアン）は `b70f123` で完了**（H/S 単体 12 ケース平均 2.84。参照実装を自前中立レンダーに掛けた値と一致し、差は基準現像とモデル自体の残差。bluesky2 全体 7.15 / 4.67 / 5.18、EV −0.26〜−0.45 で暗い）。同日に Texture／Clarity／Dehaze の同定（`.photobench/phase2/detail/`、15 ケース平均 1.93）、RW2 埋め込みレンズ歪曲補正の同定（`.photobench/phase4/lens/`、中立 0.93〜1.22）、アプリ UI の LR 相当パネル化（`f5a7985`）を実施。**C4（Texture／Clarity／Dehaze、`8c1569f`）とレンズ歪曲補正（`13b62f0`）も完了。** ただし 4 プリセット × 2 scene は 8 組すべてが EV −0.24〜−0.58 で暗く、C2 時点の旧近似より悪い（原因はハイライト／シャドウのゲイン表の振幅が実写に合っていないこと。合成で積み上がる）。その後、空間処理の位置（RAW はトーンカーブ前、非RAW は露出前）と振幅係数（kH 0.5 / kS 0.8）を実エンジンの格子探索で決め、Dehaze の量応答を round2 の実測で区分線形にした（`334fa20`）。さらに round2 セット A（16 scene）と round3（JPEG 入力 8 scene）から、ハイライト／シャドウの振幅と帯域位置を写真ごとの統計量で決める画像適応（RAW: shift＋再 fit kS、非RAW: 専用の kH・kS・shift）を入れた（`206880a`〜`46b4989`）。**4 プリセット × 2 scene は RAW: bluesky2 1.89 / pastel 1.16 / colorful 2.26 / night 6.04、JPEG: 2.74 / 1.83 / 1.99 / 5.43**（今朝 RAW 4.2 / 3.9 / 6.5 / 9.8、JPEG 4.9 / 5.6 / 7.6 / 10.4）。縦位置 RAW の向きも修正（`23bf87c`）。残課題は night の色（Red/Orange のドリフト、Calibration の順序）、明るい JPEG での法則の外挿、非常に暗い scene、シャープ／NR・周辺光量（[ENGINE_ROADMAP.md](ENGINE_ROADMAP.md)「新既定の再計測」）。

根拠・方式比較・出典は[ENGINE_ROADMAP.md](ENGINE_ROADMAP.md)。過去の調査は[汎用XMPエンジン設計](GENERIC_XMP_ENGINE.md)、[エンジン比較・根拠](ENGINE_RESEARCH.md)。

## 次の作業順

| フェーズ | 作業 | 合格条件 |
|---|---|---|
| 0 | ~~チェックポイントcommit、bluesky2専用補正の撤去~~（完了）、計測リグ（round0生成・判定は済み）、LRローカルタブのXMP往復確認（オーナーの書き出し待ち） | 往復が確認でき、リグが再現可能 |
| 1 | ~~RAW基準現像（DCP＋Adobe Color＋ACR既定カーブ＋基準露出）~~ **完了（`ce91bfc`）。** 設計は[PHASE1_BASE_RENDERING.md](PHASE1_BASE_RENDERING.md)。3枚とも平均ΔE00 1.2〜1.9、EV差 ±0.03 で合格。旧土台は 2.4〜3.0 | プリセット無しでLR既定と平均ΔE00 ≤ 2、平均EV差 ≤ 0.05（`compare_renders.py`） |
| 2 | 画素単位の色操作。計測・同定は完了。~~実装 C1 → C2~~ **完了（`2df8f6a`、`c1d274d`）** | 実写（round0/1の参照）で操作ごとに平均ΔE00 ≤ 2（基準現像 1.2〜1.4 と同水準） |
| 3 | 空間操作。~~C3（H/S）→ C4（Texture／Clarity／Dehaze）~~ **実装完了（`b70f123`、`4062010`、`8c1569f`）。** H/S 18 ケース 2.22、detail 15 ケース 2.18。残課題: H/S の振幅が実写に合わず合成で暗い（再フィット中） | v1: 実写15ケース平均 ≤ 3.1。以降、局所モデルの改良で 2 以下を目指す |
| 4 | 既定シャープ／NR、レンズ補正（歪曲は RW2 埋め込み係数で確定・実装中。周辺光量は同定できず保留）、粒子、速度 | 100%表示の解像感がLRと同等 |
| 5 | 未使用プリセット×未使用写真の総合検証（2026-09-23 夜: RAW 3 本は平均 ΔE 1.2〜2.3、night 6.0、JPEG 1.8〜2.7、night 5.4） | オーナーが普段使いできると判断 |
| 6 | NIHO Desktop統合 | — |

各フェーズの所要は前フェーズの実測後に見積もり直す。現時点の見立てはAI作業で延べ25〜45時間規模・複数セッション。完全一致は約束せず、ゲートの数値とオーナーの目視で到達点を判断する。

## オーナーにお願いする作業

1. **新 UI の実機確認**（2026-09-23 の `f5a7985`。`scripts/build-app.sh` で `dist/Photo Bench.app` を再ビルドしてから）:
   - RAW を開き、基本補正 > ホワイトバランスの色温度／色かぶり補正が撮影時の値から始まり、動かすと「カスタム」になり、「撮影時」で戻る。
   - トーンカーブ: 空き位置クリックで点追加、ドラッグで移動、枠の外へドラッグして離すと削除、「カーブをリセット」。
   - HSL・カラーグレーディング・キャリブレーションがプレビューに反映され、各セクションの「リセット」がそのセクションだけ戻す。
   - ⌘Z / ⇧⌘Z でスライダー 1 回のドラッグやカーブ操作が 1 回の Undo になる。
   - プリセット適用時に旧「HSL・カーブ近似」トグルが無く、HSL／カーブが常に反映される。JPEG 書き出しにも反映される。
2. **LR 追加書き出し（round2、生成済み）**。`exports/lr-measure/round2/round2-photos/`（153 枚の RAW クローン＋サイドカー、実容量は増えない）を Lightroom「ローカル」で開き、全選択 → 書き出し（JPG 100%・フルサイズ・sRGB・出力シャープ OFF・ファイル名そのまま）を `exports/lr-measure/round2/lr-export-photos/` へ。所要 10〜15 分、約 1.5〜2 GB。手順は同フォルダの `README.md`。内容: A = ハイライト／シャドウの画像適応（全 6 scene）、B = 複数スライダー合成（3 scene）、C = Texture／Clarity／Dehaze の線形性、D = HSL の青。
   - 手持ちの RAW を追加したい場合は、フォルダにまとめて `python3 scripts/lr_measure/make_round2.py --extra-raw-dir <dir>` で再生成できる（暗部の面積が違う写真を 5〜10 枚足せると画像適応の fit が安定する）。
   - 周辺光量用の平坦な被写体（グレーカード・曇天）を同じレンズ・同じ絞りで数枚撮れると、フェーズ4 の周辺光量補正に使える（任意）。
3. 教師データを作れるのは LR 契約中だけ。round2 の書き出しが済むまで契約を継続する。

## 実行環境の注意（2026-09-23）

- 個人 Mac mini（16GB）は、原寸 float パイプラインのレンダー・`swift test`・numpy の原寸比較を並行させると watchdog リセットで再起動する（06:01 と 11:27 に発生）。**実装エージェントは 1 体ずつ直列、重い処理は Mac Studio（64GB）で実行**する。入口は `scripts/studio/studio-run.sh`（sync / sync-data / run / fetch）。Studio 側の前提（libraw・pkgconf・`~/.venvs/photobench`・Lightroom CC のプロファイル資産）は整備済み。
- Studio と mini の中立レンダーは同一の結果（0.93 / 1.15 / 1.24）。

## 成果物・履歴

- [現行方針・調査結果・実行計画](ENGINE_ROADMAP.md)
- [日常編集の実装・検証](EDITING_MVP.md)
- [汎用モデルの設計](GENERIC_XMP_ENGINE.md)
- [無料エンジンの調査と採用候補](ENGINE_RESEARCH.md)
- [不採用となった専用補正の履歴](BLUESKY2_REFERENCE.md)
- private入力・比較履歴: `.photobench/bluesky2-20260922/`、`exports/bluesky2-20260922/`
- SDK・調査証跡: `.photobench/engine-research-20260922/`

過去の2026-07-24 formal校正・性能結果と、その既知不合格は履歴として維持する。今回のエンジン候補の合格証拠として流用しない。
