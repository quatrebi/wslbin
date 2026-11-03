<#
.SYNOPSIS
    Removes wslbin: "Settings > Apps > wslbin > Uninstall" runs this script, and so can you.

.DESCRIPTION
    Takes out what install.ps1 put in: the wrappers (the copies of wslbin.exe), the PATH entry (when the
    installer added it), wslbin.exe and the other files of the package, the entry in Settings > Apps, and
    the hooks: the blocks in the PowerShell profiles and the Clink script, unless they belong to an
    installation that is still there, and the block for AI agents when the last installation goes. Your
    wslbin.ini stays, unless -Purge. The script copies itself into a temporary folder and works from
    there, because it deletes the folder it is in.

    Which installation: -InstallDir; or the one this script is in, when it is an installation (an entry
    in Apps names it, or it is a usual place); or the usual places (C:\Program Files\wslbin,
    %LOCALAPPDATA%\Programs\wslbin) and what the entries in Apps name. An installation for
    all users (its entry in Apps is the one of the machine) asks for administrator rights (UAC).

    The exit code is 0, or 1 when something could not be removed (a program that runs holds its file:
    close it and run this again; until then the installation stays, with its entry in Apps), or 2 when
    it failed.

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

# Whether a folder is an installation that setup knows: an entry in Apps names it, or it is the usual
# place of a scope.
function Test-KnownInstallation([string]$Dir) {
    $wanted = ConvertTo-ComparablePath $Dir
    foreach ($forScope in 'AllUsers', 'CurrentUser') {
        $entry = Get-UninstallEntry (Get-UninstallHive $forScope)
        if ($entry -and $entry.Location -and (ConvertTo-ComparablePath $entry.Location) -eq $wanted) { return $true }
        if ((ConvertTo-ComparablePath (Get-DefaultInstallDir $forScope)) -eq $wanted) { return $true }
    }
    $false
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

# The wrappers of $Names (without .exe) in $Dir, deleted; returns the files that could not be (a program
# that runs holds its file).
function Remove-Wrappers([string]$Dir, [string[]]$Names) {
    $left = @()
    foreach ($name in $Names) {
        try {
            Remove-Item -LiteralPath (Join-Path $Dir "$name.exe") -Force -ErrorAction Stop
            Write-Line "removed $name.exe"
        }
        catch { $left += "$name.exe" }
    }
    , $left
}

# One installation: its wrappers, its PATH entry, its files, its entry in Apps, and the folder when
# nothing of the user's is left in it. Nothing is run from the folder: the wrappers are found by their
# product name, as wslbin finds them.
function Remove-Installation([string]$Dir, [string]$ForScope) {
    $exe = Join-Path $Dir 'wslbin.exe'
    $hive = Get-UninstallHive $ForScope

    # With administrator rights, files are deleted only in a folder that only administrators can change:
    # in any other, a link that someone put there could make this delete files elsewhere. The PATH entry
    # and the entry in Apps still go; the files are left to whoever owns them.
    if ($ForScope -eq 'AllUsers' -and (Test-Administrator)) {
        $writers = @(Get-MachineFolderWriters $Dir)
        if ($writers.Count -gt 0) {
            Write-Problem "$Dir can be changed by others than administrators ($(@($writers | Select-Object -First 3) -join '; ')), so its files are not deleted with administrator rights: delete the folder yourself. Its PATH entry and its entry in Apps are removed."
            $script:Problems++
            Remove-InstallationEntries $Dir $ForScope $hive
            return
        }
    }

    # what to delete is known before anything is: manifest.json names the files
    $files = Get-InstalledFiles $Dir
    $wrappers = @(Get-WrapperNames $Dir)
    if ($wrappers.Count -gt 0) {
        Write-Step "removing wrappers in $Dir"
        $left = Remove-Wrappers $Dir $wrappers
        if ($left.Count -gt 0) {
            # the rest stays, so that a run after the program has ended finds this installation and ends it
            Write-Problem "Could not remove $($left -join ', ') in $Dir (a program that runs holds it). Close it and run this again: until then wslbin stays installed there."
            $script:Problems++
            return
        }
    }
    $wrappers = @($wrappers | ForEach-Object { "$_.exe" })

    Remove-InstallationPath $Dir $ForScope $hive
    try {
        Remove-Item -LiteralPath $exe -Force -ErrorAction Stop
    }
    catch {
        # a terminal that runs a wrapper or wslbin itself: this installation stays (without its PATH entry,
        # which is out already), so that a run after that program has ended finds it and ends it
        Write-Problem "Could not remove ${exe}: $($_.Exception.Message) Close the programs that use it and run this again."
        $script:Problems++
        return
    }
    foreach ($relative in $files) {
        Remove-Item -LiteralPath (Join-Path $Dir $relative) -Force -ErrorAction SilentlyContinue
    }
    Remove-AsideFiles $Dir ($files + $wrappers)
    $setup = Join-Path $Dir 'setup'
    if ((Test-Path -LiteralPath $setup) -and -not (Get-ChildItem -LiteralPath $setup -Force)) { Remove-EmptyFolder $setup }
    if (Remove-UninstallEntry $hive $Dir) { Write-Step 'removed the entry in Settings > Apps' }

    $ini = Join-Path $Dir 'wslbin.ini'
    if ((Test-Path -LiteralPath $ini) -and $Purge) { Remove-Item -LiteralPath $ini -Force }
    if (Test-Path -LiteralPath $ini) { Write-Step "kept $ini (your settings; -Purge deletes it)" }
    elseif (-not (Get-ChildItem -LiteralPath $Dir -Force)) { Remove-EmptyFolder $Dir }
}

# An empty folder of the installation. One that a program is in (a terminal whose current folder it is)
# cannot be deleted; wslbin is gone from it all the same, so that is no reason to stop the uninstall.
function Remove-EmptyFolder([string]$Folder) {
    try { Remove-Item -LiteralPath $Folder -Force -ErrorAction Stop }
    catch { Write-Step "left the empty folder $Folder (a program is in it): delete it yourself" }
}

# PATH: only the scope of the installation, and only when the installer added the folder (it may have
# been there before, for something else).
function Remove-InstallationPath([string]$Dir, [string]$ForScope, $Hive) {
    $entry = Get-UninstallEntry $Hive
    $ours = $entry -and (-not $entry.Location -or (ConvertTo-ComparablePath $entry.Location) -eq (ConvertTo-ComparablePath $Dir))
    if (-not $NoPath -and $ours -and $entry.PathAdded) {
        $location = Get-PathLocation $ForScope
        if (Set-PathEntry -Hive $location.Hive -SubKey $location.SubKey -Entry $Dir -Remove) {
            Send-EnvironmentChange
            Write-Step "took $Dir out of the $ForScope PATH"
        }
    }
}

# The PATH entry and the entry in Apps of an installation whose files stay.
function Remove-InstallationEntries([string]$Dir, [string]$ForScope, $Hive) {
    Remove-InstallationPath $Dir $ForScope $Hive
    if (Remove-UninstallEntry $Hive $Dir) { Write-Step 'removed the entry in Settings > Apps' }
}

# Where this script puts what it runs from (a copy of itself, wslbin.exe for the last step): TEMP, which
# every program of the user can write. With administrator rights a folder under Program Files instead,
# which only administrators can write (that is where the elevated copy checks its files into, too).
function Get-ScratchRoot {
    if (Test-Administrator) {
        $root = [Environment]::GetFolderPath('ProgramFiles')
        if ($root -and (Test-Path -LiteralPath $root)) { return $root }
    }
    [IO.Path]::GetTempPath()
}

# The scripts that the copy with administrator rights runs to remove the installation in $Dir: those of
# that installation when only administrators can change its folder (nothing of the user's can change them
# between the check and the run, also while the question of this script waits), or else this copy.
function Get-UninstallScriptsToCheck([string]$Dir) {
    $installed = @{ 'setup\uninstall.ps1' = (Join-Path $Dir 'setup\uninstall.ps1'); 'setup\common.ps1' = (Join-Path $Dir 'setup\common.ps1') }
    $own = @{ 'setup\uninstall.ps1' = $script:EntryScript; 'setup\common.ps1' = (Join-Path $PSScriptRoot 'common.ps1') }
    $sources = $own
    $present = @($installed.Values | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }).Count -eq 2
    if ($present -and @(Get-MachineFolderWriters (Join-Path $Dir 'setup')).Count -eq 0) { $sources = $installed }
    @((Get-FileToCheck $sources['setup\uninstall.ps1'] 'setup\uninstall.ps1'), (Get-FileToCheck $sources['setup\common.ps1'] 'setup\common.ps1'))
}

# The hooks in the profiles and the Clink script go, unless they belong to an installation that is still
# there ($Left): there is one of each, and it names the wslbin.exe that it runs. The Clink script may
# also be one that a copy of wslbin outside any installation wrote ("wslbin --init clink" of a portable
# copy): it stays while that wslbin.exe is there and is not one of the installations removed ($Removed).
function Remove-Hooks([string[]]$Left, [string[]]$Removed) {
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
        $luaFile = Join-Path $folder 'wslbin.lua'
        $exe = Get-ClinkScriptExe $luaFile
        if ($null -eq $exe) { continue }
        if (Test-HookNames $exe $Left -Clink) { Write-Step "kept ${luaFile}: it runs a wslbin that is still installed"; continue }
        if ($exe -and (Test-Path -LiteralPath $exe -PathType Leaf) -and -not (Test-HookNames $exe $Removed -Clink)) {
            Write-Step "kept ${luaFile}: it runs $exe, which is not an installation that was removed"
            continue
        }
        try {
            Remove-Item -LiteralPath $luaFile -Force -ErrorAction Stop
            Write-Step "removed $luaFile"
        }
        catch {
            Write-Problem "Could not remove ${luaFile}: $($_.Exception.Message)"
            $script:Problems++
        }
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
        $helperFolder = Join-Path (Get-ScratchRoot) ('wslbin-uninstall-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $helperFolder | Out-Null
        $helper = Join-Path $helperFolder 'wslbin.exe'
        Copy-Item -LiteralPath (Join-Path $targets[0] 'wslbin.exe') -Destination $helper
    }
    try {
        foreach ($dir in $machine) {
            if (Test-Administrator) { Remove-Installation $dir 'AllUsers'; continue }
            Write-Step "asking for administrator rights (UAC) to remove the installation for all users in $dir"
            $files = Get-UninstallScriptsToCheck $dir
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
        Remove-Hooks $left $targets

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
    # the folder this script is in, when it is an installation; an unpacked release zip holds wslbin.exe and
    # this script too, and it is no installation (the usual places and the entries in Apps are looked at then)
    if (-not $dir -and (Test-Path -LiteralPath (Join-Path $here 'wslbin.exe')) -and (Test-KnownInstallation $here)) { $dir = $here }
    $temp = Join-Path (Get-ScratchRoot) ('wslbin-uninstall-script-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temp | Out-Null
    $code = 2
    try {
        Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $temp 'uninstall.ps1')
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'common.ps1') -Destination (Join-Path $temp 'common.ps1')
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (ConvertTo-CommandLineArgument (Join-Path $temp 'uninstall.ps1')))
        $arguments += Get-ParameterTokens @('Quiet', 'Purge', 'NoPath', 'ProfileRoot', 'ClinkDir', 'UninstallKey')
        if ($dir) { $arguments += '-InstallDir'; $arguments += (ConvertTo-CommandLineArgument $dir) }
        $arguments += '-FromTemp'
        # (in the temporary folder: the current folder of a process cannot be deleted, and the caller's may
        # well be the install folder)
        $process = Start-Process -FilePath (Get-PowerShellPath) -ArgumentList ($arguments -join ' ') -Wait -PassThru -NoNewWindow -WorkingDirectory $temp
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
