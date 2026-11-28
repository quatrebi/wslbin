# Shared by the test files. In BeforeAll:  . (Join-Path $PSScriptRoot 'helpers.ps1'); Initialize-WslbinTest
# State lives in $global:WslbinTest because the functions are called from several scopes.

function Initialize-WslbinTest {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
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
        # exact bytes for standard input (instead of -InputText), and the exact bytes of standard output
        # in .OutBytes (.Out is then empty): for tests of binary data
        [byte[]]$InputBytes,
        [switch]$OutputBytes,
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
    $outBuffer = $null
    if ($OutputBytes) {
        $outBuffer = [IO.MemoryStream]::new()
        $outTask = $p.StandardOutput.BaseStream.CopyToAsync($outBuffer)
    }
    else { $outTask = $p.StandardOutput.ReadToEndAsync() }
    $errTask = $p.StandardError.ReadToEndAsync()
    if ($null -ne $InputBytes) {
        $p.StandardInput.BaseStream.Write($InputBytes, 0, $InputBytes.Length)
        $p.StandardInput.BaseStream.Flush()
    }
    elseif ($null -ne $InputText) { $p.StandardInput.Write($InputText) }
    $p.StandardInput.Close()
    $p.WaitForExit()
    [pscustomobject]@{
        Out      = $(if ($OutputBytes) { '' } else { $outTask.GetAwaiter().GetResult() })
        OutBytes = $(if ($OutputBytes) { $null = $outTask.GetAwaiter().GetResult(); $outBuffer.ToArray() } else { $null })
        Err      = $errTask.GetAwaiter().GetResult()
        ExitCode = $p.ExitCode
        Dir      = $Dir
    }
}
