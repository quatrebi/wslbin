#Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '6.2.0' }
<#
  Minimal checks of the landing page and the files that pages.yml publishes. Nothing here builds the program.
#>

BeforeAll {
    $script:Repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:Html = [IO.File]::ReadAllText((Join-Path $script:Repo 'site/index.html'), [Text.Encoding]::UTF8)
    $script:PagesYml = [IO.File]::ReadAllText((Join-Path $script:Repo '.github/workflows/pages.yml'), [Text.Encoding]::UTF8)
}

Describe 'site' {
    It 'every file that pages.yml publishes by name exists in site/' {
        $m = [regex]::Match($script:PagesYml, 'foreach \(\$file in ([^)]+)\)')
        $m.Success | Should -BeTrue
        $names = @([regex]::Matches($m.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
        $names.Count | Should -BeGreaterThan 0
        foreach ($n in $names) { Test-Path -LiteralPath (Join-Path $script:Repo "site/$n") | Should -BeTrue -Because $n }
    }
    It 'index.html has one canonical link and one description meta tag' {
        [regex]::Matches($script:Html, '<link rel="canonical" ').Count | Should -Be 1
        [regex]::Matches($script:Html, '<meta name="description" ').Count | Should -Be 1
    }
    It 'the JSON-LD block of index.html parses and describes a SoftwareApplication' {
        $m = [regex]::Matches($script:Html, '(?s)<script type="application/ld\+json">(.*?)</script>')
        $m.Count | Should -Be 1
        $json = $m[0].Groups[1].Value | ConvertFrom-Json
        $json.'@type' | Should -Be 'SoftwareApplication'
    }
    It 'sitemap.xml parses and has one url entry' {
        $xml = [xml][IO.File]::ReadAllText((Join-Path $script:Repo 'site/sitemap.xml'), [Text.Encoding]::UTF8)
        @($xml.urlset.url).Count | Should -Be 1
    }
}
