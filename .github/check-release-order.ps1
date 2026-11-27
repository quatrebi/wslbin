# Used by release.yml: fails unless VERSION (SemVer 2.0, no "v") is higher than every v* tag.
# Works in Windows PowerShell 5.1 and PowerShell 7.
param([string]$Repo = (Join-Path $PSScriptRoot '..'))
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\Wslbin.Version.psm1') -DisableNameChecking -Scope Local   # Test-SemVer
. (Join-Path $PSScriptRoot '..\setup\common.ps1')   # Compare-SemVer
$version = $env:VERSION
if (-not $version -or -not (Test-SemVer $version)) { throw "VERSION is '$version', which is not SemVer 2.0." }
$tags = @(& git -C $Repo tag --list 'v*')
if ($LASTEXITCODE -ne 0) { throw "git tag --list failed in $Repo." }
$highest = $null
foreach ($tag in $tags) {
    $v = $tag.Substring(1)
    if (-not (Test-SemVer $v)) { throw "The tag $tag is not v<SemVer 2.0>: a release cannot be ordered after it." }
    if (-not $highest -or (Compare-SemVer $v $highest) -gt 0) { $highest = $v }
}
if ($highest -and (Compare-SemVer $version $highest) -le 0) {
    throw "v$version is not higher than v$highest, the highest release tag. Release a newer commit of main, or raise MAJOR.MINOR in a pull request (never lower it)."
}
if ($highest) { $shown = "v$highest" } else { $shown = 'none' }
Write-Host "v$version is higher than every tag (highest: $shown)."
exit 0
