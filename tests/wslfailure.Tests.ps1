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
