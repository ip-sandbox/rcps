# コメント削除スクリプト 設計書

仕様は [spec.md](spec.md)。この文書は実装の構成、データの形、守るべき実装上の約束を決める。仕様と食い違う場合は仕様が優先し、食い違いは仕様側を直して解消する。

## 1. 全体構成

```
src/Remove-Comments.ps1        単一ファイル処理。削除ロジックはすべてここ
src/Invoke-RemoveComments.ps1  一括処理。Remove-Comments.ps1 をドットソースして関数を呼ぶ
src/remove-comments.json       設定のサンプル
tests/Run-Tests.ps1            自作のテスト実行スクリプト（Pester は使わない）
tests/TestLib.ps1              アサーションなどの小さなテスト用関数
tests/*.Tests.ps1              テスト本体
tests/fixtures/<言語>/          入力と期待結果のファイル
.github/workflows/test.yml     CI
```

実行時に必要なのは PowerShell（5.1 または 7）と .NET の標準ライブラリだけ。`Add-Type` による C# のコンパイル、外部モジュール、外部コマンドは使わない。

## 2. Remove-Comments.ps1 の構造

```powershell
param([string]$Path, [string]$Config, [string]$OutPath, [switch]$DryRun)

# ...関数定義（すべて Rc という接頭辞を付ける）...

if ($MyInvocation.InvocationName -eq '.') { return }   # ドットソース時は関数を定義するだけ
$r = Invoke-RcMain -Path $Path -Config $Config -OutPath $OutPath -DryRun:$DryRun
# 結果行を標準出力、エラーの内容を標準エラーに出してから exit $r.ExitCode
```

- `-Path` は `Mandatory` にしない。ドットソース時に入力を求められるのを避けるため。未指定のときは `Invoke-RcMain` が終了コード9を返す。
- `Set-StrictMode -Version 2.0` と `$ErrorActionPreference = 'Stop'` は `Invoke-RcMain` と `Invoke-RcFile` の中で設定する。スクリプトの先頭には置かない（ドットソースした側に影響するため）。
- 関数は、戻り値以外のものをパイプラインに漏らさない。.NET メソッドの戻り値は `[void]` か `$null =` で捨てる。
- 標準エラーへは `[Console]::Error.WriteLine()` で書く。`Write-Error` は使わない（呼び出し側の `$ErrorActionPreference` によっては終了エラーに変わるため）。

### 2.1 主な関数

| 関数 | 役割 |
| --- | --- |
| `Invoke-RcMain -Path -Config -OutPath -DryRun` | 設定を読み、`Invoke-RcFile` を呼ぶ。結果オブジェクトを返す |
| `Read-RcSettings -ConfigPath <string or $null>` | 10章の順で設定ファイルを探し、検証して設定オブジェクト（2.2）を返す。エラーなら RcError(9) |
| `Get-RcLanguage -Settings -FilePath` | 言語キーか `$null` を返す。ファイル名の一致を拡張子より優先する |
| `Invoke-RcFile -Settings -Path -OutPath -DryRun -DisplayPath` | 1ファイルを処理して結果オブジェクト（2.3）を返す。例外を外に出さない |
| `Read-RcTextFile -Path -EncodingMode` | `@{ Text; Encoding; Bom }` を返す（第5節） |
| `Write-RcTextFile -Path -Text -Encoding -Bom` | 一時ファイルに書いてから置き換える（第5節） |
| `Get-RcComments -Language -Text` | コメントトークンの一覧を返す。言語ごとの字句解析に振り分ける（第3節） |
| `Set-RcKeepFlags -Tokens -Text -Settings -Language` | 各トークンの `Keep` を決める（第4節） |
| `Convert-RcText -Text -Tokens` | `Keep` でないトークンを削除し、5章の行ルールを適用した文字列を返す（第4.3節） |
| `New-RcError -Code -Message` | 終了コードを持った例外を作る |

### 2.2 設定オブジェクト

`Read-RcSettings` は JSON を検証し、既定値とまとめた次のハッシュテーブルを返す。これ以降の処理は JSON を直接見ない。

```
@{
  ConfigPath     = 絶対パスか $null
  ConfigDir      = 相対パスを解決する基準（設定ファイルがないときはカレントディレクトリ）
  OutputMode     = 'outDir' / 'inPlace' / $null
  OutDir         = 絶対パスか $null
  Backup         = $false
  EncodingMode   = 'auto' / 'utf8' / 'sjis'
  KeepPatterns   = string[]
  KeepRegex      = Regex[]   # コンパイル済み。CultureInvariant、caseSensitive=false なら IgnoreCase、タイムアウト1秒
  CaseSensitive  = $true
  RegionStart    = '% DEL START'
  RegionEnd      = '% DEL END'
  ExtMap         = @{ '.cpp' = 'cpp'; ... }          # キーは小文字
  NameMap        = @{ 'makefile' = 'makefile'; ... } # キーは小文字
  LangKeepPatterns = @{ java = string[]; ... }
  BatchRoot      = 絶対パスか $null
  Exclude        = string[]   # exclude と excludeFiles を合算したもの
  LogPath        = 絶対パスか $null
}
```

検証のルール（PowerShell 5.1 の `ConvertFrom-Json` を前提にする）：

- 設定ファイルは `[IO.File]::ReadAllText($p, [Text.UTF8Encoding]::new($false))` で読む（BOM の有無は問わない）。JSON の構文エラーは終了コード9。
- キー名は大文字・小文字を区別して照合する（PSCustomObject のプロパティ名は大小を区別しないため、`.PSObject.Properties` の `Name` を自分で比べる）。`_` で始まるキーはどの階層でも無視する。
- 型チェック：配列は `-is [Array]`、文字列は `-is [string]`、真偽値は `-is [bool]`。`version` は整数の 1 だけを受け付ける。`null` 値は型の違いとしてエラーにする。
- `excludeFiles` のファイルがない、または読めない場合は終了コード9。
- 拡張子は先頭が `.` でなければエラー。`.` は付けたまま小文字にして持つ。

### 2.3 結果オブジェクト

```
[pscustomobject]@{ ExitCode; Status; Removed; Kept; Message; Line }
```

- `Status`：`OK` / `UNSUPPORTED` / `ERROR`。
- `Line`：標準出力に出す結果行（spec 4章）。`DisplayPath` を使う。単一処理では `-Path` に渡された文字列そのまま、一括処理では対象ディレクトリからの相対パス（区切りは `/`）。
- `Message`：エラーの内容。`<表示パス>:<行番号>: <内容>` の形。行番号がない場合は省略する。

### 2.4 エラーの扱い

- 処理を止めるエラーは、すべて `throw (New-RcError -Code 3 -Message '...')` で投げる。例外の `Data['RcExitCode']` に終了コードを入れる。
- `Invoke-RcFile` が全体を `try/catch` で囲み、次のように終了コードに変える。
  - `RcExitCode` があればその値。
  - `RegexMatchTimeoutException` は6。
  - `IOException` と `UnauthorizedAccessException` は5。
  - それ以外は1（想定外の内部エラー。メッセージに例外の型と行番号を含める）。
- 0以外のときは、何も書き込まない（書き込みは最後の1回だけなので、それより前に失敗すれば何も変わらない）。

### 2.5 Invoke-RcFile の流れ

1. 言語を判定する。なければ `UNSUPPORTED`（2）。
2. 出力先を決める。`-OutPath` があればそれを使い、なければ `OutputMode -eq 'inPlace'` のときだけ元ファイルにする。それ以外は9。`-DryRun` のときは出力先がなくてよい。
3. ファイルを読む（第5節）。
4. トークンを取り出す → 保持を判定する → 書き換える。
5. `-DryRun` なら結果だけを返す。
6. 書き出す。元ファイルへの上書きで、内容が変わらない場合は書かない（更新日時を変えない）。`-OutPath` がある場合は内容が同じでも書く。元ファイルへの上書きで `Backup` が真なら、書き込む前に `<file>.bak` へコピーする（既存なら上書き）。

## 3. 字句解析（言語ごと）

### 3.1 トークン

```
[pscustomobject]@{ Start = <int>; End = <int>; Kind = 'line'|'block'; Fixed = $false; Keep = $false }
```

- `Start` と `End` は、テキスト（BOM を除いて読み込んだ文字列）での文字の位置。`End` は含まない。
- 行コメントの `End` は行末の改行（`\r\n` または `\n`）の直前。行末の `\` で継続するコメントは、継続先の行の末尾（改行の直前）までを1つのトークンにする。
- トークンは出現順に並び、重ならない。
- `Fixed` は固定で保持するもの（spec 7.3）。字句解析が立てる。
- 改行は `\n` と `\r\n` だけ。単独の `\r` は普通の文字として扱う。
- 閉じていないコメント・文字列・ヒアドキュメント・define などは RcError(3) を投げる。メッセージには、開始位置の行番号（1始まり）と、何が閉じていないかを含める。

### 3.2 実装の約束

- 1文字ずつ `while ($i -lt $n)` で進め、`$text[$i]` の `[char]` を比べる。パイプラインと `-match` はループの中で使わない。
- 単純な読み飛ばし（ブロックコメントの終わりや行末を探すなど）は `$text.IndexOf(...)` で一気に進める。
- 結果は `System.Collections.Generic.List[object]` に入れて返す。返すときは `,$list` とし、配列が展開されないようにする。
- 目安の性能：PowerShell 7 で 100KB の C++ ファイルを2秒以内に処理する。

### 3.3 C/C++・Java・CSS（`Get-RcCommentsCLike -Flavor cpp|java|css`）

共通：
- `/*` から `*/` までがブロックコメント。閉じていなければ3。Java の `/** */` も同じ扱い。
- `//` から行末までが行コメント（`cpp`・`java` のみ。`css` では `//` は普通の文字）。

文字列などの読み飛ばし：
- `"..."` と `'...'`：`\` は次の1文字と一緒に読み飛ばす（`\` の直後の改行も含む）。エスケープされていない改行に達したら、閉じていない文字列として3。
- `cpp`：
  - 行末 `\` による `//` コメントの継続をサポートする（行末が `\` か、`\` の直後が `\r\n`）。
  - 桁区切りの `'`（`1'000'000`、`0xFF'FF`）は文字リテラルではない。直前の文字が英数字で、その英数字の並び（`[0-9A-Za-z_']` を後ろにたどった先頭）が数字で始まる場合は、桁区切りとみなす。
  - 生文字列：`R"`、`LR"`、`uR"`、`UR"`、`u8R"` で始まり、接頭辞の直前が識別子の文字でないとき。区切り文字列 `delim` を `(` まで読み取り、`)delim"` まで読み飛ばす。見つからなければ3。
- `java`：`"""` はテキストブロック。`"""` から次の `"""` まで読み飛ばす（中の `\` は次の1文字と一緒に読み飛ばす）。
- `css`：`"..."` と `'...'` のみ。

### 3.4 TypeScript（`Get-RcCommentsTypeScript`）

- 文字列 `"` と `'` は 3.3 と同じ。
- テンプレート文字列は状態のスタックで扱う。
  - コードの状態で `` ` `` を見たらテンプレートの状態に入る。
  - テンプレートの中で `${` を見たら、コードの状態を積む。その状態は `{` と `}` の深さを持つ。
  - コードの状態で深さ0のときに `}` を見たら、テンプレートの状態に戻る。
  - テンプレートの中の `\` は次の1文字と一緒に読み飛ばす。ファイル末尾まで閉じなければ3。
- 正規表現リテラル：コードの状態で、`/` の次が `/` でも `*` でもないとき、直前の意味のあるトークン（空白とコメントは飛ばす）から判断する。
  - 正規表現とみなす：直前のトークンがない、`( , = : [ ! & | ? { } ; + - * % < > ~ ^` のどれか、またはキーワード `return typeof instanceof in of new delete void throw case do else yield await`。
  - それ以外（識別子、数値、`)`、`]`）は割り算とみなす。
  - 本体では、`\` で次の1文字を読み飛ばし、`[...]` の中の `/` では終わらない。`/` で終わったあとはフラグの英字を読み飛ばす。
  - 改行に達したら正規表現ではなかったとみなし、`/` の位置に戻って割り算として扱う（エラーにはしない）。
- 本文が正規表現 `^///\s*<reference\b` に一致する行コメントは `Fixed`。

### 3.5 HTML（`Get-RcCommentsHtml`）

- `<!--` から `-->` までがコメント。閉じていなければ3。`<!-->` と `<!--->` はそこで終わる空のコメント。
- `<!--[if` で始まるもの、`<!--<![endif]` で始まるものは `Fixed`。
- `<` の直後が英字なら開始タグとみなし、引用符（`"` `'`）の中を考慮して `>` まで読み飛ばす。タグの中の `<!--` はコメントではない。
- タグ名（大小を区別しない）が `script`、`style`、`textarea`、`title` の場合は、その後の `</タグ名` まで本文を読み飛ばす。見つからなければ3。
- `<pre>` は特別扱いしない（中のコメントも削除する）。
- `<!DOCTYPE ...>`、`<?...?>`、`</...>` は `>` まで読み飛ばす。

### 3.6 シェル（`Get-RcCommentsShell -Text [-NoHeredoc] [-Offset]`）

コードの状態：
- `#` が単語の先頭にあるときだけ、行末までのコメント。単語の先頭とは、テキストの先頭、改行・空白・タブの直後、`; & | ( ) < >` の直後のこと。
- テキストの先頭が `#!` なら、その行コメントは `Fixed`。
- `\` は次の1文字と一緒に読み飛ばす（`\#` はコメントではない）。
- `'...'` は `'` まで読み飛ばす（エスケープなし）。
- `"..."` は `\` によるエスケープを考慮する。中の `$(` はコードの状態として入れ子で処理する（コメントも削除対象）。中の `` ` `` は次の `` ` `` まで読み飛ばす。
- `` `...` `` は次のエスケープされていない `` ` `` まで読み飛ばす（中は触らない）。
- `$(` は、`(` と `)` の深さを数えながら、コードの状態を入れ子で処理する。`$((...))` も同じに扱う。`16#ff` の `#` は直前が英数字なので、コメントにならない。
- `${` は、`{` と `}` の深さを数え、引用符を考慮しながら読み飛ばす。
- `<<`（`<<<` は除く）の後に、`-`（あってもなくてもよい）、空白、区切り語（`EOF`、`'EOF'`、`"EOF"`、`\EOF`）が続けばヒアドキュメント。区切り語を順番待ちに入れる。
  - その行の改行に達したら、順番待ちの区切り語ごとに、区切り語だけの行が出るまで本文を読み飛ばす。`<<-` では行頭のタブを除いて比べる。見つからなければ3。
- 閉じていない引用符・`$(`・`${`・バッククォートは3。

既知の制限（README に書く）：`$( ... )` の中にある `case` 文の `pat)` は括弧の深さを狂わせる。

### 3.7 Makefile（`Get-RcCommentsMakefile`）

論理行（行末の `\` で継続した行をまとめたもの）ごとに処理する。

- `define`（行頭の空白、`override`、`export` の後でもよい）から `endef` までの行は触らない。`endef` がなければ3。
- タブで始まる論理行はレシピ。その論理行の部分文字列を `Get-RcCommentsShell -NoHeredoc` に渡し、返ったトークンの位置を全体の位置に直す。
  - make はレシピ行を1行ずつシェルに渡すので、ヒアドキュメントは扱わない。
  - `$$#` は直前が `$` なので、コメントにならない。
- それ以外の行では、直前が `\` でない `#` から、論理行の終わりまでがコメント。引用符は考慮しない。

### 3.8 設定ファイル .conf（`Get-RcCommentsConf`）

- 行頭の空白を除いて `#` で始まる行だけ。トークンは `#` から行末まで。

## 4. 保持の判定と書き換え

### 4.1 保持範囲（Set-RcKeepFlags の前半）

- トークンの文字列に、`RegionStart` または `RegionEnd` が序数比較（大小を区別する）で含まれるかを、出現順に調べる。
  - 範囲が開いていないときに START → 開く。
  - 範囲が開いているときに START → 4。
  - 範囲が開いていないときに END → 4。
  - 範囲が開いているときに END → 閉じる。
  - 同じトークンに START と END の両方がある場合は、START → END の順に処理する。
  - 末尾まで閉じなければ4。
- 範囲は「START トークンの開始行」から「END トークンの終了行」までの行。この行範囲と1行でも重なるトークンは、すべて `Keep`。

### 4.2 保持パターン

`Keep` は次のどれかで真になる。

- `Fixed` である。
- 保持範囲に入っている。
- `KeepPatterns` か、その言語の `LangKeepPatterns` のどれかが、トークンの文字列に含まれる（`Ordinal` / `OrdinalIgnoreCase`。.NET Framework には `String.Contains(string, StringComparison)` がないので、`IndexOf(...) -ge 0` を使う）。
- `KeepRegex` のどれかが、トークンの文字列を `\r?\n` で分けた1行に一致する。タイムアウトは例外のまま外に出し、`Invoke-RcFile` が6にする。

### 4.3 書き換え（Convert-RcText）

1. テキストを行（本文と改行）に分ける。
2. `Keep` でないトークンを、行ごとの削除範囲に変える。複数行のトークンは、開始行では開始位置から行末まで、間の行は全体、終了行では行頭から終了位置までを削除範囲にする。
3. 削除範囲がある行だけ、次を行う。
   - 削除範囲を取り除く。ある削除範囲の直前の文字と直後の文字が、どちらも同じ行にあり、どちらも空白でない場合は、空白1つに置き換える（`a/**/b` → `a b`）。HTML では置き換えない（`Convert-RcText -JoinWithSpace $false`）。
   - 残りが空白だけなら、改行ごとその行を削除する。
   - そうでなければ、行末の空白とタブを削って、改行はそのまま残す。
4. 削除範囲のない行は1文字も変えない。
5. ファイル末尾の改行：元の最終行に改行がなく、その行が削除された場合は、新しい最終行の改行を取り除く（元と同じく「末尾改行なし」にする）。

件数：`Removed` は `Keep` でないトークンの数、`Kept` は `Keep` のトークンの数。

## 5. 文字コードと書き込み

読み込み（`Read-RcTextFile`）：

1. `[IO.File]::ReadAllBytes`。
2. `EncodingMode` が `auto` のときは BOM で決める（`EF BB BF` は UTF-8、`FF FE` は UTF-16LE、`FE FF` は UTF-16BE）。
   - BOM がなければ、厳密な UTF-8（`[Text.UTF8Encoding]::new($false, $true)`）で読み、例外が出たら CP932 で読む。
   - `utf8` 指定のときは厳密な UTF-8 で読む（UTF-8 の BOM があれば保持する）。`sjis` 指定のときは CP932 で読む。
3. NUL のチェック：UTF-16 以外では、NUL バイトがあれば5。UTF-16 では、読んだ文字列に `[char]0` があれば5。
4. 往復チェック：読んだ文字列を同じエンコーディングで符号化し直し、元のバイト列（BOM を除く）と一致しなければ5（コメント以外のバイトを変えない保証のため）。
5. CP932 は `[Text.Encoding]::GetEncoding(932)` で取得する。PowerShell 7（.NET Core）では、事前に `[Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance)` を呼ぶ（`try` で囲み、5.1 では呼ばない）。

書き込み（`Write-RcTextFile`）：

- BOM のバイトと、符号化した本文を連結し、出力先と同じフォルダの一時ファイル（`<出力先>.rctmp-<GUID>`）に `WriteAllBytes` で書く。
- 出力先が既にあれば `[IO.File]::Replace($tmp, $dest, [NullString]::Value)` で置き換え、なければ `[IO.File]::Move`。PowerShell では、文字列の引数に `$null` を渡すと空文字列になるので、`[NullString]::Value` を使う。
- 失敗したら一時ファイルを消して5。

## 6. Invoke-RemoveComments.ps1

```powershell
param([string]$Config, [string]$Root, [switch]$DryRun)
$batch = @{ Config = $Config; Root = $Root; DryRun = [bool]$DryRun }   # ドットソース前に退避する
. (Join-Path $PSScriptRoot 'Remove-Comments.ps1')                       # $Config などが上書きされる
```

ドットソースすると、`Remove-Comments.ps1` の `param` の変数（`$Path`、`$Config`、`$OutPath`、`$DryRun`）が呼び出し側のスコープに作られる。そのため、自分の引数は必ず先に退避し、それ以降は `$batch` だけを使う。

流れ：

1. `Read-RcSettings` を呼ぶ。エラーなら標準エラーに出して `exit 9`。
2. 一括処理用の検証をする（どれも9）。
   - `OutputMode` が必須。`outDir` なら `OutDir` も必須。
   - 対象ディレクトリ（`-Root` があれば、カレントディレクトリ基準で解決。なければ `BatchRoot`）が存在すること。
   - `OutDir` が対象ディレクトリと同じか、その内側にないこと（パスを正規化し、大小を区別せずに前方一致で比べる。区切りの境界に注意する）。
3. 列挙：`[IO.Directory]::GetDirectories` と `GetFiles` で自前に再帰する。`.git` と `.svn` には入らない。リパースポイント（シンボリックリンクなど）のディレクトリには入らない。相対パス（区切りは `/`）の序数順に並べる。
4. 除外：グロブを正規表現に変換して照合する（`IgnoreCase`、全体一致）。最初に一致したパターンを `message` に入れる。
   - 変換：`**/` → `(?:.*/)?`、末尾の `/**` → `(?:/.*)?`、それ以外の `**` → `.*`、`*` → `[^/]*`、`?` → `[^/]`、それ以外は `[regex]::Escape`。先頭の `/` は取り除く。
5. 各ファイルについて：
   - `EXCLUDED`：除外パターンに一致した。
   - `UNSUPPORTED`：`Get-RcLanguage` が `$null`。CSV の `exitCode` は2。
   - それ以外：`Invoke-RcFile`（`outDir` なら `-OutPath` に出力先の対応するパスを渡し、`inPlace` なら渡さない）。結果が0以外なら `ERROR`。
   - `outDir` で DryRun でなければ、`EXCLUDED` と `UNSUPPORTED` を出力先にコピーする（フォルダを作り、既存は上書きする）。コピーの失敗は `ERROR`（終了コード5）。
   - 出力先にある既存のファイルを消すことはしない。
6. 表示：
   - 各ファイルの結果行を標準出力に出す。`EXCLUDED` は `EXCLUDED<TAB>path<TAB><パターン>` の形。
   - エラーの内容は標準エラーに出す。
   - 最後に `OK=n EXCLUDED=n UNSUPPORTED=n ERROR=n` を出す。
7. CSV：`LogPath` があれば、UTF-8（BOM 付き。Excel で文字化けしないため）、改行 CRLF で書く。列は spec の順。値はすべて `"` で囲み、中の `"` は2つ重ねる。`Export-Csv` は 5.1 と 7 で挙動が違うので使わない。
8. `exit`：`ERROR` があれば1、なければ0。

## 7. PowerShell 5.1 との互換のための約束

- 使わないもの：`??`、`?.`、三項演算子、パイプライン連鎖の `&&` と `||`、`ConvertFrom-Json -AsHashtable` / `-Depth`、`ForEach-Object -Parallel`、3引数以上の `Join-Path`、`[IO.Path]::GetRelativePath`、`String.Contains(string, StringComparison)`、`class`。
- `[Regex]::new(...)` や `[Text.UTF8Encoding]::new(...)` は 5.0 以降で使えるので使ってよい。
- `.ps1` ファイルは **UTF-8（BOM 付き）** で保存する。BOM がないと、日本語の Windows の 5.1 は CP932 として読み、日本語のメッセージが壊れたり構文エラーになったりする。
- `.gitattributes` で、`tests/fixtures/**` を `-text` にする（git に改行コードを変えさせない）。`*.ps1` は `text eol=crlf` にする。

## 8. テスト

### 8.1 実行方法

```
powershell -NoProfile -ExecutionPolicy Bypass -File tests/Run-Tests.ps1 [-Filter <文字列>]
pwsh -NoProfile -File tests/Run-Tests.ps1
```

- `Run-Tests.ps1` は `tests/*.Tests.ps1` を順にドットソースし、その中の `Test-Case '<名前>' { ... }` を実行する。
- 1件ごとに `PASS` / `FAIL` を表示し、最後に件数を表示する。失敗が1件でもあれば終了コード1。
- `TestLib.ps1` が提供するもの：`Test-Case`、`Assert-Equal`、`Assert-True`、`Assert-BytesEqual`（違いがあれば最初に違う位置を表示する）、`New-TestDir`（スクラッチ用の一時フォルダを作る）。
- テストは、`Remove-Comments.ps1` をドットソースし、`Invoke-RcFile` や `Read-RcSettings` を直接呼ぶ。終了コードと標準出力の形式については、実際に別プロセス（`(Get-Process -Id $PID).Path` で同じ PowerShell を起動）で確かめるテストも少数入れる。

### 8.2 期待結果ファイルによるテスト

```
tests/fixtures/<言語>/<ケース>.in.<拡張子>         入力
tests/fixtures/<言語>/<ケース>.expected.<拡張子>   期待結果（バイト単位で比べる）
tests/fixtures/<言語>/<ケース>.exit                 （任意）期待する終了コード。あれば expected は不要
tests/fixtures/<言語>/<ケース>.config.json          （任意）このケースだけの設定
```

- `fixtures.Tests.ps1` がすべてのケースを列挙し、`Invoke-RcFile` を `-OutPath`（一時フォルダ）付きで呼んで比べる。終了コード0以外が期待される場合は、出力ファイルができていないことも確かめる。
- 文字コードのテストは、テストコードの中でバイト列を作って行う（BOM 付きなどのファイルをリポジトリに置かない）。

### 8.3 CI

GitHub Actions（`.github/workflows/test.yml`）。push と pull_request で実行する。

- `windows-latest`：`powershell`（5.1）と `pwsh`（7）の両方。
- `ubuntu-latest`：`pwsh`。
