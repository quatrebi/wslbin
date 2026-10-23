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

> **Status.** `0.1.0-dev`: it works and is tested. The first release, `v0.1.0`, is not made yet:
> until then, install from a checkout of the source.

## Install

Needs Windows 10 22H2 or Windows 11 with WSL 2 and a distribution. Nothing else: wslbin is compiled
by the C# compiler that ships with Windows, from the source, on your machine.

```powershell
# from a checkout of the source:
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Source . -Link make,rsync,dig -Completion pwsh,clink

# from a release (install.ps1 and SHA256SUMS.txt are on the release page; the hash is that of
# wslbin-<tag>-source.zip; -Repository is quatrebi/wslbin unless you name another):
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Version v0.1.0 -Sha256 <hash> -Link make,rsync,dig
```

Windows does not run scripts by default, and marks a downloaded `install.ps1` as coming from the
internet: `-ExecutionPolicy Bypass` lets this one run go ahead and changes nothing else.

`-Scope AllUsers` (the default tries it first) puts wslbin in `C:\Program Files\wslbin`, in the PATH
of the machine, and asks for administrator rights (UAC). The copy that has the rights installs the
program and nothing more: `-Link` and `-Completion` are done afterwards as you, in your WSL and your
profiles (so `-Link` asks for the rights once more, to write the wrappers). `-Scope CurrentUser` (the
fallback when the rights are refused) uses `%LOCALAPPDATA%\Programs\wslbin` and the PATH of the user.
`-Completion` hooks Tab completion into PowerShell (both editions) and Clink. `-Uninstall` takes it all
out again, the block for AI agents included (your `wslbin.ini` stays). `Get-Help .\install.ps1 -Full`
lists the rest.

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
(needs [Clink](https://chrisant996.github.io/clink/)). `install.ps1 -Completion pwsh,clink` does both.
The PowerShell line also removes the aliases that would hide a wrapper (`ls`, `cat`, `rm`, ...), for
the whole session and every script in it: make wrappers only for names that you want to mean the
Linux tool.

## For AI agents

`wslbin --ai-context` prints how an agent should call Linux utilities on this machine (the same text
as [`llms.txt`](llms.txt)). `wslbin --install-ai-context` adds a short marked block to the
instructions of Claude Code (`CLAUDE.md`, and a skill) and Codex (`AGENTS.md`); `--remove` takes it
out again. Agents that work on wslbin itself: read [`AGENTS.md`](AGENTS.md).

## Build and test

```powershell
.\build.ps1                                        # bin\wslbin.exe, with no SDK and no packages
Invoke-Pester .\tests                              # everything (needs WSL; Clink tests need Clink)
Invoke-Pester .\tests -ExcludeTagFilter WSL        # what needs neither (this is what CI runs)
```

The program is C# 5 in [`src/`](src), one file for each area; [`src/wslbin.cs`](src/wslbin.cs) has the
entry point and a map of the others. The tests are Pester 5 in PowerShell 7.
[`DECISIONS.md`](DECISIONS.md) (in Russian) holds every agreed decision and what was found out on
the way.

```
src/               the program
data/              utilities that have a Windows version of their own (built into the .exe)
wsl/complete.sh    completion helper that runs in WSL
shell/             PowerShell and Clink code that "wslbin --init" fills in
docs/en  docs/ru   help texts (built into the .exe)
install.ps1        installer and uninstaller
build.ps1          the build
tests/             Pester tests
.github/workflows/ CI and release
LICENSE            MIT
```

## License

[MIT](LICENSE), Copyright (c) 2026 Dmitriy Khudnitskiy.
