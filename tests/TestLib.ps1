# Minimal test helpers (no Pester). Dot-sourced by Run-Tests.ps1.

if (-not (Test-Path variable:global:RcTestState)) {
    $global:RcTestState = @{
        Pass = 0; Fail = 0; Filter = ''
        Dirs = (New-Object 'System.Collections.Generic.List[string]')
        Root = ''; SrcScript = ''; Fixtures = ''
    }
}

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    $st = $global:RcTestState
    if ($st.Filter -and $Name.IndexOf($st.Filter, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return }
    try {
        & $Body | Out-Null
        $st.Pass++
        Write-Host "PASS  $Name"
    }
    catch {
        $st.Fail++
        Write-Host "FAIL  $Name" -ForegroundColor Red
        Write-Host "      $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Format-TestValue {
    param($Value)
    if ($null -eq $Value) { return '<null>' }
    if ($Value -is [string]) {
        return '"' + $Value.Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t') + '"'
    }
    if ($Value -is [Array]) {
        return '[' + (($Value | ForEach-Object { Format-TestValue $_ }) -join ', ') + ']'
    }
    return [string]$Value
}

function Test-ValueEqual {
    param($A, $B)
    if ($null -eq $A -or $null -eq $B) { return ($null -eq $A -and $null -eq $B) }
    if ($A -is [string] -and $B -is [string]) { return [string]::Equals($A, $B, [StringComparison]::Ordinal) }
    if ($A -is [Array] -and $B -is [Array]) {
        if ($A.Length -ne $B.Length) { return $false }
        for ($i = 0; $i -lt $A.Length; $i++) {
            if (-not (Test-ValueEqual $A[$i] $B[$i])) { return $false }
        }
        return $true
    }
    return ($A -eq $B)
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message = '')
    if (-not (Test-ValueEqual $Actual $Expected)) {
        throw ("assert equal failed. $Message`n      expected: $(Format-TestValue $Expected)`n      actual:   $(Format-TestValue $Actual)")
    }
}

function Assert-True {
    param($Condition, [string]$Message = '')
    if (-not $Condition) { throw "assert true failed. $Message" }
}

function Assert-BytesEqual {
    param([byte[]]$Actual, [byte[]]$Expected, [string]$Message = '')
    if ($null -eq $Actual) { $Actual = New-Object byte[] 0 }
    if ($null -eq $Expected) { $Expected = New-Object byte[] 0 }
    $n = [Math]::Min($Actual.Length, $Expected.Length)
    for ($i = 0; $i -lt $n; $i++) {
        if ($Actual[$i] -ne $Expected[$i]) {
            throw ("bytes differ at offset $i (expected 0x{0:X2}, actual 0x{1:X2}). $Message" -f $Expected[$i], $Actual[$i])
        }
    }
    if ($Actual.Length -ne $Expected.Length) {
        throw "byte length differs (expected $($Expected.Length), actual $($Actual.Length)); first $n bytes equal. $Message"
    }
}

# runs Block and checks that it throws an RcError with the given exit code
function Assert-RcErrorCode {
    param([int]$Code, [scriptblock]$Block, [string]$Message = '')
    $err = $null
    try { & $Block | Out-Null } catch { $err = Convert-RcException -ErrorRecord $_ }
    if ($null -eq $err) { throw "expected error code $Code but nothing was thrown. $Message" }
    if ($err.Code -ne $Code) { throw "expected error code $Code but got $($err.Code): $($err.Message). $Message" }
}

function New-TestDir {
    $d = Join-Path ([IO.Path]::GetTempPath()) ('rctest-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($d)
    $global:RcTestState.Dirs.Add($d)
    return $d
}

function Get-TestUtf8 {
    param([string]$Text)
    return , (New-Object System.Text.UTF8Encoding -ArgumentList $false).GetBytes($Text)
}

function Join-TestBytes {
    param([byte[]]$A, [byte[]]$B)
    $r = New-Object byte[] ($A.Length + $B.Length)
    [Array]::Copy($A, 0, $r, 0, $A.Length)
    [Array]::Copy($B, 0, $r, $A.Length, $B.Length)
    return , $r
}

# writes a JSON config into $Dir and returns its path
function New-TestConfig {
    param([string]$Dir, [string]$Json, [string]$Name = 'cfg.json')
    $p = Join-Path $Dir $Name
    [IO.File]::WriteAllBytes($p, (Get-TestUtf8 $Json))
    return $p
}

function New-TestSettings {
    param([string]$Json = '{}')
    $d = New-TestDir
    $p = New-TestConfig -Dir $d -Json $Json
    return (Read-RcSettings -ConfigPath $p -ScriptDir $d)
}

# makes a token covering the first occurrence of $Needle (after $From)
function New-TestToken {
    param([string]$Text, [string]$Needle, [string]$Kind = 'line', [int]$From = 0)
    $i = $Text.IndexOf($Needle, $From, [StringComparison]::Ordinal)
    if ($i -lt 0) { throw "needle not found: $Needle" }
    return New-RcToken -Start $i -End ($i + $Needle.Length) -Kind $Kind
}

# runs the script out of process; returns @{ ExitCode; Out; Err }
function Invoke-TestCli {
    param([string[]]$Arguments, [string]$WorkDir)
    $exe = (Get-Process -Id $PID).Path
    $all = New-Object 'System.Collections.Generic.List[string]'
    $all.Add('-NoProfile')
    if ($env:OS -eq 'Windows_NT') { $all.Add('-ExecutionPolicy'); $all.Add('Bypass') }
    $all.Add('-File'); $all.Add($global:RcTestState.SrcScript)
    foreach ($a in $Arguments) { $all.Add($a) }
    $quoted = $all | ForEach-Object { '"' + $_ + '"' }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = ($quoted -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if ($WorkDir) { $psi.WorkingDirectory = $WorkDir }
    $p = [System.Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    return @{ ExitCode = $p.ExitCode; Out = $out; Err = $errTask.Result }
}
