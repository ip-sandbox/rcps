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
