#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
  Interactive use: what a wrapper does when a person sits at the terminal. Run: Invoke-Pester ./tests
  (needs WSL and PowerShell 7; skipped otherwise)

  A real cmd.exe runs in a Windows pseudo console (tests/ConPty.cs) and the test types into it:
  the utility must see a terminal of the size of the window, take what is typed, show colours, run
  a full-screen program, and give up on Ctrl+C without leaving anything behind.
#>

BeforeDiscovery {
    $NoWsl = $true
    try {
        $null = & wsl.exe -l -q 2>$null
        if ($LASTEXITCODE -eq 0) { $NoWsl = $false }
    } catch { }
    $NoSession = $NoWsl -or ($PSVersionTable.PSVersion.Major -lt 7)
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers.ps1')
    Initialize-WslbinTest
    if (-not ('ConPty' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'ConPty.cs') }

    function ConvertTo-PlainText([string]$raw) {
        ($raw -replace '\x1b\[[0-9;?]*[A-Za-z]', '' -replace '\x1b\][^\x07\x1b]*(\x07|\x1b\\)', '' -replace "`r", '')
    }

    # Types a command into the session and returns what it printed, up to the next prompt.
    function Invoke-InSession($pty, [string]$Line, [int]$TimeoutMilliseconds = 8000) {
        $mark = $pty.Raw.Length
        $pty.Write($Line + "`r")
        [void]$pty.WaitFor('@@@>', $TimeoutMilliseconds, $mark + $Line.Length)
        Start-Sleep -Milliseconds 300
        $pty.Raw.Substring($mark)
    }

    # the lines that a command printed, without the echo of the typed line and without the prompt
    function Get-OutputLines([string]$raw) {
        @((ConvertTo-PlainText $raw) -split "`n" | Where-Object { $_.Trim() -and $_ -notmatch '^@@@>' } | Select-Object -Skip 1)
    }
}

AfterAll {
    try { & wsl.exe --exec bash --noprofile --norc -c 'find /tmp -maxdepth 1 -name "wslbin-tui-test-*" -delete' 2>$null } catch { }
    Remove-WslbinTest
}

Describe 'a wrapper in a terminal' -Tag 'WSL', 'Interactive' -Skip:$NoSession {
    BeforeAll {
        $script:Tool = New-WslbinHome
        $null = Invoke-Wslbin -Name 'wslbin' -Dir $script:Tool -Env @{ PATH = (Get-IsolatedPath $script:Tool) } -Arguments @('--internal-link', 'sleep', 'vi')
        $script:Pty = [ConPty]::Start('cmd.exe /d /q', $script:Tool, 100, 30)
        [void]$script:Pty.WaitFor('>', 10000, 0)
        Start-Sleep -Milliseconds 500
        $script:Pty.Write("set `"PATH=$script:Tool;%PATH%`"`r")
        Start-Sleep -Milliseconds 400
        $script:Pty.Write("prompt @@@`$G`r")
        Start-Sleep -Milliseconds 600
    }

    AfterAll {
        if ($script:Pty) { $script:Pty.Dispose() }
    }

    It 'gives the utility a terminal of the size of the window' {
        $lines = Get-OutputLines (Invoke-InSession $script:Pty 'wslbin -c "tty; stty size"')
        $lines[0] | Should -Match '^/dev/pts/\d+$'
        $lines[1] | Should -BeExactly '30 100'
    }

    It 'makes standard output and standard input terminals' {
        $out = Get-OutputLines (Invoke-InSession $script:Pty 'wslbin -c "test -t 0 && test -t 1 && test -t 2 && echo all-three-are-terminals"')
        $out | Should -Contain 'all-three-are-terminals'
    }

    It 'takes what is typed' {
        $mark = $script:Pty.Raw.Length
        $script:Pty.Write('wslbin -c "read -p ''name: '' n; echo hello-$n"' + "`r")
        [void]$script:Pty.WaitFor('name: ', 8000, $mark + 20)
        Start-Sleep -Milliseconds 300
        $script:Pty.Write("Anna`r")
        [void]$script:Pty.WaitFor('@@@>', 8000, $mark + 60)
        Start-Sleep -Milliseconds 300
        (ConvertTo-PlainText $script:Pty.Raw.Substring($mark)) | Should -Match 'hello-Anna'
    }

    It 'lets colours through' {
        $raw = Invoke-InSession $script:Pty 'wslbin -c "printf ''\e[31mRED\e[0m plain\n''"'
        $raw | Should -Match '\x1b\[[0-9;]*mRED'
    }

    It 'runs a full-screen program that is typed into' {
        $file = "/tmp/wslbin-tui-test-$([guid]::NewGuid().ToString('N')).txt"
        & wsl.exe --exec bash --noprofile --norc -c ": > $file"
        $mark = $script:Pty.Raw.Length
        $script:Pty.Write("vi $file`r")
        Start-Sleep -Seconds 3
        $script:Pty.Write('ihello from vi')
        Start-Sleep -Milliseconds 500
        $script:Pty.Write([string][char]27)
        Start-Sleep -Milliseconds 400
        $script:Pty.Write(":wq`r")
        [void]$script:Pty.WaitFor('@@@>', 10000, $mark + 50)
        Start-Sleep -Milliseconds 300
        ((& wsl.exe --exec bash --noprofile --norc -c "cat $file") -join '') | Should -BeExactly 'hello from vi'
        $answer = Get-OutputLines (Invoke-InSession $script:Pty 'echo back=%errorlevel%')
        $answer | Should -Contain 'back=0'
    }

    It 'stops at Ctrl+C, at once, and leaves nothing running in WSL' {
        # a duration of its own: other sleeps in the distribution (another test run, say) do not count
        $seconds = 5000 + (Get-Random -Maximum 900)
        $count = { ((& wsl.exe --exec bash --noprofile --norc -c "pgrep -xf 'sleep $seconds' | wc -l") -join '').Trim() }
        $mark = $script:Pty.Raw.Length
        $started = Get-Date
        $script:Pty.Write("sleep $seconds`r")
        Start-Sleep -Milliseconds 2500
        & $count | Should -BeExactly '1'
        $script:Pty.Write([string][char]3)
        $back = $script:Pty.WaitFor('@@@>', 10000, $mark + 20)
        $back | Should -BeTrue
        ((Get-Date) - $started).TotalSeconds | Should -BeLessThan 12
        Start-Sleep -Milliseconds 500
        & $count | Should -BeExactly '0'
    }

    It 'returns the exit code of the utility that Ctrl+C stopped, not zero' {
        # wsl.exe reports a utility that a signal ended as the number of the signal (2 for Ctrl+C)
        $mark = $script:Pty.Raw.Length
        $script:Pty.Write("sleep 60`r")
        Start-Sleep -Milliseconds 2500
        $script:Pty.Write([string][char]3)
        [void]$script:Pty.WaitFor('@@@>', 10000, $mark + 20)
        Start-Sleep -Milliseconds 500
        $code = @(Get-OutputLines (Invoke-InSession $script:Pty 'echo code=%errorlevel%') | Where-Object { $_ -match '^code=\d+$' })
        # no line at all must fail too
        $code | Should -BeExactly @('code=2')
    }

    It 'works as before after Ctrl+C' {
        $lines = Get-OutputLines (Invoke-InSession $script:Pty 'wslbin -c "echo still-works"')
        $lines | Should -Contain 'still-works'
    }
}
