# Convert-RcText / Set-RcKeepFlags with hand-built tokens (generic logic)

function Test-Rewrite {
    # $Specs: array of @(needle, kind) in order; all tokens non-keep unless in $KeepIdx
    param([string]$Text, $Specs, [int[]]$KeepIdx = @())
    $tokens = New-Object 'System.Collections.Generic.List[object]'
    $from = 0
    foreach ($sp in $Specs) {
        $t = New-TestToken -Text $Text -Needle $sp[0] -Kind $sp[1] -From $from
        $tokens.Add($t)
        $from = $t.End
    }
    foreach ($i in $KeepIdx) { $tokens[$i].Keep = $true }
    return (Convert-RcText -Text $Text -Tokens $tokens)
}

Test-Case 'rewrite: trailing line comment' {
    Assert-Equal (Test-Rewrite "int a = 1; // x`n" @(, @('// x', 'line'))) "int a = 1;`n"
}
Test-Case 'rewrite: whole-line comment removed with its newline' {
    Assert-Equal (Test-Rewrite "a`n  // c`nb`n" @(, @('// c', 'line'))) "a`nb`n"
}
Test-Case 'rewrite: mid-line block gets one space when neighbours touch' {
    Assert-Equal (Test-Rewrite 'a/**/b' @(, @('/**/', 'block'))) 'a b'
    Assert-Equal (Test-Rewrite 'f(/**/x)' @(, @('/**/', 'block'))) 'f( x)'
}
Test-Case 'rewrite: no extra space when whitespace already separates' {
    Assert-Equal (Test-Rewrite 'a /**/ b' @(, @('/**/', 'block'))) 'a  b'
    Assert-Equal (Test-Rewrite 'a/* c */' @(, @('/* c */', 'block'))) 'a'
    Assert-Equal (Test-Rewrite '/* c */ b' @(, @('/* c */', 'block'))) ' b'
}
Test-Case 'rewrite: adjacent blocks merge into one space' {
    Assert-Equal (Test-Rewrite 'a/**//**/b' @(@('/**/', 'block'), @('/**/', 'block'))) 'a b'
}
Test-Case 'rewrite: two blocks in one line' {
    Assert-Equal (Test-Rewrite '/*1*/ x /*2*/ y' @(@('/*1*/', 'block'), @('/*2*/', 'block'))) ' x  y'
}
Test-Case 'rewrite: multi-line block keeps code before start and after end' {
    $t = "x = 1; /* start`nmiddle`nend */ y = 2;`n"
    Assert-Equal (Test-Rewrite $t @(, @("/* start`nmiddle`nend */", 'block'))) "x = 1;`n y = 2;`n"
}
Test-Case 'rewrite: multi-line block on whole lines (incl. empty inner line)' {
    $t = "a`n/*`n`n * x`n */`nb`n"
    Assert-Equal (Test-Rewrite $t @(, @("/*`n`n * x`n */", 'block'))) "a`nb`n"
}
Test-Case 'rewrite: multi-line block with CRLF' {
    $t = "a /* x`r`n y */ b`r`nc`r`n"
    Assert-Equal (Test-Rewrite $t @(, @("/* x`r`n y */", 'block'))) "a`r`n b`r`nc`r`n"
}
Test-Case 'rewrite: Keep token is untouched (trailing spaces too)' {
    $t = "a // keep  `nb // drop`n"
    Assert-Equal (Test-Rewrite $t @(@('// keep  ', 'line'), @('// drop', 'line')) @(0)) "a // keep  `nb`n"
}
Test-Case 'rewrite: untouched lines keep trailing whitespace; touched lines are trimmed' {
    $t = "a  `n// c`nb`t`nc /* x */  `n"
    Assert-Equal (Test-Rewrite $t @(@('// c', 'line'), @('/* x */', 'block'))) "a  `nb`t`nc`n"
}
Test-Case 'rewrite: blank lines are never compressed' {
    $t = "`n// c`n`n`na`n"
    Assert-Equal (Test-Rewrite $t @(, @('// c', 'line'))) "`n`n`na`n"
}
Test-Case 'rewrite: CRLF and LF are preserved per line' {
    $t = "a // c`r`nb`n// d`r`nc`r`n"
    Assert-Equal (Test-Rewrite $t @(@('// c', 'line'), @('// d', 'line'))) "a`r`nb`nc`r`n"
}
Test-Case 'rewrite: final line without newline, comment-only -> new last line loses its newline' {
    Assert-Equal (Test-Rewrite "a`n// c" @(, @('// c', 'line'))) 'a'
    Assert-Equal (Test-Rewrite "a`r`n// c" @(, @('// c', 'line'))) 'a'
    Assert-Equal (Test-Rewrite "a`n`n// c" @(, @('// c', 'line'))) "a`n"
    Assert-Equal (Test-Rewrite "a`n/* x */" @(, @('/* x */', 'block'))) 'a'
    Assert-Equal (Test-Rewrite "a`n/* x`n y */" @(, @("/* x`n y */", 'block'))) 'a'
}
Test-Case 'rewrite: final line without newline, trailing comment' {
    Assert-Equal (Test-Rewrite 'a // c' @(, @('// c', 'line'))) 'a'
}
Test-Case 'rewrite: final newline kept when last line has one' {
    Assert-Equal (Test-Rewrite "a`n// c`n" @(, @('// c', 'line'))) "a`n"
}
Test-Case 'rewrite: everything removed gives empty text' {
    Assert-Equal (Test-Rewrite "// a`n// b`n" @(@('// a', 'line'), @('// b', 'line'))) ''
    Assert-Equal (Test-Rewrite "// a`n// b" @(@('// a', 'line'), @('// b', 'line'))) ''
}
Test-Case 'rewrite: empty text / no tokens' {
    Assert-Equal (Convert-RcText -Text '' -Tokens (New-Object 'System.Collections.Generic.List[object]')) ''
    Assert-Equal (Convert-RcText -Text "a `n b" -Tokens (New-Object 'System.Collections.Generic.List[object]')) "a `n b"
}

# ---- Set-RcKeepFlags -------------------------------------------------------

function Get-TestKeeps {
    param([string]$Text, $Tokens, $Settings, [string]$Language = 'cpp')
    Set-RcKeepFlags -Tokens $Tokens -Text $Text -Settings $Settings -Language $Language
    return , @($Tokens | ForEach-Object { [bool]$_.Keep })
}

Test-Case 'keep: Fixed token is kept' {
    $s = New-TestSettings
    $t = "a`nb`n"
    $tok = New-RcToken -Start 0 -End 1 -Kind 'line' -Fixed $true
    $l = New-Object 'System.Collections.Generic.List[object]'; $l.Add($tok)
    Assert-Equal (Get-TestKeeps $t $l $s) @($true)
}
Test-Case 'keep: patterns (global + language) are literal and case-sensitive by default' {
    $s = New-TestSettings '{"keep":{"patterns":["Copyright"]},"languages":{"java":{"keepPatterns":["@fmt"]}}}'
    $t = "// Copyright x`n// copyright y`n// @fmt z`n// a.b`n"
    $mk = { $l = New-Object 'System.Collections.Generic.List[object]'
        $f = 0; foreach ($n in @('// Copyright x', '// copyright y', '// @fmt z', '// a.b')) { $k = New-TestToken $t $n 'line' $f; $f = $k.End; $l.Add($k) }; $l }
    Assert-Equal (Get-TestKeeps $t (& $mk) $s 'cpp') @($true, $false, $false, $false)
    Assert-Equal (Get-TestKeeps $t (& $mk) $s 'java') @($true, $false, $true, $false)
}
Test-Case 'keep: caseSensitive=false applies to patterns' {
    $s = New-TestSettings '{"keep":{"patterns":["copyright"],"caseSensitive":false}}'
    $t = '// COPYRIGHT x'
    $l = New-Object 'System.Collections.Generic.List[object]'; $l.Add((New-TestToken $t $t))
    Assert-Equal (Get-TestKeeps $t $l $s) @($true)
}
Test-Case 'keep: regex matches per line of a multi-line block' {
    $s = New-TestSettings '{"keep":{"regex":["^\\s*TICKET-\\d+"]}}'
    $t = "/* a`n  TICKET-12`n */ x /* TICKET-1 */"
    $l = New-Object 'System.Collections.Generic.List[object]'
    $b1 = New-TestToken $t "/* a`n  TICKET-12`n */" 'block'
    $b2 = New-TestToken $t '/* TICKET-1 */' 'block' $b1.End
    $l.Add($b1); $l.Add($b2)
    Assert-Equal (Get-TestKeeps $t $l $s) @($true, $false)
}
Test-Case 'keep: regex caseSensitive=false' {
    $s = New-TestSettings '{"keep":{"regex":["todo"],"caseSensitive":false}}'
    $t = '// TODO x'
    $l = New-Object 'System.Collections.Generic.List[object]'; $l.Add((New-TestToken $t $t))
    Assert-Equal (Get-TestKeeps $t $l $s) @($true)
}
Test-Case 'keep: region keeps every token overlapping its lines' {
    $s = New-TestSettings
    $t = "/* a */ c // % DEL START`nx // c1`n/* b`n c */`n// % DEL END`ny // d`n"
    $l = New-Object 'System.Collections.Generic.List[object]'
    $f = 0
    foreach ($spec in @(@('/* a */', 'block'), @('// % DEL START', 'line'), @('// c1', 'line'), @("/* b`n c */", 'block'), @('// % DEL END', 'line'), @('// d', 'line'))) {
        $k = New-TestToken $t $spec[0] $spec[1] $f; $f = $k.End; $l.Add($k)
    }
    Assert-Equal (Get-TestKeeps $t $l $s) @($true, $true, $true, $true, $true, $false)
}
Test-Case 'keep: START and END in one token' {
    $s = New-TestSettings
    $t = "// % DEL START % DEL END`n// x`n"
    $l = New-Object 'System.Collections.Generic.List[object]'
    $a = New-TestToken $t '// % DEL START % DEL END'; $b = New-TestToken $t '// x' 'line' $a.End
    $l.Add($a); $l.Add($b)
    Assert-Equal (Get-TestKeeps $t $l $s) @($true, $false)
}
Test-Case 'keep: region errors are exit code 4 with line numbers' {
    $s = New-TestSettings
    $mk = { param($t, $needles)
        $l = New-Object 'System.Collections.Generic.List[object]'; $f = 0
        foreach ($n in $needles) { $k = New-TestToken $t $n 'line' $f; $f = $k.End; $l.Add($k) }; $l }
    $t1 = "// % DEL START`n// % DEL START`n"
    Assert-RcErrorCode 4 { Set-RcKeepFlags -Tokens (& $mk $t1 @('// % DEL START', '// % DEL START')) -Text $t1 -Settings $s -Language 'cpp' } 'double start'
    $t2 = "x`n// % DEL END`n"
    Assert-RcErrorCode 4 { Set-RcKeepFlags -Tokens (& $mk $t2 @('// % DEL END')) -Text $t2 -Settings $s -Language 'cpp' } 'end only'
    $t3 = "x`n// % DEL START`ny`n"
    Assert-RcErrorCode 4 { Set-RcKeepFlags -Tokens (& $mk $t3 @('// % DEL START')) -Text $t3 -Settings $s -Language 'cpp' } 'unclosed'
    $err = $null
    try { Set-RcKeepFlags -Tokens (& $mk $t3 @('// % DEL START')) -Text $t3 -Settings $s -Language 'cpp' } catch { $err = Convert-RcException -ErrorRecord $_ }
    Assert-Equal $err.Line 2 'start line number'
}
Test-Case 'keep: region keywords are case-sensitive and customizable' {
    $s = New-TestSettings '{"keepRegion":{"start":"BEGIN-KEEP","end":"END-KEEP"}}'
    $t = "// BEGIN-KEEP`n// a`n// END-KEEP`n// % DEL START`n"
    $l = New-Object 'System.Collections.Generic.List[object]'; $f = 0
    foreach ($n in @('// BEGIN-KEEP', '// a', '// END-KEEP', '// % DEL START')) { $k = New-TestToken $t $n 'line' $f; $f = $k.End; $l.Add($k) }
    Assert-Equal (Get-TestKeeps $t $l $s) @($true, $true, $true, $false)
}

Test-Case 'rewrite: JoinWithSpace=$false joins neighbours without a space' {
    $tk = { param($t, $n) $l = New-Object 'System.Collections.Generic.List[object]'; $l.Add((New-TestToken $t $n 'block')); $l }
    Assert-Equal (Convert-RcText -Text 'a/**/b' -Tokens (& $tk 'a/**/b' '/**/') -JoinWithSpace $false) 'ab'
    Assert-Equal (Convert-RcText -Text 'a/**/b' -Tokens (& $tk 'a/**/b' '/**/')) 'a b' 'default is true'
    $t = "x /* c */`n/* d */`ny"
    $l = New-Object 'System.Collections.Generic.List[object]'
    $l.Add((New-TestToken $t '/* c */' 'block')); $l.Add((New-TestToken $t '/* d */' 'block'))
    Assert-Equal (Convert-RcText -Text $t -Tokens $l -JoinWithSpace $false) "x`ny" 'rules 1,2 still apply'
}
