# Security policy

## Supported versions

Only the latest release gets fixes. The installer (`install.ps1`) installs the latest release.

## Reporting a vulnerability

Please do not open a public issue for a security problem.

Report it privately: open the **Security** tab of the repository and choose **Report a vulnerability**.
Include the wslbin version (`wslbin --version`), the Windows and WSL versions, the steps that show the
problem, and what you expected to happen.

This is a personal project. Reports are read by the maintainer when time allows; no response time is
promised.

## Scope

wslbin starts Linux programs from Windows, escapes the arguments it passes to `bash`, and its installer
runs a script from the release archive. Problems in those parts are in scope. The known limits of the
program are listed in the README under "Limitations".
