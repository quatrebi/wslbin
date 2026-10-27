# wslbin loader: downloads a release of wslbin, checks it and runs the installer that is in it.
# Served at https://quatrebi.github.io/wslbin/install.ps1. Works in Windows PowerShell 5.1 and in
# PowerShell 7; needs nothing but Windows (no modules, no extra programs).
#
#   irm https://quatrebi.github.io/wslbin/install.ps1 | iex
#
# With parameters (a script block takes them; the same two values can be set in the environment as
# WSLBIN_VERSION and WSLBIN_SCOPE before the line above):
#
#   & ([scriptblock]::Create((irm https://quatrebi.github.io/wslbin/install.ps1))) -Version 0.1.7 -Scope AllUsers
#
# What it does: reads releases.json from the site (the versions, the address and the SHA256 of each zip),
# downloads the zip from GitHub Releases into a temporary folder, checks its SHA256 (the hash comes from
# the site, the file from GitHub: two places), with -VerifyAttestation also the attestation of GitHub (needs
# the gh program), unpacks it (an entry that would leave the folder is refused), runs setup\install.ps1 from
# it in a PowerShell of its own (so that the execution policy of this one does not stop it) and deletes the
# temporary folder. Read this file before you run it: it is short. Everything is in one script block, so
# that "iex" leaves nothing of it in the session (no variables, no functions, no preferences); the exit
# code is in $LASTEXITCODE.
#
#   -Version      0.1.7; the latest when left out
#   -Scope        CurrentUser (the default: no administrator rights) or AllUsers (asks for them)
#   -InstallDir   another folder
#   -Link         utilities to make wrappers for: make,rsync,dig
#   -Completion   pwsh, clink or pwsh,clink: Tab completion
#   -NoPath       leave PATH as it is
#   -Force        install the same version again, or an older one than the one that is installed
#   -Quiet        ask nothing (without it, a console asks for what was not given: the scope and the completion)
#   -VerifyAttestation  check where the zip comes from with "gh attestation verify"
#
# -ReleasesUrl, -LocalReleases and -Repository are for the tests and for a fork. -LocalReleases names a
# releases.json on this machine, whose addresses may be files; nothing else reads a file.
& {
    param(
        [string]$Version = $env:WSLBIN_VERSION,
        [string]$Scope = $env:WSLBIN_SCOPE,
        [string]$InstallDir,
        [string[]]$Link = @(),
        [string[]]$Completion = @(),
        [switch]$NoPath,
        [switch]$Force,
        [switch]$Quiet,
        [switch]$VerifyAttestation,
        [string]$Repository = 'quatrebi/wslbin',
        [string]$ReleasesUrl = 'https://quatrebi.github.io/wslbin/releases.json',
        [string]$LocalReleases,
        # for the tests of the installer: what it passes on to setup\install.ps1 as it is
        [string]$ProfileRoot,
        [string]$ClinkDir,
        [string]$UninstallKey
    )

    $ErrorActionPreference = 'Stop'
    # the regular expression of semver.org, with [0-9] for \d; the same line is in setup\common.ps1 and
    # Wslbin.Version.psm1 (a test sees that they are the same)
    $SemVerPattern = '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-((?:0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?\z'

    function Write-Say([string]$Text) { Write-Host "wslbin: $Text" }

    # The zip of a release must be the file wslbin-<version>-win-x64.zip of the release v<version> of the
    # repository on GitHub (GitHub sends the file on from its own storage): releases.json comes from
    # another place than the zip, and must not be able to point anywhere else.
    function Test-Download([string]$Url, [string]$Asset) {
        if ($Asset -cne "wslbin-$Version-win-x64.zip") { throw "releases.json names the file '$Asset' for $Version, not wslbin-$Version-win-x64.zip." }
        if (Test-LocalFile $Url) { return }
        $expected = "https://github.com/$Repository/releases/download/v$Version/$Asset"
        if (-not [string]::Equals($Url, $expected, [StringComparison]::OrdinalIgnoreCase)) {
            throw "The address of the zip is not the download of release v$Version of $Repository on GitHub ($expected): $Url"
        }
    }

    # A zip that is a file on this machine: only with -LocalReleases (for the tests), and never an address.
    function Test-LocalFile([string]$Url) {
        $LocalReleases -and $Url -notmatch '://'
    }

    function Get-Releases {
        if ($LocalReleases) {
            if (-not (Test-Path -LiteralPath $LocalReleases)) { throw "-LocalReleases $LocalReleases does not exist." }
            $json = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $LocalReleases).ProviderPath, (New-Object Text.UTF8Encoding $false))
        }
        else {
            if ($ReleasesUrl -notmatch '^https://') { throw "-ReleasesUrl must be an https address; got '$ReleasesUrl'." }
            Write-Say "reading $ReleasesUrl"
            $client = New-Object System.Net.Http.HttpClient
            try { $json = $client.GetStringAsync($ReleasesUrl).GetAwaiter().GetResult() }
            finally { $client.Dispose() }
        }
        $document = $json | ConvertFrom-Json
        if ($document.schema -ne 1) { throw "releases.json has schema '$($document.schema)'; this loader reads schema 1. Is there a newer install.ps1?" }
        $document
    }

    # The file of a release into $Path, with a progress bar. A local file (only with -LocalReleases) is copied.
    function Get-Zip([string]$Url, [string]$Path, [string]$Name) {
        if (Test-LocalFile $Url) {
            Copy-Item -LiteralPath $Url -Destination $Path
            return
        }
        Write-Say "downloading $Url"
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromMinutes(30)
        try {
            $response = $client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            $null = $response.EnsureSuccessStatusCode()
            $total = $response.Content.Headers.ContentLength
            $source = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $target = [IO.File]::Create($Path)
            try {
                $buffer = New-Object byte[] 81920
                $done = [long]0
                $watch = [Diagnostics.Stopwatch]::StartNew()
                $lastShown = [long]-1000
                while (($read = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $target.Write($buffer, 0, $read)
                    $done += $read
                    if ($watch.ElapsedMilliseconds - $lastShown -ge 200) {
                        $lastShown = $watch.ElapsedMilliseconds
                        $seconds = [Math]::Max($watch.Elapsed.TotalSeconds, 0.001)
                        $speed = $done / $seconds
                        $status = '{0:N1} MB, {1:N1} MB/s' -f ($done / 1MB), ($speed / 1MB)
                        if ($total) {
                            $left = [int](($total - $done) / [Math]::Max($speed, 1))
                            $status = '{0:N1} of {1:N1} MB, {2:N1} MB/s, {3} s left' -f ($done / 1MB), ($total / 1MB), ($speed / 1MB), $left
                            Write-Progress -Activity "Downloading $Name" -Status $status -PercentComplete ([int](100 * $done / $total))
                        }
                        else { Write-Progress -Activity "Downloading $Name" -Status $status }
                    }
                }
            }
            finally { $target.Dispose(); $source.Dispose(); Write-Progress -Activity "Downloading $Name" -Completed }
        }
        finally { $client.Dispose() }
    }

    # Unpacks a zip into a folder, refusing an entry whose path would end up outside of it (zip slip).
    function Expand-Package([string]$ZipPath, [string]$Folder) {
        Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
        $root = [IO.Path]::GetFullPath($Folder).TrimEnd('\') + '\'
        $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
        try {
            foreach ($entry in $zip.Entries) {
                $target = [IO.Path]::GetFullPath([IO.Path]::Combine($root, $entry.FullName.Replace('/', '\')))
                if (-not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw "The zip holds an entry outside of its folder ($($entry.FullName)): refused." }
                if ($entry.FullName.EndsWith('/')) { New-Item -ItemType Directory -Path $target -Force | Out-Null; continue }
                $parent = Split-Path -Parent $target
                if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
            }
        }
        finally { $zip.Dispose() }
    }

    function Test-Interactive {
        [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
    }

    function Read-Choice([string]$Caption, [string]$Question, [string[]]$Choices, [int]$Default) {
        $descriptions = @($Choices | ForEach-Object { New-Object Management.Automation.Host.ChoiceDescription $_ })
        $Host.UI.PromptForChoice($Caption, $Question, $descriptions, $Default)
    }

    # What the entries in Settings > Apps say is installed: {Scope; Version; Location} for each scope.
    function Get-Installed {
        $keyPath = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\wslbin'
        if ($UninstallKey) { $keyPath = $UninstallKey }
        foreach ($place in @(@{ Scope = 'AllUsers'; Hive = [Microsoft.Win32.Registry]::LocalMachine }, @{ Scope = 'CurrentUser'; Hive = [Microsoft.Win32.Registry]::CurrentUser })) {
            $key = $place.Hive.OpenSubKey($keyPath)
            if (-not $key) { continue }
            try { [pscustomobject]@{ Scope = $place.Scope; Version = [string]$key.GetValue('DisplayVersion', ''); Location = [string]$key.GetValue('InstallLocation', '') } }
            finally { $key.Close() }
        }
    }

    # One argument of the command line of setup\install.ps1 (CommandLineToArgvW): in quotes, with the
    # backslashes in front of a quote (or of the closing quote) doubled.
    function ConvertTo-CommandLineArgument([string]$Value) {
        '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
    }

    # Runs setup\install.ps1 in a PowerShell of its own, of the same kind as this one (of $PSHOME, not the
    # program of this process, which may be another host), with -ExecutionPolicy Bypass: "irm | iex" works
    # under the policy Restricted of Windows PowerShell, which would not run the script in this session.
    # Returns the exit code of the installer.
    function Invoke-Setup([string]$Setup, [Collections.IDictionary]$Arguments) {
        $shell = Join-Path $PSHOME 'powershell.exe'
        if ($PSVersionTable.PSEdition -eq 'Core') { $shell = Join-Path $PSHOME 'pwsh.exe' }
        $line = '-NoProfile -ExecutionPolicy Bypass -File ' + (ConvertTo-CommandLineArgument $Setup)
        foreach ($name in $Arguments.Keys) {
            $value = $Arguments[$name]
            if ($value -is [bool]) { if ($value) { $line += " -$name" }; continue }
            # a list is one value with commas: what -File hands over for it, and what the installer takes
            $line += " -$name " + (ConvertTo-CommandLineArgument (@($value) -join ','))
        }
        $psi = New-Object System.Diagnostics.ProcessStartInfo $shell, $line
        $psi.UseShellExecute = $false
        $psi.WorkingDirectory = (Get-Location -PSProvider FileSystem).ProviderPath
        $process = [System.Diagnostics.Process]::Start($psi)
        $process.WaitForExit()
        $process.ExitCode
    }

    $temp = Join-Path ([IO.Path]::GetTempPath()) ('wslbin-load-' + [guid]::NewGuid().ToString('N'))
    $protocols = [Net.ServicePointManager]::SecurityProtocol
    $exitCode = 2
    try {
        [Net.ServicePointManager]::SecurityProtocol = $protocols -bor [Net.SecurityProtocolType]::Tls12
        Add-Type -AssemblyName System.Net.Http

        if ($Version.StartsWith('v')) { $Version = $Version.Substring(1) }
        if ($Version -and -not [regex]::IsMatch($Version, $SemVerPattern)) { throw "-Version must look like 0.1.7; got '$Version'." }
        if ($Scope -and $Scope -notin 'AllUsers', 'CurrentUser') { throw "-Scope is CurrentUser or AllUsers; got '$Scope'." }
        if ($Repository -notmatch '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\z') { throw "-Repository must look like <owner>/<name>; got '$Repository'." }

        $releases = Get-Releases
        $release = $null
        if (-not $Version) {
            if (-not $releases.latest) { throw 'There is no release of wslbin yet.' }
            $Version = [string]$releases.latest
            if (-not [regex]::IsMatch($Version, $SemVerPattern)) { throw "releases.json names '$Version' as the latest, which is not a version." }
        }
        foreach ($candidate in @($releases.releases)) { if ($candidate.version -ceq $Version) { $release = $candidate } }
        if (-not $release) {
            $known = @(@($releases.releases) | ForEach-Object { $_.version }) -join ', '
            throw "There is no release $Version. Released: $known."
        }
        if ([string]$release.sha256 -notmatch '^[0-9a-f]{64}\z') { throw "releases.json has no SHA256 for $Version." }
        Test-Download ([string]$release.url) ([string]$release.asset)

        # questions, only where nobody said and somebody can answer
        if (-not $Quiet -and (Test-Interactive)) {
            if (-not $Scope) {
                # an update goes into the scope that is installed: the other one would be a second copy,
                # so that is what Enter chooses (the installer does the same when nobody is asked)
                $default = 0
                foreach ($installed in @(Get-Installed)) {
                    $whom = $(if ($installed.Scope -eq 'AllUsers') { 'all users' } else { 'the current user' })
                    Write-Say "wslbin $($installed.Version) is installed for $whom in $($installed.Location): choose that to update it (of two installations, the one for all users is the one that runs)"
                    if ($installed.Scope -eq 'AllUsers') { $default = 1 }
                }
                $answer = Read-Choice 'wslbin' 'Install for whom?' @('&Current user (no administrator rights)', '&All users (asks for administrator rights)') $default
                $Scope = @('CurrentUser', 'AllUsers')[$answer]
            }
            if ($Completion.Count -eq 0) {
                $answer = Read-Choice 'wslbin' 'Hook Tab completion into a shell?' @('&None', '&PowerShell', '&Clink (cmd)', '&Both') 0
                switch ($answer) {
                    1 { $Completion = @('pwsh') }
                    2 { $Completion = @('clink') }
                    3 { $Completion = @('pwsh', 'clink') }
                }
            }
        }

        New-Item -ItemType Directory -Path $temp | Out-Null
        $zipPath = Join-Path $temp $release.asset
        Get-Zip ([string]$release.url) $zipPath $release.asset

        $actual = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $release.sha256) { throw "The SHA256 of the download is $actual, but releases.json says $($release.sha256). Nothing was installed." }
        Write-Say "SHA256 matches ($actual)"

        if ($VerifyAttestation) {
            $gh = Get-Command gh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $gh) { throw '-VerifyAttestation needs the gh program (https://cli.github.com), and it is not installed.' }
            # made by the release workflow of that repository, from its main branch: not by any workflow
            # that can write to the repository
            & $gh.Source attestation verify $zipPath --repo $Repository --signer-workflow "$Repository/.github/workflows/release.yml" --source-ref 'refs/heads/main'
            if ($LASTEXITCODE -ne 0) { throw "gh attestation verify failed (exit code $LASTEXITCODE): the zip is not proven to come from $Repository. Nothing was installed." }
            Write-Say "attestation of $Repository verified"
        }

        $package = Join-Path $temp 'package'
        Expand-Package $zipPath $package
        $setup = Join-Path $package 'setup\install.ps1'
        if (-not (Test-Path -LiteralPath $setup)) { throw 'The zip holds no setup\install.ps1: it is not a package of wslbin.' }

        $arguments = [ordered]@{}
        if ($Scope) { $arguments.Scope = $Scope }
        if ($InstallDir) { $arguments.InstallDir = $InstallDir }
        if ($Link.Count -gt 0) { $arguments.Link = $Link }
        if ($Completion.Count -gt 0) { $arguments.Completion = $Completion }
        if ($NoPath) { $arguments.NoPath = $true }
        if ($Force) { $arguments.Force = $true }
        if ($ProfileRoot) { $arguments.ProfileRoot = $ProfileRoot }
        if ($ClinkDir) { $arguments.ClinkDir = $ClinkDir }
        if ($UninstallKey) { $arguments.UninstallKey = $UninstallKey }
        Write-Say "installing $Version"
        $exitCode = Invoke-Setup $setup $arguments
    }
    catch {
        # (an error record would show the whole text of this script block as the place of the error)
        $Host.UI.WriteErrorLine("wslbin: $($_.Exception.Message)")
        $exitCode = 2
    }
    finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
        [Net.ServicePointManager]::SecurityProtocol = $protocols
    }
    $global:LASTEXITCODE = $exitCode
} @args
# A console that runs this through "iex" must not be closed: exit only when this is a file that was run
# (only then does a script block of it know its file).
if ({ }.File) { exit $LASTEXITCODE }
