# Photo Bench 外部調査に基づく本質的改善提案

- 実施日: 2026-07-24（JST）
- 作成: Claude（Fable 5）
- 方式: リポジトリ全文書と主要ソースの読解 + Web一次情報調査4系統（色再現 / プレビューアーキテクチャ / カタログ・選別 / 品質評価手法）+ 実機計測（オーナーの実RW2、システムSQLite）
- 対象: `/Users/takuyatakahama/Documents/app/NIHO/others/photo`
- 位置づけ: 個別実装のレビューではなく、`PROJECT_OVERVIEW.md` §8「現在の課題」に対する**方針レベルの提案**。fail-closed証跡文化、閾値の事後変更禁止、原本安全性の原則はすべて維持を前提とする。v3 parityの不採用判断を覆す提案は含まない（新契約として再定義する提案は含む）

---

## 0. 要約 — 4つの転換

現在の課題の多くは個別バグではなく、アプローチの構造に由来する。外部調査の結果、次の4転換を提案する。

| # | 現在のアプローチ | 提案する転換 | 主な根拠 |
|---|---|---|---|
| A | Adobe非公開式をclean-room近似し、2シーンで手動校正 | **土台をlinear出力+公開仕様（DNG/DCP）に替え、色変換はLightroom教師ペアからの正則化フィッティングで得る** | DNG spec 1.7.1（数式公開）、DNG SDKライセンス（組込可）、WWDC21のlinear出力公式レシピ、格子回帰研究 |
| B | プレビュー候補に原寸decodeとの空間的ピクセル一致を要求 | **「操作中draft / 停止後settle」の二層契約。settleが真値、draftは知覚ゲート** | 主要4製品すべてがプレビュー=近似設計、WWDC26 Session 305のApple公式パターン |
| C | 画質・性能の完成後に製品機能へ進む | **解約を阻む機能（永続化・カタログ・選別）を先行し、「LR契約中にしかできない作業」を最優先で実施** | 教師データ・移行データはLR解約後に入手不能。選別は埋め込みJPEGで即実現可能（実測済み） |
| D | 自作ヒューリスティック指標（plateau等）単独で合否判定 | **業界標準の知覚メトリクス（SSIMULACRA2等）と人間のフリッカー試験（ISO/IEC 29170-2型）で最終判定を較正** | JPEG AIC / VESA DSCの visually-lossless 運用、BT.500の小規模試験規定 |

一言でいうと、現在の方式は「Adobeのブラックボックスをピクセル単位で推測する」「プレビューにexport同等性を要求する」という、**業界の誰も解いていない形の問題**を解こうとしている。公開仕様・教師データ・二層プレビューという業界標準の問題設定に置き換えれば、同じ品質文化のまま到達可能性が大きく上がる。

---

## 1. 前提: 現状の強み（維持すべき資産）

提案の前に、外部と比較して明確に優れている点を記す。これらは変えない。

- **証跡文化**: manifest v3、122 artifactのhash-lock、失敗runの保存、閾値の事後変更禁止。個人開発でこの水準は例外的であり、OS/decoder更新の検知基盤としてそのまま機能する
- **原本安全性**: read-only原則、atomic export、上書き拒否、App Sandbox + security-scoped bookmark は既に製品水準
- **decoder境界**: `ImageDecoding` protocolによる交換可能設計は、本提案A（土台の交換）を安価にする
- **出力変換**: C1 shoulder + 固定L/h gamut compression + neutral bypass は67,368点グリッド検証込みで堅牢。CSS Color 4のΔEOK（JND 0.02）準拠も適切
- **metal-direct実験経路**: `EditorModel` / `ContentView` に既にopt-in実装（coalescingカウンタ付き）があり、提案Bの土台は存在する

---

## 2. 診断: 何が本質的ボトルネックか

### D1. 「解約クリティカルパス」と投資の不一致

投資のほぼ全てが画質校正・証跡基盤・プレビュー実験に向いている一方、解約を実際に阻んでいるのは「編集がアプリ終了で消える」「カタログ・選別・検索がない」「クロップがない」「WBが動かない」である。毎日使える最小ループが回っていないため、実利用からのフィードバック（何が本当に必要か）も得られていない。§10のロードマップ自体は正しい順序を示している — 問題はP1（プレビュー最適化）がv3不採用で振り出しに戻った後も、最適化研究を先に続ける計画になっていることである。

さらに重要な時間制約がある: **色再現の教師データ（LR基準書き出し）と、17,000枚の評価・アルバム等の移行データは、Lightroom契約中にしか作れない**。これは他のどの作業よりも「先にやらないと取り返しがつかない」性質を持つ（→提案C-0）。

### D2. 色一致の構造問題: ベース不在のまま後段で辻褄を合わせている

現パイプラインは「Appleのカメラ色レンダリング（`boost 0.9` = **Appleのトーンカーブが9割掛かった状態**）」の上に独自トーン近似を重ね、その出力をLightroomと比較している。つまりフィッティング対象が「Adobeのトーン+色」ではなく「Appleのトーンを打ち消しつつAdobeに寄せる合成非線形」になっており、シーン毎の残差（平均ΔE 3.3〜6.8、EVドリフト+0.21）が収束しにくい構造である。

外部調査で確定した事実がこの診断を裏付ける:

- Adobeの基本補正Exposureは**画像適応的**（原画像の白点に応じてロールオフが変わる）であることが実測分析で示されている（[Jim Kasson の実測シリーズ](https://blog.kasson.com/the-last-word/lightroom-and-photoshop-exposure-controls/)）。静的な単調プリミティブ合成では原理的に完全一致しない
- Adobeは機種ごとに**隠れたBaseline Exposure補償**を適用しており、その導出方法が公開されている（[RawDigger](https://www.rawdigger.com/howtouse/deriving-hidden-ble-compensation)）。P1524180 / RAWのEVドリフト+0.21の切り分けは、まずこの勘定合わせから始めるのが筋が良い
- 一方で、Adobeのカメラ色（DCP）の**処理数式は DNG 仕様書で完全公開**されている（→提案A）

### D3. プレビュー最適化の袋小路: ゲート設計が業界慣行より厳しい問題を解いている

v3 parityゲートは「縮小decodeが原寸decodeとplateau位置まで空間一致（1px以内）」を要求し、不合格の指標は面積 0.012〜0.015% vs 許容 0.01%（2,560px画像で数百px相当の散在差分）である。調査の結果、**プレビューにこの水準の一致を要求している製品は確認できなかった**:

- Lightroom: Smart Preview（2560px代理）編集を公式提供し「低品質表示になりうる」と明記。埋め込みプレビューは「LRのRAW解釈と一致しない」と公式に許容
- darktable: 公式マニュアルがpixelpipeを「export=full quality / darkroom=ROIのみ / 操作中=重いモジュール除外」と3段階に分離し、表示差異が出ることを明記。一致が欲しい人向けのopt-inモードには「応答性が大幅劣化」と注記
- RawTherapee: 縮小プレビューではNR等を省略し、1:1でしか正確に見えないツールに「1:1アイコン」を付け、100% detail windowで精密確認させる
- Capture One: 「ほとんどの操作はpreview（既定2560px）に対して行われる」と公式ブログに明記。フルRAWは100%表示とexportのみ

つまり業界標準は「**プレビュー=近似、export=真値、操作停止後や100%表示で精密化**」であり、品質は「ユーザーの判断を誤らせないこと」（クリップ警告の一貫性等）で担保している。現行の実UI（スライダー毎に原寸RAW decode→フルグラフ→`createCGImage` CPU readback→`NSImage`）は、Appleが公式に避けるべきと言う経路（→D4）でもある。

### D4. Apple公式パターンとの乖離

WWDC26 Session 305（[Enhance RAW image processing with Core Image](https://developer.apple.com/videos/play/wwdc2026/305/)）が対話的RAW編集の公式パターンを明示している:

1. 表示縮小時は `CIRAWFilter.scaleFactor` を使う
2. **対話用CIContextは view毎に1つ、`cacheIntermediates = true`**（パラメータ調整中に前段の重い処理をスキップさせるため）
3. Metal-backed viewへ直接描画する
4. **exportは別contextで `cacheIntermediates = false`**

現状は preview / export とも `false` であり、**previewについてはAppleの推奨と逆**。なお preview / export の context instance 分離は実装済みなので、この転換は export の再現性に一切影響しない（P1-2の承認済み方針とも整合し、それを公式根拠で加速するだけである）。

### D5. 自作指標の知覚的較正が未実施

plateau dilation指標は独自設計（Boundary IoU参考）で、「その差が人間に見えるか」の検証がない。0.0001 vs 0.00012 の攻防を面積率の土俵で続けるのは、封印ホールドアウトの文献（[Dwork et al., Science 2015](https://www.science.org/doi/10.1126/science.aaa9375)）が警告する「同じデータを見ながらの適応的判断」の誘惑でもある。業界には既製の較正手段がある: フリッカー2AFC試験（ISO/IEC 29170-2）と、そのスカラー化であるSSIMULACRA2（スコア90 = 「フリッカー試験で平均的観察者が識別不能」）。

### D6. 性能測定の変動源が既知パターン

process-fresh初回 1,903ms → 以後 339ms は、**Metal PSOのデバイス上バックエンドコンパイル + CIカーネルのランタイムコンパイル**（初回のみフルコスト、以後システムキャッシュ）という既知の仕様で説明がつく（[WWDC20 10615](https://developer.apple.com/videos/play/wwdc2020/10615/)）。また warm slider の49〜54msの揺れは、ゲート50msが**間接入力ドラッグの知覚閾値（JND ≈ 55ms、[CHI 2015実測](https://www.tactuallabs.com/papers/howMuchFasterIsFastEnoughCHI15.pdf)）のちょうど境界**にあること、QoS・thermal・コールドキャッシュが未統制であることの複合である。ゲート自体は根拠があり妥当（→提案E）。

---

## 3. 提案A: 色再現 — 「非公開式の推測」から「公開仕様 + データ駆動」へ

### A-0. 問題の再定義

「Lightroomの画作りの再現」は2つの独立した問題に分解できる。

1. **ベース色（カメラプロファイル+WB+ベース露出）**: Adobeのカメラ→出力色の基礎変換。これは**DNG仕様として数式が公開されている**（リバースエンジニアリング不要）
2. **プリセットの見え（トーン・HSL・カーブ）**: `colorful` 等の4 XMPが作る見え。これは**手元にLightroomがある限り、教師ペアを無限に生成できる回帰問題**

現在は1が不在のまま2を解析式で推測しており、最も difficult な形になっている。

### A-1. 短期: CIRAWFilterをlinear出力に切り替え、フィッティングの土台を固定する

Apple自身が「デフォルトルックを外してlinear scene-referred画像を得る」公式レシピを提示している（[WWDC21 Session 10160](https://developer.apple.com/videos/play/wwdc2021/10160/)）:

```text
baselineExposure = 0, shadowBias = 0, boostAmount = 0,
localToneMapAmount = 0, isGamutMappingEnabled = false
→ 「flat and underexposed だが、シーンの14 stopを unclipped で保持」
```

現行の `boost 0.9` を土台にする限り、独自トーンはAppleトーンとの合成を学習し続ける。**boost 0 のlinear出力を新しい校正土台**にすれば、フィッティング対象が「Adobeのレンダリングそのもの」になり、各スライダー・各プリセットの寄与分解も単純になる。これは新manifest versionの新契約として実施し、既存v3の結果は書き換えない。

### A-2. 短期（最重要・時限）: Lightroom自動化で教師データを量産する

- Lightroom Classic の Lua SDK には `LrExportSession`（プログラムからの一括書き出し）と、プラグイン経由の develop preset 適用APIがある（[developer.adobe.com/lightroom-classic](https://developer.adobe.com/lightroom-classic/)）
- さらに確実な量産ルート: **Photo BenchはすでにXMPパーサを持っている → 逆にXMPを機械生成**し（各スライダー単独 × 複数強度、プリセット別）、LRに読み込ませて一括書き出しする。LRは独自RAWの現像設定をXMPサイドカーで読み書きする（[Adobe公式](https://helpx.adobe.com/lightroom-classic/help/create-xmp-acr-files.html)）
- これにより「2シーン×1プリセット」から「**数十シーン × スライダー単独掃引 × プリセット**」へ教師データを2桁増やせる。RESEARCH.md「次の優先順位」2〜3項の実行手段そのものである

**この作業はLR契約中にしか実行できない。** 解約判断より前に、校正に必要十分なデータセット（後述D-4の層別設計: 逆光・肌・人工照明・高彩度・低照度…）を書き出して資産化しておくべきである。

### A-3. 短期〜中期: 色変換を正則化付きフィッティングで得る

「2シーン向け3D LUTは過学習するので採用しない」という現在の判断は正しい。ただし文献上の正解は「LUTをやめる」ではなく「**滑らかさ・単調性の制約付きで、多様なデータからfitする**」である:

- [Lattice Regression（NIPS 2009）](https://www.semanticscholar.org/paper/Lattice-Regression-Garcia-Gupta/0689b94e049c58b6e668d61f20901851bcb3b68f): 補間後誤差を直接最小化し、2階差分（Laplacian）正則化で滑らかさを担保。ICCプロファイル構築への応用実績
- [Monotonic Calibrated Interpolated Look-Up Tables（JMLR 2016）](https://jmlr.org/papers/volume17/15-243/15-243.pdf): **輝度軸の単調性制約**を持つLUT学習。EVドリフトやトーン反転を構造的に防止できる
- カメラプロファイル実務（[DCamProf](https://torger.se/anders/dcamprof.html)）も「精度より滑らかさ（relax既定）」を明示。「ターゲットへの過適合=実写での破綻」という思想はPhoto Benchの文化と同じ
- HaldCLUTの原理（「変換をidentity画像に通せばLUTが得られる」、[rawpedia Film Simulation](https://rawpedia.rawtherapee.com/Film_Simulation)）は、線形化後の後段（トーン・HSL・カーブ）に限り、identity TIFFをLRで現像して直接LUT化する近道としても使える

fitは leave-one-scene-out の**worst-case**（平均でなく最悪シーン）で評価し、封印ホールドアウト（→D-4）で最終確認する。現行のEV / clip / plateau ゲートはそのまま適用する。

### A-4. 中期: DCP + DNG SDK による「Adobeベース色」の標準ルート

- **DNG仕様 1.7.1.0 がDCPの全数式を公開している**（[公式PDF](https://helpx.adobe.com/content/dam/help/en/camera-raw/digital-negative/jcr_content/root/content/flex/items/position/position-par/download_section_733958301/download-1/DNG_Spec_1_7_1_0.pdf) pp.99–104: ColorMatrix/ForwardMatrixの補間・適用、HueSatMap（linear ProPhoto上のHSV三線形補間）、ProfileToneCurve（cubic spline指定）等）
- **DNG SDKのライセンスはロイヤリティフリーで商用クローズドソース組込可**（[ライセンス全文](https://scancode-licensedb.aboutcode.org/adobe-dng-sdk.html)）。GPLのRawTherapee/dcamprofのコードを読まずに、仕様書+DNG SDKだけでclean-room実装できる唯一の「Adobe公式コード」
- DCPファイル自体は Adobe DNG Converter（無償）が `/Library/Application Support/Adobe/CameraRaw/CameraProfiles/` に配置する。**アプリに同梱せず**、(a) ユーザー導入済みのものを読む（RawTherapee方式、[rawpedia](https://rawpedia.rawtherapee.com/How_to_get_LCP_and_DCP_profiles)）、(b) ColorChecker撮影から dcamprof / Lumariver で自作DCPを作って同梱（完全にクリーン）、の2段構えにする
- 注意: 「Adobe Color」はDCPではなくAdobe製品限定のXMP Enhanced Profileであり、第三者が読めるのは .dcp のみ。また `ProfileEmbedPolicy` の値と「非DNGファイル処理への利用」の文言はローカルで要確認（→§9）

制約も確定した: **CIRAWFilterはカメラネイティブRGB（Apple行列適用前）を公開しない**ため、DCPの行列部を仕様通り適用するには LibRaw 等の自前デコードが必要。LibRawは**LGPL 2.1 / CDDL 1.0のデュアルライセンスで選択制**（[公式](https://www.libraw.org/about)）であり、CDDL選択なら静的リンクでもアプリのソース開示義務がない。ただしAMaZE/RCD級のデモザイクはGPLパック側にあり、必要ならclean-room再実装のコストを見込む。**推奨は段階制**: まずA-1〜A-3（CIRAWFilter linear + fit）で色を詰め、DCP忠実適用が必要と判明した時点でLibRaw+DNG SDKルートを`ImageDecoding`境界の内側に追加する（既存設計の想定どおり）。

### A-5. EVドリフト+0.21の当面の切り分け（既存計画の補強）

計画済みの「curve / band別分解」に加えて、優先度順に:

1. **隠れBaseline Exposure勘定**（A-1のlinear土台なら消える変数。RawDiggerの導出手順を参照）
2. OKLCh mixer の Luminance=局所露光（+100 = +1 EV）定義そのもの。空が画面の大半を占めるシーン（P1524180）でグローバルEVを動かす構造であり、**Adobe HSL Luminanceの実効挙動をA-2の単独掃引データで直接測ってからfitし直す**のが本筋
3. `CIVibrance` / `CIColorControls` のHDR域挙動（ブラックボックスと明記済み）をfit対象に含めるか、独自kernel化するかの判断

### 受け入れ条件案（A）

- 新manifest（linear土台）で、教師シーン≥10・封印ホールドアウト≥2を層別確保
- fit結果は全シーンで現行ΔE / EV / clip / plateauゲートを通過し、leave-one-scene-out worst-caseで判定
- 既存4 XMPプリセットについて、SSIMULACRA2 ≥ 85（in-place比較で気づかない水準、→提案D）を暫定目標、最終はフリッカー試験
- 原寸export hash・既存回帰は非回帰

---

## 4. 提案B: プレビュー — 「ピクセル一致」から「二層契約（draft / settle）」へ

### B-0. 原則

v3の判断（縮小decode不採用・閾値を緩めない）は覆さない。代わりに、**そもそも縮小decodeを「唯一のプレビュー」として採用しようとした問題設定を変える**。業界標準とApple公式パターンに合わせ、プレビューを二層に分ける:

- **settle層（真値）**: 操作停止後・100%表示・export。原寸decode経路そのもの。定義上、画質ゲートは自明に非回帰
- **draft層（近似）**: スライダー操作中のみ。ゲートは「ピクセル一致」ではなく「**判断を誤らせないこと**」（クリップ表示の一貫性、知覚メトリクス、settleまでの時間）

### B-1. 第一手: preview contextの`cacheIntermediates = true`化（Apple公式パターン）

WWDC26 305の公式推奨どおり、**preview contextだけ** `cacheIntermediates = true` にする（export contextは`false`のまま。instance分離は実装済み）。効果の構造:

- CIは同一contextでの再renderで不変な前段（=原寸RAW decode結果）のバッファを再利用する。スライダー操作で再実行されるのは**トーン以降のみ**になる
- decodeキャッシュ境界を明示したい場合は [`CIImage.insertingIntermediate(cache: true)`](https://developer.apple.com/documentation/coreimage/ciimage/insertingintermediate(cache:)) をdecode出力直後に置く（contextの方針に関わらずその点をキャッシュ可能にする公式API）
- **この方式のdraftはsettleと同じ原寸decodeデータを使うため、v3が問題にした「縮小decode由来の空間差」が原理的に発生しない。** パリティ問題ごと消える可能性が高い
- メモリは承認済みP1-2の計画どおり [`kCIContextMemoryLimit`](https://developer.apple.com/documentation/coreimage/kcicontextmemorylimit) + 写真切替時の [`clearCaches` / `reclaimResources`](https://developer.apple.com/documentation/coreimage/cicontext/reclaimresources()) + 定常RSSゲートで拘束する（24MP RGBA16F ≒ 183MB/枚が目安）

まずこれを実装して実UIの input-to-screen を測る。**50ms p95に届けば、縮小decode系のdraftは不要**であり、二層目の議論は終わる。

### B-2. 第二手（B-1が50msに届かない場合のみ）: scaleFactor draft + settle

- 操作中のみ `scaleFactor` 縮小decode（またはdraft mode）でdraft表示し、操作停止後200〜300ms以内にsettle（原寸経路）で置き換える
- draft層の新ゲート（新manifest・事前登録）:
  - クリップ警告の判定一致（draftとsettleでクリップ表示領域の判断が変わらないこと。darktableの「入力起因/出力起因のクリップ分離」を参考に設計）
  - SSIMULACRA2 ≥ 90（フリッカー識別不能水準）— 導入前に2校正シーンで縮小系差分への感度を検証（→提案D）
  - settle到達時間 p95 ≤ 300ms、draft応答 p95 ≤ 50ms
- v3のplateau空間一致ゲートはdraft層には課さない（settle層は原寸経路なので自明に満たす）。これは「閾値を緩める」のではなく「plateau一致はsettle層の契約、draft層は知覚契約」という**層の分離**である

### B-3. 描画・初回コスト（既存P1-3計画の公式裏付けと補強）

- `createCGImage`→`NSImage` 経路はAppleが名指しで避けるべきとする静的コンテンツ経路（[WWDC20 10008](https://developer.apple.com/videos/play/wwdc2020/10008/): 「NSImageViewのようなviewは避け、Metal-backed viewへ直接描画」）。既存のmetal-direct実験経路（`MTKView` + `CIRenderDestination`、latest-only coalescing実装済み）を本採用ルートとするP1-3は公式パターンと一致しており、そのまま進めてよい
- 初回1.9秒はPSO/カーネルコンパイルの既知仕様。対策の優先順:
  1. **起動直後のオフスクリーン・ダミーレンダー1発**（代表的パラメータで。ユーザーの最初の写真オープンから初回コストを外す）
  2. 独自カーネルの `-fcikernel` ビルドと `.ci.metallib` 同梱（P1-5計画そのもの。[WWDC20 10021](https://developer.apple.com/videos/play/wwdc2020/10021/)）
  3. 自前Metal PSOがあれば `MTLBinaryArchive`（[WWDC20 10615](https://developer.apple.com/videos/play/wwdc2020/10615/)）
- macOS 26のRAW 9（CoreML統合decoder）は`decoderVersion`でopt-in。現行のRAW 8 pinは維持しつつ、初回コスト（MLモデルロード）と画質変動の両面で将来の再校正変数として記録しておく

### 受け入れ条件案（B）

- 実UI `preview-ui-path`（P1-4計画どおりsignpost計測）で input-to-screen p95 ≤ 50ms（知覚JND 55msの根拠付き）、target 16ms/frameを参考値として併記
- settle p95 ≤ 300ms、drop frame、複数写真遷移後の定常RSS（P1-2ゲート）
- 原寸export hash・画質ゲート非回帰（export contextは無変更なので構造的に満たす）
- draft層を導入する場合のみ: B-2の知覚ゲート一式を新manifestで事前登録

---

## 5. 提案C: 製品 — 解約クリティカルパスの先行立ち上げ

### C-0. 「LR契約中にしかできないこと」リスト（最優先・時限）

解約という目的から逆算すると、以下は機能実装より先に着手すべき時限タスクである:

1. **教師データ量産**（A-2）: シーン層別 × スライダー単独掃引 × プリセット別の16bit TIFF基準書き出し
2. **移行データの退避**: 17,000枚の原本・評価・フラグ・アルバム構造・編集値（XMP）の完全ローカル退避。Lightroom（クラウド版）利用とのことなので、原本+設定の一括取得手段の確認を含む（Classicカタログが手元にあるなら`.lrcat`はSQLiteであり、[構造は解析済み文書がある](https://github.com/hfiguiere/lrcat-extractor/blob/main/doc/lrcat_format.md)）
3. **受け入れ比較用の基準確保**: 解約後にA/B比較（→提案D）ができるよう、代表ワークフローのLR出力を保存

### C-1. 選別（culling）モード: 埋め込みJPEGで即立ち上がる

実機計測（オーナーの実RW2・このMac）で以下を確認済み:

| 項目 | 実測値 |
|---|---|
| DC-S5 RW2の埋め込みJPEG | **1920×1280・約670KB**（+160×120サムネイル。フルサイズは非搭載） |
| 埋め込み取得（`CGImageSourceCreateThumbnailAtIndex`、`FromImageAlways`なし） | **9〜89ms/枚**（実質I/O律速） |
| RAW実デコード（`FromImageAlways`） | 309〜473ms/枚 |

- 「選別=埋め込みJPEG即表示、編集=自前RAW現像」はPhoto Mechanic（[公式KB](https://camerabits.freshdesk.com/support/solutions/articles/48000361354-supported-file-formats-in-photo-mechanic-6)）とLightroom「Embedded & Sidecar」（[公式](https://helpx.adobe.com/lightroom-classic/help/photo-video-import-options.html)）の確立パターン。**1桁以上の速度差**が実測で出ており、17k枚選別の成立条件はこれで満たせる
- ただしDC-S5の埋め込みは1920pxのため**100%ピント確認は埋め込みでは不可能** → フィット表示までは埋め込み、ズーム要求時にRAWデコードへシームレス切替（+キャッシュ）
- FastRawViewerの反論（「埋め込みJPEGのヒストグラムは露出判断を誤らせる」、[公式](https://www.fastrawviewer.com/culling-raw-vs-jpegs)）は露出判定に限った話。UI上「埋め込み表示中」を小さく示し（LRと同じ）、露出が際どい個体はRAW表示へフォールバックできれば両立する
- キー操作はLR互換（`P`/`X`/`U`/`1-5`）+ auto-advance。DESIGN.md Phase 1の全画面選別モード仕様と一致

### C-2. カタログ実装の具体指針（Phase 1計画の詳細化）

調査で得た実務標準をそのまま採用できる:

- **SQLite設定**: `journal_mode=WAL` + `synchronous=NORMAL` + `busy_timeout≈5000` + 書き込みは`BEGIN IMMEDIATE`。GRDBの`DatabasePool`がこの規律を内蔵しており採用推奨。**このMacのシステムSQLite（3.51.0）はFTS5有効を実測確認済み**（検索はFTS5でよい。ただし`/usr/bin/sqlite3` CLIはFTS5無効なのでデバッグはHomebrew版で）
- **DB分離**: カタログDB（正・小さくバックアップ）とサムネイルDB（壊れても再生成可）を分ける（digiKam方式）。256px級サムネイルはSQLite BLOB格納が個別ファイルより速い（[SQLite公式: 35% Faster Than The Filesystem](https://www.sqlite.org/fasterthanfs.html)）。中間プレビュー（1024px超）はファイル+パス管理
- **多解像度キャッシュ**: LRのpreviews.lrdata同様「1画像=ピラミッド（例 256/1024/2560）+ 編集fingerprintキー」で無効化を自然に表現
- **バックアップ**: 稼働中DBの単純ファイルコピーは破損コピーを生む。`VACUUM INTO`での世代スナップショット（[SQLite公式](https://www.sqlite.org/backup.html)）。カタログを同期フォルダ（iCloud/Dropbox）に置かない注意書き
- **ファイル同一性**: 一次=volume UUID+相対パス、二次=size+mtime、三次=**先頭+末尾100KiBの部分ハッシュ**（digiKam実装方式。897GBの全量ハッシュ不要）。SSD未接続は「エラーでなく状態」とし、評価・アルバム操作は継続可能、原本必須操作のみブロック（LR/Capture Oneの確立UX）
- **増分スキャン**: FSEventsの**eventID永続化**でマウント時に差分スキャン+定期フルスイープ（[Apple公式ガイド](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html)が他OS書き込みボリュームでは「advisory扱い+定期スイープ」を明示）
- **削除安全**: 即unlink禁止。reject→物理削除は明示の一括操作のみ、`FileManager.trashItem`でゴミ箱経由（外付けでも`.Trashes`で復元可）。「カタログから外す」と「ディスクから消す」を別操作に
- **相互運用**: sidecarには `xmp:Rating`（0–5）/`xmp:Label`/`dc:subject` のみ書く（DBが正、XMPは冗長化 — darktable方式）。RW2本体には書かない。LRのpick/rejectフラグはXMPに載らない仕様である点に注意
- **サムネイル生成**: グリッド用は埋め込み取得→縮小、拡大用のみRAWデコード。EXIF回転は`kCGImageSourceCreateThumbnailWithTransform: true`。一括生成は`.utility` QoS+並列数制限+スクロール追い越しキャンセル。実測ベースの見積りでは17k枚の初回生成は並列化込みで目標30分に収まる

### 受け入れ条件案（C）

- アプリ再起動後に編集・評価・選別状態が復元される（Phase 1受け入れ条件そのまま）
- 17k枚規模: 起動2秒以内・グリッドスクロール落ち体感なし・選別モードで矢印送り p95 ≤ 100ms（埋め込み表示）
- SSD切断→再接続で欠損扱いゼロ、`quick_check`成功、`VACUUM INTO`スナップショットからの復元手順が文書化されている
- 原本バイト不変・カタログ破損ゼロは既存fail-closedテストの流儀で自動化

---

## 6. 提案D: 評価 — 業界標準メトリクスと人間の知覚試験で較正する

### D-1. 最終アービタ: フリッカー2AFC試験の正式プロトコル化

「Lightroomと見分けがつからない」の判定は、業界標準の **ISO/IEC 29170-2（JPEG AIC-2）型フリッカー試験**として文書化する（VESA DSCが「visually lossless」の根拠に使った実運用実績のある方法）:

- 同位置でLR出力とPhoto Bench出力を8〜10Hzで交互表示、2AFC（+Not sure）、シーンごとに十分な試行数で二項検定。**chanceと有意に区別できなければ合格**（fail-closedと整合: 識別できたら不合格）
- 素材はBT.500の規定に合わせ**最低4シーン・半分はcritical**（[ITU-R BT.500-14 §2.3本文確認済み](https://www.itu.int/dms_pubrec/itu-r/rec/bt/R-REC-BT.500-14-201910-S!!PDF-E.pdf)）。観察者1名は同規格の「informal」明示で方法論的に正当化される
- デバッグ用の前段には JPEG AIC-3 のboosting（2倍ズーム・差分2倍増幅）を使い、検出感度を底上げする

これにより、preview parityやプリセット一致の「面積率0.0001の攻防」に知覚的な最終根拠を与えられる。

### D-2. スカラーゲートの追加: SSIMULACRA2（+診断にFLIP）

- [SSIMULACRA2](https://github.com/cloudinary/ssimulacra2)（BSD-3）: **スコア90 = 「1:1フリッカーテストで平均的観察者が識別不能」、85 = in-place比較で気づかない**という既製の閾値解釈が公式に定義されており、2025年のJPEG AIC-3データセット評価でも客観メトリクス上位（SROCC 0.806）。preview parity・プリセット一致の両方に1本の知覚総合判定を足せる。注意: 圧縮アーティファクト向け設計のため、**縮小デコード系差分への感度を2校正シーンで検証してから**ゲート化する
- [NVIDIA FLIP](https://github.com/NVlabs/flip)（BSD-3）: 交互表示の知覚差マップ生成が設計目的で、**「どこが」違うかの診断に最適**。ただし近無損失域の順位付け性能は低い（SROCC 0.524〜0.631）ため合否には使わない
- LPIPSは高忠実度域で性能が低く不採用。将来HDR/P3出力を評価する時点でΔEITP（[ITU-R BT.2124](https://www.itu.int/dms_pubrec/itu-r/rec/bt/R-REC-BT.2124-0-201901-I!!PDF-E.pdf)）またはCAM16-UCSを追加（OKLabがSDR前提であることは[Ottosson本人の一次記述](https://bottosson.github.io/posts/oklab/)で確認済み）
- 平均ΔE00は「全体ドリフト検出器」として残し、合否権限は分位点・面積率・最大連結成分へ移す（画像への平均ΔE適用が不適切であることは[評価研究](https://ieeexplore.ieee.org/document/7498922/)で明確。現行の「ぼかし後p95」はS-CIELAB系の方向性と整合しており良い設計）

### D-3. plateau指標の改良（次期契約での事前登録項目）

現行指標は業界の「saturation map + 連結成分 + モルフォロジー」系と同型で筋が良い。次期manifestで事前登録すべき改良candidates:

1. dilation幅を固定1pxでなく**スケール比例**にする（縮小→比較のリサンプリング位相ズレは1pxを超えうる）
2. 面積率に加え**新規plateau最大連結成分サイズ**を併記（散在スペックルと塊を区別）
3. darktableに倣い「**入力（decode/センサー）起因」と「出力（トーン/色域）起因」のクリップを別チャンネル**で判定
4. 輝度帯の層別（Reference White超のspecular highlightはhard clipが適切な場合があると[ITU-R BT.2408](https://www.itu.int/dms_pub/itu-r/opb/rep/R-REP-BT.2408-7-2023-PDF-E.pdf)も指針化）

### D-4. シーン拡張と統計運用（既存計画の方法論固め）

- 計画中の5〜10シーンはBT.500の最低4素材要件を満たす。層別（逆光・肌・人工照明・高彩度・低照度・ISO別）で「critical半分」を確保
- **封印ホールドアウト≥2シーンを最初から分離**し、閾値・fit決定後は合否確認のみに使う。failしたら閾値でなく実装を直す（[reusable holdout, Science 2015](https://www.science.org/doi/10.1126/science.aaa9375)）
- 閾値変更は「新シーン取得前に文書で宣言→新シーンで検証」の順に固定（[Gelman & Loken: forking paths](https://sites.stat.columbia.edu/gelman/research/unpublished/p_hacking.pdf)のpre-registration運用）。既存の「結果を見た後に緩めない」原則の統計的裏付けであり、変更履歴をリポジトリに記録する
- leave-one-outは小標本で分散が大きい（[シミュレーション研究](https://link.springer.com/article/10.1186/s41512-023-00146-0)）ため、**各foldのworst-caseをゲートにする**保守的運用がfail-closed思想に合う

---

## 7. 提案E: 性能測定の安定化（BENCHMARK.md「次の性能改善」の補強）

- **cold / warm を別ゲートに分離**する。process-fresh初回のPSO/カーネルコンパイル（D6）はwarm p95に混ぜず、「初回起動体験」の製品指標として別管理（対策はB-3のwarm-up render）
- ベンチのスレッド/queueを `userInitiated` 以上のQoSに固定（Apple公式: [QoSがE/Pコア割当に影響](https://developer.apple.com/documentation/apple-silicon/tuning-your-code-s-performance-for-apple-silicon)。macOSにコア固定APIはなく、QoSで統計的に誘導するのが実務）
- run間cooldown、`thermalState`記録（実装済み）に加え、`nominal`以外のrunをフラグ付け。反復≥10 + MAD等の外れ値**検出**（削除はしない現行方針のまま、警告として記録）— [hyperfine](https://github.com/sharkdp/hyperfine) / [Google Benchmark](https://github.com/google/benchmark/blob/main/docs/reducing_variance.md)の設計を踏襲
- 50ms gateは**間接入力ドラッグのJND ≈ 55ms**（[CHI 2015](https://www.tactuallabs.com/papers/howMuchFasterIsFastEnoughCHI15.pdf)）の直下にあり根拠がある。RAILの分類ではスライダーはAnimation（10〜16ms/frame）なので、**gate 50ms / target 16ms の二層**で文書化すると恣意性が消える
- 実UI計測（P1-4のsignpost計画）は本提案B-1実装後の最初の測定対象とする

---

## 8. 実行順序の提案

依存関係と時限性から、次の順を提案する（番号は優先度。並行可能なものは明記）:

1. **C-0: LR契約中にしかできない作業**（教師データ量産の仕組み化・移行データ退避）。他のすべてに先行する時限タスク。A-2のXMP機械生成→LR一括書き出しのパイプラインを作り、シーン層別の基準ライブラリを資産化する
2. **B-1: preview context `cacheIntermediates=true` + 実UI signpost計測**（変更量が小さく、Apple公式パターンで、P1-2/P1-4承認方針の実行そのもの）。50ms達成ならプレビュー問題は閉じる
3. **C-1/C-2: カタログ+編集永続化+選別モード**（Phase 1本体）。埋め込みJPEG選別は画質研究と完全に独立で、着手可能
4. **D-1/D-2: フリッカー試験プロトコル文書化 + SSIMULACRA2の感度検証→ゲート追加**（以後の全画質判断の物差しになるため早めに）
5. **A-1/A-3: linear土台の新manifest + 教師データでのfit**（1のデータが揃い次第）
6. **B-2**（B-1が50ms未達の場合のみ）、**A-4**（fitで不足と判明した場合のみ）、B-3のkernel移行（P1-5、profile後）

「2→3→5」は概ね直列でなく並行できる。共通則として、各スライスは新しいmanifest versionと事前登録した受け入れ条件で始め、既存証跡を書き換えない（現行運用のまま）。

---

## 9. 未確認事項（担当者によるローカル確認を推奨）

調査で断定できなかった点。事実として扱う前に確認すること:

1. **DC-S5用 Adobe Standard DCP の実在とその `ProfileEmbedPolicy` 値**: DNG Converterをインストールし `/Library/Application Support/Adobe/CameraRaw/CameraProfiles/` を確認（exiftoolで読める）。policy=0の場合「非DNGファイル処理への利用」が文言上グレーな点も含めて判断
2. **`cacheIntermediates=true` 時の実UI input-to-screen 実測**（B-1の成否はこれで決まる。183MB/枚級のキャッシュ増もRSSゲートで同時測定）
3. **SSIMULACRA2の縮小デコード系差分への感度**（圧縮向け設計のため、既存2シーンのv3 artifactで挙動確認してからゲート化）
4. **Lightroom（クラウド版）からの原本+編集メタデータの完全退避手段**（Classicと違いローカル`.lrcat`がない可能性。移行計画の前提）
5. macOSの `CIContext.memoryTarget` 既定値、CIRAWFilter同一インスタンス再利用によるdemosaicキャッシュの明文仕様（公式に確認できたのはcontext経由のキャッシュまで）
6. Smart Previewの長辺が2540pxか2560pxか（公式系ソース間で表記揺れ。設計判断には影響しない）

---

## 10. 主要出典

### Apple公式
- [WWDC26 Session 305: Enhance RAW image processing with Core Image](https://developer.apple.com/videos/play/wwdc2026/305/)（対話RAW編集の公式パターン: scaleFactor / preview context cacheIntermediates=true / Metal直描 / export context false）
- [WWDC21 Session 10160: Capture and process ProRAW images](https://developer.apple.com/videos/play/wwdc2021/10160/)（linear scene-referred出力の公式レシピ）
- [WWDC20 Session 10008: Optimize the Core Image pipeline](https://developer.apple.com/videos/play/wwdc2020/10008/) / [10021: Metal-based CI kernels](https://developer.apple.com/videos/play/wwdc2020/10021/) / [10615: Build GPU binaries with Metal](https://developer.apple.com/videos/play/wwdc2020/10615/)
- [CIRAWFilter](https://developer.apple.com/documentation/coreimage/cirawfilter) / [insertingIntermediate(cache:)](https://developer.apple.com/documentation/coreimage/ciimage/insertingintermediate(cache:)) / [kCIContextMemoryLimit](https://developer.apple.com/documentation/coreimage/kcicontextmemorylimit) / [FSEvents Programming Guide](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html) / [Apple silicon performance tuning](https://developer.apple.com/documentation/apple-silicon/tuning-your-code-s-performance-for-apple-silicon)

### Adobe公式・仕様
- [DNG Specification 1.7.1.0（DCP数式: pp.99–104）](https://helpx.adobe.com/content/dam/help/en/camera-raw/digital-negative/jcr_content/root/content/flex/items/position/position-par/download_section_733958301/download-1/DNG_Spec_1_7_1_0.pdf) / [DNG SDKライセンス](https://scancode-licensedb.aboutcode.org/adobe-dng-sdk.html)
- [Smart Previews](https://helpx.adobe.com/lightroom-classic/help/lightroom-smart-previews.html) / [Embedded & Sidecar import](https://helpx.adobe.com/lightroom-classic/help/photo-video-import-options.html) / [Optimize performance（Camera Raw cache）](https://helpx.adobe.com/lightroom-classic/kb/optimize-performance-lightroom.html) / [XMP sidecar](https://helpx.adobe.com/lightroom-classic/help/create-xmp-acr-files.html) / [Lightroom Classic SDK](https://developer.adobe.com/lightroom-classic/)

### OSS・成熟製品
- darktable: [pixelpipe](https://docs.darktable.org/usermanual/development/en/darkroom/pixelpipe/the-pixelpipe-and-module-order/) / [clipping warning](https://docs.darktable.org/usermanual/4.0/en/module-reference/utility-modules/darkroom/clipping/) / [sidecar二重書き](https://docs.darktable.org/usermanual/development/en/overview/sidecar-files/sidecar/)
- RawTherapee: [Editor（detail window）](https://rawpedia.rawtherapee.com/Editor) / [DCP対応](https://rawpedia.rawtherapee.com/Color_Management) / [DCP入手](https://rawpedia.rawtherapee.com/How_to_get_LCP_and_DCP_profiles)
- [Capture One: Preview Sizes and Offline Editing](https://www.captureone.com/blog/preview-sizes-and-offline-editing-in-capture-one-pro-7) / [Photo Mechanic: Supported File Formats](https://camerabits.freshdesk.com/support/solutions/articles/48000361354-supported-file-formats-in-photo-mechanic-6) / [FastRawViewer: Culling RAW vs JPEGs](https://www.fastrawviewer.com/culling-raw-vs-jpegs)
- [LibRaw（LGPL/CDDL選択制）](https://www.libraw.org/about) / [DCamProf](https://torger.se/anders/dcamprof.html) / [rawpedia Demosaicing](https://rawpedia.rawtherapee.com/Demosaicing) / [lrcat-extractor（LRカタログ構造）](https://github.com/hfiguiere/lrcat-extractor/blob/main/doc/lrcat_format.md)
- SQLite公式: [WAL](https://www.sqlite.org/wal.html) / [Backup API](https://www.sqlite.org/backup.html) / [How To Corrupt](https://www.sqlite.org/howtocorrupt.html) / [Faster Than FS](https://www.sqlite.org/fasterthanfs.html) / [GRDB.swift](https://github.com/groue/GRDB.swift)

### 規格・研究
- [ISO/IEC 29170-2（フリッカー試験）](https://www.iso.org/standard/66094.html) / [JPEG AIC](https://jpeg.org/aic/) / [ITU-R BT.500-14本文](https://www.itu.int/dms_pubrec/itu-r/rec/bt/R-REC-BT.500-14-201910-S!!PDF-E.pdf) / [ITU-R BT.2124（ΔEITP）](https://www.itu.int/dms_pubrec/itu-r/rec/bt/R-REC-BT.2124-0-201901-I!!PDF-E.pdf) / [ITU-R BT.2408](https://www.itu.int/dms_pub/itu-r/opb/rep/R-REP-BT.2408-7-2023-PDF-E.pdf)
- [SSIMULACRA2](https://github.com/cloudinary/ssimulacra2) / [NVIDIA FLIP](https://github.com/NVlabs/flip) / [高忠実度域のメトリクス評価（2025）](https://arxiv.org/html/2509.13150v1) / [ColorVideoVDP](https://github.com/gfxdisp/ColorVideoVDP)
- [Lattice Regression (NIPS 2009)](https://www.semanticscholar.org/paper/Lattice-Regression-Garcia-Gupta/0689b94e049c58b6e668d61f20901851bcb3b68f) / [Monotonic LUTs (JMLR 2016)](https://jmlr.org/papers/volume17/15-243/15-243.pdf) / [Learning Image-adaptive 3D LUTs (TPAMI 2022)](https://arxiv.org/abs/2009.14468)
- [Dwork et al.: The reusable holdout (Science 2015)](https://www.science.org/doi/10.1126/science.aaa9375) / [Gelman & Loken: forking paths](https://sites.stat.columbia.edu/gelman/research/unpublished/p_hacking.pdf) / [LOOCVの小標本分散](https://link.springer.com/article/10.1186/s41512-023-00146-0)
- [Deber et al.: How Much Faster is Fast Enough? (CHI 2015)](https://www.tactuallabs.com/papers/howMuchFasterIsFastEnoughCHI15.pdf) / [Ng et al. (UIST 2012)](https://www.tactuallabs.com/papers/designingLowLatencyDirectTouchInputUIST12.pdf) / [RAIL model](https://web.dev/articles/rail)
- [Jim Kasson: LR/PS Exposure controls実測](https://blog.kasson.com/the-last-word/lightroom-and-photoshop-exposure-controls/) / [RawDigger: 隠れBaseline Exposure導出](https://www.rawdigger.com/howtouse/deriving-hidden-ble-compensation) / [画像への平均ΔE適用の限界](https://ieeexplore.ieee.org/document/7498922/) / [Oklab一次記事（SDR前提）](https://bottosson.github.io/posts/oklab/)
