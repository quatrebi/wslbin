#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
  Tests of what the workflows of GitHub (.github/workflows) stand on: the scripts they call
  (.github/check-version.ps1, .github/new-releases-json.ps1) and the properties of the workflow files that
  matter for safety. No workflow can run here, so the files are checked as text, and the syntax is
  checked by actionlint (AGENTS.md says how). Run: Invoke-Pester ./tests
#>

BeforeAll {
    $script:Repo = Split-Path -Parent $PSScriptRoot
    $script:Work = Join-Path ([IO.Path]::GetTempPath()) ('wslbin-workflow-tests-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:Work | Out-Null
    # the functions below are called from several scopes, so what they need is in global variables
    $global:WorkflowTestRepo = $script:Repo
    $global:WorkflowTestWork = $script:Work

    # the PowerShell that runs these tests, and a child process of it with its own environment
    function Invoke-Child {
        param([string[]]$Arguments, [hashtable]$Environment = @{}, [string]$WorkingDirectory = '', [string]$Exe = '')
        if (-not $Exe) { $Exe = (Get-Process -Id $PID).Path }
        $psi = [Diagnostics.ProcessStartInfo]::new($Exe)
        # Windows PowerShell started from PowerShell 7 with its module path cannot load its own modules
        if ($Exe -match 'WindowsPowerShell') { $null = $psi.Environment.Remove('PSModulePath') }
        foreach ($a in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File') + $Arguments) { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
        if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
        foreach ($key in $Environment.Keys) { $psi.Environment[$key] = $Environment[$key] }
        $p = [Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEndAsync()
        $err = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        @{ Out = $out.GetAwaiter().GetResult().Trim(); Err = $err.Trim(); ExitCode = $p.ExitCode }
    }
}

AfterAll {
    Remove-Item -Recurse -Force $script:Work -ErrorAction SilentlyContinue
    Remove-Variable WorkflowTestRepo, WorkflowTestWork -Scope Global -ErrorAction SilentlyContinue
}

Describe 'check-version.ps1' {
    BeforeAll {
        # one program with a known version, for all the tests of this script
        $script:Prog = Join-Path $script:Work 'prog\wslbin.exe'
        $null = & (Join-Path $script:Repo 'build.ps1') -Output $script:Prog -Version '5.6.7' 6>$null
        function Invoke-CheckVersion {
            param([string]$Expected, [string]$Program)
            $environment = @{ EXPECTED_VERSION = $Expected }
            if ($Program) { $environment.PROGRAM = $Program }
            Invoke-Child -Arguments @((Join-Path $global:WorkflowTestRepo '.github\check-version.ps1')) -Environment $environment
        }
    }

    It 'accepts the version that the program reports' {
        $r = Invoke-CheckVersion -Expected '5.6.7' -Program $script:Prog
        $r.ExitCode | Should -Be 0 -Because $r.Err
    }
    It 'refuses another version, and says both' {
        $r = Invoke-CheckVersion -Expected '9.9.9' -Program $script:Prog
        $r.ExitCode | Should -Not -Be 0
        $r.Err | Should -Match '9\.9\.9'
        $r.Err | Should -Match '5\.6\.7'
    }
    It 'refuses an expected version that is not SemVer 2.0, and runs nothing of it: <_>' -ForEach @('5.6.7; exit 0', 'v5.6.7', '', '5.6') {
        $r = Invoke-CheckVersion -Expected $_ -Program $script:Prog
        $r.ExitCode | Should -Not -Be 0
        $r.Err | Should -Match 'SemVer'
    }
    It 'refuses a program that does not exist' {
        $r = Invoke-CheckVersion -Expected '5.6.7' -Program (Join-Path $script:Work 'nowhere\wslbin.exe')
        $r.ExitCode | Should -Not -Be 0
        $r.Err | Should -Match 'does not exist'
    }
}

Describe 'new-releases-json.ps1' {
    BeforeAll {
        $script:Hash = @{}
        # (a generator of its own: Get-Random -SetSeed would fix the numbers of every test that runs after this file)
        foreach ($n in 'a', 'b', 'c', 'd') {
            $rng = [System.Random]::new([int][char]$n)
            $script:Hash[$n] = -join (1..64 | ForEach-Object { '0123456789abcdef'[$rng.Next(0, 16)] })
        }

        # a release as the API of GitHub shows it: only what the script reads
        function New-FakeRelease {
            param([string]$Tag, [bool]$Draft = $false, [bool]$Prerelease = $false, [object[]]$Assets = @(), [string]$Published = '2026-10-23T10:00:00Z')
            [pscustomobject]@{ tag_name = $Tag; draft = $Draft; prerelease = $Prerelease; published_at = $Published; assets = $Assets }
        }
        function New-FakeAsset {
            param([string]$Name, [string]$Url = '', [string]$Digest = '')
            if (-not $Url) { $Url = "https://github.com/quatrebi/wslbin/releases/download/x/$Name" }
            $asset = [ordered]@{ name = $Name; browser_download_url = $Url }
            if ($Digest) { $asset.digest = $Digest }
            [pscustomobject]$asset
        }
        # runs the script on the releases; returns the exit code, what it printed, and the file it wrote
        function Invoke-ReleasesScript {
            param([object]$Releases, [string]$RawInput = '', [string]$Exe = '')
            $dir = Join-Path $global:WorkflowTestWork ('rel-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir | Out-Null
            $in = Join-Path $dir 'in.json'
            $out = Join-Path $dir 'out\releases.json'
            if ($RawInput) { [IO.File]::WriteAllText($in, $RawInput, [Text.UTF8Encoding]::new($false)) }
            else { [IO.File]::WriteAllText($in, (ConvertTo-Json -InputObject @($Releases) -Depth 8), [Text.UTF8Encoding]::new($false)) }
            $r = Invoke-Child -Arguments @((Join-Path $global:WorkflowTestRepo '.github\new-releases-json.ps1'), '-Repository', 'quatrebi/wslbin', '-Output', $out, '-InputFile', $in) -Exe $Exe
            $r.Output = $out
            $r.Dir = $dir
            $r.Json = $(if (Test-Path -LiteralPath $out) { [IO.File]::ReadAllText($out) | ConvertFrom-Json } else { $null })
            $r
        }

        # a hash that is only in the asset "<zip>.sha256", which the script has to read
        $script:ShaFile = Join-Path $script:Work 'wslbin-0.1.10-win-x64.zip.sha256'
        [IO.File]::WriteAllText($script:ShaFile, "$($script:Hash.b.ToUpperInvariant())  wslbin-0.1.10-win-x64.zip`n", [Text.UTF8Encoding]::new($false))

        $script:Mixed = @(
            (New-FakeRelease 'v0.1.3' -Assets @((New-FakeAsset 'wslbin-0.1.3-win-x64.zip' -Digest "sha256:$($script:Hash.a)")))
            (New-FakeRelease 'v0.1.10' -Assets @((New-FakeAsset 'wslbin-0.1.10-win-x64.zip'), (New-FakeAsset 'wslbin-0.1.10-win-x64.zip.sha256' -Url ([Uri]$script:ShaFile).AbsoluteUri)))
            (New-FakeRelease 'v0.2.0-rc.1' -Prerelease $true -Assets @((New-FakeAsset 'wslbin-0.2.0-rc.1-win-x64.zip' -Digest "sha256:$($script:Hash.c)")))
            (New-FakeRelease 'v0.1.4' -Draft $true -Assets @((New-FakeAsset 'wslbin-0.1.4-win-x64.zip' -Digest "sha256:$($script:Hash.c)")))
            (New-FakeRelease 'v0.1.5' -Assets @((New-FakeAsset 'something-else.zip' -Digest "sha256:$($script:Hash.c)")))
            (New-FakeRelease 'vx.y.z' -Assets @((New-FakeAsset 'wslbin-x.y.z-win-x64.zip' -Digest "sha256:$($script:Hash.c)")))
            (New-FakeRelease 'v1.2.3-evil";calc' -Assets @((New-FakeAsset 'wslbin-1.2.3-evil";calc-win-x64.zip' -Digest "sha256:$($script:Hash.c)")))
            (New-FakeRelease 'v0.1.6' -Assets @((New-FakeAsset 'wslbin-0.1.6-win-x64.zip' -Digest 'sha256:not-a-hash')))
            (New-FakeRelease 'v0.1.7' -Assets @((New-FakeAsset 'wslbin-0.1.7-win-x64.zip'), (New-FakeAsset 'wslbin-0.1.7-win-x64.zip.sha256' -Url 'http://example.invalid/wslbin-0.1.7-win-x64.zip.sha256')))
        )
        $script:Run = Invoke-ReleasesScript -Releases $script:Mixed
    }

    It 'takes only the stable releases with their zip and a hash, highest version first' {
        $script:Run.ExitCode | Should -Be 0 -Because $script:Run.Err
        @($script:Run.Json.releases | ForEach-Object { $_.version }) | Should -Be @('0.1.10', '0.1.3')
    }
    It 'says which one is the latest by SemVer, not by date or by order' {
        $script:Run.Json.latest | Should -BeExactly '0.1.10'
    }
    It 'gives each release its tag, zip name, address, date and a lowercase SHA256' {
        $first = $script:Run.Json.releases[0]
        $first.tag | Should -BeExactly 'v0.1.10'
        $first.asset | Should -BeExactly 'wslbin-0.1.10-win-x64.zip'
        $first.url | Should -BeExactly 'https://github.com/quatrebi/wslbin/releases/download/x/wslbin-0.1.10-win-x64.zip'
        $first.sha256 | Should -BeExactly $script:Hash.b
        $script:Run.Json.releases[1].sha256 | Should -BeExactly $script:Hash.a
        foreach ($r in $script:Run.Json.releases) { $r.sha256 | Should -Match '^[0-9a-f]{64}\z' }
    }
    It 'writes the date as ISO 8601 in UTC, whatever the culture of the machine (the text of the file, not a parsed date)' {
        (Get-Content -Raw $script:Run.Output) | Should -Match '"published": "2026-10-23T10:00:00Z"'
    }
    It 'writes schema 1, UTF-8 without a byte order mark, with line feeds only' {
        $script:Run.Json.schema | Should -Be 1
        $bytes = [IO.File]::ReadAllBytes($script:Run.Output)
        ($bytes[0..2] -join ',') | Should -Not -Be '239,187,191'
        $bytes | Should -Not -Contain 13
    }
    It 'warns about the releases that it skips for a reason it can name, and writes nothing of them' {
        $text = $script:Run.Out + "`n" + $script:Run.Err
        $text | Should -Match 'v0\.1\.5'
        $text | Should -Match 'v0\.1\.6'
        (Get-Content -Raw $script:Run.Output) | Should -Not -Match 'calc|x\.y\.z|0\.2\.0|0\.1\.4|0\.1\.5|0\.1\.6|0\.1\.7'
    }
    It 'gives an empty list and no latest when there is no release' {
        $r = Invoke-ReleasesScript -Releases @()
        $r.ExitCode | Should -Be 0 -Because $r.Err
        $r.Json.latest | Should -BeNullOrEmpty
        @($r.Json.releases).Count | Should -Be 0
        $r.Json.schema | Should -Be 1
    }
    It 'fails and writes nothing when the input is not JSON' {
        $r = Invoke-ReleasesScript -Releases $null -RawInput 'this is not json'
        $r.ExitCode | Should -Not -Be 0
        Test-Path $r.Output | Should -BeFalse
    }
    It 'gives the same releases in Windows PowerShell 5.1 (its JSON is laid out differently, so the content is compared)' -Skip:(-not (Test-Path (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'))) {
        $winPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $r = Invoke-ReleasesScript -Releases $script:Mixed -Exe $winPs
        $r.ExitCode | Should -Be 0 -Because $r.Err
        ($r.Json | ConvertTo-Json -Depth 6 -Compress) | Should -BeExactly ($script:Run.Json | ConvertTo-Json -Depth 6 -Compress)
        @($r.Json.releases).Count | Should -Be 2
    }
    It 'reads a list that holds one release, in both shells' -ForEach @('pwsh', 'winps') {
        $exe = if ($_ -eq 'winps') { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' } else { '' }
        $one = New-FakeRelease 'v1.0.0' -Assets @((New-FakeAsset 'wslbin-1.0.0-win-x64.zip' -Digest "sha256:$($script:Hash.d)"))
        $r = Invoke-ReleasesScript -Releases @($one) -Exe $exe
        $r.ExitCode | Should -Be 0 -Because $r.Err
        $r.Json.latest | Should -BeExactly '1.0.0'
        @($r.Json.releases).Count | Should -Be 1
    }
    It 'does not fetch a hash from an address that is not https: such a release is skipped with a warning' {
        $text = $script:Run.Out + "`n" + $script:Run.Err
        $text | Should -Match 'v0\.1\.7'
        @($script:Run.Json.releases | ForEach-Object { $_.version }) | Should -Not -Contain '0.1.7'
    }
}

Describe 'the workflows' {
    BeforeAll {
        function global:Get-WorkflowText([string]$Name) {
            [IO.File]::ReadAllText((Join-Path $global:WorkflowTestRepo ".github\workflows\$Name")).Replace("`r`n", "`n")
        }
        # The text of every run: of a workflow, a one-line one or a block (| or >), found by indentation:
        # there is no YAML parser here, and the shape of these files is plain.
        function global:Get-RunBlocks([string]$Text) {
            $lines = $Text -split "`n"
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^(\s*)(- )?run:\s*(.*)$') {
                    $keyIndent = $Matches[1].Length + $(if ($Matches[2]) { 2 } else { 0 })
                    $rest = $Matches[3]
                    if ($rest -match '^[|>][-+]?\s*$') {
                        $block = New-Object System.Collections.Generic.List[string]
                        for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                            if ($lines[$j].Trim() -eq '') { $block.Add($lines[$j]); continue }
                            $null = $lines[$j] -match '^(\s*)'
                            if ($Matches[1].Length -le $keyIndent) { break }
                            $block.Add($lines[$j])
                        }
                        $block -join "`n"
                    }
                    else { $rest }
                }
            }
        }
        # the text of one job: from "  <job>:" to the next job or the end
        function global:Get-JobText([string]$Text, [string]$Job) {
            $m = [regex]::Match($Text, "(?ms)^  $([regex]::Escape($Job)):\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\z)")
            if (-not $m.Success) { throw "no job $Job" }
            $m.Value
        }
    }

    It '<Name>: every action is pinned to a commit and names its version in a comment' -ForEach @(@{ Name = 'ci.yml' }, @{ Name = 'release.yml' }, @{ Name = 'pages.yml' }) {
        $uses = [regex]::Matches((Get-WorkflowText $Name), '(?m)^\s*(?:- )?uses:\s*(\S+)(.*)$')
        $uses.Count | Should -BeGreaterThan 0
        foreach ($m in $uses) {
            $ref = $m.Groups[1].Value
            if ($ref.StartsWith('./')) { continue }   # a workflow of this repository
            $ref | Should -Match '@[0-9a-f]{40}\z'
            $m.Groups[2].Value | Should -Match '#\s*v\d+\.\d+\.\d+'
        }
    }
    It '<Name>: reads the repository by default (the top of the file has contents: read and nothing else)' -ForEach @(@{ Name = 'ci.yml' }, @{ Name = 'release.yml' }, @{ Name = 'pages.yml' }) {
        (Get-WorkflowText $Name) | Should -Match '(?m)^permissions:\n  contents: read\n(?!  )'
    }
    It '<Name>: pastes nothing of GitHub into a shell: no ${{ }} in any run:' -ForEach @(@{ Name = 'ci.yml' }, @{ Name = 'release.yml' }, @{ Name = 'pages.yml' }) {
        $blocks = @(Get-RunBlocks (Get-WorkflowText $Name))
        $blocks.Count | Should -BeGreaterThan 0
        foreach ($b in $blocks) { $b | Should -Not -Match '\$\{\{' }
    }
    It '<Name>: does not use pull_request_target' -ForEach @(@{ Name = 'ci.yml' }, @{ Name = 'release.yml' }, @{ Name = 'pages.yml' }) {
        (Get-WorkflowText $Name) | Should -Not -Match 'pull_request_target'
    }
    It 'finds the run: of one-line and block steps (guards the helper: a layout that hides run: would make the ${{ }} tests pass for nothing)' {
        $text = "steps:`n  - name: a`n    run: echo one`n  - run: |`n      echo two`n      echo three`n    shell: pwsh`n"
        $blocks = @(Get-RunBlocks $text)
        $blocks.Count | Should -Be 2
        $blocks[0] | Should -BeExactly 'echo one'
        $blocks[1] | Should -Match 'echo two'
        $blocks[1] | Should -Match 'echo three'
        $blocks[1] | Should -Not -Match 'shell'
    }

    Context 'ci.yml' {
        BeforeAll { $script:Ci = Get-WorkflowText 'ci.yml' }
        It 'runs on a push to main and develop, and on a pull request, and on nothing else' {
            $script:Ci | Should -Match '(?m)^on:\n  push:\n    branches: \[main, develop\]\n  pull_request:\n(?!  )'
        }
        It 'stops an older run of the same branch when a newer one starts' {
            $script:Ci | Should -Match '(?m)^concurrency:\n  group: ci-\$\{\{ github\.workflow \}\}-\$\{\{ github\.ref \}\}\n  cancel-in-progress: true\n'
        }
        It 'has no right to write, and no secret' {
            $script:Ci | Should -Not -Match ': write'
            $script:Ci | Should -Not -Match 'secrets\.'
        }
        It 'takes the whole history and the head of a pull request (the merge commit does not exist after the merge)' {
            $script:Ci | Should -Match 'fetch-depth: 0'
            $script:Ci | Should -Match 'ref: \$\{\{ github\.event\.pull_request\.head\.sha \|\| github\.sha \}\}'
        }
        It 'takes the SDK from global.json, and has a time limit' {
            $script:Ci | Should -Match 'global-json-file: global\.json'
            $script:Ci | Should -Match 'timeout-minutes: \d+'
        }
        It 'hands what GitHub says to the version step through env, as a pull request or as a branch' {
            $step = $script:Ci.Substring($script:Ci.IndexOf('id: version'))
            $step = $step.Substring(0, $step.IndexOf('- name:', 10))
            $step | Should -Match 'EVENT: \$\{\{ github\.event_name \}\}'
            $step | Should -Match 'BRANCH: \$\{\{ github\.ref_name \}\}'
            $step | Should -Match 'PR_NUMBER: \$\{\{ github\.event\.pull_request\.number \}\}'
            $step | Should -Match 'RUN_NUMBER: \$\{\{ github\.run_number \}\}'
            $step | Should -Match '-Kind pr'
            $step | Should -Match '-Kind branch'
            $step | Should -Match 'GITHUB_OUTPUT'
        }
        It 'builds with that version, checks the program says it, and keeps the program as an artifact before the tests' {
            $build = $script:Ci.IndexOf('./build.ps1 -Version')
            $check = $script:Ci.IndexOf('check-version.ps1')
            $upload = $script:Ci.IndexOf('actions/upload-artifact')
            $test = $script:Ci.IndexOf('Invoke-Pester')
            $build | Should -BeGreaterThan 0
            $check | Should -BeGreaterThan $build
            $upload | Should -BeGreaterThan $check
            $test | Should -BeGreaterThan $upload
            $script:Ci | Should -Match 'name: wslbin-\$\{\{ steps\.version\.outputs\.version \}\}'
            $script:Ci | Should -Match 'path: bin/wslbin\.exe'
            $script:Ci | Should -Match 'retention-days: 14'
            $script:Ci | Should -Match 'if-no-files-found: error'
        }
        It 'does not run the tests that need WSL' {
            $script:Ci | Should -Match "ExcludeTag = 'WSL'"
        }
    }

    Context 'pages.yml' {
        BeforeAll { $script:Pages = Get-WorkflowText 'pages.yml' }
        It 'can be called by the release, and says the address of the site' {
            $script:Pages | Should -Match '(?m)^  workflow_call:\n    outputs:\n      page_url:\n        value: \$\{\{ jobs\.deploy\.outputs\.page_url \}\}\n'
            (Get-JobText $script:Pages 'deploy') | Should -Match 'page_url: \$\{\{ steps\.deployment\.outputs\.page_url \}\}'
        }
        It 'still runs on a change of the site on main, and by hand' {
            $script:Pages | Should -Match "(?m)^  push:\n    branches: \[main\]\n    paths:\n      - 'site/\*\*'"
            $script:Pages | Should -Match '(?m)^  workflow_dispatch:'
        }
        It 'puts releases.json next to the page, made by the script of the repository, with the token in env' {
            $build = Get-JobText $script:Pages 'build'
            $build | Should -Match 'new-releases-json\.ps1'
            $build | Should -Match 'GH_TOKEN: \$\{\{ github\.token \}\}'
            $build | Should -Match 'path: _site'
            $build | Should -Not -Match ': write'
        }
        It 'may write Pages only in the job that deploys' {
            (Get-JobText $script:Pages 'deploy') | Should -Match 'pages: write\n      id-token: write'
            ([regex]::Matches($script:Pages, 'pages: write')).Count | Should -Be 1
        }
        It 'does not let two deployments run at once' {
            $script:Pages | Should -Match '(?m)^concurrency:\n  group: pages\n  cancel-in-progress: false\n'
        }
    }
}

Describe 'release.yml' {
    BeforeAll {
        $script:Rel = Get-WorkflowText 'release.yml'
        $script:TestJob = Get-JobText $script:Rel 'test'
        $script:ReleaseJob = Get-JobText $script:Rel 'release'
        $script:PagesJob = Get-JobText $script:Rel 'pages'
        $script:ProbeJob = Get-JobText $script:Rel 'probe'
    }

    It 'is started by hand and by nothing else: no push, no tag, no schedule' {
        $script:Rel | Should -Match '(?m)^on:\n  workflow_dispatch:\n(?!  )'
        $script:Rel | Should -Not -Match '(?m)^\s+(push|tags|schedule|pull_request):'
    }
    It 'does not run two releases at once, and does not cancel one that runs' {
        $script:Rel | Should -Match '(?m)^concurrency:\n  group: release\n  cancel-in-progress: false\n'
    }
    It 'refuses to go on from any branch but main, in its very first step' {
        $guard = $script:TestJob.IndexOf("refs/heads/main")
        $checkout = $script:TestJob.IndexOf('actions/checkout')
        $guard | Should -BeGreaterThan 0
        $guard | Should -BeLessThan $checkout
    }
    It 'takes the whole history and the tags to work the version out and to see that it is not released yet' {
        $script:TestJob | Should -Match 'fetch-depth: 0'
        $script:TestJob | Should -Match 'fetch-tags: true'
        $script:ReleaseJob | Should -Match 'fetch-depth: 0'
    }
    It 'works the version out for a release, and stops when that version is already released' {
        $script:TestJob | Should -Match '-Kind release'
        $script:TestJob | Should -Match 'already released'
        $script:TestJob | Should -Match 'rev-parse -q --verify'
        $script:TestJob | Should -Match 'outputs:\n      version: \$\{\{ steps\.version\.outputs\.version \}\}'
    }
    It 'tests with the right to read only, builds, checks the program and runs the tests that need no WSL' {
        $script:TestJob | Should -Not -Match ': write'
        $script:TestJob | Should -Match './build\.ps1 -Version'
        $script:TestJob | Should -Match 'check-version\.ps1'
        $script:TestJob | Should -Match "ExcludeTag = 'WSL'"
    }
    It 'runs the jobs in order: test, release, pages (the site), probe' {
        $script:ReleaseJob | Should -Match '(?m)^    needs: test\n'
        $script:PagesJob | Should -Match '(?m)^    needs: release\n'
        $script:ProbeJob | Should -Match '(?m)^    needs: \[test, pages\]\n'
    }
    It 'gives the right to write and to sign to the release job only, and the right to deploy to the pages job only' {
        ([regex]::Matches($script:Rel, 'contents: write')).Count | Should -Be 1
        $script:ReleaseJob | Should -Match 'contents: write'
        $script:ReleaseJob | Should -Match 'id-token: write'
        $script:ReleaseJob | Should -Match 'attestations: write'
        $script:ReleaseJob | Should -Match 'artifact-metadata: write'
        ([regex]::Matches($script:Rel, 'pages: write')).Count | Should -Be 1
        $script:PagesJob | Should -Match 'pages: write'
        $script:PagesJob | Should -Match 'id-token: write'
        $script:ProbeJob | Should -Not -Match ': write'
    }
    It 'builds the version of the test job again, and stops if the commit has moved' {
        $script:ReleaseJob | Should -Match 'VERSION: \$\{\{ needs\.test\.outputs\.version \}\}'
        $script:ReleaseJob | Should -Match '-Kind release'
        $script:ReleaseJob | Should -Match 'the commit has moved'
        $script:ReleaseJob | Should -Match './build\.ps1 -Version'
    }
    It 'makes the zip, its hash files and the attestation, and publishes the release on that very commit' {
        $script:ReleaseJob | Should -Match 'wslbin-\$env:VERSION-win-x64\.zip'
        $script:ReleaseJob | Should -Match 'win-x64\.zip\.sha256'
        $script:ReleaseJob | Should -Match 'SHA256SUMS\.txt'
        $script:ReleaseJob | Should -Match "subject-path: 'dist/\*'"
        $script:ReleaseJob | Should -Match 'gh release create "v\$env:VERSION"'
        $script:ReleaseJob | Should -Match '--target \$env:GITHUB_SHA'
        $script:ReleaseJob | Should -Match 'GH_TOKEN: \$\{\{ github\.token \}\}'
        $script:ReleaseJob | Should -Match '--generate-notes'
    }
    It 'puts the site on Pages by calling the one workflow that deploys, with the rights it needs' {
        $script:PagesJob | Should -Match 'uses: \./\.github/workflows/pages\.yml'
        $script:Rel | Should -Not -Match '(?m)^\s*group: pages'
    }
    It 'asks the site, after the deployment, for the version that was released' {
        $script:ProbeJob | Should -Match 'PAGE_URL: \$\{\{ needs\.pages\.outputs\.page_url \}\}'
        $script:ProbeJob | Should -Match 'VERSION: \$\{\{ needs\.test\.outputs\.version \}\}'
        $script:ProbeJob | Should -Match 'releases\.json'
        $script:ProbeJob | Should -Match 'Invoke-RestMethod'
    }
}

Describe 'dependabot.yml' {
    BeforeAll { $script:Dependabot = [IO.File]::ReadAllText((Join-Path $global:WorkflowTestRepo '.github\dependabot.yml')).Replace("`r`n", "`n") }

    It 'watches the actions of the workflows, weekly, and nothing else yet' {
        $script:Dependabot | Should -Match '(?m)^version: 2$'
        @([regex]::Matches($script:Dependabot, '(?m)^\s*- package-ecosystem: (\S+)') | ForEach-Object { $_.Groups[1].Value }) | Should -Be @('github-actions')
        $script:Dependabot | Should -Match '(?m)^      interval: weekly$'
        $script:Dependabot | Should -Match '(?m)^    directory: /$'
    }
}
