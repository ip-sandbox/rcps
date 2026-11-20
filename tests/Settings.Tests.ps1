# Read-RcSettings / Get-RcLanguage

function Assert-ConfigError {
    param([string]$Label, [string]$Json)
    $d = New-TestDir
    $p = New-TestConfig -Dir $d -Json $Json
    $err = $null
    try { Read-RcSettings -ConfigPath $p -ScriptDir $d | Out-Null } catch { $err = Convert-RcException -ErrorRecord $_ }
    if ($null -eq $err) { throw "[$Label] expected error 9 but config was accepted: $Json" }
    if ($err.Code -ne 9) { throw "[$Label] expected 9 but got $($err.Code): $($err.Message)" }
}

Test-Case 'settings: defaults (empty object)' {
    $s = New-TestSettings '{}'
    Assert-Equal $s.OutputMode $null
    Assert-Equal $s.OutDir $null
    Assert-Equal $s.Backup $false
    Assert-Equal $s.EncodingMode 'auto'
    Assert-Equal $s.KeepPatterns.Count 0
    Assert-Equal $s.KeepRegex.Count 0
    Assert-Equal $s.CaseSensitive $true
    Assert-Equal $s.RegionStart '% DEL START'
    Assert-Equal $s.RegionEnd '% DEL END'
    Assert-Equal $s.BatchRoot $null
    Assert-Equal $s.Exclude.Count 0
    Assert-Equal $s.LogPath $null
    Assert-Equal $s.ExtMap['.cpp'] 'cpp'
    Assert-Equal $s.ExtMap['.hh'] 'cpp'
    Assert-Equal $s.ExtMap['.java'] 'java'
    Assert-Equal $s.ExtMap['.ts'] 'typescript'
    Assert-Equal $s.ExtMap['.css'] 'css'
    Assert-Equal $s.ExtMap['.html'] 'html'
    Assert-True (-not $s.ExtMap.ContainsKey('.htm')) '.htm is not a default'
    Assert-Equal $s.ExtMap['.sh'] 'shell'
    Assert-Equal $s.ExtMap['.mk'] 'makefile'
    Assert-Equal $s.ExtMap['.conf'] 'conf'
    Assert-Equal $s.NameMap['makefile'] 'makefile'
    Assert-Equal $s.NameMap['gnumakefile'] 'makefile'
    Assert-Equal $s.LangKeepPatterns.Count 8
}
Test-Case 'settings: spec example is valid; sample config in src/ is valid' {
    $s = Read-RcSettings -ConfigPath (Join-Path $global:RcTestState.Root 'src/remove-comments.json')
    Assert-Equal $s.OutputMode 'outDir'
    Assert-Equal $s.ExtMap['.htm'] 'html'
    Assert-Equal $s.KeepRegex.Count 2
    Assert-True ($s.Exclude -contains 'third_party/**') 'exclude'
    Assert-True ($s.Exclude -contains 'src/lib/zlib*.c') 'excludeFiles merged'
    Assert-True ($s.LangKeepPatterns['java'] -contains '@formatter:') 'language keepPatterns'
}
Test-Case 'settings: full valid config round trip' {
    $s = New-TestSettings '{"version":1,"output":{"mode":"inPlace","backup":true},"encoding":"sjis","keep":{"patterns":["a"],"regex":["b+"],"caseSensitive":false},"keepRegion":{"start":"S","end":"E"},"log":{"path":"l.csv"}}'
    Assert-Equal $s.OutputMode 'inPlace'
    Assert-Equal $s.Backup $true
    Assert-Equal $s.EncodingMode 'sjis'
    Assert-Equal $s.CaseSensitive $false
    Assert-Equal $s.RegionStart 'S'
    Assert-True ($s.KeepRegex[0].IsMatch('BB')) 'regex IgnoreCase'
    Assert-Equal $s.KeepRegex[0].MatchTimeout ([TimeSpan]::FromSeconds(1))
}
Test-Case 'settings: underscore keys are ignored at any level' {
    $s = New-TestSettings '{"_c":1,"output":{"_x":[1],"mode":"inPlace"},"keep":{"_y":{}},"languages":{"_z":1,"cpp":{"_w":2,"extensions":[".c"]}},"keepRegion":{"_q":null}}'
    Assert-Equal $s.OutputMode 'inPlace'
    Assert-Equal $s.ExtMap['.c'] 'cpp'
}
Test-Case 'settings: errors are exit code 9' {
    Assert-ConfigError 'invalid json' '{ "version": '
    Assert-ConfigError 'empty file' ''
    Assert-ConfigError 'top-level array' '[]'
    Assert-ConfigError 'top-level array with object' '[{"version":1}]'
    Assert-ConfigError 'top-level number' '1'
    Assert-ConfigError 'top-level null' 'null'
    Assert-ConfigError 'unknown top key' '{"verison":1}'
    Assert-ConfigError 'key case mismatch' '{"Version":1}'
    Assert-ConfigError 'version 2' '{"version":2}'
    Assert-ConfigError 'version string' '{"version":"1"}'
    Assert-ConfigError 'version float' '{"version":1.5}'
    Assert-ConfigError 'version null' '{"version":null}'
    Assert-ConfigError 'output not object' '{"output":"x"}'
    Assert-ConfigError 'output null' '{"output":null}'
    Assert-ConfigError 'output unknown key' '{"output":{"modee":"inPlace"}}'
    Assert-ConfigError 'output.mode bad' '{"output":{"mode":"both"}}'
    Assert-ConfigError 'output.mode case' '{"output":{"mode":"inplace"}}'
    Assert-ConfigError 'output.mode number' '{"output":{"mode":1}}'
    Assert-ConfigError 'output.outDir number' '{"output":{"outDir":1}}'
    Assert-ConfigError 'output.outDir empty' '{"output":{"outDir":""}}'
    Assert-ConfigError 'output.backup string' '{"output":{"backup":"true"}}'
    Assert-ConfigError 'encoding bad' '{"encoding":"latin1"}'
    Assert-ConfigError 'encoding null' '{"encoding":null}'
    Assert-ConfigError 'keep not object' '{"keep":[]}'
    Assert-ConfigError 'keep unknown key' '{"keep":{"pattern":[]}}'
    Assert-ConfigError 'keep.patterns string' '{"keep":{"patterns":"x"}}'
    Assert-ConfigError 'keep.patterns number element' '{"keep":{"patterns":["a",1]}}'
    Assert-ConfigError 'keep.patterns empty string' '{"keep":{"patterns":[""]}}'
    Assert-ConfigError 'keep.regex invalid' '{"keep":{"regex":["("]}}'
    Assert-ConfigError 'keep.regex not array' '{"keep":{"regex":"a"}}'
    Assert-ConfigError 'keep.caseSensitive string' '{"keep":{"caseSensitive":"yes"}}'
    Assert-ConfigError 'keepRegion unknown key' '{"keepRegion":{"begin":"x"}}'
    Assert-ConfigError 'keepRegion.start number' '{"keepRegion":{"start":1}}'
    Assert-ConfigError 'keepRegion.end empty' '{"keepRegion":{"end":""}}'
    Assert-ConfigError 'keepRegion start == end' '{"keepRegion":{"start":"X","end":"X"}}'
    Assert-ConfigError 'unknown language' '{"languages":{"python":{"extensions":[".py"]}}}'
    Assert-ConfigError 'language key case' '{"languages":{"Cpp":{"extensions":[".c"]}}}'
    Assert-ConfigError 'language not object' '{"languages":{"cpp":[".c"]}}'
    Assert-ConfigError 'language unknown key' '{"languages":{"cpp":{"extension":[".c"]}}}'
    Assert-ConfigError 'extension without dot' '{"languages":{"cpp":{"extensions":["c"]}}}'
    Assert-ConfigError 'extension only dot' '{"languages":{"cpp":{"extensions":["."]}}}'
    Assert-ConfigError 'extensions not array' '{"languages":{"cpp":{"extensions":".c"}}}'
    Assert-ConfigError 'fileNames with path' '{"languages":{"makefile":{"fileNames":["a/Makefile"]}}}'
    Assert-ConfigError 'language keepPatterns number' '{"languages":{"cpp":{"keepPatterns":[1]}}}'
    Assert-ConfigError 'duplicate extension' '{"languages":{"cpp":{"extensions":[".h"]},"css":{"extensions":[".h"]}}}'
    Assert-ConfigError 'duplicate extension (case)' '{"languages":{"cpp":{"extensions":[".H"]},"css":{"extensions":[".h"]}}}'
    Assert-ConfigError 'duplicate extension vs default' '{"languages":{"css":{"extensions":[".css",".java"]}}}'
    Assert-ConfigError 'duplicate fileName' '{"languages":{"conf":{"fileNames":["Makefile"]}}}'
    Assert-ConfigError 'duplicate fileName (case)' '{"languages":{"conf":{"fileNames":["MAKEFILE"]}}}'
    Assert-ConfigError 'batch unknown key' '{"batch":{"dir":"x"}}'
    Assert-ConfigError 'batch.root number' '{"batch":{"root":5}}'
    Assert-ConfigError 'exclude not array' '{"exclude":"a"}'
    Assert-ConfigError 'exclude number' '{"exclude":[1]}'
    Assert-ConfigError 'excludeFiles missing file' '{"excludeFiles":["does-not-exist.txt"]}'
    Assert-ConfigError 'excludeFiles not array' '{"excludeFiles":"a.txt"}'
    Assert-ConfigError 'log unknown key' '{"log":{"file":"x"}}'
    Assert-ConfigError 'log.path number' '{"log":{"path":1}}'
}
Test-Case 'settings: missing -Config file is 9' {
    $d = New-TestDir
    Assert-RcErrorCode 9 { Read-RcSettings -ConfigPath (Join-Path $d 'nope.json') -ScriptDir $d }
}
Test-Case 'settings: no config anywhere -> built-in defaults' {
    $d = New-TestDir
    $old = (Get-Location).ProviderPath
    try {
        Set-Location -LiteralPath $d
        $s = Read-RcSettings -ConfigPath $null -ScriptDir $d
    }
    finally { Set-Location -LiteralPath $old }
    Assert-Equal $s.ConfigPath $null
    Assert-Equal $s.OutputMode $null
    Assert-Equal $s.ExtMap['.cpp'] 'cpp'
}
Test-Case 'settings: search order -Config > cwd > script dir' {
    $cwdDir = New-TestDir; $scriptDir = New-TestDir; $other = New-TestDir
    [void](New-TestConfig -Dir $cwdDir -Name 'remove-comments.json' -Json '{"encoding":"utf8"}')
    [void](New-TestConfig -Dir $scriptDir -Name 'remove-comments.json' -Json '{"encoding":"sjis"}')
    $explicit = New-TestConfig -Dir $other -Name 'x.json' -Json '{"encoding":"auto","keep":{"patterns":["E"]}}'
    $old = (Get-Location).ProviderPath
    try {
        Set-Location -LiteralPath $cwdDir
        $a = Read-RcSettings -ConfigPath $explicit -ScriptDir $scriptDir
        $b = Read-RcSettings -ConfigPath $null -ScriptDir $scriptDir
        Remove-Item -LiteralPath (Join-Path $cwdDir 'remove-comments.json')
        $c = Read-RcSettings -ConfigPath $null -ScriptDir $scriptDir
    }
    finally { Set-Location -LiteralPath $old }
    Assert-Equal $a.KeepPatterns[0] 'E' 'explicit wins'
    Assert-Equal $b.EncodingMode 'utf8' 'cwd wins over script dir'
    Assert-Equal $c.EncodingMode 'sjis' 'script dir last'
}
Test-Case 'settings: relative paths resolve against the config directory' {
    $d = New-TestDir
    $sub = Join-Path $d 'conf'
    [void][IO.Directory]::CreateDirectory($sub)
    [IO.File]::WriteAllBytes((Join-Path $sub 'list.txt'), (Get-TestUtf8 "# comment`n`nthird/**`n  vendor/*.c  `n"))
    $abs = Join-Path $d 'abs-out'
    $json = '{"output":{"outDir":"../out"},"batch":{"root":"src"},"log":{"path":"logs/l.csv"},"exclude":["a/**"],"excludeFiles":["list.txt"]}'
    $p = New-TestConfig -Dir $sub -Json $json
    $s = Read-RcSettings -ConfigPath $p -ScriptDir $d
    Assert-Equal $s.ConfigDir $sub
    Assert-Equal $s.OutDir ([IO.Path]::GetFullPath((Join-Path $sub '../out')))
    Assert-Equal $s.BatchRoot (Join-Path $sub 'src')
    Assert-Equal $s.LogPath (Join-Path (Join-Path $sub 'logs') 'l.csv')
    Assert-Equal $s.Exclude @('a/**', 'third/**', 'vendor/*.c') 'exclude + excludeFiles merged, comments/blank skipped'
    $p2 = New-TestConfig -Dir $sub -Name 'abs.json' -Json ('{"output":{"outDir":' + (ConvertTo-Json $abs) + '}}')
    Assert-Equal (Read-RcSettings -ConfigPath $p2 -ScriptDir $d).OutDir $abs 'absolute path kept'
}
Test-Case 'settings: BOM in config is accepted' {
    $d = New-TestDir
    $bytes = Join-TestBytes ([byte[]](0xEF, 0xBB, 0xBF)) (Get-TestUtf8 '{"encoding":"utf8"}')
    $p = Join-Path $d 'bom.json'
    [IO.File]::WriteAllBytes($p, $bytes)
    Assert-Equal (Read-RcSettings -ConfigPath $p -ScriptDir $d).EncodingMode 'utf8'
}
Test-Case 'settings: language entries replace only their own keys' {
    $s = New-TestSettings '{"languages":{"cpp":{"extensions":[".x",".Y"]},"html":{"extensions":[]},"makefile":{"fileNames":["Mk"]},"java":{"keepPatterns":["k"]}}}'
    Assert-Equal (Get-RcLanguage $s 'a.x') 'cpp'
    Assert-Equal (Get-RcLanguage $s 'a.y') 'cpp' 'extension is case-insensitive'
    Assert-Equal (Get-RcLanguage $s 'a.cpp') $null 'replaced'
    Assert-Equal (Get-RcLanguage $s 'a.html') $null 'disabled by empty extensions'
    Assert-Equal (Get-RcLanguage $s 'a.java') 'java' 'other keys of java untouched'
    Assert-Equal $s.LangKeepPatterns['java'][0] 'k'
    Assert-Equal (Get-RcLanguage $s 'Mk') 'makefile'
    Assert-Equal (Get-RcLanguage $s 'Makefile') $null 'fileNames replaced'
    Assert-Equal (Get-RcLanguage $s 'a.mk') 'makefile' 'extensions of makefile untouched'
    Assert-Equal (Get-RcLanguage $s 'a.conf') 'conf'
}
Test-Case 'language: detection by name and extension' {
    $s = New-TestSettings '{}'
    Assert-Equal (Get-RcLanguage $s 'dir/Makefile') 'makefile'
    Assert-Equal (Get-RcLanguage $s 'MAKEFILE') 'makefile'
    Assert-Equal (Get-RcLanguage $s 'GNUmakefile') 'makefile'
    Assert-Equal (Get-RcLanguage $s 'x/A.CPP') 'cpp'
    Assert-Equal (Get-RcLanguage $s 'a.b.sh') 'shell'
    Assert-Equal (Get-RcLanguage $s 'README.md') $null
    Assert-Equal (Get-RcLanguage $s 'noext') $null
    Assert-Equal (Get-RcLanguage $s 'a.htm') $null
    Assert-Equal (Get-RcLanguage $s 'a.conf') 'conf'
}
Test-Case 'language: file name match wins over extension' {
    $s = New-TestSettings '{"languages":{"conf":{"fileNames":["special.sh"]}}}'
    Assert-Equal (Get-RcLanguage $s 'special.sh') 'conf'
    Assert-Equal (Get-RcLanguage $s 'SPECIAL.SH') 'conf'
    Assert-Equal (Get-RcLanguage $s 'other.sh') 'shell'
}
Test-Case 'language: multi-dot extensions, longest suffix first' {
    $s = New-TestSettings '{"languages":{"typescript":{"extensions":[".ts",".d.ts"]},"css":{"extensions":[".css"]}}}'
    Assert-Equal (Get-RcLanguage $s 'a.d.ts') 'typescript'
}
Test-Case 'settings: regex compile options and 1s timeout setting' {
    $s = New-TestSettings '{"keep":{"regex":["Abc"]}}'
    Assert-True (-not $s.KeepRegex[0].IsMatch('abc')) 'case-sensitive by default'
    $s2 = New-TestSettings '{"keep":{"regex":["Abc"],"caseSensitive":false}}'
    Assert-True ($s2.KeepRegex[0].IsMatch('abc')) 'IgnoreCase'
}
Test-Case 'settings: regex timeout -> exit code 6, nothing written' {
    $d = New-TestDir
    $cfg = New-TestConfig -Dir $d -Json '{"keep":{"regex":["^#\\s*(a+)+$"]}}'
    $s = Read-RcSettings -ConfigPath $cfg -ScriptDir $d
    $in = Join-Path $d 'in.conf'
    [IO.File]::WriteAllBytes($in, (Get-TestUtf8 ("k=1`n# " + ('a' * 30) + "!`n")))
    $out = Join-Path $d 'out.conf'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-RcFile -Settings $s -Path $in -OutPath $out -DisplayPath 'in.conf'
    $sw.Stop()
    Assert-Equal $r.ExitCode 6
    Assert-Equal $r.Status 'ERROR'
    Assert-Equal $r.Line "ERROR`tin.conf`tcode=6"
    Assert-True (-not (Test-Path -LiteralPath $out)) 'no output'
    Assert-True ($sw.Elapsed.TotalSeconds -lt 10) 'times out quickly'
}
