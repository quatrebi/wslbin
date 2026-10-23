<#
.SYNOPSIS
    Installs wslbin: compiles it from source with the C# compiler that comes with Windows.

.DESCRIPTION
    No program is downloaded, only the source of a release; it is checked against a SHA256 and
    built on this machine, so the code can be read before it runs. Works in Windows PowerShell 5.1
    and in PowerShell 7. Needs nothing but Windows and WSL.

      1. gets the source: a folder or a .zip given as -Source, or the release -Version of
         -Repository (checked against -Sha256, or against SHA256SUMS.txt of the release);
      2. builds wslbin.exe in a temporary folder (build.ps1);
      3. copies it into the install folder, keeping wslbin.ini, and refreshes the wrappers
         that are already there;
      4. adds the folder to PATH (not with -NoPath);
      5. with -Link makes wrappers; with -Completion hooks Tab completion into the shells.

    Where it goes: -Scope AllUsers is C:\Program Files\wslbin and the PATH of the machine (asks for
    administrator rights, UAC); -Scope CurrentUser is %LOCALAPPDATA%\Programs\wslbin and the PATH
    of the user. Auto (the default) tries AllUsers and, if the rights are refused, takes
    CurrentUser. -InstallDir names another folder.

    -Uninstall takes all of it out again: wrappers, the folder (wslbin.ini stays if there is one),
    the PATH entry, the blocks in the PowerShell profiles and the Clink script.

    The exit code is 0, or 1 when something went wrong that did not stop the install (a profile
    that is not UTF-8 text and was left alone, a wrapper that could not be made).

.EXAMPLE
    .\install.ps1 -Source C:\src\wslbin -Link make,rsync,dig -Completion pwsh,clink

.EXAMPLE
    .\install.ps1 -Version v0.1.0 -Sha256 <hash of wslbin-v0.1.0-source.zip> -Scope AllUsers

.EXAMPLE
    .\install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [ValidateSet('Auto', 'AllUsers', 'CurrentUser')]
    [string]$Scope = 'Auto',
    [string]$InstallDir,
    # a folder with the source (a checkout), or a .zip of it
    [string]$Source,
    # the tag of a release to download, e.g. v0.1.0
    [string]$Version,
    # owner/name of the repository on GitHub that the release comes from
    [string]$Repository = 'quatrebi/wslbin',
    # expected SHA256 of the source .zip (a download; also checked for a .zip given as -Source)
    [string]$Sha256,
    # utilities to make wrappers for after the install
    [string[]]$Link = @(),
    # shells to hook Tab completion into: pwsh (both PowerShells) and clink (cmd)
    [string[]]$Completion = @(),
    [switch]$NoPath,
    [switch]$Uninstall,
    # folder that holds WindowsPowerShell\ and PowerShell\ with the profiles (default: Documents)
    [string]$ProfileRoot,
    # folder for the Clink script (default: the one that Clink names)
    [string]$ClinkDir,
    # internal: this is the copy that asks for the rights
    [switch]$Elevated,
    # internal: where that copy also writes what it says (its window closes when it ends)
    [string]$ElevatedLog
)

$ErrorActionPreference = 'Stop'

$BeginMark = '# >>> wslbin >>>'
$EndMark = '# <<< wslbin <<<'

# Everything the script says goes through these two. The copy with administrator rights writes it into
# -ElevatedLog as well, and the copy that started it shows the file afterwards.
function Write-Line([string]$Text) {
    Write-Host $Text
    if ($ElevatedLog) { Add-Content -LiteralPath $ElevatedLog -Value $Text -Encoding UTF8 }
}
function Write-Problem([string]$Text) {
    Write-Warning $Text
    if ($ElevatedLog) { Add-Content -LiteralPath $ElevatedLog -Value "WARNING: $Text" -Encoding UTF8 }
}

function Write-Step([string]$Text) { Write-Line "wslbin install: $Text" }

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
# end up in PATH and in the profiles, and an elevated copy of this script starts somewhere else.
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

# Tells running programs (Explorer, new terminals) that the environment has changed.
function Send-EnvironmentChange {
    if (-not ('Wslbin.NativeMethods' -as [type])) {
        Add-Type -Namespace Wslbin -Name NativeMethods -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint msg, System.UIntPtr wParam, string lParam, uint flags, uint timeout, out System.UIntPtr result);
'@
    }
    $result = [UIntPtr]::Zero
    [void][Wslbin.NativeMethods]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result)
}

# ---- profile blocks -----------------------------------------------------------------------------

# The text of a file that must be UTF-8 (with or without a byte order mark). Anything else is refused:
# a profile that is saved as ANSI or UTF-16 would come back damaged if it were decoded and written as UTF-8.
function Read-Utf8Text([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $skip = $(if ($hasBom) { 3 } else { 0 })
    $text = $null
    try { $text = (New-Object Text.UTF8Encoding($false, $true)).GetString($bytes, $skip, $bytes.Length - $skip) } catch { }
    # UTF-16 without a mark is valid UTF-8 with a NUL between the letters
    if ($null -eq $text -or $text.IndexOf([char]0) -ge 0) {
        throw "$Path is not UTF-8 text (is it ANSI or UTF-16?): left alone. Save it as UTF-8, or put the block in by hand."
    }
    @{ Text = $text; Bom = $hasBom }
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
    $block = ($BeginMark + ' (written by install.ps1; install.ps1 -Uninstall takes it out)' + "`n" + $Body.Trim() + "`n" + $EndMark + "`n").Replace("`n", $newline)

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
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
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

# ---- source -------------------------------------------------------------------------------------

function Test-FileHash([string]$Path, [string]$Expected) {
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($actual -ne $Expected.Trim().ToUpperInvariant()) {
        throw "The SHA256 of $Path is $actual, not $($Expected.Trim().ToUpperInvariant()). Nothing was built."
    }
}

# A folder with src\wslbin.cs in it: the one given, or what a .zip holds (also inside one folder).
function Resolve-SourceRoot([string]$Path) {
    if (Test-Path -LiteralPath (Join-Path $Path 'src\wslbin.cs')) { return $Path }
    foreach ($sub in Get-ChildItem -LiteralPath $Path -Directory) {
        if (Test-Path -LiteralPath (Join-Path $sub.FullName 'src\wslbin.cs')) { return $sub.FullName }
    }
    throw "$Path holds no src\wslbin.cs: this is not the source of wslbin."
}

function Get-SourceRoot([string]$WorkFolder) {
    if ($Source) {
        if (-not (Test-Path -LiteralPath $Source)) { throw "-Source $Source does not exist." }
        if ((Get-Item -LiteralPath $Source).PSIsContainer) {
            if ($Sha256) { throw '-Sha256 checks a .zip; a folder cannot be checked against it.' }
            return Resolve-SourceRoot $Source
        }
        if ($Sha256) { Test-FileHash $Source $Sha256 }
        $zip = $Source
    }
    else {
        if (-not $Version) { throw 'Name what to install: -Source <folder or .zip> or -Version <tag>.' }
        # both end up in a URL: nothing but what GitHub allows in them
        if ($Repository -notmatch '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$') { throw "-Repository must look like <owner>/<name>, e.g. quatrebi/wslbin; got '$Repository'." }
        if ($Version -notmatch '^[A-Za-z0-9._+-]+$') { throw "-Version must be the name of a tag, e.g. v0.1.0; got '$Version'." }
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $base = "https://github.com/$Repository/releases/download/$Version"
        $zip = Join-Path $WorkFolder "wslbin-$Version-source.zip"
        Write-Step "downloading $base/wslbin-$Version-source.zip"
        Invoke-WebRequest -Uri "$base/wslbin-$Version-source.zip" -OutFile $zip -UseBasicParsing
        $expected = $Sha256
        if (-not $expected) {
            # the hash of the same release: this guards against a damaged download, not against a changed
            # release. Pin the hash with -Sha256 where that matters.
            $sums = (Invoke-WebRequest -Uri "$base/SHA256SUMS.txt" -UseBasicParsing).Content
            if ($sums -is [byte[]]) { $sums = [Text.Encoding]::UTF8.GetString($sums) }
            foreach ($line in $sums -split "`n") {
                if ($line -match '^\s*([0-9A-Fa-f]{64})\s+\*?(\S+)\s*$' -and $Matches[2] -eq "wslbin-$Version-source.zip") { $expected = $Matches[1] }
            }
            if (-not $expected) { throw "SHA256SUMS.txt of $Version has no line for wslbin-$Version-source.zip." }
        }
        Test-FileHash $zip $expected
    }
    $target = Join-Path $WorkFolder 'source'
    Expand-Archive -LiteralPath $zip -DestinationPath $target -Force
    Resolve-SourceRoot $target
}

# ---- elevation ----------------------------------------------------------------------------------

# The command line of the copy of this script that runs with administrator rights: the parameters as
# they are now (full paths, quoted), the scope it is to install for, and -Elevated.
function Get-ElevatedArgumentLine([string]$ScopeValue, [string]$LogFile) {
    $arguments = New-Object System.Collections.Generic.List[string]
    $arguments.Add('-NoProfile'); $arguments.Add('-ExecutionPolicy'); $arguments.Add('Bypass')
    $arguments.Add('-File'); $arguments.Add((ConvertTo-CommandLineArgument $PSCommandPath))
    foreach ($key in $script:BoundParameters.Keys) {
        if ($key -in 'Scope', 'Elevated', 'ElevatedLog') { continue }
        $value = Get-Variable -Name $key -ValueOnly
        if ($value -is [switch]) { if ($value.IsPresent) { $arguments.Add("-$key") } }
        elseif ($value -is [array]) { $arguments.Add("-$key"); $arguments.Add((ConvertTo-CommandLineArgument ($value -join ','))) }
        else { $arguments.Add("-$key"); $arguments.Add((ConvertTo-CommandLineArgument ([string]$value))) }
    }
    if ($ScopeValue) { $arguments.Add('-Scope'); $arguments.Add($ScopeValue) }
    if ($LogFile) { $arguments.Add('-ElevatedLog'); $arguments.Add((ConvertTo-CommandLineArgument $LogFile)) }
    $arguments.Add('-Elevated')
    $arguments.ToArray() -join ' '
}

# Starts this script again with administrator rights and the same arguments (as they are now: full
# paths), shows what that copy said in its window (which has closed by then), and returns its exit
# code: 0 done, 1 done with problems, 2 failed; $null when the rights were refused. $ScopeValue is what
# the copy is to install for (the scope that was asked for, or the one that Auto chose).
function Invoke-Elevated([string]$ScopeValue) {
    # for scripts and tests: never put the UAC question on the screen
    if ($env:WSLBIN_NO_ELEVATION -eq '1') { return $null }
    $shell = (Get-Process -Id $PID).Path
    $log = Join-Path ([IO.Path]::GetTempPath()) ('wslbin-elevated-' + [guid]::NewGuid().ToString('N') + '.log')
    try {
        $process = Start-Process -FilePath $shell -ArgumentList (Get-ElevatedArgumentLine $ScopeValue $log) -Verb RunAs -Wait -PassThru -WorkingDirectory (Get-Location -PSProvider FileSystem).ProviderPath
    }
    catch {
        return $null
    }
    if (Test-Path -LiteralPath $log) {
        foreach ($line in Get-Content -LiteralPath $log -Encoding UTF8) { Write-Host "  (administrator) $line" }
        Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    }
    $process.ExitCode
}

# ---- the work -----------------------------------------------------------------------------------
#
# The work is in two parts. What belongs to the machine (the program in its folder, the PATH of the
# machine, the wrappers there) is done by the copy with administrator rights when the install is for
# all users. What belongs to the user who runs this (wrappers for -Link, which ask that user's WSL and
# its apt; the hooks in that user's profiles; the Clink script; the instructions of the AI agents) is
# always done here, without those rights: with another account's password at the UAC prompt, the copy
# with rights runs as that account and would change its profiles and its WSL instead.

# A PowerShell string literal of a path that reads the same in any code page: Windows PowerShell 5.1
# reads a profile without a byte order mark as ANSI, so letters outside ASCII are written as [char]
# codes (as "wslbin --init pwsh" does for the code it prints).
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
    @($folders | Select-Object -Unique)
}

# Builds wslbin.exe, puts it into $script:Dir, brings the wrappers there up to date and adds the folder
# to PATH: the part that belongs to the machine.
function Install-Program {
    $workFolder = Join-Path ([IO.Path]::GetTempPath()) ('wslbin-install-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $workFolder | Out-Null
    try {
        $root = Get-SourceRoot $workFolder
        Write-Step "building from $root"
        $built = Join-Path $workFolder 'bin\wslbin.exe'
        & (Join-Path $root 'build.ps1') -Output $built 6>$null
        if (-not (Test-Path -LiteralPath $built)) { throw 'The build produced no wslbin.exe.' }
        $version = (Invoke-Native $built @('--version')).Out | Select-Object -First 1
        Write-Step "built $version"

        if (-not (Test-Path -LiteralPath $script:Dir)) { New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null }
        $target = Join-Path $script:Dir 'wslbin.exe'
        try {
            Copy-Item -LiteralPath $built -Destination $target -Force
        }
        catch [System.IO.IOException] {
            throw "Could not replace ${target}: a program is using it (a terminal that runs a wrapper?). Close it and run this again."
        }
        Write-Step "installed $target"
    }
    finally {
        Remove-Item -LiteralPath $workFolder -Recurse -Force -ErrorAction SilentlyContinue
    }
    $exe = Join-Path $script:Dir 'wslbin.exe'

    # wrappers that were made by an earlier version are copies of it: bring them up to date
    $existing = @((Invoke-Native $exe @('--list', '--names')).Out | Where-Object { $_ })
    if ($existing.Count -gt 0) {
        Write-Step "refreshing $($existing.Count) wrapper(s)"
        Invoke-WslbinStep $exe @('--link')
    }

    if (-not $NoPath) {
        $location = Get-PathLocation $script:EffectiveScope
        if (Set-PathEntry -Hive $location.Hive -SubKey $location.SubKey -Entry $script:Dir) {
            Send-EnvironmentChange
            Write-Step "added $($script:Dir) to the $($script:EffectiveScope) PATH (new terminals see it)"
        }
        else { Write-Step "$($script:Dir) is in the PATH already" }
    }
}

# -Link and -Completion: the part that belongs to the user (see above).
function Install-UserParts {
    $exe = Join-Path $script:Dir 'wslbin.exe'
    if ($Link.Count -gt 0) {
        Write-Step "wrappers: $($Link -join ', ')"
        Invoke-WslbinStep $exe (@('--link') + $Link)
    }

    if ($Completion -contains 'pwsh') {
        $literal = ConvertTo-PowerShellLiteral $exe
        $body = "if (Test-Path -LiteralPath $literal) { & $literal --init pwsh | Invoke-Expression }"
        foreach ($profilePath in Get-ProfilePaths) {
            try {
                Set-MarkedBlock $profilePath $body
                Write-Step "Tab completion hooked into $profilePath"
            }
            catch {
                Write-Problem $_.Exception.Message
                $script:Problems++
            }
        }
    }
    if ($Completion -contains 'clink') {
        if ($ClinkDir) { Invoke-WslbinStep $exe @('--init', 'clink', '--dir', $ClinkDir) } else { Invoke-WslbinStep $exe @('--init', 'clink') }
    }
}

function Write-Summary {
    if ($script:Problems -gt 0) { Write-Step "finished, with $($script:Problems) problem(s) (see the warnings above)" }
    else { Write-Step "done. Check it with: wslbin --doctor    (a new terminal sees the PATH)" }
}

# The copy with administrator rights has installed the program for all users (exit code 0, or 1 for a
# problem that did not stop it): the user's own part follows here. Ends the script.
function Complete-AfterElevation([int]$Code) {
    $script:EffectiveScope = 'AllUsers'
    $script:Dir = $InstallDir
    if (-not $script:Dir) { $script:Dir = Get-DefaultInstallDir 'AllUsers' }
    if ($Code -ne 0 -and $Code -ne 1) {
        # an old wslbin.exe may still be there: the user's part is not done with it
        Write-Problem "The copy with administrator rights failed (exit code $Code, its messages are above); nothing more was done."
        exit $Code
    }
    if ($Code -ne 0) { $script:Problems++ }
    Install-UserParts
    Write-Summary
    if ($script:Problems -gt 0) { exit 1 }
    exit 0
}

# One installation: its wrappers, its PATH entry, wslbin.exe, and the folder when nothing of the user's
# is left in it.
function Remove-Installation([string]$Dir) {
    $exe = Join-Path $Dir 'wslbin.exe'
    Write-Step "removing wrappers in $Dir"
    Invoke-WslbinStep $exe @('--unlink', '--all')
    foreach ($forScope in 'AllUsers', 'CurrentUser') {
        if ($NoPath) { break }
        if ($forScope -eq 'AllUsers' -and -not (Test-Administrator)) { continue }
        $location = Get-PathLocation $forScope
        if (Set-PathEntry -Hive $location.Hive -SubKey $location.SubKey -Entry $Dir -Remove) {
            Send-EnvironmentChange
            Write-Step "took $Dir out of the $forScope PATH"
        }
    }
    try {
        Remove-Item -LiteralPath $exe -Force -ErrorAction Stop
    }
    catch {
        # a terminal that runs a wrapper or wslbin itself: the rest of the uninstall still goes on
        Write-Problem "Could not remove ${exe}: $($_.Exception.Message) Close the programs that use it and run this again."
        $script:Problems++
        return
    }
    if (Test-Path -LiteralPath (Join-Path $Dir 'wslbin.ini')) { Write-Step "kept $(Join-Path $Dir 'wslbin.ini') (your settings)" }
    elseif (-not (Get-ChildItem -LiteralPath $Dir -Force)) { Remove-Item -LiteralPath $Dir -Force }
}

function Uninstall-Wslbin {
    # the installations to remove: the folder named, or the two usual places; and which need the rights
    $machineDir = Get-DefaultInstallDir 'AllUsers'
    $candidates = @()
    if ($InstallDir) { $candidates += $InstallDir } else { $candidates += $machineDir; $candidates += (Get-DefaultInstallDir 'CurrentUser') }
    $targets = @($candidates | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'wslbin.exe') })
    $machine = @($targets | Where-Object { $_.StartsWith($env:ProgramFiles, [StringComparison]::OrdinalIgnoreCase) })
    $user = @($targets | Where-Object { $machine -notcontains $_ })

    if ($Elevated) {
        foreach ($dir in $machine) { Remove-Installation $dir }
        return
    }
    if ($targets.Count -eq 0) { Write-Step 'wslbin is not installed in the usual places (use -InstallDir if it is elsewhere)' }

    # The instructions of the AI agents say that wslbin is here; they go when the last installation
    # goes. A copy of wslbin.exe outside the folders that are removed does that at the end.
    $others = @(@($machineDir, (Get-DefaultInstallDir 'CurrentUser')) | Where-Object {
        $targets -notcontains $_ -and (Test-Path -LiteralPath (Join-Path $_ 'wslbin.exe')) })
    $helper = $null
    if ($targets.Count -gt 0 -and $others.Count -eq 0) {
        $helperFolder = Join-Path ([IO.Path]::GetTempPath()) ('wslbin-uninstall-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $helperFolder | Out-Null
        $helper = Join-Path $helperFolder 'wslbin.exe'
        Copy-Item -LiteralPath (Join-Path $targets[0] 'wslbin.exe') -Destination $helper
    }
    try {
        if ($machine.Count -gt 0 -and -not (Test-Administrator)) {
            Write-Step 'asking for administrator rights (UAC) to remove the installation for all users'
            $code = Invoke-Elevated $null
            if ($null -eq $code) { throw 'The administrator rights were refused: nothing was removed.' }
            if ($code -ne 0) { $script:Problems++ }
        }
        else {
            foreach ($dir in $machine) { Remove-Installation $dir }
        }
        foreach ($dir in $user) { Remove-Installation $dir }

        foreach ($profilePath in Get-ProfilePaths) {
            try {
                if (Remove-MarkedBlock $profilePath) { Write-Step "took the block out of $profilePath" }
            }
            catch {
                Write-Problem $_.Exception.Message
                $script:Problems++
            }
        }

        # the Clink script has a first line that says whose it is
        foreach ($folder in Get-ClinkScriptFolders) {
            $script = Join-Path $folder 'wslbin.lua'
            if ((Test-Path -LiteralPath $script) -and ((Get-Content -LiteralPath $script -TotalCount 1) -like '-- wslbin for cmd (Clink)*')) {
                Remove-Item -LiteralPath $script -Force
                Write-Step "removed $script"
            }
        }

        if ($helper) {
            $left = @($targets | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'wslbin.exe') })
            if ($left.Count -gt 0) { Write-Step "kept the block for AI agents: wslbin is still in $($left -join ', ')" }
            else { Invoke-WslbinStep $helper @('--install-ai-context', '--remove') }
        }
    }
    finally {
        if ($helper) { Remove-Item -LiteralPath (Split-Path -Parent $helper) -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# dot-sourced (by the tests): the functions are all that is wanted
if ($MyInvocation.InvocationName -eq '.') { return }

$script:BoundParameters = $PSBoundParameters
$InstallDir = ConvertTo-FullPath $InstallDir
$Source = ConvertTo-FullPath $Source
$ProfileRoot = ConvertTo-FullPath $ProfileRoot
$ClinkDir = ConvertTo-FullPath $ClinkDir
$Link = Split-List $Link
$Completion = Split-List $Completion
foreach ($shell in $Completion) {
    if ($shell -notin 'pwsh', 'clink') { throw "-Completion takes pwsh and clink, not '$shell'." }
}

# The copy with administrator rights does the machine's part only and ends with 0 (done), 1 (done, with
# problems) or 2 (failed): a script that stops on an error would end with 1 as well, and the copy that
# started this one must not go on as if the program were installed.
if ($Elevated) {
    try {
        if ($Uninstall) { Uninstall-Wslbin }
        else {
            $script:EffectiveScope = $(if ($Scope -eq 'Auto') { 'AllUsers' } else { $Scope })
            $script:Dir = $InstallDir
            if (-not $script:Dir) { $script:Dir = Get-DefaultInstallDir $script:EffectiveScope }
            Install-Program
        }
    }
    catch {
        Write-Problem $_.Exception.Message
        exit 2
    }
    if ($script:Problems -gt 0) { exit 1 }
    exit 0
}

if ($Uninstall) {
    Uninstall-Wslbin
    if ($script:Problems -gt 0) { exit 1 }
    return
}

# Which scope, which folder; and the rights that go with it.
$script:EffectiveScope = $Scope
if ($EffectiveScope -eq 'Auto') {
    if ($InstallDir) { $script:EffectiveScope = 'CurrentUser' }
    elseif (Test-Administrator) { $script:EffectiveScope = 'AllUsers' }
    else {
        Write-Step 'asking for administrator rights (UAC) to install for all users'
        $code = Invoke-Elevated 'AllUsers'
        if ($null -ne $code) { Complete-AfterElevation $code }
        Write-Problem 'The administrator rights were refused: installing for the current user instead.'
        $script:EffectiveScope = 'CurrentUser'
    }
}
elseif ($EffectiveScope -eq 'AllUsers' -and -not (Test-Administrator)) {
    $code = Invoke-Elevated 'AllUsers'
    if ($null -eq $code) { throw 'Installing for all users needs administrator rights, and they were refused.' }
    Complete-AfterElevation $code
}

$script:Dir = $InstallDir
if (-not $script:Dir) { $script:Dir = Get-DefaultInstallDir $script:EffectiveScope }
Install-Program
Install-UserParts
Write-Summary
if ($script:Problems -gt 0) { exit 1 }
