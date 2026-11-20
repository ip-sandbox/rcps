# Out-of-process tests: exit codes, stdout result line, stderr

function New-CliCase {
    param([string]$ConfigJson = '{}', [string]$Name = 'a.conf', [string]$Content = "# c`nk=1`n")
    $d = New-TestDir
    $cfg = New-TestConfig -Dir $d -Json $ConfigJson
    $in = Join-Path $d $Name
    [IO.File]::WriteAllBytes($in, (Get-TestUtf8 $Content))
    return @{ Dir = $d; Cfg = $cfg; In = $in }
}

Test-Case 'cli: OK line, exit 0, output written' {
    $c = New-CliCase
    $out = Join-Path $c.Dir 'o/out.conf'
    $r = Invoke-TestCli @('-Path', $c.In, '-Config', $c.Cfg, '-OutPath', $out) $c.Dir
    Assert-Equal $r.ExitCode 0 $r.Err
    Assert-Equal $r.Out.TrimEnd("`r", "`n") "OK`t$($c.In)`tremoved=1`tkept=0"
    Assert-Equal $r.Err ''
    Assert-BytesEqual ([IO.File]::ReadAllBytes($out)) (Get-TestUtf8 "k=1`n")
}
Test-Case 'cli: -DryRun needs no -OutPath and writes nothing' {
    $c = New-CliCase
    $r = Invoke-TestCli @('-Path', $c.In, '-Config', $c.Cfg, '-DryRun') $c.Dir
    Assert-Equal $r.ExitCode 0 $r.Err
    Assert-Equal $r.Out.TrimEnd("`r", "`n") "OK`t$($c.In)`tremoved=1`tkept=0"
    Assert-BytesEqual ([IO.File]::ReadAllBytes($c.In)) (Get-TestUtf8 "# c`nk=1`n")
}
Test-Case 'cli: UNSUPPORTED -> exit 2' {
    $c = New-CliCase -Name 'README.md'
    $r = Invoke-TestCli @('-Path', $c.In, '-Config', $c.Cfg, '-OutPath', (Join-Path $c.Dir 'o.md')) $c.Dir
    Assert-Equal $r.ExitCode 2
    Assert-Equal $r.Out.TrimEnd("`r", "`n") "UNSUPPORTED`t$($c.In)"
}
Test-Case 'cli: missing -Path -> ERROR code=9, message on stderr' {
    $c = New-CliCase
    $r = Invoke-TestCli @('-Config', $c.Cfg) $c.Dir
    Assert-Equal $r.ExitCode 9
    Assert-True ($r.Out -match "^ERROR`t`tcode=9") "stdout: $($r.Out)"
    Assert-True ($r.Err.Length -gt 0) 'stderr has message'
}
Test-Case 'cli: bad config -> exit 9' {
    $c = New-CliCase -ConfigJson '{"bogus":1}'
    $r = Invoke-TestCli @('-Path', $c.In, '-Config', $c.Cfg, '-DryRun') $c.Dir
    Assert-Equal $r.ExitCode 9
    Assert-Equal $r.Out.TrimEnd("`r", "`n") "ERROR`t$($c.In)`tcode=9"
    Assert-True ($r.Err -like '*bogus*') "stderr: $($r.Err)"
}
Test-Case 'cli: no -OutPath without inPlace -> exit 9, nothing written' {
    $c = New-CliCase
    $r = Invoke-TestCli @('-Path', $c.In, '-Config', $c.Cfg) $c.Dir
    Assert-Equal $r.ExitCode 9
    Assert-BytesEqual ([IO.File]::ReadAllBytes($c.In)) (Get-TestUtf8 "# c`nk=1`n")
}
Test-Case 'cli: region error -> exit 4, nothing written, message names file and line' {
    $c = New-CliCase -Content "k=1`n# % DEL START`n"
    $out = Join-Path $c.Dir 'o.conf'
    $r = Invoke-TestCli @('-Path', $c.In, '-Config', $c.Cfg, '-OutPath', $out) $c.Dir
    Assert-Equal $r.ExitCode 4
    Assert-Equal $r.Out.TrimEnd("`r", "`n") "ERROR`t$($c.In)`tcode=4"
    Assert-True ($r.Err -like "*$($c.In):2:*") "stderr: $($r.Err)"
    Assert-True (-not (Test-Path -LiteralPath $out)) 'no output'
}
Test-Case 'cli: inPlace with backup' {
    $c = New-CliCase -ConfigJson '{"output":{"mode":"inPlace","backup":true}}'
    $r = Invoke-TestCli @('-Path', $c.In, '-Config', $c.Cfg) $c.Dir
    Assert-Equal $r.ExitCode 0 $r.Err
    Assert-BytesEqual ([IO.File]::ReadAllBytes($c.In)) (Get-TestUtf8 "k=1`n")
    Assert-BytesEqual ([IO.File]::ReadAllBytes("$($c.In).bak")) (Get-TestUtf8 "# c`nk=1`n")
}
Test-Case 'cli: relative -Path/-OutPath resolve against the working directory' {
    $c = New-CliCase
    $r = Invoke-TestCli @('-Path', 'a.conf', '-Config', 'cfg.json', '-OutPath', 'sub/o.conf') $c.Dir
    Assert-Equal $r.ExitCode 0 $r.Err
    Assert-Equal $r.Out.TrimEnd("`r", "`n") "OK`ta.conf`tremoved=1`tkept=0"
    Assert-BytesEqual ([IO.File]::ReadAllBytes((Join-Path $c.Dir 'sub/o.conf'))) (Get-TestUtf8 "k=1`n")
}
