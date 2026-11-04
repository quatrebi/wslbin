# wslbin

[![CI](https://github.com/quatrebi/wslbin/actions/workflows/ci.yml/badge.svg)](https://github.com/quatrebi/wslbin/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform: Windows 10 and 11, WSL 2](https://img.shields.io/badge/platform-Windows%2010%2F11%20%2B%20WSL%202-0078D6)
[![Support on Ko-fi](https://img.shields.io/badge/Ko--fi-support%20wslbin-ff7a45?logo=ko-fi&logoColor=white)](https://ko-fi.com/Y7H12A1AMH)

**Linux utilities from WSL as ordinary Windows programs.**

`rsync`, `make`, `dig`, `nc`, `man`, a TUI like `redis-tui`: type them in PowerShell, cmd, the terminal of
an IDE, or start them from any program. Windows paths, wildcards, pipes, colours, `Ctrl+C` and exit codes
work the way you expect.

[Русский](README.ru.md) · [Install](#install) · [Usage](#usage) · [Tab completion](#tab-completion) · [For AI agents](#for-ai-agents) · [Documentation](#documentation)

## Example

```powershell
make build
rsync -av C:\proj\dist\ host:/srv/app/
rsync -av *.log host:/srv/logs/
dig example.com
```

`--wslbin-explain` prints what would run in WSL, and runs nothing:

```text
PS> rsync --wslbin-explain -av C:\proj\dist\ host:/srv/app/
rsync -av /mnt/c/proj/dist/ host:/srv/app/
PS> rsync --wslbin-explain -av *.log C:\backup\
rsync -av *.log /mnt/c/backup/
```

## What you get

- **One small `.exe`.** Each utility is a copy of `wslbin.exe` named after it (`rsync.exe`, `make.exe`, ...).
  Nothing else to install in Windows: no .NET, no runtime.
- **Paths just work.** `C:\proj\dist\` becomes `/mnt/c/proj/dist/`; bash expands `*.log` by Linux rules.
- **Safe by default.** Nothing typed as an argument can run a second command (`--wslbin-sh` and
  `wslbin -c` are for when you want Linux to interpret the text).
- **No middleman.** Input and output are not intercepted: pipes, colours and full-screen programs work, and
  the exit code of the utility is the exit code you get (125 means wslbin or `wsl.exe` failed).

> **Status.** It works and is tested, but there is no release yet and the site (GitHub Pages) is not
> published, so the install command below will work after the first release and the first Pages deployment.
> Until then, build it from the source: see [Build and use from source](CONTRIBUTING.md#build-and-use-from-source).

## Install

Needs Windows 10 22H2 or Windows 11 (x64) and WSL 2 with a distribution. The installer runs in Windows
PowerShell 5.1 and in PowerShell 7.

```powershell
irm https://quatrebi.github.io/wslbin/install.ps1 | iex
```

- It downloads the latest release, checks it and runs the installer that is in it.
- By default wslbin goes to `%LOCALAPPDATA%\Programs\wslbin` and the PATH of the user, with no administrator
  rights. In a console it asks for what you did not give: for whom to install, and whether to hook in Tab
  completion.
- Parameters (all users, wrappers, completion, a silent run) go to a script block:

```powershell
& ([scriptblock]::Create((irm https://quatrebi.github.io/wslbin/install.ps1))) -Scope AllUsers -Link make,rsync -Completion pwsh -Quiet
```

Then:

```powershell
wslbin --doctor            # checks WSL, bash, completion, PATH, wrappers, wslbin.ini
wslbin --link make rsync   # more wrappers; offers to install a missing utility with apt
wslbin --list              # wrappers and what is wrong with them
```

All parameters, what the checks prove, update, removal and install without a network:
[INSTALL.md](INSTALL.md).

## Usage

| You want | You type |
| --- | --- |
| a utility, as usual | `make build`, `rsync -av C:\x\ host:/srv/` |
| a utility that has no wrapper | `wslbin htop` |
| Linux variables and `$(...)` | `make --wslbin-sh 'OUT=$HOME/out' 'TAG=$(git rev-parse --short HEAD)'` |
| arguments exactly as typed | `grep --wslbin-raw 'a*' file.txt` |
| what will run, without running it | `rsync --wslbin-explain -av *.log C:\backup\` |
| a pipeline inside Linux | `wslbin -c "ls *.log \| wc -l"` |

The options `--wslbin-raw`, `--wslbin-sh` and `--wslbin-explain` go right after the name of the utility, and
only there; anything later belongs to the utility. By default:

- Windows paths become Linux paths. A relative path with backslashes is translated only when that file or
  folder exists in the current folder (`wslbin --help paths`).
- bash expands `*`, `?`, `[...]` and a leading `~`; everything else (`$`, `;`, `|`, `&`, quotes, braces,
  spaces) reaches the utility literally.
- PowerShell and cmd remove quotes before wslbin starts, so `grep 'a*' f` arrives as `a*`: use
  `--wslbin-raw` for that.

Help is in the program, in English and Russian: `wslbin --help`, and `wslbin --help` followed by `modes`,
`paths`, `globs`, `env`, `completion`, `config` or `troubleshooting`. Settings (`distro`, `raw`, `sh`,
`pass_env`, `path`, `args.<utility>`, `lang`) live in `wslbin.ini` next to `wslbin.exe`:
`wslbin --help config`.

## Tab completion

The variants come from bash-completion in WSL, so `rsync --<Tab>`, `make <Tab>` or `man <Tab>` give what
they give in Linux, and Windows paths work both ways (`C:\Prog` becomes `C:\Program Files\`). It needs the
`bash-completion` package in WSL (`wslbin --doctor` checks it).

In PowerShell, put this in the profile; in cmd, `wslbin --init clink` (needs
[Clink](https://chrisant996.github.io/clink/)). The installer's `-Completion pwsh,clink` does both.

```powershell
wslbin --init pwsh | Invoke-Expression
```

The PowerShell line also removes the aliases that would hide a wrapper (`ls`, `cat`, `rm`, ...), for the
whole session and every script in it: make wrappers only for names that you want to mean the Linux tool.

## For AI agents

`wslbin --ai-context` prints how an agent should call Linux utilities on this machine (the same text as
[`llms.txt`](llms.txt)). `wslbin --install-ai-context` adds a short marked block to the instructions of
Claude Code (`CLAUDE.md`, and a skill) and Codex (`AGENTS.md`); `--remove` takes it out again. Agents that
work on wslbin itself: start with [CONTRIBUTING.md](CONTRIBUTING.md).

## Documentation

- [INSTALL.md](INSTALL.md): the installer in detail (parameters, scope, checks, update, removal, offline).
- [`docs/en`](docs/en): the help texts of the program (`wslbin --help`).
- [CONTRIBUTING.md](CONTRIBUTING.md): build from source, tests, versions, layout of the repository.

## License

[MIT](LICENSE), Copyright (c) 2026 Dmitriy Khudnitskiy.
