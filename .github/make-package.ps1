<#
.SYNOPSIS
    Makes the files of a release: the zip of the package, its SHA256 and SHA256SUMS.txt.

.DESCRIPTION
    The zip wslbin-<version>-win-x64.zip holds, with / in the names of the entries:

      wslbin.exe, LICENSE
      manifest.json           the version, and every other file with its size and SHA256
      setup/install.ps1       installs from the folder the zip was unpacked into (no network)
      setup/uninstall.ps1     the program that "Settings > Apps > wslbin > Uninstall" runs
      setup/common.ps1        what the two share

    manifest.json is {"schema":1,"version":"0.1.7","files":[{"path":"wslbin.exe","size":N,"sha256":"<64 hex>"},...]};
    the installer installs only what it names, after checking it.

    wslbin-<version>-win-x64.zip.sha256 and SHA256SUMS.txt hold "<hash>  <name>" (the format of sha256sum:
    lowercase hash, two spaces, ASCII, line feeds). The version is the one the program reports: pass the
    same -Version that went into the build. Works in Windows PowerShell 5.1 and in PowerShell 7.
#>
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$Exe,
    [Parameter(Mandatory = $true)][string]$OutputDir,
    # the repository (LICENSE and setup\ are taken from it); default: the folder above this script
    [string]$Root
)

$ErrorActionPreference = 'Stop'
# Test-SemVer: the one definition of a version (-Scope Local and no -Force, so that a caller that has the
# module loaded keeps it)
Import-Module (Join-Path $PSScriptRoot '..\Wslbin.Version.psm1') -DisableNameChecking -Scope Local
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
if (-not (Test-SemVer $Version)) {
    throw "'$Version' is not a SemVer 2.0 version."
}

# the files of the package: where they come from, and the name inside the zip
$entries = @(
    @{ Name = 'wslbin.exe'; Path = (Resolve-Path -LiteralPath $Exe).ProviderPath }
    @{ Name = 'LICENSE'; Path = (Join-Path $Root 'LICENSE') }
    @{ Name = 'setup/install.ps1'; Path = (Join-Path $Root 'setup\install.ps1') }
    @{ Name = 'setup/uninstall.ps1'; Path = (Join-Path $Root 'setup\uninstall.ps1') }
    @{ Name = 'setup/common.ps1'; Path = (Join-Path $Root 'setup\common.ps1') }
)
foreach ($entry in $entries) {
    if (-not (Test-Path -LiteralPath $entry.Path -PathType Leaf)) { throw "$($entry.Path) is missing: it belongs in the package as $($entry.Name)." }
}

$files = foreach ($entry in $entries) {
    [ordered]@{
        path   = $entry.Name
        size   = (Get-Item -LiteralPath $entry.Path).Length
        sha256 = (Get-FileHash -LiteralPath $entry.Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
$manifest = [ordered]@{ schema = 1; version = $Version; files = @($files) }
$manifestJson = ((ConvertTo-Json -InputObject $manifest -Depth 4).Replace("`r`n", "`n")) + "`n"

if (-not (Test-Path -LiteralPath $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir | Out-Null }
$OutputDir = (Resolve-Path -LiteralPath $OutputDir).ProviderPath
$zipName = "wslbin-$Version-win-x64.zip"
$zipPath = Join-Path $OutputDir $zipName
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($entry in $entries) {
        $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $entry.Path, $entry.Name, [IO.Compression.CompressionLevel]::Optimal)
    }
    $manifestEntry = $zip.CreateEntry('manifest.json', [IO.Compression.CompressionLevel]::Optimal)
    $stream = $manifestEntry.Open()
    try {
        $bytes = (New-Object Text.UTF8Encoding $false).GetBytes($manifestJson)
        $stream.Write($bytes, 0, $bytes.Length)
    }
    finally { $stream.Dispose() }
}
finally { $zip.Dispose() }

$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$line = "$hash  $zipName`n"
$ascii = New-Object Text.UTF8Encoding $false
[IO.File]::WriteAllText("$zipPath.sha256", $line, $ascii)
[IO.File]::WriteAllText((Join-Path $OutputDir 'SHA256SUMS.txt'), $line, $ascii)
Write-Host "made $zipPath ($hash)"
