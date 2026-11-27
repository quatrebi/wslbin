#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
  Common Linux utilities run through wslbin in a real WSL distribution: jq, awk, seq, sed, grep, find, sort,
  tar, xargs, diff, head, tail, curl. Tagged WSL and Utilities. A test skips itself when there is no WSL
  or the utility is not installed in the distribution (nothing is installed by the tests).
  Where the exit code of a utility is not fixed by its manual, the test compares it with the same utility
  run directly by wsl.exe.
#>

BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'helpers.ps1')
    $NoWsl = $true
    try {
        $null = & wsl.exe -l -q 2>$null
        if ($LASTEXITCODE -eq 0) { $NoWsl = $false }
    } catch { }
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers.ps1')
    Initialize-WslbinTest

    # Asks WSL once which of the utilities exist. (The same check is repeated here and not taken from
    # BeforeDiscovery: variables of BeforeDiscovery are $null inside BeforeAll and It.)
    $script:Have = @{}
    $names = 'jq', 'awk', 'seq', 'sed', 'grep', 'find', 'sort', 'tar', 'xargs', 'diff', 'head', 'tail', 'curl'
    try {
        $found = @(& wsl.exe --exec bash --noprofile --norc -c ('for u in ' + ($names -join ' ') + '; do command -v "$u" >/dev/null 2>&1 && echo "have:$u"; done') 2>$null)
        foreach ($line in $found) { if ("$line".Trim() -match '^have:(.+)$') { $script:Have[$Matches[1]] = $true } }
    } catch { }

    # Non-ASCII text is built from code points: this file must read the same in any PowerShell.
    $script:Ru = -join ([char[]](0x0444, 0x0430, 0x0439, 0x043B))                       # "файл"
    $script:Emoji = [char]::ConvertFromUtf32(0x1F600)

    # true when the utility is there; otherwise marks the running test as skipped (call it first, and
    # "return" when it answers false)
    function Test-Utility {
        param([string[]]$Name)
        $missing = @($Name | Where-Object { -not $script:Have[$_] })
        if ($missing.Count -eq 0) { return $true }
        Set-ItResult -Skipped -Because "$($missing -join ', ') is not installed in the WSL distribution"
        $false
    }

    # Runs <name>.exe (a copy of wslbin) in a folder of its own that is empty unless -WorkingDirectory
    # says otherwise (a wildcard such as *.txt then matches nothing, and .[0] is no glob of a real file).
    function Invoke-U {
        param([string]$Name, [string[]]$Arguments = @(), [string]$InputText, [string]$WorkingDirectory, [string[]]$Flags = @())
        if (-not $WorkingDirectory) { $WorkingDirectory = New-FileDir -Files @() }
        $splat = @{ Name = $Name; Arguments = (@($Flags) + @($Arguments)); WorkingDirectory = $WorkingDirectory }
        if ($PSBoundParameters.ContainsKey('InputText')) { $splat.InputText = $InputText }
        Invoke-Wslbin @splat
    }

    # The exit code of the same utility run directly by wsl.exe (ASCII input only).
    function Get-DirectCode {
        param([string[]]$Command, [string]$InputText = '')
        $null = $InputText | & wsl.exe --exec @Command 2>&1
        $LASTEXITCODE
    }

    function Get-Lines([string]$Text) { @($Text.Replace("`r", '').TrimEnd("`n") -split "`n") }

    # a file of n lines "l1".."ln" in a new folder; returns the folder
    function New-LinesFile {
        param([string]$Name = 'lines.txt', [int]$Count = 5)
        $dir = New-FileDir -Files @()
        [IO.File]::WriteAllText((Join-Path $dir $Name), ((1..$Count | ForEach-Object { "l$_" }) -join "`n") + "`n")
        $dir
    }

    function Get-LinuxPath([string]$Windows) { (& wsl.exe --exec wslpath -a $Windows | Select-Object -First 1).Trim() }
}

AfterAll {
    Remove-WslbinTest
}

Describe 'common utilities through wslbin' -Tag 'WSL', 'Utilities' -Skip:$NoWsl {

    Context 'jq' {
        It 'reads standard input and prints compact JSON (-c .[0])' {
            if (-not (Test-Utility 'jq')) { return }
            $r = Invoke-U -Name 'jq' -Arguments @('-c', '.[0]') -InputText '[{"a":1}]'
            $r.ExitCode | Should -Be 0 -Because $r.Err
            $r.Out.Replace("`r", '') | Should -BeExactly "{`"a`":1}`n"
        }

        It 'builds an object with braces and a space in the filter' {
            if (-not (Test-Utility 'jq')) { return }
            $r = Invoke-U -Name 'jq' -Arguments @('-c', '{"x": .a}') -InputText '{"a":1}'
            $r.ExitCode | Should -Be 0 -Because $r.Err
            $r.Out.Replace("`r", '') | Should -BeExactly "{`"x`":1}`n"
        }

        It 'returns the exit codes of jq itself (<Case>)' -ForEach @(
            @{ Case = '-e on a missing key';  JqArgs = @('-e', '.missing'); In = '{}';       Direct = @('jq', '-e', '.missing');  ErrToo = $false }
            @{ Case = 'a bad filter';         JqArgs = @('.[');             In = '{}';       Direct = @('jq', '.[');              ErrToo = $true }
            @{ Case = 'bad JSON';             JqArgs = @('.');              In = 'not json'; Direct = @('jq', '.');               ErrToo = $true }
            @{ Case = 'a missing file';       JqArgs = @('.', '/nonexistent-wslbin-test.json'); In = ''; Direct = @('jq', '.', '/nonexistent-wslbin-test.json'); ErrToo = $true }
        ) {
            if (-not (Test-Utility 'jq')) { return }
            $want = Get-DirectCode -Command $Direct -InputText $In
            $want | Should -Not -Be 0
            $r = Invoke-U -Name 'jq' -Arguments $JqArgs -InputText $In
            $r.ExitCode | Should -Be $want
            # jq -e says nothing when it only reports "false or null" by its exit code
            if ($ErrToo) { $r.Err | Should -Not -BeNullOrEmpty }
        }

        It 'passes Cyrillic and an emoji through unchanged (-r .name)' {
            if (-not (Test-Utility 'jq')) { return }
            $name = "$script:Ru $script:Emoji $script:Ru"
            $r = Invoke-U -Name 'jq' -Arguments @('-r', '.name') -InputText ('{"name":"' + $name + '"}')
            $r.ExitCode | Should -Be 0 -Because $r.Err
            [string]::Equals($r.Out.Replace("`r", '').TrimEnd("`n"), $name, [StringComparison]::Ordinal) | Should -BeTrue -Because $r.Out
        }
    }

    Context 'awk' {
        It 'prints the first field of each line' {
            if (-not (Test-Utility 'awk')) { return }
            $r = Invoke-U -Name 'awk' -Arguments @('{print $1}') -InputText "a b`nc d`n"
            $r.ExitCode | Should -Be 0 -Because $r.Err
            Get-Lines $r.Out | Should -Be @('a', 'c')
        }

        It 'takes -F: and a comparison with >= (as in a passwd file)' {
            if (-not (Test-Utility 'awk')) { return }
            $r = Invoke-U -Name 'awk' -Arguments @('-F:', '$3 >= 1000 {print $1}') -InputText "root:x:0:0:r:/root:/bin/bash`nalice:x:1000:1000::/home/alice:/bin/sh`nbob:x:1001:1001::/home/bob:/bin/sh`n"
            $r.ExitCode | Should -Be 0 -Because $r.Err
            Get-Lines $r.Out | Should -Be @('alice', 'bob')
        }

        It 'returns the exit code of awk' {
            if (-not (Test-Utility 'awk')) { return }
            (Invoke-U -Name 'awk' -Arguments @('BEGIN{exit 3}')).ExitCode | Should -Be 3
        }

        It 'reports a syntax error with the exit code that awk gives directly' {
            if (-not (Test-Utility 'awk')) { return }
            $want = Get-DirectCode -Command @('awk', '{')
            $want | Should -Not -Be 0
            $r = Invoke-U -Name 'awk' -Arguments @('{') -InputText ''
            $r.ExitCode | Should -Be $want
            $r.Err | Should -Not -BeNullOrEmpty
        }
    }

    Context 'seq' {
        It 'counts' {
            if (-not (Test-Utility 'seq')) { return }
            Get-Lines (Invoke-U -Name 'seq' -Arguments @('3')).Out | Should -Be @('1', '2', '3')
        }

        It 'formats with -f' {
            if (-not (Test-Utility 'seq')) { return }
            Get-Lines (Invoke-U -Name 'seq' -Arguments @('-f', '%03g', '3')).Out | Should -Be @('001', '002', '003')
        }

        It 'takes a separator with a space (-s ", ")' {
            if (-not (Test-Utility 'seq')) { return }
            (Invoke-U -Name 'seq' -Arguments @('-s', ', ', '3')).Out.Replace("`r", '') | Should -BeExactly "1, 2, 3`n"
        }

        It 'reports an invalid argument with the direct exit code' {
            if (-not (Test-Utility 'seq')) { return }
            $want = Get-DirectCode -Command @('seq', 'a')
            $want | Should -Not -Be 0
            $r = Invoke-U -Name 'seq' -Arguments @('a')
            $r.ExitCode | Should -Be $want
            $r.Err | Should -Not -BeNullOrEmpty
        }
    }

    Context 'sed' {
        It 'substitutes with a pattern that has a star (s/a*/b/)' {
            if (-not (Test-Utility 'sed')) { return }
            $r = Invoke-U -Name 'sed' -Arguments @('s/a*/b/') -InputText "aaa`nxaa`n"
            $r.ExitCode | Should -Be 0 -Because $r.Err
            Get-Lines $r.Out | Should -Be @('b', 'bxaa')
        }

        It 'takes an extended expression with a group and |' {
            if (-not (Test-Utility 'sed')) { return }
            $r = Invoke-U -Name 'sed' -Arguments @('-E', 's/(x|y)/z/g') -InputText "xay`n"
            $r.ExitCode | Should -Be 0 -Because $r.Err
            Get-Lines $r.Out | Should -Be @('zaz')
        }

        It 'takes a Cyrillic argument' {
            if (-not (Test-Utility 'sed')) { return }
            $r = Invoke-U -Name 'sed' -Arguments @("s/$script:Ru/X/") -InputText "${script:Ru}ab`n"
            $r.ExitCode | Should -Be 0 -Because $r.Err
            [string]::Equals($r.Out.Replace("`r", '').TrimEnd("`n"), 'Xab', [StringComparison]::Ordinal) | Should -BeTrue -Because $r.Out
        }
    }

    Context 'grep' {
        It 'finds lines in a file given by a Windows path (-E x|y)' {
            if (-not (Test-Utility 'grep')) { return }
            $dir = New-FileDir -Files @()
            [IO.File]::WriteAllText((Join-Path $dir 'g.txt'), "ax`nbb`ncy`n")
            $r = Invoke-U -Name 'grep' -Arguments @('-E', 'x|y', "$dir\g.txt")
            $r.ExitCode | Should -Be 0 -Because $r.Err
            Get-Lines $r.Out | Should -Be @('ax', 'cy')
        }

        It 'returns 1 when nothing matches, and 2 for a missing file' {
            if (-not (Test-Utility 'grep')) { return }
            $dir = New-FileDir -Files @('g.txt')
            $none = Invoke-U -Name 'grep' -Arguments @('-E', 'zzz', "$dir\g.txt")
            $none.ExitCode | Should -Be 1
            $none.Out | Should -BeNullOrEmpty
            $missing = Invoke-U -Name 'grep' -Arguments @('x', "$dir\nope.txt")
            $missing.ExitCode | Should -Be 2
            $missing.Err | Should -Not -BeNullOrEmpty
        }
    }

    Context 'find' {
        It 'finds every file by -name in raw mode, quotes or not' {
            if (-not (Test-Utility 'find')) { return }
            $dir = New-FileDir -Files @('a.txt', 'b.txt', 'x.log')
            New-Item -ItemType Directory -Path (Join-Path $dir 'sub') | Out-Null
            [IO.File]::WriteAllText((Join-Path $dir 'sub\c.txt'), "c`n")
            $r = Invoke-U -Name 'find' -WorkingDirectory $dir -Arguments @('--wslbin-raw', '.', '-name', '*.txt')
            $r.ExitCode | Should -Be 0 -Because $r.Err
            @(Get-Lines $r.Out | Sort-Object) | Should -Be @('./a.txt', './b.txt', './sub/c.txt')
        }

        # docs/en/globs.txt: in smart mode bash expands *.txt in the current folder before find sees it
        It 'in smart mode lets bash expand *.txt in the current folder first, as globs.txt says' {
            if (-not (Test-Utility 'find')) { return }
            $dir = New-FileDir -Files @('a.txt', 'x.log')
            New-Item -ItemType Directory -Path (Join-Path $dir 'sub') | Out-Null
            [IO.File]::WriteAllText((Join-Path $dir 'sub\b.txt'), "b`n")
            $r = Invoke-U -Name 'find' -WorkingDirectory $dir -Arguments @('.', '-name', '*.txt')
            # bash passed "-name a.txt": only the file of that name, and none in sub\ is found
            $r.ExitCode | Should -Be 0 -Because $r.Err
            Get-Lines $r.Out | Should -Be @('./a.txt')
        }
    }

    Context 'sort' {
        It 'sorts standard input in reverse (-r)' {
            if (-not (Test-Utility 'sort')) { return }
            Get-Lines (Invoke-U -Name 'sort' -Arguments @('-r') -InputText "b`na`nc`n").Out | Should -Be @('c', 'b', 'a')
        }

        It 'writes the file given by -o with a Windows path on the Windows side' {
            if (-not (Test-Utility 'sort')) { return }
            $dir = New-FileDir -Files @()
            $r = Invoke-U -Name 'sort' -Arguments @('-o', "$dir\sorted.txt") -InputText "b`na`nc`n"
            $r.ExitCode | Should -Be 0 -Because $r.Err
            $r.Out | Should -BeNullOrEmpty
            [IO.File]::ReadAllText((Join-Path $dir 'sorted.txt')).Replace("`r", '') | Should -BeExactly "a`nb`nc`n"
        }
    }

    Context 'tar' {
        It 'creates an archive by Windows paths (-cf, -C) and lists it (-tf)' {
            if (-not (Test-Utility 'tar')) { return }
            $dir = New-FileDir -Files @('a.txt', 'b.txt')
            $out = New-FileDir -Files @()
            $make = Invoke-U -Name 'tar' -Arguments @('-cf', "$out\x.tar", '-C', $dir, 'a.txt', 'b.txt')
            $make.ExitCode | Should -Be 0 -Because $make.Err
            Test-Path (Join-Path $out 'x.tar') | Should -BeTrue
            $list = Invoke-U -Name 'tar' -Arguments @('-tf', "$out\x.tar")
            $list.ExitCode | Should -Be 0 -Because $list.Err
            Get-Lines $list.Out | Should -Be @('a.txt', 'b.txt')
        }
    }

    Context 'xargs' {
        It 'runs a command for each line with -I{}' {
            if (-not (Test-Utility 'xargs')) { return }
            $r = Invoke-U -Name 'xargs' -Arguments @('-I{}', 'echo', '[{}]') -InputText "a`nb`n"
            $r.ExitCode | Should -Be 0 -Because $r.Err
            Get-Lines $r.Out | Should -Be @('[a]', '[b]')
        }
    }

    Context 'diff' {
        It 'returns 0 for equal files, 1 with output for different ones, 2 for a missing file' {
            if (-not (Test-Utility 'diff')) { return }
            $dir = New-FileDir -Files @('a.txt', 'b.txt')
            Copy-Item (Join-Path $dir 'a.txt') (Join-Path $dir 'a2.txt')
            $same = Invoke-U -Name 'diff' -Arguments @("$dir\a.txt", "$dir\a2.txt")
            $same.ExitCode | Should -Be 0 -Because $same.Err
            $same.Out | Should -BeNullOrEmpty
            $differ = Invoke-U -Name 'diff' -Arguments @("$dir\a.txt", "$dir\b.txt")
            $differ.ExitCode | Should -Be 1
            $differ.Out | Should -Not -BeNullOrEmpty
            $missing = Invoke-U -Name 'diff' -Arguments @("$dir\a.txt", "$dir\nope.txt")
            $missing.ExitCode | Should -Be 2
            $missing.Err | Should -Not -BeNullOrEmpty
        }
    }

    Context 'head and tail' {
        It 'takes the first and the last two lines of a file by a Windows path (<Tool>)' -ForEach @(
            @{ Tool = 'head'; Want = @('l1', 'l2') }
            @{ Tool = 'tail'; Want = @('l4', 'l5') }
        ) {
            if (-not (Test-Utility $Tool)) { return }
            $dir = New-LinesFile
            $r = Invoke-U -Name $Tool -Arguments @('-n', '2', "$dir\lines.txt")
            $r.ExitCode | Should -Be 0 -Because $r.Err
            Get-Lines $r.Out | Should -Be $Want
        }

        It 'takes a relative path with a backslash (<Tool>)' -ForEach @(
            @{ Tool = 'head'; Want = @('l1', 'l2') }
            @{ Tool = 'tail'; Want = @('l4', 'l5') }
        ) {
            if (-not (Test-Utility $Tool)) { return }
            $dir = New-LinesFile
            $r = Invoke-U -Name $Tool -WorkingDirectory $dir -Arguments @('-n', '2', '.\lines.txt')
            $r.ExitCode | Should -Be 0 -Because $r.Err
            Get-Lines $r.Out | Should -Be $Want
        }

        It 'returns the bytes 0..255, CR LF and Ctrl+Z from standard input unchanged (head -c 258)' {
            if (-not (Test-Utility 'head')) { return }
            $bytes = [byte[]]((0..255) + @(13, 10, 26))
            $r = Invoke-Wslbin -Name 'head' -Arguments @('-c', '258') -InputBytes $bytes -OutputBytes -WorkingDirectory (New-FileDir -Files @())
            $r.ExitCode | Should -Be 0 -Because $r.Err
            $got = [byte[]]$r.OutBytes
            $want = $bytes[0..257]
            $got.Length | Should -Be 258
            [Linq.Enumerable]::SequenceEqual([byte[]]$got, [byte[]]$want) | Should -BeTrue
        }
    }

    Context 'curl' {
        It 'reads a file by a file:// URL (-sS)' {
            if (-not (Test-Utility 'curl')) { return }
            $dir = New-FileDir -Files @('hello.txt')
            $r = Invoke-U -Name 'curl' -Arguments @('-sS', ('file://' + (Get-LinuxPath (Join-Path $dir 'hello.txt'))))
            $r.ExitCode | Should -Be 0 -Because $r.Err
            $r.Out.Replace("`r", '') | Should -BeExactly "hello.txt`n"
        }

        It 'returns 7 when nothing listens on the port (127.0.0.1:1)' {
            if (-not (Test-Utility 'curl')) { return }
            $r = Invoke-U -Name 'curl' -Arguments @('-sS', 'http://127.0.0.1:1/')
            $r.ExitCode | Should -Be 7
            $r.Err | Should -Not -BeNullOrEmpty
        }
    }

    Context 'a wrapper and the pipeline' {
        It 'a wrapper named after a utility that WSL lacks gives 127 and one "command not found" line, without a wslbin: prefix' {
            $name = 'nosuch-' + [guid]::NewGuid().ToString('N')
            $r = Invoke-U -Name $name -Arguments @('x')
            $r.ExitCode | Should -Be 127
            $lines = @(Get-Lines $r.Err)
            $lines.Count | Should -Be 1 -Because $r.Err
            $lines[0] | Should -Match 'command not found'
            $lines[0] | Should -Not -Match '^wslbin:'
        }

        It 'passes the output of one wrapper to the next in a PowerShell pipeline (seq 3 | sort -r)' {
            if (-not (Test-Utility 'seq', 'sort')) { return }
            $dir = Join-Path $global:WslbinTest.Work ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir | Out-Null
            Copy-Item $global:WslbinTest.Exe (Join-Path $dir 'seq.exe')
            Copy-Item $global:WslbinTest.Exe (Join-Path $dir 'sort.exe')
            $script = "`$ErrorActionPreference = 'Stop'; (& '$dir\seq.exe' 3 | & '$dir\sort.exe' -r) -join ' '"
            $out = & pwsh -NoProfile -Command $script
            "$out".Trim() | Should -BeExactly '3 2 1'
        }

        # Pins a behaviour, it does not hide it: PowerShell ends each string it pipes into a native program
        # with CR LF, wslbin hands standard input over unchanged, so awk sees "b`r" as the second field and
        # its length is 2 and not 1. A script that pipes text from PowerShell must strip the CR itself.
        It 'pins that a CR from a PowerShell pipe is part of the last field (awk length($2) is 2 for "a b")' {
            if (-not (Test-Utility 'awk')) { return }
            $dir = Join-Path $global:WslbinTest.Work ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir | Out-Null
            Copy-Item $global:WslbinTest.Exe (Join-Path $dir 'awk.exe')
            $script = "'a b' | & '$dir\awk.exe' '{print length(`$2)}'"
            $out = & pwsh -NoProfile -Command $script
            "$out".Trim() | Should -BeExactly '2'
        }
    }
}
