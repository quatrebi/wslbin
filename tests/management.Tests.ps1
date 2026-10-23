#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
  Tests of --link, --unlink and --list. Run: Invoke-Pester ./tests

  The first Describe blocks need no WSL: wrappers are created through --internal-link, the half
  of --link that does the copying (the half that asks UAC for rights cannot be tested unattended).
  Tests tagged WSL talk to a real distribution; they skip themselves when there is none.
#>

BeforeDiscovery {
    $NoWsl = $true
    try {
        $null = & wsl.exe -l -q 2>$null
        if ($LASTEXITCODE -eq 0) { $NoWsl = $false }
    } catch { }
    $nonAscii = -join ([char[]](0x0444, 0x0430, 0x0439, 0x043B))

    $BadNames = @('a b', 'con', 'CON', 'NUL.txt', 'com1', 'LPT9', 'wslbin', 'WSLBIN', 'x.exe', 'x.', '.hidden', '_x',
                  'a/b', 'a\b', 'a:b', 'a*', 'a;b', $nonAscii)
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers.ps1')
    Initialize-WslbinTest
}

AfterAll {
    Remove-WslbinTest
    try { & wsl.exe --exec bash --noprofile --norc -c 'rm -rf "$HOME/wslbin-test-bin"' 2>$null } catch { }
}

Describe 'wrapper names' {
    It "rejects '<_>'" -ForEach $BadNames {
        $h = New-WslbinHome
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $h -Arguments @('--link', $_)
        $r.ExitCode | Should -Be 125
        $r.Err | Should -Match 'cannot be a wrapper name'
        @(Get-ChildItem $h -Filter *.exe).Count | Should -Be 1
    }

    It 'rejects an unknown option' {
        $r = Invoke-Wslbin -Name 'wslbin' -Arguments @('--link', '--frobnicate')
        $r.ExitCode | Should -Be 125
        $r.Err | Should -Match 'unknown option --frobnicate'
    }
}

Describe 'names that Windows already uses' {
    BeforeAll {
        $script:H = New-WslbinHome
        $script:Path = Get-IsolatedPath $script:H
    }

    It "refuses '<_>', which is a program in System32" -ForEach @('find', 'sort') {
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Env @{ PATH = $script:Path } -Arguments @('--link', $_)
        $r.ExitCode | Should -Be 125
        $r.Err | Should -Match "$_`: Windows already has .*System32.*$_"
        Test-Path (Join-Path $script:H "$_.exe") | Should -BeFalse
    }

    It "refuses '<_>', which cmd.exe has built in" -ForEach @('echo', 'type', 'dir', 'copy', 'ECHO') {
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Env @{ PATH = $script:Path } -Arguments @('--link', $_)
        $r.ExitCode | Should -Be 125
        $r.Err | Should -Match 'cmd.exe has a built-in command'
    }

    It 'refuses a name that another folder in PATH has, and names that folder' {
        $other = Join-Path $global:WslbinTest.Work 'other-bin'
        New-Item -ItemType Directory -Path $other | Out-Null
        Copy-Item "$env:SystemRoot\System32\whoami.exe" (Join-Path $other 'sometool.exe')
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Env @{ PATH = "$script:H;$other" } -Arguments @('--link', 'sometool')
        $r.ExitCode | Should -Be 125
        $r.Err | Should -Match ([regex]::Escape((Join-Path $other 'sometool.exe')))
    }

    It 'does not count its own folder as a conflict' {
        $h = New-WslbinHome
        (Invoke-Wslbin -Name 'wslbin' -Dir $h -Arguments @('--internal-link', 'mine')).ExitCode | Should -Be 0
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $h -Env @{ PATH = (Get-IsolatedPath $h) } -Arguments @('--link')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Match 'up to date mine.exe'
    }

    It 'applies the same checks in the elevated half' {
        $h = New-WslbinHome
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $h -Env @{ PATH = (Get-IsolatedPath $h) } -Arguments @('--internal-link', 'find', 'echo', 'a b')
        $r.ExitCode | Should -Be 125
        @(Get-ChildItem $h -Filter *.exe).Count | Should -Be 1
    }

    # A Windows program of the same name can turn up after the wrapper was made (Git adds its tools to
    # PATH, say). The wrapper must still be refreshed: an old copy of wslbin.exe keeps the old faults.
    It 'refreshes a wrapper that is there already although a Windows program of the same name has turned up since, with a warning' {
        $h = New-WslbinHome
        $null = Invoke-Wslbin -Name 'wslbin' -Dir $h -Arguments @('--internal-link', 'sometool')
        $stream = [IO.File]::Open((Join-Path $h 'sometool.exe'), 'Append'); $stream.WriteByte(0); $stream.Close()
        $other = Join-Path $global:WslbinTest.Work ('later-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $other | Out-Null
        Copy-Item "$env:SystemRoot\System32\whoami.exe" (Join-Path $other 'sometool.exe')
        $env1 = @{ PATH = "$h;$other" }

        $r = Invoke-Wslbin -Name 'wslbin' -Dir $h -Env $env1 -Arguments @('--link')
        $r.ExitCode | Should -Be 0 -Because $r.Err
        $r.Out | Should -Match 'updated sometool.exe'
        $r.Err | Should -Match 'sometool: Windows already has .*brought up to date all the same'
        (Get-FileHash (Join-Path $h 'sometool.exe')).Hash | Should -Be (Get-FileHash (Join-Path $h 'wslbin.exe')).Hash

        $stream = [IO.File]::Open((Join-Path $h 'sometool.exe'), 'Append'); $stream.WriteByte(0); $stream.Close()
        (Invoke-Wslbin -Name 'wslbin' -Dir $h -Env $env1 -Arguments @('--internal-link', 'sometool')).ExitCode | Should -Be 0
        (Get-FileHash (Join-Path $h 'sometool.exe')).Hash | Should -Be (Get-FileHash (Join-Path $h 'wslbin.exe')).Hash
    }
}

Describe 'creating, refreshing and removing wrappers' {
    BeforeEach {
        $script:H = New-WslbinHome
        $script:Env = @{ PATH = (Get-IsolatedPath $script:H) }
    }

    It 'creates exact copies of wslbin.exe' {
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--internal-link', 'alpha', 'beta')
        $r.ExitCode | Should -Be 0
        foreach ($n in 'alpha', 'beta') {
            (Get-FileHash (Join-Path $script:H "$n.exe")).Hash | Should -Be (Get-FileHash (Join-Path $script:H 'wslbin.exe')).Hash
        }
    }

    It 'lists wrappers by name, sorted, and not wslbin.exe itself' {
        $null = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--internal-link', 'beta', 'alpha', 'Gamma')
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--list', '--names')
        ($r.Out -split "`n" | Where-Object { $_ }) | Should -Be @('alpha', 'beta', 'Gamma')
    }

    It 'does not take other programs in the folder for wrappers' {
        Copy-Item "$env:SystemRoot\System32\whoami.exe" (Join-Path $script:H 'foreign.exe')
        $null = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--internal-link', 'alpha')
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--list', '--names')
        ($r.Out -split "`n" | Where-Object { $_ }) | Should -Be @('alpha')
    }

    It 'never overwrites a program that is not a wrapper' {
        $foreign = Join-Path $script:H 'foreign.exe'
        Copy-Item "$env:SystemRoot\System32\whoami.exe" $foreign
        $hash = (Get-FileHash $foreign).Hash
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Env $script:Env -Arguments @('--link', 'foreign')
        $r.ExitCode | Should -Be 125
        $r.Err | Should -Match 'is not a wslbin wrapper|exists and is not a wslbin wrapper'
        (Get-FileHash $foreign).Hash | Should -Be $hash
        (Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--internal-link', 'foreign')).ExitCode | Should -Be 125
        (Get-FileHash $foreign).Hash | Should -Be $hash
    }

    It 'refreshes only the wrappers that are out of date' {
        $null = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--internal-link', 'alpha', 'beta')
        # trailing bytes keep the program runnable and recognisable, but make it differ from wslbin.exe
        $stream = [IO.File]::Open((Join-Path $script:H 'alpha.exe'), 'Append')
        $stream.WriteByte(0); $stream.Close()
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Env $script:Env -Arguments @('--link')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Match 'updated alpha.exe'
        $r.Out | Should -Match 'up to date beta.exe'
        (Get-FileHash (Join-Path $script:H 'alpha.exe')).Hash | Should -Be (Get-FileHash (Join-Path $script:H 'wslbin.exe')).Hash
    }

    It 'refreshes and removes wrapper files whose names could not be wrapper names, and goes on with the rest' {
        $null = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--internal-link', 'aa', 'zz')
        Copy-Item (Join-Path $script:H 'aa.exe') (Join-Path $script:H 'my tool.exe')
        $stream = [IO.File]::Open((Join-Path $script:H 'aa.exe'), 'Append'); $stream.WriteByte(0); $stream.Close()
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Env $script:Env -Arguments @('--link')
        $r.ExitCode | Should -Be 0 -Because $r.Err
        $r.Out | Should -Match 'updated aa.exe'
        $r.Out | Should -Match 'zz.exe'
        (Get-FileHash (Join-Path $script:H 'aa.exe')).Hash | Should -Be (Get-FileHash (Join-Path $script:H 'wslbin.exe')).Hash

        $u = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--unlink', '--all')
        $u.ExitCode | Should -Be 0 -Because $u.Err
        (Get-ChildItem $script:H -Filter *.exe).Name | Should -Be @('wslbin.exe')
    }

    It 'does not ask for administrator rights when one file cannot be changed for another reason (read-only)' {
        $null = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--internal-link', 'locked')
        $file = Join-Path $script:H 'locked.exe'
        $stream = [IO.File]::Open($file, 'Append'); $stream.WriteByte(0); $stream.Close()      # out of date: --link wants to replace it
        (Get-Item $file).IsReadOnly = $true
        try {
            $link = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Env $script:Env -Arguments @('--link')
            $link.ExitCode | Should -Be 125
            ($link.Out + $link.Err) | Should -Not -Match 'administrator'
            ($link.Out + $link.Err) | Should -Match 'locked'

            $unlink = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--unlink', 'locked')
            $unlink.ExitCode | Should -Be 125
            ($unlink.Out + $unlink.Err) | Should -Not -Match 'administrator'
            Test-Path $file | Should -BeTrue
        }
        finally {
            (Get-Item $file).IsReadOnly = $false
        }
    }

    It 'asks for administrator rights when the folder cannot be written, and reports a refusal (WSLBIN_NO_ELEVATION is set: no question is shown)' {
        $h = New-WslbinHome
        $null = Invoke-Wslbin -Name 'wslbin' -Dir $h -Arguments @('--internal-link', 'aa')
        $stream = [IO.File]::Open((Join-Path $h 'aa.exe'), 'Append'); $stream.WriteByte(0); $stream.Close()
        $user = "$env:USERDOMAIN\$env:USERNAME"
        & icacls.exe $h /deny "${user}:(OI)(CI)(WD,AD)" /T | Out-Null
        try {
            $r = Invoke-Wslbin -Name 'wslbin' -Dir $h -Env @{ PATH = (Get-IsolatedPath $h) } -Arguments @('--link')
            $r.ExitCode | Should -Be 125
            ($r.Out + $r.Err) | Should -Match 'needs administrator rights'
            ($r.Out + $r.Err) | Should -Match 'declined'
        }
        finally {
            & icacls.exe $h /remove:d $user /T | Out-Null
        }
    }

    It 'has nothing to refresh when there are no wrappers' {
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Env $script:Env -Arguments @('--link')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Match 'no wrappers'
    }

    It 'removes the named wrappers and leaves the rest' {
        $null = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--internal-link', 'alpha', 'beta')
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--unlink', 'alpha')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Match 'removed alpha.exe'
        Test-Path (Join-Path $script:H 'alpha.exe') | Should -BeFalse
        Test-Path (Join-Path $script:H 'beta.exe') | Should -BeTrue
    }

    It 'removes all wrappers with --all, but not wslbin.exe or other programs' {
        Copy-Item "$env:SystemRoot\System32\whoami.exe" (Join-Path $script:H 'foreign.exe')
        $null = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--internal-link', 'alpha', 'beta')
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--unlink', '--all')
        $r.ExitCode | Should -Be 0
        (Get-ChildItem $script:H -Filter *.exe).Name | Should -Be @('foreign.exe', 'wslbin.exe')
    }

    It 'refuses to remove a program that is not a wrapper' {
        $foreign = Join-Path $script:H 'foreign.exe'
        Copy-Item "$env:SystemRoot\System32\whoami.exe" $foreign
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--unlink', 'foreign')
        $r.ExitCode | Should -Be 125
        $r.Err | Should -Match 'not a wslbin wrapper'
        Test-Path $foreign | Should -BeTrue
    }

    It 'reports a wrapper that does not exist, without failing' {
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--unlink', 'nosuch')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Match 'no wrapper nosuch.exe'
    }

    It 'wants names or --all for --unlink' {
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--unlink')
        $r.ExitCode | Should -Be 125
        $r.Err | Should -Match 'needs the names'
    }

    It 'refuses an invalid name in --unlink' {
        (Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--unlink', '..\evil')).ExitCode | Should -Be 125
    }

    It 'removes nothing when one of the names in --unlink is invalid' {
        $null = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--internal-link', 'alpha')
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--unlink', 'alpha', '..\evil')
        $r.ExitCode | Should -Be 125
        Test-Path (Join-Path $script:H 'alpha.exe') | Should -BeTrue
    }

    It 'refuses names together with --all in --unlink' {
        $null = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--internal-link', 'alpha')
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--unlink', '--all', 'alpha')
        $r.ExitCode | Should -Be 125
        $r.Err | Should -Match 'not both'
        Test-Path (Join-Path $script:H 'alpha.exe') | Should -BeTrue
    }

    It 'says "would update" for a wrapper that is there already, in a dry run' {
        $null = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--internal-link', 'alpha')
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Env $script:Env -Arguments @('--link', '--dry-run')
        $r.Out | Should -Match 'would update .*alpha.exe'
    }

    It 'a wrapper made by --internal-link behaves as a wrapper' {
        $null = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--internal-link', 'rsync')
        (Invoke-Wslbin -Name 'rsync' -Dir $script:H -Arguments @('--wslbin-explain', '-av', 'C:\x')).Out | Should -BeExactly "rsync -av /mnt/c/x`n"
    }
}

Describe 'with real WSL' -Tag 'WSL' -Skip:$NoWsl {
    BeforeEach {
        $script:H = New-WslbinHome
        $script:Env = @{ PATH = (Get-IsolatedPath $script:H) }
    }

    It 'creates wrappers for utilities that exist in WSL, and they work' {
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Env $script:Env -Arguments @('--link', 'rsync', 'make')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Match 'created rsync.exe'
        $r.Out | Should -Match 'created make.exe'
        (Invoke-Wslbin -Name 'rsync' -Dir $script:H -Arguments @('--version')).Out | Should -Match '^rsync\s+version'
    }

    It 'is idempotent' {
        $null = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Env $script:Env -Arguments @('--link', 'rsync')
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Env $script:Env -Arguments @('--link', 'rsync')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Match 'up to date rsync.exe'
    }

    It 'does not create a wrapper for a utility that WSL does not have' {
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Env $script:Env -Arguments @('--link', 'wslbin-no-such-tool', 'rsync')
        $r.ExitCode | Should -Be 125
        $r.Err | Should -Match 'wslbin-no-such-tool: not found in WSL'
        Test-Path (Join-Path $script:H 'wslbin-no-such-tool.exe') | Should -BeFalse
        # the other utility is still linked
        Test-Path (Join-Path $script:H 'rsync.exe') | Should -BeTrue
    }

    It 'changes nothing with --dry-run' {
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Env $script:Env -Arguments @('--link', '--dry-run', 'rsync')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Match 'would create .*rsync.exe'
        Test-Path (Join-Path $script:H 'rsync.exe') | Should -BeFalse
    }

    It 'shows the apt command in a dry run for a package that is not installed' {
        $probe = (& wsl.exe --exec bash --noprofile --norc -c 'command -v cowsay >/dev/null && echo installed; apt-cache policy cowsay 2>/dev/null | grep -q "Candidate: [0-9]" && echo candidate') -join ' '
        if ($probe -match 'installed' -or $probe -notmatch 'candidate') {
            Set-ItResult -Skipped -Because 'cowsay is installed here, or apt has no package lists to offer it from'
            return
        }
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Env $script:Env -Arguments @('--link', '--dry-run', 'cowsay')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Match 'would run: wsl.exe .*-u root --exec apt-get install -y cowsay'
        Test-Path (Join-Path $script:H 'cowsay.exe') | Should -BeFalse
    }

    It 'lists each wrapper with what is wrong with it' {
        $null = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Env $script:Env -Arguments @('--link', 'rsync', 'make')
        $null = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--internal-link', 'wslbin-fake-tool', 'ls')
        $stream = [IO.File]::Open((Join-Path $script:H 'make.exe'), 'Append'); $stream.WriteByte(0); $stream.Close()
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Env $script:Env -Arguments @('--list')
        $r.ExitCode | Should -Be 0
        $lines = $r.Out -split "`n"
        ($lines | Where-Object { $_ -match '^rsync\s' }) | Should -Match '\sok$'
        ($lines | Where-Object { $_ -match '^make\s' }) | Should -Match 'outdated'
        ($lines | Where-Object { $_ -match '^wslbin-fake-tool\s' }) | Should -Match 'not found in WSL'
        ($lines | Where-Object { $_ -match '^ls\s' }) | Should -Match "PowerShell runs its own 'ls'"
    }

    It 'finds tools in extra directories with the path key, and not without it' {
        & wsl.exe --exec bash --noprofile --norc -c 'mkdir -p "$HOME/wslbin-test-bin" && printf "#!/bin/sh\necho extra-path-works\n" > "$HOME/wslbin-test-bin/wslbintest-hello" && chmod +x "$HOME/wslbin-test-bin/wslbintest-hello"'
        $without = Invoke-Wslbin -Name 'wslbintest-hello' -Dir $script:H
        $without.ExitCode | Should -Be 127
        $with = Invoke-Wslbin -Name 'wslbintest-hello' -Dir $script:H -Ini 'path = ~/wslbin-test-bin'
        $with.ExitCode | Should -Be 0
        $with.Out.Trim() | Should -BeExactly 'extra-path-works'
        # a chain in a -c string sees the directory in every part
        $chain = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Ini 'path = ~/wslbin-test-bin' -Arguments @('-c', 'true && wslbintest-hello | cat')
        $chain.Out.Trim() | Should -BeExactly 'extra-path-works'
    }
}
