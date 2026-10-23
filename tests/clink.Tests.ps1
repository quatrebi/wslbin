#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
  Tab completion in cmd.exe with Clink: the Lua script that "wslbin --init clink" writes.
  Run: Invoke-Pester ./tests    (skipped without WSL, without Clink, or outside PowerShell 7)

  A real cmd.exe runs in a Windows pseudo console (tests/ConPty.cs), Clink is injected with a
  profile folder of its own (so that the user's Clink settings are not touched), the test types a
  line, presses Tab and Enter. The line starts with --wslbin-explain, so that what runs is the
  bash command that the completed line stands for, and that is what the test compares.
  Set WSLBIN_TEST_CLINK to the path of clink.bat if Clink is not in its usual place.
#>

BeforeDiscovery {
    $NoWsl = $true
    try {
        $null = & wsl.exe -l -q 2>$null
        if ($LASTEXITCODE -eq 0) { $NoWsl = $false }
    } catch { }

    $ClinkBat = $env:WSLBIN_TEST_CLINK
    if (-not $ClinkBat) { $ClinkBat = Join-Path ${env:ProgramFiles(x86)} 'clink\clink.bat' }
    $NoClink = (-not (Test-Path -LiteralPath $ClinkBat)) -or ($PSVersionTable.PSVersion.Major -lt 7)
    . (Join-Path $PSScriptRoot 'helpers.ps1')
    $Cases = Get-ClinkCases
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers.ps1')
    Initialize-WslbinTest
    $script:Ru = -join ([char[]](0x0444, 0x0430, 0x0439, 0x043B))
    $script:ClinkBat = $env:WSLBIN_TEST_CLINK
    if (-not $script:ClinkBat) { $script:ClinkBat = Join-Path ${env:ProgramFiles(x86)} 'clink\clink.bat' }
    if (-not ('ConPty' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'ConPty.cs') }

    # Terminal text without the escape sequences.
    function ConvertTo-PlainText([string]$raw) {
        ($raw -replace '\x1b\[[0-9;?]*[A-Za-z]', '' -replace '\x1b\][^\x07\x1b]*(\x07|\x1b\\)', '' -replace '\x1b[()][A-Za-z0-9]', '' -replace "`r", '')
    }

    # Waits until nothing new has been printed for a while (a program that was just started has
    # printed nothing yet, so a minimum is waited out first).
    function Wait-OutputStable($pty, [int]$QuietMilliseconds = 1000, [int]$MaxMilliseconds = 20000) {
        $start = [DateTime]::UtcNow
        $length = $pty.Raw.Length
        $quietSince = [DateTime]::UtcNow
        Start-Sleep -Milliseconds 600
        while (([DateTime]::UtcNow - $start).TotalMilliseconds -lt $MaxMilliseconds) {
            Start-Sleep -Milliseconds 100
            $now = $pty.Raw.Length
            if ($now -ne $length) { $length = $now; $quietSince = [DateTime]::UtcNow }
            elseif (([DateTime]::UtcNow - $quietSince).TotalMilliseconds -ge $QuietMilliseconds) { return }
        }
    }

    # Types each line into a cmd.exe with Clink, presses Tab and then Enter, and returns, for every
    # line, the last line that the command printed. $Expected[i] is what the answer should be: it
    # is only what to wait for, so that a slow answer is not read too early (the test compares).
    function Invoke-ClinkSession {
        param([string]$ToolDir, [string]$Folder, [string[]]$Typed, [string[]]$Expected)
        $profileDir = Join-Path $global:WslbinTest.Work ('clink-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $profileDir | Out-Null
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $ToolDir -Arguments @('--init', 'clink', '--dir', $profileDir)
        if ($r.ExitCode -ne 0) { throw "--init clink failed: $($r.Err)" }

        $answers = New-Object System.Collections.Generic.List[string]
        $pty = [ConPty]::Start('cmd.exe /d /q', $Folder, 220, 50)
        try {
            [void]$pty.WaitFor('>', 10000, 0)
            Start-Sleep -Milliseconds 500
            $pty.Write("set `"PATH=$ToolDir;%PATH%`"`r")
            Start-Sleep -Milliseconds 400
            $pty.Write("prompt @@@`$G`r")
            Start-Sleep -Milliseconds 400
            $mark = $pty.Raw.Length
            $pty.Write("`"$script:ClinkBat`" --profile `"$profileDir`" inject`r")
            [void]$pty.WaitFor('Clink v', 10000, $mark)
            [void]$pty.WaitFor('@@@>', 10000, $pty.Raw.IndexOf('Clink v', $mark))
            Start-Sleep -Seconds 1

            for ($i = 0; $i -lt $Typed.Count; $i++) {
                $pty.Write("`r")
                Start-Sleep -Milliseconds 700
                $pty.Write($Typed[$i] + "`t")
                Wait-OutputStable $pty
                $mark2 = $pty.Raw.Length
                $pty.Write("`r")
                [void]$pty.WaitFor($Expected[$i], 15000, $mark2)
                Wait-OutputStable $pty -QuietMilliseconds 600
                $text = ConvertTo-PlainText ($pty.Raw.Substring($mark2))
                $output = @($text -split "`n" | Where-Object { $_.Trim() -and $_ -notmatch '^@@@>' })
                $answers.Add(($output | Select-Object -Last 1))
            }
        }
        finally {
            $pty.Dispose()
        }
        , $answers.ToArray()
    }
}

AfterAll {
    Remove-WslbinTest
    try { & wsl.exe --exec bash --noprofile --norc -c 'rm -f /tmp/wslbin-clink-q*' 2>$null } catch { }
}

Describe 'Tab completion in cmd.exe with Clink' -Tag 'WSL', 'Clink' -Skip:($NoWsl -or $NoClink) {
    BeforeAll {
        $script:H = New-WslbinHome
        $null = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Env @{ PATH = (Get-IsolatedPath $script:H) } -Arguments @('--internal-link', 'rsync')
        $script:Folder = Join-Path $global:WslbinTest.Work 'clink-folder'
        New-Item -ItemType Directory -Path (Join-Path $script:Folder 'alpha one') | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:Folder 'alpha one\inner file.txt'), "x`n")
        [IO.File]::WriteAllText((Join-Path $script:Folder "$script:Ru-note.txt"), "x`n")
        [IO.File]::WriteAllText((Join-Path $script:Folder 'x&ver.txt'), "x`n")
        & wsl.exe --exec bash --noprofile --norc -c 'touch "/tmp/wslbin-clink-q\"&ver\"x"'

        $script:CaseList = Get-ClinkCases
        $script:Answers = Invoke-ClinkSession -ToolDir $script:H -Folder $script:Folder `
            -Typed @($script:CaseList | ForEach-Object { $_.Typed }) `
            -Expected @($script:CaseList | ForEach-Object { $_.Want })
    }

    It "completes '<Typed>' to the command <Want>" -ForEach $Cases {
        $i = [array]::IndexOf(@($script:CaseList | ForEach-Object { $_.Typed }), $Typed)
        $script:Answers[$i] | Should -BeExactly $Want
    }
}
