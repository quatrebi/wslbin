<#
.SYNOPSIS
    Installs wslbin from the package it is in: wslbin.exe, its LICENSE and these scripts, checked against
    manifest.json.

.DESCRIPTION
    This script is in the zip of a release (wslbin-<version>-win-x64.zip), in the folder setup\ beside
    wslbin.exe and manifest.json. It needs no network: the loader that the site serves
    (https://quatrebi.github.io/wslbin/install.ps1) downloads the zip, checks it and runs this. Works in
    Windows PowerShell 5.1 and in PowerShell 7.

      1. reads manifest.json and checks every file of the package against its SHA256;
      2. compares the version with the one that is installed (the entry in Settings > Apps): newer is
         installed, the same is "already installed" (unless the folder lacks wslbin.exe or holds another
         version: then it is installed again), older needs -Force;
      3. puts the files into the install folder: each new file is written beside its target, then the old
         ones are renamed to .old and the new ones to the names, so that a failure leaves the old
         version as it was. The wrappers that exist (the .exe files that are copies of wslbin) are
         replaced by copies of the new wslbin.exe; wslbin.ini is not touched; files that the old
         manifest named and the new one does not are deleted;
      4. adds the folder to PATH (not with -NoPath) and, last, writes the entry for Settings > Apps (the
         only thing in the registry besides PATH);
      5. with -Link makes wrappers; with -Completion hooks Tab completion into the shells.

    Where it goes: -Scope CurrentUser is %LOCALAPPDATA%\Programs\wslbin and the PATH and Apps entry of
    the user, with no administrator rights. -Scope AllUsers is C:\Program Files\wslbin and the PATH and
    Apps entry of the machine; it asks for administrator rights (UAC). Without -Scope it is CurrentUser,
    unless wslbin is installed for all users: then that installation is updated. -InstallDir names
    another folder; for all users, one that only administrators can change (a new one is made so). A
    folder that holds files with the names of wslbin's (LICENSE, manifest.json, setup\) and is not an
    installation of wslbin is refused: they belong to something else. When
    wslbin is installed in the other scope as well, this says so: of the two, the one for all users runs.

    The exit code is 0, or 1 when something went wrong that did not stop the install (a profile that is
    not UTF-8 text and was left alone, a wrapper that could not be made), or 2 when the install failed.

.EXAMPLE
    .\setup\install.ps1 -Link make,rsync,dig -Completion pwsh,clink

.EXAMPLE
    .\setup\install.ps1 -Scope AllUsers -Force
#>
[CmdletBinding()]
param(
    # default: AllUsers when wslbin is installed for all users (an update goes there), else CurrentUser
    [ValidateSet('AllUsers', 'CurrentUser')]
    [string]$Scope,
    [string]$InstallDir,
    # utilities to make wrappers for after the install
    [string[]]$Link = @(),
    # shells to hook Tab completion into: pwsh (both PowerShells) and clink (cmd)
    [string[]]$Completion = @(),
    [switch]$NoPath,
    # install the same version again, or an older one than the one that is installed
    [switch]$Force,
    # the folder of the package (default: the folder above this one)
    [string]$PackageDir,
    # folder that holds WindowsPowerShell\ and PowerShell\ with the profiles (default: Documents)
    [string]$ProfileRoot,
    # folder for the Clink script (default: the one that Clink names)
    [string]$ClinkDir,
    # a key of its own under HKCU or HKLM instead of ...\Uninstall\wslbin: for the tests
    [string]$UninstallKey,
    # internal: this is the copy with administrator rights, which runs from a folder of checked files
    [switch]$Elevated
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

# ---- the work -----------------------------------------------------------------------------------
#
# The work is in two parts. What belongs to the machine (the files, the Apps entry and the PATH of the
# machine) is done by the copy with administrator rights when the install is for all users. What belongs
# to the user who runs this (wrappers for -Link, which ask that user's WSL and its apt; the hooks in that
# user's profiles; the Clink script; the instructions of the AI agents) is always done here, without
# those rights: with another account's password at the UAC prompt, the copy with rights runs as that
# account and would change its profiles and its WSL instead.

# The scope without -Scope: the one for all users when wslbin is installed there (in -InstallDir, if
# that is given), so that an update does not make a second copy for the user that the one for all users
# hides (it comes first in PATH); else the one of the user.
function Get-DefaultScope([string]$Dir) {
    $machine = Get-UninstallEntry (Get-UninstallHive 'AllUsers')
    if (-not $machine -or -not $machine.Location -or -not (Test-Path -LiteralPath (Join-Path $machine.Location 'wslbin.exe'))) { return 'CurrentUser' }
    if ($Dir -and (ConvertTo-ComparablePath $Dir) -ne (ConvertTo-ComparablePath $machine.Location)) { return 'CurrentUser' }
    Write-Step "wslbin $($machine.Version) is installed for all users in $($machine.Location): that one is updated (-Scope CurrentUser installs a copy for this user instead)"
    'AllUsers'
}

# Whether the folder holds the installation that its entry in Apps names: wslbin.exe, and a manifest.json
# of that version.
function Test-InstallationIntact([string]$Dir, [string]$Version) {
    if (-not (Test-Path -LiteralPath (Join-Path $Dir 'wslbin.exe') -PathType Leaf)) { return $false }
    $manifest = Read-InstalledManifest $Dir
    $manifest -and $manifest.Version -ceq $Version
}

# The scope and the folder: -InstallDir, or the usual one of the scope.
function Set-InstallTarget([string]$ForScope) {
    $script:EffectiveScope = $ForScope
    $script:Dir = $InstallDir
    if (-not $script:Dir) { $script:Dir = Get-DefaultInstallDir $ForScope }
}

# Puts the package into $script:Dir, brings the wrappers there up to date, adds the folder to PATH and
# writes the Apps entry: the part that belongs to the machine. Returns $false when that version is
# installed already.
function Install-Program($Manifest) {
    $hive = Get-UninstallHive $script:EffectiveScope
    $installed = Get-UninstallEntry $hive
    $sameFolder = $installed -and $installed.Location -and (ConvertTo-ComparablePath $installed.Location) -eq (ConvertTo-ComparablePath $script:Dir)
    if ($installed -and $installed.Location -and -not $sameFolder) {
        # Settings > Apps holds one installation a scope: a second one would take the entry of the first,
        # whose files and PATH entry nothing would remove then. An entry whose folder holds no wslbin any
        # more names nothing, and is replaced.
        if (Test-Path -LiteralPath (Join-Path $installed.Location 'wslbin.exe')) {
            throw "wslbin $($installed.Version) is installed in $($installed.Location) already. Update that one (-InstallDir $($installed.Location)), or remove it first."
        }
        Write-Step "the entry in Settings > Apps names $($installed.Location), which holds no wslbin.exe any more: it is replaced"
        $installed = $null
    }
    if ($installed) {
        if (-not (ConvertFrom-SemVer $installed.Version)) {
            if (-not $Force) { throw "The entry in Settings > Apps says that wslbin '$($installed.Version)' is installed, which is not a version this installer can compare. Use -Force to install $($Manifest.Version) over it." }
        }
        else {
            $order = Compare-SemVer $Manifest.Version $installed.Version
            if ($order -eq 0 -and -not $Force) {
                if (Test-InstallationIntact $script:Dir $installed.Version) {
                    Write-Step "wslbin $($Manifest.Version) is installed already (-Force installs it again)"
                    return $false
                }
                Write-Step "wslbin $($Manifest.Version) in $($script:Dir) is not complete (wslbin.exe or its manifest.json is missing, or says another version): it is installed again"
            }
            if ($order -lt 0 -and -not $Force) {
                throw "wslbin $($installed.Version) is installed, which is newer than $($Manifest.Version). Use -Force to go back."
            }
        }
    }

    # The copy with administrator rights changes this folder and runs from nowhere a program of the user
    # could change: a folder that others can change is refused (a new one is made for administrators only).
    if ($script:EffectiveScope -eq 'AllUsers') { Initialize-MachineFolder $script:Dir }
    # manifest.json goes along: it says which version is in the folder
    $files = @($Manifest.Files) + 'manifest.json'
    Assert-FolderIsOurs $script:Dir $files
    $wrappers = @(Get-WrapperNames $script:Dir)
    $previous = Read-InstalledManifest $script:Dir

    $placement = Install-Files $script:Package $files $wrappers $script:Dir
    $pathAddedNow = $false
    try {
        Write-Step "installed $($Manifest.Version) in $($script:Dir)"
        if ($wrappers.Count -gt 0) { Write-Step "replaced $($wrappers.Count) wrapper(s) with the new wslbin.exe" }

        # the folder was put into PATH by this installer before, or now: only then does the uninstall take it out
        $pathAdded = $sameFolder -and $installed.PathAdded
        if (-not $NoPath) {
            $location = Get-PathLocation $script:EffectiveScope
            if (Set-PathEntry -Hive $location.Hive -SubKey $location.SubKey -Entry $script:Dir) {
                $pathAddedNow = $true
                $pathAdded = $true
                Send-EnvironmentChange
                Write-Step "added $($script:Dir) to the $($script:EffectiveScope) PATH (new terminals see it)"
            }
            else { Write-Step "$($script:Dir) is in the PATH already" }
        }

        # last: the entry says which version is installed, so it is written when everything else is done
        $ours = @($files + @($wrappers | ForEach-Object { "$_.exe" }) | ForEach-Object { Join-Path $script:Dir $_ })
        Set-UninstallEntry $hive $script:Dir $Manifest.Version $ours $pathAdded
    }
    catch {
        if ($pathAddedNow) {
            $null = Set-PathEntry -Hive $location.Hive -SubKey $location.SubKey -Entry $script:Dir -Remove
            Send-EnvironmentChange
        }
        Undo-Placement $placement
        throw
    }
    Complete-Placement $placement
    # what the package before had and this one has not (a file it no longer needs); never wslbin.ini
    if ($previous) {
        foreach ($relative in $previous.Files) {
            if ($files -contains $relative -or $relative -eq 'wslbin.ini') { continue }
            Remove-Item -LiteralPath (Join-Path $script:Dir $relative) -Force -ErrorAction SilentlyContinue
        }
    }
    $true
}

# -Link and -Completion: the part that belongs to the user (see above).
function Install-UserParts {
    $exe = Join-Path $script:Dir 'wslbin.exe'
    if ($Link.Count -gt 0) {
        Write-Step "wrappers: $($Link -join ', ')"
        Invoke-WslbinStep $exe (@('--link') + $Link)
    }

    if ($Completion -contains 'pwsh') {
        $body = Get-ProfileBlockBody $exe
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
        Write-ProfilePolicyWarnings
    }
    if ($Completion -contains 'clink') {
        if ($ClinkDir) { Invoke-WslbinStep $exe @('--init', 'clink', '--dir', $ClinkDir) } else { Invoke-WslbinStep $exe @('--init', 'clink') }
    }
}

# The exit code at the end: 0, or 1 when there were problems that did not stop the install.
function Complete-Install {
    if ($script:Problems -gt 0) {
        Write-Step "finished, with $($script:Problems) problem(s) (see the warnings above)"
        return 1
    }
    Write-Step 'done. Check it with: wslbin --doctor    (a new terminal sees the PATH)'
    0
}

# The whole install; returns the exit code: 0 done, 1 done with problems, 2 failed.
function Install-Wslbin {
    # The copy with administrator rights does the machine's part only. It ends with 0 (done) or 2
    # (failed): the copy that started it goes on only after 0.
    if ($Elevated) {
        try {
            Set-InstallTarget $Scope
            $manifest = Read-Manifest $script:Package
            Write-Step "package $($manifest.Version) checked against manifest.json"
            $null = Install-Program $manifest
        }
        catch {
            Write-Problem $_.Exception.Message
            return 2
        }
        return 0
    }

    Set-InstallTarget $Scope
    try {
        $manifest = Read-Manifest $script:Package
        Write-Step "package $($manifest.Version) checked against manifest.json"
        $other = Get-OtherInstallation $script:EffectiveScope $script:Dir
        if ($other) { Write-OtherInstallation $other }

        # For all users always through the copy with administrator rights, also from a PowerShell that has
        # them already: that copy installs from files checked into a folder that only administrators can
        # write, not from the package in TEMP, which any program of the user can change after the check.
        if ($script:EffectiveScope -eq 'AllUsers') {
            if (Test-Administrator) { Write-Step 'checking the package into a folder for administrators, and installing for all users from there' }
            else { Write-Step 'asking for administrator rights (UAC) to install for all users' }
            $arguments = @('-Scope', 'AllUsers', '-InstallDir', (ConvertTo-PowerShellLiteral $script:Dir)) + (Get-ParameterTokens @('NoPath', 'Force', 'UninstallKey') -PowerShell) + '-Elevated'
            $code = Invoke-Elevated @(Get-PackageFilesToCheck $script:Package $manifest) 'setup\install.ps1' $arguments
            if ($null -eq $code) { throw 'Installing for all users needs administrator rights, and they were refused. (Without -Scope AllUsers wslbin is installed for the current user, with no rights needed.)' }
            if ($code -ne 0) { throw "The copy with administrator rights failed (exit code $code; its window said why). Nothing more was done." }
            Write-Step "installed for all users in $($script:Dir)"
        }
        else {
            $null = Install-Program $manifest
        }
    }
    catch {
        Write-Problem $_.Exception.Message
        return 2
    }
    Install-UserParts
    Complete-Install
}

# dot-sourced (by the tests): the functions are all that is wanted
if ($MyInvocation.InvocationName -eq '.') { return }

$script:BoundParameters = $PSBoundParameters
$InstallDir = ConvertTo-FullPath $InstallDir
if (-not $Scope) { $Scope = Get-DefaultScope $InstallDir }
$ProfileRoot = ConvertTo-FullPath $ProfileRoot
$ClinkDir = ConvertTo-FullPath $ClinkDir
$PackageDir = ConvertTo-FullPath $PackageDir
$script:Package = $PackageDir
if (-not $script:Package) { $script:Package = Split-Path -Parent $PSScriptRoot }
$Link = Split-List $Link
$Completion = Split-List $Completion
foreach ($shell in $Completion) {
    if ($shell -notin 'pwsh', 'clink') { Write-Problem "-Completion takes pwsh and clink, not '$shell'."; exit 2 }
}
# (the last thing that Install-Wslbin hands over is its exit code)
$result = @(Install-Wslbin)
exit ([int]$result[-1])
