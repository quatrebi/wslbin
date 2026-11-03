# Shared by install.ps1 and uninstall.ps1 (dot-sourced; the tests dot-source it too). Works in Windows
# PowerShell 5.1 and in PowerShell 7. It reads the parameters of the script that dot-sources it
# ($ProfileRoot, $ClinkDir, $NoPath, $UninstallKey): they are script variables there.
#
# The script that dot-sources it sets $script:BoundParameters to its $PSBoundParameters: a copy of the
# script that is started again (from a temporary folder, or with administrator rights) gets the
# parameters from them.
$ErrorActionPreference = 'Stop'

$BeginMark = '# >>> wslbin >>>'
$EndMark = '# <<< wslbin <<<'

# Everything the script says goes through these two.
function Write-Line([string]$Text) { Write-Host $Text }
function Write-Problem([string]$Text) { Write-Warning $Text }

function Write-Step([string]$Text) { Write-Line "wslbin setup: $Text" }

# what went wrong without stopping the install; the exit code says so at the end
$script:Problems = 0

# Runs a program and returns its exit code, what it wrote to standard output and what it wrote to
# standard error. Under $ErrorActionPreference 'Stop', Windows PowerShell 5.1 turns anything that a
# program writes to standard error into an error that ends the script, and wslbin writes warnings there.
function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = New-Object System.Collections.Generic.List[string]
    $err = New-Object System.Collections.Generic.List[string]
    try {
        & $Exe @Arguments 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $err.Add($_.ToString()) } else { $out.Add([string]$_) }
        }
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $saved
    }
    [pscustomobject]@{ ExitCode = $code; Out = $out.ToArray(); Err = $err.ToArray() }
}

# Runs wslbin and shows what it says. A failure is a problem to report at the end, not a reason to stop.
function Invoke-WslbinStep([string]$Exe, [string[]]$Arguments) {
    $r = Invoke-Native $Exe $Arguments
    foreach ($line in $r.Out) { Write-Line $line }
    foreach ($line in $r.Err) { Write-Line $line }
    if ($r.ExitCode -ne 0) {
        Write-Problem "wslbin $($Arguments -join ' ') ended with exit code $($r.ExitCode)"
        $script:Problems++
    }
}

# A path in its full form, relative to the folder the script was started in: a relative path would
# end up in PATH and in the profiles, and a copy of this script that is started again starts somewhere else.
function ConvertTo-FullPath([string]$Path) {
    if (-not $Path) { return $Path }
    [IO.Path]::GetFullPath([IO.Path]::Combine((Get-Location -PSProvider FileSystem).ProviderPath, $Path))
}

# One argument of a command line that CommandLineToArgvW reads: in quotes, with the backslashes that
# stand in front of a quote (or of the closing quote) doubled.
function ConvertTo-CommandLineArgument([string]$Value) {
    '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

# "a,b" and "a", "b" are the same list (a script started with -File gets one string).
function Split-List([string[]]$Values) {
    @($Values | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-DefaultInstallDir([string]$ForScope) {
    if ($ForScope -eq 'AllUsers') { return Join-Path $env:ProgramFiles 'wslbin' }
    Join-Path $env:LOCALAPPDATA 'Programs\wslbin'
}

# The PowerShell that runs this script, as a program to start: powershell.exe (5.1) or pwsh.exe (7) of
# $PSHOME. Not the program of this process: that may be another host (the ISE, an editor).
function Get-PowerShellPath {
    if ($PSVersionTable.PSEdition -eq 'Core') { return Join-Path $PSHOME 'pwsh.exe' }
    Join-Path $PSHOME 'powershell.exe'
}

# The PowerShell that the copy with administrator rights runs in: Windows PowerShell of the system folder,
# which only administrators can change. Not the one of $PSHOME: a PowerShell 7 unpacked under the profile
# of the user is a program that the user, and any program of the user, can change.
function Get-ElevatedPowerShellPath {
    Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
}

# ---- PATH ---------------------------------------------------------------------------------------

# The registry key that holds Path for a scope, as a hive and a sub key.
function Get-PathLocation([string]$ForScope) {
    if ($ForScope -eq 'AllUsers') {
        return @{ Hive = [Microsoft.Win32.Registry]::LocalMachine; SubKey = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment' }
    }
    @{ Hive = [Microsoft.Win32.Registry]::CurrentUser; SubKey = 'Environment' }
}

function ConvertTo-ComparablePath([string]$Entry) {
    [Environment]::ExpandEnvironmentVariables($Entry.Trim().Trim('"')).TrimEnd('\').ToLowerInvariant()
}

# Folders, each once: full paths, compared without case and without a \ at the end.
function Select-UniquePath([string[]]$Paths) {
    $seen = @{}
    foreach ($path in $Paths) {
        if (-not $path) { continue }
        $full = (ConvertTo-FullPath $path).TrimEnd('\')
        $key = ConvertTo-ComparablePath $full
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $full
    }
}

# Adds a folder to the Path value, or removes it. The value keeps its kind (REG_EXPAND_SZ) and the
# entries that hold %VARIABLES%: [Environment]::SetEnvironmentVariable would flatten them.
function Set-PathEntry {
    param(
        [Parameter(Mandatory)] $Hive,
        [Parameter(Mandatory)] [string]$SubKey,
        [Parameter(Mandatory)] [string]$Entry,
        [switch]$Remove
    )
    $key = $Hive.OpenSubKey($SubKey, $true)
    if (-not $key) { $key = $Hive.CreateSubKey($SubKey) }
    try {
        $current = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
        if ($key.GetValueNames() -contains 'Path') { $kind = $key.GetValueKind('Path') }

        $wanted = ConvertTo-ComparablePath $Entry
        $entries = @($current.Split(';') | Where-Object { $_.Trim() -ne '' })
        $present = @($entries | Where-Object { (ConvertTo-ComparablePath $_) -eq $wanted }).Count -gt 0
        # the value is rewritten only when it has to change: the folder may be there already in
        # another spelling (case, quotes, a slash at the end, %VARIABLES%)
        if ($Remove -eq (-not $present)) { return $false }
        if ($Remove) { $entries = @($entries | Where-Object { (ConvertTo-ComparablePath $_) -ne $wanted }) }
        else { $entries += $Entry }
        $key.SetValue('Path', ($entries -join ';'), $kind)
        return $true
    }
    finally {
        $key.Close()
    }
}

# Tells running programs (Explorer, new terminals) that the environment has changed. .NET sends
# WM_SETTINGCHANGE "Environment" itself whenever it sets a variable of the user, and removing one that
# does not exist changes nothing in the registry and still sends it. Not Add-Type: Windows PowerShell
# compiles that into a DLL in TEMP and loads it from there, and the copy with administrator rights runs
# nothing that a program of the user could change. ([NullString]::Value: a $null given to a .NET method
# becomes "", and that would write an empty variable instead of removing one.)
function Send-EnvironmentChange {
    [Environment]::SetEnvironmentVariable('WSLBIN_NO_SUCH_VARIABLE_' + [guid]::NewGuid().ToString('N'), [NullString]::Value, 'User')
}

# ---- profile blocks -----------------------------------------------------------------------------

# The text of bytes that must be UTF-8 (with or without a byte order mark). Anything else is refused:
# a profile that is saved as ANSI or UTF-16 would come back damaged if it were decoded and written as UTF-8.
function ConvertFrom-Utf8Bytes([string]$Path, [byte[]]$Bytes) {
    $hasBom = $Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF
    $skip = $(if ($hasBom) { 3 } else { 0 })
    $text = $null
    try { $text = (New-Object Text.UTF8Encoding($false, $true)).GetString($Bytes, $skip, $Bytes.Length - $skip) } catch { }
    # UTF-16 without a mark is valid UTF-8 with a NUL between the letters
    if ($null -eq $text -or $text.IndexOf([char]0) -ge 0) {
        throw "$Path is not UTF-8 text (is it ANSI or UTF-16?): left alone. Save it as UTF-8, or put the block in by hand."
    }
    @{ Text = $text; Bom = $hasBom }
}

function Read-Utf8Text([string]$Path) {
    ConvertFrom-Utf8Bytes $Path ([IO.File]::ReadAllBytes($Path))
}

# Where the block is: the first end marker, and the last begin marker in front of it. $null when there
# is none. A marker without its partner is an error: guessing would cut text that is not ours.
function Find-MarkedBlock([string]$Path, [string]$Text) {
    $end = $Text.IndexOf($EndMark, [StringComparison]::Ordinal)
    $anyBegin = $Text.IndexOf($BeginMark, [StringComparison]::Ordinal) -ge 0
    if ($end -lt 0 -and -not $anyBegin) { return $null }
    $begin = -1
    if ($end -ge 0) { $begin = $Text.LastIndexOf($BeginMark, $end, [StringComparison]::Ordinal) }
    if ($end -lt 0 -or $begin -lt 0) {
        throw "$Path has a wslbin begin or end marker without its other half: left alone. Delete the stray marker line and run this again."
    }
    @{ Begin = $begin; End = $end }
}

# The text between the markers of the block in a file, or $null when there is no file or no block.
function Get-MarkedBlock([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $text = (Read-Utf8Text $Path).Text
    $found = Find-MarkedBlock $Path $text
    if (-not $found) { return $null }
    $text.Substring($found.Begin, $found.End - $found.Begin)
}

# Puts a block between the wslbin markers into a text file: replaces the one that is there, or
# adds one at the end. Everything else in the file stays as it is, with its line ends and BOM.
function Set-MarkedBlock([string]$Path, [string]$Body) {
    $existing = ''
    $hasBom = $false
    if (Test-Path -LiteralPath $Path) {
        $file = Read-Utf8Text $Path
        $existing = $file.Text
        $hasBom = $file.Bom
    }

    $newline = "`r`n"
    $firstBreak = $existing.IndexOf("`n")
    if ($firstBreak -ge 0 -and ($firstBreak -eq 0 -or $existing[$firstBreak - 1] -ne "`r")) { $newline = "`n" }
    $block = ($BeginMark + ' (written by the wslbin setup; uninstalling wslbin takes it out)' + "`n" + $Body.Trim() + "`n" + $EndMark + "`n").Replace("`n", $newline)

    $found = Find-MarkedBlock $Path $existing
    if ($found) {
        $after = $found.End + $EndMark.Length
        if ($after -lt $existing.Length -and $existing[$after] -eq "`r") { $after++ }
        if ($after -lt $existing.Length -and $existing[$after] -eq "`n") { $after++ }
        $text = $existing.Substring(0, $found.Begin) + $block + $existing.Substring($after)
    }
    else {
        $separator = ''
        if ($existing.Length -gt 0) { $separator = $(if ($existing.EndsWith("`n")) { $newline } else { $newline + $newline }) }
        $text = $existing + $separator + $block
    }
    $nonAscii = $text -match '[^\u0000-\u007F]'
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null }
    [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding($hasBom -or ($nonAscii -and $existing.Length -eq 0))))
}

# Takes the marked block out. A file that held nothing else is deleted. Returns whether there was one.
function Remove-MarkedBlock([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $file = Read-Utf8Text $Path
    $existing = $file.Text
    $found = Find-MarkedBlock $Path $existing
    if (-not $found) { return $false }
    $begin = $found.Begin

    $after = $found.End + $EndMark.Length
    if ($after -lt $existing.Length -and $existing[$after] -eq "`r") { $after++ }
    if ($after -lt $existing.Length -and $existing[$after] -eq "`n") { $after++ }
    $before = $begin
    # the blank line that went in front of the block goes with it
    $taken = 0
    while ($before -gt 0 -and $taken -lt 2 -and ($existing[$before - 1] -eq "`n" -or $existing[$before - 1] -eq "`r")) {
        if ($existing[$before - 1] -eq "`n") { $taken++ }
        $before--
        if ($before -gt 0 -and $existing[$before - 1] -eq "`r" -and $existing[$before] -eq "`n") { $before-- }
    }
    $left = $existing.Substring(0, $before)
    $right = $existing.Substring($after)
    $nl = $(if ($existing.Contains("`r`n")) { "`r`n" } else { "`n" })
    $text = $left + $(if ($left.Length -gt 0 -and $right.Length -gt 0) { $nl + $nl } elseif ($left.Length -gt 0) { $nl } else { '' }) + $right
    if ($text.Trim().Length -eq 0) { Remove-Item -LiteralPath $Path -Force }
    else { [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding($file.Bom))) }
    return $true
}

function Get-ProfilePaths {
    $root = $ProfileRoot
    if (-not $root) { $root = [Environment]::GetFolderPath('MyDocuments') }
    @((Join-Path $root 'WindowsPowerShell\profile.ps1'), (Join-Path $root 'PowerShell\profile.ps1'))
}

# The code of the profile block for the wslbin.exe of a folder. Its path is in it as a literal, so that a
# block can be told apart by the installation it belongs to (Test-HookNames).
function Get-ProfileBlockBody([string]$Exe) {
    $literal = ConvertTo-PowerShellLiteral $Exe
    "if (Test-Path -LiteralPath $literal) { & $literal --init pwsh | Invoke-Expression }"
}

# The execution policy under which a PowerShell runs its profile: the effective one of that program,
# without the Process scope (a script that was started with -ExecutionPolicy Bypass hands that on to every
# program it starts, through PSExecutionPolicyPreference). $null when it cannot be told.
function Get-ProfileExecutionPolicy([string]$Shell) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo $Shell, '-NoProfile -NonInteractive -Command [string](Get-ExecutionPolicy)'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    # (Windows PowerShell started with the module path of PowerShell 7 cannot load its own modules)
    foreach ($name in 'PSExecutionPolicyPreference', 'PSModulePath') {
        if ($psi.EnvironmentVariables.ContainsKey($name)) { $psi.EnvironmentVariables.Remove($name) }
    }
    try { $process = [System.Diagnostics.Process]::Start($psi) } catch { return $null }
    $process.StandardInput.Close()
    $read = $process.StandardOutput.ReadToEndAsync()
    $null = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(30000)) {
        try { $process.Kill() } catch { }
        return $null
    }
    $policy = $read.Result.Trim()
    if ($policy -notmatch '^[A-Za-z]+$') { return $null }
    $policy
}

# Warns about each PowerShell that would not run the profile that Tab completion was hooked into: under
# Restricted it runs no script at all, under AllSigned no unsigned one. Not a problem of the install.
function Write-ProfilePolicyWarnings {
    $shells = @(@{ Name = 'Windows PowerShell'; Exe = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') })
    $pwsh = Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pwsh) { $shells += @{ Name = 'PowerShell 7'; Exe = $pwsh.Source } }
    foreach ($shell in $shells) {
        if (-not (Test-Path -LiteralPath $shell.Exe)) { continue }
        $policy = Get-ProfileExecutionPolicy $shell.Exe
        if ($policy -eq 'Restricted' -or $policy -eq 'AllSigned') {
            Write-Problem "$($shell.Name) will not run the profile with the Tab completion: its execution policy is $policy. To let it run local scripts: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned (in $($shell.Name))."
        }
    }
}

# ---- hashes ------------------------------------------------------------------------------------

function Test-FileHash([string]$Path, [string]$Expected) {
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($actual -ne $Expected.Trim().ToUpperInvariant()) {
        throw "The SHA256 of $Path is $actual, not $($Expected.Trim().ToUpperInvariant())."
    }
}

function Get-BytesHash([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

# ---- elevation ----------------------------------------------------------------------------------

# A PowerShell string literal of a text that reads the same in any code page: Windows PowerShell 5.1
# reads a profile without a byte order mark as ANSI, so letters outside ASCII are written as [char]
# codes (as "wslbin --init pwsh" does for the code it prints). The typographic quotes that PowerShell
# takes for ' are outside ASCII too.
function ConvertTo-PowerShellLiteral([string]$Text) {
    $parts = New-Object System.Collections.Generic.List[string]
    $run = New-Object System.Text.StringBuilder
    foreach ($c in $Text.ToCharArray()) {
        if ([int]$c -lt 128) {
            if ($c -eq "'") { [void]$run.Append("''") } else { [void]$run.Append($c) }
            continue
        }
        if ($run.Length -gt 0) { $parts.Add("'" + $run.ToString() + "'"); [void]$run.Clear() }
        $parts.Add('[char]' + [int]$c)
    }
    if ($run.Length -gt 0 -or $parts.Count -eq 0) { $parts.Add("'" + $run.ToString() + "'") }
    if ($parts.Count -eq 1) { return $parts[0] }
    '(' + ($parts -join ' + ') + ')'
}

# The arguments of this script for a copy of it that is started again: the parameters among $Names that
# were given, as they are now (full paths), as a command line (CommandLineToArgvW) or, with -PowerShell,
# as PowerShell literals. A list is one value with commas.
function Get-ParameterTokens([string[]]$Names, [switch]$PowerShell) {
    $tokens = New-Object System.Collections.Generic.List[string]
    foreach ($key in $Names) {
        if (-not $script:BoundParameters.ContainsKey($key)) { continue }
        $value = Get-Variable -Name $key -ValueOnly
        if ($value -is [switch]) {
            if ($value.IsPresent) { $tokens.Add("-$key") }
            continue
        }
        if ($value -is [array]) { $value = $value -join ',' }
        $tokens.Add("-$key")
        if ($PowerShell) { $tokens.Add((ConvertTo-PowerShellLiteral ([string]$value))) }
        else { $tokens.Add((ConvertTo-CommandLineArgument ([string]$value))) }
    }
    $tokens.ToArray()
}

# The code that the copy with administrator rights runs (powershell -Command). It never runs a file from
# where this copy found it (the package is in the user's TEMP, which any program of the user can write,
# also after the check): it reads each file of $Files ({Source; Path; Sha256}), checks the SHA256 of what
# it read, writes it into a new folder under Program Files, which only administrators can write, and
# runs $Script with $Arguments (PowerShell literals) from there. The folder is deleted at the end. When
# that fails, the window stays open a while so that its messages can be read (not with -NoPause: a
# PowerShell that has the rights already runs it in its own console). $StageRoot is for the tests.
# The first line sets the module path to the modules of that PowerShell only, before any command runs:
# PowerShell loads a module for a command it does not know yet from the first folder of PSModulePath that
# has one, and the folders of the user come first (a module there could stand in for Get-FileHash).
function Get-ElevatedCommand([object[]]$Files, [string]$Script, [string[]]$Arguments, [string]$StageRoot, [switch]$NoPause) {
    $root = "[Environment]::GetFolderPath('ProgramFiles')"
    if ($StageRoot) { $root = ConvertTo-PowerShellLiteral $StageRoot }
    $list = @($Files | ForEach-Object {
            '@(' + (ConvertTo-PowerShellLiteral $_.Source) + ', ' + (ConvertTo-PowerShellLiteral $_.Path) + ', ' + (ConvertTo-PowerShellLiteral $_.Sha256) + ')'
        }) -join ', '
    $code = @'
$env:PSModulePath = [IO.Path]::Combine($PSHOME, 'Modules')
$ErrorActionPreference = 'Stop'
$code = 2
$stage = $null
try {
    $root = @ROOT@
    if (-not $root) { throw 'There is no Program Files folder to put the checked files in.' }
    $stage = Join-Path $root ('wslbin-setup-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $stage
    $sha = [Security.Cryptography.SHA256]::Create()
    foreach ($file in @(@FILES@)) {
        $bytes = [IO.File]::ReadAllBytes($file[0])
        $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '')
        if ($hash -ne $file[2]) { throw ('The SHA256 of ' + $file[0] + ' is ' + $hash + ', not ' + $file[2] + ': the file was changed after it was checked. Nothing was done.') }
        $target = Join-Path $stage $file[1]
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force
        [IO.File]::WriteAllBytes($target, $bytes)
    }
    $global:LASTEXITCODE = 2
    & (Join-Path $stage @SCRIPT@) @ARGUMENTS@
    $code = $LASTEXITCODE
}
catch { Write-Warning $_.Exception.Message }
finally { if ($stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue } }
if ($code -ne 0 -and @PAUSE@ -and -not [Console]::IsInputRedirected) {
    Write-Host ('wslbin setup: failed (exit code ' + $code + '). This window closes in 60 seconds, or when you press a key.')
    $until = [DateTime]::UtcNow.AddSeconds(60)
    try { while ([DateTime]::UtcNow -lt $until -and -not [Console]::KeyAvailable) { Start-Sleep -Milliseconds 200 } } catch { }
}
exit $code
'@
    $pause = $(if ($NoPause) { '$false' } else { '$true' })
    $code.Replace('@ROOT@', $root).Replace('@PAUSE@', $pause).Replace('@FILES@', $list).Replace('@SCRIPT@', (ConvertTo-PowerShellLiteral $Script)).Replace('@ARGUMENTS@', ($Arguments -join ' '))
}

# The command line of the PowerShell that runs that code.
function Get-ElevatedArgumentLine([string]$Command) {
    '-NoProfile -ExecutionPolicy Bypass -Command ' + (ConvertTo-CommandLineArgument $Command)
}

# Starts the code of Get-ElevatedCommand with administrator rights (UAC) and returns the exit code of
# the script it runs: 0 done, anything else failed (its window said why); $null when the rights were refused.
# A PowerShell that has the rights already runs the same code in its own console, without asking: the
# files are checked into a folder that only administrators can write either way, so that nothing a
# program of the user changes in TEMP after the check is run with those rights.
function Invoke-Elevated([object[]]$Files, [string]$Script, [string[]]$Arguments) {
    $admin = Test-Administrator
    # for scripts and tests: never put the UAC question on the screen
    if (-not $admin -and $env:WSLBIN_NO_ELEVATION -eq '1') { return $null }
    $start = @{
        FilePath         = Get-ElevatedPowerShellPath
        ArgumentList     = Get-ElevatedArgumentLine (Get-ElevatedCommand $Files $Script $Arguments -NoPause:$admin)
        Wait             = $true
        PassThru         = $true
        WorkingDirectory = $env:SystemRoot
    }
    if ($admin) { $start.NoNewWindow = $true } else { $start.Verb = 'RunAs' }
    try {
        $process = Start-Process @start
    }
    catch {
        return $null
    }
    $process.ExitCode
}

# A file for Get-ElevatedCommand, with the SHA256 of what is there now: $Source is to be put at $Path.
function Get-FileToCheck([string]$Source, [string]$Path) {
    [pscustomobject]@{ Source = $Source; Path = $Path; Sha256 = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash.ToLowerInvariant() }
}

# Where "wslbin --init clink" may have put wslbin.lua: the folder of -ClinkDir; or else the state
# folder that "clink info" names, and %LOCALAPPDATA%\clink.
function Get-ClinkScriptFolders {
    if ($ClinkDir) { return @($ClinkDir) }
    $folders = @(Join-Path $env:LOCALAPPDATA 'clink')
    $clink = Get-Command clink -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($clink) {
        # given up on after 10 seconds, as in "wslbin --init clink": an uninstall must not hang on it
        # (all three streams its own, so that nothing it leaves running holds those of this script)
        $psi = New-Object System.Diagnostics.ProcessStartInfo $env:ComSpec, ('/d /c ""' + $clink.Source + '" info"')
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $process = [System.Diagnostics.Process]::Start($psi)
        $process.StandardInput.Close()
        $read = $process.StandardOutput.ReadToEndAsync()
        $null = $process.StandardError.ReadToEndAsync()
        if ($process.WaitForExit(10000)) {
            foreach ($line in $read.Result -split "`r?`n") {
                if ($line -match '^state\s*:\s*(.+?)\s*$') { $folders += $Matches[1] }
            }
        }
        else {
            $null = Invoke-Native (Join-Path $env:SystemRoot 'System32\taskkill.exe') @('/T', '/F', '/PID', [string]$process.Id)
            Write-Problem "clink info did not answer within 10 seconds; wslbin.lua is looked for in $($folders -join ', ') only"
        }
    }
    @(Select-UniquePath $folders)
}

# The wslbin.exe that a Clink script of wslbin names (its line "local wslbin_exe = <Lua string>"), or
# $null when the file is not a Clink script of wslbin.
function Get-ClinkScriptExe([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8)
    if ($lines.Count -eq 0 -or $lines[0] -notlike '-- wslbin for cmd (Clink)*') { return $null }
    foreach ($line in $lines) {
        if ($line -match '^local wslbin_exe = "(.*)"\s*$') { return ($Matches[1] -replace '\\(.)', '$1') }
    }
    ''
}

# Whether a hook (the text of a profile block, or the wslbin.exe that a Clink script names) belongs to
# one of the installations in $Dirs.
function Test-HookNames([string]$Hook, [string[]]$Dirs, [switch]$Clink) {
    foreach ($dir in $Dirs) {
        $exe = Join-Path $dir 'wslbin.exe'
        if ($Clink) {
            if ($Hook -and (ConvertTo-ComparablePath $Hook) -eq (ConvertTo-ComparablePath $exe)) { return $true }
        }
        elseif ($Hook.IndexOf((ConvertTo-PowerShellLiteral $exe), [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    $false
}

# ---- the folder of an installation for all users -------------------------------------------------

# Accounts that may change what an installation for all users is made of: Administrators, SYSTEM,
# TrustedInstaller, and CREATOR OWNER (the rights that whoever makes a file there gets on it: in such a
# folder that is one of the others). Not the account that installs, even with administrator rights: with
# UAC its programs that run without those rights are the same account.
$TrustedSids = @('S-1-5-32-544', 'S-1-5-18', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464', 'S-1-3-0')

# Rights that change a folder or what is in it: write and append data (add a file, a folder), write
# extended attributes, delete a child, write attributes, delete, change the rights, take ownership, and
# the generic "all" and "write".
$ChangeRights = 0x2 -bor 0x4 -bor 0x10 -bor 0x40 -bor 0x100 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x10000000 -bor 0x40000000
# What lets an account take a folder above the install folder from under it: delete (rename) it or a
# child of it, change its rights, take ownership, the generic "all".
$TakeAwayRights = 0x40 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x10000000
# What counts on the root of a drive, which cannot be renamed: changing its rights, taking ownership,
# deleting a child, the generic "all" (making a folder in it, as C:\ lets every account, does not).
$RootRights = 0x40 -bor 0x40000 -bor 0x80000 -bor 0x10000000

function ConvertTo-AccountName($Sid) {
    try { $Sid.Translate([Security.Principal.NTAccount]).Value } catch { [string]$Sid.Value }
}

# The accounts other than $Trusted (SIDs) to whom the rights $Acl give any of $Mask, and an owner that is
# not one of $Trusted (an owner may change the rights), as a list (wrap the call in @()). -Ancestor: rights that apply to the children only
# (inherit only) do not count, since what they give is seen on the next folder down.
function Get-FolderWriters($Acl, [string[]]$Trusted, [int64]$Mask = $ChangeRights, [switch]$Ancestor) {
    $sidType = [Security.Principal.SecurityIdentifier]
    $names = New-Object System.Collections.Generic.List[string]
    $owner = $Acl.GetOwner($sidType)
    if ($owner -and $Trusted -notcontains $owner.Value) { $names.Add((ConvertTo-AccountName $owner) + ' (the owner)') }
    foreach ($rule in $Acl.GetAccessRules($true, $true, $sidType)) {
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
        if ($Ancestor -and ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)) { continue }
        if ($Trusted -contains $rule.IdentityReference.Value) { continue }
        if (([int64][int]$rule.FileSystemRights -band $Mask) -eq 0) { continue }
        $name = ConvertTo-AccountName $rule.IdentityReference
        if (-not $names.Contains($name)) { $names.Add($name) }
    }
    $names.ToArray()
}

# The accounts other than $Trusted that could change an installation in $Dir, each with the folder that
# lets them: through the rights of the folder itself, or of a folder above it that they could rename or
# take over. Empty when there are none. A folder that does not exist yet is judged by those above it.
function Get-MachineFolderWriters([string]$Dir, [string[]]$Trusted = $TrustedSids) {
    $found = New-Object System.Collections.Generic.List[string]
    $path = $Dir.TrimEnd('\')
    $first = $true
    while ($path) {
        $parent = Split-Path -Parent $path
        if (Test-Path -LiteralPath $path -PathType Container) {
            $acl = Get-Acl -LiteralPath $path -ErrorAction Stop
            if ($first) { $writers = @(Get-FolderWriters $acl $Trusted) }
            elseif (-not $parent) { $writers = @(Get-FolderWriters $acl $Trusted -Mask $RootRights -Ancestor) }
            else { $writers = @(Get-FolderWriters $acl $Trusted -Mask $TakeAwayRights -Ancestor) }
            foreach ($w in $writers) { $found.Add("$w on $path") }
        }
        $first = $false
        $path = $parent
    }
    $found.ToArray()
}

# The rights of a new folder of an installation for all users: Administrators and SYSTEM may do anything,
# Users may read and run, and nothing comes from the folder above (C:\ lets every account change what is
# in a folder made in it). With administrator rights the owner is Administrators, not the account that
# installs: that account is not trusted (its programs that run without the rights are the same account),
# and an owner may change the rights. Without them (the tests) the owner cannot be set to another.
function New-MachineFolderSecurity {
    $security = New-Object Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false)
    if (Test-Administrator) { $security.SetOwner((New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544')) }
    $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $none = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    foreach ($rule in @(@('S-1-5-32-544', 'FullControl'), @('S-1-5-18', 'FullControl'), @('S-1-5-32-545', 'ReadAndExecute'))) {
        $sid = New-Object Security.Principal.SecurityIdentifier $rule[0]
        $security.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, [Security.AccessControl.FileSystemRights]$rule[1], $inherit, $none, $allow)))
    }
    $security
}

# Makes the folder with those rights in one step, so that it never has the rights of the folder above:
# Windows PowerShell has Directory.CreateDirectory with rights, PowerShell 7 FileSystemAclExtensions.
function New-MachineFolder([string]$Dir) {
    $parent = Split-Path -Parent $Dir
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null }
    $security = New-MachineFolderSecurity
    if ('System.IO.FileSystemAclExtensions' -as [type]) { $null = [IO.FileSystemAclExtensions]::CreateDirectory($security, $Dir) }
    else { $null = [IO.Directory]::CreateDirectory($Dir, $security) }
}

# An installation for all users is run by every account and by programs with administrator rights, and
# the copy with those rights replaces and deletes files in its folder: so the folder must be one that only
# administrators can change. A new one is made so; one that is there already is refused when it is not.
function Initialize-MachineFolder([string]$Dir) {
    if (-not (Test-Path -LiteralPath $Dir)) { New-MachineFolder $Dir }
    $writers = @(Get-MachineFolderWriters $Dir)
    if ($writers.Count -gt 0) {
        $shown = @($writers | Select-Object -First 3) -join '; '
        if ($writers.Count -gt 3) { $shown += '; ...' }
        throw "$Dir can be changed by others than administrators ($shown). An installation for all users is run by every account and with administrator rights, so it must be in a folder that only administrators can change, such as $(Get-DefaultInstallDir 'AllUsers'). Nothing was installed."
    }
}

# ---- wrappers -----------------------------------------------------------------------------------

# Whether a file is a copy of wslbin.exe: its product name says so (as wslbin itself tells them).
function Test-WrapperFile([string]$Path) {
    try { [Diagnostics.FileVersionInfo]::GetVersionInfo($Path).ProductName -ceq 'wslbin' } catch { $false }
}

# The wrappers in $Dir, by name, as "wslbin --list --names" lists them: the .exe files that are wslbin,
# other than wslbin.exe. Read here, not asked of the wslbin.exe there: the copy with administrator rights
# runs no program from the folder that it changes, and a wslbin.exe that is missing or broken (an
# install that was cut short) must not leave the wrappers as old copies.
function Get-WrapperNames([string]$Dir) {
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return @() }
    @(Get-ChildItem -LiteralPath $Dir -Filter '*.exe' -File -Force -ErrorAction Stop |
            Where-Object { $_.Extension -eq '.exe' -and $_.Name -ne 'wslbin.exe' -and (Test-WrapperFile $_.FullName) } |
            ForEach-Object { $_.BaseName } | Sort-Object)
}

# ---- versions (SemVer 2.0) ----------------------------------------------------------------------

# MAJOR.MINOR.PATCH[-pre.release][+build] as its parts, or $null when the text is not one.
function ConvertFrom-SemVer([string]$Text) {
    # the regular expression of semver.org, with [0-9] for \d (which takes the digits of every script);
    # the same line is in Wslbin.Version.psm1 and in site/install.ps1 (a test sees that they are the same)
    $SemVerPattern = '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-((?:0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?\z'
    if (-not $Text) { return $null }
    # case-sensitive: -match ignores case, and then [a-z] takes the Kelvin sign as a k
    $m = [regex]::Match($Text, $SemVerPattern)
    if (-not $m.Success) { return $null }
    $pre = @()
    if ($m.Groups[4].Success) { $pre = @($m.Groups[4].Value -split '\.') }
    [pscustomobject]@{ Numbers = @($m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value); Pre = $pre }
}

# Digits as numbers of any size: the longer is the greater, and equal lengths compare as text.
function Compare-Digits([string]$A, [string]$B) {
    if ($A.Length -ne $B.Length) { return [Math]::Sign($A.Length - $B.Length) }
    [Math]::Sign([string]::CompareOrdinal($A, $B))
}

# -1, 0 or 1 as $A is lower than, equal to or higher than $B (build metadata after + counts for nothing;
# a version with a pre-release part is lower than the same one without it).
function Compare-SemVer([string]$A, [string]$B) {
    $x = ConvertFrom-SemVer $A
    $y = ConvertFrom-SemVer $B
    if (-not $x) { throw "'$A' is not a SemVer 2.0 version." }
    if (-not $y) { throw "'$B' is not a SemVer 2.0 version." }
    for ($i = 0; $i -lt 3; $i++) {
        $c = Compare-Digits $x.Numbers[$i] $y.Numbers[$i]
        if ($c -ne 0) { return $c }
    }
    if ($x.Pre.Count -eq 0 -and $y.Pre.Count -eq 0) { return 0 }
    if ($x.Pre.Count -eq 0) { return 1 }
    if ($y.Pre.Count -eq 0) { return -1 }
    $n = [Math]::Min($x.Pre.Count, $y.Pre.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $p = $x.Pre[$i]; $q = $y.Pre[$i]
        $pNum = $p -match '^[0-9]+\z'; $qNum = $q -match '^[0-9]+\z'
        if ($pNum -and $qNum) { $c = Compare-Digits $p $q }
        elseif ($pNum) { $c = -1 }
        elseif ($qNum) { $c = 1 }
        else { $c = [Math]::Sign([string]::CompareOrdinal($p, $q)) }
        if ($c -ne 0) { return $c }
    }
    [Math]::Sign($x.Pre.Count - $y.Pre.Count)
}

# ---- the package --------------------------------------------------------------------------------

# Whether a path that a manifest names stays inside its folder: not rooted, no drive, no "..", no "//".
function Test-PackagePath([string]$Relative) {
    $Relative -and $Relative -notmatch '^[\\/]|:|(^|[\\/])\.\.([\\/]|$)|[\\/]{2}'
}

# manifest.json of a package folder, checked: the version, and every file named in it present with its
# SHA256. Returns the version, the relative paths (with \), the SHA256 of each and the SHA256 of the
# bytes of manifest.json that were read. Nothing is installed from a file that the manifest does not
# name, and a path that leaves the folder is refused.
function Read-Manifest([string]$PackageDir) {
    $path = Join-Path $PackageDir 'manifest.json'
    if (-not (Test-Path -LiteralPath $path)) { throw "$PackageDir holds no manifest.json: this is not a wslbin package." }
    $bytes = [IO.File]::ReadAllBytes($path)
    $manifest = (ConvertFrom-Utf8Bytes $path $bytes).Text | ConvertFrom-Json
    if ($manifest.schema -ne 1) { throw "manifest.json has schema '$($manifest.schema)'; this installer reads schema 1." }
    if (-not (ConvertFrom-SemVer ([string]$manifest.version))) { throw "manifest.json has no valid version ('$($manifest.version)')." }
    $files = New-Object System.Collections.Generic.List[string]
    $hashes = @{}
    foreach ($entry in @($manifest.files)) {
        $relative = [string]$entry.path
        if (-not (Test-PackagePath $relative)) { throw "manifest.json names a path that is not inside the package: '$relative'." }
        $file = Join-Path $PackageDir $relative
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "manifest.json names $relative, and it is not in the package." }
        if ([string]$entry.sha256 -notmatch '^[0-9A-Fa-f]{64}\z') { throw "manifest.json has no SHA256 for $relative." }
        Test-FileHash $file ([string]$entry.sha256)
        $relative = $relative.Replace('/', '\')
        $files.Add($relative)
        $hashes[$relative] = ([string]$entry.sha256).ToLowerInvariant()
    }
    if ($files -notcontains 'wslbin.exe') { throw 'manifest.json does not name wslbin.exe.' }
    @{ Version = [string]$manifest.version; Files = $files.ToArray(); Hashes = $hashes; ManifestHash = (Get-BytesHash $bytes) }
}

# The files of a package for Get-ElevatedCommand, with the SHA256 values that Read-Manifest checked
# (manifest.json with the one of the bytes it read), not with hashes made again later.
function Get-PackageFilesToCheck([string]$PackageDir, $Manifest) {
    foreach ($relative in $Manifest.Files) {
        [pscustomobject]@{ Source = (Join-Path $PackageDir $relative); Path = $relative; Sha256 = $Manifest.Hashes[$relative] }
    }
    [pscustomobject]@{ Source = (Join-Path $PackageDir 'manifest.json'); Path = 'manifest.json'; Sha256 = $Manifest.ManifestHash }
}

# What manifest.json in $Dir says: {Version; Files} with the files relative (with \), or $null when there
# is no manifest that can be read.
function Read-InstalledManifest([string]$Dir) {
    $path = Join-Path $Dir 'manifest.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $manifest = (Read-Utf8Text $path).Text | ConvertFrom-Json
        $files = @(foreach ($entry in @($manifest.files)) {
                $relative = [string]$entry.path
                if (Test-PackagePath $relative) { $relative.Replace('/', '\') }
            })
        # a manifest.json of another program (in a folder that is not wslbin's own) names its files, which
        # are not wslbin's to delete
        if ($manifest.schema -ne 1 -or $files -notcontains 'wslbin.exe') { return $null }
        [pscustomobject]@{ Version = [string]$manifest.version; Files = $files }
    }
    catch { $null }
}

# Refuses to install into a folder that holds files with the names of wslbin's ($Files, relative) and is
# not an installation of wslbin (no manifest.json of wslbin, no wslbin.exe or wrapper that is wslbin): they
# belong to something else, which the install would overwrite and the uninstall delete. wslbin.exe itself
# is wslbin's by its name: in a folder whose install was cut short it is replaced.
function Assert-FolderIsOurs([string]$Dir, [string[]]$Files) {
    if (Read-InstalledManifest $Dir) { return }
    if (Test-WrapperFile (Join-Path $Dir 'wslbin.exe')) { return }
    if (@(Get-WrapperNames $Dir).Count -gt 0) { return }
    foreach ($relative in $Files) {
        if ($relative -eq 'wslbin.exe') { continue }
        if (Test-Path -LiteralPath (Join-Path $Dir $relative)) {
            throw "$Dir holds $relative, which is not wslbin's: install into a folder of its own. Nothing was installed."
        }
    }
}

# The files that an installation in $Dir consists of, relative: what its manifest.json names (when it
# can be read), and the files of every package so far.
function Get-InstalledFiles([string]$Dir) {
    $files = @('wslbin.exe', 'LICENSE', 'manifest.json', 'setup\install.ps1', 'setup\uninstall.ps1', 'setup\common.ps1')
    $manifest = Read-InstalledManifest $Dir
    if ($manifest) { $files += $manifest.Files }
    @($files | Select-Object -Unique)
}

# ---- the entry in "Apps" ------------------------------------------------------------------------

function Get-UninstallKeyPath {
    # $UninstallKey is a parameter of the scripts, for the tests: a key of their own instead of the real one
    if ($UninstallKey) { return $UninstallKey }
    'Software\Microsoft\Windows\CurrentVersion\Uninstall\wslbin'
}

function Get-UninstallHive([string]$ForScope) {
    if ($ForScope -eq 'AllUsers') { return [Microsoft.Win32.Registry]::LocalMachine }
    [Microsoft.Win32.Registry]::CurrentUser
}

# DisplayVersion, InstallLocation and whether the installer added the folder to PATH, or $null when there
# is no entry.
function Get-UninstallEntry($Hive) {
    $key = $Hive.OpenSubKey((Get-UninstallKeyPath))
    if (-not $key) { return $null }
    try {
        [pscustomobject]@{
            Version   = [string]$key.GetValue('DisplayVersion', '')
            Location  = [string]$key.GetValue('InstallLocation', '')
            PathAdded = ([int]$key.GetValue('PathEntryAdded', 0)) -eq 1
        }
    }
    finally { $key.Close() }
}

# The entry for Settings > Apps. EstimatedSize counts the files of wslbin ($Files: full paths), not what
# else is in the folder. PathEntryAdded says whether the installer put the folder into PATH, so that
# the uninstall does not take out an entry that was there before.
function Set-UninstallEntry($Hive, [string]$Dir, [string]$Version, [string[]]$Files, [bool]$PathAdded) {
    $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $script = Join-Path $Dir 'setup\uninstall.ps1'
    $command = '"' + $shell + '" -NoProfile -ExecutionPolicy Bypass -File "' + $script + '"'
    $bytes = [long]0
    foreach ($file in $Files) {
        if (Test-Path -LiteralPath $file -PathType Leaf) { $bytes += (Get-Item -LiteralPath $file -Force).Length }
    }
    $values = [ordered]@{
        DisplayName          = 'wslbin'
        DisplayVersion       = $Version
        Publisher            = 'Dmitriy Khudnitskiy'
        InstallLocation      = $Dir
        DisplayIcon          = (Join-Path $Dir 'wslbin.exe')
        UninstallString      = $command
        QuietUninstallString = $command + ' -Quiet'
        InstallDate          = (Get-Date).ToString('yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture)
        URLInfoAbout         = 'https://github.com/quatrebi/wslbin'
        HelpLink             = 'https://github.com/quatrebi/wslbin/issues'
    }
    $key = $Hive.CreateSubKey((Get-UninstallKeyPath))
    try {
        foreach ($name in $values.Keys) { $key.SetValue($name, [string]$values[$name], [Microsoft.Win32.RegistryValueKind]::String) }
        $key.SetValue('EstimatedSize', [int][Math]::Ceiling($bytes / 1KB), [Microsoft.Win32.RegistryValueKind]::DWord)
        $key.SetValue('NoModify', 1, [Microsoft.Win32.RegistryValueKind]::DWord)
        $key.SetValue('NoRepair', 1, [Microsoft.Win32.RegistryValueKind]::DWord)
        $key.SetValue('PathEntryAdded', [int]$PathAdded, [Microsoft.Win32.RegistryValueKind]::DWord)
    }
    finally { $key.Close() }
}

# Deletes the entry, when it is the one of this folder. Returns whether it was there. Only a key that is
# an entry of wslbin (its DisplayName says so) is deleted, with all that is under it: -UninstallKey names
# any key.
function Remove-UninstallEntry($Hive, [string]$Dir) {
    $entry = Get-UninstallEntry $Hive
    if (-not $entry) { return $false }
    if ($entry.Location -and (ConvertTo-ComparablePath $entry.Location) -ne (ConvertTo-ComparablePath $Dir)) { return $false }
    $key = $Hive.OpenSubKey((Get-UninstallKeyPath))
    try { $name = [string]$key.GetValue('DisplayName', '') }
    finally { $key.Close() }
    if ($name -cne 'wslbin') { return $false }
    $Hive.DeleteSubKeyTree((Get-UninstallKeyPath), $false)
    $true
}

# The installation of the other scope than $ForScope, when its entry names another folder that holds
# wslbin.exe: {Scope; Version; Location}, or $null. Windows puts the PATH of the machine in front of the
# PATH of the user, so of two installations the one for all users is the one that runs.
function Get-OtherInstallation([string]$ForScope, [string]$Dir) {
    $other = $(if ($ForScope -eq 'AllUsers') { 'CurrentUser' } else { 'AllUsers' })
    $entry = Get-UninstallEntry (Get-UninstallHive $other)
    if (-not $entry -or -not $entry.Location) { return $null }
    if ((ConvertTo-ComparablePath $entry.Location) -eq (ConvertTo-ComparablePath $Dir)) { return $null }
    if (-not (Test-Path -LiteralPath (Join-Path $entry.Location 'wslbin.exe'))) { return $null }
    [pscustomobject]@{ Scope = $other; Version = $entry.Version; Location = $entry.Location }
}

function Write-OtherInstallation($Other) {
    $remove = "Settings > Apps > wslbin, or $(Join-Path $Other.Location 'setup\uninstall.ps1')"
    if ($Other.Scope -eq 'AllUsers') {
        Write-Problem "wslbin $($Other.Version) is installed for all users as well, in $($Other.Location). Windows puts the PATH of the machine first, so wslbin and the wrappers there are the ones that run, not this copy. Update that one instead (-Scope AllUsers), or remove it: $remove."
    }
    else {
        Write-Problem "wslbin $($Other.Version) is installed for the current user as well, in $($Other.Location). This copy for all users comes first in PATH and is the one that runs; remove the other: $remove."
    }
}

# ---- laying files out ---------------------------------------------------------------------------

# Files of wslbin ($Names, relative to $Dir) that an earlier run set aside as <name>.old, or as
# <name>.<32 hex digits>.old when <name>.old was still held, and could not delete then (a program that runs
# cannot be overwritten or deleted, but it can be renamed). Only those: the folder may hold files of the
# user's that end in .old.
function Remove-AsideFiles([string]$Dir, [string[]]$Names) {
    $listed = @{}
    foreach ($name in $Names) {
        $target = Join-Path $Dir $name
        $parent = Split-Path -Parent $target
        if (-not $listed.ContainsKey($parent)) {
            $listed[$parent] = @()
            if (Test-Path -LiteralPath $parent -PathType Container) { $listed[$parent] = @(Get-ChildItem -LiteralPath $parent -Filter '*.old' -File -Force -ErrorAction SilentlyContinue) }
        }
        $pattern = '^' + [regex]::Escape((Split-Path -Leaf $target)) + '\.(?:[0-9a-f]{32}\.)?old\z'
        foreach ($file in $listed[$parent]) {
            if ([regex]::IsMatch($file.Name, $pattern, 'IgnoreCase')) { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue }
        }
    }
}

# Puts the files of a package into $Dir, and a copy of wslbin.exe under each name of $Wrappers, so that
# either everything is replaced or nothing is: each new file is written beside its target first, then every
# target is renamed to <name>.old and the new file to the name. A program that runs holds its file, but a
# renamed file is no trouble to it. Returns what Undo-Placement and Complete-Placement take.
function Install-Files([string]$PackageDir, [string[]]$Files, [string[]]$Wrappers, [string]$Dir) {
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($relative in $Files) {
        $items.Add(@{ Target = (Join-Path $Dir $relative); Source = (Join-Path $PackageDir $relative) })
    }
    foreach ($name in $Wrappers) {
        $items.Add(@{ Target = (Join-Path $Dir "$name.exe"); Source = (Join-Path $PackageDir 'wslbin.exe') })
    }
    Remove-AsideFiles $Dir (@($Files) + @($Wrappers | ForEach-Object { "$_.exe" }))
    $staged = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($item in $items) {
            $parent = Split-Path -Parent $item.Target
            if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null }
            $item.New = $item.Target + '.new'
            Copy-Item -LiteralPath $item.Source -Destination $item.New -Force -ErrorAction Stop
            $staged.Add($item.New)
        }
    }
    catch {
        foreach ($file in $staged) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
        throw
    }
    $done = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($item in $items) {
            $aside = $item.Target + '.old'
            # still held by a program since the update before: a name of its own, deleted at a later run
            if (Test-Path -LiteralPath $aside) { $aside = $item.Target + '.' + [guid]::NewGuid().ToString('N') + '.old' }
            $item.Aside = $null
            if (Test-Path -LiteralPath $item.Target) {
                Move-Item -LiteralPath $item.Target -Destination $aside -Force -ErrorAction Stop
                $item.Aside = $aside
            }
            $done.Add($item)
            Move-Item -LiteralPath $item.New -Destination $item.Target -Force -ErrorAction Stop
        }
    }
    catch {
        $reason = $_.Exception.Message
        Undo-Placement ([pscustomobject]@{ Done = $done.ToArray(); Items = $items.ToArray() })
        throw "Could not replace the files in ${Dir}: $reason Close the programs that use them (a terminal that runs a wrapper?) and run this again."
    }
    [pscustomobject]@{ Done = $done.ToArray(); Items = $items.ToArray() }
}

# Takes the old files back and removes the new ones.
function Undo-Placement($Placement) {
    foreach ($item in $Placement.Items) { Remove-Item -LiteralPath $item.New -Force -ErrorAction SilentlyContinue }
    foreach ($item in $Placement.Done) {
        if ($item.Aside) {
            Remove-Item -LiteralPath $item.Target -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $item.Aside) { Move-Item -LiteralPath $item.Aside -Destination $item.Target -Force -ErrorAction SilentlyContinue }
        }
        else { Remove-Item -LiteralPath $item.Target -Force -ErrorAction SilentlyContinue }
    }
}

# The new files stay: the old ones are deleted, as far as they can be (the rest goes at the next run).
function Complete-Placement($Placement) {
    foreach ($item in $Placement.Done) {
        if ($item.Aside) { Remove-Item -LiteralPath $item.Aside -Force -ErrorAction SilentlyContinue }
    }
}
