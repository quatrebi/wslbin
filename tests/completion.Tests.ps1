#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
  Tests of Tab completion: wslbin --complete, wslbin --init pwsh and --init clink.
  Run: Invoke-Pester ./tests

  The static parts (wslbin's own options, flags, generated code) need no WSL. Tests tagged WSL ask
  bash-completion in a real distribution, and the PowerShell ones go through the same engine that
  the Tab key uses (CommandCompletion.CompleteInput), in PowerShell 7 and in Windows PowerShell 5.1.
#>

BeforeDiscovery {
    $NoWsl = $true
    try {
        $null = & wsl.exe -l -q 2>$null
        if ($LASTEXITCODE -eq 0) { $NoWsl = $false }
    } catch { }
    $Shells = @(@{ Shell = 'pwsh'; Exe = 'pwsh' })
    $winPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path $winPs) { $Shells += @{ Shell = 'Windows PowerShell 5.1'; Exe = $winPs } }
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers.ps1')
    Initialize-WslbinTest
    $script:Ru = -join ([char[]](0x0444, 0x0430, 0x0439, 0x043B))

    # A folder with wslbin.exe and some wrappers; PATH is isolated so that a cat.exe or ls.exe
    # somewhere on this machine cannot stop a wrapper from being created.
    function New-WrapperHome {
        param([string[]]$Names = @('rsync', 'make', 'man', 'ls'))
        $h = New-WslbinHome
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $h -Env @{ PATH = (Get-IsolatedPath $h) } -Arguments (@('--internal-link') + $Names)
        if ($r.ExitCode -ne 0) { throw "could not create wrappers in $h" }
        $h
    }

    # wslbin --complete <cword> <words...>, as a list of candidates.
    function Get-Candidates {
        param([string]$Dir, [int]$Cword, [string[]]$Words, [string]$WorkingDirectory, [string]$Ini)
        $splat = @{ Name = 'wslbin'; Dir = $Dir; Arguments = (@('--complete', "$Cword") + $Words) }
        if ($WorkingDirectory) { $splat.WorkingDirectory = $WorkingDirectory }
        if ($PSBoundParameters.ContainsKey('Ini')) { $splat.Ini = $Ini }
        $r = Invoke-Wslbin @splat
        @($r.Out -split "`n" | Where-Object { $_ })
    }

    # Asks a PowerShell, after "wslbin --init pwsh | Invoke-Expression", what Tab would offer for each line.
    # Returns objects with Line and Items (the completion texts).
    function Invoke-PowerShellCompletion {
        param([string]$Exe, [string]$Dir, [string[]]$Lines, [string]$WorkingDirectory, [string[]]$AliasNames = @())
        $result = Join-Path $global:WslbinTest.Work ([guid]::NewGuid().ToString('N') + '.json')
        $linesFile = Join-Path $global:WslbinTest.Work ([guid]::NewGuid().ToString('N') + '.lines.json')
        [IO.File]::WriteAllText($linesFile, (ConvertTo-Json -InputObject @($Lines)), [Text.UTF8Encoding]::new($true))
        $script = @'
param($WslbinExe, $LinesFile, $ResultFile, $Aliases)
$code = & $WslbinExe --init pwsh
Invoke-Expression ($code -join "`n")
$lines = @(Get-Content -Raw -Encoding UTF8 $LinesFile | ConvertFrom-Json | ForEach-Object { $_ })
$out = @()
foreach ($line in $lines) {
    $r = [System.Management.Automation.CommandCompletion]::CompleteInput($line, $line.Length, $null)
    $out += [pscustomobject]@{ Line = $line; Items = @($r.CompletionMatches | ForEach-Object { $_.CompletionText }) }
}
$remaining = @(($Aliases -split ',') | Where-Object { $_ -and (Get-Alias $_ -ErrorAction SilentlyContinue) })
$payload = [pscustomobject]@{ Results = $out; AliasesLeft = $remaining }
[IO.File]::WriteAllText($ResultFile, (ConvertTo-Json -InputObject $payload -Depth 5), [Text.UTF8Encoding]::new($false))
'@
        $scriptFile = Join-Path $global:WslbinTest.Work ([guid]::NewGuid().ToString('N') + '.ps1')
        [IO.File]::WriteAllText($scriptFile, $script, [Text.UTF8Encoding]::new($true))

        $psi = [Diagnostics.ProcessStartInfo]::new($Exe)
        foreach ($a in '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptFile, (Join-Path $Dir 'wslbin.exe'), $linesFile, $result, ($AliasNames -join ',')) { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
        # Windows PowerShell started from PowerShell 7 with its module path cannot load its own modules
        $null = $psi.Environment.Remove('PSModulePath')
        $p = [Diagnostics.Process]::Start($psi)
        $e = $p.StandardError.ReadToEndAsync(); $o = $p.StandardOutput.ReadToEnd(); $p.WaitForExit()
        if (-not (Test-Path $result)) { throw "completion script failed ($($p.ExitCode)): $($e.Result) $o" }
        Get-Content -Raw -Encoding UTF8 $result | ConvertFrom-Json
    }

    # Folder on the Windows side that the WSL tests complete paths in.
    function New-CompletionFolder {
        $dir = New-FileDir -Files @('alpine.txt', "$script:Ru.txt", 'Makefile')
        New-Item -ItemType Directory -Path (Join-Path $dir 'alpha one') | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $dir 'alpha two') | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir 'alpha one\inner file.txt'), "x`n")
        [IO.File]::WriteAllText((Join-Path $dir 'Makefile'), "build:`n`t@echo b`ntest-all:`n`t@echo t`nclean:`n`t@echo c`n")
        $dir
    }
}

AfterAll {
    Remove-WslbinTest
}

Describe 'wslbin --complete: wslbin itself (no WSL)' {
    BeforeAll { $script:H = New-WrapperHome }

    It "offers '<Want>' for 'wslbin <Typed>'" -ForEach @(
        @{ Typed = '--li'; Want = @('--link', '--list') }
        @{ Typed = '--un'; Want = @('--unlink') }
        @{ Typed = '--ex'; Want = @('--explain') }
        @{ Typed = '--h'; Want = @('--help') }
        @{ Typed = '--ini'; Want = @('--init') }
        @{ Typed = '-c'; Want = @('-c') }
    ) {
        Get-Candidates -Dir $script:H -Cword 1 -Words @('wslbin', $Typed) | Should -Be $Want
    }

    It 'does not offer the internal commands' {
        $all = Get-Candidates -Dir $script:H -Cword 1 -Words @('wslbin', '--')
        $all | Should -Not -Contain '--complete'
        $all | Should -Not -Contain '--internal-link'
        $all | Should -Contain '--doctor'
    }

    It 'offers the shells after --init' {
        Get-Candidates -Dir $script:H -Cword 2 -Words @('wslbin', '--init', '') | Should -Be @('pwsh', 'clink')
        Get-Candidates -Dir $script:H -Cword 2 -Words @('wslbin', '--init', 'p') | Should -Be @('pwsh')
    }

    It 'offers the wrappers, and --all, after --unlink' {
        Get-Candidates -Dir $script:H -Cword 2 -Words @('wslbin', '--unlink', '') | Should -Be @('--all', 'ls', 'make', 'man', 'rsync')
        Get-Candidates -Dir $script:H -Cword 2 -Words @('wslbin', '--unlink', 'ma') | Should -Be @('make', 'man')
    }

    It 'offers the help topics' {
        Get-Candidates -Dir $script:H -Cword 2 -Words @('wslbin', '--help', 'mo') | Should -Be @('modes')
        (Get-Candidates -Dir $script:H -Cword 2 -Words @('wslbin', '--help', '')).Count | Should -BeGreaterThan 5
    }

    It 'offers the options of --link and --list' {
        Get-Candidates -Dir $script:H -Cword 2 -Words @('wslbin', '--link', '--d') | Should -Be @('--dry-run')
        Get-Candidates -Dir $script:H -Cword 2 -Words @('wslbin', '--list', '') | Should -Be @('--names')
    }

    It 'offers the wslbin flags of a wrapper, without the ones already given' {
        Get-Candidates -Dir $script:H -Cword 1 -Words @('rsync', '--wslbin-') | Should -Be @('--wslbin-raw', '--wslbin-sh', '--wslbin-explain')
        Get-Candidates -Dir $script:H -Cword 2 -Words @('rsync', '--wslbin-raw', '--wslbin-') | Should -Be @('--wslbin-sh', '--wslbin-explain')
        Get-Candidates -Dir $script:H -Cword 1 -Words @('rsync', '--wslbin-e') | Should -Be @('--wslbin-explain')
    }

    It 'asks for nothing after wslbin -c' {
        Get-Candidates -Dir $script:H -Cword 2 -Words @('wslbin', '-c', 'ls') | Should -BeNullOrEmpty
    }

    It 'rejects an index that is not a number, and nothing else' {
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--complete', 'x', 'rsync')
        $r.ExitCode | Should -Be 125
        (Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--complete')).ExitCode | Should -Be 125
    }

    It 'prints nothing, and no error, for the command word itself' {
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--complete', '0', 'wslbin')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -BeNullOrEmpty
        $r.Err | Should -BeNullOrEmpty
    }

    It 'refuses a word number that makes no sense, without a stack trace and without running out of memory' {
        foreach ($n in '2147483647', '100000', '-1') {
            $r = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--complete', $n, 'ls', 'a')
            $r.ExitCode | Should -Be 125
            $r.Err | Should -Match 'number of the word'
            $r.Err | Should -Not -Match 'Exception'
        }
    }

    It 'is silent when WSL cannot be used' {
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Ini 'distro = NoSuchDistro-wslbin-test' -Arguments @('--complete', '1', 'rsync', '--arch')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -BeNullOrEmpty
        $r.Err | Should -BeNullOrEmpty
    }
}

Describe 'wslbin --init pwsh: the generated code' {
    BeforeAll { $script:H = New-WrapperHome }

    It 'is valid PowerShell, with every value filled in' {
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--init', 'pwsh')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Not -Match '@(EXE|NAMES|FALLBACK)@'
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($r.Out, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It 'names the wrappers and the program' {
        $out = (Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--init', 'pwsh')).Out
        $out | Should -Match "@\('ls', 'make', 'man', 'rsync'\)"
        $out | Should -Match ([regex]::Escape((Join-Path $script:H 'wslbin.exe')))
    }

    It 'leaves out a wrapper file whose name could not be a wrapper name: a quote in it would break the code' {
        $h = New-WslbinHome
        $null = Invoke-Wslbin -Name 'wslbin' -Dir $h -Arguments @('--internal-link', 'good')
        Copy-Item (Join-Path $h 'good.exe') (Join-Path $h "it's.exe")
        Copy-Item (Join-Path $h 'good.exe') (Join-Path $h "a';calc;'.exe")
        $out = (Invoke-Wslbin -Name 'wslbin' -Dir $h -Arguments @('--init', 'pwsh')).Out
        $out | Should -Match "@\('good'\)"
        $out | Should -Not -Match 'calc'
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($out, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It 'registers the native fallback only when asked' {
        $plain = (Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--init', 'pwsh')).Out
        $plain | Should -Match '\$useFallback = \$false'
        $with = (Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--init', 'pwsh', '--native-fallback')).Out
        $with | Should -Match '\$useFallback = \$true'
    }

    It 'is valid in Windows PowerShell 5.1 too' -Skip:(-not (Test-Path "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe")) {
        $code = (Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--init', 'pwsh')).Out
        $file = Join-Path $global:WslbinTest.Work 'init-check.ps1'
        [IO.File]::WriteAllText($file, $code, [Text.UTF8Encoding]::new($true))
        $answer = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command "`$e = `$null; [void][System.Management.Automation.Language.Parser]::ParseFile('$file', [ref]`$null, [ref]`$e); `$e.Count"
        $answer | Should -Be '0'
    }

    It 'writes a path with non-ASCII characters so that any code page reads it back' {
        $dir = Join-Path $global:WslbinTest.Work "dir-$script:Ru"
        New-Item -ItemType Directory -Path $dir | Out-Null
        Copy-Item $global:WslbinTest.Exe (Join-Path $dir 'wslbin.exe')
        $out = (Invoke-Wslbin -Name 'wslbin' -Dir $dir -Arguments @('--init', 'pwsh')).Out
        $out | Should -Match '\[char\]\d+'
        $line = ($out -split "`n" | Where-Object { $_ -match '^\s*\$exe = ' } | Select-Object -First 1)
        $expression = $line -replace '^\s*\$exe = ', ''
        (Invoke-Expression $expression) | Should -BeExactly (Join-Path $dir 'wslbin.exe')
    }

    It 'rejects unknown shells and options' {
        (Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--init', 'zsh')).ExitCode | Should -Be 125
        (Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--init')).ExitCode | Should -Be 125
        (Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--init', 'pwsh', '--bogus')).ExitCode | Should -Be 125
    }

    It 'doubles a quote in the program path' {
        $dir = Join-Path $global:WslbinTest.Work "it's home"
        New-Item -ItemType Directory -Path $dir | Out-Null
        Copy-Item $global:WslbinTest.Exe (Join-Path $dir 'wslbin.exe')
        $out = (Invoke-Wslbin -Name 'wslbin' -Dir $dir -Arguments @('--init', 'pwsh')).Out
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($out, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        $line = ($out -split "`n" | Where-Object { $_ -match '^\s*\$exe = ' } | Select-Object -First 1)
        (Invoke-Expression ($line -replace '^\s*\$exe = ', '')) | Should -BeExactly (Join-Path $dir 'wslbin.exe')
    }
}

Describe 'wslbin --init clink' {
    BeforeAll { $script:H = New-WrapperHome }

    It 'writes wslbin.lua into the folder it is told to, with the program path filled in' {
        $target = Join-Path $global:WslbinTest.Work ('clink-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $target | Out-Null
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--init', 'clink', '--dir', $target)
        $r.ExitCode | Should -Be 0
        $lua = Get-Content -Raw (Join-Path $target 'wslbin.lua')
        $lua | Should -Not -Match '@EXE@'
        $lua | Should -Match ([regex]::Escape(((Join-Path $script:H 'wslbin.exe') -replace '\\', '\\')))
        $lua | Should -Match 'clink\.generator'
    }

    It 'refuses a folder that does not exist' {
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--init', 'clink', '--dir', (Join-Path $global:WslbinTest.Work 'no-such-folder'))
        $r.ExitCode | Should -Be 125
        $r.Err | Should -Match 'does not exist'
    }

    It 'says that --dir needs a folder' {
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--init', 'clink', '--dir')
        $r.ExitCode | Should -Be 125
        $r.Err | Should -Match '--dir needs a folder'
    }

    It 'asks "clink info" for the folder through the cmd.exe of Windows, never one in the current folder' {
        $root = Join-Path $global:WslbinTest.Work ('clink-' + [guid]::NewGuid().ToString('N'))
        $cwd = Join-Path $root 'cwd'
        $bin = Join-Path $root 'bin'
        $target = Join-Path $root 'state'
        New-Item -ItemType Directory -Path $cwd, $bin, $target | Out-Null
        # a cmd.exe planted in the folder the user is in: it only leaves a mark that it ran
        $source = Join-Path $root 'planted.cs'
        Set-Content -LiteralPath $source -Value 'class P { static void Main() { System.IO.File.WriteAllText(System.IO.Path.Combine(System.AppDomain.CurrentDomain.BaseDirectory, "ran.txt"), ""); } }'
        $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
        & $csc /nologo "/out:$(Join-Path $cwd 'cmd.exe')" $source | Out-Null
        Set-Content -LiteralPath (Join-Path $bin 'clink.cmd') -Value "@echo state : $target"
        $vars = @{ PATH = "$bin;$env:SystemRoot\System32"; PATHEXT = '.COM;.EXE;.BAT;.CMD'; LOCALAPPDATA = (Join-Path $root 'no-local-app-data') }
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--init', 'clink') -WorkingDirectory $cwd -Env $vars
        Test-Path (Join-Path $cwd 'ran.txt') | Should -BeFalse -Because 'the cmd.exe in the current folder must not run'
        $r.ExitCode | Should -Be 0 -Because $r.Err
        Test-Path (Join-Path $target 'wslbin.lua') | Should -BeTrue
    }

    It 'leaves a wslbin.lua alone that it did not write, and replaces its own' {
        $target = Join-Path $global:WslbinTest.Work ('clink-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $target | Out-Null
        $file = Join-Path $target 'wslbin.lua'
        [IO.File]::WriteAllText($file, "-- someone else's script`n")
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--init', 'clink', '--dir', $target)
        $r.ExitCode | Should -Be 125
        $r.Err | Should -Match 'was not written by wslbin'
        Get-Content -Raw $file | Should -BeExactly "-- someone else's script`n"

        Remove-Item $file
        (Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--init', 'clink', '--dir', $target)).ExitCode | Should -Be 0
        (Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Arguments @('--init', 'clink', '--dir', $target)).ExitCode | Should -Be 0
    }
}

Describe 'wslbin --complete with real WSL' -Tag 'WSL' -Skip:$NoWsl {
    BeforeAll {
        $script:H = New-WrapperHome
        $script:Dir = New-CompletionFolder
    }

    It 'completes the options of a utility from bash-completion' {
        Get-Candidates -Dir $script:H -Cword 1 -Words @('rsync', '--arch') | Should -Be @('--archive')
    }

    It 'completes subcommands the way bash does' {
        Get-Candidates -Dir $script:H -Cword 1 -Words @('wslbin', 'rsy') | Should -Contain 'rsync'
    }

    It 'completes make targets from the Makefile in the current folder' {
        $all = Get-Candidates -Dir $script:H -Cword 1 -Words @('make', '') -WorkingDirectory $script:Dir
        $all | Should -Contain 'build'
        $all | Should -Contain 'test-all'
        $all | Should -Contain 'clean'
        Get-Candidates -Dir $script:H -Cword 1 -Words @('make', 'te') -WorkingDirectory $script:Dir | Should -Be @('test-all')
    }

    It 'takes Windows paths in and gives Windows paths out' {
        $got = Get-Candidates -Dir $script:H -Cword 2 -Words @('ls', '-l', "$script:Dir\al")
        $got | Should -Be @("$script:Dir\alpha one\", "$script:Dir\alpha two\", "$script:Dir\alpine.txt")
    }

    It 'writes the drive letter and the slashes the way they were typed' {
        $slashes = $script:Dir -replace '\\', '/'
        $lower = $slashes.Substring(0, 1).ToLowerInvariant() + $slashes.Substring(1)
        Get-Candidates -Dir $script:H -Cword 1 -Words @('ls', "$lower/alph") | Should -Be @("$lower/alpha one/", "$lower/alpha two/")
    }

    It 'completes inside a folder whose name has a space' {
        Get-Candidates -Dir $script:H -Cword 1 -Words @('ls', "$script:Dir\alpha one\") | Should -Be @("$script:Dir\alpha one\inner file.txt")
    }

    It 'completes a path given to an option as --option=path' {
        Get-Candidates -Dir $script:H -Cword 1 -Words @('rsync', "--exclude-from=$script:Dir\alph") |
            Should -Be @("--exclude-from=$script:Dir\alpha one\", "--exclude-from=$script:Dir\alpha two\")
    }

    It 'completes relative paths written with backslashes' {
        Get-Candidates -Dir $script:H -Cword 1 -Words @('ls', '.\al') -WorkingDirectory $script:Dir | Should -Be @('.\alpha one\', '.\alpha two\', '.\alpine.txt')
        Get-Candidates -Dir $script:H -Cword 1 -Words @('ls', '.\alpha one\') -WorkingDirectory $script:Dir | Should -Be @('.\alpha one\inner file.txt')
    }

    It 'completes non-ASCII file names' {
        Get-Candidates -Dir $script:H -Cword 1 -Words @('ls', "$script:Dir\$script:Ru") | Should -Be @("$script:Dir\$script:Ru.txt")
    }

    It 'sees Windows paths given earlier on the line' {
        Get-Candidates -Dir $script:H -Cword 3 -Words @('make', '-C', $script:Dir, 'cl') | Should -Be @('clean')
    }

    It 'leaves paths alone in raw mode' {
        Get-Candidates -Dir $script:H -Cword 2 -Words @('ls', '--wslbin-raw', "$script:Dir\al") | Should -BeNullOrEmpty
        $slashes = (& wsl.exe --exec wslpath -a $script:Dir).Trim()
        Get-Candidates -Dir $script:H -Cword 2 -Words @('ls', '--wslbin-raw', "$slashes/al") | Should -Be @("$slashes/alpha one/", "$slashes/alpha two/", "$slashes/alpine.txt")
    }

    It 'treats a wrapper that the configuration makes raw as raw' {
        Get-Candidates -Dir $script:H -Cword 1 -Words @('ls', "$script:Dir\al") -Ini "raw = ls`n" | Should -BeNullOrEmpty
        # the configuration belongs to the folder: put it back
        $null = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Ini '' -Arguments @('--version')
    }

    It 'completes the options of commands that bash-completion registers itself (ls, grep, cat, sort)' {
        Get-Candidates -Dir $script:H -Cword 1 -Words @('ls', '--col') | Should -Contain '--color'
        Get-Candidates -Dir $script:H -Cword 1 -Words @('grep', '--inc') | Should -Contain '--include='
        Get-Candidates -Dir $script:H -Cword 1 -Words @('cat', '--nu') | Should -Contain '--number'
        Get-Candidates -Dir $script:H -Cword 1 -Words @('sort', '--ke') | Should -Contain '--key='
    }

    It 'puts a slash after a directory that is written with a leading ~' {
        $name = "wslbin-tilde-test-$([guid]::NewGuid().ToString('N'))"
        & wsl.exe --exec bash --noprofile --norc -c "mkdir -p `"`$HOME/$name`""
        try {
            Get-Candidates -Dir $script:H -Cword 1 -Words @('ls', '~/wslbin-tilde-test') | Should -Contain "~/$name/"
        }
        finally {
            & wsl.exe --exec bash --noprofile --norc -c "find `"`$HOME`" -maxdepth 1 -name '$name' -delete"
        }
    }

    It 'gives bash the name of a command as typed: RSYNC is not rsync' {
        Get-Candidates -Dir $script:H -Cword 2 -Words @('wslbin', 'RSYNC', '--arch') | Should -BeNullOrEmpty
        Get-Candidates -Dir $script:H -Cword 2 -Words @('wslbin', 'rsync', '--arch') | Should -Be @('--archive')
    }

    It 'does not run what a hostile word says (command substitution, backticks, ;, &&)' {
        $canary = "/tmp/wslbin-injection-canary-$([guid]::NewGuid().ToString('N'))"
        $words = @(
            "`$(touch $canary-1)", "``touch $canary-2``", "x;touch $canary-3", "x&&touch $canary-4", "~`$(touch $canary-5)",
            "~/`$(touch $canary-6)", "`${x:-`$(touch $canary-7)}", "x'`$(touch $canary-8)'", "--exclude-from=`$(touch $canary-9)",
            "a:`$(touch $canary-10)", "a=`$(touch $canary-11)", "*`$(touch $canary-12)*"
        )
        foreach ($command in 'rsync', 'ls', 'make', 'wslbin') {
            foreach ($word in $words) {
                $null = Get-Candidates -Dir $script:H -Cword 1 -Words @($command, $word)
                $null = Get-Candidates -Dir $script:H -Cword 2 -Words @($command, 'x', $word)
            }
        }
        ((& wsl.exe --exec bash --noprofile --norc -c "ls /tmp | grep -c 'wslbin-injection-canary-$($canary.Substring($canary.Length - 32))' || true") -join '').Trim() | Should -BeExactly '0'
    }

    It 'finds tools in the directories of the path key' {
        & wsl.exe --exec bash --noprofile --norc -c 'mkdir -p "$HOME/wslbin-test-bin" && printf "#!/bin/sh\n" > "$HOME/wslbin-test-bin/wslbintest-comp" && chmod +x "$HOME/wslbin-test-bin/wslbintest-comp"'
        try {
            Get-Candidates -Dir $script:H -Cword 1 -Words @('wslbin', 'wslbintest-c') | Should -BeNullOrEmpty
            Get-Candidates -Dir $script:H -Cword 1 -Words @('wslbin', 'wslbintest-c') -Ini 'path = ~/wslbin-test-bin' | Should -Be @('wslbintest-comp')
        }
        finally {
            & wsl.exe --exec bash --noprofile --norc -c 'rm -rf "$HOME/wslbin-test-bin"'
            $null = Invoke-Wslbin -Name 'wslbin' -Dir $script:H -Ini '' -Arguments @('--version')
        }
    }
}

Describe 'Tab completion in <Shell>' -Tag 'WSL' -Skip:$NoWsl -ForEach $Shells {
    BeforeAll {
        $script:H = New-WrapperHome
        $script:Dir = New-CompletionFolder
        $script:Lines = @(
            'rsync --arch'
            'rsync.exe --arch'
            "ls $script:Dir\alph"
            "ls '$script:Dir\alpha o"
            "ls `"$script:Dir\alpha o"
            "ls `"$script:Dir\alpha one\"
            "ls $script:Dir\$script:Ru"
            'ls .\alph'
            'wslbin --li'
            'notawrapper --arch'
        )
        # File names that are code to PowerShell when they are not quoted right: ’ is a single quote to it too.
        $script:Hostile = New-FileDir -Files @()
        $script:HostileNames = @(
            ('x' + [char]0x2019 + ';calc;' + [char]0x2019 + '.txt'),
            'y&calc.txt',
            'z$(calc).txt',
            'w`(calc).txt'
        )
        foreach ($n in $script:HostileNames) { [IO.File]::WriteAllText((Join-Path $script:Hostile $n), "x`n") }
        $script:Lines += @($script:HostileNames | ForEach-Object { "ls $script:Hostile\$($_.Substring(0, 1))" })
        # a folder that needs quotes but has no blank: Windows PowerShell passes it without quotes
        New-Item -ItemType Directory -Path (Join-Path $script:Hostile 'paren(1)') | Out-Null
        $script:Lines += "ls $script:Hostile\par"

        $script:Answer = Invoke-PowerShellCompletion -Exe $Exe -Dir $script:H -Lines $script:Lines -WorkingDirectory $script:Dir -AliasNames @('man', 'ls', 'rsync')
        function Items([string]$line) { @(($script:Answer.Results | Where-Object { $_.Line -eq $line }).Items) }
        # Before PowerShell 7.3 a quoted argument that ends in a backslash loses its closing quote on the
        # way to the program, unless the backslash is doubled; the completer does that there.
        $script:Tail = $(if ($Shell -like 'Windows PowerShell*') { '\\' } else { '\' })
    }

    It 'quotes a hostile file name so that PowerShell reads the line as one command with one argument: <_>' -ForEach @(0, 1, 2, 3) {
        $name = $script:HostileNames[$_]
        $items = @(Items "ls $script:Hostile\$($name.Substring(0, 1))")
        $items.Count | Should -Be 1
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput("ls $($items[0])", [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        $ast.EndBlock.Statements.Count | Should -Be 1
        $elements = $ast.EndBlock.Statements[0].PipelineElements
        $elements.Count | Should -Be 1
        $elements[0].CommandElements.Count | Should -Be 2
        $elements[0].CommandElements[1].GetType().Name | Should -Be 'StringConstantExpressionAst'
        [string]::Equals($elements[0].CommandElements[1].Value, "$script:Hostile\$name", [StringComparison]::Ordinal) | Should -BeTrue -Because $items[0]
    }

    It 'removes the PowerShell aliases that would hide a wrapper' {
        @($script:Answer.AliasesLeft) | Should -BeNullOrEmpty
    }

    It 'completes options, with and without .exe' {
        Items 'rsync --arch' | Should -Be @('--archive')
        Items 'rsync.exe --arch' | Should -Be @('--archive')
    }

    It 'completes Windows paths, quoting the ones with spaces and keeping the trailing backslash' {
        Items "ls $script:Dir\alph" | Should -Be @("'$script:Dir\alpha one$script:Tail'", "'$script:Dir\alpha two$script:Tail'")
    }

    It 'understands a word that is already in quotes' {
        Items "ls '$script:Dir\alpha o" | Should -Be @("'$script:Dir\alpha one$script:Tail'")
        Items "ls `"$script:Dir\alpha o" | Should -Be @("'$script:Dir\alpha one$script:Tail'")
    }

    It 'does not double the backslash of a quoted folder that has no blank, which reaches the program without quotes' {
        Items "ls $script:Hostile\par" | Should -Be @("'$script:Hostile\paren(1)\'")
    }

    It 'completes inside a quoted folder with a trailing backslash' {
        Items "ls `"$script:Dir\alpha one\" | Should -Be @("'$script:Dir\alpha one\inner file.txt'")
    }

    It 'completes non-ASCII names' {
        Items "ls $script:Dir\$script:Ru" | Should -Be @("$script:Dir\$script:Ru.txt")
    }

    It 'completes relative paths from the current folder of the shell' {
        Items 'ls .\alph' | Should -Be @("'.\alpha one$script:Tail'", "'.\alpha two$script:Tail'")
    }

    It 'completes wslbin itself' {
        Items 'wslbin --li' | Should -Be @('--link', '--list')
    }

    It 'leaves other commands to PowerShell' {
        @(Items 'notawrapper --arch').Count | Should -Be 0
    }
}
