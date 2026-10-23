# Shared by the test files. In BeforeAll:  . (Join-Path $PSScriptRoot 'helpers.ps1'); Initialize-WslbinTest
# State lives in $global:WslbinTest because the functions are called from several scopes.

function Initialize-WslbinTest {
    $repo = Split-Path -Parent $PSScriptRoot
    $work = Join-Path ([IO.Path]::GetTempPath()) ('wslbin-tests-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    $exe = Join-Path $work 'wslbin.exe'
    # WSLBIN_TEST_EXE names a wslbin.exe that is built already (CI builds it once, before the tests):
    # every test file would otherwise run build.ps1 again
    if ($env:WSLBIN_TEST_EXE) {
        if (-not (Test-Path -LiteralPath $env:WSLBIN_TEST_EXE)) { throw "WSLBIN_TEST_EXE names no file: $env:WSLBIN_TEST_EXE" }
        Copy-Item -LiteralPath $env:WSLBIN_TEST_EXE $exe
    }
    else {
        & (Join-Path $repo 'build.ps1') -Output $exe 6>$null
    }
    if (-not (Test-Path $exe)) { throw 'build.ps1 did not produce wslbin.exe' }
    $global:WslbinTest = @{ Repo = $repo; Work = $work; Exe = $exe }
}

function Remove-WslbinTest {
    if ($global:WslbinTest) { Remove-Item -Recurse -Force $global:WslbinTest.Work -ErrorAction SilentlyContinue }
}

# A fresh folder holding a copy of wslbin.exe, for tests of --link and friends.
function New-WslbinHome {
    $dir = Join-Path $global:WslbinTest.Work ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    Copy-Item $global:WslbinTest.Exe (Join-Path $dir 'wslbin.exe')
    $dir
}

# Runs a copy of wslbin.exe named "$Name.exe" (the utility), with its own wslbin.ini if $Ini is given.
# Without -Dir every call gets a folder of its own; with -Dir the folder is reused (and the copy is
# made only when it is missing). Returns stdout, stderr (both UTF-8), the exit code and the folder.
# -From names another build to copy (the one of Initialize-FakeWsl).
function Invoke-Wslbin {
    param(
        [string]$Name = 'tool',
        [string[]]$Arguments = @(),
        [string]$Ini,
        [hashtable]$Env = @{},
        [string]$InputText,
        [string]$WorkingDirectory,
        [string]$Dir,
        [switch]$IniWithBom,
        [string]$From = $global:WslbinTest.Exe
    )
    if (-not $Dir) {
        $Dir = Join-Path $global:WslbinTest.Work ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $Dir | Out-Null
    }
    $exe = Join-Path $Dir "$Name.exe"
    if (-not (Test-Path $exe)) { Copy-Item $From $exe }
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
    # wslbin --install-ai-context writes into the instructions of Claude Code and Codex, which it finds
    # through these two variables (and the home folder). A test run starts from the session of
    # whoever runs it, where they point at the real ones. Point them at folders that do not exist,
    # so that a test that forgets to name its own folders skips the agents instead of changing them.
    # a test must never put the question for administrator rights on the screen
    $psi.Environment['WSLBIN_NO_ELEVATION'] = '1'
    $psi.Environment['CLAUDE_CONFIG_DIR'] = Join-Path $global:WslbinTest.Work 'no-claude-folder-here'
    $psi.Environment['CODEX_HOME'] = Join-Path $global:WslbinTest.Work 'no-codex-folder-here'
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

# A test build of wslbin whose wsl.exe is a stand-in (tests\FakeWslEntry.cs), and the stand-in
# (tests\FakeWsl.cs): $global:WslbinTest.FakeExe and .FakeWsl. Neither needs WSL.
function Initialize-FakeWsl {
    $repo = $global:WslbinTest.Repo
    $dir = Join-Path $global:WslbinTest.Work 'fake-wsl-build'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $exe = Join-Path $dir 'wslbin.exe'
    & (Join-Path $repo 'build.ps1') -Output $exe -ExtraSource (Join-Path $repo 'tests\FakeWslEntry.cs') -Main 'Wslbin.FakeWslEntry' 6>$null
    $wsl = Join-Path $dir 'wsl.exe'
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $csc /nologo "/out:$wsl" (Join-Path $repo 'tests\FakeWsl.cs') | Out-Null
    if (-not (Test-Path $exe) -or -not (Test-Path $wsl)) { throw 'the test build with a stand-in for wsl.exe failed' }
    $global:WslbinTest.FakeExe = $exe
    $global:WslbinTest.FakeWsl = $wsl
}

# A folder with the answers of the stand-in wsl.exe (file names as in tests\FakeWsl.cs). An array is
# written as bytes (a function hands a byte[] over as object[]), anything else as UTF-8 text. Returns
# the environment for Invoke-Wslbin -Env, with a PATH that has nothing of this machine's programs in it
# (--link checks names against PATH).
function New-FakeWsl {
    param([hashtable]$Files = @{}, [bool]$HasDistribution = $true)
    $dir = Join-Path $global:WslbinTest.Work ('fake-wsl-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    foreach ($name in $Files.Keys) {
        $value = $Files[$name]
        if ($value -is [array]) { [IO.File]::WriteAllBytes((Join-Path $dir $name), [byte[]]$value) }
        else { [IO.File]::WriteAllText((Join-Path $dir $name), [string]$value, [Text.UTF8Encoding]::new($false)) }
    }
    @{
        WSLBIN_TEST_WSL     = $global:WslbinTest.FakeWsl
        WSLBIN_TEST_DISTROS = $(if ($HasDistribution) { '1' } else { '0' })
        FAKE_WSL_DIR        = $dir
        PATH                = "$env:SystemRoot\System32"
    }
}

# Text as wsl.exe writes its own messages: UTF-16.
function ConvertTo-Utf16 ([string]$Text) { [Text.Encoding]::Unicode.GetBytes($Text) }

# The bash command that --wslbin-explain prints, without the final newline.
function Get-Explain {
    param([string[]]$Arguments = @(), [string]$Name = 'tool', [string]$Ini, [string[]]$Flags = @())
    $splat = @{ Name = $Name; Arguments = (@('--wslbin-explain') + $Flags + $Arguments) }
    if ($PSBoundParameters.ContainsKey('Ini')) { $splat.Ini = $Ini }
    (Invoke-Wslbin @splat).Out.TrimEnd("`n")
}

# The bash command for one argument, with wslbin started in the given folder (relative paths depend on it).
function Get-RelExplain {
    param([string]$Argument, [string]$In, [string[]]$Flags = @())
    (Invoke-Wslbin -WorkingDirectory $In -Arguments (@('--wslbin-explain') + $Flags + @($Argument))).Out.TrimEnd("`n")
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

# PATH for a child: the given folder first, then System32 only. Keeps tests of name conflicts
# independent of what is installed on the machine.
function Get-IsolatedPath {
    param([string]$First)
    "$First;$env:SystemRoot\System32"
}

# What the Clink test types, and the bash command that each completed line must stand for.
# A function, because Pester needs the list both when it collects the tests and when it runs them.
function Get-ClinkCases {
    $ru = -join ([char[]](0x0444, 0x0430, 0x0439, 0x043B))        # "файл"
    $ruStart = $ru.Substring(0, 2)
    @(
        @{ Typed = 'rsync --wslbin-explain --arch';                           Want = 'rsync --archive' }
        @{ Typed = 'rsync --wslbin-explain -av C:\Windows\win.i';             Want = 'rsync -av /mnt/c/Windows/win.ini' }
        @{ Typed = 'rsync --wslbin-explain -av c:\windows\win.i';             Want = 'rsync -av /mnt/c/windows/win.ini' }
        # what Tab writes is a relative path with backslashes that exists in the folder, so it arrives as a Linux one
        @{ Typed = 'rsync --wslbin-explain -av alpha';                        Want = 'rsync -av alpha\ one/' }
        @{ Typed = 'rsync --wslbin-explain -av ".\alpha one\inn';             Want = 'rsync -av ./alpha\ one/inner\ file.txt' }
        @{ Typed = "rsync --wslbin-explain -av .\$ruStart";                   Want = "rsync -av ./$ru-note.txt" }
        @{ Typed = 'rsync --wslbin-explain --exclude-from=C:\Windows\win.i';  Want = 'rsync --exclude-from=/mnt/c/Windows/win.ini' }
        @{ Typed = 'rsync --wslbin-explain --exclude-from=alpha';             Want = 'rsync --exclude-from=alpha\ one/' }
        @{ Typed = 'wslbin --explain rsy';                                    Want = 'rsync' }
        # a name that cmd.exe would split at & goes in quotes; without them cmd would run "ver.txt" too
        @{ Typed = 'rsync --wslbin-explain x';                                Want = 'rsync x\&ver.txt' }
        # a Linux name with " would close those quotes: it is not offered, and the line stays as typed
        # (the file is made in WSL by the test: /tmp/wslbin-clink-q"&ver"x)
        @{ Typed = 'rsync --wslbin-explain /tmp/wslbin-clink-q';              Want = 'rsync /tmp/wslbin-clink-q' }
        @{ Typed = 'rsync --wslbin-explain --nosuchoption';                   Want = 'rsync --nosuchoption' }
    )
}
