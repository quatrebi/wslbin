# The functions that work out the version of a build of wslbin. get-version.ps1 is the command line of
# them and says what the rules are. This is a module, not a script that is dot-sourced, so that nothing
# of it (parameters, $ErrorActionPreference) leaks into the scope of whoever uses it.
# Works in Windows PowerShell 5.1 and PowerShell 7.

# the regular expression of semver.org (2.0.0), with [0-9] for \d (which in .NET takes the digits of
# every script); the same line is in setup\common.ps1 and site\install.ps1, which cannot import this
# module (they are in the package and on the site), and a test sees that the three are the same
$script:SemVerPattern = '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-((?:0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?\z'

function Test-SemVer {
    param([string]$Version)
    return [regex]::IsMatch($Version, $script:SemVerPattern)
}

# A branch name as one SemVer identifier: what follows the last '/', lower case, [0-9a-z-] only, at
# most 20 characters, never empty, never made of digits only (it would be a number, and 009 is not one).
function Get-BranchLabel {
    param([string]$Name)
    $label = ($Name -split '/')[-1].ToLowerInvariant()
    $label = [regex]::Replace($label, '[^0-9a-z-]+', '-')
    $label = [regex]::Replace($label, '-{2,}', '-').Trim('-')
    if ($label.Length -gt 20) { $label = $label.Substring(0, 20).Trim('-') }
    if ($label -eq '') { return 'branch' }
    if ($label -match '^[0-9]+$') { $label = 'b' + $label.Substring(0, [Math]::Min($label.Length, 19)) }
    return $label
}

# VersionPrefix in the text of wslbin.csproj: MAJOR.MINOR.
function Get-MajorMinor {
    param([string]$ProjectText)
    # whatever stands before the first '<' is not XML: a byte order mark, or what a console code page made of it
    $start = $ProjectText.IndexOf('<')
    if ($start -gt 0) { $ProjectText = $ProjectText.Substring($start) }
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $reader = [System.Xml.XmlReader]::Create((New-Object System.IO.StringReader($ProjectText)), $settings)
    try {
        $xml = New-Object System.Xml.XmlDocument
        $xml.Load($reader)
    }
    finally { $reader.Dispose() }
    $nodes = @($xml.SelectNodes("//*[local-name()='VersionPrefix']"))
    if ($nodes.Count -ne 1) {
        throw 'wslbin.csproj must have exactly one VersionPrefix, and it must be MAJOR.MINOR (for example 0.1).'
    }
    $value = $nodes[0].InnerText.Trim()
    if ($value -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
        throw "VersionPrefix in wslbin.csproj is '$value', but it must be MAJOR.MINOR (for example 0.1): PATCH is counted from git."
    }
    # PATCH is found by searching the history for this very line
    if ($ProjectText -notmatch '(?m)^[ \t]*<VersionPrefix>[^<\r\n]*</VersionPrefix>[ \t]*\r?$') {
        throw 'VersionPrefix in wslbin.csproj must be a line of its own, <VersionPrefix>MAJOR.MINOR</VersionPrefix>, with no attributes and no line breaks inside.'
    }
    return $value
}

# Runs git in $Repo. A failure is a result (Code, Err), not an exception.
function Invoke-Git {
    param([string]$Repo, [string[]]$Arguments)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $all = @(& git -C $Repo @Arguments 2>&1)
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $old }
    $out = @($all | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    $err = @($all | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() })
    return [pscustomobject]@{ Code = $code; Out = ($out -join "`n").Trim(); Err = ($err -join "`n").Trim() }
}

function Get-WslbinVersion {
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [ValidateSet('local', 'branch', 'pr', 'release')][string]$Kind = 'local',
        [string]$Branch,
        [long]$PullRequest = 0,
        [long]$Run = 0,
        [string]$Commit = 'HEAD'
    )

    if ($Kind -eq 'branch' -and -not $Branch) { throw '-Kind branch needs -Branch (the name of the branch).' }
    if ($Kind -eq 'pr' -and $PullRequest -lt 1) { throw '-Kind pr needs -PullRequest (the number of the pull request).' }
    if (($Kind -eq 'branch' -or $Kind -eq 'pr') -and $Run -lt 1) { throw "-Kind $Kind needs -Run (the run number of the CI)." }

    # one full path, with no trailing separator: relative to the location of PowerShell, which is what
    # a person means, and the same for Test-Path, the .NET file calls and git
    $Repo = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Repo)
    if ($Repo.Length -gt 3) { $Repo = $Repo.TrimEnd('\', '/') }

    $projectFile = Join-Path $Repo 'wslbin.csproj'
    $hasGit = (Test-Path -LiteralPath (Join-Path $Repo '.git')) -and [bool](Get-Command git -ErrorAction SilentlyContinue)
    if (-not $hasGit) {
        if ($Kind -ne 'local') {
            throw "A $Kind build needs the git history of the repository: $Repo has no .git, or git is not installed. Its PATCH is counted from the commits."
        }
        if (-not (Test-Path -LiteralPath $projectFile)) {
            throw "wslbin.csproj, which holds MAJOR.MINOR of the version, is not in $Repo."
        }
        return "$(Get-MajorMinor ([System.IO.File]::ReadAllText($projectFile))).0-nogit"
    }

    if ((Invoke-Git $Repo @('rev-parse', '--is-shallow-repository')).Out -eq 'true') {
        throw 'This is a shallow clone, and PATCH is counted from the history. Fetch all of it: git fetch --unshallow (in GitHub Actions: fetch-depth: 0 for actions/checkout).'
    }
    $full = Invoke-Git $Repo @('rev-parse', '--verify', '--quiet', "$Commit^{commit}")
    if ($full.Code -ne 0) { throw "'$Commit' is not a commit of ${Repo}: $($full.Err)" }
    $sha = (Invoke-Git $Repo @('rev-parse', '--short=7', $full.Out)).Out
    $isHead = ((Invoke-Git $Repo @('rev-parse', 'HEAD')).Out -eq $full.Out)

    # MAJOR.MINOR: a build on a machine is of the working tree (what is there is what gets built, and
    # .dirty says it is not committed); every other build is of the commit, not of the folder, which may
    # have been raised since
    $fromTree = ($Kind -eq 'local') -and $isHead -and (Test-Path -LiteralPath $projectFile)
    if ($fromTree) {
        $projectText = [System.IO.File]::ReadAllText($projectFile)
    }
    else {
        $project = Invoke-Git $Repo @('show', "$($full.Out):wslbin.csproj")
        if ($project.Code -ne 0) {
            throw "wslbin.csproj, which holds MAJOR.MINOR of the version, is not committed yet: it is not in $Commit. ($($project.Err))"
        }
        $projectText = $project.Out
    }
    $majorMinor = Get-MajorMinor $projectText

    # The commit where this MAJOR.MINOR first appeared: the OLDEST commit that adds or removes the line.
    # Not the latest: an edit that keeps the value (a new indent, a comment that quotes the line) would
    # send PATCH back to 0, and a release would have a lower version than an earlier one.
    $pattern = '<VersionPrefix>[[:space:]]*' + ($majorMinor -replace '\.', '\.') + '[[:space:]]*</VersionPrefix>'
    # --topo-order: "oldest" is the one furthest up the history, not the one with the oldest date (a clock
    # that was wrong). --diff-merges=first-parent: -G looks at no merge commit by itself, and a merge that
    # resolves a conflict to a new value is where that value appears (git 2.31 or later). The other options
    # keep the git configuration of the person out of the output (log.showRoot=false would hide the first
    # commit's change, so a later commit would be taken for the one that sets the value).
    $found = Invoke-Git $Repo @('-c', 'log.follow=false', '-c', 'log.showRoot=true', 'log', '--reverse', '--topo-order', '--diff-merges=first-parent', '--no-patch', '--no-show-signature', '--format=%H', "-G$pattern", $full.Out, '--', 'wslbin.csproj')
    if ($found.Code -ne 0) { throw "git log failed in ${Repo}: $($found.Err)" }
    $base = ($found.Out -split "`n")[0]
    if (-not $base) {
        if (-not $fromTree) {
            throw "wslbin.csproj with MAJOR.MINOR $majorMinor is not committed yet: PATCH is counted from the commit that sets it."
        }
        $patch = 0
    }
    else {
        # every commit that leads to this one and not to the base; the commits of a merged branch count too
        $count = Invoke-Git $Repo @('rev-list', '--count', "$base..$($full.Out)")
        if ($count.Code -ne 0) { throw "git rev-list failed in ${Repo}: $($count.Err)" }
        $patch = [long]$count.Out
    }

    $core = "$majorMinor.$patch"
    switch ($Kind) {
        'release' { $version = $core }
        'branch' { $version = "$core-$(Get-BranchLabel $Branch).$Run+$sha" }
        'pr' { $version = "$core-pr$PullRequest.$Run+$sha" }
        'local' {
            $version = "$core-local+$sha"
            if ($isHead) {
                $status = Invoke-Git $Repo @('status', '--porcelain', '--untracked-files=normal')
                if ($status.Code -ne 0) { throw "git status failed in ${Repo}: $($status.Err)" }
                if ($status.Out) { $version += '.dirty' }
            }
        }
    }
    if (-not (Test-SemVer $version)) { throw "Internal error: '$version' is not SemVer 2.0." }
    return $version
}

Export-ModuleMember -Function Test-SemVer, Get-BranchLabel, Get-WslbinVersion
