param([string]$Filter = '')

# Usage: pwsh -NoProfile -File tests/Run-Tests.ps1 [-Filter <text>]
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$rtTests = $PSScriptRoot
$rtRoot = Split-Path -Parent $rtTests
. (Join-Path $rtTests 'TestLib.ps1')
$global:RcTestState.Filter = $Filter
$global:RcTestState.Root = $rtRoot
$global:RcTestState.Fixtures = Join-Path $rtTests 'fixtures'
$global:RcTestState.SrcScript = Join-Path $rtRoot 'src/Remove-Comments.ps1'
. $global:RcTestState.SrcScript

$rtWatch = [Diagnostics.Stopwatch]::StartNew()
foreach ($rtFile in (Get-ChildItem -Path $rtTests -Filter '*.Tests.ps1' | Sort-Object Name)) {
    Write-Host "== $($rtFile.Name)"
    . $rtFile.FullName
}

foreach ($rtDir in $global:RcTestState.Dirs) {
    try { Remove-Item -LiteralPath $rtDir -Recurse -Force -ErrorAction Stop } catch { }
}
$rtWatch.Stop()
$rtSt = $global:RcTestState
$rtTotal = $rtSt.Pass + $rtSt.Fail
Write-Host ("Total: {0}  Passed: {1}  Failed: {2}  ({3:N1}s)" -f $rtTotal, $rtSt.Pass, $rtSt.Fail, $rtWatch.Elapsed.TotalSeconds)
if ($rtSt.Fail -gt 0) { exit 1 }
exit 0
