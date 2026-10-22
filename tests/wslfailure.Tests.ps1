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
