# Installing wslbin

The short version is in the [README](README.md#install). This file has the rest: every parameter, where wslbin
goes, what the checks prove, update, removal and install without a network. [Русский](INSTALL.ru.md).

There is no release yet and the site (GitHub Pages) is not published, so the commands below will work after
the first release and the first Pages deployment. To use wslbin before that, see
[CONTRIBUTING.md](CONTRIBUTING.md#build-and-use-from-source).

## Requirements

- Windows 10 22H2 or Windows 11, x64.
- WSL 2 with a distribution.
- Windows PowerShell 5.1 or PowerShell 7 (the installer works in both).

## Install

```powershell
irm https://quatrebi.github.io/wslbin/install.ps1 | iex
```

This is the loader. It reads the list of releases from the site, downloads the latest zip from GitHub
Releases, checks it, and runs the installer that is in it. In a console it asks for what you did not give: for
whom to install, and whether to hook Tab completion into a shell. With `-Quiet` it asks nothing.

Parameters go to a script block:

```powershell
& ([scriptblock]::Create((irm https://quatrebi.github.io/wslbin/install.ps1))) -Scope AllUsers -Link make,rsync,dig -Completion pwsh,clink -Quiet
```

A specific version: add `-Version` with a number from the [releases page](https://github.com/quatrebi/wslbin/releases),
for example `-Version 1.2.3`. `WSLBIN_VERSION` and `WSLBIN_SCOPE` in the environment do the same for the first line.

The loader:

- runs the installer in a PowerShell of its own, so the execution policy of yours does not matter;
- leaves nothing of the script in your session; the exit code is in `$LASTEXITCODE`;
- is short, so you can read it before you run it: [`site/install.ps1`](site/install.ps1).

## Parameters

| Parameter | What it does | Loader | `setup\install.ps1` | `setup\uninstall.ps1` |
| --- | --- | --- | --- | --- |
| `-Version` | version to install; the latest when left out | yes | - | - |
| `-Scope` | `CurrentUser` (the default) or `AllUsers`; see [Scope](#scope-and-administrator-rights) | yes | yes | - |
| `-InstallDir` | another folder (for the uninstall: which installation to remove) | yes | yes | yes |
| `-Link` | utilities to make wrappers for, for example `make,rsync,dig` | yes | yes | - |
| `-Completion` | `pwsh`, `clink` or `pwsh,clink`: hook Tab completion into a shell | yes | yes | - |
| `-NoPath` | leave PATH as it is | yes | yes | yes |
| `-Force` | install the same version again, or an older one than the installed one | yes | yes | - |
| `-Quiet` | ask nothing | yes | - | yes |
| `-VerifyAttestation` | also prove where the zip comes from (see [below](#what-the-checks-prove)) | yes | - | - |
| `-Purge` | also delete `wslbin.ini` | - | - | yes |

The loader hands `-Scope`, `-InstallDir`, `-Link`, `-Completion`, `-NoPath` and `-Force` on to the installer in
the zip; `-Version`, `-Quiet` and `-VerifyAttestation` it uses itself. Other parameters of these scripts are
internal or exist for the tests (a fork can change the repository of the loader).

Exit codes of `setup\install.ps1` and `setup\uninstall.ps1`:

| Code | Meaning |
| --- | --- |
| 0 | done |
| 1 | install: done, but something that did not stop it went wrong (a profile that is not UTF-8 text and was left alone, a wrapper that could not be made); uninstall: something could not be removed (a program that runs holds its file) |
| 2 | failed |

## Scope and administrator rights

| | For you (`CurrentUser`) | For all users (`AllUsers`) |
| --- | --- | --- |
| Folder | `%LOCALAPPDATA%\Programs\wslbin` | `C:\Program Files\wslbin` |
| PATH | of the user | of the machine |
| Administrator rights (UAC) | no | yes |

- Without `-Scope` the install is for you, unless wslbin is installed for all users already: then that
  installation is updated.
- With `-InstallDir` for all users, the folder must be one that only administrators can change. A new one is
  made so; an existing one that others can change is refused.
- A folder that holds files with the names of wslbin's (`LICENSE`, `manifest.json`, `setup\`) and is not an
  installation of wslbin is refused in either scope: those files belong to something else.
- When wslbin is installed in the other scope as well, the installer says so before it makes the new one. Of
  the two, the one for all users runs, because it comes first in PATH.
- One scope holds one installation: a second one in another folder is refused, even with `-Force`.

What the copy with administrator rights does (`-Scope AllUsers`):

- It installs the program and nothing more, in a folder that only administrators can write to.
- It checks the SHA256 of every file again before it writes it, and its window shows what it did.
- It runs no program from the install folder.
- This protects against changes made after the check. What you run the installer from is yours to trust, as
  with any installer.

`-Link` and `-Completion` are done afterwards as you, in your WSL and your profiles. With an installation for
all users, `-Link` asks for the rights once more, to write the wrappers. `-Completion` hooks Tab completion
into PowerShell (both editions) and Clink, and warns when the execution policy of a PowerShell would not run
the profile (then: `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`).

## What the checks prove

| Check | Done by | What it proves | What it does not prove |
| --- | --- | --- | --- |
| SHA256 of the zip against `releases.json` | the loader, always | the download is not damaged and was not replaced on the way: the hash is the one the release published with the zip, and the site compared it with GitHub's digest of the file | who built the zip: the hash and the zip come from the same project |
| `gh attestation verify` | the loader, with `-VerifyAttestation` (needs the [gh](https://cli.github.com) program) | the zip was built by the release workflow of this repository from `main` | that the code is good; only this check says where the zip comes from |
| SHA256 of every file against `manifest.json` | the installer | the files in the zip are whole, and (for all users) were not changed after the check | where the zip comes from: `manifest.json` is in the same zip |

`wslbin.exe` is not signed with Authenticode. The zip must be exactly `wslbin-<version>-win-x64.zip` of the
release `v<version>` of this repository.

## Update

Update is the same command.

- A newer version is installed.
- The same version says it is installed already (`-Force` installs it again; a folder that lacks
  `wslbin.exe` is installed again anyway).
- An older version is refused (`-Force` goes back).
- Files are replaced all together or not at all. The running `wslbin.exe` and the wrappers are renamed to
  `.old` first, and deleted at once or at the next run.
- Files that the new version no longer has are deleted. Your `wslbin.ini` is not touched.

## Remove

Settings > Apps > wslbin > Uninstall, or `setup\uninstall.ps1` in the install folder (`-Quiet` asks nothing,
`-Purge` deletes `wslbin.ini` too). Run from an unpacked zip, it looks for the installation in the usual
places and leaves the files of the zip alone.

It removes:

- the wrappers and the files of wslbin;
- the PATH entry, only if the installer added it;
- the entry in Apps;
- the hooks in the PowerShell profiles and in Clink (those that belong to an installation that stays are
  kept);
- the block for AI agents.

If a wrapper or `wslbin.exe` is in use, the installation and its entry in Apps stay, so you can run the
uninstall again after you close the program. The installer writes nothing else to the registry.

## Install without a network

The zip (`wslbin-<version>-win-x64.zip` on the [releases page](https://github.com/quatrebi/wslbin/releases),
with its `.sha256` and `SHA256SUMS.txt`) holds:

- `wslbin.exe` and `LICENSE`;
- `manifest.json`: every file with its SHA256;
- `setup\install.ps1`, `setup\uninstall.ps1` and `setup\common.ps1`.

Unpack it and run the installer from the unpacked folder:

```powershell
.\setup\install.ps1 -Link make,rsync,dig -Completion pwsh,clink
```
