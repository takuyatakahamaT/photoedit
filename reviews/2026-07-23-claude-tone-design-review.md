# Claudeトーン設計レビューと採否

- 実施日: 2026-07-23
- 方式: `claude-review` / Claude Code CLI / Opus 4.7 / read-only / deep repository review
- Fable: 指定モデルを試したが、この環境では`model_not_found`だったためOpusへ切替
- 対象: Lightroom XMP近似、基本階調、HSL/curve、校正方法

## 結論

Claudeの中心提案は「長期的には解析モデルと測定残差のhybrid。ただし2組しかない現状では解析モデルだけを採用し、プリセット専用3D LUTを学習しない」だった。この判断を採用した。

現在の2組は同じ`colorful`設定を別シーンへ適用したものなので、個々のスライダー応答や未観測色を同定できない。最低5〜10独立シーンとleave-one-image-out検証が揃うまでは、Lightroom互換ではなくclean-roomの暫定近似として扱う。

## 採用して実装した指摘

| 指摘 | 対応 |
|---|---|
| Highlights / Shadows / Whites / Blacksが編集モデルにない | `EditSettings`、XMP解析、8本のUIスライダー、レンダーへ追加 |
| channel curveとglobal curveの順序が逆 | channel curve → global curveへ修正 |
| 既存Contrastはlinear空間の単純乗算 | 独自の単調な基本階調`analytic-monotonic-hdr-basic-tone-v3`へ移動 |
| 32³ LUTは精度不足 | 64³へ拡張し、curve/HSL設定だけをキーにキャッシュ |
| HSL重み付けがバンド中心の強度を薄める | 隣接色バンドの区分線形補間へ変更 |
| 無彩色にHSL色かぶりが出る | chroma 0.025以下を不変、0.10までsmoothstepで適用量を増加 |
| 校正がtrain=test | 2画像をGo判定へ使わず、追加データとleave-one-image-outを採用条件に明記 |
| 同一URL exportのエラーが曖昧 | `sourceOverwriteForbidden`専用エラーと回帰テストを追加 |
| 未校正なのに互換と誤認し得る | UIへ`XMP近似・未校正`表示を追加し、HSL/curveは初期OFF |

## 一部採用・後続へ送った指摘

- WBは`As Shot`、絶対Temperature/Tint、増分値、明示的0を区別して解析・保持するところまで実装した。プリセット適用時にRAWを再decodeする設計と、非RAWの色順応を同じ式に見せるのは危険なため、レンダーは追加基準が揃うまで未実装とした。
- 基本階調はPCHIPそのものではなく、toe、bounded midtone warp、shoulder、pivoted contrast、HDR shoulderを合成した解析式にした。0〜4 HDR、各極値、複合値で有限・単調、CPU/software/Metalの一致をテストする。
- 64³ cubeは現時点でcurveとHSLを同居させている。段階別測定で硬いclip増加を確認したため初期OFFを維持し、HDR対応1D tone、知覚空間HSL、soft-knee色域マッピングへ分離する。
- 実行時CIKLはdeprecatedだが、`.ci.metal`のコンパイル、SwiftPM resource、完成`.app`へのmetallib同梱を一括検証する専用スライスへ分離した。kernel生成・適用失敗は黙って無視せずfail-fastにした。

## 採用しなかった指摘

- 2画像からプリセット固有3D LUT、カメラ固有affine、局所処理強度をfitする案は採用しない。未観測シーンでの破綻を測れないため。
- すべての比較を6000×4000原寸だけで行う案は、反復校正の計算量が大きいため現段階では採用しない。Lightroom参照と候補を同じSwift経路で長辺1500pxへ正規化し、shape一致を強制してCIEDE2000を測る。原寸、ゼロぼかし、100%解像感は最終Go判定で追加する。
- 数値だけを合わせるために2画像へ応答定数を追加調整することは採用しない。

## 残るblocking事項

1. 未校正HSL/curveで高彩度ハイライトの完全clipが増える。
2. XMP WBレンダー、Adobe Color/DCP、レンズ補正、Adobe独自PV2012処理が未実装。
3. 2シーンでは各スライダーの応答を識別できず、プロ用途の合否を出せない。
4. 肌色、ColorChecker、ハイライトEV、100%解像感を含む5〜10シーンのゴールデン回帰が必要。

詳細な測定値と再現手順は`CALIBRATION.md`、調査根拠は`RESEARCH.md`に記録する。
