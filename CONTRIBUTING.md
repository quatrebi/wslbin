# Contributing to wslbin

How to build wslbin from the source, use that build, run the tests and find your way around the repository.
The user guide is the [README](README.md).

Agents that work on wslbin start here, and then read the tests of the part they change. Code and comments
are in English.

## Build and use from source

Requirements:

- the [.NET SDK 10](https://dotnet.microsoft.com/download); `global.json` pins it, and `build.ps1` runs
  `dotnet` from the repository folder so that the pin applies;
- the C++ build tools of Visual Studio (the workload "Desktop development with C++"): the Native AOT
  compiler links with them;
- git 2.31 or later: the version is worked out from the history of the repository;
- access to nuget.org until the NuGet packages of the AOT compiler and of the runtime are in the cache (the
  first build, and after an update of the SDK).

The program is published as Native AOT: one self-contained `.exe` that every wrapper copies.

```powershell
.\build.ps1          # bin\wslbin.exe, with the version of this checkout
.\get-version.ps1    # that version, as SemVer 2.0
```

Until there is a release, use the build like this:

1. Copy `bin\wslbin.exe` into a folder of its own, for example `C:\tools\wslbin`, and put that folder in PATH
   (or add it to PATH of the user).
2. Make wrappers there, and check the setup:

```powershell
wslbin --link make rsync
wslbin --doctor
```

`wslbin --link` makes the wrappers beside `wslbin.exe` and warns when that folder is not in PATH.
`wslbin --init pwsh` and `wslbin --init clink` hook Tab completion in, as described in the README.

## Tests

The tests are Pester 5 in PowerShell 7 (Pester 6 runs them too).

```powershell
Invoke-Pester ./tests                              # everything
Invoke-Pester ./tests -ExcludeTagFilter WSL        # what needs neither WSL nor Clink (this is what CI runs)
```

- Tests that need a real WSL distribution, or Clink, skip themselves when it is not there.
- Every test file builds the program itself, unless `WSLBIN_TEST_EXE` names a `wslbin.exe` built already.
  Builds share `obj\` in the repository: never run two builds, or two test runs without `WSLBIN_TEST_EXE`,
  at once.
- Tests must not write outside their own folder (the real `CLAUDE_CONFIG_DIR` and home folder are
  off limits).

## Versions

Versions are automatic (SemVer 2.0). `MAJOR.MINOR` is `VersionPrefix` in [`wslbin.csproj`](wslbin.csproj): the
one thing a pull request changes by hand, and it is never lowered. `PATCH` is the number of commits since
that value first appeared, and the rest says where a build comes from: `0.1.4-develop.42+33c8830` is the 42nd
run of the CI, on `develop`, at that commit; a release has no suffix. `wslbin --version` prints it. Details
are in `get-version.ps1` and `Wslbin.Version.psm1`.

## Layout of the repository

```text
src/               the program (C# on .NET 10, one file for each area; src/wslbin.cs has the entry point and a map of the others)
wslbin.csproj      the project: MAJOR.MINOR of the version, what is built into the .exe
global.json        the pin of the .NET SDK
data/              utilities that have a Windows version of their own (built into the .exe)
wsl/complete.sh    completion helper that runs in WSL
shell/             PowerShell and Clink code that "wslbin --init" fills in
docs/en  docs/ru   help texts (built into the .exe)
setup/             install.ps1, uninstall.ps1 and what they share: they go into the release zip
site/              the site (GitHub Pages): the landing page and install.ps1, the loader
build.ps1          the build (dotnet publish, Native AOT)
get-version.ps1    the version of a build; its functions are in Wslbin.Version.psm1
tests/             Pester tests
.github/workflows/ CI, release and Pages
llms.txt           the text for AI agents, the same as "wslbin --ai-context"
README.md, README.ru.md, INSTALL.md, INSTALL.ru.md   the user documentation
LICENSE            MIT
```

The README and `docs/` are tested like code (`tests/help.Tests.ps1`): the same headings in both languages,
only options that exist, closed code blocks. Keep the English and the Russian files in step.
