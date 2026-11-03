<#
.SYNOPSIS
    Writes releases.json for the site: the stable releases of the repository, with the address and the
    SHA256 of the zip of each, and which one is the latest.

.DESCRIPTION
    {
      "schema": 1, "latest": "0.1.7",
      "releases": [ { "version": "0.1.7", "tag": "v0.1.7", "published": "...",
                      "asset": "wslbin-0.1.7-win-x64.zip", "url": "https://...", "sha256": "<64 lowercase hex>" } ]
    }

    A release is taken only when it is not a draft, not a pre-release, its tag is v<MAJOR>.<MINOR>.<PATCH>
    and nothing else, and it has the asset wslbin-<version>-win-x64.zip and its SHA256 in the asset
    wslbin-<version>-win-x64.zip.sha256 (the first 64 hex digits of its text), which the release job wrote;
    when GitHub shows a digest of the zip, it must be that SHA256 (otherwise the zip was replaced after the
    release). A release without these is skipped with a warning and leaves no trace in the file. The versions are sorted by SemVer, highest first; "latest" is the first.

    Without -InputFile the list comes from GitHub (the gh program and GH_TOKEN, which a workflow has).
    -InputFile is for the tests: a JSON array of releases in the shape of the API; only with it an address
    of the form file:/// is read from the disk (PowerShell 7 cannot read it with Invoke-WebRequest).
    Everything that is downloaded must be https.

    The file is written at the very end, UTF-8 without a byte order mark, with line feeds only.
    Works in Windows PowerShell 5.1 and PowerShell 7.
#>
param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$Output,
    [string]$InputFile
)

$ErrorActionPreference = 'Stop'
# Test-SemVer: the one definition of a version (-Scope Local and no -Force, so that a caller that has the
# module loaded keeps it)
Import-Module (Join-Path $PSScriptRoot '..\Wslbin.Version.psm1') -DisableNameChecking -Scope Local

function Get-AssetText {
    param([string]$Url)
    if ($InputFile -and $Url -match '^file:') { return [IO.File]::ReadAllText(([Uri]$Url).LocalPath) }
    if ($Url -notmatch '^https://') { throw "not an https address: $Url" }
    $content = (Invoke-WebRequest -Uri $Url -UseBasicParsing).Content
    if ($content -is [byte[]]) { return [Text.Encoding]::UTF8.GetString($content) }
    return [string]$content
}

# the releases, as objects of the API of GitHub
if ($InputFile) {
    $releases = @(Get-Content -LiteralPath $InputFile -Raw -Encoding UTF8 | ConvertFrom-Json)
}
else {
    # one compact JSON object per line, whatever the number of pages
    $lines = @(& gh api "repos/$Repository/releases?per_page=100" --paginate --jq '.[] | tojson')
    if ($LASTEXITCODE -ne 0) { throw "gh api failed with exit code $LASTEXITCODE." }
    $releases = @($lines | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
}
# Windows PowerShell 5.1 hands a JSON array over as one object that is the array, PowerShell 7 as its
# items, and an array of one release or none arrives as that release or as nothing: one flat list of releases
function Expand-Items {
    param($Item)
    if ($null -eq $Item) { return }
    if ($Item -is [array]) { foreach ($inner in $Item) { Expand-Items $inner } }
    else { $Item }
}
$releases = @(foreach ($item in $releases) { Expand-Items $item })

$found = New-Object System.Collections.Generic.List[object]
foreach ($release in $releases) {
    $tag = [string]$release.tag_name
    if ($release.draft -or $release.prerelease) { continue }
    # a stable version: SemVer 2.0 with nothing after PATCH
    $version = $(if ($tag.StartsWith('v')) { $tag.Substring(1) } else { '' })
    if (-not (Test-SemVer $version) -or $version.Contains('-') -or $version.Contains('+')) { continue }
    $zipName = "wslbin-$version-win-x64.zip"
    $assets = @($release.assets)
    $zip = $assets | Where-Object { $_.name -ceq $zipName } | Select-Object -First 1
    if (-not $zip) { Write-Warning "$tag is skipped: it has no asset $zipName."; continue }
    if ([string]$zip.browser_download_url -notmatch '^https://') { Write-Warning "$tag is skipped: the address of $zipName is not https."; continue }

    # Two records of the hash: the .sha256 file that the release job wrote when it made the zip, and the
    # digest that GitHub computes of the asset as it is now. Both must be there and agree, so that a zip
    # that was replaced after the release (by anything that may write to the repository) is not published
    # with the hash of the replacement.
    # An address that is not https is a fact of that release, which is skipped. A download that fails is not:
    # the script stops and writes nothing, so that the site keeps the releases.json that it has, rather than
    # one without that release (or with an older "latest").
    $hash = $null
    $sums = $assets | Where-Object { $_.name -ceq "$zipName.sha256" } | Select-Object -First 1
    if ($sums) {
        $sumsUrl = [string]$sums.browser_download_url
        if (-not ($InputFile -and $sumsUrl -match '^file:') -and $sumsUrl -notmatch '^https://') {
            Write-Warning "$tag is skipped: the address of $zipName.sha256 is not https."
            continue
        }
        try { $sumsText = Get-AssetText $sumsUrl }
        catch { throw "The hash of $tag could not be read from ${sumsUrl}: $($_.Exception.Message) Nothing was written." }
        if ($sumsText -match '(?m)^\s*([0-9a-fA-F]{64})\b') { $hash = $Matches[1].ToLowerInvariant() }
    }
    if (-not $hash) { Write-Warning "$tag is skipped: it has no $zipName.sha256 with a SHA256 in it."; continue }
    $digest = $zip.PSObject.Properties['digest']
    if ($digest -and [string]$digest.Value) {
        if ([string]$digest.Value -notmatch '^sha256:([0-9a-fA-F]{64})\z') { Write-Warning "$tag is skipped: the digest of $zipName is not a SHA256 ($($digest.Value))."; continue }
        if ($Matches[1].ToLowerInvariant() -ne $hash) { Write-Warning "$tag is skipped: $zipName is not the file that was released (its digest is $($Matches[1].ToLowerInvariant()), its .sha256 says $hash)."; continue }
    }

    # PowerShell 7 turns the date of the API into a DateTime, and a string of that would be in the culture of the machine
    $published = $release.published_at
    if ($published -is [datetime]) { $published = $published.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture) }
    $found.Add([pscustomobject][ordered]@{
            version   = $version
            tag       = $tag
            published = [string]$published
            asset     = $zipName
            url       = [string]$zip.browser_download_url
            sha256    = $hash
        })
}

# SemVer order: the tags are MAJOR.MINOR.PATCH only, so [version] orders them as numbers
$sorted = @($found | Sort-Object -Property @{ Expression = { [version]$_.version }; Descending = $true })
$latest = $null
if ($sorted.Count -gt 0) { $latest = $sorted[0].version }

$document = [ordered]@{ schema = 1; latest = $latest; releases = @($sorted) }
$json = (ConvertTo-Json -InputObject $document -Depth 6).Replace("`r`n", "`n")

$folder = Split-Path -Parent $Output
if ($folder -and -not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder | Out-Null }
[IO.File]::WriteAllText($Output, $json + "`n", [Text.UTF8Encoding]::new($false))
