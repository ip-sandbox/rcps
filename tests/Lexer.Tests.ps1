# C-like lexer (cpp / java / css): direct tests

function Get-TestTokens {
    param([string]$Text, [string]$Flavor)
    $t = Get-RcCommentsCLike -Text $Text -Flavor $Flavor
    return , $t
}
function Get-TokenTexts {
    param([string]$Text, [string]$Flavor)
    $t = Get-TestTokens $Text $Flavor
    $r = @(); foreach ($x in $t) { $r += $Text.Substring($x.Start, $x.End - $x.Start) }
    return , $r
}
function Get-LexError {
    param([string]$Text, [string]$Flavor)
    try { Get-RcCommentsCLike -Text $Text -Flavor $Flavor | Out-Null } catch { return (Convert-RcException -ErrorRecord $_) }
    return $null
}

Test-Case 'lexer: tokens, kinds and positions' {
    $t = "a // x`r`nb /* y`nz */ c"
    $tok = Get-TestTokens $t 'cpp'
    Assert-Equal $tok.Count 2
    Assert-Equal $tok[0].Kind 'line'
    Assert-Equal $t.Substring($tok[0].Start, $tok[0].End - $tok[0].Start) '// x' 'line comment excludes CRLF'
    Assert-Equal $tok[1].Kind 'block'
    Assert-Equal (Get-TokenTexts $t 'cpp')[1] "/* y`nz */"
}
Test-Case 'lexer: empty list is returned as a list, not null' {
    $tok = Get-TestTokens 'int a;' 'cpp'
    Assert-Equal $tok.Count 0
}
Test-Case 'lexer: css has no // comments; java/cpp do' {
    Assert-Equal (Get-TokenTexts 'a //b' 'css').Count 0
    Assert-Equal (Get-TokenTexts 'a //b' 'java').Count 1
}
Test-Case 'lexer: dispatcher wires cpp/java/css' {
    foreach ($l in 'cpp', 'java', 'css') {
        $t = Get-RcComments -Language $l -Text '/* a */'
        Assert-Equal $t.Count 1 $l
    }
}
Test-Case 'lexer: cpp continued // comment is one token' {
    $t = "a // x \`n y \`n z`nb"
    Assert-Equal (Get-TokenTexts $t 'cpp') @("// x \`n y \`n z")
    $t2 = "a // x \`r`n y`r`nb"
    Assert-Equal (Get-TokenTexts $t2 'cpp') @("// x \`r`n y")
    Assert-Equal (Get-TokenTexts "a // x \`n y" 'java') @('// x \') 'java has no continuation'
    Assert-Equal (Get-TokenTexts 'a // x \' 'cpp') @('// x \') 'backslash at EOF'
}
Test-Case 'lexer: digit separators vs char literals' {
    Assert-Equal (Get-TokenTexts "int a = 1'000; // c`nint b = 0xFF'FF; /* d */" 'cpp') @('// c', '/* d */')
    Assert-Equal (Get-TokenTexts "char c = '/'; // c" 'cpp') @('// c')
    Assert-Equal (Get-TokenTexts "x = u8'/*'; // c" 'cpp') @('// c')
}
Test-Case 'lexer: raw strings and prefixes' {
    Assert-Equal (Get-TokenTexts 'a = R"x( /* ")" )x"; // c' 'cpp') @('// c')
    Assert-Equal (Get-TokenTexts 'a = LR"(//)"; b = uR"(//)"; c = UR"(//)"; d = u8R"(//)"; // c' 'cpp') @('// c')
    # identifier ending in R is not a raw string prefix: "..." is an ordinary string (escapes apply)
    Assert-Equal (Get-TokenTexts 'fooR"a\"//b"; // c' 'cpp') @('// c')
    Assert-Equal (Get-TokenTexts 'R"(a\)"; // c' 'cpp') @('// c') 'no escapes in raw strings'
}
Test-Case 'lexer: java text block' {
    $t = "s = `"`"`"`n // x \`"`"`" */ `n`"`"`"; // c"
    Assert-Equal (Get-TokenTexts $t 'java') @('// c')
}
Test-Case 'lexer: errors are code 3 with the start line number' {
    $e = Get-LexError "a;`nb;`n/* open`nc;" 'cpp'
    Assert-Equal $e.Code 3; Assert-Equal $e.Line 3; Assert-True ($e.Message -like '*block comment*') $e.Message
    $e = Get-LexError "a;`n`nconst char *s = `"abc;`nb;" 'cpp'
    Assert-Equal $e.Code 3; Assert-Equal $e.Line 3; Assert-True ($e.Message -like '*string*') $e.Message
    $e = Get-LexError "a;`nauto s = R`"x(abc )y`";`n" 'cpp'
    Assert-Equal $e.Code 3; Assert-Equal $e.Line 2; Assert-True ($e.Message -like '*raw string*') $e.Message
    $e = Get-LexError "a;`nchar c = 'a;`n" 'cpp'
    Assert-Equal $e.Code 3; Assert-Equal $e.Line 2
    $e = Get-LexError "a;`n`n`ns = `"`"`"`nabc" 'java'
    Assert-Equal $e.Code 3; Assert-Equal $e.Line 4; Assert-True ($e.Message -like '*text block*') $e.Message
    $e = Get-LexError "a{}`n/* x" 'css'
    Assert-Equal $e.Code 3; Assert-Equal $e.Line 2
    $e = Get-LexError "a{content:`"x`n}" 'css'
    Assert-Equal $e.Code 3; Assert-Equal $e.Line 1
}
Test-Case 'lexer: error message through Invoke-RcFile contains path and start line' {
    $d = New-TestDir
    $in = Join-Path $d 'a.cpp'
    [IO.File]::WriteAllBytes($in, (Get-TestUtf8 "int a;`n`n/* open`n"))
    $r = Invoke-RcFile -Settings (New-TestSettings) -Path $in -OutPath (Join-Path $d 'o.cpp') -DisplayPath 'a.cpp'
    Assert-Equal $r.ExitCode 3
    Assert-True ($r.Message -like 'a.cpp:3: *') $r.Message
}
Test-Case 'lexer: escaped backslash-newline inside string continues it' {
    Assert-Equal (Get-TokenTexts "s = `"a\`r`nb // x`"; // c" 'cpp') @('// c')
}

Test-Case 'perf: ~100KB C++ file' {
    $block = @'
#include <stdio.h> // header
/* block comment
   spanning lines */
int add(int a, int b) { // add
    const char *s = "a // b /* c */"; /* trailing */
    char q = '\''; int n = 1'000'000;
    auto r = R"x( // raw */ )x";
    return a + b; // sum
}

'@
    $sb = New-Object System.Text.StringBuilder
    while ($sb.Length -lt 100000) { [void]$sb.Append($block.Replace("`r`n", "`n")) }
    $text = $sb.ToString()
    $d = New-TestDir
    $in = Join-Path $d 'big.cpp'
    [IO.File]::WriteAllBytes($in, (Get-TestUtf8 $text))
    $s = New-TestSettings '{"keep":{"patterns":["Copyright"],"regex":["TICKET-\\d+"]}}'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-RcFile -Settings $s -Path $in -OutPath (Join-Path $d 'big.out.cpp') -DisplayPath 'big.cpp'
    $sw.Stop()
    Write-Host ("      perf: {0:N0} bytes, {1} comments removed, {2:N2}s" -f $text.Length, $r.Removed, $sw.Elapsed.TotalSeconds)
    Assert-Equal $r.ExitCode 0 $r.Message
    Assert-True ($r.Removed -gt 1000) 'many comments'
    Assert-True ($sw.Elapsed.TotalSeconds -lt 5) "took $($sw.Elapsed.TotalSeconds)s"
}

# ---- TypeScript / HTML -----------------------------------------------------

function Get-TsTexts { param([string]$Text) $t = Get-RcCommentsTypeScript -Text $Text; $r = @(); foreach ($x in $t) { $r += $Text.Substring($x.Start, $x.End - $x.Start) }; return , $r }
function Get-HtmlTexts { param([string]$Text) $t = Get-RcCommentsHtml -Text $Text; $r = @(); foreach ($x in $t) { $r += $Text.Substring($x.Start, $x.End - $x.Start) }; return , $r }
function Get-ErrOf { param([scriptblock]$B) try { & $B | Out-Null } catch { return (Convert-RcException -ErrorRecord $_) }; return $null }

Test-Case 'ts: dispatcher wires typescript and html' {
    Assert-Equal (Get-RcComments -Language 'typescript' -Text '/* a */').Count 1
    Assert-Equal (Get-RcComments -Language 'html' -Text '<!-- a -->').Count 1
}
Test-Case 'ts: comment inside ${} is code, template text is not' {
    Assert-Equal (Get-TsTexts 'x = `a // b ${ c /* d */ } e /* f */`; // g') @('/* d */', '// g')
}
Test-Case 'ts: nested templates and braces' {
    Assert-Equal (Get-TsTexts 'x = `a${ `b${ {k: `}`}.k /* i */ }` /* j */ }d`; // g') @('/* i */', '/* j */', '// g')
}
Test-Case 'ts: regex vs division heuristic' {
    Assert-Equal (Get-TsTexts 'a = x / y; // c1 / 2') @('// c1 / 2')
    Assert-Equal (Get-TsTexts 'a = /\/\//; // c') @('// c')
    Assert-Equal (Get-TsTexts 'a = /[/]/g; // c') @('// c')
    Assert-Equal (Get-TsTexts 'if (x) return /"/; // c') @('// c') 'quote inside regex'
    Assert-Equal (Get-TsTexts "a = b / c; s = `"x`"; // c") @('// c')
    Assert-Equal (Get-TsTexts "a = 1 / 2 / 3; // c") @('// c')
}
Test-Case 'ts: regex falling back to division at a newline' {
    # '/' after "=" looks like a regex start but the line ends without a closing '/': division, no error
    Assert-Equal (Get-TsTexts "a = / b;`nc = 1; // c") @('// c')
}
Test-Case 'ts: reference directive is Fixed only for "/// <reference"' {
    $t = Get-RcCommentsTypeScript -Text "/// <reference path=`"a`" />`n/// other`n  /// <reference types=`"b`" />  `n"
    Assert-Equal $t.Count 3
    Assert-Equal @($t | ForEach-Object { $_.Fixed }) @($true, $false, $true)
}
Test-Case 'ts: errors are code 3 with start line' {
    $e = Get-ErrOf { Get-RcCommentsTypeScript -Text "a;`n`nx = ``abc`nd" }
    Assert-Equal $e.Code 3; Assert-Equal $e.Line 3
    $e = Get-ErrOf { Get-RcCommentsTypeScript -Text "a;`nx = ``a`${ b`nc" }
    Assert-Equal $e.Code 3; Assert-Equal $e.Line 2
    $e = Get-ErrOf { Get-RcCommentsTypeScript -Text "a;`n/* x" }
    Assert-Equal $e.Code 3; Assert-Equal $e.Line 2
    $e = Get-ErrOf { Get-RcCommentsTypeScript -Text "a;`ns = 'abc`n" }
    Assert-Equal $e.Code 3; Assert-Equal $e.Line 2
}
Test-Case 'html: comments, Fixed conditional comments' {
    $t = Get-RcCommentsHtml -Text "<!-- a --><!--[if IE]>x<![endif]--><!--<![endif]--><!-- b -->"
    Assert-Equal @($t | ForEach-Object { $_.Fixed }) @($false, $true, $true, $false)
}
Test-Case 'html: raw-text elements, case-insensitive, name boundary' {
    Assert-Equal (Get-HtmlTexts '<SCRIPT><!-- x --></ScRiPt><!-- y -->') @('<!-- y -->')
    Assert-Equal (Get-HtmlTexts '<scripts><!-- x --></scripts>') @('<!-- x -->')
    Assert-Equal (Get-HtmlTexts '<script src="a"/><!-- x --></script><!-- y -->') @('<!-- y -->')
    Assert-Equal (Get-HtmlTexts '<script>a</scripts> <!-- x --></script><!-- y -->') @('<!-- y -->') '</scripts is not the end tag'
    Assert-Equal (Get-HtmlTexts '<title><!-- x --></title><textarea><!-- z --></textarea><!-- y -->') @('<!-- y -->')
    Assert-Equal (Get-HtmlTexts '<pre><!-- x --></pre>') @('<!-- x -->')
}
Test-Case 'html: attribute values and declarations' {
    Assert-Equal (Get-HtmlTexts '<a href="<!-- x -->" t=''<!--''>t</a><!-- y -->') @('<!-- y -->')
    Assert-Equal (Get-HtmlTexts '<!DOCTYPE html><?xml a="<!-- x -->"?></p><!-- y -->') @('<!-- y -->')
    Assert-Equal (Get-HtmlTexts 'a < b <!-- y -->') @('<!-- y -->')
}
Test-Case 'html: errors are code 3 with start line' {
    $e = Get-ErrOf { Get-RcCommentsHtml -Text "a`n<!-- x`n" }
    Assert-Equal $e.Code 3; Assert-Equal $e.Line 2
    $e = Get-ErrOf { Get-RcCommentsHtml -Text "a`n`n<script>`nx" }
    Assert-Equal $e.Code 3; Assert-Equal $e.Line 3
    $e = Get-ErrOf { Get-RcCommentsHtml -Text "a`n<p class=`"x>`n" }
    Assert-Equal $e.Code 3; Assert-Equal $e.Line 2
}

function Measure-Lang {
    param([string]$Block, [string]$Ext, [string]$Json = '{}')
    $sb = New-Object System.Text.StringBuilder
    while ($sb.Length -lt 100000) { [void]$sb.Append($Block.Replace("`r`n", "`n")) }
    $text = $sb.ToString()
    $d = New-TestDir
    $in = Join-Path $d "big.$Ext"
    [IO.File]::WriteAllBytes($in, (Get-TestUtf8 $text))
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-RcFile -Settings (New-TestSettings $Json) -Path $in -OutPath (Join-Path $d "out.$Ext") -DisplayPath "big.$Ext"
    $sw.Stop()
    Write-Host ("      perf {0}: {1:N0} bytes, {2} comments removed, {3:N2}s" -f $Ext, $text.Length, $r.Removed, $sw.Elapsed.TotalSeconds)
    Assert-Equal $r.ExitCode 0 $r.Message
    Assert-True ($sw.Elapsed.TotalSeconds -lt 5) "took $($sw.Elapsed.TotalSeconds)s"
    return $r
}

Test-Case 'perf: ~100KB TypeScript file' {
    $block = @'
/// <reference path="x" />
import { a } from "./a"; // import
/* block
   comment */
export function f(x: number): string { // f
    const re = /ab+c\/\/[/]/gi; const d = x / 2 / 3;
    return `v=${ x /* in */ } and ${ `n${x}` } // not` + "s // str"; /* t */
}

'@
    $r = Measure-Lang $block 'ts'
    Assert-True ($r.Removed -gt 1000) 'many comments'
}
Test-Case 'perf: ~100KB HTML file' {
    $block = @'
<!-- header -->
<div class="a" title="<!-- x -->">
  <p>text</p> <!-- trailing -->
  <script>var a = 1; // js <!-- x --></script>
  <style>/* css */ p { color: red }</style>
  <!--
    multi line
  -->
  <textarea><!-- keep --></textarea>
</div>

'@
    $r = Measure-Lang $block 'html'
    Assert-True ($r.Removed -gt 1000) 'many comments'
}

Test-Case 'ts: reference directive variants are Fixed' {
    $t = Get-RcCommentsTypeScript -Text "///<reference a />`n///   <reference b />`n/// <referenced c />`n/// plain`n"
    Assert-Equal @($t | ForEach-Object { $_.Fixed }) @($true, $true, $false, $false)
}
Test-Case 'html: <!--> and <!---> are empty comments' {
    Assert-Equal (Get-HtmlTexts 'a<!-->b<!--->c<!-- d -->') @('<!-->', '<!--->', '<!-- d -->')
}

# ---- shell / Makefile ------------------------------------------------------

function Get-ShTexts { param([string]$Text, [switch]$NoHeredoc) $t = Get-RcCommentsShell -Text $Text -NoHeredoc:$NoHeredoc; $r = @(); foreach ($x in $t) { $r += $Text.Substring($x.Start, $x.End - $x.Start) }; return , $r }
function Get-MkTexts { param([string]$Text) $t = Get-RcCommentsMakefile -Text $Text; $r = @(); foreach ($x in $t) { $r += $Text.Substring($x.Start, $x.End - $x.Start) }; return , $r }

Test-Case 'sh: dispatcher wires shell and makefile' {
    Assert-Equal (Get-RcComments -Language 'shell' -Text "# a`n").Count 1
    Assert-Equal (Get-RcComments -Language 'makefile' -Text "# a`n").Count 1
}
Test-Case 'sh: shebang is Fixed only at the very start' {
    $t = Get-RcCommentsShell -Text "#!/bin/sh`n#!/bin/sh`n"
    Assert-Equal @($t | ForEach-Object { $_.Fixed }) @($true, $false)
}
Test-Case 'sh: word-start rule for #' {
    Assert-Equal (Get-ShTexts 'echo $# a#b;#c') @('#c')
    Assert-Equal (Get-ShTexts "a&#x`nb|#y`n(#z") @('#x', '#y', '#z')
    Assert-Equal (Get-ShTexts 'echo \# "#" ''#'' `#` # d') @('# d')
}
Test-Case 'sh: -Offset shifts token positions' {
    $t = Get-RcCommentsShell -Text 'ab # c' -Offset 10
    Assert-Equal $t[0].Start 13; Assert-Equal $t[0].End 16
}
Test-Case 'sh: -NoHeredoc ignores << ; heredoc handling otherwise' {
    Assert-Equal (Get-ShTexts "cat <<EOF # x`n# body`nEOF`n# y" -NoHeredoc) @('# x', '# body', '# y')
    Assert-Equal (Get-ShTexts "cat <<EOF # x`n# body`nEOF`n# y") @('# x', '# y')
}
Test-Case 'sh: several heredocs on one line, <<- with tabs' {
    $t = "cat <<A <<-B # c`nbody # 1`nA`n`t# body2`n`tB`n# d"
    Assert-Equal (Get-ShTexts $t) @('# c', '# d')
}
Test-Case 'sh: heredoc terminator must match exactly (CRLF tolerated)' {
    Assert-Equal (Get-ShTexts "cat <<E`r`nEOF`r`n# not`r`nE`r`n# yes") @('# yes')
}
Test-Case 'sh: nested contexts' {
    Assert-Equal (Get-ShTexts "x=`"`$(echo `"`$(echo `"#`" # in2`n)`" # in1`n)`" # out") @('# in2', '# in1', '# out')
    Assert-Equal (Get-ShTexts 'x=${a:-$(echo ")")} # c') @('# c')
}
Test-Case 'sh: errors are code 3 with the start line' {
    $e = Get-ErrOf { Get-RcCommentsShell -Text "a`nb`necho 'x`n" }
    Assert-Equal $e.Code 3; Assert-Equal $e.Line 3
    $e = Get-ErrOf { Get-RcCommentsShell -Text "a`n`"x`n" }
    Assert-Equal $e.Code 3; Assert-Equal $e.Line 2
    $e = Get-ErrOf { Get-RcCommentsShell -Text "a`n`necho `$(x`n" }
    Assert-Equal $e.Code 3; Assert-Equal $e.Line 3
    $e = Get-ErrOf { Get-RcCommentsShell -Text "a`ncat <<END`nx`n" }
    Assert-Equal $e.Code 3; Assert-Equal $e.Line 2
    $e = Get-ErrOf { Get-RcCommentsShell -Text "a`necho `${x`n" }
    Assert-Equal $e.Code 3; Assert-Equal $e.Line 2
}
Test-Case 'mk: comment rules' {
    Assert-Equal (Get-MkTexts "A = 1 # c`nB = a\#b`nC = 2 # x \`n more`nD") @('# c', ('# x \' + "`n" + ' more'))
    Assert-Equal (Get-MkTexts "`techo `"#`" # c`n`techo `$`$# # d") @('# c', '# d')
}
Test-Case 'mk: define / endef untouched, nesting, missing endef is 3 with start line' {
    Assert-Equal (Get-MkTexts "define A`n# x`ndefine B`n# y`nendef`n# z`nendef`n# out") @('# out')
    $e = Get-ErrOf { Get-RcCommentsMakefile -Text "a = 1`n`n override export define X`n# c`n" }
    Assert-Equal $e.Code 3; Assert-Equal $e.Line 3
}
Test-Case 'mk: recipe shell errors report the file line' {
    $e = Get-ErrOf { Get-RcCommentsMakefile -Text "a:`n`techo ok`n`techo 'x \`n y`n" }
    Assert-Equal $e.Code 3; Assert-Equal $e.Line 3
}
Test-Case 'mk: file named Makefile (no extension) is processed' {
    $d = New-TestDir
    $in = Join-Path $d 'Makefile'
    $fx = Join-Path $global:RcTestState.Fixtures 'makefile'
    [IO.File]::Copy((Join-Path $fx 'basic.in.mk'), $in)
    $r = Invoke-RcFile -Settings (New-TestSettings) -Path $in -OutPath (Join-Path $d 'out/Makefile') -DisplayPath 'Makefile'
    Assert-Equal $r.ExitCode 0 $r.Message
    Assert-BytesEqual ([IO.File]::ReadAllBytes((Join-Path $d 'out/Makefile'))) ([IO.File]::ReadAllBytes((Join-Path $fx 'basic.expected.mk')))
}
Test-Case 'perf: ~100KB shell file' {
    $block = @'
#!/bin/sh
# header comment
name="a # b"; echo "$(echo "x" # c1
)" ${name#a} $# # trailing
cat <<EOF # c2
# body $(not run)
EOF
case $x in a) echo '#' ;; # c3
esac
for f in `ls`; do echo "$f" # c4
done

'@
    $r = Measure-Lang $block 'sh'
    Assert-True ($r.Removed -gt 1000) 'many comments'
}
Test-Case 'perf: ~100KB Makefile' {
    $block = "CC = gcc # compiler`nall: dep # c`n`t@echo `"#`" # s`n`techo a \`n`t  b # c2`n# whole`n`n"
    $r = Measure-Lang $block 'mk'
    Assert-True ($r.Removed -gt 1000) 'many comments'
}
