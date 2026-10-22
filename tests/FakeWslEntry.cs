// The entry point of a test build of wslbin (Initialize-FakeWsl in helpers.ps1 builds it with
// build.ps1 -ExtraSource tests\FakeWslEntry.cs -Main Wslbin.FakeWslEntry). It is the same program, but
// wsl.exe is the stand-in that WSLBIN_TEST_WSL names (tests\FakeWsl.cs), and what the registry would
// say comes from WSLBIN_TEST_DISTROS (whether WSL has a distribution: 0 or 1) and
// WSLBIN_TEST_DEFAULT_DISTRO (the name of the default one). wslbin.exe itself is built without this
// file, so nothing in its environment can change which wsl.exe it runs.
using System;

namespace Wslbin
{
    internal static class FakeWslEntry
    {
        static int Main(string[] args)
        {
            Launcher.WslPathOverride = Environment.GetEnvironmentVariable("WSLBIN_TEST_WSL");
            string distros = Environment.GetEnvironmentVariable("WSLBIN_TEST_DISTROS");
            if (distros != null) WslQuery.HasDistribution = () => distros == "1";
            string defaultDistro = Environment.GetEnvironmentVariable("WSLBIN_TEST_DEFAULT_DISTRO");
            if (defaultDistro != null) WslQuery.DefaultDistribution = () => defaultDistro;
            return Program.Main(args);
        }
    }
}
