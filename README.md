# rcps — コメント削除スクリプト

自作のソースコードからコメントを削除する PowerShell スクリプトです。

- Windows 標準の **PowerShell 5.1** で動きます（PowerShell 7 でも動きます）。
- 追加のモジュール、外部ツール、コンパイルは不要です。3つのファイルを置くだけで使えます。
- 対応している言語は、C/C++、Java、TypeScript、CSS、HTML、シェル（.sh）、Makefile、設定ファイル（.conf）です。

詳しい仕様は [docs/spec.md](docs/spec.md)、内部の設計は [docs/design.md](docs/design.md) を見てください。

## ファイル

| ファイル | 役割 |
| --- | --- |
| `src/Remove-Comments.ps1` | 1つのファイルからコメントを削除する |
| `src/Invoke-RemoveComments.ps1` | ディレクトリ配下を一括で処理する（`Remove-Comments.ps1` と同じフォルダに置く） |
| `src/remove-comments.json` | 設定ファイルのサンプル |
| `src/oss-list.txt` | 除外パターンを書いたファイルのサンプル |

スクリプトは署名していないため、`-ExecutionPolicy Bypass` を付けて実行します。

## 使い方

### 1ファイルを処理する

```powershell
powershell -ExecutionPolicy Bypass -File Remove-Comments.ps1 -Path src\main.cpp -OutPath out\main.cpp
```

| 引数 | 内容 |
| --- | --- |
| `-Path` | 処理するファイル（必須） |
| `-Config` | 設定ファイル。省略すると、カレントディレクトリ → スクリプトのフォルダの順に `remove-comments.json` を探す |
| `-OutPath` | 書き出し先。省略できるのは、設定の `output.mode` が `inPlace`（元ファイルを上書きする）のときだけ |
| `-DryRun` | ファイルを書かず、削除・保持したコメントの数だけを表示する |

標準出力には結果を1行だけ出します。

```
OK	src\main.cpp	removed=12	kept=3
```

### ディレクトリを一括で処理する

```powershell
powershell -ExecutionPolicy Bypass -File Invoke-RemoveComments.ps1 -Config remove-comments.json [-Root ..\src] [-DryRun]
```

- 出力先、除外するファイル、ログの出力先は、すべて設定ファイルで指定します。
- `output.mode` が `outDir` のときは、出力先に元と同じフォルダ構成で書き出します。除外したファイルと対象外のファイルもそのままコピーするので、出力先をそのままビルドできます。
- 最後に `OK=n EXCLUDED=n UNSUPPORTED=n ERROR=n` を表示します。終了コードは、エラーがなければ 0、1件でもあれば 1、設定エラーなら 9 です。
- `log.path` を設定すると、ファイルごとの結果を CSV（UTF-8 BOM 付き）で書き出します。

**はじめて使うときや設定を変えたときは、まず `-DryRun` を付けて削除・保持の件数を確認してください。**

## 設定ファイルの例

```json
{
  "version": 1,
  "output": { "mode": "outDir", "outDir": "../out" },
  "keep": {
    "patterns": ["Copyright", "NOLINT", "@license"],
    "regex": ["TICKET-\\d+"]
  },
  "languages": {
    "html": { "extensions": [".html", ".htm"] }
  },
  "batch": { "root": "../src" },
  "exclude": ["third_party/**", "**/vendor/**"],
  "excludeFiles": ["oss-list.txt"],
  "log": { "path": "../out/remove-comments-log.csv" }
}
```

- 設定の中の相対パスは、設定ファイルがあるフォルダが基準です。
- 知らないキーや型の違いはエラーになります（綴り間違いを防ぐため）。メモは `_comment` のように `_` で始まるキーに書いてください。JSON の中に `//` コメントは書けません。
- 正規表現の `\` は、JSON の中では `\\` と二重に書きます。
- キーの一覧は [spec.md の10章](docs/spec.md) にあります。

## 削除しないもの

- **保持パターン：** `keep.patterns`（部分一致）か `keep.regex`（.NET の正規表現）に一致したコメント。
- **保持範囲：** `% DEL START` を含むコメントから `% DEL END` を含むコメントまで。コードも含めて一切変更しません。
  ```c
  // % DEL START
  int debug = 1; // この行もそのまま残る
  // % DEL END
  ```
- **固定で保持するもの：** シェルの1行目の `#!`、TypeScript の `/// <reference ... />`、HTML の条件付きコメント `<!--[if ...]>` と `<!--<![endif]-->`。

## 終了コード（Remove-Comments.ps1）

| コード | 意味 |
| --- | --- |
| 0 | 成功（削除したコメントが0件でも成功） |
| 1 | 想定外の内部エラー（不具合です。報告してください） |
| 2 | 対象外のファイル種別 |
| 3 | 解析エラー（閉じていないコメント・文字列・ヒアドキュメントなど） |
| 4 | 保持範囲の START と END が対応していない |
| 5 | 読み書き・文字コードのエラー（NUL を含むバイナリファイルも含む） |
| 6 | 正規表現の照合が1秒を超えた |
| 9 | 引数・設定ファイルのエラー |

0 以外のときは、出力先も元ファイルも一切書き換えません。

## 文字コードと改行

- BOM があればそれに従います（UTF-8 / UTF-16LE / UTF-16BE）。BOM がなければ UTF-8 として読み、読めなければ Shift_JIS（CP932）とみなします。
- 書き出しは、読んだときと同じ文字コード・BOM の有無・改行（CRLF / LF、行ごと）・末尾改行の有無を使います。コメント以外のバイトは変わりません。
- 読み直して元のバイト列に戻らないファイル（Shift_JIS の一部の機種依存文字など）は、安全のため終了コード5で処理しません。その場合は設定の `encoding` を指定してください。

## 既知の制限

ここに挙げた場合のほとんどは、終了コード3で止まり、ファイルを書き換えません（黙って壊すことはありません）。

- **C/C++**
  - 単独の `'` があるプリプロセッサ行（例：`#error don't`）は、閉じていない文字リテラルとして止まります。
  - `#include <a/*b>` の `/*` は、コメントの開始とみなします。
- **TypeScript**
  - 正規表現リテラルと割り算は、直前のトークンから推定して区別しています。完全には判定できません。
- **シェル**
  - `$( ... )` の中にある `case` 文の `pat)` は、括弧の対応を狂わせることがあります。
  - `$(( ))` の外にある算術の `<<`（`(( a << 2 ))` や `let x=1<<3`）は、ヒアドキュメントと誤認されることがあります。
- **Makefile**
  - レシピ行の引用符が閉じていないと止まります。
  - `\\#` のような二重のバックスラッシュは考慮しません。
- **全言語共通**
  - `\` で終わる行の次の行がコメントだけなら、行継続が壊れないよう、削除せずに空行として残します（spec 5章のルール7・8）。

## テスト

テストには Pester を使わず、自作の実行スクリプトを使います。追加のインストールは不要です。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
pwsh -NoProfile -File tests/Run-Tests.ps1 -Filter cpp    # 名前で絞り込む
```

- 言語ごとの入力と期待結果は `tests/fixtures/<言語>/` にあります。`<ケース>.in.<拡張子>` を処理した結果を、`<ケース>.expected.<拡張子>` とバイト単位で比べます。
- GitHub Actions で、Windows PowerShell 5.1、Windows の PowerShell 7、Ubuntu の PowerShell 7 の3つの環境でテストしています（`.github/workflows/test.yml`）。
- `.ps1` は UTF-8（BOM 付き）で保存してください。BOM がないと、日本語の Windows の PowerShell 5.1 で日本語が化けます。
