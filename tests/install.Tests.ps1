#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
  Tests of install.ps1. Run: Invoke-Pester ./tests

  Nothing here touches the machine: every run names a temporary install folder, profile folder and
  Clink folder, and -NoPath, so that the real PATH, profiles and Clink scripts stay as they are. The
  PATH code is tried on a registry key of its own under HKCU\Software. The part that asks for
  administrator rights (UAC) cannot be tried unattended.
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
    $script:Installer = Join-Path $script:Repo 'install.ps1'

    # the functions of the installer, without running it
    $oldPreference = $ErrorActionPreference
    . $script:Installer
    $ErrorActionPreference = $oldPreference

    # Runs install.ps1 in a child PowerShell with temporary folders for everything it could touch.
    # The installer runs wslbin, which checks names against PATH (refresh, -Link) and, on -Uninstall,
    # takes its block out of the instructions of the AI agents: so PATH holds nothing of this machine's
    # programs, and the folders of the agents are ones that do not exist unless -Env names others.
    # TEMP is a folder of its own, so that what the installer leaves there can be seen. ProgramFiles and
    # LOCALAPPDATA are folders of their own too: -Uninstall looks for installations in the usual places,
    # and wslbin may well be installed on the machine that runs the tests.
    function Invoke-Installer {
        param([string]$Exe, [string[]]$Arguments, [string]$Folder, [hashtable]$Env = @{})
        $psi = [Diagnostics.ProcessStartInfo]::new($Exe)
        foreach ($a in '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:Installer) { $psi.ArgumentList.Add($a) }
        foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $true
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
        # Windows PowerShell started from PowerShell 7 with its module path cannot load its own modules
        $null = $psi.Environment.Remove('PSModulePath')
        $psi.Environment['WSLBIN_NO_ELEVATION'] = '1'
        # System32 and nothing of the machine's programs, except the folder of dotnet: the installer builds
        # the program from the source (build.ps1), and that needs the .NET SDK
        $psi.Environment['PATH'] = "$env:SystemRoot\System32;" + (Split-Path -Parent (Get-Command dotnet).Source)
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

    # A fresh set of folders for one run: where to install, the profiles, Clink.
    function New-InstallFolders {
        $base = Join-Path $global:WslbinTest.Work ('install-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $base | Out-Null
        [pscustomobject]@{
            Base    = $base
            Install = Join-Path $base 'wslbin'
            Docs    = Join-Path $base 'Documents'
            Clink   = Join-Path $base 'clink'
        }
    }
    function Get-SafeArguments($f) { @('-Scope', 'CurrentUser', '-InstallDir', $f.Install, '-NoPath', '-ProfileRoot', $f.Docs, '-ClinkDir', $f.Clink) }
}

AfterAll {
    Remove-WslbinTest
}

Describe 'install.ps1: PATH in the registry' {
    BeforeAll {
        $script:KeyPath = "Software\wslbin-tests\$([guid]::NewGuid().ToString('N'))"
        $script:Hive = [Microsoft.Win32.Registry]::CurrentUser
        function Reset-TestKey([string]$Value, [Microsoft.Win32.RegistryValueKind]$Kind = 'ExpandString') {
            $k = $script:Hive.CreateSubKey($script:KeyPath)
            if ($null -ne $Value) { $k.SetValue('Path', $Value, $Kind) }
            $k.Close()
        }
        function Read-TestPath { $k = $script:Hive.OpenSubKey($script:KeyPath); $v = $k.GetValue('Path', '', 'DoNotExpandEnvironmentNames'); $kind = $k.GetValueKind('Path'); $k.Close(); [pscustomobject]@{ Value = $v; Kind = $kind } }
    }
    AfterAll {
        $script:Hive.DeleteSubKeyTree('Software\wslbin-tests', $false)
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

Describe 'install.ps1: blocks in profiles' {
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

Describe 'install.ps1: files it must not damage, and the elevated copy' {
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
            $parts = [CommandLineParser]::Split('prog -Source ' + (ConvertTo-CommandLineArgument $value) + ' -Next')
            $parts.Count | Should -Be 4 -Because $value
            $parts[2] | Should -BeExactly $value
        }
    }

    It 'builds the command line of the elevated copy with the scope, full paths and -Elevated, quoted' {
        $script:BoundParameters = @{ Source = 1; InstallDir = 1; Link = 1; NoPath = 1; Scope = 1 }
        $Source = 'C:\src\my wslbin\'
        $InstallDir = 'C:\Program Files\wslbin'
        $Link = @('make', 'rsync')
        $NoPath = [switch]$true
        $line = Get-ElevatedArgumentLine 'AllUsers'
        $parts = [CommandLineParser]::Split('powershell ' + $line)
        $parts | Should -Contain '-Scope'
        $parts[([array]::IndexOf($parts, '-Scope')) + 1] | Should -BeExactly 'AllUsers'
        @($parts | Where-Object { $_ -eq '-Scope' }).Count | Should -Be 1
        $parts[([array]::IndexOf($parts, '-Source')) + 1] | Should -BeExactly 'C:\src\my wslbin\'
        $parts[([array]::IndexOf($parts, '-InstallDir')) + 1] | Should -BeExactly 'C:\Program Files\wslbin'
        $parts[([array]::IndexOf($parts, '-Link')) + 1] | Should -BeExactly 'make,rsync'
        $parts | Should -Contain '-NoPath'
        $parts[-1] | Should -BeExactly '-Elevated'
        $parts | Should -Contain '-File'
    }
}

Describe 'release.yml: the tag must be the version' {
    It 'accepts the tag of the version that wslbin.exe reports, and refuses any other' {
        $tree = Join-Path $global:WslbinTest.Work ('release-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $tree '.github'), (Join-Path $tree 'bin') | Out-Null
        Copy-Item (Join-Path $script:Repo '.github\check-version.ps1') (Join-Path $tree '.github')
        # a release is built with the version of its tag (the build of the checkout has a suffix, +commit)
        $built = Join-Path $tree 'bin\wslbin.exe'
        $null = & (Join-Path $script:Repo 'build.ps1') -Output $built -Version '5.6.7' 6>$null
        $version = ((& $built --version) -replace '^wslbin ', '').Trim()
        $version | Should -BeExactly '5.6.7'
        $check = {
            param([string]$Tag)
            $env:TAG = $Tag
            try { & pwsh -NoProfile -File (Join-Path $tree '.github\check-version.ps1') 2>&1 | Out-Null; $LASTEXITCODE }
            finally { Remove-Item Env:TAG }
        }
        & $check "v$version" | Should -Be 0
        & $check 'v9.9.9' | Should -Not -Be 0
        & $check "v$version'; exit 0; '" | Should -Not -Be 0
    }
}

Describe 'install.ps1: small helpers' {
    It 'tells a right hash from a wrong one' {
        $f = Join-Path $global:WslbinTest.Work 'hash-me.txt'
        [IO.File]::WriteAllText($f, 'abc')
        $good = (Get-FileHash $f -Algorithm SHA256).Hash
        { Test-FileHash $f $good } | Should -Not -Throw
        { Test-FileHash $f $good.ToLowerInvariant() } | Should -Not -Throw
        { Test-FileHash $f ('0' * 64) } | Should -Throw '*SHA256*'
    }

    It 'takes "a,b", "a", "b" and blanks as one list' {
        (Split-List 'a,b') | Should -Be @('a', 'b')
        (Split-List @('a', 'b,c', ' ', '')) | Should -Be @('a', 'b', 'c')
        @(Split-List @()).Count | Should -Be 0
    }
}

Describe 'install.ps1 in <Shell>' -ForEach $Shells {
    It 'builds from a folder, installs, keeps wslbin.ini and hooks the shells in' {
        $f = New-InstallFolders
        New-Item -ItemType Directory -Path $f.Install, $f.Clink, (Join-Path $f.Docs 'PowerShell') | Out-Null
        [IO.File]::WriteAllText((Join-Path $f.Install 'wslbin.ini'), "raw = grep`n")
        [IO.File]::WriteAllText((Join-Path $f.Docs 'PowerShell\profile.ps1'), "# mine`n")

        $r = Invoke-Installer -Exe $Exe -Arguments ((Get-SafeArguments $f) + @('-Source', $script:Repo, '-Completion', 'pwsh,clink'))
        $r.ExitCode | Should -Be 0 -Because $r.Err
        & (Join-Path $f.Install 'wslbin.exe') --version | Should -Match '^wslbin \d+\.\d+\.\d+'
        Get-Content -Raw (Join-Path $f.Install 'wslbin.ini') | Should -BeExactly "raw = grep`n"
        Get-Content -Raw (Join-Path $f.Docs 'PowerShell\profile.ps1') | Should -Match '(?s)^# mine.*>>> wslbin >>>.*--init pwsh'
        Test-Path (Join-Path $f.Docs 'WindowsPowerShell\profile.ps1') | Should -BeTrue
        Get-Content -Raw (Join-Path $f.Clink 'wslbin.lua') | Should -Match 'clink\.generator'
        # the temporary build folders of wslbin are gone (dotnet leaves caches and logs of its own in TEMP)
        $left = @(Get-ChildItem $script:LastTemp -Force | ForEach-Object { $_.Name })
        @($left | Where-Object { $_ -like '*wslbin*' }) | Should -BeNullOrEmpty -Because "left in TEMP: $($left -join ', ')"
    }

    It 'writes the program path into the profile in ASCII, which Windows PowerShell reads in any code page' {
        $f = New-InstallFolders
        $install = Join-Path $f.Base ((-join ([char[]](0x043F, 0x0440, 0x043E, 0x0433))) + '\wslbin')     # "прог"
        New-Item -ItemType Directory -Path (Join-Path $f.Docs 'WindowsPowerShell') | Out-Null
        $arguments = @('-Scope', 'CurrentUser', '-InstallDir', $install, '-NoPath', '-ProfileRoot', $f.Docs, '-ClinkDir', $f.Clink,
                       '-Source', $script:Repo, '-Completion', 'pwsh')
        $r = Invoke-Installer -Exe $Exe -Arguments $arguments
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
        $f = New-InstallFolders
        $r = Invoke-Installer -Exe $Exe -Arguments ((Get-SafeArguments $f) + @('-Source', $script:Repo, '-Completion', 'pwsh,clink', '-Elevated'))
        $r.ExitCode | Should -Be 0 -Because $r.Err
        Test-Path (Join-Path $f.Install 'wslbin.exe') | Should -BeTrue
        Test-Path (Join-Path $f.Docs 'PowerShell\profile.ps1') | Should -BeFalse
        Test-Path (Join-Path $f.Clink 'wslbin.lua') | Should -BeFalse
    }

    It 'brings the wrappers that exist up to date and does not duplicate the profile block' {
        $f = New-InstallFolders
        $args1 = (Get-SafeArguments $f) + @('-Source', $script:Repo, '-Completion', 'pwsh')
        $null = Invoke-Installer -Exe $Exe -Arguments $args1
        # a wrapper from "an older version": a copy that differs
        $null = & (Join-Path $f.Install 'wslbin.exe') --internal-link alpha
        $old = [IO.File]::Open((Join-Path $f.Install 'alpha.exe'), 'Append'); $old.WriteByte(0); $old.Close()
        $r = Invoke-Installer -Exe $Exe -Arguments $args1
        $r.ExitCode | Should -Be 0 -Because $r.Err
        (Get-FileHash (Join-Path $f.Install 'alpha.exe')).Hash | Should -Be (Get-FileHash (Join-Path $f.Install 'wslbin.exe')).Hash
        @([regex]::Matches((Get-Content -Raw (Join-Path $f.Docs 'PowerShell\profile.ps1')), '>>> wslbin')).Count | Should -Be 1
    }

    It 'builds from a .zip when the hash is right, and stops when it is wrong' {
        $work = Join-Path $global:WslbinTest.Work ('zip-' + [guid]::NewGuid().ToString('N'))
        $tree = Join-Path $work 'wslbin-test'
        New-Item -ItemType Directory -Path $tree | Out-Null
        # what build.ps1 reads (the release zip, made by "git archive", has the whole tree)
        foreach ($item in 'src', 'data', 'docs', 'shell', 'wsl', 'build.ps1', 'wslbin.csproj', 'global.json', 'Directory.Build.props', '.editorconfig', 'nuget.config', 'Wslbin.Version.psm1') {
            Copy-Item -Recurse (Join-Path $script:Repo $item) $tree
        }
        $zip = Join-Path $work 'source.zip'
        Compress-Archive -Path $tree -DestinationPath $zip
        $hash = (Get-FileHash $zip -Algorithm SHA256).Hash

        $f = New-InstallFolders
        $ok = Invoke-Installer -Exe $Exe -Arguments ((Get-SafeArguments $f) + @('-Source', $zip, '-Sha256', $hash))
        $ok.ExitCode | Should -Be 0 -Because $ok.Err
        Test-Path (Join-Path $f.Install 'wslbin.exe') | Should -BeTrue

        $g = New-InstallFolders
        $bad = Invoke-Installer -Exe $Exe -Arguments ((Get-SafeArguments $g) + @('-Source', $zip, '-Sha256', ('0' * 64)))
        $bad.ExitCode | Should -Not -Be 0
        ($bad.Err + $bad.Out) | Should -Match 'SHA256'
        Test-Path (Join-Path $g.Install 'wslbin.exe') | Should -BeFalse
    }

    It 'says what is missing' {
        $f = New-InstallFolders
        $none = Invoke-Installer -Exe $Exe -Arguments (Get-SafeArguments $f)
        $none.ExitCode | Should -Not -Be 0
        ($none.Err + $none.Out) | Should -Match 'Name what to install'
        # what goes into the download URL is checked before anything is downloaded
        foreach ($odd in 'not a repo', 'owner/name/extra', 'owner', 'a/b?x=1', 'a/b#c') {
            $badRepo = Invoke-Installer -Exe $Exe -Arguments ((Get-SafeArguments $f) + @('-Version', 'v0.0.1', '-Repository', $odd))
            $badRepo.ExitCode | Should -Not -Be 0 -Because $odd
            ($badRepo.Err + $badRepo.Out) | Should -Match '-Repository must look like' -Because $odd
        }
        foreach ($odd in 'v1/../x', 'v1?x', 'v 1', 'v1#a') {
            $badVersion = Invoke-Installer -Exe $Exe -Arguments ((Get-SafeArguments $f) + @('-Version', $odd))
            $badVersion.ExitCode | Should -Not -Be 0 -Because $odd
            ($badVersion.Err + $badVersion.Out) | Should -Match '-Version must be the name of a tag' -Because $odd
        }
        $notSource = Invoke-Installer -Exe $Exe -Arguments ((Get-SafeArguments $f) + @('-Source', $env:SystemRoot))
        ($notSource.Err + $notSource.Out) | Should -Match 'not the source of wslbin|holds no src'
        $bad = Invoke-Installer -Exe $Exe -Arguments ((Get-SafeArguments $f) + @('-Source', $script:Repo, '-Completion', 'zsh'))
        $bad.ExitCode | Should -Not -Be 0
        ($bad.Err + $bad.Out) | Should -Match 'pwsh and clink'
        Test-Path (Join-Path $f.Install 'wslbin.exe') | Should -BeFalse
    }

    It 'takes everything out again with -Uninstall, and leaves wslbin.ini and other text alone' {
        $f = New-InstallFolders
        New-Item -ItemType Directory -Path $f.Install, $f.Clink, (Join-Path $f.Docs 'PowerShell') | Out-Null
        [IO.File]::WriteAllText((Join-Path $f.Install 'wslbin.ini'), "raw = grep`n")
        [IO.File]::WriteAllText((Join-Path $f.Docs 'PowerShell\profile.ps1'), "# mine`nSet-Alias gs git`n")
        $install = Invoke-Installer -Exe $Exe -Arguments ((Get-SafeArguments $f) + @('-Source', $script:Repo, '-Completion', 'pwsh,clink'))
        $install.ExitCode | Should -Be 0 -Because $install.Err
        $null = & (Join-Path $f.Install 'wslbin.exe') --internal-link alpha beta

        $r = Invoke-Installer -Exe $Exe -Arguments ((Get-SafeArguments $f) + '-Uninstall')
        $r.ExitCode | Should -Be 0 -Because $r.Err
        (Get-ChildItem $f.Install -Force -Name) | Should -Be @('wslbin.ini')
        (Get-Content -Raw (Join-Path $f.Docs 'PowerShell\profile.ps1')).Replace("`r`n", "`n") | Should -BeExactly "# mine`nSet-Alias gs git`n"
        Test-Path (Join-Path $f.Docs 'WindowsPowerShell\profile.ps1') | Should -BeFalse
        Test-Path (Join-Path $f.Clink 'wslbin.lua') | Should -BeFalse
    }

    It 'takes the block for the AI agents out with -Uninstall, when it removes the last installation' {
        $f = New-InstallFolders
        $claude = Join-Path $f.Base 'claude'
        New-Item -ItemType Directory -Path $claude | Out-Null
        $agents = @{ CLAUDE_CONFIG_DIR = $claude }
        $null = Invoke-Installer -Exe $Exe -Arguments ((Get-SafeArguments $f) + @('-Source', $script:Repo))
        $null = & (Join-Path $f.Install 'wslbin.exe') --install-ai-context --claude --claude-dir $claude
        Get-Content -Raw (Join-Path $claude 'CLAUDE.md') | Should -Match 'wslbin:begin'

        $r = Invoke-Installer -Exe $Exe -Arguments ((Get-SafeArguments $f) + '-Uninstall') -Env $agents
        $r.ExitCode | Should -Be 0 -Because $r.Err
        Test-Path (Join-Path $claude 'CLAUDE.md') | Should -BeFalse
        Test-Path (Join-Path $claude 'skills\wslbin') | Should -BeFalse
        @(Get-ChildItem $script:LastTemp -Force).Count | Should -Be 0
    }

    It 'goes on with -Uninstall when wslbin.exe is in use, ends with exit code 1 and a warning, and keeps the block for the agents' {
        $f = New-InstallFolders
        New-Item -ItemType Directory -Path (Join-Path $f.Docs 'PowerShell') | Out-Null
        $claude = Join-Path $f.Base 'claude'
        New-Item -ItemType Directory -Path $claude | Out-Null
        $null = Invoke-Installer -Exe $Exe -Arguments ((Get-SafeArguments $f) + @('-Source', $script:Repo, '-Completion', 'pwsh'))
        $null = & (Join-Path $f.Install 'wslbin.exe') --install-ai-context --claude --claude-dir $claude
        $lock = [IO.File]::Open((Join-Path $f.Install 'wslbin.exe'), 'Open', 'Read', 'Read')
        try {
            $r = Invoke-Installer -Exe $Exe -Arguments ((Get-SafeArguments $f) + '-Uninstall') -Env @{ CLAUDE_CONFIG_DIR = $claude }
        }
        finally {
            $lock.Close()
        }
        $r.ExitCode | Should -Be 1
        ($r.Out + $r.Err) | Should -Match 'Could not remove'
        Get-Content -Raw (Join-Path $f.Docs 'PowerShell\profile.ps1') -ErrorAction SilentlyContinue | Should -Not -Match '>>> wslbin'
        # wslbin is still there, so the agents are still told about it
        Get-Content -Raw (Join-Path $claude 'CLAUDE.md') | Should -Match 'wslbin:begin'
        $r.Out | Should -Match 'kept the block for AI agents'
    }

    It 'the copy with administrator rights ends with exit code 2 when it fails, and writes what it says into -ElevatedLog' {
        $f = New-InstallFolders
        $log = Join-Path $f.Base 'elevated.log'
        $r = Invoke-Installer -Exe $Exe -Arguments ((Get-SafeArguments $f) + @('-Source', (Join-Path $f.Base 'no-such-source'), '-Elevated', '-ElevatedLog', $log))
        $r.ExitCode | Should -Be 2
        Get-Content -Raw -Encoding UTF8 $log | Should -Match 'WARNING: -Source .*no-such-source does not exist'
    }

    It 'gives up on a "clink info" that does not answer, and goes on with -Uninstall' {
        $f = New-InstallFolders
        $null = Invoke-Installer -Exe $Exe -Arguments ((Get-SafeArguments $f) + @('-Source', $script:Repo))
        $slow = Join-Path $f.Base 'slow-clink'
        New-Item -ItemType Directory -Path $slow | Out-Null
        [IO.File]::WriteAllText((Join-Path $slow 'clink.bat'), "@ping -n 41 127.0.0.1 >nul`r`n")
        $arguments = @('-Scope', 'CurrentUser', '-InstallDir', $f.Install, '-NoPath', '-ProfileRoot', $f.Docs, '-Uninstall')   # no -ClinkDir
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-Installer -Exe $Exe -Arguments $arguments -Env @{ PATH = "$slow;$env:SystemRoot\System32" }
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 30
        ($r.Out + $r.Err) | Should -Match 'clink info did not answer within 10 seconds'
        Test-Path (Join-Path $f.Install 'wslbin.exe') | Should -BeFalse
    }

    It 'removes the folder too when there is no wslbin.ini' {
        $f = New-InstallFolders
        $null = Invoke-Installer -Exe $Exe -Arguments ((Get-SafeArguments $f) + @('-Source', $script:Repo))
        $r = Invoke-Installer -Exe $Exe -Arguments ((Get-SafeArguments $f) + '-Uninstall')
        $r.ExitCode | Should -Be 0 -Because $r.Err
        Test-Path $f.Install | Should -BeFalse
    }

    It 'does not remove a Clink script that is not its own' {
        $f = New-InstallFolders
        New-Item -ItemType Directory -Path $f.Clink | Out-Null
        [IO.File]::WriteAllText((Join-Path $f.Clink 'wslbin.lua'), "-- my own script`n")
        $null = Invoke-Installer -Exe $Exe -Arguments ((Get-SafeArguments $f) + '-Uninstall')
        Test-Path (Join-Path $f.Clink 'wslbin.lua') | Should -BeTrue
    }

    It 'resolves a relative -InstallDir against the folder it was started in, and writes full paths into the profiles' {
        $f = New-InstallFolders
        New-Item -ItemType Directory -Path $f.Base -Force | Out-Null
        $r = Invoke-Installer -Exe $Exe -Folder $f.Base -Arguments @('-Scope', 'CurrentUser', '-InstallDir', 'rel\wslbin', '-NoPath', '-Source', $script:Repo,
            '-ProfileRoot', $f.Docs, '-ClinkDir', $f.Clink, '-Completion', 'pwsh')
        $r.ExitCode | Should -Be 0 -Because $r.Err
        $expected = Join-Path $f.Base 'rel\wslbin\wslbin.exe'
        Test-Path $expected | Should -BeTrue
        Get-Content -Raw (Join-Path $f.Docs 'PowerShell\profile.ps1') | Should -Match ([regex]::Escape($expected))
    }

    It 'goes on when wslbin writes warnings to standard error (a bad line in wslbin.ini)' {
        $f = New-InstallFolders
        New-Item -ItemType Directory -Path $f.Install | Out-Null
        [IO.File]::WriteAllText((Join-Path $f.Install 'wslbin.ini'), "this is not a setting`nraw = grep`n")
        $first = Invoke-Installer -Exe $Exe -Arguments ((Get-SafeArguments $f) + @('-Source', $script:Repo))
        $first.ExitCode | Should -Be 0 -Because $first.Err
        $null = & (Join-Path $f.Install 'wslbin.exe') --internal-link alpha 2>$null
        $old = [IO.File]::Open((Join-Path $f.Install 'alpha.exe'), 'Append'); $old.WriteByte(0); $old.Close()
        $again = Invoke-Installer -Exe $Exe -Arguments ((Get-SafeArguments $f) + @('-Source', $script:Repo))
        $again.ExitCode | Should -Be 0 -Because ($again.Err + $again.Out)
        (Get-FileHash (Join-Path $f.Install 'alpha.exe')).Hash | Should -Be (Get-FileHash (Join-Path $f.Install 'wslbin.exe')).Hash
    }

    It 'leaves a profile alone that is not UTF-8, hooks the other one, and ends with exit code 1 and a warning' {
        $f = New-InstallFolders
        New-Item -ItemType Directory -Path (Join-Path $f.Docs 'WindowsPowerShell') | Out-Null
        $bytes = [byte[]](0x23, 0x20, 0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2, 0x0A)
        [IO.File]::WriteAllBytes((Join-Path $f.Docs 'WindowsPowerShell\profile.ps1'), $bytes)
        $r = Invoke-Installer -Exe $Exe -Arguments ((Get-SafeArguments $f) + @('-Source', $script:Repo, '-Completion', 'pwsh'))
        $r.ExitCode | Should -Be 1
        ($r.Out + $r.Err) | Should -Match 'not UTF-8'
        [IO.File]::ReadAllBytes((Join-Path $f.Docs 'WindowsPowerShell\profile.ps1')) | Should -Be $bytes
        Get-Content -Raw (Join-Path $f.Docs 'PowerShell\profile.ps1') | Should -Match '>>> wslbin >>>'
        Test-Path (Join-Path $f.Install 'wslbin.exe') | Should -BeTrue
    }

    It 'makes wrappers with -Link, for utilities that WSL has' -Skip:$NoWsl -Tag 'WSL' {
        $f = New-InstallFolders
        $r = Invoke-Installer -Exe $Exe -Arguments ((Get-SafeArguments $f) + @('-Source', $script:Repo, '-Link', 'rsync,make'))
        $r.ExitCode | Should -Be 0 -Because $r.Err
        Test-Path (Join-Path $f.Install 'rsync.exe') | Should -BeTrue
        Test-Path (Join-Path $f.Install 'make.exe') | Should -BeTrue
    }
}
