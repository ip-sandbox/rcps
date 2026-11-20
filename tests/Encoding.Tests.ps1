# Encodings, BOM, newlines, NUL, atomic write, backup

function New-EncSettings {
    param([string]$Json = '{}')
    return (New-TestSettings $Json)
}

# runs a .conf through Invoke-RcFile; returns @{ R; Out (bytes or $null); Dir }
function Invoke-EncCase {
    param([byte[]]$Bytes, [string]$Json = '{}')
    $d = New-TestDir
    $s = New-EncSettings $Json
    $in = Join-Path $d 'in.conf'
    $out = Join-Path $d 'sub/out.conf'
    [IO.File]::WriteAllBytes($in, $Bytes)
    $r = Invoke-RcFile -Settings $s -Path $in -OutPath $out -DisplayPath 'in.conf'
    $ob = $null
    if (Test-Path -LiteralPath $out) { $ob = [IO.File]::ReadAllBytes($out) }
    return @{ R = $r; Out = $ob; Dir = $d; In = $in }
}

$jp = -join ([char[]](0x65E5, 0x672C, 0x8A9E))      # Japanese word "nihongo"
$src = "# $jp`nname = $jp`n# end`n"
$exp = "name = $jp`n"

Test-Case 'encoding: UTF-8 without BOM' {
    $e = New-Object System.Text.UTF8Encoding -ArgumentList $false
    $c = Invoke-EncCase $e.GetBytes($src)
    Assert-Equal $c.R.ExitCode 0 $c.R.Message
    Assert-Equal $c.R.Removed 2
    Assert-BytesEqual $c.Out $e.GetBytes($exp)
}
Test-Case 'encoding: UTF-8 with BOM keeps the BOM' {
    $e = New-Object System.Text.UTF8Encoding -ArgumentList $false
    $bom = [byte[]](0xEF, 0xBB, 0xBF)
    $c = Invoke-EncCase (Join-TestBytes $bom $e.GetBytes($src))
    Assert-Equal $c.R.ExitCode 0 $c.R.Message
    Assert-BytesEqual $c.Out (Join-TestBytes $bom $e.GetBytes($exp))
}
Test-Case 'encoding: UTF-16LE with BOM' {
    $e = New-Object System.Text.UnicodeEncoding -ArgumentList $false, $false
    $bom = [byte[]](0xFF, 0xFE)
    $c = Invoke-EncCase (Join-TestBytes $bom $e.GetBytes($src.Replace("`n", "`r`n")))
    Assert-Equal $c.R.ExitCode 0 $c.R.Message
    Assert-BytesEqual $c.Out (Join-TestBytes $bom $e.GetBytes($exp.Replace("`n", "`r`n")))
}
Test-Case 'encoding: UTF-16BE with BOM' {
    $e = New-Object System.Text.UnicodeEncoding -ArgumentList $true, $false
    $bom = [byte[]](0xFE, 0xFF)
    $c = Invoke-EncCase (Join-TestBytes $bom $e.GetBytes($src))
    Assert-Equal $c.R.ExitCode 0 $c.R.Message
    Assert-BytesEqual $c.Out (Join-TestBytes $bom $e.GetBytes($exp))
}
Test-Case 'encoding: CP932 detected automatically (raw bytes)' {
    # "# <nihongo>\nname = <nihongo>\n"  nihongo = 93 FA 96 7B 8C EA
    $word = [byte[]](0x93, 0xFA, 0x96, 0x7B, 0x8C, 0xEA)
    $a = Get-TestUtf8 '# '; $nl = Get-TestUtf8 "`n"; $nm = Get-TestUtf8 'name = '
    $in = Join-TestBytes (Join-TestBytes (Join-TestBytes $a $word) $nl) (Join-TestBytes (Join-TestBytes $nm $word) $nl)
    $c = Invoke-EncCase $in
    Assert-Equal $c.R.ExitCode 0 $c.R.Message
    Assert-BytesEqual $c.Out (Join-TestBytes (Join-TestBytes $nm $word) $nl)
}
Test-Case 'encoding: CP932 with encoding=sjis forced' {
    $e = Get-RcCp932
    $c = Invoke-EncCase $e.GetBytes($src) '{"encoding":"sjis"}'
    Assert-Equal $c.R.ExitCode 0 $c.R.Message
    Assert-BytesEqual $c.Out $e.GetBytes($exp)
}
Test-Case 'encoding: forced utf8 on CP932 bytes -> 5, no output' {
    $e = Get-RcCp932
    $c = Invoke-EncCase $e.GetBytes($src) '{"encoding":"utf8"}'
    Assert-Equal $c.R.ExitCode 5
    Assert-Equal $c.Out $null
}
Test-Case 'encoding: bytes valid in neither UTF-8 nor CP932 -> 5' {
    $c = Invoke-EncCase ([byte[]](0x23, 0x20, 0x81, 0x20, 0x0A, 0x61, 0x0A))
    Assert-Equal $c.R.ExitCode 5
    Assert-Equal $c.Out $null
}
Test-Case 'encoding: NUL in file -> 5' {
    $c = Invoke-EncCase ([byte[]](0x61, 0x0A, 0x00, 0x23, 0x0A))
    Assert-Equal $c.R.ExitCode 5
    Assert-Equal $c.Out $null
}
Test-Case 'encoding: NUL in UTF-16 text -> 5' {
    $e = New-Object System.Text.UnicodeEncoding -ArgumentList $false, $false
    $c = Invoke-EncCase (Join-TestBytes ([byte[]](0xFF, 0xFE)) $e.GetBytes("a$([char]0)b`n# c`n"))
    Assert-Equal $c.R.ExitCode 5
}
Test-Case 'encoding: odd-length UTF-16 -> 5' {
    $c = Invoke-EncCase ([byte[]](0xFF, 0xFE, 0x61, 0x00, 0x62))
    Assert-Equal $c.R.ExitCode 5
}
Test-Case 'encoding: forced utf8 still honours a UTF-8 BOM; forced utf8 rejects UTF-16 BOM' {
    $e = New-Object System.Text.UTF8Encoding -ArgumentList $false
    $bom = [byte[]](0xEF, 0xBB, 0xBF)
    $c = Invoke-EncCase (Join-TestBytes $bom $e.GetBytes("# a`nb`n")) '{"encoding":"utf8"}'
    Assert-BytesEqual $c.Out (Join-TestBytes $bom $e.GetBytes("b`n"))
    $u = New-Object System.Text.UnicodeEncoding -ArgumentList $false, $false
    $c2 = Invoke-EncCase (Join-TestBytes ([byte[]](0xFF, 0xFE)) $u.GetBytes("# a`nb`n")) '{"encoding":"utf8"}'
    Assert-Equal $c2.R.ExitCode 5
}
Test-Case 'encoding: Read-RcTextFile result shape' {
    $d = New-TestDir
    $p = Join-Path $d 'f.txt'
    [IO.File]::WriteAllBytes($p, (Join-TestBytes ([byte[]](0xEF, 0xBB, 0xBF)) (Get-TestUtf8 'abc')))
    $f = Read-RcTextFile -Path $p -EncodingMode 'auto'
    Assert-Equal $f.Text 'abc' 'BOM stripped from text'
    Assert-BytesEqual $f.Bom ([byte[]](0xEF, 0xBB, 0xBF))
    [IO.File]::WriteAllBytes($p, (Get-TestUtf8 'abc'))
    $f2 = Read-RcTextFile -Path $p -EncodingMode 'auto'
    Assert-Equal $f2.Bom.Length 0
}
Test-Case 'write: replaces existing file, leaves no temp files, creates parents' {
    $d = New-TestDir
    $p = Join-Path $d 'a/b/c.txt'
    $enc = New-Object System.Text.UTF8Encoding -ArgumentList $false
    Write-RcTextFile -Path $p -Text 'one' -Encoding $enc -Bom (New-Object byte[] 0)
    Write-RcTextFile -Path $p -Text 'two' -Encoding $enc -Bom ([byte[]](0xEF, 0xBB, 0xBF))
    Assert-BytesEqual ([IO.File]::ReadAllBytes($p)) (Join-TestBytes ([byte[]](0xEF, 0xBB, 0xBF)) (Get-TestUtf8 'two'))
    Assert-Equal @(Get-ChildItem -LiteralPath (Split-Path $p -Parent)).Count 1
}
Test-Case 'write: failure -> 5 and temp file removed' {
    $d = New-TestDir
    $blocker = Join-Path $d 'dest'
    [void][IO.Directory]::CreateDirectory($blocker)           # destination is a directory
    [IO.File]::WriteAllBytes((Join-Path $blocker 'x'), (New-Object byte[] 1))
    $enc = New-Object System.Text.UTF8Encoding -ArgumentList $false
    Assert-RcErrorCode 5 { Write-RcTextFile -Path $blocker -Text 'x' -Encoding $enc -Bom (New-Object byte[] 0) }
    Assert-Equal @(Get-ChildItem -LiteralPath $d -Force | Where-Object { $_.Name -like '*rctmp*' }).Count 0
}
Test-Case 'file: missing input -> 5' {
    $d = New-TestDir
    $s = New-EncSettings
    $r = Invoke-RcFile -Settings $s -Path (Join-Path $d 'nope.conf') -OutPath (Join-Path $d 'o.conf')
    Assert-Equal $r.ExitCode 5
}
Test-Case 'file: unsupported type -> 2 (even if the file does not exist)' {
    $d = New-TestDir
    $r = Invoke-RcFile -Settings (New-EncSettings) -Path (Join-Path $d 'README.md') -OutPath (Join-Path $d 'o.md') -DisplayPath 'README.md'
    Assert-Equal $r.ExitCode 2
    Assert-Equal $r.Status 'UNSUPPORTED'
    Assert-Equal $r.Line "UNSUPPORTED`tREADME.md"
}
Test-Case 'file: internal error (unknown language key) -> 1' {
    $d = New-TestDir
    $in = Join-Path $d 'a.zzz'
    [IO.File]::WriteAllBytes($in, (Get-TestUtf8 "// x`n"))
    $s = New-EncSettings
    $s.ExtMap['.zzz'] = 'bogus'
    $r = Invoke-RcFile -Settings $s -Path $in -OutPath (Join-Path $d 'o.zzz')
    Assert-Equal $r.ExitCode 1
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $d 'o.zzz')))
}
Test-Case 'file: no destination and no inPlace -> 9; DryRun needs none' {
    $d = New-TestDir
    $in = Join-Path $d 'a.conf'
    [IO.File]::WriteAllBytes($in, (Get-TestUtf8 "# x`ny=1`n"))
    $s = New-EncSettings
    $r = Invoke-RcFile -Settings $s -Path $in
    Assert-Equal $r.ExitCode 9
    $r2 = Invoke-RcFile -Settings $s -Path $in -DryRun -DisplayPath 'a.conf'
    Assert-Equal $r2.ExitCode 0
    Assert-Equal $r2.Line "OK`ta.conf`tremoved=1`tkept=0"
    Assert-BytesEqual ([IO.File]::ReadAllBytes($in)) (Get-TestUtf8 "# x`ny=1`n")
    Assert-Equal @(Get-ChildItem -LiteralPath $d).Count 1 'DryRun writes nothing'
}
Test-Case 'file: DryRun counts kept comments' {
    $d = New-TestDir
    $in = Join-Path $d 'a.conf'
    [IO.File]::WriteAllBytes($in, (Get-TestUtf8 "# Copyright`n# x`n"))
    $s = New-EncSettings '{"keep":{"patterns":["Copyright"]}}'
    $r = Invoke-RcFile -Settings $s -Path $in -DryRun
    Assert-Equal $r.Removed 1
    Assert-Equal $r.Kept 1
}
Test-Case 'file: inPlace writes the file; backup=false makes no .bak' {
    $d = New-TestDir
    $in = Join-Path $d 'a.conf'
    [IO.File]::WriteAllBytes($in, (Get-TestUtf8 "# x`ny=1`n"))
    $r = Invoke-RcFile -Settings (New-EncSettings '{"output":{"mode":"inPlace"}}') -Path $in
    Assert-Equal $r.ExitCode 0
    Assert-BytesEqual ([IO.File]::ReadAllBytes($in)) (Get-TestUtf8 "y=1`n")
    Assert-True (-not (Test-Path -LiteralPath "$in.bak")) 'no .bak'
}
Test-Case 'file: inPlace with backup=true creates .bak (overwriting an old one)' {
    $d = New-TestDir
    $in = Join-Path $d 'a.conf'
    [IO.File]::WriteAllBytes($in, (Get-TestUtf8 "# x`ny=1`n"))
    [IO.File]::WriteAllBytes("$in.bak", (Get-TestUtf8 'old'))
    $r = Invoke-RcFile -Settings (New-EncSettings '{"output":{"mode":"inPlace","backup":true}}') -Path $in
    Assert-Equal $r.ExitCode 0
    Assert-BytesEqual ([IO.File]::ReadAllBytes($in)) (Get-TestUtf8 "y=1`n")
    Assert-BytesEqual ([IO.File]::ReadAllBytes("$in.bak")) (Get-TestUtf8 "# x`ny=1`n")
}
Test-Case 'file: inPlace with nothing to change does not touch the file' {
    $d = New-TestDir
    $in = Join-Path $d 'a.conf'
    [IO.File]::WriteAllBytes($in, (Get-TestUtf8 "y=1`n"))
    $old = [DateTime]::new(2001, 2, 3, 4, 5, 6, [DateTimeKind]::Utc)
    [IO.File]::SetLastWriteTimeUtc($in, $old)
    $r = Invoke-RcFile -Settings (New-EncSettings '{"output":{"mode":"inPlace","backup":true}}') -Path $in
    Assert-Equal $r.ExitCode 0
    Assert-Equal ([IO.File]::GetLastWriteTimeUtc($in)) $old
    Assert-True (-not (Test-Path -LiteralPath "$in.bak")) 'no .bak when nothing changes'
}
Test-Case 'file: -OutPath always writes, even when unchanged; source untouched' {
    $d = New-TestDir
    $in = Join-Path $d 'a.conf'
    [IO.File]::WriteAllBytes($in, (Get-TestUtf8 "y=1`n"))
    $out = Join-Path $d 'x/y/o.conf'
    $r = Invoke-RcFile -Settings (New-EncSettings '{"output":{"mode":"inPlace","backup":true}}') -Path $in -OutPath $out
    Assert-Equal $r.ExitCode 0
    Assert-BytesEqual ([IO.File]::ReadAllBytes($out)) (Get-TestUtf8 "y=1`n")
    Assert-True (-not (Test-Path -LiteralPath "$in.bak")) 'no .bak with -OutPath'
}
Test-Case 'file: error leaves inPlace source untouched' {
    $d = New-TestDir
    $in = Join-Path $d 'a.conf'
    $orig = Get-TestUtf8 "# % DEL START`ny=1`n"
    [IO.File]::WriteAllBytes($in, $orig)
    $r = Invoke-RcFile -Settings (New-EncSettings '{"output":{"mode":"inPlace","backup":true}}') -Path $in -DisplayPath 'a.conf'
    Assert-Equal $r.ExitCode 4
    Assert-True ($r.Message -like 'a.conf:1: *') "message has path and line: $($r.Message)"
    Assert-BytesEqual ([IO.File]::ReadAllBytes($in)) $orig
    Assert-True (-not (Test-Path -LiteralPath "$in.bak")) 'no .bak on error'
}
