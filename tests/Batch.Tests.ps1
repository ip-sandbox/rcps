# Batch processing tests (src/Invoke-RemoveComments.ps1)
# Dot-sourcing the batch script defines its functions (and overwrites $Config/$Root/$DryRun/$Path/$OutPath/$batch here).
. (Join-Path $global:RcTestState.Root 'src/Invoke-RemoveComments.ps1')

# test names for the directory layout: <dir>/src (target), <dir>/out (outDir), <dir>/cfg.json
function New-BatchTree {
    param([hashtable]$Files)
    $d = New-TestDir
    $src = Join-Path $d 'src'
    foreach ($k in $Files.Keys) {
        $p = Join-Path $src $k.Replace('/', [string][IO.Path]::DirectorySeparatorChar)
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($p))
        $v = $Files[$k]
        if ($v -is [byte[]]) { [IO.File]::WriteAllBytes($p, $v) } else { [IO.File]::WriteAllBytes($p, (Get-TestUtf8 $v)) }
    }
    if (-not [IO.Directory]::Exists($src)) { [void][IO.Directory]::CreateDirectory($src) }
    return $d
}

function ConvertTo-JsonPath { param([string]$P) return $P.Replace('\', '/') }

function Invoke-TestBatch {
    param([string]$Dir, [string]$Json, [string]$Root, [switch]$DryRun)
    $cfg = New-TestConfig -Dir $Dir -Json $Json
    $emptyScriptDir = New-TestDir
    if ($Root) { return (Invoke-RcBatch -Config $cfg -Root $Root -DryRun:$DryRun -ScriptDir $emptyScriptDir) }
    return (Invoke-RcBatch -Config $cfg -DryRun:$DryRun -ScriptDir $emptyScriptDir)
}

$script:OutDirJson = '"output":{"mode":"outDir","outDir":"out"},"batch":{"root":"src"}'

function Read-TestBytes { param([string]$P) return , [IO.File]::ReadAllBytes($P) }
function Test-Exists { param([string]$P) return [IO.File]::Exists($P) }

Test-Case 'batch: outDir mirrors; EXCLUDED and UNSUPPORTED are copied byte-identical' {
    $bin = [byte[]](0, 1, 2, 255, 254)
    $d = New-BatchTree @{
        'a.conf'              = "# c`nk=1`n"
        'sub/deep/b.c'        = "int a; // x`r`nint b;`r`n"
        'third_party/z.c'     = "int z; // keep me`n"
        'README.md'           = "# readme // not code`n"
        'sub/data.bin'        = $bin
    }
    $r = Invoke-TestBatch $d ('{' + $script:OutDirJson + ',"exclude":["third_party/**"]}')
    Assert-Equal $r.ExitCode 0 ($r.ErrorLines -join '|')
    $o = Join-Path $d 'out'
    Assert-BytesEqual (Read-TestBytes (Join-Path $o 'a.conf')) (Get-TestUtf8 "k=1`n")
    Assert-BytesEqual (Read-TestBytes (Join-Path $o 'sub/deep/b.c')) (Get-TestUtf8 "int a;`r`nint b;`r`n")
    Assert-BytesEqual (Read-TestBytes (Join-Path $o 'third_party/z.c')) (Get-TestUtf8 "int z; // keep me`n")
    Assert-BytesEqual (Read-TestBytes (Join-Path $o 'README.md')) (Get-TestUtf8 "# readme // not code`n")
    Assert-BytesEqual (Read-TestBytes (Join-Path $o 'sub/data.bin')) $bin
    Assert-Equal $r.Counts['OK'] 2
    Assert-Equal $r.Counts['EXCLUDED'] 1
    Assert-Equal $r.Counts['UNSUPPORTED'] 2
    # originals untouched
    Assert-BytesEqual (Read-TestBytes (Join-Path $d 'src/a.conf')) (Get-TestUtf8 "# c`nk=1`n")
}

Test-Case 'batch: stdout lines are sorted (ordinal) with EXCLUDED pattern and summary' {
    $d = New-BatchTree @{ 'b.conf' = "# x`n"; 'a.conf' = "k=1`n"; 'B.md' = 'x'; 'v/x.c' = 'int x;' }
    $r = Invoke-TestBatch $d ('{' + $script:OutDirJson + ',"exclude":["v/**"]}')
    Assert-Equal $r.Lines @(
        "UNSUPPORTED`tB.md",
        "OK`ta.conf`tremoved=0`tkept=0",
        "OK`tb.conf`tremoved=1`tkept=0",
        "EXCLUDED`tv/x.c`tv/**",
        'OK=2 EXCLUDED=1 UNSUPPORTED=1 ERROR=0')
}

Test-Case 'batch: glob conversion' {
    function Test-Glob([string]$g, [string]$p) { return (Convert-RcGlobToRegex -Glob $g).IsMatch($p) }
    Assert-True (Test-Glob 'third_party/**' 'third_party/a/b.c')
    Assert-True (Test-Glob 'third_party/**' 'third_party/a.c')
    Assert-True (-not (Test-Glob 'third_party/**' 'xthird_party/a.c'))
    Assert-True (Test-Glob '**/vendor/**' 'vendor/a.c')
    Assert-True (Test-Glob '**/vendor/**' 'a/b/vendor/c/d.c')
    Assert-True (-not (Test-Glob '**/vendor/**' 'a/myvendor/c.c'))
    Assert-True (Test-Glob 'src/lib/zlib*.c' 'src/lib/zlib.c')
    Assert-True (Test-Glob 'src/lib/zlib*.c' 'src/lib/zlib_x.c')
    Assert-True (-not (Test-Glob 'src/lib/zlib*.c' 'src/lib/sub/zlib.c'))
    Assert-True (-not (Test-Glob 'src/lib/zlib*.c' 'src/lib/zlib.cpp'))
    Assert-True (Test-Glob '*' 'a.c')
    Assert-True (-not (Test-Glob '*' 'a/b.c'))
    Assert-True (Test-Glob '*.c' 'a.c')
    Assert-True (-not (Test-Glob '*.c' 'd/a.c'))
    Assert-True (Test-Glob 'a?c' 'abc')
    Assert-True (-not (Test-Glob 'a?c' 'a/c'))
    Assert-True (-not (Test-Glob 'a.c' 'abc'))
    Assert-True (Test-Glob 'SRC/A.C' 'src/a.c')
    Assert-True (Test-Glob '/src/a.c' 'src/a.c')
    Assert-True (Test-Glob 'a/**/b.c' 'a/b.c')
    Assert-True (Test-Glob 'a/**/b.c' 'a/x/y/b.c')
    Assert-True (Test-Glob 'x**y' 'x/q/y')
    Assert-True (Test-Glob 'a+b(1).c' 'a+b(1).c')
}

Test-Case 'batch: exclude patterns in action (case-insensitive, first match reported)' {
    $d = New-BatchTree @{
        'third_party/a.c' = 'int a; // c'; 'x/Vendor/b.c' = 'int b; // c'; 'src/lib/zlib1.c' = 'int c; // c'
        'src/lib/sub/zlib2.c' = 'int d; // c'; 'top.c' = 'int e; // c'; 'sub/top.c' = 'int f; // c'
    }
    $r = Invoke-TestBatch $d ('{' + $script:OutDirJson + ',"exclude":["THIRD_PARTY/**","**/vendor/**","src/lib/zlib*.c","*.c","top.c"]}')
    $by = @{}
    foreach ($row in $r.Rows) { $by[$row.Path] = $row }
    Assert-Equal $by['third_party/a.c'].Message 'THIRD_PARTY/**'
    Assert-Equal $by['x/Vendor/b.c'].Message '**/vendor/**'
    Assert-Equal $by['src/lib/zlib1.c'].Message 'src/lib/zlib*.c'
    Assert-Equal $by['top.c'].Message '*.c'
    Assert-Equal $by['top.c'].Status 'EXCLUDED'
    Assert-Equal $by['src/lib/sub/zlib2.c'].Status 'OK'
    Assert-Equal $by['sub/top.c'].Status 'OK'
}

Test-Case 'batch: excludeFiles with comments and blank lines' {
    $d = New-BatchTree @{ 'oss/a.c' = 'int a; // c'; 'mine.c' = 'int m; // c'; 'lib.c' = 'int l; // c' }
    [IO.File]::WriteAllBytes((Join-Path $d 'list.txt'), (Get-TestUtf8 "# comment`n`noss/**`r`n   `n  lib.c  `n"))
    $r = Invoke-TestBatch $d ('{' + $script:OutDirJson + ',"excludeFiles":["list.txt"]}')
    Assert-Equal $r.Counts['EXCLUDED'] 2
    Assert-Equal $r.Counts['OK'] 1
    Assert-BytesEqual (Read-TestBytes (Join-Path $d 'out/mine.c')) (Get-TestUtf8 'int m;')
}

Test-Case 'batch: .git and .svn are skipped (not processed, not copied)' {
    $d = New-BatchTree @{ '.git/config' = "# c`n"; '.svn/x.c' = 'int a; // c'; 'sub/.git/y.c' = 'int y;'; 'a.c' = 'int a; // c' }
    $r = Invoke-TestBatch $d ('{' + $script:OutDirJson + '}')
    Assert-Equal @($r.Rows | ForEach-Object { $_.Path }) @('a.c')
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $d 'out/.git')))
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $d 'out/.svn')))
}

Test-Case 'batch: reparse-point directories are not entered' {
    if ($env:OS -ne 'Windows_NT' -and -not $IsLinux -and -not $IsMacOS) { return }
    $d = New-BatchTree @{ 'a.c' = 'int a; // c' }
    $other = New-TestDir
    [IO.File]::WriteAllBytes((Join-Path $other 'x.c'), (Get-TestUtf8 'int x; // c'))
    $link = Join-Path $d 'src/lnk'
    try { New-Item -ItemType SymbolicLink -Path $link -Target $other -ErrorAction Stop | Out-Null }
    catch { Write-Host '      (symlink not permitted; skipped)'; return }
    $r = Invoke-TestBatch $d ('{' + $script:OutDirJson + '}')
    Assert-Equal @($r.Rows | ForEach-Object { $_.Path }) @('a.c')
}

Test-Case 'batch: inPlace without backup' {
    $d = New-BatchTree @{ 'a.c' = "int a; // c`n"; 'sub/r.md' = "# x`n"; 'x/ex.c' = "int e; // c`n" }
    $r = Invoke-TestBatch $d '{"output":{"mode":"inPlace"},"batch":{"root":"src"},"exclude":["x/**"]}'
    Assert-Equal $r.ExitCode 0 ($r.ErrorLines -join '|')
    $s = Join-Path $d 'src'
    Assert-BytesEqual (Read-TestBytes (Join-Path $s 'a.c')) (Get-TestUtf8 "int a;`n")
    Assert-BytesEqual (Read-TestBytes (Join-Path $s 'x/ex.c')) (Get-TestUtf8 "int e; // c`n")
    Assert-True (-not (Test-Exists (Join-Path $s 'a.c.bak')))
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $d 'out')))
}

Test-Case 'batch: inPlace with backup' {
    $d = New-BatchTree @{ 'a.c' = "int a; // c`n"; 'plain.c' = "int p;`n" }
    $r = Invoke-TestBatch $d '{"output":{"mode":"inPlace","backup":true},"batch":{"root":"src"}}'
    Assert-Equal $r.ExitCode 0 ($r.ErrorLines -join '|')
    $s = Join-Path $d 'src'
    Assert-BytesEqual (Read-TestBytes (Join-Path $s 'a.c')) (Get-TestUtf8 "int a;`n")
    Assert-BytesEqual (Read-TestBytes (Join-Path $s 'a.c.bak')) (Get-TestUtf8 "int a; // c`n")
    Assert-True (-not (Test-Exists (Join-Path $s 'plain.c.bak'))) 'unchanged file gets no backup'
}

Test-Case 'batch: DryRun writes nothing except the CSV log' {
    $d = New-BatchTree @{ 'a.c' = "int a; // c`n"; 'r.md' = 'x'; 'v/e.c' = 'int e;' }
    $json = '{' + $script:OutDirJson + ',"exclude":["v/**"],"log":{"path":"logs/x/log.csv"}}'
    $r = Invoke-TestBatch $d $json -DryRun
    Assert-Equal $r.ExitCode 0 ($r.ErrorLines -join '|')
    Assert-Equal $r.Lines[0] "OK`ta.c`tremoved=1`tkept=0"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $d 'out'))) 'no outDir'
    Assert-True (Test-Exists (Join-Path $d 'logs/x/log.csv')) 'log written'
    Assert-BytesEqual (Read-TestBytes (Join-Path $d 'src/a.c')) (Get-TestUtf8 "int a; // c`n")
    # inPlace dry run: no change, no .bak
    $d2 = New-BatchTree @{ 'a.c' = "int a; // c`n" }
    $r2 = Invoke-TestBatch $d2 '{"output":{"mode":"inPlace","backup":true},"batch":{"root":"src"}}' -DryRun
    Assert-Equal $r2.Counts['OK'] 1
    Assert-BytesEqual (Read-TestBytes (Join-Path $d2 'src/a.c')) (Get-TestUtf8 "int a; // c`n")
    Assert-True (-not (Test-Exists (Join-Path $d2 'src/a.c.bak')))
}

Test-Case 'batch: CSV log exact content (BOM, CRLF, all quoted)' {
    $d = New-BatchTree @{ 'a.conf' = "# c`nk=1`n"; 'n.md' = 'x'; 'v/x.c' = 'int x;' }
    $r = Invoke-TestBatch $d ('{' + $script:OutDirJson + ',"exclude":["v/**"],"log":{"path":"out/log.csv"}}')
    Assert-Equal $r.ExitCode 0 ($r.ErrorLines -join '|')
    $expected = '"path","status","exitCode","removed","kept","message"' + "`r`n" +
        '"a.conf","OK","0","1","0",""' + "`r`n" +
        '"n.md","UNSUPPORTED","2","","",""' + "`r`n" +
        '"v/x.c","EXCLUDED","","","","v/**"' + "`r`n"
    $bom = [byte[]](0xEF, 0xBB, 0xBF)
    Assert-BytesEqual (Read-TestBytes (Join-Path $d 'out/log.csv')) (Join-TestBytes $bom (Get-TestUtf8 $expected))
}

Test-Case 'batch: CSV quoting doubles embedded quote characters' {
    Assert-Equal (ConvertTo-RcCsvLine @('a"b', 'c,d', '')) '"a""b","c,d",""'
    $p = Join-Path (New-TestDir) 'sub/l.csv'
    $row = [pscustomobject]@{ Path = 'x.c'; Status = 'ERROR'; ExitCode = 3; Removed = $null; Kept = $null; Message = 'x.c:1: say "hi"' }
    Write-RcCsvLog -Path $p -Rows @($row)
    $t = [Text.Encoding]::UTF8.GetString((Read-TestBytes $p)).TrimStart([char]0xFEFF)
    Assert-Equal $t ('"path","status","exitCode","removed","kept","message"' + "`r`n" + '"x.c","ERROR","3","","","x.c:1: say ""hi"""' + "`r`n")
}

Test-Case 'batch: ERROR file does not stop others; exit 1; no output for it' {
    $d = New-BatchTree @{ 'a.c' = "int a; // c`n"; 'bad.c' = "int b; /* open`n"; 'z.c' = "int z; // c`n" }
    $r = Invoke-TestBatch $d ('{' + $script:OutDirJson + '}')
    Assert-Equal $r.ExitCode 1
    Assert-Equal $r.Counts['ERROR'] 1
    Assert-Equal $r.Counts['OK'] 2
    Assert-Equal $r.Lines[1] "ERROR`tbad.c`tcode=3"
    Assert-Equal $r.Lines[3] 'OK=2 EXCLUDED=0 UNSUPPORTED=0 ERROR=1'
    Assert-Equal $r.ErrorLines.Count 1
    Assert-True ($r.ErrorLines[0] -like 'bad.c:1:*') $r.ErrorLines[0]
    Assert-True (-not (Test-Exists (Join-Path $d 'out/bad.c')))
    Assert-True (Test-Exists (Join-Path $d 'out/a.c'))
    Assert-True (Test-Exists (Join-Path $d 'out/z.c'))
    Assert-Equal $r.Rows[1].ExitCode 3
    Assert-True ($r.Rows[1].Message -like 'bad.c:1:*') 'message in row'
}

Test-Case 'batch: settings error -> exit 9, nothing processed' {
    $d = New-BatchTree @{ 'a.c' = "int a; // c`n" }
    $r = Invoke-TestBatch $d ('{' + $script:OutDirJson + ',"bogus":1}')
    Assert-Equal $r.ExitCode 9
    Assert-Equal $r.Rows.Count 0
    Assert-Equal $r.Lines.Count 0
    Assert-True ($r.ErrorLines[0] -like '*bogus*') $r.ErrorLines[0]
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $d 'out')))
}

Test-Case 'batch: outDir equal to or inside root -> exit 9' {
    $d = New-BatchTree @{ 'a.c' = "int a; // c`n" }
    $r1 = Invoke-TestBatch $d '{"output":{"mode":"outDir","outDir":"src/out"},"batch":{"root":"src"}}'
    Assert-Equal $r1.ExitCode 9
    $r2 = Invoke-TestBatch $d '{"output":{"mode":"outDir","outDir":"src"},"batch":{"root":"src"}}'
    Assert-Equal $r2.ExitCode 9
    $r3 = Invoke-TestBatch $d '{"output":{"mode":"outDir","outDir":"SRC/"},"batch":{"root":"src"}}'
    Assert-Equal $r3.ExitCode 9
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $d 'src/out')))
}

Test-Case 'batch: outDir sibling with common name prefix is allowed' {
    Assert-True (Test-RcPathInside -Out '/t/src/out' -Root '/t/src')
    Assert-True (Test-RcPathInside -Out '/t/src' -Root '/t/src/')
    Assert-True (Test-RcPathInside -Out '/t/SRC/x' -Root '/t/src')
    Assert-True (-not (Test-RcPathInside -Out '/t/src2' -Root '/t/src'))
    Assert-True (-not (Test-RcPathInside -Out '/t/sr' -Root '/t/src'))
    $d = New-BatchTree @{ 'a.c' = "int a; // c`n" }
    $r = Invoke-TestBatch $d '{"output":{"mode":"outDir","outDir":"src2"},"batch":{"root":"src"}}'
    Assert-Equal $r.ExitCode 0 ($r.ErrorLines -join '|')
    Assert-True (Test-Exists (Join-Path $d 'src2/a.c'))
}

Test-Case 'batch: missing output.mode -> exit 9' {
    $d = New-BatchTree @{ 'a.c' = "int a; // c`n" }
    $r = Invoke-TestBatch $d '{"batch":{"root":"src"}}'
    Assert-Equal $r.ExitCode 9
    Assert-True ($r.ErrorLines[0] -like '*output.mode*') $r.ErrorLines[0]
    $r2 = Invoke-TestBatch $d '{"output":{"mode":"outDir"},"batch":{"root":"src"}}'
    Assert-Equal $r2.ExitCode 9
}

Test-Case 'batch: missing root or nonexistent root -> exit 9' {
    $d = New-BatchTree @{ 'a.c' = 'int a;' }
    Assert-Equal (Invoke-TestBatch $d '{"output":{"mode":"inPlace"}}').ExitCode 9
    Assert-Equal (Invoke-TestBatch $d '{"output":{"mode":"inPlace"},"batch":{"root":"nope"}}').ExitCode 9
}

Test-Case 'batch: -Root overrides batch.root; relative batch.root resolves against config dir' {
    $d = New-BatchTree @{ 'a.c' = "int a; // c`n" }
    $other = Join-Path $d 'other'
    [void][IO.Directory]::CreateDirectory($other)
    [IO.File]::WriteAllBytes((Join-Path $other 'o.c'), (Get-TestUtf8 "int o; // c`n"))
    $json = '{' + $script:OutDirJson + '}'
    $r = Invoke-TestBatch $d $json
    Assert-Equal @($r.Rows | ForEach-Object { $_.Path }) @('a.c') 'relative to config dir'
    $saved = Get-Location
    try {
        Set-Location -LiteralPath ([IO.Path]::GetTempPath())
        $r1 = Invoke-TestBatch $d $json
        Assert-Equal @($r1.Rows | ForEach-Object { $_.Path }) @('a.c') 'cwd does not matter'
    }
    finally { Set-Location -LiteralPath $saved }
    $r2 = Invoke-TestBatch $d '{"output":{"mode":"outDir","outDir":"out2"},"batch":{"root":"src"}}' -Root $other
    Assert-Equal @($r2.Rows | ForEach-Object { $_.Path }) @('o.c') '-Root wins'
    Assert-True (Test-Exists (Join-Path $d 'out2/o.c'))
}

Test-Case 'batch: out-of-process run, exit code and summary line' {
    $d = New-BatchTree @{ 'a.c' = "int a; // c`n"; 'r.md' = 'x'; 'v/x.c' = 'int x;' }
    $cfg = New-TestConfig -Dir $d -Json ('{' + $script:OutDirJson + ',"exclude":["v/**"]}')
    $script = Join-Path $global:RcTestState.Root 'src/Invoke-RemoveComments.ps1'
    $r = Invoke-TestCli -Script $script -Arguments @('-Config', $cfg) -WorkDir $d
    Assert-Equal $r.ExitCode 0 $r.Err
    $lines = @($r.Out -split "\r?\n" | Where-Object { $_ -ne '' })
    Assert-Equal $lines[$lines.Count - 1] 'OK=1 EXCLUDED=1 UNSUPPORTED=1 ERROR=0'
    Assert-Equal $lines[0] "OK`ta.c`tremoved=1`tkept=0"
    Assert-BytesEqual (Read-TestBytes (Join-Path $d 'out/a.c')) (Get-TestUtf8 "int a;`n")
    # failing file -> exit 1; bad config -> exit 9
    [IO.File]::WriteAllBytes((Join-Path $d 'src/bad.c'), (Get-TestUtf8 "/* open`n"))
    $r1 = Invoke-TestCli -Script $script -Arguments @('-Config', $cfg, '-DryRun') -WorkDir $d
    Assert-Equal $r1.ExitCode 1
    Assert-True ($r1.Err -like '*bad.c:1:*') $r1.Err
    $bad = New-TestConfig -Dir $d -Json '{"nope":1}' -Name 'bad.json'
    $r2 = Invoke-TestCli -Script $script -Arguments @('-Config', $bad) -WorkDir $d
    Assert-Equal $r2.ExitCode 9
    Assert-Equal $r2.Out ''
}

Test-Case 'batch: CSV leaves exitCode/removed/kept empty when Remove-Comments did not run' {
    $d = New-BatchTree @{ 'bad.c' = "/* open`n"; 'v/x.c' = 'int x;' }
    $r = Invoke-TestBatch $d ('{' + $script:OutDirJson + ',"exclude":["v/**"],"log":{"path":"out/log.csv"}}')
    $t = [Text.Encoding]::UTF8.GetString((Read-TestBytes (Join-Path $d 'out/log.csv'))).TrimStart([char]0xFEFF)
    $l = $t -split "`r`n"
    Assert-True ($l[1] -like '"bad.c","ERROR","3","","","bad.c:1:*') $l[1]
    Assert-Equal $l[2] '"v/x.c","EXCLUDED","","","","v/**"'
}

Test-Case 'batch: OnLine callback streams lines; no callback prints nothing' {
    $d = New-BatchTree @{ 'a.conf' = "# c`n"; 'bad.c' = "/* open`n" }
    $script:got = New-Object 'System.Collections.Generic.List[string]'
    $cfg = New-TestConfig -Dir $d -Json ('{' + $script:OutDirJson + '}')
    $r = Invoke-RcBatch -Config $cfg -ScriptDir (New-TestDir) -OnLine { param($k, $t) $script:got.Add("${k}:$t") }
    Assert-Equal $script:got.Count ($r.Lines.Count + $r.ErrorLines.Count)
    Assert-Equal $script:got[0] ('out:' + $r.Lines[0])
    Assert-True ($script:got[1] -like 'out:ERROR*') $script:got[1]
    Assert-True ($script:got[2] -like 'err:bad.c:1:*') $script:got[2]
}

Test-Case 'batch: file and directory names containing [ ]' {
    $d = New-BatchTree @{ 'a[1].conf' = "# c`nk=1`n"; 'x[y]/b[2].c' = "int a; // c`n"; 'x[y]/r[3].md' = 'm' }
    $r = Invoke-TestBatch $d ('{' + $script:OutDirJson + '}')
    Assert-Equal $r.ExitCode 0 ($r.ErrorLines -join '|')
    Assert-Equal $r.Counts['OK'] 2
    Assert-Equal $r.Counts['UNSUPPORTED'] 1
    Assert-BytesEqual (Read-TestBytes (Join-Path $d 'out/a[1].conf')) (Get-TestUtf8 "k=1`n")
    Assert-BytesEqual (Read-TestBytes (Join-Path $d 'out/x[y]/b[2].c')) (Get-TestUtf8 "int a;`n")
    Assert-BytesEqual (Read-TestBytes (Join-Path $d 'out/x[y]/r[3].md')) (Get-TestUtf8 'm')
}
