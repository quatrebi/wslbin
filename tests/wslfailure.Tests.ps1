#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
  What wslbin does when WSL is missing, answers with an error, or does not answer; and where it refuses
  to run. A test build of wslbin runs a stand-in for wsl.exe (tests\FakeWsl.cs, tests\FakeWslEntry.cs),
  so none of this needs WSL and all of it runs in CI.
#>

BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'helpers.ps1')
    $NoGitBash = -not (Get-GitBash)
    $NoWsl = $true
    try {
        $null = & wsl.exe -l -q 2>$null
        if ($LASTEXITCODE -eq 0) { $NoWsl = $false }
    } catch { }
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers.ps1')
    Initialize-WslbinTest
    Initialize-FakeWsl

    # What the wsl.exe of Windows 10 prints in answer to any command when WSL is not installed: its usage
    # text (shortened; the option names are the same in every language). One line ends in "WSL 2", as in
    # the real text, which once made "wsl -l -v" look as if it listed a distribution.
    $script:Usage = ConvertTo-Utf16 (@(
        'Copyright (c) Microsoft Corporation. All rights reserved.'
        ''
        'Usage: wsl.exe [Argument] [Options...] [CommandLine]'
        ''
        '    --install [Distro] [Options...]'
        '        Install additional Windows Subsystem for Linux distributions.'
        '    --list, -l [Options]'
        '        Lists distributions.'
        '    --shutdown'
        '        Immediately terminates all running distributions and the WSL 2'
        '        lightweight utility virtual machine.'
        '    --status'
        '        Show the status of Windows Subsystem for Linux.'
        ''
    ) -join "`r`n")

    function Invoke-Fake {
        param([hashtable]$Wsl, [string]$Name = 'wslbin', [string[]]$Arguments, [string]$WorkingDirectory)
        $splat = @{ From = $global:WslbinTest.FakeExe; Name = $Name; Arguments = $Arguments; Env = $Wsl }
        if ($WorkingDirectory) { $splat.WorkingDirectory = $WorkingDirectory }
        Invoke-Wslbin @splat
    }

    function Get-Calls([hashtable]$Wsl) {
        $file = Join-Path $Wsl.FAKE_WSL_DIR 'calls.txt'
        if (Test-Path $file) { @(Get-Content $file) } else { @() }
    }
}

AfterAll {
    # a stand-in that a failed test left waiting would keep the folder from being removed
    Get-Process wsl -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$($global:WslbinTest.Work)*" } | Stop-Process -Force
    Remove-WslbinTest
}

Describe 'WSL is not installed: wsl.exe answers with its usage text' {
    It '--doctor says so, with the fix, and takes no line of the text for a distribution' {
        $wsl = New-FakeWsl -Files @{ 'list.out' = $script:Usage; 'list.exit' = '1' }
        $r = Invoke-Fake -Wsl $wsl -Arguments @('--doctor')
        $r.ExitCode | Should -Be 125
        $r.Out | Should -Match '\[FAIL\] WSL is not installed'
        $r.Out | Should -Match ([regex]::Escape("fix: run 'wsl --install' as administrator"))
        $r.Out | Should -Not -Match 'distributions:'
        $r.Out | Should -Not -Match 'default distribution'
    }

    It '--link says so in one line' {
        $wsl = New-FakeWsl -Files @{ 'run.out' = $script:Usage; 'run.exit' = '1' }
        $r = Invoke-Fake -Wsl $wsl -Arguments @('--link', 'jq')
        $r.ExitCode | Should -Be 125
        $lines = @($r.Err.TrimEnd("`n") -split "`n")
        $lines.Count | Should -Be 1 -Because $r.Err
        $lines[0] | Should -BeExactly "wslbin: cannot run bash in WSL: WSL is not installed (wsl.exe answers with its usage text) (fix: run 'wsl --install' as administrator)"
    }

    It 'finds the usage text on standard output when standard error holds only a line break' {
        $wsl = New-FakeWsl -Files @{ 'run.out' = $script:Usage; 'run.err' = [byte[]](0, 13, 10); 'run.exit' = '1' }
        (Invoke-Fake -Wsl $wsl -Arguments @('--link', 'jq')).Err | Should -Match 'WSL is not installed'
    }

    It 'a wrapper exits with 125 and says why, instead of passing on the exit code of wsl.exe' {
        $wsl = New-FakeWsl -Files @{ 'run.out' = $script:Usage; 'run.exit' = '1' } -HasDistribution $false
        $r = Invoke-Fake -Wsl $wsl -Name 'grep' -Arguments @('x', 'file')
        $r.ExitCode | Should -Be 125
        $r.Err | Should -Match ([regex]::Escape("WSL is not installed, or has no distribution, so wsl.exe answered instead of running the command (fix: run 'wsl --install' as administrator)"))
    }

    It "a wrapper passes on the utility's own exit code when WSL has a distribution" {
        $wsl = New-FakeWsl -Files @{ 'run.exit' = '1' }
        $r = Invoke-Fake -Wsl $wsl -Name 'grep' -Arguments @('x', 'file')
        $r.ExitCode | Should -Be 1
        $r.Err | Should -BeNullOrEmpty
    }
}

Describe 'messages of wsl.exe' {
    It 'lists the distributions of wsl -l -v and nothing else' {
        $list = ConvertTo-Utf16 ("  NAME              STATE           VERSION`r`n* Ubuntu-24.04      Running         2`r`n  docker-desktop    Stopped         2`r`n")
        $wsl = New-FakeWsl -Files @{ 'list.out' = $list; 'run.out' = "5.2.21(1)-release`n" }
        (Invoke-Fake -Wsl $wsl -Arguments @('--doctor')).Out | Should -Match ([regex]::Escape('[ ok ] distributions: Ubuntu-24.04 (default), docker-desktop'))
    }

    It 'shows a message in another language as it is (wsl.exe writes UTF-16)' {
        # "Нет дистрибутива с указанным именем." and "Код ошибки"
        $text = (-join [char[]](0x41D, 0x435, 0x442, 0x20, 0x434, 0x438, 0x441, 0x442, 0x440, 0x438, 0x431, 0x443, 0x442, 0x438, 0x432, 0x430)) + '.'
        $code = (-join [char[]](0x41A, 0x43E, 0x434, 0x20, 0x43E, 0x448, 0x438, 0x431, 0x43A, 0x438)) + ': Wsl/Service/WSL_E_DISTRO_NOT_FOUND'
        $wsl = New-FakeWsl -Files @{ 'run.out' = (ConvertTo-Utf16 "$text`r`n$code`r`n"); 'run.exit' = '-1' }
        $r = Invoke-Fake -Wsl $wsl -Arguments @('--link', 'jq')
        $r.ExitCode | Should -Be 125
        [string]::Equals($r.Err.TrimEnd("`n"), "wslbin: cannot run bash in WSL: $text $code", [StringComparison]::Ordinal) | Should -BeTrue -Because $r.Err
    }

    It 'reads what bash writes after a message of wsl.exe in UTF-16 on the same stream' {
        $out = [byte[]]((ConvertTo-Utf16 "wsl: a warning of wsl.exe`r`n") + [Text.Encoding]::UTF8.GetBytes("ok jq`n"))
        $wsl = New-FakeWsl -Files @{ 'run.out' = $out }
        $r = Invoke-Fake -Wsl $wsl -Arguments @('--link', '--dry-run', 'jq')
        $r.ExitCode | Should -Be 0 -Because $r.Err
        $r.Out | Should -Match 'would create .*jq\.exe'
    }

    It 'takes a distribution whose state is more than one word (translated), and no indented line of a text' {
        $state = 'Wird ausgef' + [char]0x00FC + 'hrt'
        $list = ConvertTo-Utf16 ("  NAME      STATE           VERSION`r`n* Ubuntu    $state    2`r`n" +
                                 "        Immediately terminates all running distributions and the WSL 2`r`n")
        $wsl = New-FakeWsl -Files @{ 'list.out' = $list; 'run.out' = "5.2.21(1)-release`n" }
        $out = (Invoke-Fake -Wsl $wsl -Arguments @('--doctor')).Out
        $out | Should -Match ([regex]::Escape('[ ok ] distributions: Ubuntu (default)') + '\r?\n')
    }

    It '--doctor does not call the wrappers "all fine" when WSL could not be asked' {
        $wsl = New-FakeWsl -Files @{ 'list.out' = $script:Usage; 'list.exit' = '1' }
        $h = Join-Path $global:WslbinTest.Work ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $h | Out-Null
        $null = Invoke-Wslbin -From $global:WslbinTest.FakeExe -Name 'wslbin' -Dir $h -Arguments @('--internal-link', 'grep')
        $r = Invoke-Wslbin -From $global:WslbinTest.FakeExe -Name 'wslbin' -Dir $h -Env $wsl -Arguments @('--doctor')
        $r.Out | Should -Match 'wrapper\(s\), not checked in WSL: grep'
        $r.Out | Should -Not -Match 'all fine'
    }

    It '--list does not call a wrapper "ok" when WSL could not be asked' {
        $wsl = New-FakeWsl -Files @{ 'run.out' = (ConvertTo-Utf16 "There is no distribution with the supplied name.`r`n"); 'run.exit' = '-1' }
        $h = Join-Path $global:WslbinTest.Work ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $h | Out-Null
        $null = Invoke-Wslbin -From $global:WslbinTest.FakeExe -Name 'wslbin' -Dir $h -Arguments @('--internal-link', 'grep')
        $r = Invoke-Wslbin -From $global:WslbinTest.FakeExe -Name 'wslbin' -Dir $h -Env $wsl -Arguments @('--list')
        $r.Out | Should -Match '^grep\s+not checked in WSL'
        $r.Out | Should -Not -Match '\bok\b'
        $r.Err | Should -Match 'could not ask WSL'
    }

    It 'keeps all of a long message, with the error code at its end' {
        $text = ('Windows Subsystem for Linux has no installed distributions. ' * 5) + 'Error code: Wsl/Service/CreateInstance/GetDefaultDistro/WSL_E_DEFAULT_DISTRO_NOT_FOUND'
        $wsl = New-FakeWsl -Files @{ 'run.out' = (ConvertTo-Utf16 "$text`r`n"); 'run.exit' = '-1' }
        (Invoke-Fake -Wsl $wsl -Arguments @('--link', 'jq')).Err | Should -Match 'GetDefaultDistro/WSL_E_DEFAULT_DISTRO_NOT_FOUND'
    }
}

Describe 'a wsl.exe that does not answer, or a wrapper that is stopped' {

    It 'stops wsl.exe when the wrapper is stopped (by a timeout of its caller, say)' {
        $wsl = New-FakeWsl -Files @{ 'run.sleep' = '60000' }
        $dir = Join-Path $global:WslbinTest.Work ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        Copy-Item $global:WslbinTest.FakeExe (Join-Path $dir 'sleep.exe')
        $psi = [Diagnostics.ProcessStartInfo]::new((Join-Path $dir 'sleep.exe'))
        $psi.ArgumentList.Add('60')
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        foreach ($key in $wsl.Keys) { $psi.Environment[$key] = $wsl[$key] }
        $wrapper = [Diagnostics.Process]::Start($psi)
        $pidFile = Join-Path $wsl.FAKE_WSL_DIR 'pid.txt'
        $deadline = (Get-Date).AddSeconds(20)
        while (-not (Test-Path $pidFile) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
        $fake = Get-Process -Id ([int](Get-Content $pidFile))
        $wrapper.Kill()
        $fake.WaitForExit(10000) | Should -BeTrue -Because 'wsl.exe must not outlive the wrapper'
    }
}

Describe 'a drive that WSL has not mounted' -Skip:$NoGitBash {
    # wsl.exe cannot enter a folder of such a drive (subst, a network drive): it says "Failed to
    # translate" and starts the command in the Linux home folder. The script that wslbin hands to
    # wsl.exe checks for that first. Here it runs in Git Bash, which has no /mnt/c, as WSL has no
    # /mnt/<drive> for such a drive; HOME says whether bash "started in the home folder".
    BeforeAll {
        $script:Folder = New-FileDir -Files @()
        $wsl = New-FakeWsl
        $null = Invoke-Fake -Wsl $wsl -Name 'printf' -Arguments @('%s', 'ran') -WorkingDirectory $script:Folder
        $words = [IO.File]::ReadAllText((Join-Path $wsl.FAKE_WSL_DIR 'args.bin'), [Text.UTF8Encoding]::new($false)) -split "`0"
        $script:Script = $words[[array]::IndexOf($words, '-c') + 1]
    }

    It 'refuses to run the command when bash started in the home folder instead of the folder' {
        $r = Invoke-GitBash -Script $script:Script -WorkingDirectory $script:Folder -Env @{ HOME = $script:Folder }
        $r.ExitCode | Should -Be 125
        $r.Err | Should -Match 'wslbin: WSL cannot enter .* it was not run'
        $r.Out | Should -BeNullOrEmpty
    }

    It 'runs the command when bash is in the folder' {
        $r = Invoke-GitBash -Script $script:Script -WorkingDirectory $script:Folder -Env @{ HOME = $global:WslbinTest.Work }
        $r.ExitCode | Should -Be 0 -Because $r.Err
        $r.Out | Should -BeExactly 'ran'
    }
}

Describe 'a folder of another distribution' -Tag 'WSL' -Skip:$NoWsl {
    BeforeAll {
        $script:Default = ((& wsl.exe --exec sh -c 'echo $WSL_DISTRO_NAME') -join '').Trim()
        $script:InDefault = "\\wsl.localhost\$script:Default\tmp"
    }

    It 'refuses to run when no distro is set and the folder is not in the default distribution' {
        $wsl = New-FakeWsl
        $wsl.WSLBIN_TEST_DEFAULT_DISTRO = 'Other-wslbin-test'
        $r = Invoke-Fake -Wsl $wsl -Name 'rm' -Arguments @('*.log') -WorkingDirectory $script:InDefault
        $r.ExitCode | Should -Be 125
        $r.Err | Should -Match "is in the distribution $([regex]::Escape($script:Default)), but wslbin runs in Other-wslbin-test"
        Get-Calls $wsl | Should -BeNullOrEmpty
    }

    It 'runs in a folder of the default distribution' {
        $wsl = New-FakeWsl
        $wsl.WSLBIN_TEST_DEFAULT_DISTRO = $script:Default
        $r = Invoke-Fake -Wsl $wsl -Name 'rm' -Arguments @('*.log') -WorkingDirectory $script:InDefault
        $r.ExitCode | Should -Be 0 -Because $r.Err
        @(Get-Calls $wsl).Count | Should -Be 1
    }
}

Describe 'a folder that has no Linux path' {
    BeforeAll {
        # The test folder through the administrative share of its drive: a network path to Windows.
        $work = $global:WslbinTest.Work
        $script:Unc = '\\localhost\' + $work.Substring(0, 1) + '$' + $work.Substring(2)
        $script:NoUnc = -not (Test-Path -LiteralPath $script:Unc)
    }

    It 'a wrapper refuses to run there, and does not start wsl.exe' {
        if ($script:NoUnc) { Set-ItResult -Skipped -Because "$script:Unc cannot be reached"; return }
        $wsl = New-FakeWsl
        $r = Invoke-Fake -Wsl $wsl -Name 'rm' -Arguments @('*.log') -WorkingDirectory $script:Unc
        $r.ExitCode | Should -Be 125
        $r.Err | Should -Match 'has no Linux path, so the command would run in your Linux home folder'
        Get-Calls $wsl | Should -BeNullOrEmpty
    }

    It '--wslbin-explain says that it would not run' {
        if ($script:NoUnc) { Set-ItResult -Skipped -Because "$script:Unc cannot be reached"; return }
        $r = Invoke-Wslbin -Name 'rm' -Arguments @('--wslbin-explain', '*.log') -WorkingDirectory $script:Unc
        $r.ExitCode | Should -Be 0
        $r.Out | Should -BeExactly "rm *.log`n"
        $r.Err | Should -Match 'has no Linux path.*would not run'
    }
}
