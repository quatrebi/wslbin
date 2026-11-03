#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
  Tests of the version of a build (Wslbin.Version.psm1 and its command line, get-version.ps1): MAJOR.MINOR
  from wslbin.csproj, PATCH counted from git, the rest from where the build runs.
  Run: Invoke-Pester ./tests

  The repositories of the tests live in a temporary folder, and git runs in them with no configuration of
  the machine or the session: no system or global config, no hooks, none of the GIT_* variables that
  could point it at another repository or give the commits another author.
#>

BeforeDiscovery {
    $Shells = @(@{ Shell = 'pwsh'; Exe = (Get-Process -Id $PID).Path })
    $winPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path $winPs) { $Shells += @{ Shell = 'Windows PowerShell 5.1'; Exe = $winPs } }

    # non-ASCII text is built from code points, so that this file reads the same in any PowerShell
    $umlauts = "$([char]0xDC)n$([char]0xEF)code"
    $cyrillic = -join ([char[]](0x432, 0x435, 0x442, 0x43A, 0x430))
    $BranchLabels = @(
        @{ Name = 'develop'; Label = 'develop' }
        @{ Name = 'main'; Label = 'main' }
        @{ Name = 'feature/Fix_Path'; Label = 'fix-path' }
        @{ Name = 'bugfix/JIRA-12/Long Name Here!'; Label = 'long-name-here' }
        @{ Name = 'release/1.2'; Label = '1-2' }
        @{ Name = '2024'; Label = 'b2024' }
        @{ Name = 'users/dk/009'; Label = 'b009' }
        @{ Name = '///'; Label = 'branch' }
        @{ Name = ''; Label = 'branch' }
        @{ Name = 'fix/a--b'; Label = 'a-b' }
        @{ Name = 'feature/--x--'; Label = 'x' }
        @{ Name = 'a_very_long_branch_name_that_goes_on_and_on'; Label = 'a-very-long-branch-n' }
        @{ Name = $umlauts; Label = 'n-code' }
        @{ Name = "x/$cyrillic"; Label = 'branch' }
    )
    $BadVersionFiles = @('1', '1.2.3', '01.2', 'a.b', '1.2-rc', '')
    # edits of the version file that keep MAJOR.MINOR
    $Edits = @(
        @{ Name = 'a comment'; Comment = "  <!-- a comment -->`n"; Indent = '    ' }
        @{ Name = 'a comment that quotes the line'; Comment = "  <!-- <VersionPrefix>0.1</VersionPrefix> -->`n"; Indent = '    ' }
        @{ Name = 'a new indent of the line'; Comment = ''; Indent = '        ' }
    )
}

BeforeAll {
    $script:Repo = Split-Path -Parent $PSScriptRoot
    $script:Script = Join-Path $script:Repo 'get-version.ps1'
    $script:Module = Join-Path $script:Repo 'Wslbin.Version.psm1'
    $script:Work = Join-Path ([IO.Path]::GetTempPath()) ('wslbin-version-tests-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:Work | Out-Null
    # the functions below are called from several scopes, so the folder lives in a global variable
    $global:VersionTestWork = $script:Work

    $script:SavedGitEnv = @{}
    foreach ($name in 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_OBJECT_DIRECTORY', 'GIT_NAMESPACE', 'GIT_COMMON_DIR', 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_NOSYSTEM',
        'GIT_CONFIG_PARAMETERS', 'GIT_CONFIG_COUNT', 'HOME', 'XDG_CONFIG_HOME',
        'GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_AUTHOR_DATE', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL', 'GIT_COMMITTER_DATE') {
        # (a $null given to a .NET method becomes an empty string: an empty GIT_DIR is not the same as none)
        $script:SavedGitEnv[$name] = [Environment]::GetEnvironmentVariable($name)
        Remove-Item -Path "Env:\$name" -ErrorAction SilentlyContinue
    }
    $env:GIT_CONFIG_NOSYSTEM = '1'
    $env:GIT_CONFIG_GLOBAL = Join-Path $script:Work 'no-global-gitconfig'
    # a home folder with nothing in it: no ~/.config/git/ignore or attributes of the person who runs the tests
    $env:HOME = Join-Path $script:Work 'home'
    $env:XDG_CONFIG_HOME = Join-Path $script:Work 'home\xdg'

    Import-Module $script:Module -Force -DisableNameChecking

    # the official regular expression of semver.org (2.0.0)
    $script:SemVer = '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$'

    # Precedence of SemVer 2.0 (build metadata is ignored): -1, 0 or 1.
    function Compare-SemVer([string]$A, [string]$B) {
        $pa = ($A -split '\+')[0]; $pb = ($B -split '\+')[0]
        $ca, $ra = $pa -split '-', 2; $cb, $rb = $pb -split '-', 2
        $na = @($ca -split '\.' | ForEach-Object { [int]$_ }); $nb = @($cb -split '\.' | ForEach-Object { [int]$_ })
        for ($i = 0; $i -lt 3; $i++) { if ($na[$i] -ne $nb[$i]) { return [Math]::Sign($na[$i] - $nb[$i]) } }
        if (-not $ra -and -not $rb) { return 0 }
        if (-not $ra) { return 1 }
        if (-not $rb) { return -1 }
        $ia = $ra -split '\.'; $ib = $rb -split '\.'
        for ($i = 0; $i -lt [Math]::Min($ia.Count, $ib.Count); $i++) {
            $x = $ia[$i]; $y = $ib[$i]
            $xn = $x -match '^\d+$'; $yn = $y -match '^\d+$'
            if ($xn -and $yn) { if ([int64]$x -ne [int64]$y) { return [Math]::Sign([int64]$x - [int64]$y) } }
            elseif ($xn) { return -1 }
            elseif ($yn) { return 1 }
            else { $c = [string]::CompareOrdinal($x, $y); if ($c -ne 0) { return [Math]::Sign($c) } }
        }
        return [Math]::Sign($ia.Count - $ib.Count)
    }

    function Invoke-FixtureGit {
        param([string]$Dir, [string[]]$Arguments)
        $psi = [Diagnostics.ProcessStartInfo]::new('git')
        $all = @('-C', $Dir, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgsign=false', '-c', 'core.autocrlf=false') + $Arguments
        foreach ($a in $all) { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = [Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd()
        $err = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        if ($p.ExitCode -ne 0) { throw "git $($Arguments -join ' ') failed: $err" }
        $out.Trim()
    }

    function Set-VersionFile {
        param([string]$Dir, [string]$Value, [string]$Comment = '', [string]$Indent = '    ')
        $text = "<Project>`n$Comment  <PropertyGroup>`n$Indent<VersionPrefix>$Value</VersionPrefix>`n  </PropertyGroup>`n</Project>`n"
        [IO.File]::WriteAllText((Join-Path $Dir 'wslbin.csproj'), $text, [Text.UTF8Encoding]::new($false))
    }

    # a repository whose first commit introduces the version file; more commits are added with Add-FixtureCommits
    function New-VersionRepo {
        param([string]$Value = '0.1', [switch]$NoCommit, [string]$Name = '')
        if (-not $Name) { $Name = 'vrepo-' + [guid]::NewGuid().ToString('N') }
        $dir = Join-Path $global:VersionTestWork $Name
        New-Item -ItemType Directory -Path $dir | Out-Null
        $null = Invoke-FixtureGit $dir @('init', '-q', '-b', 'main')
        Set-VersionFile $dir $Value
        if ($NoCommit) { $null = Invoke-FixtureGit $dir @('commit', '-q', '--allow-empty', '-m', 'nothing') }
        else {
            $null = Invoke-FixtureGit $dir @('add', 'wslbin.csproj')
            $null = Invoke-FixtureGit $dir @('commit', '-q', '-m', 'version file')
        }
        $dir
    }

    # Empty commits; with the same parent, message, author and second two of them are one and the same
    # commit, so the commits of different branches get different messages (-Prefix).
    function Add-FixtureCommits {
        param([string]$Dir, [int]$Count, [string]$Prefix = 'commit')
        for ($i = 1; $i -le $Count; $i++) { $null = Invoke-FixtureGit $Dir @('commit', '-q', '--allow-empty', '-m', "$Prefix $i") }
    }

    function Save-VersionFile {
        param([string]$Dir, [string]$Message)
        $null = Invoke-FixtureGit $Dir @('add', 'wslbin.csproj')
        $null = Invoke-FixtureGit $Dir @('commit', '-q', '-m', $Message)
    }

    function Get-Sha7 {
        param([string]$Dir, [string]$Rev = 'HEAD')
        Invoke-FixtureGit $Dir @('rev-parse', '--short=7', $Rev)
    }

    # get-version.ps1 as a program of its own: stdout, stderr and the exit code
    function Invoke-GetVersion {
        param([string]$Exe, [string[]]$Arguments, [string]$ScriptPath = $script:Script, [string]$WorkingDirectory = '')
        $psi = [Diagnostics.ProcessStartInfo]::new($Exe)
        foreach ($a in '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) { $psi.ArgumentList.Add($a) }
        foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
        if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
        # Windows PowerShell started from PowerShell 7 with its module path cannot load its own modules
        $null = $psi.Environment.Remove('PSModulePath')
        $p = [Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd()
        $err = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        @{ Out = $out.Trim(); Err = $err.Trim(); ExitCode = $p.ExitCode }
    }

    # shared by the read-only tests: 0.1 introduced, then three commits (patch 3 at the head)
    $script:A = New-VersionRepo
    $script:AIntro = Invoke-FixtureGit $script:A @('rev-parse', 'HEAD')
    Add-FixtureCommits $script:A 3
    $script:ASha = Get-Sha7 $script:A
}

AfterAll {
    foreach ($name in $script:SavedGitEnv.Keys) {
        if ($null -eq $script:SavedGitEnv[$name]) { Remove-Item -Path "Env:\$name" -ErrorAction SilentlyContinue }
        else { Set-Item -Path "Env:\$name" -Value $script:SavedGitEnv[$name] }
    }
    Remove-Module Wslbin.Version -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $script:Work -ErrorAction SilentlyContinue
    Remove-Variable VersionTestWork -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Get-BranchLabel' {
    It "turns '<Name>' into '<Label>'" -ForEach $BranchLabels {
        Get-BranchLabel $Name | Should -BeExactly $Label
    }

    It 'gives a label that is a valid SemVer identifier for any branch name' {
        $rng = [Random]::new(20261022)
        $pieces = @('a', 'Z', 'q', '0', '7', '/', '/', '_', ' ', '-', '-', '.', '!', '+', '@', '#', 'x/', 'feature/',
            [string][char]0xE9, -join ([char[]](0x432, 0x435)), [char]::ConvertFromUtf32(0x1F600), "`t")
        $bad = @()
        $empty = 0
        for ($i = 0; $i -lt 500; $i++) {
            $length = $rng.Next(0, 24)
            $name = ''
            for ($k = 0; $k -lt $length; $k++) { $name += $pieces[$rng.Next($pieces.Count)] }
            if ($name -eq '') { $empty++ }
            $label = Get-BranchLabel $name
            $ok = $label -cmatch '^[0-9a-z-]{1,20}$' -and $label -notmatch '^-|-$|--' -and $label -notmatch '^[0-9]+$'
            if (-not $ok) { $bad += "'$name' -> '$label'" }
        }
        $bad | Should -BeNullOrEmpty
        $empty | Should -BeGreaterThan 0   # the empty name is among what was tried
    }
}

Describe 'Get-WslbinVersion' {
    Context 'PATCH counts commits from the commit where MAJOR.MINOR first appeared' {
        It 'is 0 at the commit that introduced the version file' {
            Get-WslbinVersion -Repo $script:A -Kind release -Commit $script:AIntro | Should -BeExactly '0.1.0'
        }
        It 'is one more for every later commit' {
            Get-WslbinVersion -Repo $script:A -Kind release | Should -BeExactly '0.1.3'
            Get-WslbinVersion -Repo $script:A -Kind release -Commit 'HEAD~1' | Should -BeExactly '0.1.2'
        }
        It 'starts again from 0 when MAJOR.MINOR is raised, and an older commit keeps its own version' {
            $b = New-VersionRepo '0.1'
            Add-FixtureCommits $b 2
            Set-VersionFile $b '0.2'
            Save-VersionFile $b 'raise the version'
            $bump = Invoke-FixtureGit $b @('rev-parse', 'HEAD')
            Add-FixtureCommits $b 2
            Get-WslbinVersion -Repo $b -Kind release -Commit 'HEAD~3' | Should -BeExactly '0.1.2'
            Get-WslbinVersion -Repo $b -Kind release -Commit $bump | Should -BeExactly '0.2.0'
            Get-WslbinVersion -Repo $b -Kind release | Should -BeExactly '0.2.2'
        }
        It 'is not reset by an edit of the version file that keeps MAJOR.MINOR: <Name>' -ForEach $Edits {
            $c = New-VersionRepo '0.1'
            Add-FixtureCommits $c 2
            Set-VersionFile $c '0.1' -Comment $Comment -Indent $Indent
            Save-VersionFile $c 'an edit that keeps the value'
            Add-FixtureCommits $c 1
            Get-WslbinVersion -Repo $c -Kind release | Should -BeExactly '0.1.4'
        }
        It 'finds the first commit by the history, not by the dates (two branches, one clock that was wrong)' {
            $k = New-VersionRepo '0.1'
            $null = Invoke-FixtureGit $k @('switch', '-q', '-c', 'side')
            Set-VersionFile $k '0.1' -Comment "  <!-- <VersionPrefix>0.1</VersionPrefix> -->`n"
            Save-VersionFile $k 'a comment that quotes the line, on a branch'
            $null = Invoke-FixtureGit $k @('switch', '-q', 'main')
            Set-VersionFile $k '0.1' -Indent '        '
            $env:GIT_COMMITTER_DATE = '2001-01-01T00:00:00'
            try { Save-VersionFile $k 'a new indent, dated long ago' }
            finally { Remove-Item -Path 'Env:\GIT_COMMITTER_DATE' -ErrorAction SilentlyContinue }
            $null = Invoke-FixtureGit $k @('merge', '-q', '--no-ff', '--no-edit', 'side')
            # the two edits and the merge itself; both edits touch the line, and the older-dated one must not become the base
            Get-WslbinVersion -Repo $k -Kind release | Should -BeExactly '0.1.3'
        }
        It 'keeps growing when MAJOR.MINOR goes back to an old value' {
            $r = New-VersionRepo '0.1'
            Add-FixtureCommits $r 2
            Set-VersionFile $r '0.2'
            Save-VersionFile $r 'raise'
            Add-FixtureCommits $r 1
            Get-WslbinVersion -Repo $r -Kind release | Should -BeExactly '0.2.1'
            Set-VersionFile $r '0.1'
            Save-VersionFile $r 'go back'
            Add-FixtureCommits $r 1
            # counted from where 0.1 first appeared, so no 0.1.N of the first time comes again
            Get-WslbinVersion -Repo $r -Kind release | Should -BeExactly '0.1.6'
        }
        It 'counts the commits of a merged branch too' {
            $m = New-VersionRepo '0.1'
            Add-FixtureCommits $m 1
            $null = Invoke-FixtureGit $m @('switch', '-q', '-c', 'feature')
            Add-FixtureCommits $m 2 -Prefix 'feature'
            $null = Invoke-FixtureGit $m @('switch', '-q', 'main')
            Add-FixtureCommits $m 1 -Prefix 'main'
            $null = Invoke-FixtureGit $m @('merge', '-q', '--no-ff', '--no-edit', 'feature')
            # c1 and the commit on main, two on the branch, and the merge itself
            Get-WslbinVersion -Repo $m -Kind release | Should -BeExactly '0.1.5'
        }
        It 'counts from a merge that brings a new value in by resolving a conflict (git log -G looks at no merge by itself)' {
            $g = New-VersionRepo '0.1'
            $null = Invoke-FixtureGit $g @('switch', '-q', '-c', 'side')
            Set-VersionFile $g '0.2'
            Save-VersionFile $g 'side raises to 0.2'
            $null = Invoke-FixtureGit $g @('switch', '-q', 'main')
            Set-VersionFile $g '0.3'
            Save-VersionFile $g 'main raises to 0.3'
            # the merge stops at the conflict on the line, which is resolved to a value that neither branch had
            try { $null = Invoke-FixtureGit $g @('merge', '-q', '--no-edit', 'side') } catch { }
            Set-VersionFile $g '0.4'
            Save-VersionFile $g 'merge side, resolved to 0.4'
            Get-WslbinVersion -Repo $g -Kind release | Should -BeExactly '0.4.0'
            Add-FixtureCommits $g 1
            Get-WslbinVersion -Repo $g -Kind release | Should -BeExactly '0.4.1'
        }
        It 'counts from the first commit also when git is set not to show the root commit (log.showRoot)' {
            $s = New-VersionRepo '0.1'
            Add-FixtureCommits $s 2
            $null = Invoke-FixtureGit $s @('config', 'log.showRoot', 'false')
            Get-WslbinVersion -Repo $s -Kind release | Should -BeExactly '0.1.2'
        }
    }

    Context 'what the build adds' {
        It 'a push to a branch: -<branch>.<run>+<commit>' {
            Get-WslbinVersion -Repo $script:A -Kind branch -Branch 'develop' -Run 42 | Should -BeExactly "0.1.3-develop.42+$($script:ASha)"
        }
        It 'names the branch by what follows the last slash' {
            Get-WslbinVersion -Repo $script:A -Kind branch -Branch 'feature/Fix_Path' -Run 43 | Should -BeExactly "0.1.3-fix-path.43+$($script:ASha)"
        }
        It 'a pull request: -pr<number>.<run>+<commit>' {
            Get-WslbinVersion -Repo $script:A -Kind pr -PullRequest 7 -Run 45 | Should -BeExactly "0.1.3-pr7.45+$($script:ASha)"
        }
        It 'builds the commit that is asked for, and names that commit' {
            $sha = Get-Sha7 $script:A 'HEAD~2'
            Get-WslbinVersion -Repo $script:A -Kind branch -Branch 'develop' -Run 1 -Commit 'HEAD~2' | Should -BeExactly "0.1.1-develop.1+$sha"
        }
        It 'a release has no suffix' {
            Get-WslbinVersion -Repo $script:A -Kind release | Should -BeExactly '0.1.3'
        }
        It 'every build of a commit is lower than the release of that commit, and higher than the release before it' {
            $release = Get-WslbinVersion -Repo $script:A -Kind release
            $before = Get-WslbinVersion -Repo $script:A -Kind release -Commit 'HEAD~1'
            $builds = @(
                (Get-WslbinVersion -Repo $script:A -Kind branch -Branch 'develop' -Run 9),
                (Get-WslbinVersion -Repo $script:A -Kind branch -Branch 'main' -Run 10),
                (Get-WslbinVersion -Repo $script:A -Kind pr -PullRequest 3 -Run 11),
                (Get-WslbinVersion -Repo $script:A -Kind local))
            $builds.Count | Should -Be 4
            foreach ($b in $builds) {
                $b | Should -Match $script:SemVer
                Compare-SemVer $b $release | Should -Be -1
                Compare-SemVer $b $before | Should -Be 1
            }
            Compare-SemVer $release $before | Should -Be 1
        }
        It 'a raise of MAJOR.MINOR is higher than every version before it' {
            $r = New-VersionRepo '0.1'
            Add-FixtureCommits $r 4
            $old = Get-WslbinVersion -Repo $r -Kind branch -Branch 'develop' -Run 5
            Set-VersionFile $r '0.2'
            Save-VersionFile $r 'raise'
            Compare-SemVer (Get-WslbinVersion -Repo $r -Kind release) $old | Should -Be 1
        }
    }

    Context 'a build on a machine (-local)' {
        It 'is -local+<commit>' {
            Get-WslbinVersion -Repo $script:A -Kind local | Should -BeExactly "0.1.3-local+$($script:ASha)"
        }
        It 'has .dirty when something is not committed, also when git is set not to show untracked files' {
            $d = New-VersionRepo
            Add-FixtureCommits $d 1
            $null = Invoke-FixtureGit $d @('config', 'status.showUntrackedFiles', 'no')
            Set-Content -Path (Join-Path $d 'new.txt') -Value 'not committed'
            Get-WslbinVersion -Repo $d -Kind local | Should -BeExactly "0.1.1-local+$(Get-Sha7 $d).dirty"
        }
        It 'has no .dirty for a commit that is not HEAD: the working tree is not what that commit built' {
            $d = New-VersionRepo
            Add-FixtureCommits $d 2
            Set-Content -Path (Join-Path $d 'new.txt') -Value 'not committed'
            Get-WslbinVersion -Repo $d -Kind local -Commit 'HEAD~1' | Should -BeExactly "0.1.1-local+$(Get-Sha7 $d 'HEAD~1')"
        }
        It 'reads MAJOR.MINOR from the working tree: a raise that is not committed yet starts at 0' {
            $r = New-VersionRepo '0.1'
            Add-FixtureCommits $r 2
            Set-VersionFile $r '0.2'
            Get-WslbinVersion -Repo $r -Kind local | Should -BeExactly "0.2.0-local+$(Get-Sha7 $r).dirty"
            # a release is of the commit: the raise is not in it
            Get-WslbinVersion -Repo $r -Kind release | Should -BeExactly '0.1.2'
        }
        It 'works before the version file is committed' {
            $r = New-VersionRepo -NoCommit
            Get-WslbinVersion -Repo $r -Kind local | Should -BeExactly "0.1.0-local+$(Get-Sha7 $r).dirty"
        }
    }

    Context 'where the folder is' {
        It 'takes a relative -Repo relative to the location of PowerShell' {
            Push-Location $script:A
            try { Get-WslbinVersion -Repo . -Kind release | Should -BeExactly '0.1.3' }
            finally { Pop-Location }
        }
        It 'takes a folder with a space in its name and a trailing backslash' {
            $s = New-VersionRepo -Name 'with a space'
            Add-FixtureCommits $s 1
            Get-WslbinVersion -Repo "$s\" -Kind release | Should -BeExactly '0.1.1'
        }
        It 'reads a version file that has a byte order mark' {
            $bom = New-VersionRepo
            $text = [IO.File]::ReadAllText((Join-Path $bom 'wslbin.csproj'))
            [IO.File]::WriteAllText((Join-Path $bom 'wslbin.csproj'), $text, [Text.UTF8Encoding]::new($true))
            Save-VersionFile $bom 'a version file with a byte order mark'
            Get-WslbinVersion -Repo $bom -Kind release | Should -BeExactly '0.1.1'
            Get-WslbinVersion -Repo $bom -Kind local | Should -Match '^0\.1\.1-local\+'
        }
    }

    Context 'what it refuses' {
        It 'a branch build without a branch or a run number' {
            { Get-WslbinVersion -Repo $script:A -Kind branch -Run 1 } | Should -Throw '*-Branch*'
            { Get-WslbinVersion -Repo $script:A -Kind branch -Branch 'x' } | Should -Throw '*-Run*'
        }
        It 'a pull request build without a number or a run number' {
            { Get-WslbinVersion -Repo $script:A -Kind pr -Run 1 } | Should -Throw '*-PullRequest*'
            { Get-WslbinVersion -Repo $script:A -Kind pr -PullRequest 7 } | Should -Throw '*-Run*'
        }
        It "a version file that says '<_>' instead of MAJOR.MINOR" -ForEach $BadVersionFiles {
            $r = New-VersionRepo $_
            { Get-WslbinVersion -Repo $r -Kind release } | Should -Throw "*is '$_', but it must be MAJOR.MINOR*"
        }
        It 'a folder without the version file' {
            $empty = Join-Path $script:Work ('empty-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $empty | Out-Null
            { Get-WslbinVersion -Repo $empty -Kind local } | Should -Throw '*wslbin.csproj*is not in*'
        }
        It 'a <Kind> build while the version file is not committed yet' -ForEach @(
            @{ Kind = 'release'; Extra = @{} }
            @{ Kind = 'branch'; Extra = @{ Branch = 'develop'; Run = 1 } }
            @{ Kind = 'pr'; Extra = @{ PullRequest = 1; Run = 1 } }
        ) {
            $r = New-VersionRepo -NoCommit
            { Get-WslbinVersion -Repo $r -Kind $Kind @Extra } | Should -Throw '*is not committed yet: it is not in HEAD*'
        }
        It 'a VersionPrefix that is not a line of its own: <Name>' -ForEach @(
            @{ Name = 'it has an attribute'; Text = "<Project>`n  <PropertyGroup>`n    <VersionPrefix Condition=`"'x' == 'x'`">0.1</VersionPrefix>`n  </PropertyGroup>`n</Project>`n" }
            @{ Name = 'it is split in lines'; Text = "<Project>`n  <PropertyGroup>`n    <VersionPrefix>`n      0.1`n    </VersionPrefix>`n  </PropertyGroup>`n</Project>`n" }
        ) {
            $r = New-VersionRepo
            [IO.File]::WriteAllText((Join-Path $r 'wslbin.csproj'), $Text, [Text.UTF8Encoding]::new($false))
            Save-VersionFile $r 'a version file in another form'
            { Get-WslbinVersion -Repo $r -Kind release } | Should -Throw '*a line of its own*'
        }
        It 'a shallow clone, and says how to get the whole history' {
            $url = 'file:///' + ($script:A -replace '\\', '/')
            $clone = Join-Path $script:Work ('shallow-' + [guid]::NewGuid().ToString('N'))
            $null = Invoke-FixtureGit $script:Work @('clone', '-q', '--depth', '1', $url, $clone)
            { Get-WslbinVersion -Repo $clone -Kind release } | Should -Throw '*fetch-depth*'
        }
        It 'a commit that is an option of git, and writes nothing' {
            $target = Join-Path $script:Work 'written-by-an-option.txt'
            { Get-WslbinVersion -Repo $script:A -Kind release -Commit "--output=$target" } | Should -Throw "*is not a commit*"
            Test-Path $target | Should -BeFalse
        }
        It 'a commit that does not exist' {
            { Get-WslbinVersion -Repo $script:A -Kind release -Commit 'no-such-branch' } | Should -Throw "*'no-such-branch' is not a commit*"
        }
    }

    Context 'in a git worktree (.git is a file)' {
        BeforeAll {
            $script:Worktree = Join-Path $script:Work ('wt-' + [guid]::NewGuid().ToString('N'))
            $null = Invoke-FixtureGit $script:A @('worktree', 'add', '-q', '--detach', $script:Worktree, 'HEAD')
        }
        It 'gives the version of the commit that is checked out' {
            Get-WslbinVersion -Repo $script:Worktree -Kind release | Should -BeExactly '0.1.3'
            Get-WslbinVersion -Repo $script:Worktree -Kind branch -Branch 'develop' -Run 1 | Should -BeExactly "0.1.3-develop.1+$($script:ASha)"
        }
    }

    Context 'without git history (a source archive, or a checkout without git)' {
        BeforeAll {
            $script:Plain = Join-Path $script:Work ('plain-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $script:Plain | Out-Null
            Set-VersionFile $script:Plain '0.1'
        }
        It 'a build on a machine says -nogit: PATCH is unknown' {
            Get-WslbinVersion -Repo $script:Plain -Kind local | Should -BeExactly '0.1.0-nogit'
        }
        It 'ignores a file called VERSION' {
            [IO.File]::WriteAllText((Join-Path $script:Plain 'VERSION'), "9.9.9`n", [Text.UTF8Encoding]::new($false))
            Get-WslbinVersion -Repo $script:Plain -Kind local | Should -BeExactly '0.1.0-nogit'
        }
        It 'refuses a <Kind> build: two builds would have the same version' -ForEach @(
            @{ Kind = 'release'; Extra = @{} }
            @{ Kind = 'branch'; Extra = @{ Branch = 'develop'; Run = 1 } }
            @{ Kind = 'pr'; Extra = @{ PullRequest = 1; Run = 1 } }
        ) {
            { Get-WslbinVersion -Repo $script:Plain -Kind $Kind @Extra } | Should -Throw '*needs the git history*'
        }
    }
}

Describe 'get-version.ps1 as a program (<Shell>)' -ForEach $Shells {
    It 'prints the version and nothing else' {
        $r = Invoke-GetVersion $Exe @('-Repo', $script:A, '-Kind', 'branch', '-Branch', 'feature/Fix_Path', '-Run', '43')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -BeExactly "0.1.3-fix-path.43+$($script:ASha)"
        $r.Err | Should -BeNullOrEmpty
    }
    It 'defaults to the folder of the script, and to a local build' {
        $d = New-VersionRepo
        Add-FixtureCommits $d 2
        Copy-Item $script:Script (Join-Path $d 'get-version.ps1')
        Copy-Item $script:Module (Join-Path $d 'Wslbin.Version.psm1')
        $r = Invoke-GetVersion $Exe @() -ScriptPath (Join-Path $d 'get-version.ps1')
        $r.ExitCode | Should -Be 0
        # the copies of the script are themselves changes that are not committed
        $r.Out | Should -BeExactly "0.1.2-local+$(Get-Sha7 $d).dirty"
    }
    It 'takes a relative folder, and a folder with a space and a trailing backslash' {
        $s = New-VersionRepo -Name ('with a space ' + $Shell.Substring(0, 3))
        Add-FixtureCommits $s 1
        (Invoke-GetVersion $Exe @('-Repo', '.', '-Kind', 'release') -WorkingDirectory $s).Out | Should -BeExactly '0.1.1'
        (Invoke-GetVersion $Exe @('-Repo', "$s\", '-Kind', 'release')).Out | Should -BeExactly '0.1.1'
    }
    It 'prints nothing and exits with an error when the version file is wrong' {
        $bad = New-VersionRepo '1.2.3'
        $r = Invoke-GetVersion $Exe @('-Repo', $bad)
        $r.ExitCode | Should -Not -Be 0
        $r.Out | Should -BeNullOrEmpty
        $r.Err | Should -Match "'1\.2\.3'"
    }
}

Describe 'Test-SemVer' {
    It 'says <Answer> for <Name>' -ForEach @(
        @{ Name = 'a release'; Text = '1.2.3'; Answer = $true }
        @{ Name = 'a version with a prerelease and metadata'; Text = '1.2.3-develop.42+33c8830'; Answer = $true }
        @{ Name = 'a version that ends with a line break'; Text = "1.2.3`n"; Answer = $false }
        @{ Name = 'two parts only'; Text = '1.2'; Answer = $false }
        @{ Name = 'a leading zero'; Text = '01.2.3'; Answer = $false }
    ) {
        Test-SemVer $Text | Should -Be $Answer
    }
}

Describe 'Get-MajorMinor' {
    # the module is entered to reach what it does not export
    It 'reads the version of a text that has <Name> before the first tag' -ForEach @(
        @{ Name = 'nothing'; Prefix = '' }
        @{ Name = 'a byte order mark'; Prefix = ([string][char]0xFEFF) }
        @{ Name = 'what a DOS code page makes of a byte order mark'; Prefix = (-join ([char[]](0x2229, 0x2557, 0x2510))) }
    ) {
        $text = $Prefix + "<Project>`n  <PropertyGroup>`n    <VersionPrefix>1.4</VersionPrefix>`n  </PropertyGroup>`n</Project>`n"
        # (the module of this repository: another copy of it may be loaded in the same session)
        $module = @(Get-Module Wslbin.Version | Where-Object { $_.Path -eq $script:Module })[0]
        & $module { param($t) Get-MajorMinor $t } $text | Should -BeExactly '1.4'
    }
}
