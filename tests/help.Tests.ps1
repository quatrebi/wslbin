#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
  Tests of wslbin --help, --ai-context and --install-ai-context, and of the texts in docs/.
  Run: Invoke-Pester ./tests    (none of it needs WSL)

  --install-ai-context writes into the instructions of AI agents. Every test points it at a temporary
  folder (--claude-dir, --codex-dir, or the variables CLAUDE_CONFIG_DIR, CODEX_HOME and USERPROFILE of
  the child), never at the real ones.
#>

BeforeDiscovery {
    $repo = Split-Path -Parent $PSScriptRoot
    $Topics = @('modes', 'paths', 'globs', 'env', 'completion', 'config', 'troubleshooting')
    $Languages = @('en', 'ru')
    $TopicCases = foreach ($lang in $Languages) { foreach ($topic in $Topics) { @{ Lang = $lang; Topic = $topic } } }
    $DocFiles = foreach ($lang in $Languages) {
        Get-ChildItem -Path (Join-Path $repo "docs\$lang") -File | ForEach-Object { @{ Lang = $lang; File = $_.Name } }
    }
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'helpers.ps1')
    Initialize-WslbinTest
    $script:Repo = Split-Path -Parent $PSScriptRoot
    $script:Home1 = New-WslbinHome
    $script:Cyrillic = -join ([char[]](0x0418, 0x0441, 0x043F, 0x043E, 0x043B, 0x044C, 0x0437, 0x043E, 0x0432, 0x0430, 0x043D, 0x0438, 0x0435))   # "Использование"
    # Every option of wslbin, its commands and their own options alike. A list of its own on purpose,
    # not taken from the program: a text that names an option the program has lost must fail.
    $script:KnownOptions = @('--help', '--version', '--link', '--unlink', '--list', '--doctor', '--init', '--ai-context',
                             '--install-ai-context', '--raw', '--sh', '--explain', '--all', '--dry-run', '--names', '--native-fallback',
                             '--dir', '--remove', '--claude', '--codex', '--claude-dir', '--codex-dir', '--yes', '--complete')

    function Read-Doc([string]$lang, [string]$file) {
        ([IO.File]::ReadAllText((Join-Path $script:Repo "docs\$lang\$file"), [Text.UTF8Encoding]::new($false))).Replace("`r`n", "`n")
    }
    function Invoke-Help([string[]]$Arguments, [string]$Lang) {
        $splat = @{ Name = 'wslbin'; Dir = $script:Home1; Arguments = $Arguments; Ini = "lang = $Lang`n" }
        Invoke-Wslbin @splat
    }
    # a folder in the shape of the home folder of a user: where the agents keep their instructions
    function New-AgentHome {
        $h = Join-Path $global:WslbinTest.Work ('agents-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $h | Out-Null
        $h
    }
}

AfterAll {
    Remove-WslbinTest
}

Describe 'wslbin --help' {
    It 'prints the overview in <Lang>' -ForEach @(@{ Lang = 'en' }, @{ Lang = 'ru' }) {
        $r = Invoke-Help -Arguments @('--help') -Lang $Lang
        $r.ExitCode | Should -Be 0
        $r.Out.Replace("`r", '') | Should -BeExactly ((Read-Doc $Lang 'help.txt').TrimEnd("`n") + "`n")
    }

    It 'is the same with -h and with no argument after --help' {
        $a = (Invoke-Help -Arguments @('-h') -Lang 'en').Out
        $b = (Invoke-Help -Arguments @('--help') -Lang 'en').Out
        $a | Should -BeExactly $b
    }

    It 'prints <Topic> in <Lang>' -ForEach $TopicCases {
        $r = Invoke-Help -Arguments @('--help', $Topic) -Lang $Lang
        $r.ExitCode | Should -Be 0
        $r.Out.Replace("`r", '') | Should -BeExactly ((Read-Doc $Lang "$Topic.txt").TrimEnd("`n") + "`n")
    }

    It 'knows the topic in any case' {
        (Invoke-Help -Arguments @('--help', 'PATHS') -Lang 'en').Out | Should -Match 'Paths: Windows to Linux'
    }

    It 'answers in Russian when wslbin.ini says lang = ru' {
        (Invoke-Help -Arguments @('--help') -Lang 'ru').Out | Should -Match $script:Cyrillic
        (Invoke-Help -Arguments @('--help') -Lang 'en').Out | Should -Not -Match $script:Cyrillic
    }

    It 'answers in the language of Windows with lang = auto' {
        # (on an English Windows this tells nothing from "always English"; on a Russian one it does)
        $want = if ([Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'ru') { 'ru' } else { 'en' }
        $r = Invoke-Help -Arguments @('--help') -Lang 'auto'
        $r.Out.Replace("`r", '') | Should -BeExactly ((Read-Doc $want 'help.txt').TrimEnd("`n") + "`n")
    }

    It 'warns about a language it does not have and uses the language of Windows' {
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $script:Home1 -Ini "lang = klingon`n" -Arguments @('--help')
        $r.Err | Should -Match 'lang must be en, ru or auto'
        $r.ExitCode | Should -Be 0
    }

    It 'refuses an unknown topic and names the ones there are' {
        $r = Invoke-Help -Arguments @('--help', 'nosuch') -Lang 'en'
        $r.ExitCode | Should -Be 125
        $r.Err | Should -Match 'modes, paths, globs, env, completion, config, troubleshooting'
        (Invoke-Help -Arguments @('--help', 'modes', 'paths') -Lang 'en').ExitCode | Should -Be 125
    }

    It 'shows the overview on standard error and fails when started without arguments' {
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $script:Home1 -Ini "lang = en`n"
        $r.ExitCode | Should -Be 125
        $r.Err | Should -Match 'Usage'
        $r.Out | Should -BeNullOrEmpty
    }
}

Describe 'the texts in docs/' {
    It 'has the same files in both languages' {
        $en = (Get-ChildItem (Join-Path $script:Repo 'docs\en') -File).Name | Sort-Object
        $ru = (Get-ChildItem (Join-Path $script:Repo 'docs\ru') -File).Name | Sort-Object
        $ru | Should -Be $en
    }

    It 'has a file for every topic, and no topic without a file' {
        $files = (Get-ChildItem (Join-Path $script:Repo 'docs\en') -File -Filter *.txt).BaseName | Where-Object { $_ -ne 'help' } | Sort-Object
        $files | Should -Be (@('modes', 'paths', 'globs', 'env', 'completion', 'config', 'troubleshooting') | Sort-Object)
    }

    It '<File> (<Lang>) is UTF-8 without a byte order mark, with Unix line ends' -ForEach $DocFiles {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $script:Repo "docs\$Lang\$File"))
        ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
        $bytes -contains 13 | Should -BeFalse
        { [Text.UTF8Encoding]::new($false, $true).GetString($bytes) } | Should -Not -Throw
    }

    It '<File> (<Lang>) does not mention a wslbin option that does not exist' {
        $text = Read-Doc $Lang $File
        $used = [regex]::Matches($text, 'wslbin (--[a-z][a-z-]*)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        $used | Where-Object { $_ -notin $script:KnownOptions } | Should -BeNullOrEmpty
        $flags = [regex]::Matches($text, '--wslbin-[a-z]+') | ForEach-Object { $_.Value } | Sort-Object -Unique
        $flags | Where-Object { $_ -notin @('--wslbin-raw', '--wslbin-sh', '--wslbin-explain') } | Should -BeNullOrEmpty
    } -ForEach $DocFiles

    It 'names every wslbin.ini key in the config text (<Lang>)' -ForEach @(@{ Lang = 'en' }, @{ Lang = 'ru' }) {
        $text = Read-Doc $Lang 'config.txt'
        foreach ($key in 'distro', 'lang', 'raw', 'sh', 'pass_env', 'path', 'args.') { $text | Should -Match "(?m)^\s+$([regex]::Escape($key))" }
    }

    It 'lists in the overview every command that wslbin has (<Lang>)' -ForEach @(@{ Lang = 'en' }, @{ Lang = 'ru' }) {
        $text = Read-Doc $Lang 'help.txt'
        foreach ($c in '--link', '--unlink', '--list', '--doctor', '--init', '--ai-context', '--install-ai-context', '--help', '--version') { $text | Should -Match ([regex]::Escape($c)) }
    }

    It 'keeps llms.txt in step with the text for agents' {
        $llms = ([IO.File]::ReadAllText((Join-Path $script:Repo 'llms.txt'), [Text.UTF8Encoding]::new($false))).Replace("`r`n", "`n")
        $llms | Should -Match ([regex]::Escape((Read-Doc 'en' 'ai-context.md').TrimEnd("`n")))
    }
}

Describe 'the READMEs' {
    BeforeAll {
        # The parameters of a script: of its param block, or (the loader, which is one script block,
        # & { param(...) ... } @args, so that iex leaves nothing behind) of the block it runs.
        function Get-ScriptParameters([string]$path) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
            $block = $ast.ParamBlock
            if (-not $block) {
                $inner = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }, $false)
                if ($inner) { $block = $inner.ScriptBlock.ParamBlock }
            }
            if ($block) { $block.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath } }
        }
        # the README names the loader of the site and the scripts of the package: any of their parameters will do
        $script:InstallParameters = @('site\install.ps1', 'setup\install.ps1', 'setup\uninstall.ps1' | ForEach-Object { Get-ScriptParameters (Join-Path $script:Repo $_) } | Sort-Object -Unique)
        $script:InstallParameters.Count | Should -BeGreaterThan 10
        function Read-Readme([string]$name) { [IO.File]::ReadAllText((Join-Path $script:Repo $name), [Text.UTF8Encoding]::new($false)).Replace("`r`n", "`n") }
        function Get-WslbinOptions([string]$text) {
            [regex]::Matches($text, 'wslbin (--[a-z][a-z-]*)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        }
        function Get-InstallParameters([string]$text) {
            # the parameters written after install.ps1 or uninstall.ps1 on a line; lines with Get-Help are Get-Help's
            $names = foreach ($m in [regex]::Matches($text, '(?m)^(?<line>[^\n]*install\.ps1[^\n`]*)')) {
                if ($m.Groups['line'].Value -match 'Get-Help') { continue }
                $after = $m.Groups['line'].Value.Substring($m.Groups['line'].Value.IndexOf('install.ps1'))
                [regex]::Matches($after, '(?<![\w-])-([A-Z][A-Za-z0-9]+)') | ForEach-Object { $_.Groups[1].Value }
            }
            $names | Sort-Object -Unique
        }
    }

    # The documents of the root: the READMEs, the installer's page (INSTALL, in both languages) and the
    # page for contributors (CONTRIBUTING, English only). They are not in docs/, which holds the help topics.
    It 'link to each other, and the READMEs lead to the installer page of their language' {
        (Read-Readme 'README.md') | Should -Match '\(README\.ru\.md\)'
        (Read-Readme 'README.ru.md') | Should -Match '\(README\.md\)'
        (Read-Readme 'INSTALL.md') | Should -Match '\(INSTALL\.ru\.md\)'
        (Read-Readme 'INSTALL.ru.md') | Should -Match '\(INSTALL\.md\)'
        (Read-Readme 'README.md') | Should -Match '\(INSTALL\.md[)#]'
        (Read-Readme 'README.ru.md') | Should -Match '\(INSTALL\.ru\.md[)#]'
    }

    It '<File> mentions only wslbin options that exist' -ForEach @(@{ File = 'README.md' }, @{ File = 'README.ru.md' }, @{ File = 'INSTALL.md' }, @{ File = 'INSTALL.ru.md' }, @{ File = 'CONTRIBUTING.md' }) {
        Get-WslbinOptions (Read-Readme $File) | Where-Object { $_ -notin $script:KnownOptions } | Should -BeNullOrEmpty
    }

    It '<File> uses only install.ps1 parameters that exist' -ForEach @(@{ File = 'README.md' }, @{ File = 'README.ru.md' }, @{ File = 'INSTALL.md' }, @{ File = 'INSTALL.ru.md' }) {
        $used = Get-InstallParameters (Read-Readme $File)
        @($used).Count | Should -BeGreaterThan 3
        $used | Where-Object { $_ -notin $script:InstallParameters } | Should -BeNullOrEmpty
    }

    It 'name the same options and the same install parameters in both languages (<En> and <Ru>)' -ForEach @(@{ En = 'README.md'; Ru = 'README.ru.md' }, @{ En = 'INSTALL.md'; Ru = 'INSTALL.ru.md' }) {
        $en = Read-Readme $En; $ru = Read-Readme $Ru
        Get-WslbinOptions $ru | Should -Be (Get-WslbinOptions $en)
        Get-InstallParameters $ru | Should -Be (Get-InstallParameters $en)
    }

    It 'describe the same sections in both languages (<En> and <Ru>)' -ForEach @(@{ En = 'README.md'; Ru = 'README.ru.md' }, @{ En = 'INSTALL.md'; Ru = 'INSTALL.ru.md' }) {
        # the number of headings of each level, outside the code blocks
        $headings = {
            param($t)
            $outside = [regex]::Replace($t, '(?ms)^```.*?^```', '')
            @([regex]::Matches($outside, '(?m)^(#{1,6}) ') | ForEach-Object { $_.Groups[1].Value.Length })
        }
        (& $headings (Read-Readme $Ru)) | Should -Be (& $headings (Read-Readme $En))
    }

    # (`$LASTEXITCODE` once came out as ``: PowerShell had put its own variable in, which was empty)
    It '<File> has no empty piece of code' -ForEach @(@{ File = 'README.md' }, @{ File = 'README.ru.md' }, @{ File = 'INSTALL.md' }, @{ File = 'INSTALL.ru.md' }, @{ File = 'CONTRIBUTING.md' }) {
        [regex]::Matches((Read-Readme $File), '(?<!`)``(?!`)').Count | Should -Be 0
    }

    It '<File> opens every code block with three backticks and closes it' -ForEach @(@{ File = 'README.md' }, @{ File = 'README.ru.md' }, @{ File = 'INSTALL.md' }, @{ File = 'INSTALL.ru.md' }, @{ File = 'CONTRIBUTING.md' }) {
        $text = Read-Readme $File
        # a block opened with one backtick ("`powershell") pairs every fence after it the wrong way round
        [regex]::Matches($text, '(?m)^`[a-z]+$').Count | Should -Be 0
        @([regex]::Matches($text, '(?m)^```')).Count % 2 | Should -Be 0
    }

    It '<File> is UTF-8 without a byte order mark, with Unix line ends' -ForEach @(@{ File = 'README.md' }, @{ File = 'README.ru.md' }, @{ File = 'INSTALL.md' }, @{ File = 'INSTALL.ru.md' }, @{ File = 'CONTRIBUTING.md' }) {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $script:Repo $File))
        ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
        $bytes -contains 13 | Should -BeFalse
        { [Text.UTF8Encoding]::new($false, $true).GetString($bytes) } | Should -Not -Throw
    }

    # A link to a file or to a heading that is not there is a dead link on GitHub: the files, and the anchors
    # (GitHub's rule: lower case, only letters, digits, - and _ stay, spaces become -), are checked.
    It '<File>: every relative link names a file that exists, and every #anchor a heading that exists' -ForEach @(@{ File = 'README.md' }, @{ File = 'README.ru.md' }, @{ File = 'INSTALL.md' }, @{ File = 'INSTALL.ru.md' }, @{ File = 'CONTRIBUTING.md' }) {
        $slugsOf = {
            param($t)
            $outside = [regex]::Replace($t, '(?ms)^```.*?^```', '')
            foreach ($m in [regex]::Matches($outside, '(?m)^#{1,6}\s+(.+?)\s*$')) {
                $s = $m.Groups[1].Value.ToLowerInvariant().Replace('`', '').Replace('*', '')
                ([regex]::Replace($s, '[^\p{L}\p{N}\p{M} _-]', '')).Replace(' ', '-')
            }
        }
        $text = Read-Readme $File
        $outside = [regex]::Replace($text, '(?ms)^```.*?^```', '')
        $links = [regex]::Matches($outside, '\]\((?<target>[^)\s]+)\)') | ForEach-Object { $_.Groups['target'].Value } | Where-Object { $_ -notmatch '^(https?:|mailto:)' }
        @($links).Count | Should -BeGreaterThan 0
        foreach ($link in $links) {
            # (not $file and $anchor: PowerShell names ignore case, so $file would be $File, the file under test)
            $linkFile, $linkAnchor = $link -split '#', 2
            $linkedDocument = if ($linkFile) { $linkFile } else { $File }
            Test-Path -LiteralPath (Join-Path $script:Repo $linkedDocument) | Should -BeTrue -Because "$File links to $link"
            if ($linkAnchor -and $linkedDocument -match '\.md$') {
                @(& $slugsOf (Read-Readme $linkedDocument)) | Should -Contain $linkAnchor -Because "$File links to $link"
            }
        }
    }

    # The site links to headings of the README on GitHub (github.com/quatrebi/wslbin#usage): they must exist there.
    It 'site/index.html: every link to a heading of the README names one that exists' {
        $site = [IO.File]::ReadAllText((Join-Path $script:Repo 'site\index.html'), [Text.UTF8Encoding]::new($false))
        $readme = [regex]::Replace((Read-Readme 'README.md'), '(?ms)^```.*?^```', '')
        $slugs = foreach ($m in [regex]::Matches($readme, '(?m)^#{1,6}\s+(.+?)\s*$')) {
            ([regex]::Replace($m.Groups[1].Value.ToLowerInvariant().Replace('`', '').Replace('*', ''), '[^\p{L}\p{N}\p{M} _-]', '')).Replace(' ', '-')
        }
        # (#readme is GitHub's own anchor for the whole README, not a heading of it)
        $anchors = [regex]::Matches($site, 'https://github\.com/quatrebi/wslbin#([A-Za-z0-9_-]+)') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -ne 'readme' } | Sort-Object -Unique
        @($anchors).Count | Should -BeGreaterThan 0
        foreach ($a in $anchors) { @($slugs) | Should -Contain $a -Because "site/index.html links to README#$a" }
    }
}

Describe 'the help text of wslbin.ini' {
    It 'names auto as a value of lang (<Lang>)' -ForEach @(@{ Lang = 'en' }, @{ Lang = 'ru' }) {
        $text = Read-Doc $Lang 'config.txt'
        $line = ($text -split "`n" | Where-Object { $_ -match '^\s+lang = ' } | Select-Object -First 1)
        $after = $text.Substring($text.IndexOf($line) + $line.Length)
        ($after -split "`n" | Select-Object -First 3) -join ' ' | Should -Match '\bauto\b'
    }
}
Describe 'wslbin --ai-context' {
    It 'prints the text for agents in <Lang>' -ForEach @(@{ Lang = 'en' }, @{ Lang = 'ru' }) {
        $r = Invoke-Help -Arguments @('--ai-context') -Lang $Lang
        $r.ExitCode | Should -Be 0
        $r.Out.Replace("`r", '') | Should -BeExactly ((Read-Doc $Lang 'ai-context.md').TrimEnd("`n") + "`n")
    }

    It 'takes no arguments' {
        (Invoke-Help -Arguments @('--ai-context', 'x') -Lang 'en').ExitCode | Should -Be 125
    }
}

Describe 'wslbin --install-ai-context' {
    BeforeAll {
        function Install-Context([string[]]$More, [hashtable]$Env = @{}) {
            Invoke-Wslbin -Name 'wslbin' -Dir $script:Home1 -Env $Env -Arguments (@('--install-ai-context') + $More)
        }
    }

    It 'adds a marked block to CLAUDE.md and AGENTS.md, and a skill for Claude Code' {
        $c = New-AgentHome; $x = New-AgentHome
        $r = Install-Context @('--claude-dir', $c, '--codex-dir', $x)
        $r.ExitCode | Should -Be 0
        $claude = Get-Content -Raw (Join-Path $c 'CLAUDE.md')
        $claude | Should -Match '<!-- wslbin:begin'
        $claude | Should -Match 'wslbin --ai-context'
        $claude | Should -Match '<!-- wslbin:end -->'
        Get-Content -Raw (Join-Path $x 'AGENTS.md') | Should -Match '<!-- wslbin:begin'
        $skill = Get-Content -Raw (Join-Path $c 'skills\wslbin\SKILL.md')
        $skill | Should -Match '(?s)^---\r?\nname: wslbin\r?\ndescription: .+?\r?\n---'
        $skill | Should -Match 'Linux utilities from WSL run on this machine'
        Test-Path (Join-Path $x 'skills') | Should -BeFalse
    }

    It 'is idempotent' {
        $c = New-AgentHome; $x = New-AgentHome
        $null = Install-Context @('--claude-dir', $c, '--codex-dir', $x)
        $before = (Get-FileHash (Join-Path $c 'CLAUDE.md')).Hash, (Get-FileHash (Join-Path $c 'skills\wslbin\SKILL.md')).Hash, (Get-FileHash (Join-Path $x 'AGENTS.md')).Hash
        $r = Install-Context @('--claude-dir', $c, '--codex-dir', $x)
        $r.Out | Should -Match 'up to date'
        $after = (Get-FileHash (Join-Path $c 'CLAUDE.md')).Hash, (Get-FileHash (Join-Path $c 'skills\wslbin\SKILL.md')).Hash, (Get-FileHash (Join-Path $x 'AGENTS.md')).Hash
        $after | Should -Be $before
        @([regex]::Matches((Get-Content -Raw (Join-Path $c 'CLAUDE.md')), 'wslbin:begin')).Count | Should -Be 1
    }

    It 'keeps what is already in the file, and puts the block after it' {
        $c = New-AgentHome
        [IO.File]::WriteAllText((Join-Path $c 'CLAUDE.md'), "# Mine`n`nUse tabs.`n", [Text.UTF8Encoding]::new($false))
        $r = Install-Context @('--claude-dir', $c, '--claude')
        $text = (Get-Content -Raw (Join-Path $c 'CLAUDE.md')).Replace("`r`n", "`n")
        $text | Should -Match '(?s)^# Mine\n\nUse tabs\.\n\n<!-- wslbin:begin'
    }

    It 'follows the line ends of the file' {
        $c = New-AgentHome
        [IO.File]::WriteAllText((Join-Path $c 'CLAUDE.md'), "# Mine`r`n`r`nUse tabs.`r`n", [Text.UTF8Encoding]::new($false))
        $null = Install-Context @('--claude-dir', $c, '--claude')
        $bytes = [IO.File]::ReadAllText((Join-Path $c 'CLAUDE.md'))
        ($bytes -replace "`r`n", '').Contains("`n") | Should -BeFalse
        $bytes | Should -Match '<!-- wslbin:end -->\r\n$'
    }

    It 'keeps a byte order mark that the file has' {
        $c = New-AgentHome
        [IO.File]::WriteAllText((Join-Path $c 'CLAUDE.md'), "# Mine`n", [Text.UTF8Encoding]::new($true))
        $null = Install-Context @('--claude-dir', $c, '--claude')
        $b = [IO.File]::ReadAllBytes((Join-Path $c 'CLAUDE.md'))
        ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) | Should -BeTrue
    }

    It 'writes through a symbolic link: the link stays, the file it points to gets the block' {
        $c = New-AgentHome
        $dotfiles = New-AgentHome
        $real = Join-Path $dotfiles 'CLAUDE.md'
        [IO.File]::WriteAllText($real, "# Mine`n", [Text.UTF8Encoding]::new($false))
        $link = Join-Path $c 'CLAUDE.md'
        try { New-Item -ItemType SymbolicLink -Path $link -Target $real -ErrorAction Stop | Out-Null }
        catch { Set-ItResult -Skipped -Because 'this account may not make symbolic links (Developer Mode is off)'; return }
        $r = Install-Context @('--claude-dir', $c, '--claude')
        $r.ExitCode | Should -Be 0 -Because $r.Err
        (Get-Item $link).LinkType | Should -BeExactly 'SymbolicLink'
        Get-Content -Raw $real | Should -Match '<!-- wslbin:begin'
        $r = Install-Context @('--claude-dir', $c, '--claude', '--remove')
        $r.ExitCode | Should -Be 0 -Because $r.Err
        (Get-Item $link).LinkType | Should -BeExactly 'SymbolicLink'
        Get-Content -Raw $real | Should -Not -Match 'wslbin'
        @(Get-ChildItem $c -Filter '*.tmp' -Force).Count + @(Get-ChildItem $dotfiles -Filter '*.tmp' -Force).Count | Should -Be 0
    }

    It 'leaves a read-only file as it is, says so in one line, and still does the other agent' {
        $c = New-AgentHome; $x = New-AgentHome
        $path = Join-Path $c 'CLAUDE.md'
        [IO.File]::WriteAllText($path, "# Mine`n", [Text.UTF8Encoding]::new($false))
        (Get-Item $path).IsReadOnly = $true
        try {
            $r = Install-Context @('--claude-dir', $c, '--codex-dir', $x)
        }
        finally { (Get-Item $path).IsReadOnly = $false }
        $r.ExitCode | Should -Be 125
        $r.Err | Should -Match 'Claude Code: .*CLAUDE\.md is read-only'
        $r.Err | Should -Not -Match 'internal error|   at '
        # nothing claims a change that was not made
        $r.Out | Should -Not -Match 'added the wslbin block'
        [IO.File]::ReadAllText($path) | Should -BeExactly "# Mine`n"
        Get-Content -Raw (Join-Path $x 'AGENTS.md') | Should -Match '<!-- wslbin:begin'
        @(Get-ChildItem $c -Filter '*.tmp' -Force).Count | Should -Be 0
    }

    It 'keeps the attributes of the file it changes' {
        $c = New-AgentHome
        $path = Join-Path $c 'CLAUDE.md'
        [IO.File]::WriteAllText($path, "# Mine`n", [Text.UTF8Encoding]::new($false))
        (Get-Item $path -Force).Attributes = 'Hidden'
        $r = Install-Context @('--claude-dir', $c, '--claude')
        $r.ExitCode | Should -Be 0 -Because $r.Err
        (Get-Item $path -Force).Attributes.HasFlag([IO.FileAttributes]::Hidden) | Should -BeTrue
    }

    It 'replaces its own block in place when the text has changed, and touches nothing else' {
        $c = New-AgentHome
        $null = Install-Context @('--claude-dir', $c, '--claude')
        $path = Join-Path $c 'CLAUDE.md'
        $text = [IO.File]::ReadAllText($path)
        $edited = $text.Replace('Linux utilities (make', 'OLD TEXT (make')
        [IO.File]::WriteAllText($path, "before`n" + $edited + "after`n", [Text.UTF8Encoding]::new($false))
        $r = Install-Context @('--claude-dir', $c, '--claude')
        $r.Out | Should -Match 'updated the wslbin block'
        $now = (Get-Content -Raw $path).Replace("`r`n", "`n")
        $now | Should -Not -Match 'OLD TEXT'
        $now | Should -Match '(?s)^before\n.*<!-- wslbin:end -->\nafter\n$'
    }

    It 'takes out only the block and the skill, with --remove' {
        $c = New-AgentHome; $x = New-AgentHome
        [IO.File]::WriteAllText((Join-Path $c 'CLAUDE.md'), "# Mine`n`nUse tabs.`n", [Text.UTF8Encoding]::new($false))
        $null = Install-Context @('--claude-dir', $c, '--codex-dir', $x)
        $r = Install-Context @('--claude-dir', $c, '--codex-dir', $x, '--remove')
        $r.ExitCode | Should -Be 0
        (Get-Content -Raw (Join-Path $c 'CLAUDE.md')).Replace("`r`n", "`n") | Should -BeExactly "# Mine`n`nUse tabs.`n"
        Test-Path (Join-Path $c 'skills\wslbin') | Should -BeFalse
        # AGENTS.md held nothing but the block: it goes away with it
        Test-Path (Join-Path $x 'AGENTS.md') | Should -BeFalse
    }

    It 'says so when there is nothing to remove' {
        $c = New-AgentHome
        $r = Install-Context @('--claude-dir', $c, '--claude', '--remove')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Match 'no wslbin block'
    }

    It 'leaves a skill that is not its own alone' {
        $c = New-AgentHome
        New-Item -ItemType Directory -Path (Join-Path $c 'skills\wslbin') | Out-Null
        [IO.File]::WriteAllText((Join-Path $c 'skills\wslbin\SKILL.md'), "---`nname: wslbin`n---`nMy own.`n", [Text.UTF8Encoding]::new($false))
        $r = Install-Context @('--claude-dir', $c, '--claude')
        $r.Out | Should -Match 'left .* alone'
        Get-Content -Raw (Join-Path $c 'skills\wslbin\SKILL.md') | Should -Match 'My own'
        $null = Install-Context @('--claude-dir', $c, '--claude', '--remove')
        Test-Path (Join-Path $c 'skills\wslbin\SKILL.md') | Should -BeTrue
    }

    It 'changes nothing with --dry-run' {
        $c = New-AgentHome
        $r = Install-Context @('--claude-dir', $c, '--claude', '--dry-run')
        $r.Out | Should -Match 'would create '
        $r.Out | Should -Not -Match 'would (created|updated|removed|added)'
        @(Get-ChildItem $c -Recurse).Count | Should -Be 0
    }

    It 'says what it would do in a dry run of an update and of --remove, in plain words' {
        $c = New-AgentHome
        [IO.File]::WriteAllText((Join-Path $c 'CLAUDE.md'), "# Mine`n")
        $null = Install-Context @('--claude-dir', $c, '--claude')
        $before = (Get-FileHash (Join-Path $c 'CLAUDE.md')).Hash
        $remove = Install-Context @('--claude-dir', $c, '--claude', '--remove', '--dry-run')
        $remove.Out | Should -Match 'would remove the wslbin block from'
        $remove.Out | Should -Match 'would remove .*SKILL\.md'
        $remove.Out | Should -Not -Match 'would (created|updated|removed|added)'
        (Get-FileHash (Join-Path $c 'CLAUDE.md')).Hash | Should -Be $before
        Test-Path (Join-Path $c 'skills\wslbin\SKILL.md') | Should -BeTrue
    }

    It 'refuses a folder for the agent that the other option leaves out: <Only> <Folder>' -ForEach @(
        @{ Only = '--codex'; Folder = '--claude-dir' }
        @{ Only = '--claude'; Folder = '--codex-dir' }
    ) {
        $c = New-AgentHome
        $r = Install-Context @($Only, $Folder, $c)
        $r.ExitCode | Should -Be 125
        $r.Err | Should -Match ([regex]::Escape($Folder) + ' names the folder of .*, which ' + [regex]::Escape($Only) + ' leaves out')
        @(Get-ChildItem $c -Recurse).Count | Should -Be 0
    }

    It 'goes where the variables of the agents point' {
        $c = New-AgentHome; $x = New-AgentHome
        $r = Install-Context @() -Env @{ CLAUDE_CONFIG_DIR = $c; CODEX_HOME = $x; USERPROFILE = (New-AgentHome) }
        $r.ExitCode | Should -Be 0
        Test-Path (Join-Path $c 'CLAUDE.md') | Should -BeTrue
        Test-Path (Join-Path $x 'AGENTS.md') | Should -BeTrue
    }

    It 'falls back to .claude and .codex in the home folder, and does not create them' {
        $u = New-AgentHome
        New-Item -ItemType Directory -Path (Join-Path $u '.claude') | Out-Null
        $r = Install-Context @() -Env @{ CLAUDE_CONFIG_DIR = $null; CODEX_HOME = $null; USERPROFILE = $u }
        $r.ExitCode | Should -Be 0
        Test-Path (Join-Path $u '.claude\CLAUDE.md') | Should -BeTrue
        Test-Path (Join-Path $u '.codex') | Should -BeFalse
        $r.Out | Should -Match 'Codex: skipped'
    }

    It 'skips the agents without a home folder, instead of looking for .claude in the current folder' {
        $u = New-AgentHome
        New-Item -ItemType Directory -Path (Join-Path $u '.claude') | Out-Null
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $script:Home1 -WorkingDirectory $u -Env @{ CLAUDE_CONFIG_DIR = $null; CODEX_HOME = $null; USERPROFILE = $null } -Arguments @('--install-ai-context')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Match 'Claude Code: skipped, USERPROFILE is not set'
        Test-Path (Join-Path $u '.claude\CLAUDE.md') | Should -BeFalse
    }

    It 'creates the folder of an agent only when it is named' {
        $u = New-AgentHome
        $named = Join-Path $u 'made-by-name'
        $null = Install-Context @('--codex-dir', $named, '--codex')
        Test-Path (Join-Path $named 'AGENTS.md') | Should -BeTrue
    }

    It 'writes the block in English and the skill in the language of wslbin.ini' {
        $c = New-AgentHome
        $r = Invoke-Wslbin -Name 'wslbin' -Dir $script:Home1 -Ini "lang = ru`n" -Arguments @('--install-ai-context', '--claude-dir', $c, '--claude')
        (Get-Content -Raw -Encoding UTF8 (Join-Path $c 'CLAUDE.md')) | Should -Not -Match $script:Cyrillic.Substring(0, 3)
        (Get-Content -Raw -Encoding UTF8 (Join-Path $c 'skills\wslbin\SKILL.md')) | Should -Match ([regex]::Escape((-join ([char[]](0x0423, 0x0442, 0x0438, 0x043B, 0x0438, 0x0442, 0x044B)))))   # "Утилиты"
    }

    It 'does not touch the real folders of the agents when no folder is named (the helper points the variables at nothing)' {
        # (and the home folder at one of the test: were the variables ever ignored, ~/.claude is not the real one)
        $r = Install-Context @() -Env @{ USERPROFILE = (New-AgentHome) }
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Match 'Claude Code: skipped'
        $r.Out | Should -Match 'Codex: skipped'
        Test-Path (Join-Path $global:WslbinTest.Work 'no-claude-folder-here') | Should -BeFalse
    }

    It 'leaves a file alone that is not UTF-8 text, and says so' -ForEach @(
        @{ Kind = 'ANSI (cp1251)'; Bytes = [byte[]](0x23, 0x20, 0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2, 0x0A) }
        @{ Kind = 'UTF-16 with a mark'; Bytes = [byte[]]([Text.Encoding]::Unicode.GetPreamble() + [Text.Encoding]::Unicode.GetBytes("# hi`n")) }
        @{ Kind = 'UTF-16 without a mark'; Bytes = [byte[]][Text.Encoding]::Unicode.GetBytes("# hi`n") }
    ) {
        $c = New-AgentHome
        $path = Join-Path $c 'CLAUDE.md'
        [IO.File]::WriteAllBytes($path, $Bytes)
        foreach ($more in @(), @('--remove')) {
            $r = Install-Context (@('--claude-dir', $c, '--claude') + $more)
            $r.ExitCode | Should -Be 125
            $r.Err | Should -Match 'not UTF-8'
            [IO.File]::ReadAllBytes($path) | Should -Be $Bytes
        }
        Test-Path (Join-Path $c 'skills') | Should -BeFalse
    }

    It 'refuses to guess when a marker has lost its partner, and leaves the file as it is (<Case>)' -ForEach @(
        @{ Case = 'begin without end'; Text = "# mine`n<!-- wslbin:begin (old) -->`nMy own important notes`n" }
        @{ Case = 'end without begin'; Text = "# mine`nMy own notes`n<!-- wslbin:end -->`n" }
    ) {
        $c = New-AgentHome
        $path = Join-Path $c 'CLAUDE.md'
        [IO.File]::WriteAllText($path, $Text, [Text.UTF8Encoding]::new($false))
        foreach ($more in @(), @('--remove')) {
            $r = Install-Context (@('--claude-dir', $c, '--claude') + $more)
            $r.ExitCode | Should -Be 125
            $r.Err | Should -Match 'without its other half'
            [IO.File]::ReadAllText($path) | Should -BeExactly $Text
        }
    }

    It 'replaces a complete block even when a begin marker lies in front of it, and keeps what is between' {
        $c = New-AgentHome
        $path = Join-Path $c 'CLAUDE.md'
        $null = Install-Context @('--claude-dir', $c, '--claude')
        $block = [IO.File]::ReadAllText($path)
        $edited = "<!-- wslbin:begin stray -->`nMy notes`n" + $block.Replace('Linux utilities (make', 'OLD (make')
        [IO.File]::WriteAllText($path, $edited, [Text.UTF8Encoding]::new($false))
        $r = Install-Context @('--claude-dir', $c, '--claude')
        $r.ExitCode | Should -Be 0
        $now = [IO.File]::ReadAllText($path)
        $now | Should -Match '^<!-- wslbin:begin stray -->\r?\nMy notes\r?\n'
        $now | Should -Not -Match 'OLD'
    }

    It 'refuses unknown options and a missing folder name' {
        (Install-Context @('--bogus')).ExitCode | Should -Be 125
        (Install-Context @('--claude-dir')).ExitCode | Should -Be 125
    }
}
