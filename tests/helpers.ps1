# Shared by the test files. In BeforeAll:  . (Join-Path $PSScriptRoot 'helpers.ps1'); Initialize-WslbinTest
# State lives in $global:WslbinTest because the functions are called from several scopes.

function Initialize-WslbinTest {
    $repo = Split-Path -Parent $PSScriptRoot
    $work = Join-Path ([IO.Path]::GetTempPath()) ('wslbin-tests-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    $exe = Join-Path $work 'wslbin.exe'
    & (Join-Path $repo 'build.ps1') -Output $exe 6>$null
    if (-not (Test-Path $exe)) { throw 'build.ps1 did not produce wslbin.exe' }
    $global:WslbinTest = @{ Repo = $repo; Work = $work; Exe = $exe }
}

function Remove-WslbinTest {
    if ($global:WslbinTest) { Remove-Item -Recurse -Force $global:WslbinTest.Work -ErrorAction SilentlyContinue }
}

# Runs a copy of wslbin.exe named "$Name.exe" (the utility), with its own wslbin.ini if $Ini is given.
# Without -Dir every call gets a folder of its own; with -Dir the folder is reused (and the copy is
# made only when it is missing). Returns stdout, stderr (both UTF-8), the exit code and the folder.
function Invoke-Wslbin {
    param(
        [string]$Name = 'tool',
        [string[]]$Arguments = @(),
        [string]$Ini,
        [hashtable]$Env = @{},
        [string]$InputText,
        [string]$WorkingDirectory,
        [string]$Dir,
        [switch]$IniWithBom
    )
    if (-not $Dir) {
        $Dir = Join-Path $global:WslbinTest.Work ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $Dir | Out-Null
    }
    $exe = Join-Path $Dir "$Name.exe"
    if (-not (Test-Path $exe)) { Copy-Item $global:WslbinTest.Exe $exe }
    if ($PSBoundParameters.ContainsKey('Ini')) {
        [IO.File]::WriteAllText((Join-Path $Dir 'wslbin.ini'), $Ini, [Text.UTF8Encoding]::new([bool]$IniWithBom))
    }

    $psi = [Diagnostics.ProcessStartInfo]::new($exe)
    foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
    $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    $null = $psi.Environment.Remove('WSLENV')
    foreach ($key in $Env.Keys) {
        if ($null -eq $Env[$key]) { $null = $psi.Environment.Remove($key) } else { $psi.Environment[$key] = $Env[$key] }
    }

    $p = [Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if ($null -ne $InputText) { $p.StandardInput.Write($InputText) }
    $p.StandardInput.Close()
    $p.WaitForExit()
    [pscustomobject]@{
        Out      = $outTask.GetAwaiter().GetResult()
        Err      = $errTask.GetAwaiter().GetResult()
        ExitCode = $p.ExitCode
        Dir      = $Dir
    }
}

# The bash command that --wslbin-explain prints, without the final newline.
function Get-Explain {
    param([string[]]$Arguments = @(), [string]$Name = 'tool', [string]$Ini, [string[]]$Flags = @())
    $splat = @{ Name = $Name; Arguments = (@('--wslbin-explain') + $Flags + $Arguments) }
    if ($PSBoundParameters.ContainsKey('Ini')) { $splat.Ini = $Ini }
    (Invoke-Wslbin @splat).Out.TrimEnd("`n")
}

# A directory on the Windows side with a few files, for tests of wildcards and paths.
function New-FileDir {
    param([string[]]$Files)
    $dir = Join-Path $global:WslbinTest.Work ('files-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    foreach ($f in $Files) { [IO.File]::WriteAllText((Join-Path $dir $f), "$f`n") }
    $dir
}

# Arguments that each must arrive as exactly one argument, as typed. A function and not a variable of
# BeforeDiscovery: such a variable is $null inside It, and "$null | ForEach-Object" makes one empty
# item, so a test that compared the two used to pass while it checked nothing.
function Get-NastyArguments {
    $ruSpaced = -join ([char[]](0x0444, 0x20, 0x0430, 0x0439, 0x043B))   # "ф айл"
    @(
        'plain', 'a b', 'x;echo pwned', '$(id)', '$HOME', '`uname`', '{print $1, $2}', "it's", 'say "hi"',
        'back\slash', 'trail\', 'two\\', '\"', 'a|b&c', 'a>b<c', '#hash', '!bang', '~tilde-mid', 'a~b',
        $ruSpaced, '', ' ', "tab`there", "line1`nline2", '%PATH%', '^caret', '(paren)', '{a,b}',
        '[bracket', 'br]acket', '--opt=value with spaces',
        '[[:$(id):]]', '[[=`id`=]]', '[[.;.]]', 'a[[:x;y:]]b'
    )
}

# Random arguments made of the characters that hurt (shell syntax, wildcards, quotes, brackets,
# non-ASCII), each of which must reach the utility exactly as typed. Left out, because wslbin changes
# them by design: a leading ~ (bash expands it), $ or ` in sh mode (substituted), a wildcard in a path
# with a slash (it matches real files), a Windows drive path (translated) and a relative path made of
# dots and backslashes (it exists in any folder, so it is translated).
function New-HostileArguments {
    param([System.Random]$Random, [int]$Count, [ValidateSet('smart', 'sh', 'raw')][string]$Mode)
    # the marks of [:class:], [=e=] and [.s.] are pieces of their own, so that such shapes turn up
    $alphabet = @(' ', ' ', 'a', 'b', 'x', '1', '[', ']', '[', '*', '?', '!', '^', '-', '\', '\', '"', "'", '$', '(', ')', '{', '}', ';', '|', '&',
                  '<', '>', '~', '`', '#', '%', '=', ',', ':', '@', '/', '.', "`t", "`n", [string][char]0x44F, [string][char]0x65E5,
                  '[[:', ':]]', '[[=', '=]]', '[[.', '.]]', '$(', 'alpha')
    $list = New-Object System.Collections.Generic.List[string]
    while ($list.Count -lt $Count) {
        $s = -join (1..$Random.Next(1, 13) | ForEach-Object { $alphabet[$Random.Next(0, $alphabet.Count)] })
        if ($s -match '[*?\[]' -and $s.Contains('/')) { continue }
        if ($s -match '[A-Za-z]:[\\/]' -or $s -match '\.\\|\\\.') { continue }
        if ($Mode -ne 'raw' -and $s.StartsWith('~')) { continue }
        if ($Mode -eq 'sh' -and ($s.Contains('$') -or $s.Contains('`'))) { continue }
        $list.Add($s)
    }
    $list.ToArray()
}

# bash.exe of Git for Windows, or $null when it is not installed (GitHub's Windows runners have it).
function Get-GitBash {
    foreach ($candidate in @("$env:ProgramFiles\Git\bin\bash.exe", "${env:ProgramFiles(x86)}\Git\bin\bash.exe")) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    $null
}

# Runs a bash script, given on standard input as UTF-8, in Git Bash in the given folder; returns
# stdout, stderr and the exit code.
function Invoke-GitBash {
    param([string]$Script, [string]$WorkingDirectory, [hashtable]$Env = @{})
    $psi = [Diagnostics.ProcessStartInfo]::new((Get-GitBash))
    foreach ($a in '--noprofile', '--norc', '-s') { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
    $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $psi.WorkingDirectory = $WorkingDirectory
    foreach ($key in $Env.Keys) { $psi.Environment[$key] = $Env[$key] }
    $p = [Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $p.StandardInput.Write($Script + "`n")
    $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    [pscustomobject]@{ Out = $out; Err = $errTask.GetAwaiter().GetResult(); ExitCode = $p.ExitCode }
}
