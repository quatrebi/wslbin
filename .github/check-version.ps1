# Used by both jobs of release.yml: fails unless the tag (the TAG variable, never pasted into the code)
# looks like a version and bin/wslbin.exe reports that version.
$ErrorActionPreference = 'Stop'
if ($env:TAG -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$') {
    throw "'$env:TAG' is not a version tag (v1.2.3, or v1.2.3-rc.1)."
}
$reported = & (Join-Path $PSScriptRoot '..\bin\wslbin.exe') --version
if ($reported -ne "wslbin $($env:TAG.Substring(1))") {
    throw "The tag is $env:TAG, but the program says '$reported'. Change the version in src/wslbin.cs and tag again."
}
