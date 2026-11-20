param([string]$Config, [string]$Root, [switch]$DryRun)
$batch = @{ Config = $Config; Root = $Root; DryRun = [bool]$DryRun }   # save before dot-sourcing (it overwrites $Config etc.)
. (Join-Path $PSScriptRoot 'Remove-Comments.ps1')

# Invoke-RemoveComments.ps1 : batch driver (see docs/spec.md ch.8, docs/design.md 6)
# No deletion logic here; every file goes through Invoke-RcFile.

# glob (relative path, '/' separated) -> anchored Regex (IgnoreCase, full match)
function Convert-RcGlobToRegex {
    param([string]$Glob)
    $g = $Glob.TrimStart([char]47)
    $sb = New-Object System.Text.StringBuilder
    $n = $g.Length
    $i = 0
    while ($i -lt $n) {
        $c = $g[$i]
        if ($c -eq [char]42) {
            if ($i + 1 -lt $n -and $g[$i + 1] -eq [char]42) {
                if ($i + 2 -lt $n -and $g[$i + 2] -eq [char]47) {
                    [void]$sb.Append('(?:.*/)?')
                    $i += 3
                }
                else {
                    [void]$sb.Append('.*')
                    $i += 2
                }
            }
            else {
                [void]$sb.Append('[^/]*')
                $i++
            }
        }
        elseif ($c -eq [char]47 -and ($n - $i) -eq 3 -and $g[$i + 1] -eq [char]42 -and $g[$i + 2] -eq [char]42) {
            [void]$sb.Append('(?:/.*)?')
            $i += 3
        }
        elseif ($c -eq [char]63) {
            [void]$sb.Append('[^/]')
            $i++
        }
        else {
            [void]$sb.Append([regex]::Escape([string]$c))
            $i++
        }
    }
    $opts = [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant -bor [Text.RegularExpressions.RegexOptions]::Singleline
    return (New-Object System.Text.RegularExpressions.Regex -ArgumentList ('^(?:' + $sb.ToString() + ')\z'), $opts)
}

# true when $Out equals $Root or lies below it (normalized full paths, case-insensitive, separator boundary)
function Test-RcPathInside {
    param([string]$Out, [string]$Root)
    $sep = [IO.Path]::DirectorySeparatorChar
    $o = [IO.Path]::GetFullPath($Out).TrimEnd($sep, [IO.Path]::AltDirectorySeparatorChar)
    $r = [IO.Path]::GetFullPath($Root).TrimEnd($sep, [IO.Path]::AltDirectorySeparatorChar)
    if ([string]::Equals($o, $r, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $o.StartsWith($r + $sep, [StringComparison]::OrdinalIgnoreCase)
}

function Add-RcBatchFiles {
    param([string]$Dir, [string]$Prefix, $List)
    foreach ($f in [IO.Directory]::GetFiles($Dir)) {
        $List.Add($Prefix + [IO.Path]::GetFileName($f))
    }
    foreach ($d in [IO.Directory]::GetDirectories($Dir)) {
        $name = [IO.Path]::GetFileName($d)
        if ([string]::Equals($name, '.git', [StringComparison]::OrdinalIgnoreCase) -or
            [string]::Equals($name, '.svn', [StringComparison]::OrdinalIgnoreCase)) { continue }
        $attr = [IO.File]::GetAttributes($d)
        if (($attr -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        Add-RcBatchFiles -Dir $d -Prefix ($Prefix + $name + '/') -List $List
    }
}

# relative paths ('/' separated), ordinal order
function Get-RcBatchFiles {
    param([string]$Root)
    $list = New-Object 'System.Collections.Generic.List[string]'
    Add-RcBatchFiles -Dir $Root -Prefix '' -List $list
    $arr = $list.ToArray()
    [Array]::Sort($arr, [StringComparer]::Ordinal)
    return , $arr
}

function ConvertTo-RcCsvLine {
    param([string[]]$Fields)
    $q = [string][char]34
    $parts = foreach ($f in $Fields) { $q + $f.Replace($q, $q + $q) + $q }
    return ($parts -join ',')
}

function ConvertTo-RcCsvNum {
    param($Value)
    if ($null -eq $Value) { return '' }
    return [string]$Value
}

function Write-RcCsvLog {
    param([string]$Path, $Rows)
    $sb = New-Object System.Text.StringBuilder
    $crlf = "`r`n"
    [void]$sb.Append((ConvertTo-RcCsvLine @('path', 'status', 'exitCode', 'removed', 'kept', 'message'))).Append($crlf)
    foreach ($r in $Rows) {
        $line = ConvertTo-RcCsvLine @($r.Path, $r.Status, (ConvertTo-RcCsvNum $r.ExitCode), (ConvertTo-RcCsvNum $r.Removed), (ConvertTo-RcCsvNum $r.Kept), $r.Message)
        [void]$sb.Append($line).Append($crlf)
    }
    $enc = New-Object System.Text.UTF8Encoding -ArgumentList $true
    $body = $enc.GetBytes($sb.ToString())
    $bom = $enc.GetPreamble()
    $bytes = New-Object byte[] ($bom.Length + $body.Length)
    [Array]::Copy($bom, 0, $bytes, 0, $bom.Length)
    [Array]::Copy($body, 0, $bytes, $bom.Length, $body.Length)
    $parent = [IO.Path]::GetDirectoryName($Path)
    if ($parent) { [void][IO.Directory]::CreateDirectory($parent) }
    [IO.File]::WriteAllBytes($Path, $bytes)
}

# Returns @{ ExitCode; Rows; Counts; Lines (stdout); ErrorLines (stderr) }. Prints nothing.
function Invoke-RcBatch {
    param([string]$Config, [string]$Root, [switch]$DryRun, [string]$ScriptDir, [scriptblock]$OnLine)
    Set-StrictMode -Version 2.0
    $ErrorActionPreference = 'Stop'
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $errs = New-Object 'System.Collections.Generic.List[string]'
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $counts = [ordered]@{ OK = 0; EXCLUDED = 0; UNSUPPORTED = 0; ERROR = 0 }
    $exit = 0
    $emit = {
        param([string]$Kind, [string]$Text)
        if ($Kind -eq 'out') { $lines.Add($Text) } else { $errs.Add($Text) }
        if ($null -ne $OnLine) { & $OnLine $Kind $Text }
    }
    try {
        # ---- settings and batch validation (all exit 9, nothing processed)
        try {
            $s = Read-RcSettings -ConfigPath $Config -ScriptDir $ScriptDir
            if (-not $s.OutputMode) { throw (New-RcError -Code 9 -Message "output.mode is required for batch processing") }
            if ($s.OutputMode -eq 'outDir' -and -not $s.OutDir) { throw (New-RcError -Code 9 -Message "output.outDir is required when output.mode is 'outDir'") }
            if ($Root) { $rootDir = Resolve-RcPath -PathText $Root }
            elseif ($s.BatchRoot) { $rootDir = $s.BatchRoot }
            else { throw (New-RcError -Code 9 -Message 'no target directory: give -Root or set batch.root') }
            if (-not [IO.Directory]::Exists($rootDir)) { throw (New-RcError -Code 9 -Message "target directory not found: $rootDir") }
            if ($s.OutputMode -eq 'outDir' -and (Test-RcPathInside -Out $s.OutDir -Root $rootDir)) {
                throw (New-RcError -Code 9 -Message "output.outDir must not be the target directory or inside it: $($s.OutDir)")
            }
        }
        catch {
            $info = Convert-RcException -ErrorRecord $_
            & $emit 'err' $info.Message
            return [pscustomobject]@{ ExitCode = $info.Code; Rows = $rows.ToArray(); Counts = $counts; Lines = $lines.ToArray(); ErrorLines = $errs.ToArray() }
        }

        $globs = New-Object 'System.Collections.Generic.List[object]'
        foreach ($p in $s.Exclude) { $globs.Add(@{ Pattern = $p; Regex = (Convert-RcGlobToRegex -Glob $p) }) }

        $sep = [IO.Path]::DirectorySeparatorChar
        foreach ($rel in (Get-RcBatchFiles -Root $rootDir)) {
            $src = [IO.Path]::Combine($rootDir, $rel.Replace('/', [string]$sep))
            $dest = $null
            if ($s.OutputMode -eq 'outDir') { $dest = [IO.Path]::Combine($s.OutDir, $rel.Replace('/', [string]$sep)) }

            $matched = $null
            foreach ($g in $globs) { if ($g.Regex.IsMatch($rel)) { $matched = $g.Pattern; break } }

            $row = $null
            $copy = $false
            $outLine = ''
            $errMsg = $null
            if ($null -ne $matched) {
                $row = [pscustomobject]@{ Path = $rel; Status = 'EXCLUDED'; ExitCode = $null; Removed = $null; Kept = $null; Message = $matched }
                $outLine = "EXCLUDED`t$rel`t$matched"
                $copy = $true
            }
            else {
                $r = Invoke-RcFile -Settings $s -Path $src -OutPath $dest -DryRun:$DryRun -DisplayPath $rel
                $msg = ''
                if ($r.Status -eq 'ERROR') { $msg = $r.Message; $errMsg = $r.Message }
                $row = [pscustomobject]@{ Path = $rel; Status = $r.Status; ExitCode = $r.ExitCode; Removed = $null; Kept = $null; Message = $msg }
                if ($r.Status -eq 'OK') { $row.Removed = $r.Removed; $row.Kept = $r.Kept }
                $outLine = $r.Line
                if ($r.Status -eq 'UNSUPPORTED') { $copy = $true }
            }

            if ($copy -and $dest -and -not $DryRun) {
                try {
                    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest))
                    [IO.File]::Copy($src, $dest, $true)
                }
                catch {
                    $m = "${rel}: cannot copy to output: $($_.Exception.Message)"
                    $row = [pscustomobject]@{ Path = $rel; Status = 'ERROR'; ExitCode = 5; Removed = $null; Kept = $null; Message = $m }
                    $outLine = "ERROR`t$rel`tcode=5"
                    $errMsg = $m
                }
            }
            & $emit 'out' $outLine
            if ($null -ne $errMsg) { & $emit 'err' $errMsg }
            $rows.Add($row)
            $counts[$row.Status] = [int]$counts[$row.Status] + 1
        }

        & $emit 'out' (('OK={0} EXCLUDED={1} UNSUPPORTED={2} ERROR={3}' -f $counts['OK'], $counts['EXCLUDED'], $counts['UNSUPPORTED'], $counts['ERROR']))
        if ($counts['ERROR'] -gt 0) { $exit = 1 }

        if ($s.LogPath) {
            try { Write-RcCsvLog -Path $s.LogPath -Rows $rows }
            catch {
                & $emit 'err' "cannot write log '$($s.LogPath)': $($_.Exception.Message)"
                $exit = 1
            }
        }
    }
    catch {
        $info = Convert-RcException -ErrorRecord $_
        & $emit 'err' $info.Message
        $exit = 1
    }
    return [pscustomobject]@{ ExitCode = $exit; Rows = $rows.ToArray(); Counts = $counts; Lines = $lines.ToArray(); ErrorLines = $errs.ToArray() }
}

if ($MyInvocation.InvocationName -eq '.') { return }

$rcBatchResult = Invoke-RcBatch -Config $batch.Config -Root $batch.Root -DryRun:$batch.DryRun -ScriptDir $PSScriptRoot -OnLine {
    param($kind, $text)
    if ($kind -eq 'out') { [Console]::Out.WriteLine($text) } else { [Console]::Error.WriteLine($text) }
}
exit $rcBatchResult.ExitCode
