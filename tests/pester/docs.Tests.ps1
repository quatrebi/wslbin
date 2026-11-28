#Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '6.2.0' }
<#
  Tests of wslbin --help, --ai-context and --install-ai-context, and of the texts in docs/.
  Run: Invoke-Pester ./tests    (none of it needs WSL)

  --install-ai-context writes into the instructions of AI agents. Every test points it at a temporary
  folder (--claude-dir, --codex-dir, or the variables CLAUDE_CONFIG_DIR, CODEX_HOME and USERPROFILE of
  the child), never at the real ones.
#>

BeforeDiscovery {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
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
    $script:Repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
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
}
Describe 'wslbin --ai-context' {
}

Describe 'wslbin --install-ai-context' {
    BeforeAll {
        function Install-Context([string[]]$More, [hashtable]$Env = @{}) {
            Invoke-Wslbin -Name 'wslbin' -Dir $script:Home1 -Env $Env -Arguments (@('--install-ai-context') + $More)
        }
    }

}
