# photobench-engine プロトコル（v1）

NIHO Desktop（Tauri）が写真編集タブのために起動する、Photo Bench の現像エンジンの入出力の約束。
エンジンは PhotoCore をそのまま使い、画は Photo Bench アプリ・`photobench-render` と同じになる。
NIHO 側の Epic は niho-coliving/niho-app#16314（Desktop 側は #16316）。

## 起動と終了

- 起動: `photobench-engine --stdio`。NIHO Desktop が子プロセスとして起動する（写真編集タブで最初の要求が来たとき）
- 終了: 標準入力が閉じたら、走行中の `render` を取り消して終了する。`shutdown` 要求でも終了する（どちらも、走行中の `open` / `export` は終わるまで最大 30 秒待つ。まだ始まっていない要求には応答しない）
- 標準エラー出力はログ（1 行 1 件、先頭に `photobench-engine:`）。NIHO Desktop は末尾だけを保持する
- 環境変数は NIHO Desktop が許可したものだけが渡る前提で、HOME と PATH 以外に依存しない

## 形式

- 要求: 標準入力に 1 行 1 つの JSON（UTF-8、改行で区切る）
  `{"id": 1, "method": "open", "params": {...}}`
  `id` は正の整数で、呼び出し側が一意に振る
- 応答: 標準出力に 1 行の JSON ヘッダ。バイナリを伴う応答は、ヘッダの `"binaryLength": N` の改行の直後に、ちょうど N バイトの本体が続く
  - 成功: `{"id": 1, "ok": true, "result": {...}}`（バイナリ付きは `"binaryLength"` と `"mime"` を足す）
  - 失敗: `{"id": 1, "ok": false, "error": {"code": "...", "message": "..."}}`
  - `id` が読めない行（JSON でない、`id` が無い・正の整数でない）には `"id": 0` の `invalidRequest` を返す
- 応答は `id` で対応づける。順番は要求と一致しないことがある（`render` の取り消しなど）
- 標準出力には応答以外を書かない

### エラーコード

| code | 意味 |
|---|---|
| `invalidRequest` | JSON が読めない、method が無い・知らない、params の型が違う、パスが絶対パスでない |
| `notFound` | `photoId` が開かれていない（`close` した写真の、待機中・走行中の `render` も） |
| `cancelled` | 同じ写真へのより新しい `render` が来たので取り消した |
| `decodeFailed` | 写真を読めない（壊れている・対応していない形式・ファイルが無い） |
| `presetInvalid` | XMP を読めない、Camera Raw の設定が 1 つも無い |
| `exportFailed` | 書き出せない（書き込み先に書けない、開いている写真の原本を上書きしようとしたなど） |
| `internal` | それ以外 |

Adobe のカメラプロファイルが見つからない RAW はエラーにしない（macOS の RAW 現像で開き、`open` の `profile` が `fallback` になる）。

## 編集設定（settings）

PhotoCore の `EditSettings` を JSONEncoder で書いたもの（Photo Bench アプリの保存形式と同じ）。
呼び出し側は `presetSettings` などで受け取った JSON を保持し、次の数値キーだけを書き換えて送り返す。それ以外のキーは中身を解釈せず、そのまま返す。

| キー | 範囲 | 意味 |
|---|---|---|
| `exposure` | −5〜+5 | 露光量（EV） |
| `contrast` / `highlights` / `shadows` / `whites` / `blacks` | −100〜+100 | 基本補正 |
| `texture` / `clarity` / `dehaze` | −100〜+100 | テクスチャ・明瞭度・かすみの除去 |
| `vibrance` / `saturation` | −100〜+100 | 自然な彩度・彩度 |
| `whiteBalance` | オブジェクト | RAW の色温度・色かぶり補正。`{"mode": "custom", "temperature": 2000〜50000, "tint": −150〜+150}`、撮影時に戻すときは `{"mode": "asShot"}` |
| `relativeTemperature` / `relativeTint` | −100〜+100 | RAW 以外（JPEG など）の色温度・色かぶり補正 |

`whiteBalance` が効くのは、`open` の `asShotWhiteBalance` が null でない写真（Adobe のカメラプロファイルで開いた RAW）だけ。
RAW 以外と `profile: "fallback"` の RAW には `relativeTemperature` / `relativeTint` を使う（Photo Bench アプリと同じ）。

## メソッド

### `hello`
- params: なし
- result: `{"engineVersion": "0.1.0+<git sha>", "protocolVersion": 1}`
  `<git sha>` は 12 桁。未コミットの変更を含むビルドは `+<git sha>.dirty`、`scripts/package-engine.sh` を通さない開発ビルドは `+dev`

### `builtinPresets`
エンジンに同梱した NIHO のプリセット（bluesky2 / colorful / night / pastel）。
- params: なし
- result: `{"presets": [{"id": "niho-bluesky2", "name": "bluesky2", "xmp": "<XMP 本文>"}, ...]}`

### `presetSettings`
XMP を読み、`base` に当てた編集設定を返す（Lightroom と同じく、プリセットが持つ項目だけを置き換える）。
- params: `{"xmp": "<XMP 本文>", "base": <settings>}`（`base` を省くと既定値に当てる）
- result: `{"name": "<プリセット名>", "settings": <settings>, "unsupported": ["Sharpness", ...]}`
  `name` は XMP の `crs:Name`（無ければ空文字）。
  `unsupported` は、エンジンが再現しない項目（シャープ・ノイズ軽減・粒子・周辺光量など）の XMP キー名。Photo Bench アプリが「未対応」と数える項目と同じで、値が 0 の項目や Photo Bench が知らない項目も含む（埋め込みの Look は `Look.<キー>`）

### `open`
写真を読み、プレビュー用の作業コピー（長辺 2560px）を作る。原寸のデコードは保持せず、`export` のときに読み直す。
- params: `{"path": "<絶対パス>"}`（NIHO Desktop がネイティブの選択ダイアログで得たパスだけを渡す）
- result: `{"photoId": "<ID>", "kind": "raw" | "raster", "fileName": "P1524180.RW2", "width": 6000, "height": 4000, "asShotWhiteBalance": {"temperature": 5200, "tint": 3} | null, "profile": "adobe" | "fallback" | null, "settings": <既定の編集設定>}`
  `width` / `height` は向きを反映した原寸。`settings` は何も当てていない状態（Photo Bench の `EditSettings.neutral`）で、プリセットを当てるときの `base` にもなる
  - `profile`: RAW をどう現像したか。`adobe` は Adobe のカメラプロファイル（Lightroom と同じ基準の色）。`fallback` はプロファイルが見つからない（または LibRaw が読めない）ため macOS の RAW 現像（Core Image）で開いたもので、色は Lightroom と揃わない。Lightroom / Lightroom Classic / Adobe DNG Converter のどれかを入れると `adobe` になる。RAW 以外は null
  - `asShotWhiteBalance`: 撮影時の色温度・色かぶり（整数に丸めた値）。`profile` が `adobe` の RAW のときだけ
- 同時に開いておける写真は 4 枚まで。5 枚目を開くと、いちばん長く使っていない写真の作業コピーを捨てる（`photoId` はそのまま使え、次の要求で読み直す）

### `render`
プレビューの JPEG を返す（バイナリ付き）。
- params: `{"photoId": "<ID>", "settings": <settings>, "maxDimension": 1600, "drag": false, "original": false}`
  - `maxDimension`: 長辺の上限（px、最大 2560。省くと 2560、それより大きい値は 2560 として扱う）
  - `drag`: スライダーをドラッグ中なら true。その写真で最初の `drag: true` の settings からドラッグが始まり、近似で速く描く（Photo Bench の `PreviewDragSession` と同じ）。離したら `drag: false` でもう一度呼ぶと正確な画になり、ドラッグが終わる
  - `original`: true なら編集前（既定の設定）の画。`settings` は省いてよく、ドラッグの状態は変えない
- result: `{"width": 1600, "height": 1067}`、`"mime": "image/jpeg"`、`"binaryLength": N`（`width` / `height` は JPEG の画素数。原寸より大きくはしない）
- 同じ写真へのより新しい `render` が来たら、待機中のものはすぐに、走行中のものは止まったところで `cancelled` で終わる（別の写真の要求と `export` は取り消さない）
  ドラッグ中は前の応答が返ってから次を送る（待たずに送り続けると取り消しが続き、画が出ない）

### `export`
原寸の JPEG を書き出す。
- params: `{"photoId": "<ID>", "settings": <settings>, "destinationPath": "<絶対パス>.jpg", "jpegQuality": 0.92}`（NIHO Desktop が保存ダイアログで得たパスだけを渡す。`jpegQuality` は省くと 0.92）
- result: `{"path": "<書いたパス>", "width": 6000, "height": 4000, "bytes": 8123456}`
  書き込み先のフォルダが無ければ作る。開いている写真の原本は上書きしない（`exportFailed`）

### `close`
- params: `{"photoId": "<ID>"}`
- result: `{}`（その写真の待機中・走行中の `render` は `notFound` で終わる）

### `shutdown`
- params: なし
- result: 走行中の `render` を取り消し、走行中の `open` / `export` が終わるのを待ってから `{}` を返して終了する。まだ始まっていない要求と、`shutdown` の後に届いた要求には応答しない

## 第三者ライセンス

`dist/engine/licenses/` に、同梱する dylib のライセンス文を Homebrew の keg ごと（`<formula>-<version>/`）に置き、一覧を `licenses/INDEX.txt` に書く（LibRaw: LGPL-2.1-only OR CDDL-1.0、Little CMS: MIT、libjpeg-turbo: IJG AND BSD-3-Clause AND Zlib、JasPer: JasPer-2.0、LLVM OpenMP: Apache-2.0 WITH LLVM-exception）。
LibRaw などは動的リンクのまま同梱し、差し替えできる形を保つ。Adobe のカメラプロファイルは同梱しない（各 Mac の Lightroom / DNG Converter から実行時に読む）。

## 同梱の形（NIHO Desktop へ）

`scripts/package-engine.sh` が `dist/engine/` を作る。

```
dist/engine/
  MacOS/photobench-engine      # 実行ファイル（LC_RPATH = @executable_path/../Frameworks）
  Frameworks/*.dylib           # LibRaw・lcms2 と、その依存（install name は @rpath/…）
  licenses/                    # 同梱 dylib のライセンス文と一覧（INDEX.txt）
  engine.json                  # 版・git の commit・同梱 dylib の出所と対応 macOS・各ファイルの SHA-256
```

NIHO Desktop のビルドは、`MacOS/photobench-engine` を `Contents/MacOS/photobench-engine` に、`Frameworks/` の dylib を `Contents/Frameworks/` に置く。
`dist/engine/` の中も同じ相対位置なので、開発時はその場で起動できる。
すべて ad-hoc 署名する（Apple Silicon は署名の無い・壊れた実行ファイルを起動しない）。NIHO Desktop を Developer ID で署名・公証するときは、hardened runtime のライブラリ検証に通るよう、同梱の dylib と実行ファイルも同じ ID で署名し直す。
同梱の dylib は Homebrew のボトルなので、パッケージを作った Mac の macOS 向けにビルドされている。起動できる最も古い macOS は `engine.json` の `minimumMacOS`（実行ファイル自体は macOS 14 以降）。
