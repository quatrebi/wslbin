# Builds bin\wslbin.exe with the C# compiler that ships with Windows (no SDK needed).
# Same command as in AGENTS.md, plus /resource for the texts that live in files of the repository.
# Works in Windows PowerShell 5.1 and PowerShell 7.
param(
    [string]$Output = (Join-Path $PSScriptRoot 'bin\wslbin.exe'),
    # for the tests only (Initialize-FakeWsl in tests\helpers.ps1): more source files, and the class
    # whose Main starts the program
    [string[]]$ExtraSource = @(),
    [string]$Main
)

$ErrorActionPreference = 'Stop'

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { throw "C# compiler not found: $csc" }

$outDir = Split-Path -Parent $Output
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

# file in the repository -> resource name (the constants in the Resources class of src\Help.cs)
$resources = @(
    @('wsl\complete.sh', 'wslbin.wsl.complete.sh'),
    @('shell\wslbin.ps1', 'wslbin.shell.wslbin.ps1'),
    @('shell\wslbin.lua', 'wslbin.shell.wslbin.lua')
)
$arguments = @('/nologo', '/optimize+', '/target:exe', "/out:$Output")
foreach ($r in $resources) {
    $file = Join-Path $PSScriptRoot $r[0]
    if (-not (Test-Path $file)) { throw "missing $file" }
    $arguments += "/resource:$file,$($r[1])"
}
# the program: every .cs file in src (src\wslbin.cs holds the entry point and the version)
foreach ($source in Get-ChildItem -Path (Join-Path $PSScriptRoot 'src') -Filter '*.cs' -File | Sort-Object Name) {
    $arguments += $source.FullName
}
foreach ($source in $ExtraSource) { $arguments += $source }
if ($Main) { $arguments += "/main:$Main" }

& $csc @arguments
if ($LASTEXITCODE -ne 0) { throw "csc failed with exit code $LASTEXITCODE" }

Write-Host "Built $Output"
