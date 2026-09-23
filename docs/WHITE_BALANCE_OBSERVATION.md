# RAWホワイトバランス観測記録

更新日: 2026-09-24（JST）

状態: **開発用の観測基盤と正式な2シーン観測は完了したが、製品のホワイトバランス処理は未接続である。** この結果は候補の順位、Adobe値からCore Image値への変換、Lightroom相当の品質、またはproduction採用を決める証拠ではない。

機械可読な正本は、Mac Studioの`~/Documents/app/photo-edit-app-calibration/`配下にある次の2ファイルである（Git管理外）。2026-07-24のMac mini run `51ba2f46-185d-4b87-8345-407d380214cd`は、Mac miniの`.photobench/white-balance-observations/`に履歴として残る。

- `.photobench/white-balance-observations/4fb4cf01-059f-4193-ac7e-504b654b6853/run.json`
- `.photobench/white-balance-observations/4fb4cf01-059f-4193-ac7e-504b654b6853/analysis.json`

## 1. この観測の目的

Photo Benchは、クラウドやAIに依存せず、最終的にLightroomを置き換えられるローカル専用写真編集アプリを目指している。ただしLightroomは当面継続し、比較用の教師出力と退避手段として使う。

今回のスライスでは、RAWホワイトバランスをいきなり製品へ接続せず、次を先に固定した。

1. As Shotは既存production decoder delegateへ委ね、neutral setterを呼ばず、製品graphを変えない。
2. custom Temperature / Tintだけをfresh `CIRAWFilter`へ設定し、その結果を再現可能な開発用artifactとして観測する。
3. AdobeのTemperature / TintとAppleの値を同一の変換規則と仮定しない。
4. 個人RAW、Lightroom参照TIFF、生成artifact、撮影メタデータを公開Gitへ入れない。
5. 2シーンの結果から製品挙動を変更できないことを、manifestとanalyzerで機械的に固定する。

## 2. 一次資料から確定した境界

[Apple `CIRAWFilter.neutralTemperature`](https://developer.apple.com/documentation/coreimage/cirawfilter/neutraltemperature)の範囲は2,000K〜50,000K、[`neutralTint`](https://developer.apple.com/documentation/coreimage/cirawfilter/neutraltint)は-150〜150である。[`neutralChromaticity`](https://developer.apple.com/documentation/coreimage/cirawfilter/neutralchromaticity)はxy色度を扱う別の入口である。

[Adobe Camera Raw namespace](https://developer.adobe.com/xmp/docs/xmp-namespaces/crs/)にもTemperature、Tint、WhiteBalanceがあるが、これはAdobeの編集設定の名前と値域を定義するもので、Core Imageとの画素同一性や変換式を定義しない。[Lightroomの色調整説明](https://helpx.adobe.com/lightroom-classic/desktop/process-and-develop-photos/image-tone-color.html)でも、profileとwhite balanceは別の基礎制御である。

したがって、Lightroom教師のTemperature / Tintは**参照メタデータ**として保存するだけで、Core Imageへそのまま投入しない。両backendの数値範囲が同じことも、意味や画作りが同じ証拠にはしない。

## 3. 実装した観測経路

製品の`CoreImageDecoder`と`RenderEngine`にはcustom WBを接続していない。観測専用の`CoreImageRAWWhiteBalanceDecoder`が、次の2経路を分ける。

- As Shot: 既存のproduction delegateをそのまま使用する。
- Custom: 要求ごとにfreshな`CIRAWFilter`を作り、Core Image RAW 8、full-resolution、DC-S5限定profile、Temperature / Tint、decode provenanceを固定する。

生成経路は次である。

```text
private RAW
  → fresh Core Image RAW 8 decode
  → As Shot または観測用 custom neutral
  → 既存production edits / output graph
  → edge-clamped Lanczosで最大辺1,500px
  → terminal sRGB transform
  → RGBA16 sRGB TIFF
  → source EXIF / XMP / IPTC / GPSを除去し、canonical sRGB ICCだけ保持
```

setter順序は`temperature → tint`を主経路、`tint → temperature`を比較経路とし、custom中心点でTIFF全bytesの完全一致を要求する。

## 4. 事前登録した候補集合

各シーン18候補を、結果を見る前にmanifestへ固定した。

- As Shot: 1
- fresh filterから読んだ中心Temperature / Tintを書き戻すcustom center: 1
- Temperature軸: 中心からmired差 `-100, -60, -30, +30, +60, +100`: 6
- Tint軸: 中心から `-60, -30, -15, +15, +30, +60`: 6
- 交差点: mired差 `±30` × Tint差 `±15`: 4

1シーンあたり、18候補、固定Lightroom参照、setter順序比較の20 artifactで、2シーン合計40 artifactである。Temperature軸をKelvin等間隔ではなくmired差で扱うのは、色温度の逆数側で変化を観測するためである。

## 5. 正式証跡

2026-09-24に、校正manifest v4の再固定（処理fingerprint・source一覧・校正機）に合わせて、WB観測manifestのbase hash・source一覧・実行環境を更新し、Mac Studioで再実行した。同日、`ColorOps` v2で校正manifestが変わったため再度実行し、校正runnerと空間処理のsource変更後にもそれぞれ実行した。40 artifactは同日の前回までのrunとバイト一致し、値は`efed3014…`とも同一である。

- suite: `dc-s5-lightroom-9.3-white-balance-observation-2026-07-24-v1`
- run ID: `4fb4cf01-059f-4193-ac7e-504b654b6853`
- manifest SHA-256: `e0b6735ea9ec7f9fb3cd86e6b71bfd7647d73fc1d37378c0087543bc1261c396`
- source fingerprint: `ec3af3440d5129a5f0e8cdf8cc260b3691d928155fa8f3538ff7c9c83b3f5178`
- release executable SHA-256: `ad4af4c88f229df896b390489187e841a7c191fe53731c4962264f7ba952160f`
- ExifTool: `13.55`（Homebrew）
- runtime: macOS `26.5.2` build `25F84`、`Mac13,1`、Apple M1 Max、arm64、release
- 検証対象: 44 source、40 / 40 artifact、2 development scene、0 holdout
- validation: `passed`
- adoption status: `exploratory-observation-only`
- production adoption allowed: `false`

2026-07-24の旧run `51ba2f46-185d-4b87-8345-407d380214cd`（manifest SHA-256 `aea4c936…`、source fingerprint `413fce7e…`、macOS `26.3.1`、`Mac16,10`、Apple M4、28 source）も同じ判定だった。

runnerはprivate inputのGit追跡、出力rootのignore漏れ、symlink、既存run / 既存file、source・input・binary・ExifToolの途中変更、成果物hash・byte count・provenance・metadata契約違反を拒否する。analyzerはrunとmanifestのsnapshot、全artifact、release binary、source fingerprintを解析前後に再検証し、既存のanalysisを上書きしない。

## 6. 観測結果

固定Lightroom参照はLightroom 9.3、Process Version 15.4、Adobe Standard、As Shotである。以下は全画面の記述値であり、候補の採否や変換規則ではない。

| scene | Lightroom教師 metadata | Core Image As Shot → 固定LR参照 | custom center → 固定LR参照 |
|---|---|---:|---:|
| P1524180 | 3,600K / Tint +18 | mean ΔE00 `3.6660254`、EV `+0.1050280` | mean ΔE00 `3.6660273`、EV `+0.1050287` |
| P1522877 | 5,400K / Tint +15 | mean ΔE00 `2.1292410`、EV `+0.0294952` | mean ΔE00 `2.1292424`、EV `+0.0294943` |

fresh filterの中心値を書き戻したcustom centerとAs Shotの差は次のとおりだった。

| scene | mean ΔE00 | p95 ΔE00 | RGB MAE | EV drift | byte exact |
|---|---:|---:|---:|---:|---|
| P1524180 | `0.0001513` | `0.0007339` | `5.09e-7` | `+6.79e-7` | いいえ |
| P1522877 | `0.0003225` | `0.0014482` | `1.06e-6` | `-9.75e-7` | いいえ |

2026-07-24のMac mini run（macOS `26.3.1`、Apple M4）との差は、上の2表の各値とも`3e-6`未満だった。

この差は非常に小さいが、byte exactではない。fresh filterのgetter値を書き戻す操作がAs Shotと常に同一になる、別OS・別cameraでも同じ、Adobe値との写像が得られた、とは解釈しない。

setter順序の比較は両シーンでbyte exactだった。

- P1524180: `temperature → tint` = `tint → temperature`
- P1522877: `temperature → tint` = `tint → temperature`

これは今回の2 RAW、固定decoder / runtime、custom中心点だけの観測である。Core Image API一般の順序非依存性を保証しない。

## 7. 校正v4との関係

WB観測manifestは、正式校正v4の入力・scene順・処理契約をbyte exactに継承する。2026-09-24の再固定後、Mac Studioで校正を5回実行した。詳細は[`CALIBRATION.md`](../CALIBRATION.md)にまとめる。

- calibration run ID（正本）: `012d7d73-9157-4f93-9562-3fb7e25d8dc3`
- manifest SHA-256: `1e7742ff99d6d6e8375629d5a7700159803f55816d96bffa54ce84fc786fd905`
- source fingerprint: `fb79f313aa642ad91cd03de9ae3f42bf82f83496d455be13127020907f139eb4`
- release executable SHA-256: `7a59d6a60bf017a9e63f13f168f2b5fbcdc34106ee32e3fa15a92e26bbf852fb`
- 7 inputs、42 source、122 / 122 artifact verified

Lightroom品質は4経路とも、canonical settleは2シーンとも合格した。一方、preview parityは3,072px / 3,840pxともeligible candidateがない。LR-input経路の非決定的な描画欠損は修正済みである。WB観測の構造合格は、これらの既知不合格を解消しない。

2026-07-24の旧校正run `1c324af0-7ec3-4c33-bc6f-3bd653794800`（manifest SHA-256 `9da1fd58…`、26 source）は履歴として残す。

## 8. 未解決の課題

現時点でproduction WBを接続しない理由は明確である。

1. 2 development scene、1 camera model、0 sealed holdoutしかない。
2. 固定As Shot Lightroom参照しかなく、Lightroom側のTemperature / Tint sweepがない。
3. 灰色カード、ColorChecker、skin、foliage、highlight、mixed-light等のROIがない。
4. Adobe StandardとApple camera transformのprofile差をWB差から分離できない。
5. UIスライダー、latest-only decode、cancel、stale result拒否をまだ実装していない。
6. preview / export / edit persistence / Undo・Redo / XMP importのWB意味論が未接続である。
7. As Shotが取得できない場合のfallbackと、その状態をUIへどう明示するか未確定である。
8. cross-process lockがなく、同一rootで校正・観測を並行実行できない。

## 9. production接続前の受け入れ条件

次の順で進める。

1. daylight、shade、tungsten、LED / fluorescent、mixed light、低照度を含む5〜10以上のdevelopment sceneを追加する。
2. 最後まで調整に使わないsealed holdoutを最低2 scene用意する。同じ被写体・連写・派生cropは同じscene groupへ固定する。
3. gray cardまたはColorCheckerを含むsceneを用意し、neutral、skin、foliage、highlightをROIで別評価する。
4. Lightroom側でAs Shot中心のTemperature-only、Tint-only、少数の交差点を、同じprofile / Process Version / tone / export条件で書き出す。
5. Adobe値を直接コピーするbaselineと、必要な場合だけ単調で説明可能なtransform候補を分け、holdoutを見る前に指標と閾値を固定する。
6. `asShot | custom | unavailable/fallback`を型で区別し、decoder version、camera profile、source、resolved値を編集schemaへ保存する。
7. WB変更をdecode-affecting editとして扱い、latest-only / cancellation / stale result拒否を実装する。
8. previewと原寸exportが同じWB intent / provenanceを使い、再起動、Undo・Redo、XMP importでも再現されることを確認する。
9. As Shot取得不能時は黙って別処理へ切り替えず、fallback理由を画面と証跡へ明示する。
10. 既存のEV、clip、plateau、preview parity、canonical settleをWB sweepでも非回帰にする。

## 10. 再現コマンド

個人RAWとLightroom参照TIFFがローカルrootにあり、Git追跡されず、`.photobench/`がignoreされていることが前提である。同じrootで別の校正・観測を並行実行しない。

```sh
swift run -c release PhotoBenchWhiteBalanceObservation "$PWD"
python3 scripts/analyze-white-balance-observation.py "$PWD" \
  --run .photobench/white-balance-observations/<run-id>/run.json
python3 -m unittest scripts/test_analyze_white_balance_observation.py
```

runnerは新しいrun IDを作り、analyzerはそのrun directoryへ一度だけ`analysis.json`を作る。既存runやanalysisは上書きしない。

## 11. 判断

今回の成果は、custom RAW WBを安全に観測し、欠測や個人データ混入を合格に倒さない基盤である。製品にWB機能が実装されたわけではない。次はLightroom契約中に教師sceneとsweepを増やし、profile差とWB差を分離してから、preview / export / persistenceへ同じWB intentを接続する。
