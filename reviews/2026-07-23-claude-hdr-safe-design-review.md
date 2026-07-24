# HDR-safe output transform: Claude 設計レビュー

- 実施日: 2026-07-23
- レビュー種別: 実装前（Claude Opus、read-only）
- 対象: `2026-07-23-hdr-safe-output-transform-design.md`
- 判定: **PROCEED WITH CHANGES**

## 採用した指摘

1. 3D `CIColorCube` の外挿へ依存せず、トーンカーブとカラーミキサーを独立した明示的な関数に分離する。
   - カーブは encoded sRGB 上で評価し、端点の傾きを使って外挿する。
   - カラーミキサーは linear sRGB ↔ OKLab/OKLCh の専用カーネルとする。
2. 出力変換を highlight shoulder と gamut compression の2段に分け、CPU参照実装とGPU実装を個別にテストできる境界にする。
3. shoulder の制御値は輝度だけにしない。`[2, 0.1, 0.1]` のような飽和ハイライトも確実に収めるため、最大チャンネルを含める。
4. OKLCh の gamut compression は固定明度・固定色相で sRGB 境界を二分探索し、soft knee 後に小さな安全余白を置く。途中で明度を安易に clamp しない。
5. neutral bypass は「有界な sRGB ラスター入力」かつ「許容誤差内の neutral settings」に限定する。RAW は neutral settings でも出力変換を通す。
6. RAW decoder から実際に 1.0 超の値が届くことを計測する。届かなければ後段だけでなく上流の gamut mapping 方針を再検討する。
7. 実写2組の相対比較だけでなく、HDR ray・飽和色・透明度を含む synthetic test を主ゲートにする。plateau の絶対上限、平均露出ドリフト、CPU/GPU一致を検証する。
8. alpha は unpremultiply → 色変換 → premultiply を明示する。

## 再検証で訂正した指摘

初回レビューには「OKLab の L/a/b 全成分を `2^(adjustment/300)` 倍すると、RGBでは +3EV 相当になる」という指摘があったが、独立検算で誤りを発見したため同じ Claude Opus に数式を限定して再レビューした。再レビューは **CORRECTION REQUIRED** とし、初回指摘を撤回した。

正の線形RGBゲイン `g` に対して OKLab は立方根の斉次性を持つため、

`OKLab(g × RGB) = cbrt(g) × OKLab(RGB)`

である。したがって L/a/b の3成分すべてを同じ `k = 2^(adjustment/300)` で拡大すると、逆変換後は `k^3 = 2^(adjustment/100)` のRGBゲインとなる。`adjustment = 100` は正しく +1EV で、色相とRGB比も数学的に保存される。この換算は維持する。

## 今回の実装境界

- 実装する: 1D tone curve、OKLCh mixer、HDR shoulder、OKLCh soft gamut compression、RAW headroom 診断、synthetic gate、既存2シーンの比較ゲート。
- 後続へ送る: Metal 化、2D Cmax LUT、Display-P3/HDR export、5〜10シーンの manifest/leave-one-scene-out 校正。
