# RAWホワイトバランス観測 — Claude実装レビューと反映記録

- 実施日: 2026-07-24（JST）
- reviewer: Claude Opus 4.7
- 実行方式: `claude-review` skill、repository read-onlyレビュー
- 対象: RAW WB decoder、観測manifest / runner / analyzer、private-data guard、校正archive互換
- Claude判定: **blockingなし**
- 最終判断: **観測基盤として採用。製品WBとしては未採用**

## 1. Claudeが確認した構造

Claudeは、実装が次の境界を多層で守っていることを確認した。

- `.asShot`は既存`CoreImageDecoder`へそのまま委譲し、neutral propertyへ触れない。
- `.custom`だけcandidateごとにfresh `CIRAWFilter`を作り、Core Image RAW 8、full-resolution、DC-S5限定校正、Temperature / Tint、provenanceを固定する。
- custom値は範囲、finite / normal、Float round-trip、signed zeroを型のinitializerで正規化・検証する。
- runnerはmanifest、base manifest、private inputs、source、release executable、ExifToolを実行前後に検証する。
- 1 sceneにつきLightroom参照1、固定18候補、setter-order比較1の20 artifactを作り、2 sceneで40 artifactを要求する。
- outputはsymlink拒否、既存拒否、stagingからのno-replace publish、directory fsyncでwrite-onceにする。
- analyzerはrun / manifest snapshot、候補順、全artifact、metadata、hash、release provenanceを独立再検証し、既存`analysis.json`を置換しない。
- adoptionはSwift型、manifest literal、Python exact validation、禁止語検査で`exploratory-observation-only`へ固定し、製品型への変換を持たない。
- 過去校正manifestはarchive snapshot、現行byte一致、Git objectの順で解決し、manifestを更新しても過去runを検証できる。

Claudeの結論は、As Shot非介入、fresh custom filter、no-overwrite、privacy二重監査、adoption封じ、source fingerprint照合にblockingはない、というものだった。

## 2. ClaudeのShould指摘と対応

### S1: run directory作成エラーの分類

`mkdir`失敗をすべて「既存run」と表示すると、権限不足やdisk fullを誤診するという指摘。

**対応済み**。`fileWriteFileExists`だけを競合・既存として扱い、それ以外は元のエラー説明を保持してrun directory作成失敗として返す。

### S2: analyzerのrelease executable再検証

release binaryが無い場合の診断が弱く、証跡と実際の実行物の対応が分かりにくいという指摘。

**対応済み**。analyzerはrelease productの存在とSHA-256を再検証し、無い場合は必要な`swift build -c release --product PhotoBenchWhiteBalanceObservation`を明示する。runは実行中binary自身のhashを記録し、debug / releaseの取り違えを拒否する。

### S3: 実行中binaryの置換検知

観測開始時しかexecutableをhashしないと、別buildによる途中置換を検出できないという指摘。

**対応済み**。runner終了時にもcurrent executableを再取得し、開始時のSHA-256とbuild configurationの一致を要求する。

### S4: 部分校正archive復旧後の再検証

過去runのarchive treeは存在するが`source-manifest.json`だけ欠けた場合、snapshotを書いた直後にarchive全体をもう一度検証すべきという指摘。

**対応済み**。snapshot復元後とstagingの最終移動後に、通常file、manifest SHA、期待artifact集合、run evidence全体を再検証し、directoryを同期する。専用の履歴manifest resolver / immutable writerテストも追加した。

### S5: private入力が過去にGit追跡されていないか

`.gitignore`は将来の追加を防ぐだけで、すでに追跡されたRAW / Lightroom TIFFを検出しないという指摘。

**対応済み**。runnerはprivate input pathを`git ls-files --`で検査し、1件でも追跡されていれば開始しない。Python analyzerも同じ状態を独立に拒否し、回帰テストを持つ。

## 3. Claudeレビュー後の独立監査で直した点

Claudeレビュー後、Codex側の証跡監査でさらに2件を修正した。

### 解析中のTOCTOUとsnapshot完全性

analyzerが検証対象を途中で読み直し、検証済みbyteと最終reportの入力がずれる余地を除いた。manifest / run / artifact集合のsnapshotを解析全体で固定し、publish直前にもsource、binary、input、artifact、ExifTool identityを再検証する。

### provenance field名による禁止語の誤検知

一般文字列走査では、正当なMetal provenance key `recommendedMaxWorkingSetSize`まで`recommend`禁止語に誤検知し得た。禁止語検査を人間向け選定表現が現れ得るJSON pathへ限定し、provenance fieldはexact allowlistで構造検証するテストを追加した。これにより、候補の推薦を禁止したまま、正当なruntime provenanceを落とさない。

## 4. 正式な再検証

### 自動テスト

- Swift Testing: `119 tests / 10 suites` 成功
- Python calibration analyzer: `61 tests` 成功
- Python WB observation analyzer: `17 tests` 成功

### 校正v4

- run ID: `1c324af0-7ec3-4c33-bc6f-3bd653794800`
- manifest SHA-256: `9da1fd58ec4ead9b921dea477319423711567de3c06f8eb39d429c89980267f6`
- source fingerprint: `b7d8c57fab4428679a4f4e7cfacf2f64e67b317e9b9f46a00093cf7b5bf1a858`
- release executable SHA-256: `6f1be9b7a44529f25fb7fe8ad90b6b030bfa128e2108174bc86cab09cd775a15`
- 122 / 122 artifact verified

構造・canonical settleは合格した。一方、P1524180 / RAWのEV quality gateと、3,072 / 3,840px preview parityは不合格のままである。WB観測追加によって既知の画質不合格を隠していない。

### WB観測

- run ID: `51ba2f46-185d-4b87-8345-407d380214cd`
- manifest SHA-256: `aea4c93626b0a32259c747d2e2ca4ca82b45647d0336507bb709bc86b4e0faf3`
- source fingerprint: `413fce7eb57938b958f3e1efd7f835e6fd7cae5561e8327341e4c4faaaec8b3e`
- release executable SHA-256: `5e08849cc3d431cde4c42aad7523fd4b704591ae5aecb3f2d11404f92a0edf44`
- 28 source、40 / 40 artifact、2 development scene、0 holdout
- validation: `passed`
- adoption: `exploratory-observation-only`
- production adoption allowed: `false`

validation合格は構造・hash・provenance・privacy・候補順の合格であり、Lightroom画質合格ではない。

## 5. 意図的に残したP2

以下は次の観測schemaまたは運用強化で検討するが、今回のwrite-once正式runを阻む問題ではない。

- source file一覧へ役割を持たせ、production / observation / analyzer等をmachine-readableに区別する。
- recordに書いた寸法だけでなく、analyzer側でもTIFF pixel dimensionsを直接読み、全40 artifactが期待寸法か検証する。
- analyzerのmetadata監査を最終publish直前にも明示的な専用testでmutationさせ、postflightが確実に止めることを示す。
- Python環境の依存packageとversion / hashをprovenanceへ追加する。
- Apple RAWの内部camera profileが公開APIで観測できない制約を、macOS更新時の再観測runbookへつなげる。

## 6. 最終判断

実装レビューと修正後、観測基盤にはblockingは残っていない。正式runは、候補を再現可能に観測し、private data混入・改変・上書き・production誤採用をfail-closedに拒否する目的を達成した。

一方で、2 development sceneの固定As Shot参照からLightroom相当のWBを選ぶことはできない。次の品質スライスはLightroom Temperature / Tint教師sweep、gray card / ColorChecker、領域別指標、5〜10以上のdevelopment scene、最低2 sealed holdoutを先に用意する。製品接続はその契約を通った後に、latest-only decode、preview / export一致、永続化、Undo / Redoと一体で別レビューする。

正式結果の正本は[`docs/WHITE_BALANCE_OBSERVATION.md`](../docs/WHITE_BALANCE_OBSERVATION.md)を参照する。
