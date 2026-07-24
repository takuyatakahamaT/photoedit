# RAWホワイトバランス観測 — Claude設計レビューと採否記録

- 実施日: 2026-07-24（JST）
- reviewer: Claude Opus 4.7
- 実行方式: `claude-review` skill、設計v1と修正版v2のread-onlyレビュー
- 対象: 製品の既定挙動を変えず、Core Image RAWのAs Shot / custom neutralを観測する開発専用スライス
- 最終判定: **Conditional Go。v1のblocking 5件はv2で解消し、限定された観測基盤として実装開始可**

## 1. レビューの目的

LightroomのTemperature / TintとApple `CIRAWFilter`のneutral設定は、名前と値域が似ていても同じ画素結果を保証しない。2 development sceneしかない状態で候補値を製品へ流すと、WB差、Adobe profile差、decoder差を混同した過学習になる。

このため、Claudeには次の境界を重点的に確認してもらった。

- 既存As Shotの画素を変えないか
- Adobe値とApple値を同一視していないか
- OS、decoder、profile、色空間等のprovenanceを残せるか
- exploratory結果が製品へ自動流入しないか
- private RAW / Lightroom TIFF / metadataを公開Gitへ漏らさないか
- run途中失敗、上書き、setter順序、候補集合の事後変更をfail-closedにできるか

## 2. 設計v1のblockingと反映

| blocking | Claudeの懸念 | v2で採用した解決 |
|---|---|---|
| B1: As Shotへの介入 | neutral propertyのreadだけでもlazy RAW graphへ影響する可能性があり、「書き戻さない」だけでは既存画素不変を保証できない | `.asShot`は既存production decoderへそのまま委譲し、追加filter生成・neutral read/writeを一切しない。customだけ別のfresh filterを使う |
| B2: Adobe / Appleの意味論混同 | Lightroom UI値をApple格子の中心とみなす根拠がなく、同一Kelvinが同一chromaticityとは限らない | 候補はApple側のfresh As Shot neutralを中心にmired / tint offsetで構成。Adobe値は参照metadataとしてのみ保存し、Core Imageへ投入しない |
| B3: provenance不足 | 同じTemperature / TintでもOS、RAW decoder、profile、EDR、色空間等が違えば別画素になり得る | macOS build、Core Image version、decoder version、supported versions、camera校正profile、boost / EDR、scale / draft、neutral policy、色空間、hardware / Metal、source / input / executable hashを必須化。非公開のApple内部profile IDは捏造せず観測不能と記録 |
| B4: production昇格防止が運用依存 | `exploratory`という注記だけでは、後で候補を製品へ流用できてしまう | 観測型・manifest loader・CLI targetを製品型から分離し、adoption literalは`exploratory-observation-only`だけを受理。`EditSettings`、production decoder、`RenderEngine`への変換APIと製品側loaderを作らない |
| B5: Tint / rankingの過剰解釈 | ΔE最小をLightroom Tintの推定や採用値と誤読し得る | analyzerは候補順をmanifest順に固定し、ranking、winner、best、recommend、mappingを出力しない。Lightroom Tintや物理照明を逆算しない |

Claudeのv2再レビューでは、新規blockingはなかった。

## 3. Conditional Goの条件と実装方針

Claudeが実装前または実装中に満たすべきとした条件は、次の方針へ落とした。

1. As Shotとcustomは同じ既存production raster / output graphを使い、観測専用の別resize実装を作らない。
2. setter順序は`temperature → tint`を主経路、`tint → temperature`を比較経路とし、custom中心点でTIFF全bytesの一致を要求する。一致しないrunは記述値として採用せず失敗させる。
3. private outputはGit管理外の`.photobench/white-balance-observations/`だけに作る。入力private fixtureのGit追跡、output ignore漏れ、symlinkを起動時に拒否する。
4. TIFF metadataはImageIOで除去し、ExifToolでもEXIF / GPS / MakerNote / IPTC / XMP / serial等の不在とcanonical sRGB ICCだけの保持を再監査する。
5. 新runはcanonical UUID directoryと`.incomplete.json` sentinelで所有し、既存runのresume / replaceをしない。途中失敗は新run IDで最初からやり直す。
6. 候補は結果を見る前に18件へ固定する。As Shot、custom center、mired軸6、tint軸6、少数の四隅4とし、候補順を含むmanifest改変を拒否する。
7. 2 scene / development only / 0 holdoutをmachine-readableに残し、production adoptionを常に`false`とする。

## 4. 採用しなかった案

### 観測結果をそのまま製品WBへ接続

不採用。Lightroom側は固定As Shot参照しかなく、Temperature / Tint教師sweep、gray card / ColorChecker、領域別指標、sealed holdoutがない。候補選択や変換式は今回の証拠から導けない。

### Lightroom値をCore Imageへ1対1で渡す

不採用。同名・同値域は互換性の証拠ではない。camera profile、matrix、chromatic adaptation、decoderが異なるため、Adobe値は教師metadataとApple探索の結果を分けて保持する。

### RAW decode後の色温度filterで全候補を近似

不採用。RAW WBはdemosaic等より前のdecode-affecting制御であり、後段filterは同じ処理ではない。観測候補ごとにfresh `CIRAWFilter`でfull RAW decodeする。

### 観測packageを別repositoryへ分離

今回は不採用。別Swift target、製品非依存の型、製品loader不在、Git管理外artifact root、単一adoption literalの組み合わせで、レビュー可能性を保ちながら構造分離できる。将来この境界が崩れるなら再検討する。

## 5. 残存リスク

- Apple内部camera profileは公開APIから完全には観測できず、過去runはそのmacOS buildに対する記述である。
- setter順序のbyte一致は今回の2 RAW、custom中心点、現行runtimeだけの観測であり、Apple API一般の保証ではない。
- Lightroom参照はLightroom 9.3 / Process Version 15.4 / Adobe Standardの固定成果物であり、将来参照を更新する場合は別suiteとして扱う必要がある。
- 2 development scene、1 camera、0 holdoutでは統計的なproduction判断ができない。
- custom WBを将来製品へ接続するときは、latest-only decode、cancellation、stale result拒否、preview / export / persistence / Undoの共通intentを別設計・別レビューで追加する必要がある。

## 6. 最終判断

設計レビューによって、「WB機能を早く画面へ付ける」スライスから、「As Shotを一切変えず、custom RAW WBを再現可能かつ非採用前提で観測する」スライスへ狭めた。この変更により、Lightroom相当をまだ証明できない段階で製品挙動を変えるリスクと、private写真を公開Gitへ漏らすリスクを先に封じられた。

正式結果とproduction接続前の条件は[`docs/WHITE_BALANCE_OBSERVATION.md`](../docs/WHITE_BALANCE_OBSERVATION.md)を正とする。
