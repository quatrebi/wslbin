<#
.SYNOPSIS
    Removes wslbin: "Settings > Apps > wslbin > Uninstall" runs this script, and so can you.

.DESCRIPTION
    Takes out what install.ps1 put in: the wrappers (wslbin --unlink --all), the PATH entry (when the
    installer added it), wslbin.exe and the other files of the package, the entry in Settings > Apps, and
    the hooks: the blocks in the PowerShell profiles and the Clink script, unless they belong to an
    installation that is still there, and the block for AI agents when the last installation goes. Your
    wslbin.ini stays, unless -Purge. The script copies itself into a temporary folder and works from
    there, because it deletes the folder it is in.

    Which installation: -InstallDir; or the one this script is in; or the usual places (C:\Program
    Files\wslbin, %LOCALAPPDATA%\Programs\wslbin) and what the entries in Apps name. An installation for
    all users (its entry in Apps is the one of the machine) asks for administrator rights (UAC).

    The exit code is 0, or 1 when something could not be removed (a program that runs holds its file:
    close it and run this again), or 2 when it failed.

.EXAMPLE
    .\setup\uninstall.ps1 -Quiet
#>
[CmdletBinding()]
param(
    [string]$InstallDir,
    # no question, no waiting for a key
    [switch]$Quiet,
    # also delete wslbin.ini
    [switch]$Purge,
    [switch]$NoPath,
    # folder that holds WindowsPowerShell\ and PowerShell\ with the profiles (default: Documents)
    [string]$ProfileRoot,
    # folder where wslbin.lua of Clink is looked for (default: the ones that Clink names)
    [string]$ClinkDir,
    # a key of its own under HKCU or HKLM instead of ...\Uninstall\wslbin: for the tests
    [string]$UninstallKey,
    # internal: this is the copy that works from the temporary folder
    [switch]$FromTemp,
    # internal: this is the copy with administrator rights, which removes the installation -InstallDir
    # for all users and runs from a folder of checked files
    [switch]$Elevated
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

# Whether an installation is the one for all users or for the user: the entry in Apps that names its
# folder says so (an install for all users may be in any folder). A folder without an entry is the one
# for all users only when it is the usual place of that.
function Get-InstallationScope([string]$Dir) {
    $wanted = ConvertTo-ComparablePath $Dir
    foreach ($forScope in 'AllUsers', 'CurrentUser') {
        $entry = Get-UninstallEntry (Get-UninstallHive $forScope)
        if ($entry -and $entry.Location -and (ConvertTo-ComparablePath $entry.Location) -eq $wanted) { return $forScope }
    }
    if ((ConvertTo-ComparablePath (Get-DefaultInstallDir 'AllUsers')) -eq $wanted) { return 'AllUsers' }
    'CurrentUser'
}

# The folders that hold an installation: the usual places and what the entries in Apps name, and $More.
function Get-Installations([string[]]$More) {
    $candidates = @((Get-DefaultInstallDir 'AllUsers'), (Get-DefaultInstallDir 'CurrentUser')) + @($More)
    foreach ($forScope in 'AllUsers', 'CurrentUser') {
        $entry = Get-UninstallEntry (Get-UninstallHive $forScope)
        if ($entry -and $entry.Location) { $candidates += $entry.Location }
    }
    @(Select-UniquePath $candidates | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'wslbin.exe') })
}

# One installation: its wrappers, its PATH entry, its files, its entry in Apps, and the folder when
# nothing of the user's is left in it.
function Remove-Installation([string]$Dir, [string]$ForScope) {
    $exe = Join-Path $Dir 'wslbin.exe'
    # what to delete is known before anything is: manifest.json names the files
    $files = Get-InstalledFiles $Dir
    $wrappers = @()
    $list = Invoke-Native $exe @('--list', '--names')
    if ($list.ExitCode -eq 0) { $wrappers = @($list.Out | Where-Object { $_ } | ForEach-Object { "$_.exe" }) }
    Write-Step "removing wrappers in $Dir"
    Invoke-WslbinStep $exe @('--unlink', '--all')

    # PATH: only the scope of the installation, and only when the installer added the folder (it may have
    # been there before, for something else)
    $hive = Get-UninstallHive $ForScope
    $entry = Get-UninstallEntry $hive
    $ours = $entry -and (-not $entry.Location -or (ConvertTo-ComparablePath $entry.Location) -eq (ConvertTo-ComparablePath $Dir))
    if (-not $NoPath -and $ours -and $entry.PathAdded) {
        $location = Get-PathLocation $ForScope
        if (Set-PathEntry -Hive $location.Hive -SubKey $location.SubKey -Entry $Dir -Remove) {
            Send-EnvironmentChange
            Write-Step "took $Dir out of the $ForScope PATH"
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
    foreach ($relative in $files) {
        Remove-Item -LiteralPath (Join-Path $Dir $relative) -Force -ErrorAction SilentlyContinue
    }
    Remove-AsideFiles $Dir ($files + $wrappers)
    $setup = Join-Path $Dir 'setup'
    if ((Test-Path -LiteralPath $setup) -and -not (Get-ChildItem -LiteralPath $setup -Force)) { Remove-Item -LiteralPath $setup -Force }
    if (Remove-UninstallEntry $hive $Dir) { Write-Step 'removed the entry in Settings > Apps' }

    $ini = Join-Path $Dir 'wslbin.ini'
    if ((Test-Path -LiteralPath $ini) -and $Purge) { Remove-Item -LiteralPath $ini -Force }
    if (Test-Path -LiteralPath $ini) { Write-Step "kept $ini (your settings; -Purge deletes it)" }
    elseif (-not (Get-ChildItem -LiteralPath $Dir -Force)) { Remove-Item -LiteralPath $Dir -Force }
}

# The hooks in the profiles and the Clink script go, unless they belong to an installation that is still
# there ($Left): there is one of each, and it names the wslbin.exe that it runs.
function Remove-Hooks([string[]]$Left) {
    foreach ($profilePath in Get-ProfilePaths) {
        try {
            $block = Get-MarkedBlock $profilePath
            if ($null -eq $block) { continue }
            if (Test-HookNames $block $Left) { Write-Step "kept the block in ${profilePath}: it runs a wslbin that is still installed"; continue }
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
        $exe = Get-ClinkScriptExe $script
        if ($null -eq $exe) { continue }
        if (Test-HookNames $exe $Left -Clink) { Write-Step "kept ${script}: it runs a wslbin that is still installed"; continue }
        Remove-Item -LiteralPath $script -Force
        Write-Step "removed $script"
    }
}

function Uninstall-Wslbin {
    if ($Elevated) {
        if (-not $InstallDir) { throw 'The copy with administrator rights needs -InstallDir: the installation for all users to remove.' }
        Remove-Installation $InstallDir 'AllUsers'
        return
    }

    # the installations to remove: the folder named, or the one this script is in, or the usual places
    # and what the entries in Apps name; and which of them are for all users
    $all = Get-Installations @($InstallDir)
    $targets = $all
    if ($InstallDir) { $targets = @(Select-UniquePath @($InstallDir) | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'wslbin.exe') }) }
    $machine = @($targets | Where-Object { (Get-InstallationScope $_) -eq 'AllUsers' })
    $user = @($targets | Where-Object { $machine -notcontains $_ })
    if ($targets.Count -eq 0) { Write-Step 'wslbin is not installed in the usual places (use -InstallDir if it is elsewhere)' }

    # The instructions of the AI agents say that wslbin is here; they go when the last installation
    # goes. A copy of wslbin.exe outside the folders that are removed does that at the end.
    $others = @($all | Where-Object { $targets -notcontains $_ })
    $helper = $null
    if ($targets.Count -gt 0 -and $others.Count -eq 0) {
        $helperFolder = Join-Path ([IO.Path]::GetTempPath()) ('wslbin-uninstall-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $helperFolder | Out-Null
        $helper = Join-Path $helperFolder 'wslbin.exe'
        Copy-Item -LiteralPath (Join-Path $targets[0] 'wslbin.exe') -Destination $helper
    }
    try {
        foreach ($dir in $machine) {
            if (Test-Administrator) { Remove-Installation $dir 'AllUsers'; continue }
            Write-Step "asking for administrator rights (UAC) to remove the installation for all users in $dir"
            $files = @((Get-FileToCheck $script:EntryScript 'setup\uninstall.ps1'), (Get-FileToCheck (Join-Path $PSScriptRoot 'common.ps1') 'setup\common.ps1'))
            $arguments = @('-InstallDir', (ConvertTo-PowerShellLiteral $dir)) + (Get-ParameterTokens @('Purge', 'NoPath', 'UninstallKey') -PowerShell) + @('-Quiet', '-Elevated')
            $code = Invoke-Elevated $files 'setup\uninstall.ps1' $arguments
            if ($null -eq $code) { throw "The administrator rights were refused: the installation for all users in $dir was not removed." }
            if ($code -ne 0) {
                Write-Problem "The copy with administrator rights ended with exit code $code (its window said why)."
                $script:Problems++
            }
        }
        foreach ($dir in $user) { Remove-Installation $dir 'CurrentUser' }

        $left = @($all | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'wslbin.exe') })
        Remove-Hooks $left

        if ($helper) {
            if ($left.Count -gt 0) { Write-Step "kept the block for AI agents: wslbin is still in $($left -join ', ')" }
            else { Invoke-WslbinStep $helper @('--install-ai-context', '--remove') }
        }
    }
    finally {
        if ($helper) { Remove-Item -LiteralPath (Split-Path -Parent $helper) -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# The exit code at the end: 0, or 1 when something could not be removed.
function Complete-Uninstall {
    if ($script:Problems -gt 0) { return 1 }
    0
}

# dot-sourced (by the tests): the functions are all that is wanted
if ($MyInvocation.InvocationName -eq '.') { return }

$script:EntryScript = $PSCommandPath
$script:BoundParameters = $PSBoundParameters
$InstallDir = ConvertTo-FullPath $InstallDir
$ProfileRoot = ConvertTo-FullPath $ProfileRoot
$ClinkDir = ConvertTo-FullPath $ClinkDir

# This script is in the folder that it is to delete: it runs again from a temporary folder, and that
# copy removes the folder.
if (-not $FromTemp -and -not $Elevated) {
    $here = Split-Path -Parent $PSScriptRoot
    $dir = $InstallDir
    if (-not $dir -and (Test-Path -LiteralPath (Join-Path $here 'wslbin.exe'))) { $dir = $here }
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('wslbin-uninstall-script-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temp | Out-Null
    $code = 2
    try {
        Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $temp 'uninstall.ps1')
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'common.ps1') -Destination (Join-Path $temp 'common.ps1')
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (ConvertTo-CommandLineArgument (Join-Path $temp 'uninstall.ps1')))
        $arguments += Get-ParameterTokens @('Quiet', 'Purge', 'NoPath', 'ProfileRoot', 'ClinkDir', 'UninstallKey')
        if ($dir) { $arguments += '-InstallDir'; $arguments += (ConvertTo-CommandLineArgument $dir) }
        $arguments += '-FromTemp'
        $process = Start-Process -FilePath (Get-PowerShellPath) -ArgumentList ($arguments -join ' ') -Wait -PassThru -NoNewWindow
        $code = $process.ExitCode
    }
    finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
    exit $code
}

if (-not $Quiet -and -not $Elevated -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
    $choice = $Host.UI.PromptForChoice('wslbin', 'Remove wslbin (its wrappers, PATH entry, files and hooks in the profiles)?',
        @((New-Object Management.Automation.Host.ChoiceDescription '&Yes'), (New-Object Management.Automation.Host.ChoiceDescription '&No')), 1)
    if ($choice -ne 0) { Write-Step 'nothing was removed'; exit 0 }
}
try { Uninstall-Wslbin }
catch {
    Write-Problem $_.Exception.Message
    exit 2
}
exit (Complete-Uninstall)
