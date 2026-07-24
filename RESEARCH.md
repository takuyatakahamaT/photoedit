# RAW写真編集アプリ調査と採用判断

- 調査日: 2026-07-23、画質・性能設計追補: 2026-07-24
- 目的: 個人用macOS写真編集アプリで、プロ用途の色・階調・解像感と17,000枚規模の操作性を両立する
- 方針: 公式文書と成熟OSSの設計を参照するが、GPL/AGPL実装コードはコピーしないclean-room開発

## 結論

UIとアプリ基盤はSwiftUI/AppKit、画像処理はMetal-backed Core Image、RAWは交換可能な`ImageDecoding`境界の内側でCore Image RAW 8をDC-S5向けに暫定採用する。XMPはAdobeの命令形式として解析するが、Adobe Camera Rawの画そのものではない。色の合否は、手元のLightroom 16bit TIFFを正としてCIEDE2000、肌色、クリップ、解像感を継続測定する。

manifest v4の最終レポートでは、RAW / Lightroom入力の4経路すべてで`full`の平均ΔEが`basic`より改善し、complete clipとnear clipは全候補0、新規共有plateauも上限`0.0005`以内だった。一方、P1524180 / RAWの平均EV差だけは`+0.003839 → +0.207869 EV`となり、上限`0.05384 EV`を超えた。目視でもLightroom-afterより明るく、暖色・マゼンタと青の彩度が強い。したがって出力安全性の改善をLightroomの画作りの再現とはみなさない。

preview parity v4では、原寸・3,072px・3,840px RAW decodeへ同じ編集を適用してfinal 2,560pxへ揃えた。3,072pxは2 / 6、3,840pxは4 / 6比較でspatial plateau上限を超え、候補なし・full-resolution decode fallbackとなった。canonical settleは **extended-linear-sRGB edits → edge-clamped Lanczos downsample → terminal sRGB transform** を固定し、2 development sceneでcomplete / near clip `0 → 0`と新規plateau上限内を確認した。独立holdoutはなく、未知sceneへの一般化ではない。

RAW WBは、製品挙動を変えない開発専用runnerでAs Shot / custom neutralの固定18候補を2 development sceneへ適用し、再現可能な正式観測を取得した。中心customはAs Shotと平均ΔE `0.000151 / 0.000323`で数値的に極めて近かったがbyte exactではなく、Lightroom As Shotとの差は平均ΔE `3.6660 / 2.1292`残った。これはWB、Adobe Standard、camera profile、decoder等の複合差を含み得る。Lightroom teacher sweepもsealed holdoutもないため、候補順位・変換式・production採用は決めていない。

[`reviews/2026-07-24-claude-research-improvement-proposals.md`](reviews/2026-07-24-claude-research-improvement-proposals.md)は、外部調査に基づく優先順位と技術候補の助言資料として参照する。Lightroomは当面継続するため、解約前退避を急ぐより、教師として使える期間にWB・profile・tone / colorを層別して品質差を潰す。一方、linear RAW土台、DCP、preview cache、draft / settle、SSIMULACRA2、制約付きLUT、初回遅延原因などの個別主張は未検証で、仕様や合格証跡にはしない。

## Adobeの仕様から分かること

[AdobeのProcess Version説明](https://helpx.adobe.com/ie/camera-raw/using/process-versions.html)はPV2012系でHighlights、Shadows、Whites、Blacks等を使うことを示し、[LightroomのTone controls](https://helpx.adobe.com/lightroom-classic/desktop/help/tone-control-adjustment.html)は主な影響域を、Blacks 0〜10%、Shadows 10〜30%、Exposure/Contrast 30〜70%、Highlights 70〜90%、Whites 90〜100%として説明している。しかしレンダー数式、Adobe Colorのプロファイル本体、内部処理順は公開していない。

[Adobe Camera Raw namespace](https://developer.adobe.com/xmp/docs/xmp-namespaces/crs/)はXMPプロパティの名称と型を定義する。よって「XMP値を正しく読める」と「Lightroomと同じ色になる」は別の受け入れ条件にする。[AdobeのProfile / White Balance説明](https://helpx.adobe.com/lightroom-classic/desktop/process-and-develop-photos/image-tone-color.html)も両者を別の基本制御として扱う。Photo BenchはWB値を解析・保持し、製品経路とは分離したrunnerでRAW neutral候補を観測できるようになったが、camera profile / DCPはなく、productionレンダーにも未接続である。したがって現時点の色差をtoneだけ、またはWBだけで解決しようとしない。

## Appleの一次資料から分かること

[Apple `CIRAWFilter.extendedDynamicRangeAmount`](https://developer.apple.com/documentation/coreimage/cirawfilter/extendeddynamicrangeamount)は、`0`をEDRなし、`1`を既定のEDR、`2`を最大EDRと定義している。DC-S5の2 RAWではEDR 1がEDR 2の`> 1`画素領域の約96.3% / 93.8%を回収しながら最大値の伸びを抑えたため、Make/Model一致時だけ`boost = 0.9`、EDR 1を使う。これはAppleの一般推奨を機種横断の校正値と解釈したものではなく、DC-S5実画像で限定検証したプロファイルである。

Appleは`CIRAWFilter`に[`neutralTemperature`](https://developer.apple.com/documentation/coreimage/cirawfilter/neutraltemperature)、[`neutralTint`](https://developer.apple.com/documentation/coreimage/cirawfilter/neutraltint)、[`neutralChromaticity`](https://developer.apple.com/documentation/coreimage/cirawfilter/neutralchromaticity)をRAW decode時のneutral制御として公開している。Photo BenchはAs Shotではdelegateの状態を変更せず、custom候補ごとにfresh filterを作る。2 development scene×18固定候補の正式観測は構造・hash・release provenanceに合格したが、LightroomのTemperature / Tint教師sweep、gray基準、領域別指標、sealed holdoutがないため、候補順位やAdobe→Apple変換を導出しない。

[Apple extended linear sRGB](https://developer.apple.com/documentation/coregraphics/cgcolorspace/extendedlinearsrgb)は、linear sRGB primaries / white pointを使いながら0未満と1超の成分を表現できる。Photo Benchは[`CIContext`のworking color space](https://developer.apple.com/documentation/coreimage/cicontext/workingcolorspace)にこれを明示し、[output color space](https://developer.apple.com/documentation/coreimage/cicontextoption/outputcolorspace?language=objc)をsRGBとして分離する。RAW decode後から縮小まで拡張値を保持し、表示とJPEG/TIFFの境界でだけbounded sRGBへ収容する。

性能面では、Appleの[`CIRAWFilter.scaleFactor`](https://developer.apple.com/documentation/coreimage/cirawfilter/scalefactor)は縮小RAW出力を作る手段だが、原寸decode後縮小との色・階調同等性までは保証しない。[Appleの対話RAW設計例](https://developer.apple.com/videos/play/wwdc2026/305/)も対話表示でscale factorと再利用contextを使い、exportでは別contextと原寸処理を使い分ける。Photo Benchもpreview / exportを別`CIContext` instanceへ分離したが、実測で画質gateを外したscale factor候補は採用しない。

v4ではAppleの高品質縮小[`CILanczosScaleTransform`](https://developer.apple.com/documentation/coreimage/cifilter-swift.class/lanczosscaletransform%28%29)をterminal transformより前へ置く。有限`CIImage`の外側は透明黒として評価されるため、[`clampedToExtent()`](https://developer.apple.com/documentation/coreimage/ciimage/clampedtoextent%28%29)でedge pixelを延長してから縮小し、exact extentへcropする。Core Imageは[遅延評価graph](https://developer.apple.com/documentation/coreimage/processing-an-image-using-built-in-filters)なので、ノード順だけでなく最終rasterをテストする。旧v3 archiveの縮小後clip増加とv4 canonical passを対に保存し、処理順の回帰を検知する。

plateau比較は、面積差だけでなくfinal raster上のsquare-3x3 dilationを使い、斜めを含む1px境界移動と、それより外側に生じた領域を分けた。これは物体境界で領域IoUとは別の境界感度が必要だとする[Boundary IoU研究](https://openaccess.thecvf.com/content/CVPR2021/html/Cheng_Boundary_IoU_Improving_Object-Centric_Image_Segmentation_Evaluation_CVPR_2021_paper.html)を参考にしたPhoto Bench固有の許容であり、論文の閾値を流用したものではない。最大connected component、最悪128×128 window、Chebyshev距離histogramも保存するが、scene数が不足するため現時点では診断値とし、結果を見てhard thresholdを後付けしない。

最新のarchived v4 formal benchmarkは、process-fresh `357.990 ms`、warm high-quality `58.023 ms`、原寸JPEG `225.922 ms`が合格し、warm slider `55.649 ms`だけが50ms gateを超えた。ただし1 runだけで、WB観測source追加前のmanifest / sourceへ固定され、現行HEADとはfingerprintが異なる。したがって安定性も現行sourceの性能合否も証明しない。旧v3の連続3 runは履歴として残すが、v4の反復へ混ぜない。[Google Benchmarkの反復・warm-up指針](https://google.github.io/benchmark/user_guide.html)を参考に全sampleを保存し、遅い値をoutlierとして削除・再試行しない。

画質不採用の縮小decodeを前提にせず、[Core Image render destinationの公式例](https://developer.apple.com/documentation/coreimage/generating-an-animation-with-a-core-image-render-destination)に沿ってproductionのfull-decode graphをMetal-backed destinationへ直接描画するopt-in経路を実装した。最終ハードニング直前の詳細traceではGPU commandは完了したが、初回は[`presentedTime`](https://developer.apple.com/documentation/metal/mtldrawable/presentedtime)が0、再試行はpresented callbackが返らず、実画面提示を確認できなかった。その後に`drawableSize > 0`のwatchdog条件と`allowsNextDrawableTimeout = true`を追加し、最終sourceではfallback画像と空表示がないことを再確認したが、同じ詳細traceは再取得していない。Appleが示すとおり[`MTKView.currentDrawable`](https://developer.apple.com/documentation/metalkit/mtkview/currentdrawable)はnilになり得るため、再試行・可視性・10秒deadline・一方向fallbackを実装したが、positive presentationなしに成功とは判定しない。

次の性能研究候補には、操作中の暫定表示と停止後の高品質settleを分ける案、zoomed-out表示とは別に100% detail windowを持つ案がある。[darktableのpixelpipe](https://docs.darktable.org/usermanual/development/en/darkroom/pixelpipe/the-pixelpipe-and-module-order/)は対話中に処理量を減らすpipeを、[RawTherapeeのdetail window](https://rawpedia.rawtherapee.com/Editor)は縮小表示で省く重い処理を小さな100%領域で確認する設計を示す。Photo Benchではこれらをそのまま移植せず、zoomed-out応答、高品質settle、100% detail、原寸exportを別々に受け入れ判定する。Metal直接表示の追加調査はpositive presentationとlifecycle reducerの1スライスにtimeboxし、成立しなければ既定legacyのまま製品機能へ進む。

[`CIContextOption.cacheIntermediates`](https://developer.apple.com/documentation/coreimage/cicontextoption/cacheintermediates)は似た後続renderを速くできる一方で中間bufferを保持する。cacheを試す場合はpreview contextだけに限定し、[`reclaimResources`](https://developer.apple.com/documentation/coreimage/cicontext/reclaimresources%28%29)と写真切替後の定常RSS gateを同時に導入する。`MTKView`はsRGB / SDRと対応8-bit unormを明示し、Metal非対応時は現行経路へ戻す。[`os_signpost`](https://developer.apple.com/documentation/os/logging/recording_performance_data)とInstrumentsのMetal System Traceでinput-to-screen / hardware GPU / readback / dropped frameを分離する。CIKLからpackaged Metal kernelへの移行だけでは50ms gateと再現性の両方を解消しない。

## 参考にした実装

### darktable

[darktable](https://github.com/darktable-org/darktable)は、RAW原本をread-onlyで扱う非破壊現像、SQLiteライブラリ、XMP sidecar、GPU処理、複数キャッシュ、マスク、書き出しを持つ成熟例である。公式の[sidecar設計](https://docs.darktable.org/usermanual/development/en/overview/sidecar-files/sidecar/)は編集履歴を原本と分けて可搬にし、[storage設定](https://docs.darktable.org/usermanual/development/en/preferences-settings/storage/)はライブラリDBとsidecarの役割を分ける。[tone equalizerの公式説明](https://docs.darktable.org/usermanual/development/en/module-reference/processing-modules/tone-equalizer/)では、scene-linear RGB、EV領域、edge-awareなguided filterを使い、局所コントラストを保ちながら階調帯を調整する。

[darktable sigmoid](https://docs.darktable.org/usermanual/development/en/module-reference/processing-modules/sigmoid/)と[darktable AgX](https://docs.darktable.org/usermanual/development/en/module-reference/processing-modules/agx/)は、scene-referred値をdisplay-referred範囲へ連続的に写す際、ハイライトの色相・彩度・局所コントラストが設計上の論点になることを示す。Photo Benchはこれらの数式やlookを移植せず、「中間HDR値を保つ」「出力境界で連続圧縮する」「toneとgamutを分離して回帰測定する」という原則だけを採用した。

採用する原則:

- 原本を変更せず、編集レシピだけを保存する。
- 内部はfloat、8bit化は表示/JPEGの最後だけにする。
- SQLiteを高速検索・現在状態の正、sidecarを原本と一緒に持ち運べる冗長バックアップにする。片方だけへ依存しない。
- サムネイル、操作中プレビュー、原寸書き出しを別解像度・別キャッシュにする。
- 長期的な局所階調は、単純なグローバル曲線ではなくscene-referred + edge-aware方式を比較する。

### RawTherapee / LibRaw

[RawTherapeeのtone equalizer実装](https://github.com/RawTherapee/RawTherapee/blob/039b9b89d43315be6b42e8fbb33b8cfb39edd4bf/rtengine/iptoneequalizer.cc)も、log/EV領域の帯域補正を行う成熟例である。GPLコードはコピーせず、出力品質と設計上の比較対象にだけ使う。

[LibRaw](https://www.libraw.org/docs)はApple未対応カメラやCore Image回帰時の差し替え候補。ただしLibRawだけでAdobe Colorにはならず、DCP、WB、デモザイク、ハイライト復元、ノイズ低減、レンズ補正、色管理を一式構築する必要がある。現時点で即時移行する合理性はない。

### RapidRAW

[RapidRAW](https://github.com/CyberTimon/RapidRAW)は、Rust + Tauri + WGPU/WGSLで非破壊編集、クロップ、複数マスク、ROIレンダー、LRUキャッシュ、遅延サムネイル、アルバムを持つ、個人開発のLightroom型アプリ例である。GPUへ処理グラフを集約し、表示範囲・表示解像度だけを高速更新する方針を参考にする。

AGPL-3.0なのでコードは取り込まない。同プロジェクトの[Lightroom XMP import議論](https://github.com/CyberTimon/RapidRAW/issues/533)でも、XMP値を読めても現像エンジンが違うため100%同じ画像にはならないという判断が示されている。

## 現在の画像処理

| 領域 | 現在 | 判定 |
|---|---|---|
| RAW | Core Image RAW 8 + `panasonic-dc-s5-lightroom-9.3-edr1-v2`（boost 0.9 / EDR 1） | RAW 8が利用可能でMake/ModelがDC-S5のときだけ使用。他機種はgeneric未校正へ戻し、値を流用しない |
| 作業コンテキスト | extended linear sRGBのMetal-backed `CIContext` | 表示・JPEG/TIFF出力はsRGB。Display P3は未実装 |
| 基本階調 | 露出後、輝度をsRGB transferへ写し、5調整を共通RGBゲインで適用 | `analytic-monotonic-hdr-basic-tone-v3`。Adobe数式ではない |
| curve | encoded-sRGB 1D区分線形曲線。0〜1外は有限な正の端点傾きで外挿 | XMP点列のclean-room近似。実験扱いで初期OFF |
| color mixer | OKLCh 8バンドでhue / chromaを環状補間し、効果量100%のLuminanceを`+100 = +1 EV`の局所露光として適用。相対chromaで低彩度を保護 | Adobe HSLの内部処理とは異なる。実験扱いで初期OFF |
| WB | XMPのモード・絶対値・増分値を保持し、開発runnerでAs Shot / custom neutralを固定観測 | 2sceneの観測構造だけが成立。順位・変換式・製品preview / export / persistence / Undoは未実装 |
| resize / 出力変換 | extended-linear編集 → edge-clamped Lanczos → terminal sRGB transform | terminal nodeはmax-channel C1 shoulder + OKLCh固定L/h gamut compression。bounded-sRGB neutral入力はbypass |
| ファイル出力 | 原寸sRGB JPEG、比較用16bit sRGB TIFF | 原本上書きなし、JPEGはatomic install |

## 基本階調モデルの判断

Adobeの非公開式を推測して複製せず、toe、bounded midtone warp、shoulder、pivoted contrast、HDR shoulderという単調プリミティブで構成した。0〜1内の端点と順序を保ち、露出で1を超えた値も負のHighlights/Whitesで回収できる。0〜4の入力、各±100、複合極端値で有限・単調、CPUと実Core Imageカーネルが2e-5未満で一致することをテストする。

2シーン専用3D LUTやカメラaffineは、見かけのΔEを下げても未観測色・未観測照明で破綻する可能性が高いため採用しない。最低5〜10独立シーンのleave-one-image-outで改善が確認できるまで、機種固有補正を追加しない。

長期的には、[Guided Image Filtering論文](https://mmlab.ie.cuhk.edu.hk/2010/eccv10_Guided.pdf)のようなedge-preserving filterを用いた、scene-referred/log EVの局所階調へ進む余地がある。ただしグローバル調整との役割、halo、GPU負荷を基準画像で比較してから採用する。

## ハイライトと色域の判断

現行処理はtone、色編集、出力収容を分離する。カーブはencoded-sRGBの1D曲線とし、HDR端点を最後のsegment傾きで外挿する。XMP HSLは[Björn OttossonのOKLab / OKLCh一次資料](https://bottosson.github.io/posts/oklab/)を基礎に、8色バンドを知覚空間で補間する。LuminanceはOKLabの斉次性からlinear RGBの局所露光へ定義し、`+25 = +0.25 EV`を単独fixtureで検証する。ただしAdobeのHSL処理を再現したものではなく、この既知差を画像EV gateの補正理由には使わない。

最終出力では、最大チャンネルから求めた圧縮率をRGB全体へ掛け、チャンネル比を保つ。shoulderは`knee = 0.99`、`ceiling = 0.998`、`softness = 0.008`で、接続点の値と一次微分が連続するC1曲線である。その後もsRGB外にある色だけ、OKLChのlightness Lとhue hを固定してchroma Cを圧縮する。

[ACES Reference Gamut Compression](https://docs.acescentral.com/rgc/overview/)は、入力色域外や不安定な高彩度値を出力過程で扱う必要性を整理している。また[ACES Chroma Compression](https://docs.acescentral.com/system-components/output-transforms/technical-details/chroma-compression/)は、lightnessとhueを固定してchromaを圧縮する設計を説明する。Photo BenchはACES変換や定数を実装したものではなく、toneとgamutを分け、L/hを動かさずCを境界へ収める設計原則だけを参考にした。

実レンダーの数値契約は、[W3C CSS Color 4のΔEOK](https://www.w3.org/TR/css-color-4/#deltaEOK)を使う。RGBAf / CIKLの単精度OKLab変換は、LMS成分がゼロ近傍を横切る極端な色域外入力で条件が悪化する。signed cube rootの正則化は広い色相ずれと追加逆行を生んだため採用しない。代わりに、mixer単独の最大操作から導く`C/Cmax <= 2`を運用域、global saturationまで重ねた`<= 4`をstress域とし、67,368点でΔEOK、L、色相、最大彩度逆行、boundednessを別々に監視する。これは2実写へ合わせた閾値ではなく、編集controlの定義と1 JND約0.02から導いた保守的な契約である。

bounded sRGB内の通常画像でカラー編集がneutralなら、最終出力変換そのものをbypassする。すでに安全なJPEG等を再マッピングしないことも、HDRを収容することと同じく品質要件である。

最終レポートでは4経路すべてでcomplete / near clip非回帰、ΔE、新規共有plateauのゲートを通過した。一方、P1524180 / RAWのfull平均EV差`+0.207869`は許容上限`0.05384`を超える。安全な出力収容は成立したが、実験的HSL/curveの事業品質は未達であり、初期OFFを維持する。

## Core Image kernelの移行判断

現在の独自画像kernelは実行時CIKL `CIColorKernel(source:)`を使っており、APIはdeprecatedである。ただし今すぐMetalへ置換すると、CI用Metalの`-fcikernel` / `-cikernel`、SwiftPM resource bundle、完成`.app`へのmetallib同梱を同時に変更することになる。色校正スライスへ混ぜず、専用スライスで次を満たして移行する。

1. `.ci.metal`をCore Image用フラグでビルドする。
2. `CIColorKernel(functionName:fromMetalLibraryData:)`でロードする。
3. kernel欠落時に処理を黙ってスキップしない。
4. 4097段階の0〜4 HDRランプでCPUとの誤差を2e-5未満に保つ。
5. 完成`.app`を`.build`外へ置いて起動し、resource同梱とcodesignを確認する。
6. 移行前後のLightroom TIFF比較を一致させる。

[AppleのCore Image Metal解説](https://developer.apple.com/videos/play/wwdc2021/10159/)と[Swift package resources](https://developer.apple.com/documentation/xcode/bundling-resources-with-a-swift-package)を実装根拠にする。現行コードもkernel生成・適用失敗を黙って無視せず、明示的に停止する。

## macOSのフォルダ権限と署名

[AppleのApp Sandboxファイルアクセス](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)に従い、写真ルートは`NSOpenPanel`でユーザーが選んだURLだけを対象にする。App Sandboxのuser-selected read/writeとapp-scoped bookmarksを有効にし、[security-scoped bookmark](https://developer.apple.com/documentation/professional-video-applications/enabling-security-scoped-bookmark-and-url-access)を次回起動へ保存する。[`startAccessingSecurityScopedResource()`](https://developer.apple.com/documentation/foundation/url/startaccessingsecurityscopedresource%28%29)で復元URLの利用期間を明示し、Panelによる暗黙の開始も含めて終了時に対応するstopを一度だけ呼ぶ。

この設計により、初回起動は固定のDocumentsパスを自動走査せず、許可済みの同じ`.app`を再起動したときだけフォルダを自動復元する。破損・失効bookmarkは削除して再選択へ戻し、外付けSSDが一時的に見つからないケースは権限を削除しない。`NSDocumentsFolderUsageDescription`と`NSRemovableVolumesUsageDescription`もアプリへ一つずつ記載する。

既定buildはApp Sandbox付きad-hoc署名とした。手元で見つかった別組織のApple Development証明書は個人アプリへ流用しない。[Apple TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)が説明するdesignated requirementの性質上、ad-hoc署名はアプリを再ビルドすると同一性が変わり、保存済み権限の再選択が必要になる場合がある。現状はこれを安全な既知制限として表示し、ユーザー自身の署名identityを明示指定した場合だけ安定署名へ切り替える。

## 測定規格

色差はSharmaらの[CIEDE2000定義](https://hajim.rochester.edu/ece/sites/gsharma/papers/)を実装し、全画面だけでなく中間調と低ディテール領域も保存する。さらに未ぼかし16bit TIFFからcomplete / near clipを測り、basic/full共有ハイライトに新たに生じたplateau、linear-sRGB輝度の平均EV差もfail-closedで判定する。preview parity v4はぼかし後ΔE00 p95、signed plateau面積差、1px dilation外面積もhard gateとし、canonical settleは縮小後の整数clip countを別gateにする。単一の平均ΔEだけでは、肌、局所クリップ、ノイズ、シャープネス、色相回転を評価できないため、最終Go判定では領域別ΔE、EV、ハイライト階調、100%表示の解像感、複数ディスプレイでの目視を併用する。

現行の自動回帰はSwift Testing `119 tests / 10 suites`、Python calibration analyzer `61 tests`、Python WB observation analyzer `17 tests`である。従来のtone / color / decode / evidence契約に加え、旧 / 新graphの識別、edge-clamped Lanczos、縮小後terminal transform、canonical settleの整数clip count、fresh RAW WB filter、固定18候補、private data / provenance / no-replace契約と欠測時fail-closedを検証する。Metal直接表示のactual present lifecycle、production WB、camera profile / DCP、独立holdout品質は未検証である。

## 次の優先順位

1. LightroomのTemperature / Tint教師sweep、gray card / ColorChecker、領域別指標を追加し、観測済みRAW WB候補をWB・baseline exposure・profile差へ分解する
2. 5〜10以上の探索sceneと最低2 sealed holdoutを追加し、事前登録gateを通ったWBだけをlatest-only decode、preview / export一致、永続化、Undoと一体で製品へ接続する
3. 編集値の再起動後復元とSQLiteカタログを実装し、原本・正本DB・再生成可能cacheを分離する
4. crop / rotate、100% detail、sharpening、noise reduction、lens correctionをpreview / export共通契約で実装する
5. 現行full-decode UIのinput-to-presentを測り、Metal直接表示はpositive presentationを得られる範囲だけtimeboxして比較する
6. 埋め込みJPEGを使う選別、評価、pick / rejectを実装し、17,000枚で起動・送り・scrollを測る
7. 複数校正runを安全に扱う前にcross-process lockを追加する
8. profile結果に必要性が示された場合だけCIKLをpackaged Metal kernelへ移行し、その後に非AIブラシを進める
