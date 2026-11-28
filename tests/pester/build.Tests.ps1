#Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '6.2.0' }
<#
  Tests of how wslbin is built: the .NET 10 project (wslbin.csproj, global.json) and the source that has
  to be fit for a single-file Native AOT program, and build.ps1 with the version it puts in the program.
  Run: Invoke-Pester ./tests
#>

BeforeAll {
    $script:Repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    # the 22 resources of the program, by name (the csc build had the same ones); a function, because
    # the variables of BeforeDiscovery do not exist in BeforeAll and It
    function Get-ExpectedResourceNames {
        $names = @('wslbin.wsl.complete.sh', 'wslbin.shell.wslbin.ps1', 'wslbin.shell.wslbin.lua', 'wslbin.data.native-versions.txt')
        foreach ($language in 'en', 'ru') {
            foreach ($file in 'ai-context.md', 'completion.txt', 'config.txt', 'env.txt', 'globs.txt', 'help.txt', 'modes.txt', 'paths.txt', 'troubleshooting.txt') {
                $names += "wslbin.docs.$language.$file"
            }
        }
        $names
    }

    Import-Module (Join-Path $script:Repo 'Wslbin.Version.psm1') -Force -DisableNameChecking

    # the official regular expression of semver.org (2.0.0)
    $script:SemVer = '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$'

    function Get-ProjectXml {
        $xml = New-Object System.Xml.XmlDocument
        $xml.Load((Join-Path $script:Repo 'wslbin.csproj'))
        $xml
    }
    # the text of the first element of that name anywhere in wslbin.csproj, or $null
    function Get-ProjectValue([string]$Name) {
        $nodes = @((Get-ProjectXml).SelectNodes("//*[local-name()='$Name']"))
        if ($nodes.Count -eq 0) { return $null }
        $nodes[0].InnerText.Trim()
    }
}

Describe 'wslbin.csproj' {
    It 'is an SDK project for net10.0-windows that publishes Native AOT for win-x64' {
        (Get-ProjectXml).DocumentElement.GetAttribute('Sdk') | Should -BeExactly 'Microsoft.NET.Sdk'
        Get-ProjectValue 'OutputType' | Should -BeExactly 'Exe'
        Get-ProjectValue 'TargetFramework' | Should -BeExactly 'net10.0-windows'
        Get-ProjectValue 'RuntimeIdentifier' | Should -BeExactly 'win-x64'
        Get-ProjectValue 'PublishAot' | Should -BeExactly 'true'
        Get-ProjectValue 'AssemblyName' | Should -BeExactly 'wslbin'
    }
    It 'holds MAJOR.MINOR as VersionPrefix' {
        Get-ProjectValue 'VersionPrefix' | Should -Match '^(0|[1-9]\d*)\.(0|[1-9]\d*)$'
    }
    It 'is built with InvariantGlobalization and size first, so the source asks Windows for its language, not CultureInfo' {
        # InvariantGlobalization lives in Wslbin.Sources.props, which wslbin.csproj imports
        $sources = [xml](Get-Content -Raw (Join-Path $script:Repo 'Wslbin.Sources.props'))
        $sources.SelectNodes("//*[local-name()='InvariantGlobalization']")[0].InnerText.Trim() | Should -Be 'true'
        Get-ProjectValue 'OptimizationPreference' | Should -Be 'Size'
        # with InvariantGlobalization the current culture is the invariant one: it would always be English
        Get-ChildItem (Join-Path $script:Repo 'src') -Filter '*.cs' |
            Select-String -Pattern 'CultureInfo\.(CurrentUICulture|CurrentCulture)' | Should -BeNullOrEmpty
    }
    It 'embeds the 22 resources under their names' {
        $json = & dotnet msbuild (Join-Path $script:Repo 'wslbin.csproj') -getItem:EmbeddedResource -nologo | Out-String
        $names = @(($json | ConvertFrom-Json).Items.EmbeddedResource | ForEach-Object { $_.LogicalName } | Sort-Object)
        $names.Count | Should -Be 22
        $names | Should -Be @(Get-ExpectedResourceNames | Sort-Object)
    }
}

Describe 'global.json' {
    It 'pins the .NET SDK 10 and lets the feature band roll forward' {
        $sdk = (Get-Content -Raw (Join-Path $script:Repo 'global.json') | ConvertFrom-Json).sdk
        $sdk.version | Should -BeExactly '10.0.100'
        $sdk.rollForward | Should -BeExactly 'latestFeature'
    }
}

Describe 'the source of the program' {
    It 'avoids what breaks in a single-file AOT program: Assembly.Location and Marshal.SizeOf(Type)' {
        Get-ChildItem (Join-Path $script:Repo 'src') -Filter '*.cs' |
            Select-String -Pattern 'GetExecutingAssembly\(\)\.Location|Marshal\.SizeOf\(typeof' | Should -BeNullOrEmpty
    }
}

Describe 'the version of this repository' {
    It 'is valid SemVer 2.0' {
        Get-WslbinVersion -Repo $script:Repo -Kind local | Should -Match $script:SemVer
    }
}

Describe 'build.ps1' {
    BeforeAll {
        # (the test of the build servers looks for one that started after this: every build of this file
        # goes through build.ps1, the first one in Initialize-WslbinTest)
        $global:BuildTestStarted = Get-Date
        . (Join-Path $PSScriptRoot 'helpers.ps1')
        Initialize-WslbinTest

        # builds into a folder of its own and returns the path of the program
        function Build-WithVersion {
            param([string]$Version, [string]$Folder = '')
            if (-not $Folder) { $Folder = 'build-' + [guid]::NewGuid().ToString('N') }
            $exe = Join-Path (Join-Path $global:WslbinTest.Work $Folder) 'wslbin.exe'
            $null = & (Join-Path $global:WslbinTest.Repo 'build.ps1') -Output $exe -Version $Version 6>$null
            $exe
        }
    }
    AfterAll {
        Remove-WslbinTest
        Remove-Variable BuildTestStarted -Scope Global -ErrorAction SilentlyContinue
    }

    It '-Version is what --version prints and what the file properties say' {
        $exe = Build-WithVersion '1.2.3-develop.7+abc1234'
        (& $exe --version) | Should -BeExactly 'wslbin 1.2.3-develop.7+abc1234'
        $info = (Get-Item $exe).VersionInfo
        $info.ProductVersion | Should -BeExactly '1.2.3-develop.7+abc1234'
        $info.FileVersion | Should -BeExactly '1.2.3.0'
        $info.ProductName | Should -BeExactly 'wslbin'
    }
    It 'refuses a version that is not SemVer 2.0: <_>' -ForEach @('banana', '1.2', '01.2.3', '1.2.3-', '1.2.3+') {
        { Build-WithVersion $_ } | Should -Throw '*SemVer*'
    }
    It 'says why a build fails: the error of the compiler is in the message' {
        $bad = Join-Path $global:WslbinTest.Work 'Broken.cs'
        [IO.File]::WriteAllText($bad, "namespace Broken {`n", [Text.UTF8Encoding]::new($false))
        $out = Join-Path $global:WslbinTest.Work 'broken\wslbin.exe'
        # (callers silence the information stream with 6>$null: the reason must not travel in it)
        { & (Join-Path $global:WslbinTest.Repo 'build.ps1') -Output $out -ExtraSource $bad 6>$null } | Should -Throw '*error CS*'
        Test-Path $out | Should -BeFalse
    }
    # (the last one has the Kelvin sign, which a match that ignores case takes for k)
    # last, so that it comes after every build of this file (it looks at a server that started after the
    # file did; a server that somebody else, an IDE for one, starts in that time would fail it too)
}
