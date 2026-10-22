#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
  wslbin tests. Run from the repository root:  Invoke-Pester ./tests

  Logic tests (path translation, escaping, modes, config, WSLENV plan) go through
  --wslbin-explain and need no WSL, so they run in CI too.
  Tests tagged WSL run utilities in a real distribution and are skipped when there is none:
  Invoke-Pester ./tests -ExcludeTagFilter WSL    # logic tests only
#>

BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'helpers.ps1')
    $NoGitBash = -not (Get-GitBash)

    # Non-ASCII text is built from code points: this file must read the same in any PowerShell.
    $ru = -join ([char[]](0x0444, 0x0430, 0x0439, 0x043B))        # "файл"
    $ruSpaced = -join ([char[]](0x0444, 0x20, 0x0430, 0x0439, 0x043B))   # "ф айл"

    $NoWsl = $true
    try {
        $null = & wsl.exe -l -q 2>$null
        if ($LASTEXITCODE -eq 0) { $NoWsl = $false }
    } catch { }

    $SmartCases = @(
        @{ Arg = 'plain';           Want = 'plain' }
        @{ Arg = 'a b';             Want = 'a\ b' }
        @{ Arg = 'x;echo pwned';    Want = 'x\;echo\ pwned' }
        @{ Arg = '$(id)';           Want = '\$\(id\)' }
        @{ Arg = '$HOME';           Want = '\$HOME' }
        @{ Arg = '`uname`';         Want = '\`uname\`' }
        @{ Arg = '{print $1, $2}';  Want = '\{print\ \$1,\ \$2\}' }
        @{ Arg = '{a,b}';           Want = '\{a,b\}' }
        @{ Arg = "it's";            Want = "it\'s" }
        @{ Arg = 'say "hi"';        Want = 'say\ \"hi\"' }
        @{ Arg = 'a\b';             Want = 'a\\b' }
        @{ Arg = 'trailing\';       Want = 'trailing\\' }
        @{ Arg = 'a|b&c';           Want = 'a\|b\&c' }
        @{ Arg = 'a>b<c';           Want = 'a\>b\<c' }
        @{ Arg = '(paren)';         Want = '\(paren\)' }
        @{ Arg = '#hash';           Want = '\#hash' }
        @{ Arg = '!bang';           Want = '\!bang' }
        @{ Arg = '^caret';          Want = '\^caret' }
        @{ Arg = '%PATH%';          Want = '%PATH%' }
        @{ Arg = 'key=value';       Want = 'key=value' }
        @{ Arg = '';                Want = "''" }
        @{ Arg = $ru;               Want = $ru }
        @{ Arg = $ruSpaced;         Want = ($ruSpaced -replace ' ', '\ ') }
        # wildcards stay live: bash expands them in the current directory
        @{ Arg = '*.log';           Want = '*.log' }
        @{ Arg = 'file?.txt';       Want = 'file?.txt' }
        @{ Arg = '[abc]*';          Want = '[abc]*' }
        @{ Arg = '[!a]*';           Want = '[!a]*' }
        @{ Arg = '[^a]*';           Want = '[^a]*' }
        @{ Arg = '[a-z]*';          Want = '[a-z]*' }
        @{ Arg = '[[:digit:]]*';    Want = '[[:digit:]]*' }
        @{ Arg = 'a[[:alpha:]]b';   Want = 'a[[:alpha:]]b' }
        @{ Arg = '[[=e=]x]';        Want = '[[=e=]x]' }
        @{ Arg = '[[.-.]]';         Want = '[[.-.]]' }
        # what sits between [: and :] (or [= =], [. .]) reaches bash as it is only when it can be a class:
        # anything else is ordinary members, escaped one by one
        @{ Arg = '[[:a;id;:]]';     Want = '[\[:a\;id\;:]\]' }
        @{ Arg = '[[:$(id):]]';     Want = '[\[:\$\(id\):]\]' }
        @{ Arg = '[[=$(id)=]]';     Want = '[\[=\$\(id\)=]\]' }
        @{ Arg = '[[.`id`.]]';      Want = '[\[.\`id\`.]\]' }
        @{ Arg = '[[:${x}:]]';      Want = '[\[:\$\{x\}:]\]' }
        @{ Arg = '[[:Alpha:]]';     Want = '[\[:Alpha:]\]' }
        @{ Arg = '[[= =]]';         Want = '[\[=\ =]\]' }
        @{ Arg = 'a[b]c';           Want = 'a[b]c' }
        @{ Arg = '[a b]';           Want = '[a\ b]' }
        @{ Arg = '[]]';             Want = '[\]]' }
        @{ Arg = '--include=*.txt'; Want = '--include=*.txt' }
        @{ Arg = 'host:/srv/*';     Want = 'host:/srv/*' }
        # a bracket that never closes is an ordinary character
        @{ Arg = '[';               Want = '\[' }
        @{ Arg = '[abc';            Want = '\[abc' }
        @{ Arg = 'a]';              Want = 'a\]' }
        @{ Arg = '[]';              Want = '\[\]' }
        # ~ expands only at the start of an argument
        @{ Arg = '~';               Want = '~' }
        @{ Arg = '~/x';             Want = '~/x' }
        @{ Arg = '~user';           Want = '~user' }
        @{ Arg = 'a~b';             Want = 'a\~b' }
        @{ Arg = '~~';              Want = '~\~' }
    )

    $ShCases = @(
        @{ Arg = '$HOME';                          Want = '"$HOME"' }
        @{ Arg = 'OUT=$HOME/out';                  Want = '"OUT=$HOME/out"' }
        @{ Arg = '${A:-b c}';                      Want = '"${A:-b c}"' }
        @{ Arg = '$(date)';                        Want = '"$(date)"' }
        @{ Arg = '$((1+2))';                       Want = '"$((1+2))"' }
        @{ Arg = '`uname`';                        Want = '"`uname`"' }
        @{ Arg = 'TAG=$(git rev-parse --short HEAD)'; Want = '"TAG=$(git rev-parse --short HEAD)"' }
        # quotes inside $(...) are bash text and stay as typed; outside they are escaped
        @{ Arg = 'X=$(echo "a b")';                Want = '"X=$(echo "a b")"' }
        @{ Arg = "X=`$(echo ')')";                 Want = "`"X=`$(echo ')')`"" }
        @{ Arg = 'a"b$c';                          Want = '"a\"b$c"' }
        @{ Arg = 'a\b$c';                          Want = '"a\\b$c"' }
        @{ Arg = '~/$X';                           Want = '~/"$X"' }
        # no $ or ` in the argument: same as the smart mode
        @{ Arg = 'a;b';                            Want = 'a\;b' }
        @{ Arg = '*.log';                          Want = '*.log' }
    )

    $RawCases = @(
        @{ Arg = 'plain';        Want = 'plain' }
        @{ Arg = 'a*';           Want = "'a*'" }
        @{ Arg = "it's";         Want = "'it'\''s'" }
        @{ Arg = 'C:\x';         Want = "'C:\x'" }
        @{ Arg = '$HOME';        Want = "'`$HOME'" }
        @{ Arg = '';             Want = "''" }
        @{ Arg = 'key=value';    Want = 'key=value' }
        @{ Arg = '~';            Want = "'~'" }
    )

}

BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers.ps1')
    Initialize-WslbinTest
    $script:Ru = -join ([char[]](0x0444, 0x0430, 0x0439, 0x043B))
}

AfterAll {
    Remove-WslbinTest
}
Describe 'smart mode: escaping' {
    It "<Arg> -> <Want>" -ForEach $SmartCases {
        Get-Explain -Arguments @($Arg) | Should -BeExactly "tool $Want"
    }

    It 'keeps a newline inside quotes, where a backslash would swallow it' {
        Get-Explain -Arguments @("a`nb") | Should -BeExactly "tool a'`n'b"
    }
}

Describe 'sh mode' {
    It "<Arg> -> <Want>" -ForEach $ShCases {
        Get-Explain -Flags '--wslbin-sh' -Arguments @($Arg) | Should -BeExactly "tool $Want"
    }

    It 'leaves a $ alone in the default mode' {
        Get-Explain -Arguments @('OUT=$HOME/out') | Should -BeExactly 'tool OUT=\$HOME/out'
    }
}

Describe 'raw mode' {
    It "<Arg> -> <Want>" -ForEach $RawCases {
        Get-Explain -Flags '--wslbin-raw' -Arguments @($Arg) | Should -BeExactly "tool $Want"
    }
}

Describe 'flags of a wrapper' {
    It 'recognises --wslbin-* only in front of the arguments' {
        Get-Explain -Arguments @('-a', '--wslbin-raw') | Should -BeExactly 'tool -a --wslbin-raw'
    }

    It 'accepts the mode flag before or after --wslbin-explain' {
        (Invoke-Wslbin -Arguments @('--wslbin-raw', '--wslbin-explain', 'a*')).Out | Should -BeExactly "tool 'a*'`n"
    }

    It 'refuses an unknown --wslbin-* flag' {
        $r = Invoke-Wslbin -Arguments @('--wslbin-bogus')
        $r.ExitCode | Should -Be 125
        $r.Err | Should -Match 'unknown option --wslbin-bogus'
    }

    It 'refuses raw and sh together' {
        $r = Invoke-Wslbin -Arguments @('--wslbin-raw', '--wslbin-sh', '--wslbin-explain')
        $r.ExitCode | Should -Be 125
        $r.Err | Should -Match 'cannot be combined'
    }

    It 'passes --help and --version to the utility, not to wslbin' {
        Get-Explain -Arguments @('--help', '--version') | Should -BeExactly 'tool --help --version'
    }

    It 'exits with 0 when only explaining' {
        (Invoke-Wslbin -Arguments @('--wslbin-explain', 'x')).ExitCode | Should -Be 0
    }
}

Describe 'the utility name' {
    It 'is the name of the .exe without its extension' {
        Get-Explain -Name 'rsync' -Arguments @('-a') | Should -BeExactly 'rsync -a'
    }

    It 'may contain dots and plus signs' {
        Get-Explain -Name 'g++' | Should -BeExactly 'g++'
        Get-Explain -Name 'python3.12' | Should -BeExactly 'python3.12'
    }

    It 'is not mistaken for a bash keyword' {
        Get-Explain -Name 'time' -Arguments @('-v', 'ls') | Should -BeExactly '\time -v ls'
    }

    It 'is not mistaken for a variable assignment' {
        Get-Explain -Name 'a=b' -Arguments @('x') | Should -BeExactly "'a=b' x"
    }
}

Describe 'wslbin.ini' {
    It 'warns about a file that is not UTF-8, and still reads its keys' {
        $dir = Join-Path $global:WslbinTest.Work ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        # "raw = tool" and a comment in Windows-1251 (0xD4 0xE0 0xE9 0xEB, "файл"): not UTF-8
        $bytes = [Text.Encoding]::ASCII.GetBytes("# ") + [byte[]](0xD4, 0xE0, 0xE9, 0xEB) + [Text.Encoding]::ASCII.GetBytes("`nraw = tool`n")
        [IO.File]::WriteAllBytes((Join-Path $dir 'wslbin.ini'), $bytes)
        $r = Invoke-Wslbin -Dir $dir -Arguments @('--wslbin-explain', 'a*')
        $r.Out | Should -BeExactly "tool 'a*'`n"
        $r.Err | Should -Match 'is not UTF-8 text'
    }

    It 'makes a utility raw' {
        Get-Explain -Ini "raw = tool, other`n" -Arguments @('a*', 'C:\x') | Should -BeExactly "tool 'a*' 'C:\x'"
    }

    It 'makes a utility sh' {
        Get-Explain -Ini "sh = tool`n" -Arguments @('$HOME') | Should -BeExactly 'tool "$HOME"'
    }

    It 'lets a flag override the configured mode' {
        Get-Explain -Ini "raw = tool`n" -Flags '--wslbin-sh' -Arguments @('$HOME') | Should -BeExactly 'tool "$HOME"'
    }

    It 'matches utility names and keys without regard to case' {
        Get-Explain -Ini "RAW = TOOL`n" -Arguments @('a*') | Should -BeExactly "tool 'a*'"
    }

    It 'adds up repeated list keys' {
        Get-Explain -Ini "raw = one`nraw = tool`n" -Arguments @('a*') | Should -BeExactly "tool 'a*'"
    }

    It 'puts default arguments in front of the typed ones' {
        Get-Explain -Ini 'args.tool = --color=auto -x' -Arguments @('dir') | Should -BeExactly 'tool --color=auto -x dir'
    }

    It 'groups default arguments with quotes' {
        Get-Explain -Ini 'args.tool = "a b" c' | Should -BeExactly 'tool a\ b c'
    }

    It 'applies the mode to default arguments too' {
        Get-Explain -Ini "raw = tool`nargs.tool = a*" | Should -BeExactly "tool 'a*'"
    }

    It 'ignores comments and blank lines, and reads a UTF-8 byte order mark' {
        $ini = "# comment`n; another`n`n  raw = tool  `n"
        Get-Explain -Ini $ini -Arguments @('a*') | Should -BeExactly "tool 'a*'"
        (Invoke-Wslbin -Ini $ini -IniWithBom -Arguments @('--wslbin-explain', 'a*')).Out | Should -BeExactly "tool 'a*'`n"
    }

    It 'warns about bad lines and unknown keys, with line numbers, and carries on' {
        $r = Invoke-Wslbin -Ini "raw = tool`nnot a setting`nfrobnicate = 1`n" -Arguments @('--wslbin-explain', 'a*')
        $r.Out | Should -BeExactly "tool 'a*'`n"
        $r.Err | Should -Match "line 2: expected 'key = value'"
        $r.Err | Should -Match "line 3: unknown key 'frobnicate'"
        $r.ExitCode | Should -Be 0
    }

    It 'does not need to exist' {
        (Invoke-Wslbin -Arguments @('--wslbin-explain', 'x')).Err | Should -BeNullOrEmpty
    }

    It 'adds directories to PATH inside WSL with the path key' {
        Get-Explain -Ini 'path = ~/.local/bin, /opt/my tools' -Arguments @('x') |
            Should -BeExactly 'export PATH="$HOME/.local/bin:/opt/my tools:$PATH"; tool x'
    }

    It 'puts the PATH change in front of a -c string too' {
        (Invoke-Wslbin -Name 'wslbin' -Ini 'path = ~/bin' -Arguments @('--explain', '-c', 'a | b')).Out |
            Should -BeExactly "export PATH=`"`$HOME/bin:`$PATH`"; a | b`n"
    }

    It 'escapes what bash would read inside the double quotes of a path entry' {
        Get-Explain -Ini 'path = /a$b"c' | Should -BeExactly 'export PATH="/a\$b\"c:$PATH"; tool'
    }

    It 'takes the quotes off a path entry in quotes, as off distro' {
        Get-Explain -Ini 'path = "/opt/my tools", ~/bin' | Should -BeExactly 'export PATH="/opt/my tools:$HOME/bin:$PATH"; tool'
    }

    It 'ignores a path entry that has a colon, with a warning' {
        $r = Invoke-Wslbin -Ini 'path = /a:b, /c' -Arguments @('--wslbin-explain')
        $r.Out | Should -BeExactly "export PATH=`"/c:`$PATH`"; tool`n"
        $r.Err | Should -Match "line 1: path entry '/a:b' contains ':'"
    }

    It 'adds nothing without the path key' {
        Get-Explain -Arguments @('x') | Should -BeExactly 'tool x'
    }
}

Describe 'wslbin.exe itself' {
    It 'prints its version' {
        $r = Invoke-Wslbin -Name 'wslbin' -Arguments @('--version')
        $r.Out | Should -Match '^wslbin \d+\.\d+\.\d+'
        $r.ExitCode | Should -Be 0
    }

    It 'prints usage and fails without arguments' {
        $r = Invoke-Wslbin -Name 'wslbin'
        $r.ExitCode | Should -Be 125
        $r.Err | Should -Match 'Usage'
    }

    It 'takes --raw and --sh before the utility' {
        (Invoke-Wslbin -Name 'wslbin' -Arguments @('--explain', '--raw', 'grep', 'a*')).Out | Should -BeExactly "grep 'a*'`n"
        (Invoke-Wslbin -Name 'wslbin' -Arguments @('--sh', '--explain', 'make', 'V=$X')).Out | Should -BeExactly "make `"V=`$X`"`n"
    }

    It 'hands a whole string to bash with -c' {
        (Invoke-Wslbin -Name 'wslbin' -Arguments @('--explain', '-c', 'ls *.log | wc -l')).Out | Should -BeExactly "ls *.log | wc -l`n"
    }

    It 'refuses -c with --raw, -c without a string, and unknown options' {
        (Invoke-Wslbin -Name 'wslbin' -Arguments @('--raw', '-c', 'x')).ExitCode | Should -Be 125
        (Invoke-Wslbin -Name 'wslbin' -Arguments @('-c')).ExitCode | Should -Be 125
        $r = Invoke-Wslbin -Name 'wslbin' -Arguments @('--bogus')
        $r.ExitCode | Should -Be 125
        $r.Err | Should -Match 'unknown option --bogus'
    }

}

# The bash command that --wslbin-explain prints, run by a real bash without WSL: Git Bash, which GitHub's
# Windows runners have, so the escaping is checked by bash in CI and not only on a machine with WSL.
Describe 'escaping, checked by bash (Git Bash)' -Skip:$NoGitBash {
    BeforeAll {
        $script:Empty = New-FileDir -Files @()
        # The arguments that printf got, one per NUL.
        function Get-Delivered([string[]]$Flags, [string[]]$Arguments) {
            $explain = Invoke-Wslbin -Name 'printf' -WorkingDirectory $script:Empty -Arguments (@('--wslbin-explain') + $Flags + '%s\0' + $Arguments)
            $explain.ExitCode | Should -Be 0 -Because $explain.Err
            $r = Invoke-GitBash -Script $explain.Out -WorkingDirectory $script:Empty
            $r.ExitCode | Should -Be 0 -Because $r.Err
            $got = @($r.Out -split "`0")
            if ($got[-1] -eq '') { $got = @($got | Select-Object -First ($got.Count - 1)) }
            $got
        }
        function Assert-Delivered([string[]]$Sent, [string[]]$Got, [string]$Label) {
            $Got.Count | Should -Be $Sent.Count -Because $Label
            for ($i = 0; $i -lt $Sent.Count; $i++) {
                if (-not [string]::Equals($Got[$i], $Sent[$i], [StringComparison]::Ordinal)) {
                    throw "${Label}: sent <$($Sent[$i] -replace "`n",'\n')> but printf got <$($Got[$i] -replace "`n",'\n')>"
                }
            }
        }
    }

    It 'delivers every argument as typed (<Mode>)' -ForEach @(
        @{ Mode = 'smart'; Flags = @() }
        @{ Mode = 'raw';   Flags = @('--wslbin-raw') }
    ) {
        $nasty = @(Get-NastyArguments)
        Assert-Delivered $nasty (Get-Delivered $Flags $nasty) $Mode
    }

    It 'delivers arguments without $ and ` as typed in sh mode' {
        $plain = @(Get-NastyArguments | Where-Object { $_ -notmatch '[$`]' })
        $plain.Count | Should -BeGreaterThan 20
        Assert-Delivered $plain (Get-Delivered @('--wslbin-sh') $plain) 'sh'
    }

    It 'delivers 3000 random hostile arguments as typed, in every mode' {
        $rng = [System.Random]::new(20261022)
        foreach ($mode in @(@{ Name = 'smart'; Flags = @() }, @{ Name = 'raw'; Flags = @('--wslbin-raw') }, @{ Name = 'sh'; Flags = @('--wslbin-sh') })) {
            for ($round = 0; $round -lt 10; $round++) {
                $sent = @(New-HostileArguments -Random $rng -Count 100 -Mode $mode.Name)
                Assert-Delivered $sent (Get-Delivered $mode.Flags $sent) "$($mode.Name) round $round"
            }
        }
    }
}

Describe 'real WSL' -Tag 'WSL' -Skip:$NoWsl {
    It 'delivers every argument as exactly one argument, as typed (<Mode>)' -ForEach @(
        @{ Mode = 'smart'; Flags = @() }
        @{ Mode = 'raw';   Flags = @('--wslbin-raw') }
    ) {
        $dir = New-FileDir -Files @('unrelated.txt')
        $nasty = @(Get-NastyArguments)
        $nasty.Count | Should -BeGreaterThan 30
        $r = Invoke-Wslbin -Name 'printf' -WorkingDirectory $dir -Arguments (@($Flags) + '[%s]\n' + $nasty)
        $r.ExitCode | Should -Be 0
        $r.Err | Should -BeNullOrEmpty
        $want = ($nasty | ForEach-Object { "[$_]" }) -join "`n"
        $r.Out.Replace("`r", '').TrimEnd("`n") | Should -BeExactly $want
    }

    It 'delivers arguments without $ and ` as typed in sh mode' {
        $dir = New-FileDir -Files @('unrelated.txt')
        $plain = @(Get-NastyArguments | Where-Object { $_ -notmatch '[$`]' })
        $plain.Count | Should -BeGreaterThan 20
        $r = Invoke-Wslbin -Name 'printf' -WorkingDirectory $dir -Arguments (@('--wslbin-sh', '[%s]\n') + $plain)
        $r.ExitCode | Should -Be 0
        $want = ($plain | ForEach-Object { "[$_]" }) -join "`n"
        $r.Out.Replace("`r", '').TrimEnd("`n") | Should -BeExactly $want
    }

    # What the text for agents says about reading non-ASCII output in PowerShell.
    It 'gives PowerShell the output of a utility in UTF-8, which it reads after [Console]::OutputEncoding is set' {
        $dir = Join-Path $global:WslbinTest.Work ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        Copy-Item $global:WslbinTest.Exe (Join-Path $dir 'printf.exe')
        $codes = '0x0444, 0x0430, 0x0439, 0x043B'
        $script = "[Console]::OutputEncoding = [Text.Encoding]::UTF8; `$w = -join [char[]]($codes); `$got = & '$(Join-Path $dir 'printf.exe')' '%s' `$w; [int](`$got -eq `$w)"
        (& pwsh -NoProfile -Command $script) | Should -Be '1'
    }

    It 'lets bash expand wildcards in the current directory, by Linux rules' {
        $dir = New-FileDir -Files @('a.log', 'b.log', 'c d.log', 'x.txt')
        (Invoke-Wslbin -Name 'ls' -WorkingDirectory $dir -Arguments @('-1', '*.log')).Out.Replace("`r", '') | Should -BeExactly "a.log`nb.log`nc d.log`n"
        (Invoke-Wslbin -Name 'ls' -WorkingDirectory $dir -Arguments @('-1', '[ab].log')).Out.Replace("`r", '') | Should -BeExactly "a.log`nb.log`n"
        (Invoke-Wslbin -Name 'ls' -WorkingDirectory $dir -Arguments @('-1', '[!a].log')).Out.Replace("`r", '') | Should -BeExactly "b.log`n"
        (Invoke-Wslbin -Name 'ls' -WorkingDirectory $dir -Arguments @('-1', '?.txt')).Out.Replace("`r", '') | Should -BeExactly "x.txt`n"
    }

    It 'passes a wildcard that matches nothing as it is' {
        $dir = New-FileDir -Files @('x.txt')
        $r = Invoke-Wslbin -Name 'printf' -WorkingDirectory $dir -Arguments @('[%s]\n', '*.nomatch', '--include=*.txt', 'server:/path/*')
        $r.Out.Replace("`r", '') | Should -BeExactly "[*.nomatch]`n[--include=*.txt]`n[server:/path/*]`n"
    }

    It 'does not expand wildcards in raw mode' {
        $dir = New-FileDir -Files @('a.log')
        (Invoke-Wslbin -Name 'printf' -WorkingDirectory $dir -Arguments @('--wslbin-raw', '[%s]\n', '*.log')).Out.Replace("`r", '') | Should -BeExactly "[*.log]`n"
    }

    It 'handles non-ASCII file names and arguments' {
        $dir = New-FileDir -Files @("$script:Ru.txt", "$script:Ru 2.txt")
        $r = Invoke-Wslbin -Name 'ls' -WorkingDirectory $dir -Arguments @('-1', "$script:Ru*")
        $r.Out.Replace("`r", '') | Should -BeExactly "$script:Ru 2.txt`n$script:Ru.txt`n"
    }

    It 'feeds standard input to the utility and returns its output' {
        $r = Invoke-Wslbin -Name 'cat' -InputText "abc`ndef`n"
        $r.Out.Replace("`r", '') | Should -BeExactly "abc`ndef`n"
        $r.ExitCode | Should -Be 0
    }

    It 'keeps standard error apart from standard output' {
        $r = Invoke-Wslbin -Name 'ls' -Arguments @('/nonexistent-wslbin-test')
        $r.Out | Should -BeNullOrEmpty
        $r.Err | Should -Match 'No such file'
        $r.ExitCode | Should -Be 2
    }

    It 'returns the exit code of the utility' {
        (Invoke-Wslbin -Name 'false').ExitCode | Should -Be 1
        (Invoke-Wslbin -Name 'wslbin' -Arguments @('-c', 'exit 7')).ExitCode | Should -Be 7
        (Invoke-Wslbin -Name 'wslbin' -Arguments @('-c', 'exit 0')).ExitCode | Should -Be 0
    }

    It 'returns 127 for a utility that does not exist' {
        $r = Invoke-Wslbin -Name 'wslbin' -Arguments @('nosuchutility-wslbin-test')
        $r.ExitCode | Should -Be 127
        $r.Err | Should -Match 'command not found'
    }

    It 'returns 125 when wsl.exe cannot start the distribution' {
        (Invoke-Wslbin -Name 'echo' -Ini 'distro = NoSuchDistro-wslbin-test' -Arguments @('hi')).ExitCode | Should -Be 125
    }

    It 'runs in the configured distribution' {
        $default = (& wsl.exe --exec printenv WSL_DISTRO_NAME).Trim()
        $r = Invoke-Wslbin -Name 'printenv' -Ini "distro = $default" -Arguments @('WSL_DISTRO_NAME')
        $r.Out.Trim() | Should -BeExactly $default
        $r.ExitCode | Should -Be 0
    }

    It 'substitutes Linux variables and commands in sh mode, as one argument each' {
        $home1 = (& wsl.exe --exec bash --noprofile --norc -c 'printf %s "$HOME"')
        $r = Invoke-Wslbin -Name 'printf' -Arguments @('--wslbin-sh', '[%s]\n', 'h=$HOME', 'a$(echo b c)d', '`echo z`', 'q="$(echo "x y")"')
        $r.Out.Replace("`r", '') | Should -BeExactly "[h=$home1]`n[ab cd]`n[z]`n[q=`"x y`"]`n"
    }

    It 'leaves $ and ` alone in the default mode' {
        $r = Invoke-Wslbin -Name 'printf' -Arguments @('[%s]\n', '$HOME', '$(id)')
        $r.Out.Replace("`r", '') | Should -BeExactly "[`$HOME]`n[`$(id)]`n"
    }

    It 'does not let an argument run a second command' {
        $dir = New-FileDir -Files @('x.txt')
        $r = Invoke-Wslbin -Name 'printf' -WorkingDirectory $dir -Arguments @('[%s]\n', 'x; touch pwned', '$(touch pwned2)', '`touch pwned3`', 'a && touch pwned4')
        $r.ExitCode | Should -Be 0
        (Get-ChildItem $dir).Name | Should -Be @('x.txt')
    }

    It 'passes the rest of a -c command line as $0, $1, ...' {
        (Invoke-Wslbin -Name 'wslbin' -Arguments @('-c', 'printf "[%s]" "$0" "$1"', 'a', 'b c')).Out | Should -BeExactly '[a][b c]'
    }

    It 'runs pipelines and && inside -c' {
        $dir = New-FileDir -Files @('a.log', 'b.log')
        (Invoke-Wslbin -Name 'wslbin' -WorkingDirectory $dir -Arguments @('-c', 'ls *.log | wc -l && echo done')).Out.Replace("`r", '') | Should -BeExactly "2`ndone`n"
    }

    It 'keeps an empty $0 and empty parameters of a -c string empty, and an argument with SOH inside as it is' {
        $r = Invoke-Wslbin -Name 'wslbin' -Arguments @('-c', 'printf "[%s][%s][%s][%s]" "$0" "$1" "$2" "$#"', '', '', 'y')
        $r.ExitCode | Should -Be 0 -Because $r.Err
        # the comparison is ordinal: PowerShell's own would take U+0001 for nothing at all
        [string]::Equals($r.Out, '[][][y][2]', [StringComparison]::Ordinal) | Should -BeTrue -Because "got: $(($r.Out.ToCharArray() | ForEach-Object { [int]$_ }) -join ' ')"
        $soh = [string][char]1
        $inside = Invoke-Wslbin -Name 'wslbin' -Arguments @('-c', 'printf "[%s][%s]" "$1" "$2"', 'x', "a${soh}b", '')
        [string]::Equals($inside.Out, "[a${soh}b][]", [StringComparison]::Ordinal) | Should -BeTrue -Because "got: $(($inside.Out.ToCharArray() | ForEach-Object { [int]$_ }) -join ' ')"
    }

    # Random strings of the characters that hurt, fixed seed (New-HostileArguments in helpers.ps1 says
    # what is left out and why). The same check runs in CI through Git Bash ("escaping, checked by bash").
    It 'delivers 3000 random hostile arguments as typed, in every mode' {
        $rng = [System.Random]::new(20261021)
        $modes = @(
            @{ Name = 'smart'; Flags = @() }
            @{ Name = 'raw'; Flags = @('--wslbin-raw') }
            @{ Name = 'sh'; Flags = @('--wslbin-sh') }
        )
        $dir = New-FileDir -Files @()
        $checked = 0
        foreach ($mode in $modes) {
            for ($round = 0; $round -lt 10; $round++) {
                $sent = @(New-HostileArguments -Random $rng -Count 100 -Mode $mode.Name)
                $r = Invoke-Wslbin -Name 'printf' -WorkingDirectory $dir -Arguments (@($mode.Flags) + '%s\0' + $sent)
                $r.ExitCode | Should -Be 0 -Because "$($mode.Name) round $round`: $($r.Err)"
                $got = @($r.Out -split "`0")
                if ($got[-1] -eq '') { $got = $got[0..($got.Count - 2)] }
                $got.Count | Should -Be $sent.Count -Because "$($mode.Name) round $round"
                for ($i = 0; $i -lt $sent.Count; $i++) {
                    if (-not [string]::Equals($got[$i], $sent[$i], [StringComparison]::Ordinal)) { throw "$($mode.Name): sent <$($sent[$i] -replace "`n",'\n')> but the utility got <$($got[$i] -replace "`n",'\n')>" }
                }
                $checked += $sent.Count
            }
        }
        $checked | Should -Be 3000
    }
}
