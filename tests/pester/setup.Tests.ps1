#Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '6.2.0' }
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
    # A wslbin that is really installed here (the usual folders, or an entry in Apps) is found by an uninstall
    # that is not given -InstallDir: PowerShell resets ProgramFiles in the environment of a child, so the
    # tests cannot hide the usual folder of all users. Tests whose result depends on "no other
    # installation" skip themselves then, and never run an uninstall that could reach the real one.
    $RealInstall = $false
    foreach ($usual in @((Join-Path $env:ProgramFiles 'wslbin'), (Join-Path $env:LOCALAPPDATA 'Programs\wslbin'))) {
        if (Test-Path -LiteralPath (Join-Path $usual 'wslbin.exe')) { $RealInstall = $true }
    }
    foreach ($hive in @([Microsoft.Win32.Registry]::LocalMachine, [Microsoft.Win32.Registry]::CurrentUser)) {
        $appsKey = $hive.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Uninstall\wslbin')
        if ($appsKey) {
            $where = [string]$appsKey.GetValue('InstallLocation', '')
            if ($where -and (Test-Path -LiteralPath (Join-Path $where 'wslbin.exe'))) { $RealInstall = $true }
            $appsKey.Close()
        }
    }
    # With administrator rights a child process of uninstall.ps1 puts its own copy and its helper wslbin.exe under
    # the real Program Files (Get-ScratchRoot takes [Environment]::GetFolderPath('ProgramFiles'), which the
    # ProgramFiles variable that Invoke-Script sets does not change), and with UAC on it refuses a per-user
    # installation with exit code 2. The tests that run uninstall.ps1 in a child process skip themselves then
    # (the runner of CI); the in-process tests cover that code with faked rights and a scratch folder of their own.
    $AdminProcess = $false
    try {
        $AdminProcess = ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { }
    if ($AdminProcess) { Write-Host 'setup.Tests: this process has administrator rights: the tests that run uninstall.ps1 in a child process are skipped (it would write under the real Program Files, and with UAC on it refuses a per-user installation)' }
    $NoWsl = $true
    try {
        $null = & wsl.exe -l -q 2>$null
        if ($LASTEXITCODE -eq 0) { $NoWsl = $false }
    } catch { }
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers.ps1')
    Initialize-WslbinTest
    $script:Repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:MakePackage = Join-Path $script:Repo '.github\make-package.ps1'
    $script:Loader = Join-Path $script:Repo 'site\install.ps1'

    # the functions of the scripts, without running them
    $oldPreference = $ErrorActionPreference
    . (Join-Path $script:Repo 'setup\common.ps1')
    $ErrorActionPreference = $oldPreference

    # The functions read the parameters of the scripts ($UninstallKey, $NoPath, $ProfileRoot, $ClinkDir) as
    # variables of the caller; unset, they mean the real Apps entry, the real PATH and the real profiles.
    # Values of the test right after each dot-source, so that a test that forgets one touches nothing real.
    function Set-SafeScriptDefaults {
        $safe = Join-Path $global:WslbinTest.Work ('unset-' + [guid]::NewGuid().ToString('N'))
        Set-Variable -Scope 1 -Name UninstallKey -Value ('Software\wslbin-tests\unset-' + [guid]::NewGuid().ToString('N'))
        Set-Variable -Scope 1 -Name NoPath -Value $true
        Set-Variable -Scope 1 -Name ProfileRoot -Value (Join-Path $safe 'Documents')
        Set-Variable -Scope 1 -Name ClinkDir -Value (Join-Path $safe 'clink')
    }
    Set-SafeScriptDefaults

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
        $k.SetValue('DisplayName', 'wslbin')
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

    It 'reads back through the checks of the installer' {
        $manifest = Read-Manifest $script:Pkg.Dir
        $manifest.Version | Should -BeExactly '0.1.7'
        $manifest.Files | Should -Contain 'setup\install.ps1'
        $manifest.Files | Should -Contain 'wslbin.exe'
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

    It 'knows what is not a version: <Text>' -ForEach @(
        @{ Text = '1.2' }, @{ Text = 'v1.2.3' }, @{ Text = '01.2.3' }, @{ Text = '1.2.3-' }, @{ Text = '1.2.3-01' }, @{ Text = '1.2.3.4' }, @{ Text = '' }, @{ Text = 'latest' }
    ) {
        ConvertFrom-SemVer $Text | Should -BeNullOrEmpty
        { Compare-SemVer $Text '1.0.0' } | Should -Throw '*SemVer*'
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

    It 'does nothing when the folder is there already, whatever the case, quotes or slash at the end' {
        Reset-TestKey 'C:\Windows;"c:\WSLBIN\"'
        (Set-PathEntry -Hive $script:Hive -SubKey $script:KeyPath -Entry 'C:\wslbin') | Should -BeFalse
        (Read-TestPath).Value | Should -BeExactly 'C:\Windows;"c:\WSLBIN\"'
    }

    It 'removes only that folder' {
        Reset-TestKey 'C:\Windows;C:\wslbin;C:\Tools;c:\wslbin\'
        (Set-PathEntry -Hive $script:Hive -SubKey $script:KeyPath -Entry 'C:\wslbin' -Remove) | Should -BeTrue
        (Read-TestPath).Value | Should -BeExactly 'C:\Windows;C:\Tools'
        (Set-PathEntry -Hive $script:Hive -SubKey $script:KeyPath -Entry 'C:\wslbin' -Remove) | Should -BeFalse
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

    It 'takes the block out and leaves the rest as it was' {
        $original = "# mine`nSet-Alias gs git`n"
        $p = New-TestFile $original
        Set-MarkedBlock $p 'one'
        (Remove-MarkedBlock $p) | Should -BeTrue
        (Get-Content -Raw $p).Replace("`r`n", "`n") | Should -BeExactly $original
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

    It 'passes the usual place under Program Files, and refuses a folder of the user (the folder itself and those above)' {
        @(Get-MachineFolderWriters (Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'wslbin')).Count | Should -Be 0
        $mine = Join-Path $global:WslbinTest.Work ('mine-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $mine | Out-Null
        $writers = @(Get-MachineFolderWriters $mine)
        $writers.Count | Should -BeGreaterThan 0
        ($writers -join "`n") | Should -Match ([regex]::Escape($mine))
    }

    It 'refuses an installation for all users in a folder that others can change, and installs nothing' {
        $mine = Join-Path $global:WslbinTest.Work ('mine-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $mine | Out-Null
        # (the rights of Users make it certain, whoever runs the test)
        $acl = Get-Acl -LiteralPath $mine
        $users = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-545'
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($users, 'Modify', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
        Set-Acl -LiteralPath $mine -AclObject $acl
        { Initialize-MachineFolder $mine } | Should -Throw '*can be changed by others than administrators*Nothing was installed*'
    }

}

Describe 'setup: the environment and the copy with administrator rights' {
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

    # PowerShell loads a module for a command it does not know yet from the first folder of PSModulePath that
    # has one, and the folders of the user come first: a module there must not stand in for the commands of
    # the copy with administrator rights. (PowerShell 7 puts its own folder first, whatever the variable says.)
    # With administrator rights (a runner of CI) the copy deletes no file in a folder that the account can
    # change, and TEMP is such a folder; that is the behaviour (the test below, with administrator rights
    # put in by a stand-in, covers it). So this one runs where the test process has no such rights.
}

Describe 'setup\install.ps1, its functions in this process' {
    BeforeAll {
        $saved = $ErrorActionPreference
        . (Join-Path $script:Repo 'setup\install.ps1')
        $ErrorActionPreference = $saved
        Set-SafeScriptDefaults
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

}

Describe 'setup\uninstall.ps1, its functions in this process' {
    BeforeAll {
        $saved = $ErrorActionPreference
        . (Join-Path $script:Repo 'setup\uninstall.ps1')
        $ErrorActionPreference = $saved
        Set-SafeScriptDefaults
        # One uninstall in this process, with an installation of the test as the one found: admin rights and UAC
        # are faked, the hives and the usual folders are those of the test. Returns the exit code;
        # $script:Started says whether wslbin.exe was run.
        function Invoke-InProcessUninstall($f, [bool]$Admin, [bool]$Uac, [string]$Dir, [switch]$UsualIsInstall) {
            $machine = New-FakeMachineHive
            function Get-UninstallHive([string]$ForScope) { if ($ForScope -eq 'AllUsers') { return $machine }; [Microsoft.Win32.Registry]::CurrentUser }
            function Get-DefaultInstallDir([string]$ForScope) {
                if ($ForScope -eq 'CurrentUser' -and $UsualIsInstall) { return $f.Install }
                Join-Path $f.Base "usual-$ForScope"
            }
            $script:FakeAdmin = $Admin; $script:FakeUac = $Uac
            function Test-Administrator { $script:FakeAdmin }
            function Test-UacEnabled { $script:FakeUac }
            # with the faked rights the real one would choose a folder under Program Files (and a process
            # without the rights cannot make it): the scratch folders of this test go in its own folder
            function Get-ScratchRoot { $f.Base }
            $script:Started = $false
            function Invoke-WslbinStep { $script:Started = $true }
            $UninstallKey = $f.Key; $NoPath = $true; $Purge = $false; $Elevated = $false
            $InstallDir = $Dir; $ProfileRoot = $f.Docs; $ClinkDir = $f.Clink
            $script:Problems = 0; $script:Refused = 0
            $saved = @{ CLAUDE_CONFIG_DIR = $env:CLAUDE_CONFIG_DIR; CODEX_HOME = $env:CODEX_HOME }
            try {
                $env:CLAUDE_CONFIG_DIR = Join-Path $f.Base 'no-claude-folder-here'
                $env:CODEX_HOME = Join-Path $f.Base 'no-codex-folder-here'
                Uninstall-Wslbin 6>$null 3>$null
                Complete-Uninstall
            }
            finally {
                foreach ($name in $saved.Keys) {
                    if ($null -eq $saved[$name]) { Remove-Item "Env:\$name" -ErrorAction SilentlyContinue } else { Set-Item "Env:\$name" $saved[$name] }
                }
            }
        }
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

    It 'takes everything out, from its own copy in the folder, and leaves wslbin.ini and other text alone' -Skip:$AdminProcess {
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

    It 'removes the folder too when there is no wslbin.ini, and wslbin.ini with -Purge' -Skip:$AdminProcess {
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

    # (the last one has the Kelvin sign, which a match that ignores case takes for k)
}

Describe 'the loader and the scripts in the package' {
}
