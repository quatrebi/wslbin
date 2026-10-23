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
    and nothing else, and it has the asset wslbin-<version>-win-x64.zip and a SHA256 for it: the digest
    that GitHub shows on the asset, or else the first 64 hex digits of the text of the asset
    wslbin-<version>-win-x64.zip.sha256. A release without one of these is skipped with a warning and
    leaves no trace in the file. The versions are sorted by SemVer, highest first; "latest" is the first.

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
    if ($tag -notmatch '^v((0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*))\z') { continue }
    $version = $Matches[1]
    $zipName = "wslbin-$version-win-x64.zip"
    $assets = @($release.assets)
    $zip = $assets | Where-Object { $_.name -ceq $zipName } | Select-Object -First 1
    if (-not $zip) { Write-Warning "$tag is skipped: it has no asset $zipName."; continue }
    if ([string]$zip.browser_download_url -notmatch '^https://') { Write-Warning "$tag is skipped: the address of $zipName is not https."; continue }

    $hash = $null
    $digest = $zip.PSObject.Properties['digest']
    if ($digest -and [string]$digest.Value -match '^sha256:([0-9a-fA-F]{64})\z') { $hash = $Matches[1].ToLowerInvariant() }
    if (-not $hash) {
        $sums = $assets | Where-Object { $_.name -ceq "$zipName.sha256" } | Select-Object -First 1
        if ($sums) {
            try {
                if ((Get-AssetText ([string]$sums.browser_download_url)) -match '(?m)^\s*([0-9a-fA-F]{64})\b') { $hash = $Matches[1].ToLowerInvariant() }
            }
            catch { Write-Warning "$tag is skipped: the hash could not be read ($($_.Exception.Message))."; continue }
        }
    }
    if (-not $hash) { Write-Warning "$tag is skipped: no SHA256 of $zipName was found."; continue }

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
