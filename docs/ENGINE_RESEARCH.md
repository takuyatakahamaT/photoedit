# 無料で組み込める現像エンジンの調査

調査日: 2026-09-22 JST。公式資料と配布ソースを確認。候補エンジンを使った実画像比較は未実施。

## 結論と選定方針

**第一候補は、LibRawによるRAW読み込み、DNG/DCPに沿った基準色処理、自社の共通XMP演算を組み合わせる構成。** これは調査に基づく設計提案であり、Lightroomとの再現性が実証済みの完成品ではない。

DNG SDKは無料で利用できるAdobeの部品として有用。ただし、これだけで任意のLightroom XMPを適用できる現像エンジンではない。RawTherapee/ARTは基準色や独立した現像結果の比較候補。現在のCore Image経路を比較対象として残し、最初の基準現像の検証結果を見て本採用を決める。

オーナー条件は「Adobeのエンジンが無料なら利用可。月額費用が発生するなら独自に作りたい」。恒久無料での本番利用を確認できないクラウドAPIは採用対象から外す。ローカルで完結する構成を優先する。

## 候補比較

| 候補 | 無料利用・組み込み | XMP / Lightroom再現との関係 | 判断 |
|---|---|---|---|
| Photoshop API v2 | 公式導入条件はFirefly Servicesを含むEnterprise契約。恒久無料の本番利用枠は確認できない | XMP適用は公式機能 | 今回の費用条件では採用しない |
| Adobe DNG SDK 1.7.1 build 2724 | 配布LICENSEにroyalty-freeの利用・改変・配布等の許諾。著作権表示等の条件あり | DNG読書き、WB・カメラプロファイル・基礎レンダー等。現行LRプリセットの演算一式ではない | 基準色処理の部品候補 |
| LibRaw | 無償。LGPL 2.1 / CDDL 1.0から選択。対象ライブラリの配布条件に従う | RAW読み込みの土台。LRのXMP現像は提供しない | RAWデコード第一候補 |
| RawTherapee | 無料、GPLv3。製品への組み込み時はGPLの配布設計が必要 | DCP対応。現像設定はPP3。DCPが使えることとLR XMP互換は別 | 比較・実験用の第一候補 |
| ART | 無料、GPLv3。RawTherapee派生。LibRaw選択可 | 独自ARP処理設定。XMPのmetadata対応はLR現像互換を意味しない | 比較用の第二候補 |
| darktable | 無料の現像アプリ | 公式FAQが他社preset非互換・LR編集取込の限界を明記。DCP非対応 | LR互換基盤としては優先しない |
| 現在のCore Image RAW | 現アプリですでに利用中。追加の現像サービス契約なし | AppleのRAW処理であり、XMPのAdobe設定への互換は自前で必要 | 比較基準と既存編集互換として保持 |

## 根拠

### Adobeの公式API

公式のPhotoshop API導入条件にはEnterprise契約が挙げられる。旧API FAQには試用と有料利用の区別もあるが、古い試用枠を現在の恒久無料枠として採用しない。現在の金額や課金の内訳は未確定。契約・API登録・写真送信は実施していない。[公式導入条件](https://developer.adobe.com/firefly-services/docs/photoshop/getting-started/)、[旧FAQ](https://developer.adobe.com/photoshop/api/faq/faq/)

### Adobe DNG SDKを実際に調べた結果

[公式DNGページ](https://www.adobe.com/support/downloads/dng/dng_sdk.html)から案内される1.7.1 build 2724（2026-09-08）を調査用private領域へ取得した。SDKを製品に導入・ビルドしてはいない。

- 取得URL: `https://download.adobe.com/pub/adobe/dng/dng_sdk_1_7_1_2724_20260908.zip`
- SHA-256: `740fbe95c69e09e9cd17654a5e4fef2d7021254b06fd2b8c5557b79a1496b50c`
- `LICENSE.txt` §1に無償の利用・複製・改変・配布・再許諾等の許諾がある。§2の表示保持等、§5の商用配布時条件もある。DNG形式の特許許諾とSDK本体のライセンスを混同しない。
- `dng_render.h/.cpp`にはWB白色点、露出、shadow clip、カメラプロファイル、HueSatMap、tone curve、出力色空間等がある。既定curveは`dng_tone_curve_acr3_default`。
- `dng_sdk/source`の`.h/.cpp`では、`Exposure2012`、`Highlights2012`、`ParametricShadows`、`Clarity2012`、`ProcessVersion`の文字列は見つからなかった。

**判断:** 上記の公開APIとソースの範囲から、DNG SDKを現行Lightroomの汎用XMP現像エンジンとして扱うことはできない。一方、DNG/DCPの基準色処理を自社で一から書かずに済ませる候補になる。SDKの許諾が、別途配布されるAdobe Color等のプロファイル資産の再配布まで許諾するとは扱わない。

証跡: `.photobench/engine-research-20260922/`内の取得manifest、LICENSE、readme、render source。

### LibRaw

公式説明はRAWデータの読み出しを主目的とし、製品品質の現像をライブラリの範囲としていない。したがって、これを入れればLightroomの色になるとは説明しない。CDDL §3.6は他コードと組み合わせたLarger Workを扱っているが、Covered Software自体の条件は残る。採用時はバージョン固定、付属依存、改変範囲、表示とソース提供を具体化する。[公式説明・ライセンス](https://www.libraw.org/about)、[CDDL原文](https://github.com/LibRaw/LibRaw/blob/master/LICENSE.CDDL)

### RawTherapee / ART

RawTherapeeはDCP内のtone curveやHue/Saturation関連テーブル等を扱い、AdobeのDCPに合わせる工夫がある。ただし、同マニュアルにもbaseline exposureやblack renderなどの扱いによる差が記載されている。CLIの設定入力はPP3。これをXMP互換と解釈しない。[色管理](https://rawpedia.rawtherapee.com/Color_Management)、[CLI](https://rawpedia.rawtherapee.com/Command-Line_Options)、[公式ソース・GPLv3](https://github.com/RawTherapee/RawTherapee)

ARTは独自に再構成した現像処理を持ち、LibRawやOpenColorIO等にも対応するが、処理設定はARP。評価対象にはなるが、XMP sidecar対応という表示だけでAdobe現像対応と判断しない。[ART公式](https://artraweditor.github.io/)

### darktable

現在の公式FAQは他アプリのpreset非互換を明示し、LRからの現像設定importは限定的と説明する。DCPを必要とする場合にRawTherapee/ARTを案内している。古い「LR XMP import」記事だけを根拠に互換エンジンとして採用しない。[公式FAQ](https://www.darktable.org/about/faq/)

## 推奨する共通モデル

1. **入力を正す:** RAW sensor data、黒/白レベル、As Shot WB、カメラ色変換、プロファイルを扱う。JPEGは既に現像済みなので、RAWと同じ基準処理を二重適用しない。
2. **XMPを共通設定に正規化:** absent / explicit zero、絶対WB / 増分WB、ProcessVersion、カーブ、色混合、空間効果、外部profileを区別する。
3. **各設定を共通演算へ渡す:** 露出、基本階調、point/parametric curve、HSL、grading、texture等。係数は操作のモデルとして共有する。写真名・preset digestによる補正分岐を禁止する。
4. **追加微調整を別層にする:** プリセット適用結果の後にユーザーの明るさ・色温度・色かぶり・彩度を重ね、Undoと保存へ接続する。
5. **出力を一本化:** 同じ演算と色管理でプレビューと原寸JPEGを作る。

単一の3D LUTだけでは、周囲の画素に依存するtextureや局所階調、RAWのデコード・WBまで表現できない。LUTは必要な色変換部分の実装方法として使い、全現像処理の代用とはしない。

## 次の実施順と判定

### 次の調査・試作

- LibRaw＋DNG/DCP候補と既存Core Imageの**プリセットなし基準現像**を比較する。DCP外部資産の入手・利用条件、RW2 metadata連携、baseline exposure、WBを確定する。
- RawTherapee/ARTの独立した現像結果も参考にする。ライブラリ導入だけでLRに一致すると推測して製品を置換しない。
- 自社の共通XMPパラメータと演算順の契約を決め、最初はWB・露出・基本階調の操作別検証を行う。

### 合格してから進む作業

- point/parametric curve、HSL、grading、textureへ対応を広げる。
- 普段の4プリセットに加え、実装調整へ使わなかったpresetと写真で確認する。
- 全体平均の色差、色別の誤差、明暗差、halo、clip、未知設定の扱い、操作速度を評価する。
- NIHO Desktopへ統合するのは共通処理の再現性・日常操作が確認できてから。

現在の3組は検証資産として残す。ただし、1枚目はLRのprofile/レンズ/粒子等の条件差もある。操作ごとの差を測る基準データは別途必要で、取得手順と必要枚数をまとめてからオーナーへ依頼する。

## 未決事項

- LibRawとDNG SDKをどの範囲で接続するか。SDK全体の導入と、必要な色処理部品のみの利用を比較する。
- 再配布可能なカメラprofileと、ユーザー所有profileの扱い。
- LRと同じ値に対する非公開演算の再現精度。構造を共通化することと、LRと同じ画質が得られることは別々に検証する。
- 初期対応範囲と工数。現段階で「任意のXMPを完全互換」とした納期は提示しない。
