param([string]$Path, [string]$Config, [string]$OutPath, [switch]$DryRun)

# Remove-Comments.ps1 : single-file comment remover (see docs/spec.md, docs/design.md)
# All functions carry the "Rc" prefix. No Set-StrictMode at script level (dot-source safe).

# ---------------------------------------------------------------------------
# errors / results
# ---------------------------------------------------------------------------

function New-RcError {
    param([int]$Code, [string]$Message, [int]$Line = 0)
    $ex = New-Object System.Exception -ArgumentList $Message
    $ex.Data['RcExitCode'] = $Code
    if ($Line -gt 0) { $ex.Data['RcLine'] = $Line }
    return $ex
}

# ErrorRecord -> @{ Code; Message; Line }  (design 2.4)
function Convert-RcException {
    param($ErrorRecord)
    $e = $ErrorRecord.Exception
    while ($null -ne $e) {
        if ($e.Data.Contains('RcExitCode')) {
            $line = 0
            if ($e.Data.Contains('RcLine')) { $line = [int]$e.Data['RcLine'] }
            return @{ Code = [int]$e.Data['RcExitCode']; Message = [string]$e.Message; Line = $line }
        }
        if ($e -is [System.Text.RegularExpressions.RegexMatchTimeoutException]) {
            return @{ Code = 6; Message = 'regex match timed out'; Line = 0 }
        }
        if ($e -is [System.IO.IOException] -or $e -is [System.UnauthorizedAccessException]) {
            return @{ Code = 5; Message = [string]$e.Message; Line = 0 }
        }
        $e = $e.InnerException
    }
    $root = $ErrorRecord.Exception
    $at = ''
    if ($null -ne $ErrorRecord.InvocationInfo) { $at = " (script line $($ErrorRecord.InvocationInfo.ScriptLineNumber))" }
    return @{ Code = 1; Message = "internal error: $($root.GetType().FullName): $($root.Message)$at"; Line = 0 }
}

function Format-RcMessage {
    param([string]$Display, $Info)
    if ($Info.Line -gt 0) { return "${Display}:$($Info.Line): $($Info.Message)" }
    return "${Display}: $($Info.Message)"
}

function New-RcResult {
    param([int]$ExitCode, [string]$Status, [string]$Display, [int]$Removed = 0, [int]$Kept = 0, [string]$Message = '')
    $tab = "`t"
    switch ($Status) {
        'OK'          { $line = "OK${tab}${Display}${tab}removed=${Removed}${tab}kept=${Kept}" }
        'UNSUPPORTED' { $line = "UNSUPPORTED${tab}${Display}" }
        default       { $line = "ERROR${tab}${Display}${tab}code=${ExitCode}" }
    }
    return [pscustomobject]@{
        ExitCode = $ExitCode; Status = $Status; Removed = $Removed; Kept = $Kept; Message = $Message; Line = $line
    }
}

# ---------------------------------------------------------------------------
# settings (design 2.2, spec ch.10)
# ---------------------------------------------------------------------------

function Resolve-RcPath {
    param([string]$PathText, [string]$BaseDir)
    if (-not $BaseDir) { $BaseDir = (Get-Location).ProviderPath }
    if ([IO.Path]::IsPathRooted($PathText)) { return [IO.Path]::GetFullPath($PathText) }
    return [IO.Path]::GetFullPath([IO.Path]::Combine($BaseDir, $PathText))
}

# JSON object -> hashtable of its keys (case-sensitive key check, "_" keys ignored)
function Get-RcObjectMap {
    param($Obj, [string[]]$Allowed, [string]$Where)
    if ($null -eq $Obj -or $Obj -isnot [System.Management.Automation.PSCustomObject]) {
        throw (New-RcError -Code 9 -Message "$Where must be an object")
    }
    $map = @{}
    foreach ($p in $Obj.PSObject.Properties) {
        $name = [string]$p.Name
        if ($name.StartsWith('_')) { continue }
        if (-not ($Allowed -ccontains $name)) {
            throw (New-RcError -Code 9 -Message "unknown key '$name' in $Where")
        }
        $map[$name] = $p.Value
    }
    return $map
}

function Get-RcString {
    param($Value, [string]$Where)
    if ($Value -is [datetime]) {
        throw (New-RcError -Code 9 -Message "$Where looks like a date and was converted to [datetime] by ConvertFrom-Json (PowerShell 7 without -DateKind); use PowerShell 7.5 or later, or change the value so it does not look like a date")
    }
    if ($Value -isnot [string]) { throw (New-RcError -Code 9 -Message "$Where must be a string") }
    if ($Value.Length -eq 0) { throw (New-RcError -Code 9 -Message "$Where must not be empty") }
    return $Value
}

function Get-RcBool {
    param($Value, [string]$Where)
    if ($Value -isnot [bool]) { throw (New-RcError -Code 9 -Message "$Where must be true or false") }
    return $Value
}

function Get-RcStringArray {
    param($Value, [string]$Where)
    if ($Value -isnot [Array]) { throw (New-RcError -Code 9 -Message "$Where must be an array of strings") }
    $list = New-Object 'System.Collections.Generic.List[string]'
    foreach ($v in $Value) {
        $list.Add((Get-RcString -Value $v -Where "$Where[]"))
    }
    return , $list.ToArray()
}

function Get-RcDefaultLanguages {
    return @{
        cpp        = @{ Extensions = [string[]]@('.c', '.cpp', '.cc', '.h', '.hpp', '.hh'); FileNames = [string[]]@(); KeepPatterns = [string[]]@() }
        java       = @{ Extensions = [string[]]@('.java'); FileNames = [string[]]@(); KeepPatterns = [string[]]@() }
        typescript = @{ Extensions = [string[]]@('.ts'); FileNames = [string[]]@(); KeepPatterns = [string[]]@() }
        css        = @{ Extensions = [string[]]@('.css'); FileNames = [string[]]@(); KeepPatterns = [string[]]@() }
        html       = @{ Extensions = [string[]]@('.html'); FileNames = [string[]]@(); KeepPatterns = [string[]]@() }
        shell      = @{ Extensions = [string[]]@('.sh'); FileNames = [string[]]@(); KeepPatterns = [string[]]@() }
        makefile   = @{ Extensions = [string[]]@('.mk'); FileNames = [string[]]@('Makefile', 'makefile', 'GNUmakefile'); KeepPatterns = [string[]]@() }
        conf       = @{ Extensions = [string[]]@('.conf'); FileNames = [string[]]@(); KeepPatterns = [string[]]@() }
    }
}

function Read-RcSettings {
    param([string]$ConfigPath, [string]$ScriptDir)
    if (-not $ScriptDir) { $ScriptDir = $PSScriptRoot }
    $cwd = (Get-Location).ProviderPath

    # search order: -Config > ./remove-comments.json > <script dir>/remove-comments.json
    $cfgFile = $null
    if ($ConfigPath) {
        $cfgFile = Resolve-RcPath -PathText $ConfigPath -BaseDir $cwd
        if (-not [IO.File]::Exists($cfgFile)) {
            throw (New-RcError -Code 9 -Message "config file not found: $ConfigPath")
        }
    }
    else {
        $c1 = Join-Path $cwd 'remove-comments.json'
        if ([IO.File]::Exists($c1)) { $cfgFile = $c1 }
        elseif ($ScriptDir) {
            $c2 = Join-Path $ScriptDir 'remove-comments.json'
            if ([IO.File]::Exists($c2)) { $cfgFile = $c2 }
        }
    }
    $configDir = $cwd
    if ($cfgFile) { $configDir = [IO.Path]::GetDirectoryName($cfgFile) }

    $top = @{}
    if ($cfgFile) {
        $root = $null
        try {
            $json = [IO.File]::ReadAllText($cfgFile, (New-Object System.Text.UTF8Encoding -ArgumentList $false))
            if ($json.TrimStart().StartsWith('[')) { throw 'top level must be an object' }
            if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
                $root = ConvertFrom-Json -InputObject $json -DateKind String -ErrorAction Stop
            }
            else {
                $root = ConvertFrom-Json -InputObject $json -ErrorAction Stop
            }
        }
        catch {
            throw (New-RcError -Code 9 -Message "cannot parse config '$cfgFile': $($_.Exception.Message)")
        }
        $top = Get-RcObjectMap -Obj $root -Where 'config' -Allowed @(
            'version', 'output', 'encoding', 'keep', 'keepRegion', 'languages', 'batch', 'exclude', 'excludeFiles', 'log')
    }

    $s = @{
        ConfigPath       = $cfgFile
        ConfigDir        = $configDir
        OutputMode       = $null
        OutDir           = $null
        Backup           = $false
        EncodingMode     = 'auto'
        KeepPatterns     = [string[]]@()
        KeepRegex        = @()
        CaseSensitive    = $true
        RegionStart      = '% DEL START'
        RegionEnd        = '% DEL END'
        ExtMap           = @{}
        NameMap          = @{}
        LangKeepPatterns = @{}
        BatchRoot        = $null
        Exclude          = [string[]]@()
        LogPath          = $null
    }

    if ($top.ContainsKey('version')) {
        $v = $top['version']
        if (-not (($v -is [int] -or $v -is [long]) -and $v -eq 1)) {
            throw (New-RcError -Code 9 -Message 'version must be the integer 1')
        }
    }

    if ($top.ContainsKey('output')) {
        $o = Get-RcObjectMap -Obj $top['output'] -Where 'output' -Allowed @('mode', 'outDir', 'backup')
        if ($o.ContainsKey('mode')) {
            $m = $o['mode']
            if ($m -isnot [string] -or -not (@('outDir', 'inPlace') -ccontains $m)) {
                throw (New-RcError -Code 9 -Message "output.mode must be 'outDir' or 'inPlace'")
            }
            $s.OutputMode = $m
        }
        if ($o.ContainsKey('outDir')) {
            $s.OutDir = Resolve-RcPath -PathText (Get-RcString -Value $o['outDir'] -Where 'output.outDir') -BaseDir $configDir
        }
        if ($o.ContainsKey('backup')) { $s.Backup = Get-RcBool -Value $o['backup'] -Where 'output.backup' }
    }

    if ($top.ContainsKey('encoding')) {
        $e = $top['encoding']
        if ($e -isnot [string] -or -not (@('auto', 'utf8', 'sjis') -ccontains $e)) {
            throw (New-RcError -Code 9 -Message "encoding must be 'auto', 'utf8' or 'sjis'")
        }
        $s.EncodingMode = $e
    }

    if ($top.ContainsKey('keep')) {
        $k = Get-RcObjectMap -Obj $top['keep'] -Where 'keep' -Allowed @('patterns', 'regex', 'caseSensitive')
        if ($k.ContainsKey('patterns')) { $s.KeepPatterns = Get-RcStringArray -Value $k['patterns'] -Where 'keep.patterns' }
        if ($k.ContainsKey('caseSensitive')) { $s.CaseSensitive = Get-RcBool -Value $k['caseSensitive'] -Where 'keep.caseSensitive' }
        if ($k.ContainsKey('regex')) {
            $srcs = Get-RcStringArray -Value $k['regex'] -Where 'keep.regex'
            $opts = [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
            if (-not $s.CaseSensitive) { $opts = $opts -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase }
            $list = New-Object 'System.Collections.Generic.List[object]'
            foreach ($src in $srcs) {
                try { $rx = New-Object System.Text.RegularExpressions.Regex -ArgumentList $src, $opts, ([TimeSpan]::FromSeconds(1)) }
                catch { throw (New-RcError -Code 9 -Message "invalid regex in keep.regex: '$src': $($_.Exception.Message)") }
                $list.Add($rx)
            }
            $s.KeepRegex = $list.ToArray()
        }
    }

    if ($top.ContainsKey('keepRegion')) {
        $r = Get-RcObjectMap -Obj $top['keepRegion'] -Where 'keepRegion' -Allowed @('start', 'end')
        if ($r.ContainsKey('start')) { $s.RegionStart = Get-RcString -Value $r['start'] -Where 'keepRegion.start' }
        if ($r.ContainsKey('end')) { $s.RegionEnd = Get-RcString -Value $r['end'] -Where 'keepRegion.end' }
    }
    if ([string]::Equals($s.RegionStart, $s.RegionEnd, [StringComparison]::Ordinal)) {
        throw (New-RcError -Code 9 -Message 'keepRegion.start and keepRegion.end must differ')
    }

    # languages: only the keys written replace the defaults
    $langNames = @('cpp', 'java', 'typescript', 'css', 'html', 'shell', 'makefile', 'conf')
    $defs = Get-RcDefaultLanguages
    if ($top.ContainsKey('languages')) {
        $lm = Get-RcObjectMap -Obj $top['languages'] -Where 'languages' -Allowed $langNames
        foreach ($ln in $langNames) {
            if (-not $lm.ContainsKey($ln)) { continue }
            $lo = Get-RcObjectMap -Obj $lm[$ln] -Where "languages.$ln" -Allowed @('extensions', 'fileNames', 'keepPatterns')
            if ($lo.ContainsKey('extensions')) {
                $exts = Get-RcStringArray -Value $lo['extensions'] -Where "languages.$ln.extensions"
                foreach ($x in $exts) {
                    if (-not $x.StartsWith('.') -or $x.Length -lt 2) {
                        throw (New-RcError -Code 9 -Message "languages.$ln.extensions: '$x' must start with '.'")
                    }
                }
                $defs[$ln].Extensions = $exts
            }
            if ($lo.ContainsKey('fileNames')) {
                $names = Get-RcStringArray -Value $lo['fileNames'] -Where "languages.$ln.fileNames"
                foreach ($x in $names) {
                    if ($x.IndexOf([char]47) -ge 0 -or $x.IndexOf([char]92) -ge 0) {
                        throw (New-RcError -Code 9 -Message "languages.$ln.fileNames: '$x' must be a file name without path")
                    }
                }
                $defs[$ln].FileNames = $names
            }
            if ($lo.ContainsKey('keepPatterns')) {
                $defs[$ln].KeepPatterns = Get-RcStringArray -Value $lo['keepPatterns'] -Where "languages.$ln.keepPatterns"
            }
        }
    }
    foreach ($ln in $langNames) {
        foreach ($x in $defs[$ln].Extensions) {
            $key = $x.ToLowerInvariant()
            if ($s.ExtMap.ContainsKey($key) -and $s.ExtMap[$key] -ne $ln) {
                throw (New-RcError -Code 9 -Message "extension '$x' is assigned to both '$($s.ExtMap[$key])' and '$ln'")
            }
            $s.ExtMap[$key] = $ln
        }
        foreach ($x in $defs[$ln].FileNames) {
            $key = $x.ToLowerInvariant()
            if ($s.NameMap.ContainsKey($key) -and $s.NameMap[$key] -ne $ln) {
                throw (New-RcError -Code 9 -Message "file name '$x' is assigned to both '$($s.NameMap[$key])' and '$ln'")
            }
            $s.NameMap[$key] = $ln
        }
        $s.LangKeepPatterns[$ln] = $defs[$ln].KeepPatterns
    }

    if ($top.ContainsKey('batch')) {
        $b = Get-RcObjectMap -Obj $top['batch'] -Where 'batch' -Allowed @('root')
        if ($b.ContainsKey('root')) {
            $s.BatchRoot = Resolve-RcPath -PathText (Get-RcString -Value $b['root'] -Where 'batch.root') -BaseDir $configDir
        }
    }

    $ex = New-Object 'System.Collections.Generic.List[string]'
    if ($top.ContainsKey('exclude')) {
        foreach ($x in (Get-RcStringArray -Value $top['exclude'] -Where 'exclude')) { $ex.Add($x) }
    }
    if ($top.ContainsKey('excludeFiles')) {
        foreach ($f in (Get-RcStringArray -Value $top['excludeFiles'] -Where 'excludeFiles')) {
            $full = Resolve-RcPath -PathText $f -BaseDir $configDir
            try { $content = [IO.File]::ReadAllText($full, (New-Object System.Text.UTF8Encoding -ArgumentList $false)) }
            catch { throw (New-RcError -Code 9 -Message "cannot read excludeFiles '$f': $($_.Exception.Message)") }
            foreach ($ln in ($content -split "\r?\n")) {
                $t = $ln.Trim()
                if ($t.Length -eq 0 -or $t.StartsWith('#')) { continue }
                $ex.Add($t)
            }
        }
    }
    $s.Exclude = $ex.ToArray()

    if ($top.ContainsKey('log')) {
        $lg = Get-RcObjectMap -Obj $top['log'] -Where 'log' -Allowed @('path')
        if ($lg.ContainsKey('path')) {
            $s.LogPath = Resolve-RcPath -PathText (Get-RcString -Value $lg['path'] -Where 'log.path') -BaseDir $configDir
        }
    }
    return $s
}

function Get-RcLanguage {
    param($Settings, [string]$FilePath)
    $name = [IO.Path]::GetFileName($FilePath)
    if (-not $name) { return $null }
    $lower = $name.ToLowerInvariant()
    if ($Settings.NameMap.ContainsKey($lower)) { return $Settings.NameMap[$lower] }
    # longest suffix first (".d.ts" before ".ts")
    $i = $lower.IndexOf([char]46)
    while ($i -ge 0) {
        $suffix = $lower.Substring($i)
        if ($Settings.ExtMap.ContainsKey($suffix)) { return $Settings.ExtMap[$suffix] }
        $i = $lower.IndexOf([char]46, $i + 1)
    }
    return $null
}

# ---------------------------------------------------------------------------
# file I/O (design 5)
# ---------------------------------------------------------------------------

function Get-RcCp932 {
    try { [Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance) } catch { }
    return [Text.Encoding]::GetEncoding(932, [Text.EncoderFallback]::ExceptionFallback, [Text.DecoderFallback]::ExceptionFallback)
}

function Test-RcBytesEqual {
    param([byte[]]$A, [byte[]]$B, [int]$OffsetA)
    if ($A.Length - $OffsetA -ne $B.Length) { return $false }
    for ($i = 0; $i -lt $B.Length; $i++) {
        if ($A[$OffsetA + $i] -ne $B[$i]) { return $false }
    }
    return $true
}

function Read-RcTextFile {
    param([string]$Path, [string]$EncodingMode = 'auto')
    $bytes = [IO.File]::ReadAllBytes($Path)
    $n = $bytes.Length
    $utf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false, $true
    $enc = $null
    $bomLen = 0
    $isUtf16 = $false

    if ($EncodingMode -eq 'sjis') {
        $enc = Get-RcCp932
    }
    elseif ($n -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $enc = $utf8; $bomLen = 3
    }
    elseif ($EncodingMode -eq 'auto' -and $n -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $enc = New-Object System.Text.UnicodeEncoding -ArgumentList $false, $false, $true; $bomLen = 2; $isUtf16 = $true
    }
    elseif ($EncodingMode -eq 'auto' -and $n -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $enc = New-Object System.Text.UnicodeEncoding -ArgumentList $true, $false, $true; $bomLen = 2; $isUtf16 = $true
    }
    else {
        $enc = $utf8
    }

    $text = $null
    try { $text = $enc.GetString($bytes, $bomLen, $n - $bomLen) }
    catch {
        if ($EncodingMode -eq 'auto' -and $bomLen -eq 0 -and -not $isUtf16) {
            # not valid UTF-8 -> CP932
            $enc = Get-RcCp932
            try { $text = $enc.GetString($bytes, 0, $n) }
            catch { throw (New-RcError -Code 5 -Message 'cannot decode file as UTF-8 or Shift_JIS') }
        }
        else {
            throw (New-RcError -Code 5 -Message "cannot decode file with the selected encoding ($EncodingMode)")
        }
    }

    # NUL check = binary
    if ($isUtf16) {
        if ($text.IndexOf([char]0) -ge 0) { throw (New-RcError -Code 5 -Message 'file contains NUL (binary file)') }
    }
    elseif ([Array]::IndexOf($bytes, [byte]0) -ge 0) {
        throw (New-RcError -Code 5 -Message 'file contains NUL (binary file)')
    }

    # round trip: the decoded text must re-encode to the same bytes
    $back = $null
    try { $back = $enc.GetBytes($text) }
    catch { throw (New-RcError -Code 5 -Message 'text does not round-trip through its encoding') }
    if (-not (Test-RcBytesEqual -A $bytes -B $back -OffsetA $bomLen)) {
        throw (New-RcError -Code 5 -Message 'text does not round-trip through its encoding')
    }

    $bom = New-Object byte[] $bomLen
    if ($bomLen -gt 0) { [Array]::Copy($bytes, 0, $bom, 0, $bomLen) }
    return @{ Text = $text; Encoding = $enc; Bom = $bom }
}

function Write-RcTextFile {
    param([string]$Path, [string]$Text, $Encoding, [byte[]]$Bom)
    $tmp = $null
    try {
        $body = $Encoding.GetBytes($Text)
        if ($null -eq $Bom) { $Bom = New-Object byte[] 0 }
        $all = New-Object byte[] ($Bom.Length + $body.Length)
        [Array]::Copy($Bom, 0, $all, 0, $Bom.Length)
        [Array]::Copy($body, 0, $all, $Bom.Length, $body.Length)
        $dir = [IO.Path]::GetDirectoryName($Path)
        if ($dir -and -not [IO.Directory]::Exists($dir)) { [void][IO.Directory]::CreateDirectory($dir) }
        $tmp = "$Path.rctmp-" + [Guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllBytes($tmp, $all)
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) }
        else { [IO.File]::Move($tmp, $Path) }
    }
    catch {
        $msg = $_.Exception.Message
        if ($tmp -and [IO.File]::Exists($tmp)) { try { [IO.File]::Delete($tmp) } catch { } }
        throw (New-RcError -Code 5 -Message "write failed: $msg")
    }
}

# ---------------------------------------------------------------------------
# lexers
# ---------------------------------------------------------------------------

function New-RcToken {
    param([int]$Start, [int]$End, [string]$Kind = 'line', [bool]$Fixed = $false)
    return [pscustomobject]@{ Start = $Start; End = $End; Kind = $Kind; Fixed = $Fixed; Keep = $false }
}

# conf: a line whose first non-blank char is '#' (design 3.8)
function Get-RcCommentsConf {
    param([string]$Text)
    $list = New-Object 'System.Collections.Generic.List[object]'
    $n = $Text.Length
    $pos = 0
    while ($pos -lt $n) {
        $nl = $Text.IndexOf([char]10, $pos)
        if ($nl -lt 0) { $lineEnd = $n; $ce = $n }
        else {
            $lineEnd = $nl + 1
            if ($nl -gt $pos -and $Text[$nl - 1] -ceq [char]13) { $ce = $nl - 1 } else { $ce = $nl }
        }
        $i = $pos
        while ($i -lt $ce -and [char]::IsWhiteSpace($Text[$i])) { $i++ }
        if ($i -lt $ce -and $Text[$i] -ceq [char]35) {
            $list.Add((New-RcToken -Start $i -End $ce -Kind 'line'))
        }
        $pos = $lineEnd
    }
    return , $list
}

# C/C++, Java, CSS (design 3.3)
function Get-RcLineNumber {
    param([string]$Text, [int]$Pos)
    $line = 1
    $p = 0
    while ($true) {
        $q = $Text.IndexOf([char]10, $p)
        if ($q -lt 0 -or $q -ge $Pos) { break }
        $line++
        $p = $q + 1
    }
    return $line
}

function Test-RcIdentChar {
    param([char]$C)
    return ([char]::IsLetterOrDigit($C) -or $C -ceq [char]95)
}

# skips a '...' or "..." literal starting at $Start (the quote); returns the index after the closing quote
function Skip-RcQuoted {
    param([string]$Text, [int]$Start, [string]$What)
    $q = $Text[$Start]
    $n = $Text.Length
    $j = $Start + 1
    while ($j -lt $n) {
        $ch = $Text[$j]
        if ($ch -ceq [char]92) {
            if ($j + 2 -lt $n -and $Text[$j + 1] -ceq [char]13 -and $Text[$j + 2] -ceq [char]10) { $j += 3 } else { $j += 2 }
            continue
        }
        if ($ch -ceq $q) { return ($j + 1) }
        if ($ch -ceq [char]10) { break }
        $j++
    }
    throw (New-RcError -Code 3 -Line (Get-RcLineNumber -Text $Text -Pos $Start) -Message "unclosed $What")
}

function Get-RcCommentsCLike {
    param([string]$Text, [string]$Flavor)
    $list = New-Object 'System.Collections.Generic.List[object]'
    $n = $Text.Length
    $special = [char[]]@([char]47, [char]34, [char]39)
    $isCpp = ($Flavor -ceq 'cpp')
    $isJava = ($Flavor -ceq 'java')
    $i = 0
    while ($i -lt $n) {
        $i = $Text.IndexOfAny($special, $i)
        if ($i -lt 0) { break }
        $c = $Text[$i]
        if ($c -ceq [char]47) {
            $next = [char]0
            if ($i + 1 -lt $n) { $next = $Text[$i + 1] }
            if ($next -ceq [char]42) {
                $end = $Text.IndexOf('*/', $i + 2, [StringComparison]::Ordinal)
                if ($end -lt 0) {
                    throw (New-RcError -Code 3 -Line (Get-RcLineNumber -Text $Text -Pos $i) -Message 'unclosed block comment')
                }
                $list.Add((New-RcToken -Start $i -End ($end + 2) -Kind 'block'))
                $i = $end + 2
            }
            elseif ($next -ceq [char]47 -and $Flavor -cne 'css') {
                $p = $i
                while ($true) {
                    $nl = $Text.IndexOf([char]10, $p)
                    if ($nl -lt 0) { $ce = $n } elseif ($nl -gt $p -and $Text[$nl - 1] -ceq [char]13) { $ce = $nl - 1 } else { $ce = $nl }
                    if ($isCpp -and $nl -ge 0 -and $ce -gt $p -and $Text[$ce - 1] -ceq [char]92) { $p = $nl + 1; continue }
                    break
                }
                if ($isCpp -and $nl -lt 0 -and $ce -gt 0 -and $Text[$ce - 1] -ceq [char]92) { $ce = $n }
                $list.Add((New-RcToken -Start $i -End $ce -Kind 'line'))
                $i = $ce
            }
            else { $i++ }
            continue
        }
        if ($c -ceq [char]34) {
            if ($isJava -and $i + 2 -lt $n -and $Text[$i + 1] -ceq [char]34 -and $Text[$i + 2] -ceq [char]34) {
                $j = $i + 3
                $closed = $false
                while ($j -lt $n) {
                    $ch = $Text[$j]
                    if ($ch -ceq [char]92) { $j += 2; continue }
                    if ($ch -ceq [char]34 -and $j + 2 -lt $n + 0 -and $Text[$j + 1] -ceq [char]34 -and $Text[$j + 2] -ceq [char]34) { $closed = $true; break }
                    $j++
                }
                if (-not $closed) {
                    throw (New-RcError -Code 3 -Line (Get-RcLineNumber -Text $Text -Pos $i) -Message 'unclosed text block')
                }
                $i = $j + 3
                continue
            }
            if ($isCpp -and $i -gt 0 -and $Text[$i - 1] -ceq [char]82) {
                $ps = $i - 1                 # index of 'R'
                if ($ps -ge 2 -and $Text[$ps - 2] -ceq [char]117 -and $Text[$ps - 1] -ceq [char]56) { $ps -= 2 }
                elseif ($ps -ge 1 -and (@([char]76, [char]117, [char]85) -ccontains $Text[$ps - 1])) { $ps -= 1 }
                if ($ps -eq 0 -or -not (Test-RcIdentChar $Text[$ps - 1])) {
                    $k = $i + 1
                    while ($k -lt $n -and $k - $i -le 17 -and $Text[$k] -cne [char]40) {
                        $d = $Text[$k]
                        if ($d -ceq [char]41 -or $d -ceq [char]92 -or $d -ceq [char]34 -or [char]::IsWhiteSpace($d)) { break }
                        $k++
                    }
                    if ($k -ge $n -or $Text[$k] -cne [char]40 -or $k - $i - 1 -gt 16) {
                        throw (New-RcError -Code 3 -Line (Get-RcLineNumber -Text $Text -Pos $i) -Message 'invalid raw string delimiter')
                    }
                    $term = ')' + $Text.Substring($i + 1, $k - $i - 1) + '"'
                    $end = $Text.IndexOf($term, $k + 1, [StringComparison]::Ordinal)
                    if ($end -lt 0) {
                        throw (New-RcError -Code 3 -Line (Get-RcLineNumber -Text $Text -Pos $i) -Message 'unclosed raw string')
                    }
                    $i = $end + $term.Length
                    continue
                }
            }
            $i = Skip-RcQuoted -Text $Text -Start $i -What 'string'
            continue
        }
        # single quote
        if ($isCpp -and $i -gt 0 -and [char]::IsLetterOrDigit($Text[$i - 1])) {
            $b = $i - 1
            while ($b -ge 0 -and ((Test-RcIdentChar $Text[$b]) -or $Text[$b] -ceq [char]39)) { $b-- }
            $b++
            if ($Text[$b] -ge [char]48 -and $Text[$b] -le [char]57) { $i++; continue }   # digit separator
        }
        $i = Skip-RcQuoted -Text $Text -Start $i -What 'character literal'
    }
    return , $list
}

# TypeScript (design 3.4)
# decides whether a '/' after the code in $Seg starts a regex literal ('re') or is a division ('div')
function Get-RcTsPrev {
    param([string]$Seg, [string]$Prev)
    $e = $Seg.Length - 1
    while ($e -ge 0 -and [char]::IsWhiteSpace($Seg[$e])) { $e-- }
    if ($e -lt 0) { return $Prev }
    $ch = $Seg[$e]
    # postfix ++ / -- : the '/' that follows is a division
    if (($ch -ceq [char]43 -or $ch -ceq [char]45) -and $e -ge 1 -and $Seg[$e - 1] -ceq $ch) { return 'div' }
    if ('(,=:[!&|?{};+-*%<>~^/'.IndexOf($ch) -ge 0) { return 're' }
    if ([char]::IsLetterOrDigit($ch) -or $ch -ceq [char]95 -or $ch -ceq [char]36) {
        $b = $e
        while ($b -gt 0 -and ([char]::IsLetterOrDigit($Seg[$b - 1]) -or $Seg[$b - 1] -ceq [char]95 -or $Seg[$b - 1] -ceq [char]36)) { $b-- }
        $word = $Seg.Substring($b, $e - $b + 1)
        if (@('return', 'typeof', 'instanceof', 'in', 'of', 'new', 'delete', 'void', 'throw', 'case', 'do', 'else', 'yield', 'await') -ccontains $word) { return 're' }
    }
    return 'div'
}

function Get-RcCommentsTypeScript {
    param([string]$Text)
    $list = New-Object 'System.Collections.Generic.List[object]'
    $n = $Text.Length
    $codeSpecial = [char[]]@([char]47, [char]34, [char]39, [char]96, [char]123, [char]125)
    $tmplSpecial = [char[]]@([char]96, [char]92, [char]36)
    $depthStack = New-Object 'System.Collections.Generic.List[int]'
    $startStack = New-Object 'System.Collections.Generic.List[int]'
    $inTemplate = $false
    $depth = 0
    $tstart = 0
    $prev = 're'
    $segStart = 0
    $i = 0
    while ($i -lt $n) {
        if ($inTemplate) {
            $j = $Text.IndexOfAny($tmplSpecial, $i)
            if ($j -lt 0) { $i = $n; break }
            $c = $Text[$j]
            if ($c -ceq [char]92) { $i = $j + 2 }
            elseif ($c -ceq [char]36) {
                if ($j + 1 -lt $n -and $Text[$j + 1] -ceq [char]123) {
                    $depthStack.Add($depth); $startStack.Add($tstart)
                    $depth = 0; $inTemplate = $false; $prev = 're'
                    $i = $j + 2; $segStart = $i
                }
                else { $i = $j + 1 }
            }
            else {
                $inTemplate = $false; $prev = 'div'
                $i = $j + 1; $segStart = $i
            }
            continue
        }
        $i = $Text.IndexOfAny($codeSpecial, $i)
        if ($i -lt 0) { $i = $n; break }
        $c = $Text[$i]
        if ($c -ceq [char]47) {
            $prev = Get-RcTsPrev -Seg $Text.Substring($segStart, $i - $segStart) -Prev $prev
            $segStart = $i
            $next = [char]0
            if ($i + 1 -lt $n) { $next = $Text[$i + 1] }
            if ($next -ceq [char]42) {
                $end = $Text.IndexOf('*/', $i + 2, [StringComparison]::Ordinal)
                if ($end -lt 0) {
                    throw (New-RcError -Code 3 -Line (Get-RcLineNumber -Text $Text -Pos $i) -Message 'unclosed block comment')
                }
                $list.Add((New-RcToken -Start $i -End ($end + 2) -Kind 'block'))
                $i = $end + 2; $segStart = $i
            }
            elseif ($next -ceq [char]47) {
                $nl = $Text.IndexOf([char]10, $i)
                if ($nl -lt 0) { $ce = $n } elseif ($nl -gt $i -and $Text[$nl - 1] -ceq [char]13) { $ce = $nl - 1 } else { $ce = $nl }
                $tok = New-RcToken -Start $i -End $ce -Kind 'line'
                if ([regex]::IsMatch($Text.Substring($i, $ce - $i), '^///\s*<reference\b', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)) { $tok.Fixed = $true }
                $list.Add($tok)
                $i = $ce; $segStart = $i
            }
            elseif ($prev -ceq 're') {
                $j = $i + 1
                $inClass = $false
                $ok = $false
                while ($j -lt $n) {
                    $ch = $Text[$j]
                    if ($ch -ceq [char]92) { $j += 2; continue }
                    if ($ch -ceq [char]10) { break }
                    if ($ch -ceq [char]91) { $inClass = $true }
                    elseif ($ch -ceq [char]93) { $inClass = $false }
                    elseif ($ch -ceq [char]47 -and -not $inClass) { $ok = $true; break }
                    $j++
                }
                if ($ok) {
                    $j++
                    while ($j -lt $n -and [char]::IsLetter($Text[$j])) { $j++ }
                    $i = $j; $segStart = $i; $prev = 'div'
                }
                else { $i++ }       # not a regex after all: division
            }
            else { $i++ }
            continue
        }
        if ($c -ceq [char]34 -or $c -ceq [char]39) {
            $i = Skip-RcQuoted -Text $Text -Start $i -What 'string'
            $prev = 'div'; $segStart = $i
            continue
        }
        if ($c -ceq [char]96) {
            $inTemplate = $true; $tstart = $i
            $i++
            continue
        }
        if ($c -ceq [char]123) { $depth++ }
        elseif ($depth -gt 0) { $depth-- }
        elseif ($depthStack.Count -gt 0) {
            $last = $depthStack.Count - 1
            $depth = $depthStack[$last]; $tstart = $startStack[$last]
            $depthStack.RemoveAt($last); $startStack.RemoveAt($last)
            $inTemplate = $true
        }
        $prev = 're'
        $i++; $segStart = $i
    }
    if ($inTemplate -or $depthStack.Count -gt 0) {
        if (-not $inTemplate) { $tstart = $startStack[$startStack.Count - 1] }
        throw (New-RcError -Code 3 -Line (Get-RcLineNumber -Text $Text -Pos $tstart) -Message 'unclosed template literal')
    }
    return , $list
}

# HTML (design 3.5)
function Get-RcCommentsHtml {
    param([string]$Text)
    $list = New-Object 'System.Collections.Generic.List[object]'
    $n = $Text.Length
    $ord = [StringComparison]::Ordinal
    $i = 0
    while ($i -lt $n) {
        $i = $Text.IndexOf([char]60, $i)
        if ($i -lt 0) { break }
        if ($i + 3 -lt $n -and $Text[$i + 1] -ceq [char]33 -and $Text[$i + 2] -ceq [char]45 -and $Text[$i + 3] -ceq [char]45) {
            if ($i + 4 -lt $n -and $Text[$i + 4] -ceq [char]62) { $end = $i + 2; $tokEnd = $i + 5 }                  # <!-->
            elseif ($i + 5 -lt $n -and $Text[$i + 4] -ceq [char]45 -and $Text[$i + 5] -ceq [char]62) { $end = $i + 3; $tokEnd = $i + 6 }   # <!--->
            else {
                $end = $Text.IndexOf('-->', $i + 4, $ord)
                if ($end -lt 0) {
                    throw (New-RcError -Code 3 -Line (Get-RcLineNumber -Text $Text -Pos $i) -Message 'unclosed comment')
                }
                $tokEnd = $end + 3
            }
            $tok = New-RcToken -Start $i -End $tokEnd -Kind 'block'
            if ([string]::CompareOrdinal($Text, $i, '<!--[if', 0, 7) -eq 0 -or
                [string]::CompareOrdinal($Text, $i, '<!--<![endif]', 0, 13) -eq 0) { $tok.Fixed = $true }
            $list.Add($tok)
            $i = $tokEnd
            continue
        }
        if ($i + 1 -lt $n -and $Text[$i + 1] -lt [char]128 -and [char]::IsLetter($Text[$i + 1])) {
            $j = $i + 1
            while ($j -lt $n -and -not [char]::IsWhiteSpace($Text[$j]) -and $Text[$j] -cne [char]62 -and $Text[$j] -cne [char]47) { $j++ }
            $name = $Text.Substring($i + 1, $j - $i - 1).ToLowerInvariant()
            $k = $j
            $closed = $false
            while ($k -lt $n) {
                $ch = $Text[$k]
                if ($ch -ceq [char]34 -or $ch -ceq [char]39) {
                    # a quote opens a value only right after '=' (whitespace allowed); otherwise it is an ordinary character
                    $pp = $k - 1
                    while ($pp -ge $j -and [char]::IsWhiteSpace($Text[$pp])) { $pp-- }
                    if ($pp -ge $j -and $Text[$pp] -ceq [char]61) {
                        $q = $Text.IndexOf($ch, $k + 1)
                        if ($q -lt 0) { break }
                        $k = $q + 1
                        continue
                    }
                }
                if ($ch -ceq [char]62) { $closed = $true; break }
                $k++
            }
            if (-not $closed) {
                throw (New-RcError -Code 3 -Line (Get-RcLineNumber -Text $Text -Pos $i) -Message "unclosed tag <$name")
            }
            $i = $k + 1
            if (@('script', 'style', 'textarea', 'title') -ccontains $name) {
                $p = $i
                $found = -1
                while ($true) {
                    $q = $Text.IndexOf("</$name", $p, [StringComparison]::OrdinalIgnoreCase)
                    if ($q -lt 0) { break }
                    $a = $q + 2 + $name.Length
                    if ($a -ge $n -or [char]::IsWhiteSpace($Text[$a]) -or $Text[$a] -ceq [char]62 -or $Text[$a] -ceq [char]47) { $found = $q; break }
                    $p = $a
                }
                if ($found -lt 0) {
                    throw (New-RcError -Code 3 -Line (Get-RcLineNumber -Text $Text -Pos ($i - 1)) -Message "unclosed <$name> element")
                }
                $i = $found
            }
            continue
        }
        if ($i + 1 -lt $n -and ($Text[$i + 1] -ceq [char]33 -or $Text[$i + 1] -ceq [char]63 -or $Text[$i + 1] -ceq [char]47)) {
            $q = $Text.IndexOf([char]62, $i)
            if ($q -lt 0) { break }
            $i = $q + 1
            continue
        }
        $i++
    }
    return , $list
}

# Shell (design 3.6). State is carried in a hashtable; nested contexts use recursion.
function Skip-RcShBacktick {
    param($St, [int]$I)
    $j = $I + 1
    $n = $St.N
    $set = [char[]]@([char]96, [char]92)
    while ($j -lt $n) {
        $j = $St.Text.IndexOfAny($set, $j)
        if ($j -lt 0) { break }
        if ($St.Text[$j] -ceq [char]92) { $j += 2; continue }
        return ($j + 1)
    }
    throw (New-RcError -Code 3 -Line (Get-RcLineNumber -Text $St.Text -Pos $I) -Message 'unclosed backquote')
}

function Skip-RcShDq {
    param($St, [int]$I, [bool]$NoHd)
    $text = $St.Text
    $n = $St.N
    $j = $I + 1
    $set = [char[]]@([char]34, [char]92, [char]36, [char]96)
    while ($j -lt $n) {
        $j = $text.IndexOfAny($set, $j)
        if ($j -lt 0) { break }
        $c = $text[$j]
        if ($c -ceq [char]34) { return ($j + 1) }
        if ($c -ceq [char]92) { $j += 2; continue }
        if ($c -ceq [char]96) { $j = Skip-RcShBacktick -St $St -I $j; continue }
        # '$'
        if ($j + 1 -lt $n -and $text[$j + 1] -ceq [char]40) {
            if ($j + 2 -lt $n -and $text[$j + 2] -ceq [char]40) { $j = Invoke-RcShCode -St $St -I ($j + 2) -Paren $true -NoHd $true -OpenPos $j }
            else { $j = Invoke-RcShCode -St $St -I ($j + 2) -Paren $true -NoHd $NoHd -OpenPos $j }
        }
        elseif ($j + 1 -lt $n -and $text[$j + 1] -ceq [char]123) { $j = Skip-RcShBrace -St $St -I $j -NoHd $NoHd }
        else { $j++ }
    }
    throw (New-RcError -Code 3 -Line (Get-RcLineNumber -Text $text -Pos $I) -Message 'unclosed double quote')
}

# I is the position of '$' in "${"
function Skip-RcShBrace {
    param($St, [int]$I, [bool]$NoHd)
    $text = $St.Text
    $n = $St.N
    $j = $I + 2
    $depth = 1
    $set = [char[]]@([char]123, [char]125, [char]39, [char]34, [char]92, [char]96)
    while ($j -lt $n) {
        $j = $text.IndexOfAny($set, $j)
        if ($j -lt 0) { break }
        $c = $text[$j]
        if ($c -ceq [char]123) { $depth++; $j++ }
        elseif ($c -ceq [char]125) { $depth--; $j++; if ($depth -eq 0) { return $j } }
        elseif ($c -ceq [char]92) { $j += 2 }
        elseif ($c -ceq [char]39) {
            $q = $text.IndexOf([char]39, $j + 1)
            if ($q -lt 0) { throw (New-RcError -Code 3 -Line (Get-RcLineNumber -Text $text -Pos $j) -Message 'unclosed single quote') }
            $j = $q + 1
        }
        elseif ($c -ceq [char]34) { $j = Skip-RcShDq -St $St -I $j -NoHd $NoHd }
        else { $j = Skip-RcShBacktick -St $St -I $j }
    }
    throw (New-RcError -Code 3 -Line (Get-RcLineNumber -Text $text -Pos $I) -Message 'unclosed ${')
}

# reads the bodies of the queued here-documents starting at line start $P; returns the position after them
function Skip-RcShHeredocs {
    param($St, [int]$P)
    $text = $St.Text
    $n = $St.N
    $entries = $St.Queue.ToArray()
    $St.Queue.Clear()
    foreach ($e in $entries) {
        $found = $false
        while ($P -lt $n) {
            $nl = $text.IndexOf([char]10, $P)
            if ($nl -lt 0) { $le = $n; $ce = $n }
            else {
                $le = $nl + 1
                if ($nl -gt $P -and $text[$nl - 1] -ceq [char]13) { $ce = $nl - 1 } else { $ce = $nl }
            }
            $line = $text.Substring($P, $ce - $P)
            if ($e.Strip) { $line = $line.TrimStart([char]9) }
            $P = $le
            if ([string]::Equals($line, $e.Delim, [StringComparison]::Ordinal)) { $found = $true; break }
        }
        if (-not $found) {
            throw (New-RcError -Code 3 -Line (Get-RcLineNumber -Text $text -Pos $e.Pos) -Message "unclosed here-document (delimiter '$($e.Delim)')")
        }
    }
    return $P
}

# true when the simple command that contains $Pos is a 'let' command (its arguments are arithmetic)
function Test-RcShLetArgs {
    param([string]$Text, [int]$Pos)
    $seps = [char[]]@([char]59, [char]38, [char]124, [char]10, [char]40, [char]96)
    $b = -1
    if ($Pos -gt 0) { $b = $Text.LastIndexOfAny($seps, $Pos - 1) }
    $seg = $Text.Substring($b + 1, $Pos - $b - 1).TrimStart()
    return [regex]::IsMatch($seg, '^let(?:\s|$)', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
}

# scans code from $I; with -Paren returns the position after the matching ')' (for "$(")
function Invoke-RcShCode {
    param($St, [int]$I, [bool]$Paren, [bool]$NoHd, [int]$OpenPos)
    $text = $St.Text
    $n = $St.N
    $depth = 0
    if ($Paren) { $set = $St.SpecialParen } else { $set = $St.SpecialTop }
    while ($I -lt $n) {
        $I = $text.IndexOfAny($set, $I)
        if ($I -lt 0) { $I = $n; break }
        $c = $text[$I]
        if ($c -ceq [char]35) {
            $wordStart = ($I -eq 0)
            if (-not $wordStart) {
                $pc = $text[$I - 1]
                $wordStart = ([char]::IsWhiteSpace($pc) -or ';&|()<>'.IndexOf($pc) -ge 0)
            }
            if (-not $wordStart) { $I++; continue }
            $nl = $text.IndexOf([char]10, $I)
            if ($nl -lt 0) { $ce = $n } elseif ($nl -gt $I -and $text[$nl - 1] -ceq [char]13) { $ce = $nl - 1 } else { $ce = $nl }
            $tok = New-RcToken -Start ($I + $St.Offset) -End ($ce + $St.Offset) -Kind 'line'
            if ($I -eq 0 -and $ce -ge 2 -and $text[1] -ceq [char]33) { $tok.Fixed = $true }
            $St.Tokens.Add($tok)
            $I = $ce
        }
        elseif ($c -ceq [char]10) {
            if ($St.Queue.Count -gt 0) { $I = Skip-RcShHeredocs -St $St -P ($I + 1) } else { $I++ }
        }
        elseif ($c -ceq [char]92) { $I += 2 }
        elseif ($c -ceq [char]39) {
            $q = $text.IndexOf([char]39, $I + 1)
            if ($q -lt 0) { throw (New-RcError -Code 3 -Line (Get-RcLineNumber -Text $text -Pos $I) -Message 'unclosed single quote') }
            $I = $q + 1
        }
        elseif ($c -ceq [char]34) { $I = Skip-RcShDq -St $St -I $I -NoHd $NoHd }
        elseif ($c -ceq [char]96) { $I = Skip-RcShBacktick -St $St -I $I }
        elseif ($c -ceq [char]36) {
            $nx = [char]0
            if ($I + 1 -lt $n) { $nx = $text[$I + 1] }
            if ($nx -ceq [char]40) {
                if ($I + 2 -lt $n -and $text[$I + 2] -ceq [char]40) { $I = Invoke-RcShCode -St $St -I ($I + 2) -Paren $true -NoHd $true -OpenPos $I }
                else { $I = Invoke-RcShCode -St $St -I ($I + 2) -Paren $true -NoHd $NoHd -OpenPos $I }
            }
            elseif ($nx -ceq [char]123) { $I = Skip-RcShBrace -St $St -I $I -NoHd $NoHd }
            elseif ($nx -ceq [char]39) {
                # $'...' : ANSI-C quoting, backslash escapes
                $j = $I + 2
                $set2 = [char[]]@([char]39, [char]92)
                $closed = $false
                while ($j -lt $n) {
                    $j = $text.IndexOfAny($set2, $j)
                    if ($j -lt 0) { break }
                    if ($text[$j] -ceq [char]92) { $j += 2; continue }
                    $closed = $true; break
                }
                if (-not $closed) { throw (New-RcError -Code 3 -Line (Get-RcLineNumber -Text $text -Pos $I) -Message 'unclosed $-quote') }
                $I = $j + 1
            }
            elseif ($nx -ceq [char]36) { $I += 2 }
            else { $I++ }
        }
        elseif ($c -ceq [char]60) {
            if ($NoHd -or $St.NoHeredoc -or $I + 1 -ge $n -or $text[$I + 1] -cne [char]60) { $I++; continue }
            if (Test-RcShLetArgs -Text $text -Pos $I) { $I += 2; continue }     # let x=1<<2 : arithmetic shift
            if ($I + 2 -lt $n -and $text[$I + 2] -ceq [char]60) { $I += 3; continue }     # here-string
            $j = $I + 2
            $strip = $false
            if ($j -lt $n -and $text[$j] -ceq [char]45) { $strip = $true; $j++ }
            while ($j -lt $n -and ($text[$j] -ceq [char]32 -or $text[$j] -ceq [char]9)) { $j++ }
            $delim = ''
            if ($j -lt $n) {
                $d = $text[$j]
                if ($d -ceq [char]39 -or $d -ceq [char]34) {
                    $q = $text.IndexOf($d, $j + 1)
                    if ($q -lt 0) { throw (New-RcError -Code 3 -Line (Get-RcLineNumber -Text $text -Pos $j) -Message 'unclosed quote in here-document delimiter') }
                    $delim = $text.Substring($j + 1, $q - $j - 1)
                    $j = $q + 1
                }
                else {
                    if ($d -ceq [char]92) { $j++ }
                    $k = $j
                    while ($k -lt $n -and -not [char]::IsWhiteSpace($text[$k]) -and ';&|()<>'.IndexOf($text[$k]) -lt 0) { $k++ }
                    $delim = $text.Substring($j, $k - $j)
                    $j = $k
                }
            }
            if ($delim.Length -gt 0) { $St.Queue.Add([pscustomobject]@{ Delim = $delim; Strip = $strip; Pos = $I }) }
            $I = [Math]::Max($j, $I + 2)
        }
        elseif ($c -ceq [char]40) {
            $wordStart = ($I -eq 0)
            if (-not $wordStart) {
                $pc = $text[$I - 1]
                $wordStart = ([char]::IsWhiteSpace($pc) -or ';&|('.IndexOf($pc) -ge 0)
            }
            if ($wordStart -and $I + 1 -lt $n -and $text[$I + 1] -ceq [char]40) {
                # (( ... )) arithmetic command: no here-documents inside
                $I = Invoke-RcShCode -St $St -I ($I + 1) -Paren $true -NoHd $true -OpenPos $I
            }
            else { $depth++; $I++ }
        }
        else {
            # ')'
            if ($depth -eq 0) { return ($I + 1) }
            $depth--; $I++
        }
    }
    if ($Paren) {
        throw (New-RcError -Code 3 -Line (Get-RcLineNumber -Text $text -Pos $OpenPos) -Message 'unclosed $(')
    }
    return $I
}

function Get-RcCommentsShell {
    param([string]$Text, [switch]$NoHeredoc, [int]$Offset = 0)
    $st = @{
        Text = $Text; N = $Text.Length; Offset = $Offset; NoHeredoc = [bool]$NoHeredoc
        Tokens = (New-Object 'System.Collections.Generic.List[object]')
        Queue = (New-Object 'System.Collections.Generic.List[object]')
        SpecialTop = [char[]]@([char]35, [char]92, [char]39, [char]34, [char]96, [char]36, [char]60, [char]10, [char]40)
        SpecialParen = [char[]]@([char]35, [char]92, [char]39, [char]34, [char]96, [char]36, [char]60, [char]10, [char]40, [char]41)
    }
    [void](Invoke-RcShCode -St $st -I 0 -Paren $false -NoHd $false -OpenPos 0)
    if ($st.Queue.Count -gt 0) {
        $e = $st.Queue[0]
        throw (New-RcError -Code 3 -Line (Get-RcLineNumber -Text $Text -Pos $e.Pos) -Message "unclosed here-document (delimiter '$($e.Delim)')")
    }
    return , $st.Tokens
}

# Makefile (design 3.7)
function Get-RcCommentsMakefile {
    param([string]$Text)
    $list = New-Object 'System.Collections.Generic.List[object]'
    $n = $Text.Length
    $cs = [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    $defineRe = '^\s*(?:(?:override|export)\s+)*define(?:\s|$)'
    $endefRe = '^\s*endef(?:\s|#|$)'
    $pos = 0
    $defDepth = 0
    $defStart = 0
    while ($pos -lt $n) {
        # one logical line: [pos, ce)
        $p = $pos
        while ($true) {
            $nl = $Text.IndexOf([char]10, $p)
            if ($nl -lt 0) { $ce = $n; $le = $n } else {
                $le = $nl + 1
                if ($nl -gt $p -and $Text[$nl - 1] -ceq [char]13) { $ce = $nl - 1 } else { $ce = $nl }
            }
            if ($nl -ge 0 -and $ce -gt $p -and $Text[$ce - 1] -ceq [char]92) { $p = $le; continue }
            break
        }
        $lineStart = $pos
        $line = $Text.Substring($lineStart, $ce - $lineStart)
        $pos = $le

        if ($defDepth -gt 0) {
            if ([regex]::IsMatch($line, $endefRe, $cs)) { $defDepth-- }
            elseif ([regex]::IsMatch($line, $defineRe, $cs)) { $defDepth++ }
            continue
        }
        if ($line.IndexOf('define', [StringComparison]::Ordinal) -ge 0 -and [regex]::IsMatch($line, $defineRe, $cs)) { $defDepth = 1; $defStart = $lineStart; continue }

        if ($line.Length -gt 0 -and $line[0] -ceq [char]9) {
            try { $sub = Get-RcCommentsShell -Text $line -NoHeredoc -Offset $lineStart }
            catch {
                $info = Convert-RcException -ErrorRecord $_
                if ($info.Code -eq 3 -and $info.Line -gt 0) {
                    throw (New-RcError -Code 3 -Line ((Get-RcLineNumber -Text $Text -Pos $lineStart) + $info.Line - 1) -Message $info.Message)
                }
                throw
            }
            foreach ($t in $sub) { $list.Add($t) }
            continue
        }
        $h = $line.IndexOf([char]35)
        while ($h -ge 0 -and $h -gt 0 -and $line[$h - 1] -ceq [char]92) { $h = $line.IndexOf([char]35, $h + 1) }
        if ($h -ge 0) { $list.Add((New-RcToken -Start ($lineStart + $h) -End $ce -Kind 'line')) }
    }
    if ($defDepth -gt 0) {
        throw (New-RcError -Code 3 -Line (Get-RcLineNumber -Text $Text -Pos $defStart) -Message 'define without endef')
    }
    return , $list
}

function Get-RcComments {
    param([string]$Language, [string]$Text)
    if ($Language -ceq 'conf') {
        $t = Get-RcCommentsConf -Text $Text
        return , $t
    }
    if (@('cpp', 'java', 'css') -ccontains $Language) {
        $t = Get-RcCommentsCLike -Text $Text -Flavor $Language
        return , $t
    }
    if ($Language -ceq 'typescript') {
        $t = Get-RcCommentsTypeScript -Text $Text
        return , $t
    }
    if ($Language -ceq 'html') {
        $t = Get-RcCommentsHtml -Text $Text
        return , $t
    }
    if ($Language -ceq 'shell') {
        $t = Get-RcCommentsShell -Text $Text
        return , $t
    }
    if ($Language -ceq 'makefile') {
        $t = Get-RcCommentsMakefile -Text $Text
        return , $t
    }
    throw (New-RcError -Code 1 -Message "unknown language: $Language")
}

# ---------------------------------------------------------------------------
# keep flags (design 4.1, 4.2)
# ---------------------------------------------------------------------------

# lines: Start / ContentEnd (before CR LF) / End (after newline); no phantom line after a final newline
function Get-RcLineTable {
    param([string]$Text)
    $ls = New-Object 'System.Collections.Generic.List[int]'
    $lc = New-Object 'System.Collections.Generic.List[int]'
    $le = New-Object 'System.Collections.Generic.List[int]'
    $n = $Text.Length
    $pos = 0
    while ($pos -lt $n) {
        $nl = $Text.IndexOf([char]10, $pos)
        if ($nl -lt 0) { $ce = $n; $end = $n }
        else {
            $end = $nl + 1
            if ($nl -gt $pos -and $Text[$nl - 1] -ceq [char]13) { $ce = $nl - 1 } else { $ce = $nl }
        }
        $ls.Add($pos); $lc.Add($ce); $le.Add($end)
        $pos = $end
    }
    return @{ Start = $ls.ToArray(); ContentEnd = $lc.ToArray(); End = $le.ToArray() }
}

function Get-RcLineIndex {
    param([int[]]$Starts, [int]$Pos)
    $idx = [Array]::BinarySearch($Starts, $Pos)
    if ($idx -lt 0) { $idx = (-bnot $idx) - 1 }
    if ($idx -lt 0) { $idx = 0 }
    return $idx
}

function Set-RcKeepFlags {
    param($Tokens, [string]$Text, $Settings, [string]$Language)
    $table = Get-RcLineTable -Text $Text
    $starts = $table.Start
    $ord = [StringComparison]::Ordinal

    # token -> first / last line index
    $firstLine = New-Object 'System.Collections.Generic.List[int]'
    $lastLine = New-Object 'System.Collections.Generic.List[int]'
    foreach ($t in $Tokens) {
        $firstLine.Add((Get-RcLineIndex -Starts $starts -Pos $t.Start))
        $lastLine.Add((Get-RcLineIndex -Starts $starts -Pos ([Math]::Max($t.Start, $t.End - 1))))
    }

    # 4.1 regions
    $ranges = New-Object 'System.Collections.Generic.List[int[]]'
    $open = $false
    $openLine = 0
    $k = 0
    foreach ($t in $Tokens) {
        $tt = $Text.Substring($t.Start, $t.End - $t.Start)
        $hasStart = $tt.IndexOf($Settings.RegionStart, $ord) -ge 0
        $hasEnd = $tt.IndexOf($Settings.RegionEnd, $ord) -ge 0
        if ($hasStart) {
            if ($open) {
                throw (New-RcError -Code 4 -Line ($firstLine[$k] + 1) -Message "keep region START inside a region opened at line $($openLine + 1)")
            }
            $open = $true
            $openLine = $firstLine[$k]
        }
        if ($hasEnd) {
            if (-not $open) {
                throw (New-RcError -Code 4 -Line ($firstLine[$k] + 1) -Message 'keep region END without START')
            }
            $open = $false
            $ranges.Add([int[]]@($openLine, $lastLine[$k]))
        }
        $k++
    }
    if ($open) {
        throw (New-RcError -Code 4 -Line ($openLine + 1) -Message 'keep region START has no END')
    }

    # 4.2 patterns
    $pats = New-Object 'System.Collections.Generic.List[string]'
    foreach ($p in $Settings.KeepPatterns) { $pats.Add($p) }
    if ($Language -and $Settings.LangKeepPatterns.ContainsKey($Language)) {
        foreach ($p in $Settings.LangKeepPatterns[$Language]) { $pats.Add($p) }
    }
    if ($Settings.CaseSensitive) { $cmp = [StringComparison]::Ordinal } else { $cmp = [StringComparison]::OrdinalIgnoreCase }

    $k = 0
    foreach ($t in $Tokens) {
        $keep = [bool]$t.Fixed
        if (-not $keep) {
            foreach ($r in $ranges) {
                if ($firstLine[$k] -le $r[1] -and $lastLine[$k] -ge $r[0]) { $keep = $true; break }
            }
        }
        if (-not $keep -and ($pats.Count -gt 0 -or $Settings.KeepRegex.Count -gt 0)) {
            $tt = $Text.Substring($t.Start, $t.End - $t.Start)
            foreach ($p in $pats) {
                if ($tt.IndexOf($p, $cmp) -ge 0) { $keep = $true; break }
            }
            if (-not $keep -and $Settings.KeepRegex.Count -gt 0) {
                if ($tt.IndexOf([char]10) -ge 0) { $lines = [regex]::Split($tt, '\r?\n') } else { $lines = @($tt) }
                :lineLoop foreach ($line in $lines) {
                    foreach ($rx in $Settings.KeepRegex) {
                        if ($rx.IsMatch($line)) { $keep = $true; break lineLoop }
                    }
                }
            }
        }
        $t.Keep = $keep
        $k++
    }
}

# ---------------------------------------------------------------------------
# rewrite (design 4.3)
# ---------------------------------------------------------------------------

function Convert-RcText {
    param([string]$Text, $Tokens, [bool]$JoinWithSpace = $true)
    $table = Get-RcLineTable -Text $Text
    $starts = $table.Start
    $cends = $table.ContentEnd
    $ends = $table.End
    $count = $starts.Length

    # per-line deletion ranges
    $perLine = @{}
    foreach ($t in $Tokens) {
        if ($t.Keep) { continue }
        $l1 = Get-RcLineIndex -Starts $starts -Pos $t.Start
        $l2 = Get-RcLineIndex -Starts $starts -Pos ([Math]::Max($t.Start, $t.End - 1))
        for ($l = $l1; $l -le $l2; $l++) {
            $a = [Math]::Max($t.Start, $starts[$l])
            $b = [Math]::Min($t.End, $cends[$l])
            if ($b -lt $a) { $b = $a }
            if (-not $perLine.ContainsKey($l)) { $perLine[$l] = New-Object 'System.Collections.Generic.List[int[]]' }
            $perLine[$l].Add([int[]]@($a, $b))
        }
    }

    $sb = New-Object System.Text.StringBuilder
    $lastDeleted = $false
    $prevBs = $false      # last output line ends with a backslash (line continuation)
    for ($l = 0; $l -lt $count; $l++) {
        $s = $starts[$l]; $ce = $cends[$l]; $e = $ends[$l]
        if (-not $perLine.ContainsKey($l)) {
            [void]$sb.Append($Text, $s, $e - $s)
            $prevBs = ($ce -gt $s -and $Text[$ce - 1] -ceq [char]92)
            continue
        }
        # merge touching ranges
        $merged = New-Object 'System.Collections.Generic.List[int[]]'
        foreach ($r in $perLine[$l]) {
            if ($merged.Count -gt 0 -and $r[0] -le $merged[$merged.Count - 1][1]) {
                if ($r[1] -gt $merged[$merged.Count - 1][1]) { $merged[$merged.Count - 1][1] = $r[1] }
            }
            else { $merged.Add([int[]]@($r[0], $r[1])) }
        }
        $line = New-Object System.Text.StringBuilder
        $pos = $s
        foreach ($r in $merged) {
            [void]$line.Append($Text, $pos, $r[0] - $pos)
            if ($r[1] -gt $r[0] -and $r[1] -ge $ce) {
                # spec 5 rule 6: trim only the whitespace right before a deletion that runs to the line's content end
                $before = $line.ToString()
                $tr = $before.TrimEnd([char[]]@([char]32, [char]9))
                # rule 8: do not trim if that would leave a trailing backslash
                if (-not ($tr.Length -gt 0 -and $tr[$tr.Length - 1] -ceq [char]92)) {
                    [void]$line.Remove($tr.Length, $before.Length - $tr.Length)
                }
            }
            if ($JoinWithSpace -and $r[0] -gt $s -and $r[1] -lt $ce -and
                -not [char]::IsWhiteSpace($Text[$r[0] - 1]) -and -not [char]::IsWhiteSpace($Text[$r[1]])) {
                [void]$line.Append([char]32)
            }
            $pos = $r[1]
        }
        [void]$line.Append($Text, $pos, $ce - $pos)
        $content = $line.ToString()
        if ([string]::IsNullOrWhiteSpace($content)) {
            if ($prevBs) {
                # rule 7: keep an empty line so that a continuation does not join the next code line
                if ($e -gt $ce) { [void]$sb.Append($Text, $ce, $e - $ce) }
                $prevBs = $false
                if ($e -eq $ce) { $lastDeleted = $true }
                continue
            }
            if ($l -eq $count - 1 -and $e -eq $ce) { $lastDeleted = $true }
            continue
        }
        [void]$sb.Append($content)
        [void]$sb.Append($Text, $ce, $e - $ce)
        $prevBs = ($content.Length -gt 0 -and $content[$content.Length - 1] -ceq [char]92)
    }

    $out = $sb.ToString()
    if ($lastDeleted -and $out.Length -gt 0 -and $out[$out.Length - 1] -ceq [char]10) {
        $cut = 1
        if ($out.Length -ge 2 -and $out[$out.Length - 2] -ceq [char]13) { $cut = 2 }
        $out = $out.Substring(0, $out.Length - $cut)
    }
    return $out
}

# ---------------------------------------------------------------------------
# one file (design 2.5)
# ---------------------------------------------------------------------------

function Invoke-RcFile {
    param($Settings, [string]$Path, [string]$OutPath, [switch]$DryRun, [string]$DisplayPath)
    Set-StrictMode -Version 2.0
    $ErrorActionPreference = 'Stop'
    if (-not $DisplayPath) { $DisplayPath = $Path }
    try {
        if (-not $Path) { throw (New-RcError -Code 9 -Message 'path is required') }
        $full = Resolve-RcPath -PathText $Path
        $lang = Get-RcLanguage -Settings $Settings -FilePath $full
        if (-not $lang) {
            return (New-RcResult -ExitCode 2 -Status 'UNSUPPORTED' -Display $DisplayPath)
        }

        $dest = $null
        $inPlace = $false
        if ($OutPath) { $dest = Resolve-RcPath -PathText $OutPath }
        elseif ($Settings.OutputMode -eq 'inPlace') { $dest = $full; $inPlace = $true }
        elseif (-not $DryRun) {
            throw (New-RcError -Code 9 -Message "no output destination: give -OutPath or set output.mode to 'inPlace'")
        }

        $file = Read-RcTextFile -Path $full -EncodingMode $Settings.EncodingMode
        $text = $file.Text
        $tokens = Get-RcComments -Language $lang -Text $text
        Set-RcKeepFlags -Tokens $tokens -Text $text -Settings $Settings -Language $lang
        $removed = 0; $kept = 0
        foreach ($t in $tokens) { if ($t.Keep) { $kept++ } else { $removed++ } }
        $newText = Convert-RcText -Text $text -Tokens $tokens -JoinWithSpace ($lang -cne 'html')

        if (-not $DryRun) {
            $write = $true
            if ($inPlace -and [string]::Equals($newText, $text, [StringComparison]::Ordinal)) { $write = $false }
            if ($write) {
                if ($inPlace -and $Settings.Backup) {
                    try { [IO.File]::Copy($full, "$full.bak", $true) }
                    catch { throw (New-RcError -Code 5 -Message "cannot create backup: $($_.Exception.Message)") }
                }
                Write-RcTextFile -Path $dest -Text $newText -Encoding $file.Encoding -Bom $file.Bom
            }
        }
        return (New-RcResult -ExitCode 0 -Status 'OK' -Display $DisplayPath -Removed $removed -Kept $kept)
    }
    catch {
        $info = Convert-RcException -ErrorRecord $_
        return (New-RcResult -ExitCode $info.Code -Status 'ERROR' -Display $DisplayPath -Message (Format-RcMessage -Display $DisplayPath -Info $info))
    }
}

function Invoke-RcMain {
    param([string]$Path, [string]$Config, [string]$OutPath, [switch]$DryRun)
    Set-StrictMode -Version 2.0
    $ErrorActionPreference = 'Stop'
    try {
        if (-not $Path) {
            throw (New-RcError -Code 9 -Message 'usage: Remove-Comments.ps1 -Path <file> [-Config <json>] [-OutPath <file>] [-DryRun]')
        }
        $settings = Read-RcSettings -ConfigPath $Config
    }
    catch {
        $info = Convert-RcException -ErrorRecord $_
        return (New-RcResult -ExitCode $info.Code -Status 'ERROR' -Display $Path -Message $info.Message)
    }
    return (Invoke-RcFile -Settings $settings -Path $Path -OutPath $OutPath -DryRun:$DryRun -DisplayPath $Path)
}

if ($MyInvocation.InvocationName -eq '.') { return }

$rcResult = Invoke-RcMain -Path $Path -Config $Config -OutPath $OutPath -DryRun:$DryRun
[Console]::Out.WriteLine($rcResult.Line)
if ($rcResult.Message) { [Console]::Error.WriteLine($rcResult.Message) }
exit $rcResult.ExitCode
