# wslbin

[![CI](https://github.com/quatrebi/wslbin/actions/workflows/ci.yml/badge.svg)](https://github.com/quatrebi/wslbin/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/quatrebi/wslbin?include_prereleases)](https://github.com/quatrebi/wslbin/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform: Windows 10 and 11, WSL 2](https://img.shields.io/badge/platform-Windows%2010%2F11%20%2B%20WSL%202-0078D6)
![No dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)

[Русский](README.ru.md)

Linux utilities from WSL as ordinary Windows programs. `rsync`, `make`, `dig`, `nc`, `man`, a TUI like
`redis-tui`: type them in PowerShell, cmd, a terminal of an IDE, or start them from any program, with
Windows paths, wildcards, pipes, colours, `Ctrl+C` and exit codes working the way you expect.

```powershell
make build
rsync -av C:\proj\dist\ host:/srv/app/
rsync -av *.log host:/srv/logs/
dig example.com
```

Each utility is a copy of one small `wslbin.exe` named after it (`rsync.exe`, `make.exe`, ...). It
turns `C:\proj\dist\` into `/mnt/c/proj/dist/`, lets bash expand `*.log` by Linux rules, escapes
everything else, runs the utility in WSL and returns its exit code. Input and output are not
intercepted, so pipes and full-screen programs work.

> **Status.** It works and is tested, but there is no release yet, so the command below has nothing to
> download until the first one is made (by a button in Actions). Until then, build it from the source: see
> [Build and contribute](#build-and-contribute).

## Install

Needs Windows 10 22H2 or Windows 11 with WSL 2 and a distribution. The program is one self-contained
file and needs nothing else (no .NET, no build tools).

```powershell
irm https://quatrebi.github.io/wslbin/install.ps1 | iex
```

That downloads the latest release, checks it, and runs the installer that is in it. In a console it asks
for whom to install and whether to hook Tab completion in; with parameters (a script block takes them) it
asks nothing:

```powershell
& ([scriptblock]::Create((irm https://quatrebi.github.io/wslbin/install.ps1))) -Version 0.1.7 -Scope AllUsers -Link make,rsync,dig -Completion pwsh,clink -Quiet
```

`WSLBIN_VERSION` and `WSLBIN_SCOPE` in the environment do the same for the first line. Read the script
before you run it, if you like: [`site/install.ps1`](site/install.ps1) is short. It reads the list of
releases from the site (`releases.json`: the address and the SHA256 of each zip), downloads the zip from
GitHub Releases, checks the SHA256 (the hash comes from the site and the file from GitHub), with
`-VerifyAttestation` also where GitHub says it was built (needs the [gh](https://cli.github.com) program),
unpacks it into a temporary folder and runs `setup\install.ps1` from it.

The zip (`wslbin-<version>-win-x64.zip` on the [releases page](https://github.com/quatrebi/wslbin/releases),
with its `.sha256` and `SHA256SUMS.txt`) holds `wslbin.exe`, `LICENSE`, `manifest.json` (every file with
its SHA256) and `setup\install.ps1`, `setup\uninstall.ps1`: unpack it and run
`.\setup\install.ps1 -Link make,rsync,dig -Completion pwsh,clink` to install without a network.

`-Scope AllUsers` (the default tries it first) puts wslbin in `C:\Program Files\wslbin`, in the PATH
of the machine, and asks for administrator rights (UAC). The copy that has the rights installs the
program and nothing more: `-Link` and `-Completion` are done afterwards as you, in your WSL and your
profiles (so `-Link` asks for the rights once more, to write the wrappers). `-Scope CurrentUser` (the
fallback when the rights are refused) uses `%LOCALAPPDATA%\Programs\wslbin` and the PATH of the user, and
needs no rights. `-Completion` hooks Tab completion into PowerShell (both editions) and Clink.

**Update** is the same command: it compares the version with the one in Settings > Apps, installs a newer
one, says "installed already" for the same one (`-Force` installs it again) and refuses an older one
(`-Force` goes back). Files are replaced all together or not at all; the running `wslbin.exe` and the
wrappers are renamed to `.old` first and deleted at once or at the next run. Your `wslbin.ini` is not
touched.

**Remove**: Settings > Apps > wslbin > Uninstall, or `setup\uninstall.ps1` in the install folder
(`-Quiet` asks nothing, `-Purge` deletes `wslbin.ini` too). It takes out the wrappers, the PATH entry,
the files, the entry in Apps, the hooks in the profiles and Clink, and the block for AI agents. The
installer writes nothing else to the registry.

Then:

```powershell
wslbin --doctor            # checks WSL, bash, completion, PATH, wrappers, wslbin.ini
wslbin --link make rsync   # more wrappers; offers to install a missing utility with apt
wslbin --list              # wrappers and what is wrong with them
```

## Use

| You want | You type |
| --- | --- |
| a utility, as usual | `make build`, `rsync -av C:\x\ host:/srv/` |
| a utility that has no wrapper | `wslbin htop` |
| Linux variables and `$(...)` | `make --wslbin-sh 'OUT=$HOME/out' 'TAG=$(git rev-parse --short HEAD)'` |
| arguments exactly as typed | `grep --wslbin-raw 'a*' file.txt` |
| what will run, without running it | `rsync --wslbin-explain -av *.log C:\backup\` |
| a pipeline inside Linux | `wslbin -c "ls *.log \| wc -l"` |

By default Windows paths become Linux paths, bash expands `*`, `?`, `[...]` and a leading `~`, and
everything else (`$`, `;`, `|`, `&`, quotes, braces, spaces) reaches the utility literally. Nothing
typed as an argument can run a second command. A relative path with backslashes (`.\file`, `src\a.c`,
what Tab completion writes) is translated when that file or folder exists in the current folder, and
left as typed when it does not (`.\d+` stays a regular expression). PowerShell and cmd remove quotes
before wslbin starts, so `grep 'a*' f` arrives as `a*`: use `--wslbin-raw` for that.

Help is in the program, in English and Russian: `wslbin --help`, and `wslbin --help` followed by
`modes`, `paths`, `globs`, `env`, `completion`, `config` or `troubleshooting`. The same texts are in
[`docs/en`](docs/en). Settings (`distro`, `raw`, `sh`, `pass_env`, `path`, `args.<utility>`, `lang`)
live in `wslbin.ini` next to `wslbin.exe`: `wslbin --help config`.

## Tab completion

The variants come from bash-completion in WSL, so `rsync --<Tab>`, `make <Tab>` or `man <Tab>` give what
they give in Linux, and Windows paths work both ways (`C:\Prog` becomes `C:\Program Files\`).
In PowerShell, put `wslbin --init pwsh | Invoke-Expression` in the profile; in cmd, `wslbin --init clink`
(needs [Clink](https://chrisant996.github.io/clink/)). The installer's `-Completion pwsh,clink` does both.
The PowerShell line also removes the aliases that would hide a wrapper (`ls`, `cat`, `rm`, ...), for
the whole session and every script in it: make wrappers only for names that you want to mean the
Linux tool.

## For AI agents

`wslbin --ai-context` prints how an agent should call Linux utilities on this machine (the same text
as [`llms.txt`](llms.txt)). `wslbin --install-ai-context` adds a short marked block to the
instructions of Claude Code (`CLAUDE.md`, and a skill) and Codex (`AGENTS.md`); `--remove` takes it
out again. Agents that work on wslbin itself: read [`AGENTS.md`](AGENTS.md).

## Build and contribute

Needs the [.NET SDK 10](https://dotnet.microsoft.com/download), the C++ build tools of Visual Studio
(the workload "Desktop development with C++") and access to nuget.org until the NuGet packages of the
AOT compiler and of the runtime are in the cache (the first build, and after an update of the SDK).
The program is published as Native AOT: one self-contained `.exe` that every wrapper copies.

```powershell
.\build.ps1                                        # bin\wslbin.exe, with the version of this checkout
.\get-version.ps1                                  # that version, as SemVer 2.0
Invoke-Pester .\tests                              # everything (needs WSL; Clink tests need Clink)
Invoke-Pester .\tests -ExcludeTagFilter WSL        # what needs neither (this is what CI runs)
```

The program is C# on .NET 10 in [`src/`](src), one file for each area; [`src/wslbin.cs`](src/wslbin.cs)
has the entry point and a map of the others. The tests are Pester 5 in PowerShell 7.
[`DECISIONS.md`](DECISIONS.md) (in Russian) holds every agreed decision and what was found out on
the way; agents that work on wslbin read [`AGENTS.md`](AGENTS.md).

Versions are automatic (SemVer 2.0). `MAJOR.MINOR` is `VersionPrefix` in
[`wslbin.csproj`](wslbin.csproj): it is the one thing a pull request changes by hand, and it is never
lowered. `PATCH` is the number of commits since that value first appeared, and the rest says where a
build comes from: `0.1.4-develop.42+33c8830` is the 42nd run of the CI, on `develop`, at that commit; a
release has no suffix. Builds of different branches never have the same version, and
`wslbin --version` prints it.

```
src/               the program
wslbin.csproj      the project: MAJOR.MINOR of the version, what is built into the .exe
data/              utilities that have a Windows version of their own (built into the .exe)
wsl/complete.sh    completion helper that runs in WSL
shell/             PowerShell and Clink code that "wslbin --init" fills in
docs/en  docs/ru   help texts (built into the .exe)
setup/             install.ps1, uninstall.ps1 and what they share: they go into the release zip
site/              the site (GitHub Pages): the landing page and install.ps1, the loader
build.ps1          the build (dotnet publish, Native AOT)
get-version.ps1    the version of a build; its functions are in Wslbin.Version.psm1
tests/             Pester tests
.github/workflows/ CI and release
LICENSE            MIT
```

## License

[MIT](LICENSE), Copyright (c) 2026 Dmitriy Khudnitskiy.
