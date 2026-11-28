# The coverage gate of the pull request: the share of the lines of src\ that the unit tests run.
#
#   ./tests/coverage-gate.ps1 -Report <cobertura.xml> -Minimum 75
#
# Only files under src\ count (the report of the code coverage tool also lists generated code), a line that
# the report lists more than once (a method with several ranges, a lambda) counts once, and it is covered when
# any of its entries was hit. The root line-rate of the report is not used: it counts what the tool decides to
# count. Prints a table (to $GITHUB_STEP_SUMMARY too, when that is set) and exits with 1 below the minimum.
# Works in Windows PowerShell 5.1 and PowerShell 7.
param(
    [Parameter(Mandatory)][string]$Report,
    [double]$Minimum = 75,
    # the repository folder, which src\ is under
    [string]$Repository = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Report)) { throw "The coverage report was not found: $Report" }
$srcRoot = [IO.Path]::GetFullPath((Join-Path $Repository 'src')).TrimEnd('\') + '\'

$xml = [xml](Get-Content -Raw -LiteralPath $Report)
$sources = @($xml.coverage.sources.source | Where-Object { $_ } | ForEach-Object { "$_" })

# file -> (line number -> covered)
$files = @{}
foreach ($class in $xml.SelectNodes('//class')) {
    $name = $class.filename
    if (-not $name) { continue }
    $full = $null
    if ([IO.Path]::IsPathRooted($name)) { $full = $name }
    else {
        foreach ($s in $sources + $Repository) {
            $candidate = Join-Path $s $name
            if (Test-Path -LiteralPath $candidate) { $full = $candidate; break }
        }
        if (-not $full) { $full = Join-Path $Repository $name }
    }
    $full = [IO.Path]::GetFullPath($full)
    if (-not $full.StartsWith($srcRoot, [StringComparison]::OrdinalIgnoreCase)) { continue }
    if (-not $files.ContainsKey($full)) { $files[$full] = @{} }
    foreach ($line in $class.SelectNodes('lines/line')) {
        $number = [int]$line.number
        $hit = [int]$line.hits -gt 0
        if (-not $files[$full].ContainsKey($number)) { $files[$full][$number] = $hit }
        elseif ($hit) { $files[$full][$number] = $true }
    }
}
if ($files.Count -eq 0) { throw "The report lists no file under $srcRoot." }

$rows = foreach ($f in ($files.Keys | Sort-Object)) {
    $lines = $files[$f].Values
    $covered = @($lines | Where-Object { $_ }).Count
    [pscustomobject]@{ File = $f.Substring($srcRoot.Length); Lines = $lines.Count; Covered = $covered; Percent = [math]::Round(100.0 * $covered / [math]::Max(1, $lines.Count), 1) }
}
$total = ($rows | Measure-Object Lines -Sum).Sum
$covered = ($rows | Measure-Object Covered -Sum).Sum
$percent = [math]::Round(100.0 * $covered / $total, 2)

$table = $rows | Format-Table -AutoSize | Out-String
Write-Host $table
Write-Host ("src\ lines: {0} of {1} covered = {2}% (minimum {3}%)" -f $covered, $total, $percent, $Minimum)

if ($env:GITHUB_STEP_SUMMARY) {
    $md = @("### Coverage of src\ by the unit tests", '', '| File | Lines | Covered | % |', '|---|---:|---:|---:|')
    foreach ($r in $rows) { $md += "| $($r.File) | $($r.Lines) | $($r.Covered) | $($r.Percent) |" }
    $md += "| **total** | **$total** | **$covered** | **$percent** |"
    $md += ''
    $md += "Minimum: $Minimum%. " + $(if ($percent -ge $Minimum) { 'Passed.' } else { 'FAILED.' })
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value ($md -join "`n")
}

if ($percent -lt $Minimum) {
    Write-Host "Coverage $percent% is below the minimum $Minimum%."
    exit 1
}
exit 0
