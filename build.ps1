# Builds wslbin.exe: one self-contained Native AOT program for Windows (win-x64), with dotnet publish.
# Needs the .NET SDK 10 and the C++ build tools of Visual Studio (the AOT compiler links with them), and
# NuGet access to nuget.org whenever the packages of the AOT compiler and of the runtime are not in the
# cache yet: on the first build, and after an update of the SDK (nuget.config of the repository names
# the only source). The version of the program is -Version, or what get-version.ps1 says for this checkout.
# Works in Windows PowerShell 5.1 and PowerShell 7.
param(
    [string]$Output = (Join-Path $PSScriptRoot 'bin\wslbin.exe'),
    # the version of the program, SemVer 2.0
    [string]$Version,
    # for the tests only (Initialize-FakeWsl in tests\helpers.ps1): more source files, and the class
    # whose Main starts the program
    [string[]]$ExtraSource = @(),
    [string]$Main
)

$ErrorActionPreference = 'Stop'
# (not -Force: that would unload the module from whoever called this script, and Local keeps the
# functions out of their session)
Import-Module (Join-Path $PSScriptRoot 'Wslbin.Version.psm1') -DisableNameChecking -Scope Local

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw 'The .NET SDK 10 is needed to build wslbin (https://dotnet.microsoft.com/download): dotnet was not found in PATH.'
}
if ($Version) {
    if (-not (Test-SemVer $Version)) { throw "'$Version' is not SemVer 2.0 (https://semver.org)." }
}
else {
    $Version = Get-WslbinVersion -Repo $PSScriptRoot -Kind local
}
# these become properties of MSBuild on its command line, where ; % $ @ and ' mean something
if ($Main -and -not [regex]::IsMatch($Main, '^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*\z')) {
    throw "-Main must be the name of a class, like Wslbin.FakeWslEntry; got '$Main'."
}
$extra = @($ExtraSource | ForEach-Object {
        $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($_)
        if ($full -match '[,;%$@''"]') { throw "-ExtraSource: the path '$full' has a character that MSBuild reads as something else (, ; % `$ @ ' `")." }
        $full
    })
$Output = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Output)

$publish = Join-Path ([IO.Path]::GetTempPath()) ('wslbin-publish-' + [guid]::NewGuid().ToString('N'))
$arguments = @(
    'publish', (Join-Path $PSScriptRoot 'wslbin.csproj').Replace('\', '/'), '-c', 'Release', '-r', 'win-x64', '-o', $publish.Replace('\', '/'),
    # (no build servers: they would stay alive after the build, and hold on to its folders and to files)
    '-nologo', '-v:q', '--disable-build-servers', "-p:Version=$Version", "-p:InformationalVersion=$Version"
)
if ($extra.Count -gt 0) { $arguments += ('-p:ExtraSource=' + (($extra | ForEach-Object { $_.Replace('\', '/') }) -join '%3B')) }
if ($Main) { $arguments += "-p:Main=$Main" }
if ($extra.Count -gt 0 -or $Main) {
    # A test build has a folder of its own for what the compiler leaves behind, so that it never mixes
    # with the normal build. (A slash and not a backslash at the end of a path: Windows PowerShell 5.1
    # would take a backslash before the closing quote of an argument with a space for an escape.)
    if ($PSScriptRoot -match '[,;%$@'']') {
        throw "A test build (-ExtraSource, -Main) needs a path of the repository without , ; % `$ @ ' (MSBuild reads them in a property): $PSScriptRoot"
    }
    # The key is made of the names of the files and of -Main, not of their folders: a test that builds
    # from a new temporary folder every time would leave a folder of 100 MB in obj each run.
    $sha = [Security.Cryptography.SHA256]::Create()
    $names = ($extra | ForEach-Object { Split-Path -Leaf $_ }) -join '|'
    $key = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($names + '#' + $Main))).Replace('-', '').Substring(0, 8).ToLowerInvariant()
    $variant = (Join-Path $PSScriptRoot "obj\variant-$key").Replace('\', '/')
    $arguments += "-p:BaseIntermediateOutputPath=$variant/obj/", "-p:BaseOutputPath=$variant/bin/"
}

$oldPath = $env:Path
Push-Location -LiteralPath $PSScriptRoot   # dotnet looks for global.json from the folder it runs in
try {
    # The AOT compiler looks for the C++ tools with vswhere.exe, which is not in PATH of an ordinary shell.
    $vsInstaller = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer'
    if (-not (Get-Command vswhere -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath (Join-Path $vsInstaller 'vswhere.exe'))) {
        $env:Path = "$vsInstaller;$env:Path"
    }

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $log = @(& dotnet @arguments 2>&1)
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $oldPreference }
    if ($code -ne 0) {
        # the reason is in the message: callers silence the information stream, where Write-Host writes
        # the lines with an error first (warnings may come after them), then the end of the log
        $lines = @($log | ForEach-Object { "$_" } | Where-Object { $_.Trim() })
        # (dotnet itself says "A compatible .NET SDK was not found" without the word error, and then lists the SDKs)
        $errors = @($lines | Where-Object { $_ -match '\berror\b|was not found|Requested SDK|global\.json|Platform linker' } | Select-Object -First 15)
        $tail = @($lines | Select-Object -Last 15 | Where-Object { $errors -notcontains $_ })
        throw "dotnet publish failed (exit code $code):`n$(($errors + $tail) -join "`n")"
    }
    foreach ($line in $log) { if ("$line" -match 'warning ') { Write-Warning "$line" } }

    $built = Join-Path $publish 'wslbin.exe'
    if (-not (Test-Path -LiteralPath $built)) { throw "dotnet publish made no wslbin.exe in $publish." }
    $outDir = Split-Path -Parent $Output
    if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
    Copy-Item -LiteralPath $built -Destination $Output -Force
}
finally {
    Pop-Location
    $env:Path = $oldPath
    if (Test-Path -LiteralPath $publish) { Remove-Item -LiteralPath $publish -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "Built $Output"
