#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
  Tests of the package and the scripts that install and remove it: .github/make-package.ps1, setup/*.ps1
  and the loader that the site serves (site/install.ps1). Run: Invoke-Pester ./tests

  Nothing here touches the machine: every run names a temporary install folder, profile folder and
  Clink folder, -NoPath, and a registry key of its own under HKCU\Software\wslbin-tests instead of the
  entry in Settings > Apps, so that the real PATH, profiles, Clink scripts and Apps stay as they are. The
  PATH code is tried on a registry key of its own as well, and HKLM is stood in for by a key under
  HKCU\Software\wslbin-tests. The UAC prompt itself cannot be tried unattended: the code that the copy with
  administrator rights runs is run here without them, with a folder of the test in the place of Program
  Files, and the functions that start it are replaced in the tests that run the scripts in this process.
#>

BeforeDiscovery {
    $Shells = @(@{ Shell = 'pwsh'; Exe = 'pwsh' })
    $winPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path $winPs) { $Shells += @{ Shell = 'Windows PowerShell 5.1'; Exe = $winPs } }
    $NoWsl = $true
    try {
        $null = & wsl.exe -l -q 2>$null
        if ($LASTEXITCODE -eq 0) { $NoWsl = $false }
    } catch { }
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers.ps1')
    Initialize-WslbinTest
    $script:Repo = Split-Path -Parent $PSScriptRoot
    $script:MakePackage = Join-Path $script:Repo '.github\make-package.ps1'
    $script:Loader = Join-Path $script:Repo 'site\install.ps1'

    # the functions of the scripts, without running them
    $oldPreference = $ErrorActionPreference
    . (Join-Path $script:Repo 'setup\common.ps1')
    $ErrorActionPreference = $oldPreference

    # A copy of wslbin.exe that differs from it by one byte after the end (a program still runs with that):
    # "the next version" of a package.
    function New-ExeVariant {
        $path = Join-Path $global:WslbinTest.Work ('variant-' + [guid]::NewGuid().ToString('N') + '.exe')
        Copy-Item $global:WslbinTest.Exe $path
        $stream = [IO.File]::Open($path, 'Append'); $stream.WriteByte(0); $stream.Close()
        $path
    }

    # A package as the release makes it, and the folder it unpacks to.
    function New-Package {
        param([string]$Version = '0.1.7', [string]$ExePath = $global:WslbinTest.Exe)
        $base = Join-Path $global:WslbinTest.Work ('pkg-' + [guid]::NewGuid().ToString('N'))
        $dist = Join-Path $base 'dist'
        & $script:MakePackage -Version $Version -Exe $ExePath -OutputDir $dist 6>$null
        $zip = Join-Path $dist "wslbin-$Version-win-x64.zip"
        $dir = Join-Path $base 'unpacked'
        Expand-Archive -LiteralPath $zip -DestinationPath $dir
        [pscustomobject]@{
            Version   = $Version
            Dist      = $dist
            Zip       = $zip
            Dir       = $dir
            Install   = Join-Path $dir 'setup\install.ps1'
            Hash      = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }

    # Runs a script in a child PowerShell with temporary folders for everything it could touch.
    # The installer runs wslbin, which checks names against PATH (the wrappers) and, on uninstall, takes its
    # block out of the instructions of the AI agents: so PATH holds nothing of this machine's programs, and
    # the folders of the agents are ones that do not exist unless -Env names others. TEMP is a folder of
    # its own, so that what the scripts leave there can be seen. ProgramFiles and LOCALAPPDATA are folders
    # of their own too: the uninstaller looks for installations in the usual places, and wslbin may well be
    # installed on the machine that runs the tests. Without -UninstallKey among the arguments the script
    # gets a key of its own, never the real one. -ArgumentLine is a whole command line instead (for
    # -Command): then the caller names the key.
    function Invoke-Script {
        param([string]$Exe, [string]$Script, [string[]]$Arguments, [string]$Folder, [hashtable]$Env = @{}, [string]$ArgumentLine)
        $psi = [Diagnostics.ProcessStartInfo]::new($Exe)
        if ($ArgumentLine) { $psi.Arguments = $ArgumentLine }
        else {
            foreach ($a in '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) { $psi.ArgumentList.Add($a) }
            foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
            if ($Arguments -notcontains '-UninstallKey') {
                $psi.ArgumentList.Add('-UninstallKey')
                $psi.ArgumentList.Add('Software\wslbin-tests\run-' + [guid]::NewGuid().ToString('N'))
            }
        }
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $true
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
        # Windows PowerShell started from PowerShell 7 with its module path cannot load its own modules
        $null = $psi.Environment.Remove('PSModulePath')
        $psi.Environment['WSLBIN_NO_ELEVATION'] = '1'
        $psi.Environment['PATH'] = "$env:SystemRoot\System32"
        $psi.Environment['CLAUDE_CONFIG_DIR'] = Join-Path $global:WslbinTest.Work 'no-claude-folder-here'
        $psi.Environment['CODEX_HOME'] = Join-Path $global:WslbinTest.Work 'no-codex-folder-here'
        $script:LastTemp = Join-Path $global:WslbinTest.Work ('temp-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:LastTemp | Out-Null
        $psi.Environment['TEMP'] = $script:LastTemp
        $psi.Environment['TMP'] = $script:LastTemp
        $psi.Environment['ProgramFiles'] = Join-Path $global:WslbinTest.Work 'no-program-files'
        $psi.Environment['LOCALAPPDATA'] = Join-Path $global:WslbinTest.Work 'no-local-app-data'
        foreach ($key in $Env.Keys) { $psi.Environment[$key] = $Env[$key] }
        if ($Folder) { $psi.WorkingDirectory = $Folder }
        $p = [Diagnostics.Process]::Start($psi)
        $p.StandardInput.Close()
        $e = $p.StandardError.ReadToEndAsync(); $o = $p.StandardOutput.ReadToEnd(); $p.WaitForExit()
        [pscustomobject]@{ Out = $o; Err = $e.Result; ExitCode = $p.ExitCode }
    }

    # setup\install.ps1 of a package
    function Invoke-Installer {
        param([string]$Exe, [object]$Package, [string[]]$Arguments, [string]$Folder, [hashtable]$Env = @{})
        Invoke-Script -Exe $Exe -Script $Package.Install -Arguments $Arguments -Folder $Folder -Env $Env
    }

    # A fresh set of folders for one run: where to install, the profiles, Clink, the key of the Apps entry.
    function New-InstallFolders {
        $base = Join-Path $global:WslbinTest.Work ('install-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $base | Out-Null
        [pscustomobject]@{
            Base    = $base
            Install = Join-Path $base 'wslbin'
            Docs    = Join-Path $base 'Documents'
            Clink   = Join-Path $base 'clink'
            Key     = 'Software\wslbin-tests\apps-' + [guid]::NewGuid().ToString('N')
        }
    }
    function Get-SafeArguments($f) {
        @('-Scope', 'CurrentUser', '-InstallDir', $f.Install, '-NoPath', '-ProfileRoot', $f.Docs, '-ClinkDir', $f.Clink, '-UninstallKey', $f.Key)
    }
    function Get-AppsEntry($f) {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($f.Key)
        if (-not $key) { return $null }
        $entry = @{}
        foreach ($name in $key.GetValueNames()) { $entry[$name] = $key.GetValue($name) }
        $key.Close()
        $entry
    }
    function Install-Test($shell, $package, $f, [string[]]$More = @()) {
        Invoke-Installer -Exe $shell -Package $package -Arguments ((Get-SafeArguments $f) + $More)
    }
    # a key under HKCU\Software\wslbin-tests that stands in for HKLM (the tests have no administrator rights)
    function New-FakeMachineHive {
        [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\wslbin-tests\machine-' + [guid]::NewGuid().ToString('N'))
    }
    # an entry in Apps under a hive (the real HKCU, or a fake HKLM), as the installer writes it
    function Set-TestEntry($Hive, [string]$Key, [string]$Version, [string]$Location) {
        $k = $Hive.CreateSubKey($Key)
        $k.SetValue('DisplayVersion', $Version)
        $k.SetValue('InstallLocation', $Location)
        $k.Close()
    }
}

AfterAll {
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree('Software\wslbin-tests', $false)
    Remove-WslbinTest
}

Describe 'make-package.ps1: the files of a release' {
    BeforeAll {
        $script:Pkg = New-Package -Version '0.1.7'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
    }

    It 'makes the zip, its SHA256 and SHA256SUMS.txt in the format of sha256sum' {
        (Get-ChildItem $script:Pkg.Dist -Name | Sort-Object) | Should -Be @('SHA256SUMS.txt', 'wslbin-0.1.7-win-x64.zip', 'wslbin-0.1.7-win-x64.zip.sha256')
        $expected = "$($script:Pkg.Hash)  wslbin-0.1.7-win-x64.zip`n"
        [IO.File]::ReadAllText((Join-Path $script:Pkg.Dist 'SHA256SUMS.txt')) | Should -BeExactly $expected
        [IO.File]::ReadAllText((Join-Path $script:Pkg.Dist 'wslbin-0.1.7-win-x64.zip.sha256')) | Should -BeExactly $expected
    }

    It 'puts the program, the license, the manifest and the three scripts in the zip, with / in the names' {
        $zip = [IO.Compression.ZipFile]::OpenRead($script:Pkg.Zip)
        try { $names = @($zip.Entries | ForEach-Object { $_.FullName } | Sort-Object) } finally { $zip.Dispose() }
        $names | Should -Be @('LICENSE', 'manifest.json', 'setup/common.ps1', 'setup/install.ps1', 'setup/uninstall.ps1', 'wslbin.exe')
    }

    It 'writes a manifest with the version and the size and SHA256 of every other file' {
        $text = [IO.File]::ReadAllText((Join-Path $script:Pkg.Dir 'manifest.json'))
        $text.Contains("`r") | Should -BeFalse
        $manifest = $text | ConvertFrom-Json
        $manifest.schema | Should -Be 1
        $manifest.version | Should -BeExactly '0.1.7'
        @($manifest.files).Count | Should -Be 5
        foreach ($file in $manifest.files) {
            $path = Join-Path $script:Pkg.Dir $file.path
            $file.size | Should -Be (Get-Item $path).Length
            $file.sha256 | Should -BeExactly (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }

    It 'reads back through the checks of the installer' {
        $manifest = Read-Manifest $script:Pkg.Dir
        $manifest.Version | Should -BeExactly '0.1.7'
        $manifest.Files | Should -Contain 'setup\install.ps1'
        $manifest.Files | Should -Contain 'wslbin.exe'
    }

    It 'refuses a version that is not SemVer 2.0' {
        { & $script:MakePackage -Version 'v0.1' -Exe $global:WslbinTest.Exe -OutputDir (Join-Path $global:WslbinTest.Work 'x') 6>$null } | Should -Throw '*SemVer*'
    }

    It 'takes a version with a pre-release part and build metadata' {
        $p = New-Package -Version '0.2.0-rc.1+abc1234'
        (Read-Manifest $p.Dir).Version | Should -BeExactly '0.2.0-rc.1+abc1234'
    }
}

Describe 'versions: SemVer 2.0 order' {
    It 'orders <Lower> before <Higher>' -ForEach @(
        @{ Lower = '0.1.7'; Higher = '0.1.10' }
        @{ Lower = '0.9.9'; Higher = '0.10.0' }
        @{ Lower = '1.9.0'; Higher = '2.0.0' }
        @{ Lower = '1.0.0-alpha'; Higher = '1.0.0-alpha.1' }
        @{ Lower = '1.0.0-alpha.1'; Higher = '1.0.0-alpha.beta' }
        @{ Lower = '1.0.0-alpha.beta'; Higher = '1.0.0-beta' }
        @{ Lower = '1.0.0-beta'; Higher = '1.0.0-beta.2' }
        @{ Lower = '1.0.0-beta.2'; Higher = '1.0.0-beta.11' }
        @{ Lower = '1.0.0-beta.11'; Higher = '1.0.0-rc.1' }
        @{ Lower = '1.0.0-rc.1'; Higher = '1.0.0' }
        @{ Lower = '0.1.4-develop.9+aaaaaaa'; Higher = '0.1.4' }
        @{ Lower = '0.1.4-develop.9'; Higher = '0.1.4-develop.10' }
        @{ Lower = '99999999999999999999.0.0'; Higher = '100000000000000000000.0.0' }
    ) {
        Compare-SemVer $Lower $Higher | Should -Be -1
        Compare-SemVer $Higher $Lower | Should -Be 1
    }

    It 'calls versions equal that differ in build metadata only' {
        Compare-SemVer '0.1.7+aaa' '0.1.7+bbb' | Should -Be 0
        Compare-SemVer '0.1.7' '0.1.7' | Should -Be 0
    }

    It 'knows what is not a version: <Text>' -ForEach @(
        @{ Text = '1.2' }, @{ Text = 'v1.2.3' }, @{ Text = '01.2.3' }, @{ Text = '1.2.3-' }, @{ Text = '1.2.3-01' }, @{ Text = '1.2.3.4' }, @{ Text = '' }, @{ Text = 'latest' }
    ) {
        ConvertFrom-SemVer $Text | Should -BeNullOrEmpty
        { Compare-SemVer $Text '1.0.0' } | Should -Throw '*SemVer*'
    }

    It 'takes ASCII only: not the Kelvin sign that -match takes for a k, not the digits of other scripts (<Name>)' -ForEach @(
        @{ Name = 'Kelvin sign'; Code = 0x212A; Prefix = '1.0.0-' }
        @{ Name = 'Arabic-Indic digit'; Code = 0x0661; Prefix = '1.0.' }
    ) {
        $text = $Prefix + [char]$Code
        ConvertFrom-SemVer $text | Should -BeNullOrEmpty
    }

    It 'has one definition of a version: the same pattern in Wslbin.Version.psm1, setup\common.ps1 and the loader' {
        $patterns = foreach ($relative in 'Wslbin.Version.psm1', 'setup\common.ps1', 'site\install.ps1') {
            $found = [regex]::Matches([IO.File]::ReadAllText((Join-Path $script:Repo $relative)), "(?m)^\s*\`$(?:script:)?SemVerPattern = '([^']+)'\s*$")
            $found.Count | Should -Be 1 -Because $relative
            $found[0].Groups[1].Value
        }
        @($patterns).Count | Should -Be 3
        @($patterns | Select-Object -Unique).Count | Should -Be 1
        # and the scripts of the release take it from the module, not from a copy of their own
        foreach ($relative in '.github\make-package.ps1', '.github\new-releases-json.ps1') {
            $text = [IO.File]::ReadAllText((Join-Path $script:Repo $relative))
            $text | Should -Match 'Import-Module \(Join-Path \$PSScriptRoot ''\.\.\\Wslbin\.Version\.psm1''\) -DisableNameChecking -Scope Local' -Because $relative
            $text | Should -Not -Match '\[1-9\]\[0-9\]\*\)\\\.' -Because $relative
        }
    }
}

Describe 'setup: PATH in the registry' {
    BeforeAll {
        $script:KeyPath = "Software\wslbin-tests\path-$([guid]::NewGuid().ToString('N'))"
        $script:Hive = [Microsoft.Win32.Registry]::CurrentUser
        function Reset-TestKey([string]$Value, [Microsoft.Win32.RegistryValueKind]$Kind = 'ExpandString') {
            $k = $script:Hive.CreateSubKey($script:KeyPath)
            if ($null -ne $Value) { $k.SetValue('Path', $Value, $Kind) }
            $k.Close()
        }
        function Read-TestPath { $k = $script:Hive.OpenSubKey($script:KeyPath); $v = $k.GetValue('Path', '', 'DoNotExpandEnvironmentNames'); $kind = $k.GetValueKind('Path'); $k.Close(); [pscustomobject]@{ Value = $v; Kind = $kind } }
    }
    AfterAll {
        $script:Hive.DeleteSubKeyTree($script:KeyPath, $false)
    }

    It 'adds a folder at the end and keeps what is there, %VARIABLES% included' {
        Reset-TestKey 'C:\Windows;%SystemRoot%\System32;C:\Tools'
        (Set-PathEntry -Hive $script:Hive -SubKey $script:KeyPath -Entry 'C:\wslbin') | Should -BeTrue
        (Read-TestPath).Value | Should -BeExactly 'C:\Windows;%SystemRoot%\System32;C:\Tools;C:\wslbin'
    }

    It 'keeps the kind of the value' {
        Reset-TestKey 'C:\Windows' 'ExpandString'
        $null = Set-PathEntry -Hive $script:Hive -SubKey $script:KeyPath -Entry 'C:\wslbin'
        (Read-TestPath).Kind | Should -Be 'ExpandString'
        Reset-TestKey 'C:\Windows' 'String'
        $null = Set-PathEntry -Hive $script:Hive -SubKey $script:KeyPath -Entry 'C:\wslbin'
        (Read-TestPath).Kind | Should -Be 'String'
    }

    It 'does nothing when the folder is there already, whatever the case, quotes or slash at the end' {
        Reset-TestKey 'C:\Windows;"c:\WSLBIN\"'
        (Set-PathEntry -Hive $script:Hive -SubKey $script:KeyPath -Entry 'C:\wslbin') | Should -BeFalse
        (Read-TestPath).Value | Should -BeExactly 'C:\Windows;"c:\WSLBIN\"'
    }

    It 'sees a folder written with a variable as the same folder' {
        $env:WSLBIN_TEST_ROOT = 'C:\somewhere'
        try {
            Reset-TestKey 'C:\Windows;%WSLBIN_TEST_ROOT%\bin'
            (Set-PathEntry -Hive $script:Hive -SubKey $script:KeyPath -Entry 'C:\somewhere\bin') | Should -BeFalse
        }
        finally { Remove-Item Env:WSLBIN_TEST_ROOT }
    }

    It 'removes only that folder' {
        Reset-TestKey 'C:\Windows;C:\wslbin;C:\Tools;c:\wslbin\'
        (Set-PathEntry -Hive $script:Hive -SubKey $script:KeyPath -Entry 'C:\wslbin' -Remove) | Should -BeTrue
        (Read-TestPath).Value | Should -BeExactly 'C:\Windows;C:\Tools'
        (Set-PathEntry -Hive $script:Hive -SubKey $script:KeyPath -Entry 'C:\wslbin' -Remove) | Should -BeFalse
    }

    It 'makes the value when there is none' {
        $script:Hive.DeleteSubKeyTree($script:KeyPath, $false)
        (Set-PathEntry -Hive $script:Hive -SubKey $script:KeyPath -Entry 'C:\wslbin') | Should -BeTrue
        (Read-TestPath).Value | Should -BeExactly 'C:\wslbin'
    }

    It 'does not leave an empty entry behind when the last folder goes' {
        Reset-TestKey 'C:\wslbin'
        $null = Set-PathEntry -Hive $script:Hive -SubKey $script:KeyPath -Entry 'C:\wslbin' -Remove
        (Read-TestPath).Value | Should -BeExactly ''
    }
}

Describe 'setup: blocks in profiles' {
    BeforeAll {
        function New-TestFile([string]$Text, [bool]$Bom = $false, [string]$Name = 'profile.ps1') {
            $p = Join-Path $global:WslbinTest.Work ([guid]::NewGuid().ToString('N') + '-' + $Name)
            if ($null -ne $Text) { [IO.File]::WriteAllText($p, $Text, [Text.UTF8Encoding]::new($Bom)) }
            $p
        }
    }

    It 'makes the file when there is none, with the folder' {
        $p = Join-Path $global:WslbinTest.Work "$([guid]::NewGuid().ToString('N'))\sub\profile.ps1"
        Set-MarkedBlock $p 'Write-Host hello'
        (Get-Content -Raw $p) | Should -Match '(?s)^# >>> wslbin >>>.*\nWrite-Host hello\r?\n# <<< wslbin <<<'
    }

    It 'adds the block after what the file holds, with a blank line between' {
        $p = New-TestFile "# mine`nSet-Alias gs git`n"
        Set-MarkedBlock $p 'Write-Host hello'
        (Get-Content -Raw $p).Replace("`r`n", "`n") | Should -Match '(?s)^# mine\nSet-Alias gs git\n\n# >>> wslbin >>>'
    }

    It 'replaces its own block in place, once' {
        $p = New-TestFile "before`n"
        Set-MarkedBlock $p 'one'
        Add-Content $p "after"
        Set-MarkedBlock $p 'two'
        $text = (Get-Content -Raw $p).Replace("`r`n", "`n")
        $text | Should -Match '(?s)^before\n\n# >>> wslbin >>>.*\ntwo\n# <<< wslbin <<<\nafter'
        $text | Should -Not -Match 'one'
        @([regex]::Matches($text, '>>> wslbin')).Count | Should -Be 1
    }

    It 'follows the line ends of the file' {
        $p = New-TestFile "# mine`r`nSet-Alias gs git`r`n"
        Set-MarkedBlock $p 'Write-Host hello'
        $text = [IO.File]::ReadAllText($p)
        ($text -replace "`r`n", '').Contains("`n") | Should -BeFalse
        $p2 = New-TestFile "# mine`nline`n"
        Set-MarkedBlock $p2 'Write-Host hello'
        [IO.File]::ReadAllText($p2).Contains("`r") | Should -BeFalse
    }

    It 'keeps a byte order mark, and adds one to a new file only when the text needs it' {
        $p = New-TestFile "# mine`n" $true
        Set-MarkedBlock $p 'x'
        $b = [IO.File]::ReadAllBytes($p)
        ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) | Should -BeTrue
        $ascii = New-TestFile $null
        Set-MarkedBlock $ascii 'x'
        ([IO.File]::ReadAllBytes($ascii)[0]) | Should -Not -Be 0xEF
        $cyr = New-TestFile $null
        Set-MarkedBlock $cyr ('# ' + (-join ([char[]](0x044F, 0x0437, 0x044B, 0x043A))))
        ([IO.File]::ReadAllBytes($cyr)[0]) | Should -Be 0xEF
    }

    It 'takes the block out and leaves the rest as it was' {
        $original = "# mine`nSet-Alias gs git`n"
        $p = New-TestFile $original
        Set-MarkedBlock $p 'one'
        (Remove-MarkedBlock $p) | Should -BeTrue
        (Get-Content -Raw $p).Replace("`r`n", "`n") | Should -BeExactly $original
    }

    It 'deletes a file that held nothing but the block' {
        $p = New-TestFile $null
        Set-MarkedBlock $p 'one'
        (Remove-MarkedBlock $p) | Should -BeTrue
        Test-Path $p | Should -BeFalse
    }

    It 'says no when there is no block, or no file' {
        $p = New-TestFile "# mine`n"
        (Remove-MarkedBlock $p) | Should -BeFalse
        (Get-Content -Raw $p) | Should -BeExactly "# mine`n"
        (Remove-MarkedBlock (Join-Path $global:WslbinTest.Work 'no-such-file.ps1')) | Should -BeFalse
    }
}

Describe 'setup: files it must not damage, and the elevated copy' {
    BeforeAll {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CommandLineParser
{
    [DllImport("shell32.dll", SetLastError = true)]
    static extern IntPtr CommandLineToArgvW([MarshalAs(UnmanagedType.LPWStr)] string commandLine, out int count);
    public static string[] Split(string commandLine)
    {
        int count;
        IntPtr list = CommandLineToArgvW(commandLine, out count);
        var result = new string[count];
        for (int i = 0; i < count; i++) result[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(list, i * IntPtr.Size));
        return result;
    }
}
'@ -ErrorAction SilentlyContinue
    }

    It 'leaves a profile alone that is not UTF-8 text, in both functions' -ForEach @(
        @{ Kind = 'ANSI (cp1251)'; Bytes = [byte[]](0x23, 0x20, 0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2, 0x0A) }
        @{ Kind = 'UTF-16 with a mark'; Bytes = [byte[]]([Text.Encoding]::Unicode.GetPreamble() + [Text.Encoding]::Unicode.GetBytes("# hi`n")) }
        @{ Kind = 'UTF-16 without a mark'; Bytes = [byte[]][Text.Encoding]::Unicode.GetBytes("# hi`n") }
    ) {
        $p = Join-Path $global:WslbinTest.Work ([guid]::NewGuid().ToString('N') + '-profile.ps1')
        [IO.File]::WriteAllBytes($p, $Bytes)
        { Set-MarkedBlock $p 'x' } | Should -Throw '*not UTF-8*'
        { Remove-MarkedBlock $p } | Should -Throw '*not UTF-8*'
        [IO.File]::ReadAllBytes($p) | Should -Be $Bytes
    }

    It 'refuses to guess when a marker has lost its partner (<Case>)' -ForEach @(
        @{ Case = 'begin without end'; Text = "# mine`n# >>> wslbin >>> old`nMy own important lines`n" }
        @{ Case = 'end without begin'; Text = "# mine`nMy own lines`n# <<< wslbin <<<`n" }
    ) {
        $p = Join-Path $global:WslbinTest.Work ([guid]::NewGuid().ToString('N') + '-profile.ps1')
        [IO.File]::WriteAllText($p, $Text, [Text.UTF8Encoding]::new($false))
        { Set-MarkedBlock $p 'x' } | Should -Throw '*without its other half*'
        { Remove-MarkedBlock $p } | Should -Throw '*without its other half*'
        [IO.File]::ReadAllText($p) | Should -BeExactly $Text
    }

    It 'quotes an argument so that the command-line parser of Windows reads it back as it was' {
        foreach ($value in 'C:\src\wslbin\', 'C:\a b\c', 'x"y', 'plain', 'C:\dir with space\', 'tail\\', 'a"b\"c', 'C:\Program Files\wslbin') {
            $parts = [CommandLineParser]::Split('prog -PackageDir ' + (ConvertTo-CommandLineArgument $value) + ' -Next')
            $parts.Count | Should -Be 4 -Because $value
            $parts[2] | Should -BeExactly $value
        }
    }

    It 'hands the parameters that were given on to a copy that starts again, as a command line and as PowerShell literals' {
        $script:BoundParameters = @{ InstallDir = 1; Link = 1; NoPath = 1; Force = 1; Scope = 1 }
        # a quote, a typographic quote (PowerShell takes it for '), letters outside ASCII, a \ at the end
        $InstallDir = "C:\it's " + [char]0x2019 + 'q' + [char]0x2019 + ' ' + (-join ([char[]](0x043F, 0x0440, 0x043E, 0x0433))) + '\'
        $Link = @('make', 'rsync')
        $NoPath = [switch]$true
        $Force = [switch]$false
        $Scope = 'AllUsers'

        $tokens = @(Get-ParameterTokens @('InstallDir', 'Link', 'NoPath', 'Force', 'NotGiven'))
        $parts = [CommandLineParser]::Split('powershell ' + ($tokens -join ' '))
        $parts[1..($parts.Count - 1)] | Should -Be @('-InstallDir', $InstallDir, '-Link', 'make,rsync', '-NoPath')

        $literal = @(Get-ParameterTokens @('InstallDir', 'Link', 'NoPath', 'Force') -PowerShell)
        $literal.Count | Should -Be 5
        $literal[0] | Should -BeExactly '-InstallDir'
        [string]::Equals((Invoke-Expression $literal[1]), $InstallDir, [StringComparison]::Ordinal) | Should -BeTrue
        (Invoke-Expression $literal[3]) | Should -BeExactly 'make,rsync'
        $literal[4] | Should -BeExactly '-NoPath'
        # every character outside ASCII is a [char] code: nothing a code page can damage
        ($literal -join ' ') | Should -Not -Match '[^\u0000-\u007F]'
    }

    It 'puts the code of the copy with administrator rights on its command line as one argument, without a double quote in it' {
        $files = @([pscustomobject]@{ Source = "C:\Users\o'neil\AppData\Local\Temp\x\wslbin.exe"; Path = 'wslbin.exe'; Sha256 = ('ab' * 32) })
        $command = Get-ElevatedCommand $files 'setup\install.ps1' @('-Scope', 'AllUsers', '-Elevated')
        $command.Contains('"') | Should -BeFalse
        $parts = [CommandLineParser]::Split('powershell ' + (Get-ElevatedArgumentLine $command))
        $parts.Count | Should -Be 6
        $parts[1..4] | Should -Be @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command')
        $parts[5] | Should -BeExactly $command
        # it puts the checked files under Program Files, which only administrators can write
        $command | Should -Match "\[Environment\]::GetFolderPath\('ProgramFiles'\)"
        $command | Should -Match "'C:\\Users\\o''neil\\AppData"
    }
}

Describe 'setup: small helpers' {
    It 'tells a right hash from a wrong one' {
        $f = Join-Path $global:WslbinTest.Work 'hash-me.txt'
        [IO.File]::WriteAllText($f, 'abc')
        $good = (Get-FileHash $f -Algorithm SHA256).Hash
        { Test-FileHash $f $good } | Should -Not -Throw
        { Test-FileHash $f $good.ToLowerInvariant() } | Should -Not -Throw
        { Test-FileHash $f ('0' * 64) } | Should -Throw '*SHA256*'
    }

    It 'reads the execution policy of a PowerShell without the Process scope that this one hands on' {
        $winPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $saved = $env:PSExecutionPolicyPreference
        try {
            $env:PSExecutionPolicyPreference = 'AllSigned'
            $first = Get-ProfileExecutionPolicy $winPs
            $env:PSExecutionPolicyPreference = 'Unrestricted'
            $second = Get-ProfileExecutionPolicy $winPs
        }
        finally {
            if ($null -eq $saved) { Remove-Item Env:\PSExecutionPolicyPreference -ErrorAction SilentlyContinue } else { $env:PSExecutionPolicyPreference = $saved }
        }
        $first | Should -BeIn @('Restricted', 'AllSigned', 'RemoteSigned', 'Unrestricted', 'Bypass', 'Default', 'Undefined')
        $second | Should -BeExactly $first
    }

    It 'takes each folder once, whatever the case, a \ at the end or a relative spelling' {
        $base = $global:WslbinTest.Work
        $all = @(Select-UniquePath @((Join-Path $base 'One'), (Join-Path $base 'one\'), (Join-Path $base 'ONE'), '', (Join-Path $base 'two')))
        $all | Should -Be @((Join-Path $base 'One'), (Join-Path $base 'two'))
    }

    It 'takes "a,b", "a", "b" and blanks as one list' {
        (Split-List 'a,b') | Should -Be @('a', 'b')
        (Split-List @('a', 'b,c', ' ', '')) | Should -Be @('a', 'b', 'c')
        @(Split-List @()).Count | Should -Be 0
    }
}

Describe 'setup: the folder of an installation for all users' {
    BeforeAll {
        $script:Me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        function New-TestSecurity([string]$Owner, [object[]]$Rules) {
            $security = New-Object Security.AccessControl.DirectorySecurity
            $security.SetOwner((New-Object Security.Principal.SecurityIdentifier $Owner))
            foreach ($r in $Rules) {
                $flags = $(if ($r.Count -gt 2) { $r[2] } else { 'None' })
                $rule = New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier $r[0]), [Security.AccessControl.FileSystemRights]$r[1], 'ContainerInherit, ObjectInherit', $flags, 'Allow')
                $security.AddAccessRule($rule)
            }
            $security
        }
    }

    It 'trusts administrators, SYSTEM and TrustedInstaller, and lets everyone read' {
        $acl = New-TestSecurity 'S-1-5-32-544' @(@('S-1-5-32-544', 'FullControl'), @('S-1-5-18', 'FullControl'), @('S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464', 'FullControl'), @('S-1-5-32-545', 'ReadAndExecute'), @('S-1-1-0', 'Read'))
        @(Get-FolderWriters $acl $TrustedSids).Count | Should -Be 0
    }

    It 'names an account that may change the folder, and an owner that is not trusted' {
        $acl = New-TestSecurity $script:Me @(@('S-1-5-32-544', 'FullControl'), @('S-1-5-11', 'Modify'))
        $writers = @(Get-FolderWriters $acl $TrustedSids)
        $writers.Count | Should -Be 2
        $writers[0] | Should -Match '\(the owner\)$'
        @(Get-FolderWriters (New-TestSecurity 'S-1-5-32-544' @(, @('S-1-5-11', 'AppendData'))) $TrustedSids).Count | Should -Be 1
        @(Get-FolderWriters (New-TestSecurity 'S-1-5-32-544' @(, @('S-1-5-11', 'Delete'))) $TrustedSids).Count | Should -Be 1
        @(Get-FolderWriters (New-TestSecurity 'S-1-5-32-544' @(, @('S-1-5-11', 'ChangePermissions'))) $TrustedSids).Count | Should -Be 1
    }

    It 'on a folder above, counts only what lets an account take the folder away, and not rights for the children only' {
        # C:\ lets every account make a folder in it, and gives them Modify on what is made (inherit only)
        $acl = New-TestSecurity 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464' @(@('S-1-5-11', 'CreateDirectories'), @('S-1-5-11', 'Modify', 'InheritOnly'))
        @(Get-FolderWriters $acl $TrustedSids -Mask $TakeAwayRights -Ancestor).Count | Should -Be 0
        @(Get-FolderWriters $acl $TrustedSids).Count | Should -Be 1
        @(Get-FolderWriters (New-TestSecurity 'S-1-5-32-544' @(, @('S-1-5-11', 'Delete'))) $TrustedSids -Mask $TakeAwayRights -Ancestor).Count | Should -Be 1
    }

    It 'passes the usual place under Program Files, and refuses a folder of the user (the folder itself and those above)' {
        @(Get-MachineFolderWriters (Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'wslbin')).Count | Should -Be 0
        $mine = Join-Path $global:WslbinTest.Work ('mine-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $mine | Out-Null
        $writers = @(Get-MachineFolderWriters $mine)
        $writers.Count | Should -BeGreaterThan 0
        ($writers -join "`n") | Should -Match ([regex]::Escape($mine))
    }

    It 'makes a new folder with the rights of administrators only, nothing inherited, in <Shell>' -ForEach $Shells {
        $dir = Join-Path $global:WslbinTest.Work ('machine-' + [guid]::NewGuid().ToString('N') + '\a\wslbin')
        $command = "`$ErrorActionPreference = 'Stop'; . '$($script:Repo)\setup\common.ps1'; New-MachineFolder '$dir'"
        $r = Invoke-Script -Exe $Exe -ArgumentLine ('-NoProfile -ExecutionPolicy Bypass -Command ' + (ConvertTo-CommandLineArgument $command))
        $r.ExitCode | Should -Be 0 -Because $r.Err
        $acl = Get-Acl -LiteralPath $dir
        $acl.AreAccessRulesProtected | Should -BeTrue
        $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        @($rules | Where-Object { $_.IsInherited }).Count | Should -Be 0
        @($rules | ForEach-Object { $_.IdentityReference.Value } | Sort-Object) | Should -Be @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-32-545')
        # the folder is made by this account, which is no administrator here: that much it says
        (@(Get-FolderWriters $acl $TrustedSids) -join "`n") | Should -Match '\(the owner\)$'
    }

    It 'refuses an installation for all users in a folder that others can change, and installs nothing' {
        $mine = Join-Path $global:WslbinTest.Work ('mine-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $mine | Out-Null
        { Initialize-MachineFolder $mine } | Should -Throw '*can be changed by others than administrators*Nothing was installed*'
    }
}

Describe 'setup: the environment and the copy with administrator rights' {
    It 'tells running programs that the environment changed without compiling anything, and leaves no variable behind' {
        Send-EnvironmentChange
        'Wslbin.NativeMethods' -as [type] | Should -BeNullOrEmpty
        # (the variables of the user are real here: what a broken version wrote is taken out again)
        $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
        try {
            $left = @($k.GetValueNames() | Where-Object { $_ -like 'WSLBIN_NO_SUCH_VARIABLE_*' })
            foreach ($name in $left) { $k.DeleteValue($name) }
        }
        finally { $k.Close() }
        $left.Count | Should -Be 0
    }

    It 'runs the checked copy in this console, with no UAC prompt and no pause, when it has administrator rights already' {
        $script:Started = $null
        function Test-Administrator { $true }
        function Start-Process {
            param($FilePath, $ArgumentList, [switch]$Wait, [switch]$PassThru, $WorkingDirectory, [switch]$NoNewWindow, $Verb)
            $script:Started = @{}
            foreach ($key in $PSBoundParameters.Keys) { $script:Started[$key] = $PSBoundParameters[$key] }
            [pscustomobject]@{ ExitCode = 0 }
        }
        $saved = $env:WSLBIN_NO_ELEVATION
        try {
            $env:WSLBIN_NO_ELEVATION = '1'
            Invoke-Elevated @() 'setup\install.ps1' @('-Elevated') | Should -Be 0
        }
        finally { $env:WSLBIN_NO_ELEVATION = $saved }
        $script:Started.ContainsKey('Verb') | Should -BeFalse
        $script:Started.NoNewWindow | Should -BeTrue
        $script:Started.ArgumentList | Should -Match ([regex]::Escape('-and $false -and'))
        (Get-ElevatedCommand @() 'setup\install.ps1' @()) | Should -Match ([regex]::Escape('$code -ne 0 -and $true -and'))
    }
}

Describe 'setup: the manifest is checked before anything is installed' {
    BeforeAll {
        # a package folder whose manifest.json says what the test needs
        function New-ManifestFolder([string]$Json, [hashtable]$Files = @{}) {
            $dir = Join-Path $global:WslbinTest.Work ('manifest-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir | Out-Null
            foreach ($name in $Files.Keys) {
                $path = Join-Path $dir $name
                New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
                [IO.File]::WriteAllText($path, $Files[$name])
            }
            [IO.File]::WriteAllText((Join-Path $dir 'manifest.json'), $Json)
            $dir
        }
    }

    It 'refuses a folder without manifest.json' {
        $dir = Join-Path $global:WslbinTest.Work ('empty-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        { Read-Manifest $dir } | Should -Throw '*no manifest.json*'
    }

    It 'refuses a file that was changed after the manifest was made' {
        $p = New-Package
        [IO.File]::AppendAllText((Join-Path $p.Dir 'LICENSE'), 'tampered')
        { Read-Manifest $p.Dir } | Should -Throw '*SHA256*'
    }

    It 'refuses a file that is named and not there' {
        $p = New-Package
        Remove-Item (Join-Path $p.Dir 'setup\common.ps1')
        { Read-Manifest $p.Dir } | Should -Throw '*not in the package*'
    }

    It 'refuses a path that leaves the package: <Path>' -ForEach @(
        @{ Path = '../evil.ps1' }, @{ Path = '..\evil.ps1' }, @{ Path = 'C:\Windows\x.exe' }, @{ Path = '\x' }, @{ Path = 'a/../../x' }, @{ Path = 'setup//x' }
    ) {
        $json = '{"schema":1,"version":"0.1.7","files":[{"path":"' + $Path.Replace('\', '\\') + '","sha256":"' + ('0' * 64) + '"}]}'
        $dir = New-ManifestFolder $json
        { Read-Manifest $dir } | Should -Throw '*not inside the package*'
    }

    It 'refuses a wrong schema, a wrong version, a missing hash and a package without the program' {
        $dir = New-ManifestFolder '{"schema":2,"version":"0.1.7","files":[]}'
        { Read-Manifest $dir } | Should -Throw '*schema*'
        $dir = New-ManifestFolder '{"schema":1,"version":"v1","files":[]}'
        { Read-Manifest $dir } | Should -Throw '*valid version*'
        $dir = New-ManifestFolder '{"schema":1,"version":"0.1.7","files":[{"path":"wslbin.exe"}]}' @{ 'wslbin.exe' = 'x' }
        { Read-Manifest $dir } | Should -Throw '*no SHA256*'
        $dir = New-ManifestFolder '{"schema":1,"version":"0.1.7","files":[]}'
        { Read-Manifest $dir } | Should -Throw '*does not name wslbin.exe*'
    }
}

Describe 'setup: laying files out, all or nothing' {
    BeforeAll {
        function New-Layout {
            $base = Join-Path $global:WslbinTest.Work ('layout-' + [guid]::NewGuid().ToString('N'))
            $package = Join-Path $base 'package'
            $dir = Join-Path $base 'dir'
            New-Item -ItemType Directory -Path (Join-Path $package 'setup'), (Join-Path $dir 'setup') | Out-Null
            [IO.File]::WriteAllText((Join-Path $package 'wslbin.exe'), 'new exe')
            [IO.File]::WriteAllText((Join-Path $package 'LICENSE'), 'new license')
            [IO.File]::WriteAllText((Join-Path $package 'setup\install.ps1'), 'new install')
            [pscustomobject]@{ Package = $package; Dir = $dir; Files = @('wslbin.exe', 'LICENSE', 'setup\install.ps1') }
        }
    }

    It 'puts the files and the wrappers in, renames what was there to .old, and deletes the .old files when it is told to' {
        $l = New-Layout
        [IO.File]::WriteAllText((Join-Path $l.Dir 'wslbin.exe'), 'old exe')
        [IO.File]::WriteAllText((Join-Path $l.Dir 'alpha.exe'), 'old wrapper')
        $placement = Install-Files $l.Package $l.Files @('alpha') $l.Dir
        [IO.File]::ReadAllText((Join-Path $l.Dir 'wslbin.exe')) | Should -BeExactly 'new exe'
        [IO.File]::ReadAllText((Join-Path $l.Dir 'alpha.exe')) | Should -BeExactly 'new exe'
        [IO.File]::ReadAllText((Join-Path $l.Dir 'setup\install.ps1')) | Should -BeExactly 'new install'
        [IO.File]::ReadAllText((Join-Path $l.Dir 'wslbin.exe.old')) | Should -BeExactly 'old exe'
        Complete-Placement $placement
        (Get-ChildItem $l.Dir -Recurse -File -Name | Sort-Object) | Should -Be @('alpha.exe', 'LICENSE', 'setup\install.ps1', 'wslbin.exe')
    }

    It 'puts the old files back when the work after it fails' {
        $l = New-Layout
        [IO.File]::WriteAllText((Join-Path $l.Dir 'wslbin.exe'), 'old exe')
        $placement = Install-Files $l.Package $l.Files @() $l.Dir
        Undo-Placement $placement
        [IO.File]::ReadAllText((Join-Path $l.Dir 'wslbin.exe')) | Should -BeExactly 'old exe'
        (Get-ChildItem $l.Dir -Recurse -File -Name | Sort-Object) | Should -Be @('wslbin.exe')
    }

    It 'leaves the old version as it was when a file cannot be replaced' {
        $l = New-Layout
        [IO.File]::WriteAllText((Join-Path $l.Dir 'wslbin.exe'), 'old exe')
        [IO.File]::WriteAllText((Join-Path $l.Dir 'LICENSE'), 'old license')
        # the second file is held by a program: the first one has been replaced by then
        $lock = [IO.File]::Open((Join-Path $l.Dir 'LICENSE'), 'Open', 'Read', 'None')
        try { { Install-Files $l.Package $l.Files @() $l.Dir } | Should -Throw '*Could not replace the files*' }
        finally { $lock.Close() }
        [IO.File]::ReadAllText((Join-Path $l.Dir 'wslbin.exe')) | Should -BeExactly 'old exe'
        [IO.File]::ReadAllText((Join-Path $l.Dir 'LICENSE')) | Should -BeExactly 'old license'
        (Get-ChildItem $l.Dir -Recurse -File -Name | Sort-Object) | Should -Be @('LICENSE', 'wslbin.exe')
    }

    It 'deletes the files that an earlier run could not delete' {
        $l = New-Layout
        [IO.File]::WriteAllText((Join-Path $l.Dir 'wslbin.exe.old'), 'left')
        [IO.File]::WriteAllText((Join-Path $l.Dir 'setup\install.ps1.old'), 'left')
        [IO.File]::WriteAllText((Join-Path $l.Dir 'alpha.exe.old'), 'left')
        $null = Install-Files $l.Package $l.Files @('alpha') $l.Dir
        (Get-ChildItem $l.Dir -Recurse -File -Name | Where-Object { $_ -like '*.old' }) | Should -BeNullOrEmpty
    }

    It 'leaves files alone that end in .old and are not its own (the folder may hold the user''s)' {
        $l = New-Layout
        New-Item -ItemType Directory -Path (Join-Path $l.Dir 'notes') | Out-Null
        # (notes.older has the short name NOTES~1.OLD, which a filter *.old of Windows PowerShell 5.1 matches)
        foreach ($name in 'backup.old', 'notes\draft.old', 'notes.older', 'LICENSE.older') {
            [IO.File]::WriteAllText((Join-Path $l.Dir $name), 'mine')
        }
        $null = Install-Files $l.Package $l.Files @() $l.Dir
        foreach ($name in 'backup.old', 'notes\draft.old', 'notes.older', 'LICENSE.older') {
            Test-Path -LiteralPath (Join-Path $l.Dir $name) | Should -BeTrue -Because $name
        }
    }
}

Describe 'setup\install.ps1 in <Shell>' -ForEach $Shells {
    It 'installs the package, keeps wslbin.ini, writes the Apps entry and hooks the shells in' {
        $p = New-Package -Version '0.1.7'
        $f = New-InstallFolders
        New-Item -ItemType Directory -Path $f.Install, $f.Clink, (Join-Path $f.Docs 'PowerShell') | Out-Null
        [IO.File]::WriteAllText((Join-Path $f.Install 'wslbin.ini'), "raw = grep`n")
        [IO.File]::WriteAllText((Join-Path $f.Docs 'PowerShell\profile.ps1'), "# mine`n")

        $r = Install-Test $Exe $p $f @('-Completion', 'pwsh,clink')
        $r.ExitCode | Should -Be 0 -Because $r.Err
        & (Join-Path $f.Install 'wslbin.exe') --version | Should -Match '^wslbin \d+\.\d+\.\d+'
        (Get-ChildItem $f.Install -Recurse -File -Name | Sort-Object) | Should -Be @('LICENSE', 'manifest.json', 'setup\common.ps1', 'setup\install.ps1', 'setup\uninstall.ps1', 'wslbin.exe', 'wslbin.ini')
        Get-Content -Raw (Join-Path $f.Install 'wslbin.ini') | Should -BeExactly "raw = grep`n"
        Get-Content -Raw (Join-Path $f.Docs 'PowerShell\profile.ps1') | Should -Match '(?s)^# mine.*>>> wslbin >>>.*--init pwsh'
        Test-Path (Join-Path $f.Docs 'WindowsPowerShell\profile.ps1') | Should -BeTrue
        Get-Content -Raw (Join-Path $f.Clink 'wslbin.lua') | Should -Match 'clink\.generator'
        @(Get-ChildItem $script:LastTemp -Force | ForEach-Object { $_.Name } | Where-Object { $_ -like '*wslbin*' }) | Should -BeNullOrEmpty

        $apps = Get-AppsEntry $f
        $apps.DisplayName | Should -BeExactly 'wslbin'
        $apps.DisplayVersion | Should -BeExactly '0.1.7'
        $apps.Publisher | Should -BeExactly 'Dmitriy Khudnitskiy'
        $apps.InstallLocation | Should -BeExactly $f.Install
        $apps.DisplayIcon | Should -BeExactly (Join-Path $f.Install 'wslbin.exe')
        $apps.UninstallString | Should -Match 'powershell\.exe" -NoProfile -ExecutionPolicy Bypass -File ".*setup\\uninstall\.ps1"$'
        $apps.QuietUninstallString | Should -Be ($apps.UninstallString + ' -Quiet')
        $apps.NoModify | Should -Be 1
        $apps.NoRepair | Should -Be 1
        $apps.EstimatedSize | Should -BeGreaterThan 0
        $apps.InstallDate | Should -Match '^\d{8}$'
        $apps.URLInfoAbout | Should -Match '^https://github\.com/quatrebi/wslbin'
        $apps.HelpLink | Should -Match '^https://github\.com/quatrebi/wslbin/issues'
    }

    It 'writes the program path into the profile in ASCII, which Windows PowerShell reads in any code page' {
        $p = New-Package
        $f = New-InstallFolders
        $install = Join-Path $f.Base ((-join ([char[]](0x043F, 0x0440, 0x043E, 0x0433))) + '\wslbin')     # "прог"
        New-Item -ItemType Directory -Path (Join-Path $f.Docs 'WindowsPowerShell') | Out-Null
        $arguments = @('-Scope', 'CurrentUser', '-InstallDir', $install, '-NoPath', '-ProfileRoot', $f.Docs, '-ClinkDir', $f.Clink, '-UninstallKey', $f.Key, '-Completion', 'pwsh')
        $r = Invoke-Installer -Exe $Exe -Package $p -Arguments $arguments
        $r.ExitCode | Should -Be 0 -Because $r.Err
        $profilePath = Join-Path $f.Docs 'WindowsPowerShell\profile.ps1'
        $bytes = [IO.File]::ReadAllBytes($profilePath)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        # and Windows PowerShell finds the program through it
        $winPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $check = "`$block = (Get-Content -Raw -LiteralPath '$profilePath') -replace '(?s).*?if \(Test-Path -LiteralPath (.+?)\) \{.*', '`$1'; Test-Path -LiteralPath (Invoke-Expression `$block)"
        (& $winPs -NoProfile -Command $check) | Should -Be 'True'
    }

    It 'leaves the part of the user (profiles, -Link, Clink) to the copy that started the one with administrator rights' {
        $p = New-Package
        $f = New-InstallFolders
        $r = Install-Test $Exe $p $f @('-Completion', 'pwsh,clink', '-Elevated')
        $r.ExitCode | Should -Be 0 -Because $r.Err
        Test-Path (Join-Path $f.Install 'wslbin.exe') | Should -BeTrue
        Test-Path (Join-Path $f.Docs 'PowerShell\profile.ps1') | Should -BeFalse
        Test-Path (Join-Path $f.Clink 'wslbin.lua') | Should -BeFalse
    }

    It 'updates: replaces the files and the wrappers, keeps wslbin.ini, does not duplicate the profile block, leaves no .old or .new' {
        $f = New-InstallFolders
        $first = New-Package -Version '0.1.7'
        $null = Install-Test $Exe $first $f @('-Completion', 'pwsh')
        $null = & (Join-Path $f.Install 'wslbin.exe') --internal-link alpha beta
        [IO.File]::WriteAllText((Join-Path $f.Install 'wslbin.ini'), "raw = grep`n")

        $second = New-Package -Version '0.1.8' -ExePath (New-ExeVariant)
        $r = Install-Test $Exe $second $f @('-Completion', 'pwsh')
        $r.ExitCode | Should -Be 0 -Because $r.Err
        $newHash = (Get-FileHash (Join-Path $second.Dir 'wslbin.exe')).Hash
        (Get-FileHash (Join-Path $f.Install 'wslbin.exe')).Hash | Should -Be $newHash
        (Get-FileHash (Join-Path $f.Install 'alpha.exe')).Hash | Should -Be $newHash
        (Get-FileHash (Join-Path $f.Install 'beta.exe')).Hash | Should -Be $newHash
        (Get-Content -Raw (Join-Path $f.Install 'manifest.json') | ConvertFrom-Json).version | Should -BeExactly '0.1.8'
        (Get-AppsEntry $f).DisplayVersion | Should -BeExactly '0.1.8'
        Get-Content -Raw (Join-Path $f.Install 'wslbin.ini') | Should -BeExactly "raw = grep`n"
        @(Get-ChildItem $f.Install -Recurse -File -Name | Where-Object { $_ -match '\.(old|new)$' }) | Should -BeNullOrEmpty
        @([regex]::Matches((Get-Content -Raw (Join-Path $f.Docs 'PowerShell\profile.ps1')), '>>> wslbin')).Count | Should -Be 1
    }

    It 'says "installed already" for the same version and changes nothing; -Force installs it again' {
        $f = New-InstallFolders
        $null = Install-Test $Exe (New-Package -Version '0.1.7') $f
        $same = New-Package -Version '0.1.7' -ExePath (New-ExeVariant)
        $before = (Get-FileHash (Join-Path $f.Install 'wslbin.exe')).Hash

        $r = Install-Test $Exe $same $f
        $r.ExitCode | Should -Be 0 -Because $r.Err
        $r.Out | Should -Match 'installed already'
        (Get-FileHash (Join-Path $f.Install 'wslbin.exe')).Hash | Should -Be $before

        $r = Install-Test $Exe $same $f @('-Force')
        $r.ExitCode | Should -Be 0 -Because $r.Err
        (Get-FileHash (Join-Path $f.Install 'wslbin.exe')).Hash | Should -Be (Get-FileHash (Join-Path $same.Dir 'wslbin.exe')).Hash
    }

    It 'refuses an older version, and goes back with -Force' {
        $f = New-InstallFolders
        $null = Install-Test $Exe (New-Package -Version '0.1.10') $f
        $older = New-Package -Version '0.1.9' -ExePath (New-ExeVariant)
        $r = Install-Test $Exe $older $f
        $r.ExitCode | Should -Be 2
        ($r.Out + $r.Err) | Should -Match '0\.1\.10 is installed, which is newer than 0\.1\.9'
        (Get-AppsEntry $f).DisplayVersion | Should -BeExactly '0.1.10'

        $r = Install-Test $Exe $older $f @('-Force')
        $r.ExitCode | Should -Be 0 -Because $r.Err
        (Get-AppsEntry $f).DisplayVersion | Should -BeExactly '0.1.9'
    }

    It 'treats a pre-release as older than its release, and a release as newer than a build' {
        $f = New-InstallFolders
        $null = Install-Test $Exe (New-Package -Version '0.2.0-rc.1') $f
        $r = Install-Test $Exe (New-Package -Version '0.2.0' -ExePath (New-ExeVariant)) $f
        $r.ExitCode | Should -Be 0 -Because $r.Err
        (Get-AppsEntry $f).DisplayVersion | Should -BeExactly '0.2.0'
    }

    It 'refuses to install over an installation in another folder of the same scope, -Force or not (one entry in Apps a scope)' {
        $f = New-InstallFolders
        $null = Install-Test $Exe (New-Package -Version '0.1.7') $f
        $elsewhere = Join-Path $f.Base 'elsewhere'
        $next = New-Package -Version '0.1.8' -ExePath (New-ExeVariant)
        $arguments = @('-Scope', 'CurrentUser', '-InstallDir', $elsewhere, '-NoPath', '-ProfileRoot', $f.Docs, '-ClinkDir', $f.Clink, '-UninstallKey', $f.Key)
        foreach ($more in @(@(), @('-Force'))) {
            $r = Invoke-Installer -Exe $Exe -Package $next -Arguments ($arguments + $more)
            $r.ExitCode | Should -Be 2
            (($r.Out + $r.Err) -replace '\s+', ' ') | Should -Match 'is installed in .* already'
            Test-Path $elsewhere | Should -BeFalse
        }
        (Get-AppsEntry $f).InstallLocation | Should -BeExactly $f.Install
    }

    It 'replaces an entry in Apps that names a folder without wslbin' {
        $f = New-InstallFolders
        Set-TestEntry ([Microsoft.Win32.Registry]::CurrentUser) $f.Key '0.1.7' (Join-Path $f.Base 'gone')
        $r = Install-Test $Exe (New-Package -Version '0.1.8') $f
        $r.ExitCode | Should -Be 0 -Because $r.Err
        (Get-AppsEntry $f).InstallLocation | Should -BeExactly $f.Install
        (Get-AppsEntry $f).DisplayVersion | Should -BeExactly '0.1.8'
    }

    It 'installs nothing from a package whose file was changed' {
        $p = New-Package
        [IO.File]::AppendAllText((Join-Path $p.Dir 'LICENSE'), 'tampered')
        $f = New-InstallFolders
        $r = Install-Test $Exe $p $f
        $r.ExitCode | Should -Be 2
        ($r.Out + $r.Err) | Should -Match 'SHA256'
        Test-Path (Join-Path $f.Install 'wslbin.exe') | Should -BeFalse
        Get-AppsEntry $f | Should -BeNullOrEmpty
    }

    It 'goes on when wslbin writes warnings to standard error (a bad line in wslbin.ini)' {
        $f = New-InstallFolders
        New-Item -ItemType Directory -Path $f.Install | Out-Null
        [IO.File]::WriteAllText((Join-Path $f.Install 'wslbin.ini'), "this is not a setting`nraw = grep`n")
        $first = Install-Test $Exe (New-Package -Version '0.1.7') $f
        $first.ExitCode | Should -Be 0 -Because $first.Err
        $null = & (Join-Path $f.Install 'wslbin.exe') --internal-link alpha 2>$null
        $again = Install-Test $Exe (New-Package -Version '0.1.8' -ExePath (New-ExeVariant)) $f
        $again.ExitCode | Should -Be 0 -Because ($again.Err + $again.Out)
        (Get-FileHash (Join-Path $f.Install 'alpha.exe')).Hash | Should -Be (Get-FileHash (Join-Path $f.Install 'wslbin.exe')).Hash
    }

    It 'says what is wrong with the arguments' {
        $p = New-Package
        $f = New-InstallFolders
        $bad = Install-Test $Exe $p $f @('-Completion', 'zsh')
        $bad.ExitCode | Should -Not -Be 0
        ($bad.Err + $bad.Out) | Should -Match 'pwsh and clink'
        $none = Install-Test $Exe $p $f @('-PackageDir', (Join-Path $f.Base 'no-such-package'))
        $none.ExitCode | Should -Be 2
        ($none.Err + $none.Out) | Should -Match 'no manifest.json'
        Test-Path (Join-Path $f.Install 'wslbin.exe') | Should -BeFalse
    }

    It 'resolves a relative -InstallDir against the folder it was started in, and writes full paths into the profiles' {
        $p = New-Package
        $f = New-InstallFolders
        $r = Invoke-Installer -Exe $Exe -Package $p -Folder $f.Base -Arguments @('-Scope', 'CurrentUser', '-InstallDir', 'rel\wslbin', '-NoPath',
            '-ProfileRoot', $f.Docs, '-ClinkDir', $f.Clink, '-UninstallKey', $f.Key, '-Completion', 'pwsh')
        $r.ExitCode | Should -Be 0 -Because $r.Err
        $expected = Join-Path $f.Base 'rel\wslbin\wslbin.exe'
        Test-Path $expected | Should -BeTrue
        Get-Content -Raw (Join-Path $f.Docs 'PowerShell\profile.ps1') | Should -Match ([regex]::Escape($expected))
    }

    It 'leaves a profile alone that is not UTF-8, hooks the other one, and ends with exit code 1 and a warning' {
        $p = New-Package
        $f = New-InstallFolders
        New-Item -ItemType Directory -Path (Join-Path $f.Docs 'WindowsPowerShell') | Out-Null
        $bytes = [byte[]](0x23, 0x20, 0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2, 0x0A)
        [IO.File]::WriteAllBytes((Join-Path $f.Docs 'WindowsPowerShell\profile.ps1'), $bytes)
        $r = Install-Test $Exe $p $f @('-Completion', 'pwsh')
        $r.ExitCode | Should -Be 1
        ($r.Out + $r.Err) | Should -Match 'not UTF-8'
        [IO.File]::ReadAllBytes((Join-Path $f.Docs 'WindowsPowerShell\profile.ps1')) | Should -Be $bytes
        Get-Content -Raw (Join-Path $f.Docs 'PowerShell\profile.ps1') | Should -Match '>>> wslbin >>>'
        Test-Path (Join-Path $f.Install 'wslbin.exe') | Should -BeTrue
    }

    It 'the copy with administrator rights ends with exit code 2 when it fails, and says why' {
        $p = New-Package
        $f = New-InstallFolders
        $r = Install-Test $Exe $p $f @('-PackageDir', (Join-Path $f.Base 'no-such-package'), '-Elevated')
        $r.ExitCode | Should -Be 2
        ($r.Out + $r.Err) | Should -Match 'no manifest\.json'
    }

    It 'counts only its own files in the size of the Apps entry, and leaves the user''s files that end in .old' {
        $p = New-Package
        $f = New-InstallFolders
        New-Item -ItemType Directory -Path $f.Install | Out-Null
        $big = Join-Path $f.Install 'my-data.bin'
        $stream = [IO.File]::Create($big); $stream.SetLength(8MB); $stream.Close()
        [IO.File]::WriteAllText((Join-Path $f.Install 'my-notes.old'), 'mine')
        $r = Install-Test $Exe $p $f
        $r.ExitCode | Should -Be 0 -Because $r.Err
        $ours = (Get-ChildItem $f.Install -Recurse -File | Where-Object { $_.Name -notin 'my-data.bin', 'my-notes.old' } | Measure-Object Length -Sum).Sum
        (Get-AppsEntry $f).EstimatedSize | Should -Be ([int][Math]::Ceiling($ours / 1KB))
        $null = Install-Test $Exe (New-Package -Version '0.1.8' -ExePath (New-ExeVariant)) $f
        Test-Path (Join-Path $f.Install 'my-notes.old') | Should -BeTrue
    }

    It 'finds the wrappers by their product name and runs nothing from the install folder, so a broken wslbin.exe there does not keep them old' {
        $p = New-Package
        $f = New-InstallFolders
        New-Item -ItemType Directory -Path $f.Install | Out-Null
        # a program that is not wslbin in the place of wslbin.exe (an install that was cut short, or a
        # file put there by someone else), a wrapper, and a program of the user's that is not one
        Copy-Item (Join-Path $env:SystemRoot 'System32\where.exe') (Join-Path $f.Install 'wslbin.exe')
        Copy-Item $global:WslbinTest.Exe (Join-Path $f.Install 'alpha.exe')
        Copy-Item (Join-Path $env:SystemRoot 'System32\where.exe') (Join-Path $f.Install 'mine.exe')
        $r = Install-Test $Exe $p $f
        $r.ExitCode | Should -Be 0 -Because ($r.Out + $r.Err)
        $newHash = (Get-FileHash (Join-Path $p.Dir 'wslbin.exe')).Hash
        (Get-FileHash (Join-Path $f.Install 'wslbin.exe')).Hash | Should -Be $newHash
        (Get-FileHash (Join-Path $f.Install 'alpha.exe')).Hash | Should -Be $newHash
        (Get-FileHash (Join-Path $f.Install 'mine.exe')).Hash | Should -Be (Get-FileHash (Join-Path $env:SystemRoot 'System32\where.exe')).Hash
    }

    It 'installs the same version again when the folder lacks wslbin.exe, although the entry in Apps says it is there' {
        $f = New-InstallFolders
        $p = New-Package -Version '0.1.7'
        (Install-Test $Exe $p $f).ExitCode | Should -Be 0
        Remove-Item (Join-Path $f.Install 'wslbin.exe')
        $r = Install-Test $Exe $p $f
        $r.ExitCode | Should -Be 0 -Because $r.Err
        $r.Out | Should -Not -Match 'installed already'
        $r.Out | Should -Match 'is not complete'
        Test-Path (Join-Path $f.Install 'wslbin.exe') | Should -BeTrue
    }

    It 'refuses an entry in Apps whose version is not one it can compare, and installs over it with -Force' {
        $f = New-InstallFolders
        (Install-Test $Exe (New-Package -Version '0.1.7') $f).ExitCode | Should -Be 0
        $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($f.Key); $k.SetValue('DisplayVersion', 'garbage'); $k.Close()
        $next = New-Package -Version '0.1.8' -ExePath (New-ExeVariant)
        $r = Install-Test $Exe $next $f
        $r.ExitCode | Should -Be 2
        (($r.Out + $r.Err) -replace '\s+', ' ') | Should -Match "says that wslbin 'garbage' is installed.*Use -Force"
        $r = Install-Test $Exe $next $f @('-Force')
        $r.ExitCode | Should -Be 0 -Because $r.Err
        (Get-AppsEntry $f).DisplayVersion | Should -BeExactly '0.1.8'
    }

    It 'deletes on update the files that the old manifest named and the new one does not, and nothing else' {
        $f = New-InstallFolders
        (Install-Test $Exe (New-Package -Version '0.1.7') $f).ExitCode | Should -Be 0
        # as if 0.1.7 had shipped a file more
        $manifestPath = Join-Path $f.Install 'manifest.json'
        $manifest = Get-Content -Raw $manifestPath | ConvertFrom-Json
        $manifest.files = @($manifest.files) + [pscustomobject]@{ path = 'setup/retired.ps1'; size = 1; sha256 = ('0' * 64) } + [pscustomobject]@{ path = 'wslbin.ini'; size = 1; sha256 = ('0' * 64) }
        [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $f.Install 'setup\retired.ps1'), 'old')
        [IO.File]::WriteAllText((Join-Path $f.Install 'wslbin.ini'), "raw = grep`n")
        [IO.File]::WriteAllText((Join-Path $f.Install 'notes.txt'), 'mine')
        $r = Install-Test $Exe (New-Package -Version '0.1.8' -ExePath (New-ExeVariant)) $f
        $r.ExitCode | Should -Be 0 -Because $r.Err
        Test-Path (Join-Path $f.Install 'setup\retired.ps1') | Should -BeFalse
        Test-Path (Join-Path $f.Install 'wslbin.ini') | Should -BeTrue
        Test-Path (Join-Path $f.Install 'notes.txt') | Should -BeTrue
        Test-Path (Join-Path $f.Install 'setup\install.ps1') | Should -BeTrue
    }

    It 'updates while the wslbin.exe.old of the update before is still held by a program, and deletes it at a later run' {
        $f = New-InstallFolders
        (Install-Test $Exe (New-Package -Version '0.1.7') $f).ExitCode | Should -Be 0
        $held = Join-Path $f.Install 'wslbin.exe.old'
        [IO.File]::WriteAllText($held, 'a wslbin that still runs')
        $lock = [IO.File]::Open($held, 'Open', 'Read', 'Read')
        try { $r = Install-Test $Exe (New-Package -Version '0.1.8' -ExePath (New-ExeVariant)) $f }
        finally { $lock.Close() }
        $r.ExitCode | Should -Be 0 -Because ($r.Out + $r.Err)
        (Get-AppsEntry $f).DisplayVersion | Should -BeExactly '0.1.8'
        $r = Install-Test $Exe (New-Package -Version '0.1.9' -ExePath (New-ExeVariant)) $f
        $r.ExitCode | Should -Be 0 -Because $r.Err
        @(Get-ChildItem $f.Install -File -Name | Where-Object { $_ -like '*.old' }) | Should -BeNullOrEmpty
    }

    It 'warns about a profile that its PowerShell would not run, without failing: <Policy>' -ForEach @(@{ Policy = 'Restricted' }, @{ Policy = 'AllSigned' }) {
        # the policy is what a child process says; the test makes it say what it needs
        $f = New-InstallFolders
        $command = "`$ErrorActionPreference = 'Stop'; . '$($script:Repo)\setup\common.ps1'; function Get-ProfileExecutionPolicy { '$Policy' }; Write-ProfilePolicyWarnings"
        $r = Invoke-Script -Exe $Exe -ArgumentLine ('-NoProfile -ExecutionPolicy Bypass -Command ' + (ConvertTo-CommandLineArgument $command))
        $r.ExitCode | Should -Be 0 -Because $r.Err
        (($r.Out + $r.Err) -replace '\s+', ' ') | Should -Match "Windows PowerShell will not run the profile with the Tab completion: its execution policy is $Policy"
    }

    It 'makes wrappers with -Link, for utilities that WSL has' -Skip:$NoWsl -Tag 'WSL' {
        $p = New-Package
        $f = New-InstallFolders
        $r = Install-Test $Exe $p $f @('-Link', 'rsync,make')
        $r.ExitCode | Should -Be 0 -Because $r.Err
        Test-Path (Join-Path $f.Install 'rsync.exe') | Should -BeTrue
        Test-Path (Join-Path $f.Install 'make.exe') | Should -BeTrue
    }
}

Describe 'the copy with administrator rights, the code that it runs, in <Shell>' -ForEach $Shells {
    # What UAC starts is "powershell -Command <Get-ElevatedCommand>". Here it runs without the rights, with
    # a folder of the test in the place of Program Files, and installs for the current user.
    BeforeAll {
        function Invoke-ElevatedCode($Exe, [object[]]$Files, [string]$Script, [string[]]$Arguments, [string]$StageRoot) {
            $command = Get-ElevatedCommand $Files $Script $Arguments $StageRoot
            Invoke-Script -Exe $Exe -ArgumentLine (Get-ElevatedArgumentLine $command)
        }
        function Get-ElevatedInstallArguments($f) {
            @('-Scope', 'CurrentUser', '-InstallDir', (ConvertTo-PowerShellLiteral $f.Install), '-NoPath', '-UninstallKey', (ConvertTo-PowerShellLiteral $f.Key), '-Elevated')
        }
    }

    It 'checks the files into a folder of its own, installs from there and deletes that folder' {
        $p = New-Package -Version '0.1.7'
        $f = New-InstallFolders
        $stageRoot = Join-Path $f.Base 'program-files'
        New-Item -ItemType Directory -Path $stageRoot | Out-Null
        $files = @(Get-PackageFilesToCheck $p.Dir (Read-Manifest $p.Dir))
        @($files | ForEach-Object { $_.Path }) | Should -Contain 'manifest.json'
        $r = Invoke-ElevatedCode $Exe $files 'setup\install.ps1' (Get-ElevatedInstallArguments $f) $stageRoot
        $r.ExitCode | Should -Be 0 -Because ($r.Err + $r.Out)
        (Get-FileHash (Join-Path $f.Install 'wslbin.exe')).Hash | Should -Be (Get-FileHash (Join-Path $p.Dir 'wslbin.exe')).Hash
        (Get-AppsEntry $f).DisplayVersion | Should -BeExactly '0.1.7'
        # the Apps entry names the install folder, never the folder of checked files
        (Get-AppsEntry $f).InstallLocation | Should -BeExactly $f.Install
        @(Get-ChildItem $stageRoot -Force).Count | Should -Be 0
    }

    It 'does nothing when a file was changed after this copy checked it, and deletes what it had copied' {
        $p = New-Package -Version '0.1.7'
        $f = New-InstallFolders
        $stageRoot = Join-Path $f.Base 'program-files'
        New-Item -ItemType Directory -Path $stageRoot | Out-Null
        $files = @(Get-PackageFilesToCheck $p.Dir (Read-Manifest $p.Dir))
        # what another program of the user could do between the check and the UAC prompt
        [IO.File]::AppendAllText((Join-Path $p.Dir 'setup\common.ps1'), "`nWrite-Host 'not ours'`n")
        $r = Invoke-ElevatedCode $Exe $files 'setup\install.ps1' (Get-ElevatedInstallArguments $f) $stageRoot
        $r.ExitCode | Should -Be 2
        (($r.Out + $r.Err) -replace '\s+', ' ') | Should -Match 'common\.ps1 is [0-9A-F]{64}, not [0-9a-f]{64}: the file was changed after it was checked'
        ($r.Out + $r.Err) | Should -Not -Match 'not ours'
        Test-Path $f.Install | Should -BeFalse
        Get-AppsEntry $f | Should -BeNullOrEmpty
        @(Get-ChildItem $stageRoot -Force).Count | Should -Be 0
    }

    It 'removes an installation for all users from a folder of its own, and takes that folder away' {
        $f = New-InstallFolders
        $first = Install-Test $Exe (New-Package) $f
        $first.ExitCode | Should -Be 0 -Because $first.Err
        $stageRoot = Join-Path $f.Base 'program-files'
        New-Item -ItemType Directory -Path $stageRoot | Out-Null
        $files = @((Get-FileToCheck (Join-Path $f.Install 'setup\uninstall.ps1') 'setup\uninstall.ps1'), (Get-FileToCheck (Join-Path $f.Install 'setup\common.ps1') 'setup\common.ps1'))
        $arguments = @('-InstallDir', (ConvertTo-PowerShellLiteral $f.Install), '-NoPath', '-UninstallKey', (ConvertTo-PowerShellLiteral $f.Key), '-Quiet', '-Elevated')
        $r = Invoke-ElevatedCode $Exe $files 'setup\uninstall.ps1' $arguments $stageRoot
        $r.ExitCode | Should -Be 0 -Because ($r.Err + $r.Out)
        Test-Path $f.Install | Should -BeFalse
        @(Get-ChildItem $stageRoot -Force).Count | Should -Be 0
        @(Get-ChildItem $script:LastTemp -Force).Count | Should -Be 0
    }
}

Describe 'setup\install.ps1, its functions in this process' {
    BeforeAll {
        $saved = $ErrorActionPreference
        . (Join-Path $script:Repo 'setup\install.ps1')
        $ErrorActionPreference = $saved
        # PATH of a key of the test, never the real one
        function New-TestPathKey([string]$Value) {
            $path = 'Software\wslbin-tests\path-' + [guid]::NewGuid().ToString('N')
            $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($path)
            $k.SetValue('Path', $Value, 'ExpandString')
            $k.Close()
            $path
        }
        function Read-TestPathKey([string]$Path) {
            $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Path)
            try { [string]$k.GetValue('Path', '', 'DoNotExpandEnvironmentNames') } finally { $k.Close() }
        }
        function Get-AppsValue($f, [string]$Name) {
            $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($f.Key)
            try { $k.GetValue($Name) } finally { $k.Close() }
        }
    }

    It 'writes the Apps entry last: when PATH fails, the entry still names the version that was there, and the files are the old ones' {
        $f = New-InstallFolders
        $first = New-Package -Version '0.1.7'
        (Install-Test 'pwsh' $first $f).ExitCode | Should -Be 0
        $second = New-Package -Version '0.1.8' -ExePath (New-ExeVariant)
        $pathKey = New-TestPathKey 'C:\Windows'
        function Get-PathLocation { @{ Hive = [Microsoft.Win32.Registry]::CurrentUser; SubKey = $pathKey } }
        function Set-PathEntry { throw 'PATH cannot be written' }
        $UninstallKey = $f.Key; $NoPath = $false; $Force = $false; $InstallDir = $f.Install
        $script:Package = $second.Dir
        $script:Dir = $InstallDir; $script:EffectiveScope = 'CurrentUser'
        { Install-Program (Read-Manifest $second.Dir) 6>$null } | Should -Throw '*PATH cannot be written*'
        (Get-AppsEntry $f).DisplayVersion | Should -BeExactly '0.1.7'
        (Get-FileHash (Join-Path $f.Install 'wslbin.exe')).Hash | Should -Be (Get-FileHash (Join-Path $first.Dir 'wslbin.exe')).Hash
    }

    It 'takes its PATH entry back when the Apps entry cannot be written' {
        $f = New-InstallFolders
        $p = New-Package -Version '0.1.7'
        $pathKey = New-TestPathKey 'C:\Windows'
        function Get-PathLocation { @{ Hive = [Microsoft.Win32.Registry]::CurrentUser; SubKey = $pathKey } }
        function Set-UninstallEntry { throw 'the registry said no' }
        $UninstallKey = $f.Key; $NoPath = $false; $Force = $false; $InstallDir = $f.Install
        $script:Package = $p.Dir
        $script:Dir = $InstallDir; $script:EffectiveScope = 'CurrentUser'
        { Install-Program (Read-Manifest $p.Dir) 6>$null } | Should -Throw '*the registry said no*'
        Read-TestPathKey $pathKey | Should -BeExactly 'C:\Windows'
        Test-Path (Join-Path $f.Install 'wslbin.exe') | Should -BeFalse
    }

    It 'records in the Apps entry whether it put the folder into PATH (not when the folder was there before)' {
        $p = New-Package -Version '0.1.7'
        $UninstallKey = $null; $NoPath = $false; $Force = $false
        $script:Package = $p.Dir

        $f = New-InstallFolders
        $pathKey = New-TestPathKey "C:\Windows;$($f.Install)"
        function Get-PathLocation { @{ Hive = [Microsoft.Win32.Registry]::CurrentUser; SubKey = $pathKey } }
        $UninstallKey = $f.Key; $InstallDir = $f.Install
        $script:Dir = $InstallDir; $script:EffectiveScope = 'CurrentUser'
        $null = Install-Program (Read-Manifest $p.Dir) 6>$null
        Get-AppsValue $f 'PathEntryAdded' | Should -Be 0

        $g = New-InstallFolders
        $pathKey = New-TestPathKey 'C:\Windows'
        $UninstallKey = $g.Key; $InstallDir = $g.Install
        $script:Dir = $InstallDir; $script:EffectiveScope = 'CurrentUser'
        $null = Install-Program (Read-Manifest $p.Dir) 6>$null
        Get-AppsValue $g 'PathEntryAdded' | Should -Be 1
        Read-TestPathKey $pathKey | Should -BeExactly "C:\Windows;$($g.Install)"
        # an update finds the folder in PATH, put there by the first install: the entry still says so
        $next = New-Package -Version '0.1.8' -ExePath (New-ExeVariant)
        $script:Package = $next.Dir
        $null = Install-Program (Read-Manifest $next.Dir) 6>$null
        (Get-AppsEntry $g).DisplayVersion | Should -BeExactly '0.1.8'
        Get-AppsValue $g 'PathEntryAdded' | Should -Be 1
    }

    It 'goes on with the part of the user only when the copy with administrator rights ended with 0, and gives it checked files: <Code>' -ForEach @(
        @{ Code = 0; Expected = 0 }, @{ Code = 1; Expected = 2 }, @{ Code = 2; Expected = 2 }, @{ Code = -196608; Expected = 2 }
    ) {
        $p = New-Package -Version '0.1.7'
        $f = New-InstallFolders
        $Scope = 'AllUsers'; $Elevated = $false; $InstallDir = $f.Install; $UninstallKey = $f.Key
        $Link = @(); $Completion = @('pwsh'); $ProfileRoot = $f.Docs; $ClinkDir = $f.Clink; $NoPath = $true; $Force = $false
        $script:Package = $p.Dir
        $script:BoundParameters = @{ NoPath = 1; UninstallKey = 1 }
        $script:Problems = 0
        $script:Asked = $null
        $answer = $Code
        function Test-Administrator { $false }
        function Invoke-Elevated([object[]]$Files, [string]$Script, [string[]]$Arguments) {
            $script:Asked = @{ Files = $Files; Script = $Script; Arguments = $Arguments }
            $answer
        }
        function Write-ProfilePolicyWarnings { }
        $result = @(Install-Wslbin 6>$null 3>$null)[-1]
        $result | Should -Be $Expected
        Test-Path (Join-Path $f.Docs 'PowerShell\profile.ps1') | Should -Be ($Expected -eq 0)

        $script:Asked.Script | Should -BeExactly 'setup\install.ps1'
        $script:Asked.Arguments | Should -Contain '-Elevated'
        $script:Asked.Arguments[0..3] | Should -Be @('-Scope', 'AllUsers', '-InstallDir', (ConvertTo-PowerShellLiteral $f.Install))
        $manifest = Read-Manifest $p.Dir
        foreach ($file in $script:Asked.Files) {
            $file.Source | Should -BeExactly (Join-Path $p.Dir $file.Path)
            $file.Sha256 | Should -BeExactly (Get-FileHash $file.Source -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        @($script:Asked.Files).Count | Should -Be ($manifest.Files.Count + 1)
    }

    It 'installs for all users through the checked copy also from a PowerShell that has administrator rights already' {
        $p = New-Package -Version '0.1.7'
        $f = New-InstallFolders
        $Scope = 'AllUsers'; $Elevated = $false; $InstallDir = $f.Install; $UninstallKey = $f.Key
        $Link = @(); $Completion = @(); $ProfileRoot = $f.Docs; $ClinkDir = $f.Clink; $NoPath = $true; $Force = $false
        $script:Package = $p.Dir
        $script:BoundParameters = @{ NoPath = 1; UninstallKey = 1 }
        $script:Problems = 0
        $script:Asked = $null
        function Test-Administrator { $true }
        function Install-Program { throw 'installed from the package in TEMP' }
        function Invoke-Elevated([object[]]$Files, [string]$Script, [string[]]$Arguments) { $script:Asked = @{ Files = $Files; Script = $Script; Arguments = $Arguments }; 0 }
        $result = @(Install-Wslbin 6>$null 3>$null)[-1]
        $result | Should -Be 0
        $script:Asked.Script | Should -BeExactly 'setup\install.ps1'
        $script:Asked.Arguments | Should -Contain '-Elevated'
    }

    It 'updates the installation for all users when no -Scope is given, and installs for the user when there is none' {
        $f = New-InstallFolders
        $machine = New-FakeMachineHive
        function Get-UninstallHive([string]$ForScope) { if ($ForScope -eq 'AllUsers') { return $machine }; [Microsoft.Win32.Registry]::CurrentUser }
        $UninstallKey = $f.Key
        Get-DefaultScope '' 6>$null | Should -BeExactly 'CurrentUser'
        $theirs = Join-Path $f.Base 'for-all'
        New-Item -ItemType Directory -Path $theirs | Out-Null
        Set-TestEntry $machine $f.Key '0.1.7' $theirs
        # an entry whose folder holds no wslbin is no installation
        Get-DefaultScope '' 6>$null | Should -BeExactly 'CurrentUser'
        Copy-Item $global:WslbinTest.Exe (Join-Path $theirs 'wslbin.exe')
        Get-DefaultScope '' 6>$null | Should -BeExactly 'AllUsers'
        Get-DefaultScope $theirs 6>$null | Should -BeExactly 'AllUsers'
        Get-DefaultScope (Join-Path $f.Base 'other') 6>$null | Should -BeExactly 'CurrentUser'
    }

    It 'says so when wslbin is installed in the other scope as well, and which of the two runs' {
        $f = New-InstallFolders
        $machine = New-FakeMachineHive
        function Get-UninstallHive([string]$ForScope) { if ($ForScope -eq 'AllUsers') { return $machine }; [Microsoft.Win32.Registry]::CurrentUser }
        $UninstallKey = $f.Key
        $theirs = Join-Path $f.Base 'for-all'
        New-Item -ItemType Directory -Path $theirs | Out-Null
        Copy-Item $global:WslbinTest.Exe (Join-Path $theirs 'wslbin.exe')
        Set-TestEntry $machine $f.Key '0.1.7' $theirs

        $other = Get-OtherInstallation 'CurrentUser' $f.Install
        $other.Scope | Should -BeExactly 'AllUsers'
        $other.Version | Should -BeExactly '0.1.7'
        $other.Location | Should -BeExactly $theirs
        $text = (Write-OtherInstallation $other 3>&1 | Out-String) -replace '\s+', ' '
        $text | Should -Match 'installed for all users as well'
        $text | Should -Match 'PATH of the machine first'
        $text | Should -Match ([regex]::Escape((Join-Path $theirs 'setup\uninstall.ps1')))
        # the same folder, or a scope with no other entry, is no second installation
        Get-OtherInstallation 'CurrentUser' $theirs | Should -BeNullOrEmpty
        Get-OtherInstallation 'AllUsers' $theirs | Should -BeNullOrEmpty
        Set-TestEntry ([Microsoft.Win32.Registry]::CurrentUser) $f.Key '0.1.8' $theirs
        Get-OtherInstallation 'AllUsers' $f.Install | Should -Not -BeNullOrEmpty
    }
}

Describe 'setup\uninstall.ps1, its functions in this process' {
    BeforeAll {
        $saved = $ErrorActionPreference
        . (Join-Path $script:Repo 'setup\uninstall.ps1')
        $ErrorActionPreference = $saved
    }

    It 'tells an installation for all users by its entry in Apps, wherever its folder is' {
        $f = New-InstallFolders
        $machine = New-FakeMachineHive
        function Get-UninstallHive([string]$ForScope) { if ($ForScope -eq 'AllUsers') { return $machine }; [Microsoft.Win32.Registry]::CurrentUser }
        $UninstallKey = $f.Key
        $elsewhere = Join-Path $f.Base 'D\tools\wslbin'
        Set-TestEntry $machine $f.Key '0.1.7' $elsewhere
        Get-InstallationScope $elsewhere | Should -BeExactly 'AllUsers'
        Get-InstallationScope ($elsewhere.ToUpperInvariant() + '\') | Should -BeExactly 'AllUsers'
        # a folder whose name only starts like Program Files is not the place of the machine
        Get-InstallationScope ($env:ProgramFiles + 'X\wslbin') | Should -BeExactly 'CurrentUser'
        Get-InstallationScope ($env:ProgramFiles + ' (x86)\wslbin') | Should -BeExactly 'CurrentUser'
        Get-InstallationScope (Join-Path $env:ProgramFiles 'wslbin') | Should -BeExactly 'AllUsers'
        Set-TestEntry ([Microsoft.Win32.Registry]::CurrentUser) $f.Key '0.1.7' $f.Install
        Get-InstallationScope $f.Install | Should -BeExactly 'CurrentUser'
    }

    It 'takes the folder out of PATH only when the installer put it there' {
        foreach ($case in @(@{ Added = 0; Expected = 'C:\Windows;{0}' }, @{ Added = 1; Expected = 'C:\Windows' })) {
            $f = New-InstallFolders
            (Install-Test 'pwsh' (New-Package) $f).ExitCode | Should -Be 0
            $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($f.Key); $k.SetValue('PathEntryAdded', $case.Added, 'DWord'); $k.Close()
            $pathKey = 'Software\wslbin-tests\path-' + [guid]::NewGuid().ToString('N')
            $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($pathKey); $k.SetValue('Path', "C:\Windows;$($f.Install)", 'ExpandString'); $k.Close()
            function Get-PathLocation { @{ Hive = [Microsoft.Win32.Registry]::CurrentUser; SubKey = $pathKey } }
            $UninstallKey = $f.Key; $NoPath = $false; $Purge = $false
            Remove-Installation $f.Install 'CurrentUser' 6>$null
            Test-Path $f.Install | Should -BeFalse
            $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($pathKey)
            [string]$k.GetValue('Path', '', 'DoNotExpandEnvironmentNames') | Should -BeExactly ($case.Expected -f $f.Install)
            $k.Close()
        }
    }

    It 'with administrator rights deletes no file in a folder that others can change, and still takes out its PATH entry and its entry in Apps' {
        $f = New-InstallFolders
        (Install-Test 'pwsh' (New-Package) $f).ExitCode | Should -Be 0
        $machine = New-FakeMachineHive
        Set-TestEntry $machine $f.Key '0.1.7' $f.Install
        function Get-UninstallHive([string]$ForScope) { if ($ForScope -eq 'AllUsers') { return $machine }; [Microsoft.Win32.Registry]::CurrentUser }
        function Test-Administrator { $true }
        function Get-MachineFolderWriters { 'Everyone on ' + $f.Install }
        $UninstallKey = $f.Key; $NoPath = $true; $Purge = $false
        $script:Problems = 0
        Remove-Installation $f.Install 'AllUsers' 6>$null 3>$null
        $script:Problems | Should -Be 1
        Test-Path (Join-Path $f.Install 'wslbin.exe') | Should -BeTrue
        $machine.OpenSubKey($f.Key) | Should -BeNullOrEmpty
    }

    It 'removes an installation without running a program of its folder: the wrappers are found by their product name' {
        $f = New-InstallFolders
        (Install-Test 'pwsh' (New-Package) $f).ExitCode | Should -Be 0
        $null = & (Join-Path $f.Install 'wslbin.exe') --internal-link alpha
        function Invoke-Native { throw 'a program of the folder was run' }
        function Invoke-WslbinStep { throw 'a program of the folder was run' }
        $UninstallKey = $f.Key; $NoPath = $true; $Purge = $false
        $script:Problems = 0
        Remove-Installation $f.Install 'CurrentUser' 6>$null 3>$null
        $script:Problems | Should -Be 0
        Test-Path $f.Install | Should -BeFalse
    }

    It 'gives the copy with administrator rights the scripts of the installation when only administrators can change its folder, else its own' {
        $f = New-InstallFolders
        (Install-Test 'pwsh' (New-Package) $f).ExitCode | Should -Be 0
        $script:EntryScript = Join-Path $script:Repo 'setup\uninstall.ps1'
        $own = @(Get-UninstallScriptsToCheck $f.Install)
        $own[0].Source | Should -BeExactly $script:EntryScript
        function Get-MachineFolderWriters { }
        $installed = @(Get-UninstallScriptsToCheck $f.Install)
        @($installed | ForEach-Object { $_.Path }) | Should -Be @('setup\uninstall.ps1', 'setup\common.ps1')
        $installed[0].Source | Should -BeExactly (Join-Path $f.Install 'setup\uninstall.ps1')
        $installed[1].Source | Should -BeExactly (Join-Path $f.Install 'setup\common.ps1')
        foreach ($file in $installed) { $file.Sha256 | Should -BeExactly (Get-FileHash $file.Source -Algorithm SHA256).Hash.ToLowerInvariant() }
    }

    It 'asks for administrator rights to remove an installation for all users, from checked copies of its scripts' {
        $f = New-InstallFolders
        $machine = New-FakeMachineHive
        $elsewhere = Join-Path $f.Base 'D\tools\wslbin'
        New-Item -ItemType Directory -Path $elsewhere | Out-Null
        Copy-Item $global:WslbinTest.Exe (Join-Path $elsewhere 'wslbin.exe')
        Set-TestEntry $machine $f.Key '0.1.7' $elsewhere
        function Get-UninstallHive([string]$ForScope) { if ($ForScope -eq 'AllUsers') { return $machine }; [Microsoft.Win32.Registry]::CurrentUser }
        # nothing of this machine: the usual places are folders of the test
        function Get-DefaultInstallDir([string]$ForScope) { Join-Path $f.Base "usual-$ForScope" }
        function Test-Administrator { $false }
        function Invoke-Elevated([object[]]$Files, [string]$Script, [string[]]$Arguments) { $script:Asked = @{ Files = $Files; Script = $Script; Arguments = $Arguments }; 0 }
        $script:Asked = $null
        $script:EntryScript = Join-Path $script:Repo 'setup\uninstall.ps1'
        $script:BoundParameters = @{ UninstallKey = 1; NoPath = 1 }
        $UninstallKey = $f.Key; $InstallDir = $elsewhere; $NoPath = $true; $Purge = $false; $Elevated = $false
        $ProfileRoot = $f.Docs; $ClinkDir = $f.Clink
        # this process has the real folders of the AI agents: an uninstall that went wrong must not reach them
        $saved = @{ CLAUDE_CONFIG_DIR = $env:CLAUDE_CONFIG_DIR; CODEX_HOME = $env:CODEX_HOME }
        try {
            $env:CLAUDE_CONFIG_DIR = Join-Path $f.Base 'no-claude-folder-here'
            $env:CODEX_HOME = Join-Path $f.Base 'no-codex-folder-here'
            Uninstall-Wslbin 6>$null 3>$null
        }
        finally {
            foreach ($name in $saved.Keys) {
                if ($null -eq $saved[$name]) { Remove-Item "Env:\$name" -ErrorAction SilentlyContinue } else { Set-Item "Env:\$name" $saved[$name] }
            }
        }

        $script:Asked.Script | Should -BeExactly 'setup\uninstall.ps1'
        $script:Asked.Arguments[0..1] | Should -Be @('-InstallDir', (ConvertTo-PowerShellLiteral $elsewhere))
        $script:Asked.Arguments | Should -Contain '-Elevated'
        @($script:Asked.Files | ForEach-Object { $_.Path }) | Should -Be @('setup\uninstall.ps1', 'setup\common.ps1')
        foreach ($file in $script:Asked.Files) { $file.Sha256 | Should -BeExactly (Get-FileHash $file.Source -Algorithm SHA256).Hash.ToLowerInvariant() }
        # (the copy with the rights was not really started, so the installation is still there)
        Test-Path (Join-Path $elsewhere 'wslbin.exe') | Should -BeTrue
    }
}

Describe 'setup\uninstall.ps1 in <Shell>' -ForEach $Shells {
    BeforeAll {
        # installs a package and returns what the uninstaller of that installation is run with
        function Install-ForUninstall($Exe, $f, [string[]]$More = @()) {
            $r = Install-Test $Exe (New-Package) $f $More
            $r.ExitCode | Should -Be 0 -Because $r.Err
        }
        function Get-UninstallArguments($f) {
            @('-InstallDir', $f.Install, '-NoPath', '-ProfileRoot', $f.Docs, '-ClinkDir', $f.Clink, '-UninstallKey', $f.Key, '-Quiet')
        }
        function Invoke-Uninstaller($Exe, $f, [string[]]$More = @(), [hashtable]$Env = @{}) {
            Invoke-Script -Exe $Exe -Script (Join-Path $f.Install 'setup\uninstall.ps1') -Arguments ((Get-UninstallArguments $f) + $More) -Env $Env
        }
    }

    It 'takes everything out, from its own copy in the folder, and leaves wslbin.ini and other text alone' {
        $f = New-InstallFolders
        New-Item -ItemType Directory -Path $f.Install, $f.Clink, (Join-Path $f.Docs 'PowerShell') | Out-Null
        [IO.File]::WriteAllText((Join-Path $f.Install 'wslbin.ini'), "raw = grep`n")
        [IO.File]::WriteAllText((Join-Path $f.Docs 'PowerShell\profile.ps1'), "# mine`nSet-Alias gs git`n")
        Install-ForUninstall $Exe $f @('-Completion', 'pwsh,clink')
        $null = & (Join-Path $f.Install 'wslbin.exe') --internal-link alpha beta
        Get-AppsEntry $f | Should -Not -BeNullOrEmpty

        $r = Invoke-Uninstaller $Exe $f
        $r.ExitCode | Should -Be 0 -Because $r.Err
        (Get-ChildItem $f.Install -Force -Name) | Should -Be @('wslbin.ini')
        (Get-Content -Raw (Join-Path $f.Docs 'PowerShell\profile.ps1')).Replace("`r`n", "`n") | Should -BeExactly "# mine`nSet-Alias gs git`n"
        Test-Path (Join-Path $f.Docs 'WindowsPowerShell\profile.ps1') | Should -BeFalse
        Test-Path (Join-Path $f.Clink 'wslbin.lua') | Should -BeFalse
        Get-AppsEntry $f | Should -BeNullOrEmpty
        # its copy in the temporary folder is gone too
        @(Get-ChildItem $script:LastTemp -Force).Count | Should -Be 0
    }

    It 'removes the folder too when there is no wslbin.ini, and wslbin.ini with -Purge' {
        $f = New-InstallFolders
        Install-ForUninstall $Exe $f
        (Invoke-Uninstaller $Exe $f).ExitCode | Should -Be 0
        Test-Path $f.Install | Should -BeFalse

        $g = New-InstallFolders
        New-Item -ItemType Directory -Path $g.Install | Out-Null
        [IO.File]::WriteAllText((Join-Path $g.Install 'wslbin.ini'), "raw = grep`n")
        Install-ForUninstall $Exe $g
        (Invoke-Uninstaller $Exe $g @('-Purge')).ExitCode | Should -Be 0
        Test-Path $g.Install | Should -BeFalse
    }

    It 'finds the installation by the folder it is in, when -InstallDir is not given' {
        $f = New-InstallFolders
        Install-ForUninstall $Exe $f
        $r = Invoke-Script -Exe $Exe -Script (Join-Path $f.Install 'setup\uninstall.ps1') -Arguments @('-NoPath', '-ProfileRoot', $f.Docs, '-ClinkDir', $f.Clink, '-UninstallKey', $f.Key, '-Quiet')
        $r.ExitCode | Should -Be 0 -Because $r.Err
        Test-Path $f.Install | Should -BeFalse
        Get-AppsEntry $f | Should -BeNullOrEmpty
    }

    It 'takes the block for the AI agents out, when it removes the last installation' {
        $f = New-InstallFolders
        $claude = Join-Path $f.Base 'claude'
        New-Item -ItemType Directory -Path $claude | Out-Null
        Install-ForUninstall $Exe $f
        $null = & (Join-Path $f.Install 'wslbin.exe') --install-ai-context --claude --claude-dir $claude
        Get-Content -Raw (Join-Path $claude 'CLAUDE.md') | Should -Match 'wslbin:begin'

        $r = Invoke-Uninstaller $Exe $f -Env @{ CLAUDE_CONFIG_DIR = $claude }
        $r.ExitCode | Should -Be 0 -Because $r.Err
        Test-Path (Join-Path $claude 'CLAUDE.md') | Should -BeFalse
        Test-Path (Join-Path $claude 'skills\wslbin') | Should -BeFalse
        @(Get-ChildItem $script:LastTemp -Force).Count | Should -Be 0
    }

    It 'goes on when wslbin.exe is in use, ends with exit code 1 and a warning, keeps the entry in Apps and the hooks of the program that stays' {
        $f = New-InstallFolders
        New-Item -ItemType Directory -Path (Join-Path $f.Docs 'PowerShell') | Out-Null
        $claude = Join-Path $f.Base 'claude'
        New-Item -ItemType Directory -Path $claude | Out-Null
        Install-ForUninstall $Exe $f @('-Completion', 'pwsh')
        $null = & (Join-Path $f.Install 'wslbin.exe') --install-ai-context --claude --claude-dir $claude
        $lock = [IO.File]::Open((Join-Path $f.Install 'wslbin.exe'), 'Open', 'Read', 'Read')
        try { $r = Invoke-Uninstaller $Exe $f -Env @{ CLAUDE_CONFIG_DIR = $claude } }
        finally { $lock.Close() }
        $r.ExitCode | Should -Be 1
        ($r.Out + $r.Err) | Should -Match 'Could not remove'
        Get-Content -Raw (Join-Path $f.Docs 'PowerShell\profile.ps1') | Should -Match '>>> wslbin'
        Get-Content -Raw (Join-Path $claude 'CLAUDE.md') | Should -Match 'wslbin:begin'
        $r.Out | Should -Match 'kept the block for AI agents'
        # and the entry in Apps stays, so that the uninstall can be run again; that run takes the rest out
        Get-AppsEntry $f | Should -Not -BeNullOrEmpty
        $again = Invoke-Uninstaller $Exe $f
        $again.ExitCode | Should -Be 0 -Because $again.Err
        Get-AppsEntry $f | Should -BeNullOrEmpty
        Get-Content -Raw (Join-Path $f.Docs 'PowerShell\profile.ps1') -ErrorAction SilentlyContinue | Should -Not -Match '>>> wslbin'
    }

    It 'keeps the installation and its entry in Apps while a wrapper runs, and removes it all at the next run' {
        $f = New-InstallFolders
        Install-ForUninstall $Exe $f
        $null = & (Join-Path $f.Install 'wslbin.exe') --internal-link alpha beta
        # a wrapper that runs holds its file: it can be read, not deleted
        $lock = [IO.File]::Open((Join-Path $f.Install 'beta.exe'), 'Open', 'Read', 'Read')
        try { $r = Invoke-Uninstaller $Exe $f }
        finally { $lock.Close() }
        $r.ExitCode | Should -Be 1
        (($r.Out + $r.Err) -replace '\s+', ' ') | Should -Match 'Could not remove beta\.exe .*run this again'
        Test-Path (Join-Path $f.Install 'wslbin.exe') | Should -BeTrue
        Get-AppsEntry $f | Should -Not -BeNullOrEmpty
        $again = Invoke-Uninstaller $Exe $f
        $again.ExitCode | Should -Be 0 -Because $again.Err
        Test-Path $f.Install | Should -BeFalse
        Get-AppsEntry $f | Should -BeNullOrEmpty
    }

    It 'keeps the profile blocks and the Clink script when they run another installation that stays' {
        # two installations: one in the usual place of the user (LOCALAPPDATA of its own), one elsewhere;
        # the hooks are made last by the one in the usual place
        $f = New-InstallFolders
        $localAppData = Join-Path $f.Base 'lad'
        $usual = Join-Path $localAppData 'Programs\wslbin'
        New-Item -ItemType Directory -Path $f.Clink | Out-Null
        $first = Install-Test $Exe (New-Package) $f @('-Completion', 'pwsh,clink')
        $first.ExitCode | Should -Be 0 -Because $first.Err
        # (an entry in Apps of its own: one scope holds one, and the installer refuses a second in the same key)
        $arguments = @('-Scope', 'CurrentUser', '-InstallDir', $usual, '-NoPath', '-ProfileRoot', $f.Docs, '-ClinkDir', $f.Clink, '-UninstallKey', ($f.Key + '-usual'), '-Completion', 'pwsh,clink')
        $second = Invoke-Installer -Exe $Exe -Package (New-Package) -Arguments $arguments -Env @{ LOCALAPPDATA = $localAppData }
        $second.ExitCode | Should -Be 0 -Because $second.Err

        $r = Invoke-Uninstaller $Exe $f -Env @{ LOCALAPPDATA = $localAppData }
        $r.ExitCode | Should -Be 0 -Because $r.Err
        Test-Path (Join-Path $f.Install 'wslbin.exe') | Should -BeFalse
        Test-Path (Join-Path $usual 'wslbin.exe') | Should -BeTrue
        Get-Content -Raw (Join-Path $f.Docs 'PowerShell\profile.ps1') | Should -Match ([regex]::Escape((ConvertTo-PowerShellLiteral (Join-Path $usual 'wslbin.exe'))))
        Get-ClinkScriptExe (Join-Path $f.Clink 'wslbin.lua') | Should -BeExactly (Join-Path $usual 'wslbin.exe')
    }

    It 'takes out the hooks that run the installation it removes, while another one stays' {
        $f = New-InstallFolders
        $localAppData = Join-Path $f.Base 'lad'
        $usual = Join-Path $localAppData 'Programs\wslbin'
        New-Item -ItemType Directory -Path $f.Clink | Out-Null
        # (an entry in Apps of its own: one scope holds one, and the installer refuses a second in the same key)
        $arguments = @('-Scope', 'CurrentUser', '-InstallDir', $usual, '-NoPath', '-ProfileRoot', $f.Docs, '-ClinkDir', $f.Clink, '-UninstallKey', ($f.Key + '-usual'))
        $first = Invoke-Installer -Exe $Exe -Package (New-Package) -Arguments $arguments -Env @{ LOCALAPPDATA = $localAppData }
        $first.ExitCode | Should -Be 0 -Because $first.Err
        $second = Install-Test $Exe (New-Package) $f @('-Completion', 'pwsh,clink')
        $second.ExitCode | Should -Be 0 -Because $second.Err

        $r = Invoke-Uninstaller $Exe $f -Env @{ LOCALAPPDATA = $localAppData }
        $r.ExitCode | Should -Be 0 -Because $r.Err
        Test-Path (Join-Path $f.Docs 'PowerShell\profile.ps1') | Should -BeFalse
        Test-Path (Join-Path $f.Clink 'wslbin.lua') | Should -BeFalse
        Test-Path (Join-Path $usual 'wslbin.exe') | Should -BeTrue
    }

    It 'leaves the entry of another installation alone' {
        $f = New-InstallFolders
        Install-ForUninstall $Exe $f
        $other = Join-Path $f.Base 'other'
        New-Item -ItemType Directory -Path $other | Out-Null
        Copy-Item (Join-Path $f.Install 'wslbin.exe') $other
        $r = Invoke-Script -Exe $Exe -Script (Join-Path $f.Install 'setup\uninstall.ps1') -Arguments @('-InstallDir', $other, '-NoPath', '-ProfileRoot', $f.Docs, '-ClinkDir', $f.Clink, '-UninstallKey', $f.Key, '-Quiet')
        $r.ExitCode | Should -Be 0 -Because $r.Err
        Test-Path $other | Should -BeFalse
        Test-Path (Join-Path $f.Install 'wslbin.exe') | Should -BeTrue
        (Get-AppsEntry $f).InstallLocation | Should -BeExactly $f.Install
    }

    It 'gives up on a "clink info" that does not answer, and goes on' {
        $f = New-InstallFolders
        Install-ForUninstall $Exe $f
        $slow = Join-Path $f.Base 'slow-clink'
        New-Item -ItemType Directory -Path $slow | Out-Null
        [IO.File]::WriteAllText((Join-Path $slow 'clink.bat'), "@ping -n 41 127.0.0.1 >nul`r`n")
        $arguments = @('-InstallDir', $f.Install, '-NoPath', '-ProfileRoot', $f.Docs, '-UninstallKey', $f.Key, '-Quiet')   # no -ClinkDir
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-Script -Exe $Exe -Script (Join-Path $f.Install 'setup\uninstall.ps1') -Arguments $arguments -Env @{ PATH = "$slow;$env:SystemRoot\System32" }
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 30
        ($r.Out + $r.Err) | Should -Match 'clink info did not answer within 10 seconds'
        Test-Path (Join-Path $f.Install 'wslbin.exe') | Should -BeFalse
    }

    It 'does not remove a Clink script that is not its own' {
        $f = New-InstallFolders
        Install-ForUninstall $Exe $f
        New-Item -ItemType Directory -Path $f.Clink | Out-Null
        [IO.File]::WriteAllText((Join-Path $f.Clink 'wslbin.lua'), "-- my own script`n")
        $null = Invoke-Uninstaller $Exe $f
        Test-Path (Join-Path $f.Clink 'wslbin.lua') | Should -BeTrue
    }

    It 'says so when there is nothing to remove' {
        $f = New-InstallFolders
        $r = Invoke-Script -Exe $Exe -Script (Join-Path $script:Repo 'setup\uninstall.ps1') -Arguments @('-InstallDir', $f.Install, '-NoPath', '-ProfileRoot', $f.Docs, '-ClinkDir', $f.Clink, '-UninstallKey', $f.Key, '-Quiet')
        $r.ExitCode | Should -Be 0 -Because $r.Err
        $r.Out | Should -Match 'is not installed'
    }
}

Describe 'the loader (site/install.ps1) in <Shell>' -ForEach $Shells {
    BeforeAll {
        # a releases.json on disk for the versions given (version -> package), with addresses that are files
        function New-LocalReleases([object[]]$Packages, [string]$Latest, [string]$Sha256, [string]$Url, [string]$Asset) {
            $base = Join-Path $global:WslbinTest.Work ('releases-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $base | Out-Null
            $items = foreach ($p in $Packages) {
                $hash = $p.Hash
                if ($Sha256) { $hash = $Sha256 }
                $address = $p.Zip
                if ($Url) { $address = $Url }
                $name = "wslbin-$($p.Version)-win-x64.zip"
                if ($Asset) { $name = $Asset }
                [ordered]@{ version = $p.Version; tag = "v$($p.Version)"; published = '2026-10-23T00:00:00Z'; asset = $name; url = $address; sha256 = $hash }
            }
            $document = [ordered]@{ schema = 1; latest = $Latest; releases = @($items) }
            $path = Join-Path $base 'releases.json'
            [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $document -Depth 5), [Text.UTF8Encoding]::new($false))
            $path
        }
        function Invoke-Loader($Exe, $f, [string]$Releases, [string[]]$More = @(), [hashtable]$Env = @{}) {
            $arguments = @('-LocalReleases', $Releases, '-Quiet', '-Scope', 'CurrentUser', '-InstallDir', $f.Install, '-NoPath', '-ProfileRoot', $f.Docs, '-ClinkDir', $f.Clink, '-UninstallKey', $f.Key) + $More
            Invoke-Script -Exe $Exe -Script $script:Loader -Arguments $arguments -Env $Env
        }
        # The loader as the README shows it with parameters: & ([scriptblock]::Create((irm ...))) -Version ...,
        # in a PowerShell started with -Command, which prints $LASTEXITCODE afterwards.
        function Invoke-LoaderBlock($Exe, $f, [string]$Releases, [string[]]$More = @(), [hashtable]$Env = @{}) {
            $values = @('-LocalReleases', $Releases, '-Quiet', '-Scope', 'CurrentUser', '-InstallDir', $f.Install, '-NoPath', '-ProfileRoot', $f.Docs, '-ClinkDir', $f.Clink, '-UninstallKey', $f.Key) + $More
            $arguments = ($values | ForEach-Object { if ($_.StartsWith('-')) { $_ } else { ConvertTo-PowerShellLiteral $_ } }) -join ' '
            $command = "& ([scriptblock]::Create([IO.File]::ReadAllText($(ConvertTo-PowerShellLiteral $script:Loader)))) $arguments; 'exit code: ' + `$LASTEXITCODE"
            Invoke-Script -Exe $Exe -ArgumentLine ('-NoProfile -Command ' + (ConvertTo-CommandLineArgument $command)) -Env $Env
        }
    }

    It 'installs the latest release, checking its SHA256, and leaves nothing in TEMP' {
        $old = New-Package -Version '0.1.7'
        $new = New-Package -Version '0.1.10' -ExePath (New-ExeVariant)
        $releases = New-LocalReleases @($new, $old) '0.1.10'
        $f = New-InstallFolders
        $r = Invoke-Loader $Exe $f $releases
        $r.ExitCode | Should -Be 0 -Because ($r.Err + $r.Out)
        $r.Out | Should -Match 'SHA256 matches'
        (Get-AppsEntry $f).DisplayVersion | Should -BeExactly '0.1.10'
        (Get-FileHash (Join-Path $f.Install 'wslbin.exe')).Hash | Should -Be (Get-FileHash (Join-Path $new.Dir 'wslbin.exe')).Hash
        @(Get-ChildItem $script:LastTemp -Force | ForEach-Object { $_.Name } | Where-Object { $_ -like '*wslbin*' }) | Should -BeNullOrEmpty
    }

    It 'installs the version that was asked for, with or without a v' {
        $old = New-Package -Version '0.1.7'
        $new = New-Package -Version '0.1.10' -ExePath (New-ExeVariant)
        $releases = New-LocalReleases @($new, $old) '0.1.10'
        $f = New-InstallFolders
        (Invoke-Loader $Exe $f $releases @('-Version', 'v0.1.7')).ExitCode | Should -Be 0
        (Get-AppsEntry $f).DisplayVersion | Should -BeExactly '0.1.7'
    }

    It 'passes -Link, -Completion and -Force on to the installer' {
        $p = New-Package -Version '0.1.7'
        $releases = New-LocalReleases @($p) '0.1.7'
        $f = New-InstallFolders
        New-Item -ItemType Directory -Path $f.Clink | Out-Null
        $r = Invoke-Loader $Exe $f $releases @('-Completion', 'pwsh,clink')
        $r.ExitCode | Should -Be 0 -Because $r.Err
        Get-Content -Raw (Join-Path $f.Docs 'PowerShell\profile.ps1') | Should -Match '>>> wslbin >>>'
        Get-Content -Raw (Join-Path $f.Clink 'wslbin.lua') | Should -Match 'clink\.generator'
        (Invoke-Loader $Exe $f $releases).Out | Should -Match 'installed already'
        $forced = Invoke-Loader $Exe $f $releases @('-Force')
        $forced.Out | Should -Match 'installed 0\.1\.7'
    }

    It 'stops when the hash in releases.json is not the hash of the download, and installs nothing' {
        $p = New-Package -Version '0.1.7'
        $releases = New-LocalReleases @($p) '0.1.7' -Sha256 ('0' * 64)
        $f = New-InstallFolders
        $r = Invoke-Loader $Exe $f $releases
        $r.ExitCode | Should -Be 2
        ($r.Err + $r.Out) | Should -Match 'SHA256 of the download'
        Test-Path (Join-Path $f.Install 'wslbin.exe') | Should -BeFalse
        @(Get-ChildItem $script:LastTemp -Force | ForEach-Object { $_.Name } | Where-Object { $_ -like '*wslbin*' }) | Should -BeNullOrEmpty
    }

    It 'says which versions there are when the one asked for is not' {
        $p = New-Package -Version '0.1.7'
        $releases = New-LocalReleases @($p) '0.1.7'
        $r = Invoke-Loader $Exe (New-InstallFolders) $releases @('-Version', '9.9.9')
        $r.ExitCode | Should -Be 2
        ($r.Err + $r.Out) | Should -Match 'no release 9\.9\.9\. Released: 0\.1\.7'
    }

    It 'says so when there is no release yet' {
        $releases = New-LocalReleases @() $null
        $r = Invoke-Loader $Exe (New-InstallFolders) $releases
        $r.ExitCode | Should -Be 2
        ($r.Err + $r.Out) | Should -Match 'no release of wslbin yet'
    }

    It 'refuses a zip with an entry that would be written outside of its folder' {
        $base = Join-Path $global:WslbinTest.Work ('evil-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $base | Out-Null
        $zipPath = Join-Path $base 'wslbin-0.1.7-win-x64.zip'
        Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::Open($zipPath, 'Create')
        foreach ($name in 'wslbin.exe', '../escaped.txt') {
            $entry = $zip.CreateEntry($name)
            $writer = New-Object IO.StreamWriter($entry.Open())
            $writer.Write('x'); $writer.Dispose()
        }
        $zip.Dispose()
        $package = [pscustomobject]@{ Version = '0.1.7'; Zip = $zipPath; Hash = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLowerInvariant() }
        $releases = New-LocalReleases @($package) '0.1.7'
        $f = New-InstallFolders
        $r = Invoke-Loader $Exe $f $releases
        $r.ExitCode | Should -Be 2
        ($r.Err + $r.Out) | Should -Match 'outside of its folder'
        Test-Path (Join-Path $script:LastTemp 'escaped.txt') | Should -BeFalse
        Test-Path (Join-Path (Split-Path -Parent $script:LastTemp) 'escaped.txt') | Should -BeFalse
        Test-Path (Join-Path $f.Install 'wslbin.exe') | Should -BeFalse
    }

    It 'refuses a zip that is not a package' {
        $base = Join-Path $global:WslbinTest.Work ('notpkg-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $base | Out-Null
        [IO.File]::WriteAllText((Join-Path $base 'readme.txt'), 'hello')
        $zipPath = Join-Path $base 'wslbin-0.1.7-win-x64.zip'
        Compress-Archive -Path (Join-Path $base 'readme.txt') -DestinationPath $zipPath
        $package = [pscustomobject]@{ Version = '0.1.7'; Zip = $zipPath; Hash = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLowerInvariant() }
        $r = Invoke-Loader $Exe (New-InstallFolders) (New-LocalReleases @($package) '0.1.7')
        $r.ExitCode | Should -Be 2
        ($r.Err + $r.Out) | Should -Match 'no setup\\install.ps1'
    }

    It 'downloads only the zip of that very release of the repository on GitHub, over https: <Address>' -ForEach @(
        @{ Address = 'https://example.com/wslbin-0.1.7-win-x64.zip' }
        @{ Address = 'https://github.com.evil.example/quatrebi/wslbin/releases/download/v0.1.7/wslbin-0.1.7-win-x64.zip' }
        @{ Address = 'https://github.com/quatrebi/wslbin/archive/main.zip' }
        @{ Address = 'https://github.com/someone/else/releases/download/v0.1.7/wslbin-0.1.7-win-x64.zip' }
        @{ Address = 'https://github.com/quatrebi/wslbin/releases/download/v0.1.6/wslbin-0.1.7-win-x64.zip' }
        @{ Address = 'https://github.com/quatrebi/wslbin/releases/download/v0.1.7/other.zip' }
        @{ Address = 'http://github.com/quatrebi/wslbin/releases/download/v0.1.7/wslbin-0.1.7-win-x64.zip' }
    ) {
        $p = New-Package -Version '0.1.7'
        $releases = New-LocalReleases @($p) '0.1.7' -Url $Address
        $r = Invoke-Loader $Exe (New-InstallFolders) $releases
        $r.ExitCode | Should -Be 2
        # (the console of Windows PowerShell 5.1 wraps an error message at its width)
        (($r.Err + $r.Out) -replace '\s+', ' ') | Should -Match 'is not the download of release v0\.1\.7 of quatrebi/wslbin on GitHub'
        ($r.Err + $r.Out) | Should -Not -Match 'downloading'
    }

    It 'takes only the zip of the version it installs, with no folder in its name: <Asset>' -ForEach @(
        @{ Asset = '..\wslbin-0.1.7-win-x64.zip' }, @{ Asset = 'sub/wslbin-0.1.7-win-x64.zip' }, @{ Asset = 'wslbin-0.1.6-win-x64.zip' }, @{ Asset = 'WSLBIN-0.1.7-win-x64.zip' }
    ) {
        $p = New-Package -Version '0.1.7'
        $r = Invoke-Loader $Exe (New-InstallFolders) (New-LocalReleases @($p) '0.1.7' -Asset $Asset)
        $r.ExitCode | Should -Be 2
        (($r.Err + $r.Out) -replace '\s+', ' ') | Should -Match "names the file '.*' for 0\.1\.7, not wslbin-0\.1\.7-win-x64\.zip"
    }

    It 'refuses a releases.json that is not on https' {
        $plain = Invoke-Script -Exe $Exe -Script $script:Loader -Arguments @('-ReleasesUrl', 'http://example.com/releases.json', '-Quiet')
        $plain.ExitCode | Should -Be 2
        ($plain.Err + $plain.Out) | Should -Match 'must be an https address'
    }

    It 'runs the installer in a PowerShell of its own, so that it works where this session may run no script file' {
        $p = New-Package -Version '0.1.7'
        $f = New-InstallFolders
        # the policy of the Process scope: what "powershell -ExecutionPolicy Restricted" would set
        $r = Invoke-LoaderBlock $Exe $f (New-LocalReleases @($p) '0.1.7') -Env @{ PSExecutionPolicyPreference = 'Restricted' }
        $r.Out | Should -Match 'exit code: 0' -Because ($r.Err + $r.Out)
        (Get-AppsEntry $f).DisplayVersion | Should -BeExactly '0.1.7'
    }

    It 'reports the exit code of the installer in $LASTEXITCODE when it is run as a script block' {
        $f = New-InstallFolders
        $old = New-Package -Version '0.1.7'
        $new = New-Package -Version '0.1.10' -ExePath (New-ExeVariant)
        $releases = New-LocalReleases @($new, $old) '0.1.10'
        $null = Invoke-Loader $Exe $f $releases
        (Get-AppsEntry $f).DisplayVersion | Should -BeExactly '0.1.10'
        # an older version than the one installed: the installer refuses with exit code 2
        $r = Invoke-LoaderBlock $Exe $f $releases @('-Version', '0.1.7')
        $r.Out | Should -Match 'exit code: 2' -Because ($r.Err + $r.Out)
        (($r.Err + $r.Out) -replace '\s+', ' ') | Should -Match 'newer than 0\.1\.7'
    }

    It 'passes paths with spaces, quotes and letters outside ASCII on to the installer' {
        $p = New-Package -Version '0.1.7'
        $f = New-InstallFolders
        $f.Install = Join-Path $f.Base ("it's my " + (-join ([char[]](0x043F, 0x0440, 0x043E, 0x0433))) + '\wslbin')
        $r = Invoke-Loader $Exe $f (New-LocalReleases @($p) '0.1.7')
        $r.ExitCode | Should -Be 0 -Because ($r.Err + $r.Out)
        Test-Path -LiteralPath (Join-Path $f.Install 'wslbin.exe') | Should -BeTrue
        (Get-AppsEntry $f).InstallLocation | Should -BeExactly $f.Install
    }

    It 'refuses a releases.json of another schema' {
        $path = Join-Path $global:WslbinTest.Work ('schema-' + [guid]::NewGuid().ToString('N') + '.json')
        [IO.File]::WriteAllText($path, '{"schema":2,"latest":"1.0.0","releases":[]}')
        $r = Invoke-Loader $Exe (New-InstallFolders) $path
        $r.ExitCode | Should -Be 2
        ($r.Err + $r.Out) | Should -Match 'schema'
    }

    It 'refuses odd versions, scopes and repositories before it goes to the network: <Argument> <Value>' -ForEach @(
        @{ Argument = '-Version'; Value = '1/../x' }, @{ Argument = '-Version'; Value = '0.1' }, @{ Argument = '-Version'; Value = 'latest' }
        @{ Argument = '-Scope'; Value = 'Everyone' }, @{ Argument = '-Scope'; Value = 'Auto' }, @{ Argument = '-Repository'; Value = 'a/b/c' }
    ) {
        $r = Invoke-Script -Exe $Exe -Script $script:Loader -Arguments @($Argument, $Value, '-Quiet')
        $r.ExitCode | Should -Be 2
        ($r.Err + $r.Out) | Should -Match 'must look like|is CurrentUser or AllUsers'
    }

    It 'takes the version and the scope from the environment, does not close the console when it is run with iex, and leaves nothing of itself in the session' {
        $command = "`$ErrorActionPreference = 'Continue'; Get-Content -Raw -LiteralPath '$script:Loader' | Invoke-Expression; 'still here'; " +
        "'preference: ' + `$ErrorActionPreference; 'exit code: ' + `$LASTEXITCODE; " +
        "'functions: ' + @(Get-Command Get-Releases, Get-Zip, Invoke-Setup, Write-Say -ErrorAction SilentlyContinue).Count; " +
        "'variables: ' + @(Get-Variable Version, Scope, LocalReleases, SemVerPattern, release, temp, exitCode -ErrorAction SilentlyContinue).Count"
        $psi = [Diagnostics.ProcessStartInfo]::new($Exe)
        foreach ($a in '-NoProfile', '-Command', $command) { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
        $null = $psi.Environment.Remove('PSModulePath')
        $psi.Environment['WSLBIN_VERSION'] = 'not-a-version'
        $psi.Environment['WSLBIN_SCOPE'] = 'CurrentUser'
        $p = [Diagnostics.Process]::Start($psi)
        $p.StandardInput.Close()
        $e = $p.StandardError.ReadToEndAsync(); $o = $p.StandardOutput.ReadToEnd(); $p.WaitForExit()
        $o | Should -Match 'still here'
        $e.Result | Should -Match "must look like 0\.1\.7; got 'not-a-version'"
        $o | Should -Match 'preference: Continue'
        $o | Should -Match 'exit code: 2'
        $o | Should -Match 'functions: 0'
        $o | Should -Match 'variables: 0'
    }
}

Describe 'the loader and the scripts in the package' {
    It 'takes an attestation only from the release workflow of the repository, run on main (-VerifyAttestation)' {
        $text = Get-Content -Raw $script:Loader
        $text | Should -Match ([regex]::Escape('attestation verify $zipPath --repo $Repository --signer-workflow "$Repository/.github/workflows/release.yml" --source-ref ''refs/heads/main'''))
    }

    It 'parse in Windows PowerShell 5.1 and PowerShell 7' {
        $winPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        foreach ($relative in 'site\install.ps1', 'setup\install.ps1', 'setup\uninstall.ps1', 'setup\common.ps1', '.github\make-package.ps1') {
            $path = Join-Path $script:Repo $relative
            $errors = $null; $tokens = $null
            [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
            @($errors).Count | Should -Be 0 -Because "$relative in PowerShell 7"
            if (Test-Path $winPs) {
                $out = & $winPs -NoProfile -Command "`$e = `$null; `$t = `$null; [void][Management.Automation.Language.Parser]::ParseFile('$path', [ref]`$t, [ref]`$e); `$e.Count"
                [string]$out | Should -Be '0' -Because "$relative in Windows PowerShell 5.1"
            }
        }
    }

    It 'use none of what Windows PowerShell 5.1 lacks (null-conditional access, ::new)' {
        foreach ($relative in 'site\install.ps1', 'setup\install.ps1', 'setup\uninstall.ps1', 'setup\common.ps1', '.github\make-package.ps1') {
            $text = [IO.File]::ReadAllText((Join-Path $script:Repo $relative))
            $text | Should -Not -Match '[\w)\]]\?\.[\w\[]|\]::new\(' -Because $relative
        }
    }

    It 'are LF text without a byte order mark' {
        foreach ($relative in 'site\install.ps1', 'setup\install.ps1', 'setup\uninstall.ps1', 'setup\common.ps1', '.github\make-package.ps1') {
            $bytes = [IO.File]::ReadAllBytes((Join-Path $script:Repo $relative))
            ($bytes[0] -eq 0xEF) | Should -BeFalse -Because $relative
            ($bytes -contains 13) | Should -BeFalse -Because "$relative has a CR"
        }
    }
}
