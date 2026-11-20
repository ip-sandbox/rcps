# Regression tests for the code-review fixes (trailing whitespace, TS ++/--, HTML attrs, shell arithmetic, case-sensitive chars, outDir ancestor)

# runs a whole file through Invoke-RcFile; returns @{ R = result; Out = output text or $null }
function Convert-TestFull {
    param([string]$Ext, [string]$Text)
    $d = New-TestDir
    $in = Join-Path $d "in$Ext"
    $out = Join-Path $d "out$Ext"
    [IO.File]::WriteAllBytes($in, (Get-TestUtf8 $Text))
    $r = Invoke-RcFile -Settings (New-TestSettings '{}') -Path $in -OutPath $out -DisplayPath "in$Ext"
    $o = $null
    if ([IO.File]::Exists($out)) { $o = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($out)) }
    return @{ R = $r; Out = $o }
}

# ---- 2. trailing whitespace ------------------------------------------------
Test-Case 'review2: whitespace inside a template literal after a mid-line comment is kept' {
    $r = Convert-TestFull '.ts' "f(/* c */ ``a   `nb``);`n"
    Assert-Equal $r.R.ExitCode 0 $r.R.Message
    Assert-Equal $r.Out "f( ``a   `nb``);`n"
}
Test-Case 'review2: whitespace inside a C++ raw string after a mid-line comment is kept' {
    $r = Convert-TestFull '.cpp' "/* c */ R`"(abc   `n)`";`n"
    Assert-Equal $r.R.ExitCode 0 $r.R.Message
    Assert-Equal $r.Out " R`"(abc   `n)`";`n"
}
Test-Case 'review2: whitespace before a line-end comment or a multi-line block start is trimmed' {
    Assert-Equal (Convert-TestFull '.c' "int a = 1;   // x`n").Out "int a = 1;`n"
    Assert-Equal (Convert-TestFull '.c' "x;   /* start`n end */`n").Out "x;`n"
    Assert-Equal (Convert-TestFull '.c' "x;   /* start`n end */ y;   `n").Out "x;`n y;   `n"
}
Test-Case 'review2: original trailing whitespace after a mid-line comment is kept' {
    Assert-Equal (Convert-TestFull '.c' "a /* c */ b   `n").Out "a  b   `n"
}
Test-Case 'review2: rule 8 still keeps whitespace before a trailing backslash' {
    Assert-Equal (Convert-TestFull '.sh' "echo a \  # c`necho b`n").Out "echo a \  `necho b`n"
}

# ---- 3. TypeScript postfix ++ / -- ----------------------------------------
Test-Case 'review3: ts postfix ++/-- before / is a division' {
    $r = Convert-TestFull '.ts' "x = i++ / 2; s = '/';`n"
    Assert-Equal $r.R.ExitCode 0 $r.R.Message
    Assert-Equal $r.Out "x = i++ / 2; s = '/';`n"
    $r2 = Convert-TestFull '.ts' "n-- / 2; // note`n"
    Assert-Equal $r2.R.ExitCode 0 $r2.R.Message
    Assert-Equal $r2.Out "n-- / 2;`n"
}
Test-Case 'review3: ts regex after unary/binary + stays a regex' {
    $r = Convert-TestFull '.ts' "a = +/re/.source; // c`n"
    Assert-Equal $r.Out "a = +/re/.source;`n"
    $r2 = Convert-TestFull '.ts' "x = y + /[/]x/.test(s); // c`n"
    Assert-Equal $r2.Out "x = y + /[/]x/.test(s);`n"
}

# ---- 4. HTML attributes ----------------------------------------------------
Test-Case 'review4: html unquoted attribute value containing a quote' {
    $r = Convert-TestFull '.html' "<a title=it's>x</a><!-- c --><p class='y'>`n"
    Assert-Equal $r.R.ExitCode 0 $r.R.Message
    Assert-Equal $r.Out "<a title=it's>x</a><p class='y'>`n"
    $r2 = Convert-TestFull '.html' "<a title=say`"hi>x</a><!-- c -->`n"
    Assert-Equal $r2.Out "<a title=say`"hi>x</a>`n"
}
Test-Case 'review4: html quoted values containing > still work' {
    $r = Convert-TestFull '.html' "<a title = `"a>b`" alt='<!-- x -->'>t</a><!-- c -->`n"
    Assert-Equal $r.R.ExitCode 0 $r.R.Message
    Assert-Equal $r.Out "<a title = `"a>b`" alt='<!-- x -->'>t</a>`n"
}

# ---- 5. shell arithmetic ---------------------------------------------------
Test-Case 'review5: (( x = y << 2 )) is not a here-document' {
    $r = Convert-TestFull '.sh' "(( x = y << 2 ))`necho hi # c`n"
    Assert-Equal $r.R.ExitCode 0 $r.R.Message
    Assert-Equal $r.Out "(( x = y << 2 ))`necho hi`n"
}
Test-Case 'review5: let x=1<<2 is not a here-document' {
    $r = Convert-TestFull '.sh' "let x=1<<2 # c`necho hi # d`n"
    Assert-Equal $r.R.ExitCode 0 $r.R.Message
    Assert-Equal $r.Out "let x=1<<2`necho hi`n"
    $r2 = Convert-TestFull '.sh' "echo a; let x=1<<2; echo b # c`n"
    Assert-Equal $r2.R.ExitCode 0 $r2.R.Message
    Assert-Equal $r2.Out "echo a; let x=1<<2; echo b`n"
}
Test-Case 'review5: real here-documents still work' {
    $r = Convert-TestFull '.sh' "cat <<EOF`n# not a comment`nEOF`necho x # c`n"
    Assert-Equal $r.R.ExitCode 0 $r.R.Message
    Assert-Equal $r.Out "cat <<EOF`n# not a comment`nEOF`necho x`n"
    $r2 = Convert-TestFull '.sh' "letter <<EOF`n# keep`nEOF`n"
    Assert-Equal $r2.Out "letter <<EOF`n# keep`nEOF`n"
    $r3 = Convert-TestFull '.sh' "echo `$((1<<2)) # c`ncat <<EOF`n# in`nEOF`n"
    Assert-Equal $r3.Out "echo `$((1<<2))`ncat <<EOF`n# in`nEOF`n"
}

# ---- 6. case-sensitive char comparisons ------------------------------------
Test-Case 'review6: C++ lowercase r"x" is an ordinary string, raw-string prefixes are exact' {
    $r = Convert-TestFull '.cpp' "s = r`"x // not`"; // c`n"
    Assert-Equal $r.R.ExitCode 0 $r.R.Message
    Assert-Equal $r.Out "s = r`"x // not`";`n"
    # lR"( is not a raw-string prefix: the string ends at the first quote
    $r2 = Convert-TestFull '.cpp' "s = lR`"(a`" // c`n"
    Assert-Equal $r2.R.ExitCode 0 $r2.R.Message
    Assert-Equal $r2.Out "s = lR`"(a`"`n"
    # u8R / LR / uR / UR are raw
    $r3 = Convert-TestFull '.cpp' "a = u8R`"x(`" // in )x`"; // c`n"
    Assert-Equal $r3.Out "a = u8R`"x(`" // in )x`";`n"
    # U8R is not a raw prefix
    $r4 = Convert-TestFull '.cpp' "a = U8R`"x(`" // c`n"
    Assert-Equal $r4.Out "a = U8R`"x(`"`n"
}
Test-Case 'review6: HTML tag names are matched case-insensitively' {
    $r = Convert-TestFull '.html' "<SCRIPT>var a; <!-- keep --></SCRIPT><!-- c -->`n<Style>/* x */ <!-- k --></STYLE>`n"
    Assert-Equal $r.R.ExitCode 0 $r.R.Message
    Assert-Equal $r.Out "<SCRIPT>var a; <!-- keep --></SCRIPT>`n<Style>/* x */ <!-- k --></STYLE>`n"
}
Test-Case 'review6: shell LET is not the let builtin' {
    $r = Convert-TestFull '.sh' "LET x=1 <<EOF`n# keep`nEOF`necho # c`n"
    Assert-Equal $r.R.ExitCode 0 $r.R.Message
    Assert-Equal $r.Out "LET x=1 <<EOF`n# keep`nEOF`necho`n"
}

# ---- 1. outDir containing the root -----------------------------------------
Test-Case 'review1: outDir that contains the root -> exit 9, nothing written' {
    $d = New-BatchTree @{ 'a.c' = "int a; // c`n" }
    $r = Invoke-TestBatch $d '{"output":{"mode":"outDir","outDir":"."},"batch":{"root":"src"}}'
    Assert-Equal $r.ExitCode 9
    Assert-Equal $r.Rows.Count 0
    Assert-BytesEqual (Read-TestBytes (Join-Path $d 'src/a.c')) (Get-TestUtf8 "int a; // c`n")
    $r2 = Invoke-TestBatch $d ('{"output":{"mode":"outDir","outDir":' + (ConvertTo-Json (ConvertTo-JsonPath $d)) + '},"batch":{"root":"src"}}')
    Assert-Equal $r2.ExitCode 9
    $r3 = Invoke-TestBatch $d '{"output":{"mode":"outDir","outDir":".."},"batch":{"root":"src"}}'
    Assert-Equal $r3.ExitCode 9
}
Test-Case 'review1: sibling outDirs are still fine' {
    $d = New-BatchTree @{ 'a.c' = "int a; // c`n" }
    Assert-Equal (Invoke-TestBatch $d '{"output":{"mode":"outDir","outDir":"src2"},"batch":{"root":"src"}}').ExitCode 0
    Assert-Equal (Invoke-TestBatch $d '{"output":{"mode":"outDir","outDir":"../outsib"},"batch":{"root":"src"}}').ExitCode 0
    Assert-Equal (Invoke-TestBatch $d '{"output":{"mode":"outDir","outDir":"o/ut"},"batch":{"root":"src"}}').ExitCode 0
}
