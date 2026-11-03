# Used by the jobs of ci.yml and release.yml: fails unless the program that was built reports the version
# that was asked for. EXPECTED_VERSION (SemVer 2.0, no "v") and, for the tests, PROGRAM come through the
# environment, never pasted into the code of a workflow.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\Wslbin.Version.psm1') -DisableNameChecking -Scope Local

$expected = $env:EXPECTED_VERSION
if (-not $expected -or -not (Test-SemVer $expected)) {
    throw "EXPECTED_VERSION is '$expected', which is not SemVer 2.0."
}
$program = $env:PROGRAM
if (-not $program) { $program = Join-Path $PSScriptRoot '..\bin\wslbin.exe' }
if (-not (Test-Path -LiteralPath $program)) { throw "The program $program does not exist." }

# exactly one line, exactly that text (the case too), and exit code 0
$reported = @(& $program --version)
if ($LASTEXITCODE -ne 0) { throw "$program --version ended with exit code $LASTEXITCODE." }
if ($reported.Count -ne 1 -or $reported[0] -cne "wslbin $expected") {
    throw "Expected 'wslbin $expected', but the program says '$($reported -join ' | ')'."
}
