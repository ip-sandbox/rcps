# Golden-file tests: tests/fixtures/<lang>/<case>.in.<ext> etc. (design 8.2)

$ftRoot = $global:RcTestState.Fixtures
$ftDefaultConfig = Join-Path $ftRoot '_default.config.json'

foreach ($ftDir in (Get-ChildItem -Path $ftRoot -Directory | Sort-Object Name)) {
    foreach ($ftIn in (Get-ChildItem -Path $ftDir.FullName -File | Where-Object { $_.Name -match '\.in\.' } | Sort-Object Name)) {
        if ($ftIn.Name -notmatch '^(?<case>.+?)\.in\.(?<ext>.+)$') { continue }
        $ftCase = $Matches['case']
        $ftExt = $Matches['ext']
        $ftBase = Join-Path $ftDir.FullName $ftCase
        $ftCfg = "$ftBase.config.json"
        if (-not (Test-Path -LiteralPath $ftCfg)) { $ftCfg = $ftDefaultConfig }
        $ftExit = "$ftBase.exit"
        $ftExpected = "$ftBase.expected.$ftExt"
        $ftInPath = $ftIn.FullName

        Test-Case "fixture $($ftDir.Name)/$ftCase" {
            $work = New-TestDir
            $settings = Read-RcSettings -ConfigPath $ftCfg -ScriptDir $work
            $out = Join-Path $work "out/result.$ftExt"
            $r = Invoke-RcFile -Settings $settings -Path $ftInPath -OutPath $out -DisplayPath 'x'
            if (Test-Path -LiteralPath $ftExit) {
                $want = [int]((Get-Content -LiteralPath $ftExit -Raw).Trim())
                Assert-Equal $r.ExitCode $want "exit code ($($r.Message))"
                Assert-True (-not (Test-Path -LiteralPath $out)) 'output must not be written on error'
            }
            else {
                Assert-Equal $r.ExitCode 0 "exit code ($($r.Message))"
                Assert-BytesEqual ([IO.File]::ReadAllBytes($out)) ([IO.File]::ReadAllBytes($ftExpected)) 'output bytes'
            }
        }
    }
}
