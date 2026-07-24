# Photo Bench P1 証跡・安全性 Claude 最終レビュー

- 実施日: 2026-07-24（JST）
- reviewer: Claude Opus 4.7 Max
- job ID: `paneB-3-photo-p1-final-review`
- 実行方式: `claude-review` skill、read-only（`Read` / `Grep` / `Glob` のみ）
- 対象: `/Users/takuyatakahama/Documents/app/NIHO/others/photo`

## 結論

Claude の判定は **blocking なし**。P1 の preview / export intent 分離、原寸 export guard、fail-closed の品質・構造 gate、証跡保存、scaled RAW preview の UI 未採用という判断は、コードと evidence の範囲で honest かつ安全に成立している。

レビューで挙がった Should 5 件のうち S1〜S4 は Codex が修正した。S5 は提案どおりの寸法 assertion を入れると、意図した `3,072 / 3,840 px decode → 2,560 px 表示` の oversampling を誤って拒否するため、preview parity v3 の契約として再定義して次段へ送る。

## Claude の Should 指摘と対応

### S1: native size 不明時の fail-close

Claude は、RAW decoder が native size `0` を返した場合に一致検査を通過し得る点を指摘した。

**対応済み**。decoder で native width / height の正・finite を要求し、export guard でも native size と実 image extent の正・finite・一致を再検査する。未知、ゼロ、NaN、infinity を full-resolution export として扱わないテストを追加した。

### S2: preview / export の `CIContext` 分離

Claude は、同じ `CIContext` を共有したまま preview cache を有効化すると、export の再現性へ影響し得る点を指摘した。

**対応済み**。1つの再利用可能な `RenderEngine` が、別インスタンスの `previewContext` と `exportContext` を保持する構造へ変更した。現段階は両方とも `cacheIntermediates: false` で、benchmark も製品と同じ topology を測る。context が別 identity であることをテストした。

### S3: benchmark workload 名の曖昧さ

Claude は、schema v2 の `raw-warm-full-preview` における `full` が「full preset / settings」を意味し、full-resolution decode と誤読し得る点を指摘した。

**方針確定**。既存 archive との互換性のため schema v2 の machine ID は変更しない。人向け文書では decode intent と workload の意味を glossary / 表示名で分離する。ID 自体の変更は、実 UI workload を導入する schema v3 で行う。

レビュー後の最終整合監査で、原寸JPEG workloadの説明が実装と異なり`export-only RenderEngine`と記録されていた点も修正した。実装どおり「同じ再利用`RenderEngine`のexport contextと、独立した原寸RAW decode」とし、source / binary hashを更新して校正とbenchmarkを再生成した。この説明文修正は画像処理ロジックを変えていないが、Claudeのread-only review後の変更なので、以下はCodexによる再検証証跡である。

### S4: benchmark の exit code 意味論

Claude は、`notEvaluated` が数値不合格と同じ exit `1` になる点を指摘した。

**対応済み**。判定を `pass` / `performanceFailed` / `notEvaluated` に分離し、`--enforce` では合格 `0`、正しく評価された数値不合格 `1`、構造・実行・provenance 不整合または評価不能 `2` とした。未知の CLI flag も exit `2` になる smoke test を確認した。非 enforce の診断実行は証跡合格を意味しない。

### S5: scaled decode と表示寸法の整合検査

Claude は、scaled decode の requested maximum dimension と `renderPreview` の要求寸法の不整合を検出する assertion を提案した。

**提案の目的を採用し、具体案は v3 へ再定義**。単純な `render maxDimension >= decoded width` 制約は、`3,072 / 3,840 px` で decode して `2,560 px` へ縮小する意図的 oversampling を拒否する。v3 では最終出力 `2,560 px` と decode 候補寸法を別フィールドで記録し、画質 parity、plateau、crop、性能を一体で検証する。

## Codex 側の最終証跡

### 校正

- run ID: `4f3acc34-907b-4b95-b77d-fd2e10ddbf3a`
- source fingerprint: `1e422e30355f7b043b55bab2e0903bbb2f58c161ebcddb5307b60329466e106a`
- debug binary SHA-256: `1a69cc521042858367d2b15557ef300d90b2aed67158cb355b4da3d9486e8af7`
- artifact validation: `116 / 116`
- quality gate: `false`
- preview parity gate: `false`

構造・hash 検証は完了しているが、既知の Lightroom 画質差と preview plateau gate が不合格であり、scaled preview の UI 採用根拠にはしていない。

### Benchmark

- 最新 run ID: `aade27ac-672f-4b71-b501-697a2b65a0f0`
- release binary SHA-256: `cbed5d7ad03978b66e1e9722f930112bd5fcc2b18864ee911ced8970e6fad2bd`
- 最新結果: `2 / 4` performance gates 合格、全体は不合格
- 同一 source の直前 run: `ec8d16e3-88ff-4d15-9464-2181d82e3163`、`1 / 4`合格で全体は不合格

両runともthermal stateは`nominal`、low power modeは無効だったが、warm workloadとprocess-freshが大きく振れ、現sourceでは性能gateを通らなかった。バックグラウンド負荷、sample 数、GPU / readback内部区間を含む再現性が残存リスクである。実 UI の input-to-screen latency、drop frame、複数写真後の定常 RSS は未測定のため、engine benchmark で代用しない。

### Build / test

- `swift test`: 83 tests 成功
- `python3 scripts/test_analyze_calibration.py`: 38 tests 成功
- release app build: 成功
- `codesign --verify --deep --strict`: 成功

Claude は read-only review だったため、これらの live test、benchmark 再実行、build、codesign は Codex が別途確認した。

## 残存リスクと次の判断

- scaled RAW preview はまだ実 UI に接続しない。
- preview parity v3 は、oversampling 候補、plateau の面積純増と 1 px dilation 外の新規領域、合成 fixture を正式契約にする。
- `CIContext` の preview cache、メモリ上限、写真切替時 eviction は未実装であり、複数写真 workload と RSS gate が必要。
- Core Image RAW pipeline は macOS 更新で変動し得るため、runtime provenance と再校正を継続する。
- 2 scene の結果だけでは Lightroom 同等の業務画質を主張できない。解約判断前に 5〜10 の独立 scene、100% crop、実操作性能、export 再現性を確認する。

現段階は「P1 の安全な候補経路と検証基盤が整った」状態であり、**Lightroom の契約を停止できる完成状態ではない**。
