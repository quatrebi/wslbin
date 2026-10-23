<#
.SYNOPSIS
    The version of a build of wslbin, as SemVer 2.0 (https://semver.org), and nothing else on stdout.

.DESCRIPTION
    MAJOR.MINOR is VersionPrefix in wslbin.csproj: a pull request raises it. PATCH is the number of
    commits that lead to the built commit and not to the commit where that MAJOR.MINOR first appeared
    (the commits of a merged branch count too), so it needs the whole history. The rest says where the
    build comes from, so that builds of different branches never have the same version:

        release   0.1.3                          a release (made from main)
        branch    0.1.3-fix-path.43+1a2b3c4      a push: -<branch>.<run number>+<commit>
        pr        0.1.3-pr7.45+1a2b3c4           a pull request: -pr<number>.<run number>+<commit>
        local     0.1.3-local+1a2b3c4            a build on a machine; .dirty after the commit when the
                                                 tree has changes that are not committed

    The branch is named by what follows its last slash (feature/Fix_Path is fix-path): lower case,
    [0-9a-z-], at most 20 characters. The run number is the one of the CI, which counts for all branches.
    The build metadata (+commit) does not count in the order of versions, the rest does:
    0.1.3-fix-path.43 is lower than the release 0.1.3 of the same commit.

    A local build is of the working tree, so it takes MAJOR.MINOR from the file as it is, even when the
    raise is not committed yet; every other build is of the commit and takes it from there.

    Without git history (a source archive, which has no .git) PATCH is unknown: a local build is
    MAJOR.MINOR.0-nogit, and the other kinds are refused.

.PARAMETER Repo
    The folder with wslbin.csproj. Default: the folder of this script.
.PARAMETER Kind
    release, branch, pr or local (the default).
.PARAMETER Branch
    The name of the branch, for -Kind branch.
.PARAMETER PullRequest
    The number of the pull request, for -Kind pr.
.PARAMETER Run
    The run number of the CI, for -Kind branch and pr.
.PARAMETER Commit
    The commit that is built. Default: HEAD.
#>
param(
    [string]$Repo = $PSScriptRoot,
    [ValidateSet('local', 'branch', 'pr', 'release')][string]$Kind = 'local',
    [string]$Branch,
    [long]$PullRequest = 0,
    [long]$Run = 0,
    [string]$Commit = 'HEAD'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Wslbin.Version.psm1') -Force -DisableNameChecking

Get-WslbinVersion -Repo $Repo -Kind $Kind -Branch $Branch -PullRequest $PullRequest -Run $Run -Commit $Commit
