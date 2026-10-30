#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
  Tests of how wslbin is built: the .NET 10 project (wslbin.csproj, global.json) and the source that has
  to be fit for a single-file Native AOT program, and build.ps1 with the version it puts in the program.
  Run: Invoke-Pester ./tests
#>

BeforeAll {
    $script:Repo = Split-Path -Parent $PSScriptRoot

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
    It 'names the product wslbin: wrappers are recognised by it' {
        Get-ProjectValue 'Product' | Should -BeExactly 'wslbin'
    }
    It 'holds MAJOR.MINOR as VersionPrefix' {
        Get-ProjectValue 'VersionPrefix' | Should -Match '^(0|[1-9]\d*)\.(0|[1-9]\d*)$'
    }
    It 'does not turn on UseSystemResourceKeys: the "internal error" message keeps the texts of exceptions' {
        # (MSBuild reads true in any case)
        Get-ProjectValue 'UseSystemResourceKeys' | Should -Not -Be 'true'
        $props = Join-Path $script:Repo 'Directory.Build.props'
        if (Test-Path $props) { Get-Content -Raw $props | Should -Not -Match '<UseSystemResourceKeys>\s*true' }
    }
    It 'is built with InvariantGlobalization and size first, so the source asks Windows for its language, not CultureInfo' {
        Get-ProjectValue 'InvariantGlobalization' | Should -Be 'true'
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
    It 'sets no assembly attributes: the project does (title, product, description, versions)' {
        Get-ChildItem (Join-Path $script:Repo 'src') -Filter '*.cs' |
            Select-String -Pattern 'Assembly(Title|Product|Description|Version|FileVersion|InformationalVersion)\s*\(' | Should -BeNullOrEmpty
    }
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
    It 'without -Version, the program says what get-version.ps1 gives for this checkout' {
        $expected = Get-WslbinVersion -Repo $script:Repo -Kind local
        # built here, not taken from $global:WslbinTest.Exe: CI hands the tests a program that was built
        # once with the version of its branch (WSLBIN_TEST_EXE)
        $exe = Join-Path (Join-Path $global:WslbinTest.Work ('build-' + [guid]::NewGuid().ToString('N'))) 'wslbin.exe'
        $null = & (Join-Path $global:WslbinTest.Repo 'build.ps1') -Output $exe 6>$null
        (& $exe --version) | Should -BeExactly "wslbin $expected"
    }
    It 'refuses a version that is not SemVer 2.0: <_>' -ForEach @('banana', '1.2', '01.2.3', '1.2.3-', '1.2.3+') {
        { Build-WithVersion $_ } | Should -Throw '*SemVer*'
    }
    It 'builds twice with different versions, and each program says its own' {
        $first = Build-WithVersion '3.0.1-first.1'
        $second = Build-WithVersion '3.0.2-second.2'
        (& $first --version) | Should -BeExactly 'wslbin 3.0.1-first.1'
        (& $second --version) | Should -BeExactly 'wslbin 3.0.2-second.2'
    }
    It 'builds into a folder with a space and non-ASCII letters in its name' {
        $folder = (-join ([char[]](0x41F, 0x440, 0x438, 0x432, 0x435, 0x442))) + ' build'
        $exe = Build-WithVersion '3.1.0-folder.1' -Folder $folder
        (& $exe --version) | Should -BeExactly 'wslbin 3.1.0-folder.1'
    }
    It 'a test build (-ExtraSource, -Main) is a build of its own: the normal program never obeys WSLBIN_TEST_WSL' {
        Initialize-FakeWsl
        $viaFake = New-FakeWsl
        $null = Invoke-Wslbin -Name 'rsync' -Arguments @('x') -Env $viaFake -From $global:WslbinTest.FakeExe
        Test-Path (Join-Path $viaFake.FAKE_WSL_DIR 'calls.txt') | Should -BeTrue

        # a normal build after the test build must not have taken anything of it
        $after = Build-WithVersion '3.2.0-after.1'
        $viaNormal = New-FakeWsl
        $null = Invoke-Wslbin -Name 'rsync' -Arguments @('x') -Env $viaNormal -From $after
        Test-Path (Join-Path $viaNormal.FAKE_WSL_DIR 'calls.txt') | Should -BeFalse
    }
    It 'builds in Windows PowerShell 5.1 too, into a folder with a space' -Skip:(-not (Test-Path (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'))) {
        $winPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $exe = Join-Path $global:WslbinTest.Work 'built by 5.1\wslbin.exe'
        $psi = [Diagnostics.ProcessStartInfo]::new($winPs)
        foreach ($a in '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $script:Repo 'build.ps1'), '-Output', $exe, '-Version', '4.0.0-ps51.1') { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        # Windows PowerShell started from PowerShell 7 with its module path cannot load its own modules
        $null = $psi.Environment.Remove('PSModulePath')
        $p = [Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEndAsync()
        $err = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        $p.ExitCode | Should -Be 0 -Because $err
        (& $exe --version) | Should -BeExactly 'wslbin 4.0.0-ps51.1'
    }
    It 'says why a build fails: the error of the compiler is in the message' {
        $bad = Join-Path $global:WslbinTest.Work 'Broken.cs'
        [IO.File]::WriteAllText($bad, "namespace Broken {`n", [Text.UTF8Encoding]::new($false))
        $out = Join-Path $global:WslbinTest.Work 'broken\wslbin.exe'
        # (callers silence the information stream with 6>$null: the reason must not travel in it)
        { & (Join-Path $global:WslbinTest.Repo 'build.ps1') -Output $out -ExtraSource $bad 6>$null } | Should -Throw '*error CS*'
        Test-Path $out | Should -BeFalse
    }
    It 'leaves PATH as it was, also when the build fails' {
        $bad = Join-Path $global:WslbinTest.Work 'Broken2.cs'
        [IO.File]::WriteAllText($bad, "namespace Broken2 {`n", [Text.UTF8Encoding]::new($false))
        $before = $env:Path
        { & (Join-Path $global:WslbinTest.Repo 'build.ps1') -Output (Join-Path $global:WslbinTest.Work 'broken2\wslbin.exe') -ExtraSource $bad 6>$null } | Should -Throw
        $env:Path | Should -BeExactly $before
    }
    It 'takes several -ExtraSource files (and a relative one, relative to where PowerShell is)' {
        $second = Join-Path $global:WslbinTest.Work 'Second.cs'
        [IO.File]::WriteAllText($second, "namespace Wslbin { internal static class Second { internal static int Value = 3; } }`n", [Text.UTF8Encoding]::new($false))
        $exe = Join-Path $global:WslbinTest.Work 'several\wslbin.exe'
        Push-Location $global:WslbinTest.Work
        try {
            $null = & (Join-Path $global:WslbinTest.Repo 'build.ps1') -Output $exe -Version '3.3.0-several.1' -ExtraSource @((Join-Path $global:WslbinTest.Repo 'tests\FakeWslEntry.cs'), '.\Second.cs') -Main 'Wslbin.FakeWslEntry' 6>$null
        }
        finally { Pop-Location }
        (& $exe --version) | Should -BeExactly 'wslbin 3.3.0-several.1'
    }
    It 'refuses a -Main that is not the name of a class: <_>' -ForEach @('X;Foo=bar', 'two words', 'a"b', '1Start') {
        { & (Join-Path $global:WslbinTest.Repo 'build.ps1') -Output (Join-Path $global:WslbinTest.Work 'nomain\wslbin.exe') -Main $_ 6>$null } | Should -Throw '*-Main*'
    }
    It 'refuses a -Main that ends with a line break' {
        { & (Join-Path $global:WslbinTest.Repo 'build.ps1') -Output (Join-Path $global:WslbinTest.Work 'nomain2\wslbin.exe') -Main "Wslbin.FakeWslEntry`n" 6>$null } | Should -Throw '*-Main*'
    }
    It 'refuses the -ExtraSource path <_>, which MSBuild would read as something else' -ForEach @('C:\a;b.cs', 'C:\a%b.cs', 'C:\a$b.cs', 'C:\a,b.cs') {
        { & (Join-Path $global:WslbinTest.Repo 'build.ps1') -Output (Join-Path $global:WslbinTest.Work 'nopath\wslbin.exe') -ExtraSource $_ 6>$null } | Should -Throw '*-ExtraSource: the path*'
    }
    It 'honours the global.json of the repository wherever it is started from (a pin that no machine has stops the build)' {
        $tree = Join-Path $global:WslbinTest.Work 'strict-pin'
        New-Item -ItemType Directory -Path $tree | Out-Null
        foreach ($item in 'src', 'data', 'docs', 'shell', 'wsl', 'build.ps1', 'wslbin.csproj', 'Directory.Build.props', 'nuget.config', 'Wslbin.Version.psm1') {
            Copy-Item -Recurse (Join-Path $script:Repo $item) $tree
        }
        # dotnet looks for global.json from the folder it runs in; the build must run it from the repository,
        # not from where the person stands, and then no SDK matches this pin
        [IO.File]::WriteAllText((Join-Path $tree 'global.json'), '{ "sdk": { "version": "9.9.999", "rollForward": "disable" } }', [Text.UTF8Encoding]::new($false))
        $psi = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        foreach ($a in '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $tree 'build.ps1'), '-Output', (Join-Path $tree 'out\wslbin.exe'), '-Version', '3.6.0-pin.1') { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.WorkingDirectory = $env:SystemRoot
        $p = [Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEndAsync()
        $err = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        $p.ExitCode | Should -Not -Be 0
        $err | Should -Match '9\.9\.999'
        Test-Path (Join-Path $tree 'out\wslbin.exe') | Should -BeFalse
    }
    It 'builds when it is started from another folder' {
        $exe = Join-Path $global:WslbinTest.Work 'elsewhere\wslbin.exe'
        $psi = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        foreach ($a in '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $script:Repo 'build.ps1'), '-Output', $exe, '-Version', '3.4.0-elsewhere.1') { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.WorkingDirectory = $env:SystemRoot
        $p = [Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEndAsync()
        $err = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        $p.ExitCode | Should -Be 0 -Because $err
        (& $exe --version) | Should -BeExactly 'wslbin 3.4.0-elsewhere.1'
    }
    It 'says in one sentence that the .NET SDK is missing' {
        $psi = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        foreach ($a in '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $script:Repo 'build.ps1'), '-Output', (Join-Path $global:WslbinTest.Work 'no-sdk\wslbin.exe')) { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.Environment['PATH'] = "$env:SystemRoot\System32"
        $null = $psi.Environment.Remove('DOTNET_ROOT')
        $p = [Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEndAsync()
        $err = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        $p.ExitCode | Should -Not -Be 0
        $err | Should -Match '\.NET SDK 10'
        @($err.Trim() -split "`n").Count | Should -BeLessThan 6
    }
    It 'refuses a test build in a repository whose path MSBuild would read as something else' {
        $tree = Join-Path $global:WslbinTest.Work 'with,comma'
        New-Item -ItemType Directory -Path $tree | Out-Null
        foreach ($item in 'build.ps1', 'Wslbin.Version.psm1') { Copy-Item (Join-Path $script:Repo $item) $tree }
        # in a process of its own: the copy of the module must not be loaded into the session of the tests
        $psi = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        foreach ($a in '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $tree 'build.ps1'), '-Output', (Join-Path $tree 'out\wslbin.exe'), '-Version', '3.7.0-comma.1', '-Main', 'Wslbin.FakeWslEntry') { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = [Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEndAsync()
        $err = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        $p.ExitCode | Should -Not -Be 0
        $err | Should -Match 'A test build'
        Test-Path (Join-Path $tree 'out\wslbin.exe') | Should -BeFalse
    }
    # last, so that it comes after every build of this file (it looks at a server that started after the
    # file did; a server that somebody else, an IDE for one, starts in that time would fail it too)
    It 'leaves no build server of the compiler running, after any of the builds of this file' {
        @(Get-Process -Name VBCSCompiler -ErrorAction SilentlyContinue | Where-Object { $_.StartTime -ge $global:BuildTestStarted }) | Should -BeNullOrEmpty
    }
}
