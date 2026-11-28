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

Four test projects (xUnit v3 on Microsoft.Testing.Platform, run with `dotnet test`) and Pester 6.2.0 for the
PowerShell scripts. The .NET SDK 10 is all they need; nothing here is a package of the program itself (the
packages live in `tests/Directory.Packages.props`).

```powershell
# the program's code, against a fake machine; fast, no WSL; the PR gate is 75 % of the lines of src/
dotnet test --project tests/Wslbin.Tests.Unit

# the same with the coverage and the gate (what CI runs)
dotnet test --project tests/Wslbin.Tests.Unit --coverage --coverage-output-format cobertura `
  --coverage-output "$PWD/tests/artifacts/coverage.cobertura.xml" --coverage-settings "$PWD/tests/coverage.config"
./tests/coverage-gate.ps1 -Report tests/artifacts/coverage.cobertura.xml -Minimum 75

# the built program as a process (and the escaping, checked by the bash of Git for Windows)
dotnet test --project tests/Wslbin.Tests.Integration

# a real WSL distribution, a terminal: on a machine of a person only, not in CI
dotnet test --project tests/Wslbin.Tests.E2E

# the PowerShell scripts: installer, versions, workflows, documents
Invoke-Pester ./tests/pester
```

- `tests/Wslbin.Testable` builds `src/*.cs` as a library for the unit tests (the same sources as `wslbin.exe`,
  listed in `Wslbin.Sources.props`). The program reaches the machine (environment, console, registry, processes)
  only through `IHost` in `src/Host.cs`; a unit test says which machine it means (`Host.Use(new FakeHost())`).
  The banned APIs of `tests/BannedSymbols.Src.txt` make the build refuse `Console`, `Environment` and the like in
  `src/` anywhere else, and `[ExcludeFromCodeCoverage]` everywhere.
- The integration and E2E tests build the program themselves (`build.ps1`, once per run, under the mutex
  `Global\wslbin-build`), unless `WSLBIN_TEST_EXE` names a `wslbin.exe` built already: CI builds once and sets it.
  Never run two builds at once: they share `obj\` in the repository.
- A missing Git Bash or PowerShell skips the tests that need it; `WSLBIN_REQUIRE_TOOLS=1` (CI) makes that a failure.
- Set `DOTNET_CLI_TELEMETRY_OPTOUT=1` and `TESTINGPLATFORM_TELEMETRY_OPTOUT=1` to keep the test runs from phoning home.
- Tests must not write outside their own folder (the real `CLAUDE_CONFIG_DIR` and home folder are
  off limits).

## Versions

Versions are automatic (SemVer 2.0). `MAJOR.MINOR` is `VersionPrefix` in [`wslbin.csproj`](wslbin.csproj): the
one thing a pull request changes by hand, and it is never lowered. `PATCH` is the number of commits since
that value first appeared, and the rest says where a build comes from: `0.1.24-pr3.42+33c8830` is the 42nd
CI run, for pull request 3, at that commit (a push to `main` or a manual run gives `-<branch>.<run>`, for
example `-main.43`); a release has no suffix. `wslbin --version` prints it. Details
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
Wslbin.Sources.props  what the program is made of (src, embedded texts), shared with the unit-test library
wslbin.slnx        the program and the test projects
tests/             Wslbin.Testable, Wslbin.Tests.Unit / Integration / E2E, FakeWsl (a stand-in for wsl.exe), pester/ (PowerShell scripts)
.github/workflows/ CI, release and Pages
llms.txt           the text for AI agents, the same as "wslbin --ai-context"
README.md, README.ru.md, INSTALL.md, INSTALL.ru.md   the user documentation
LICENSE            MIT
```

The README and `docs/` are tested like code (`tests/pester/docs.Tests.ps1`): the same headings in both languages,
only options that exist, closed code blocks. Keep the English and the Russian files in step.
