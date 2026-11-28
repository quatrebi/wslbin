// The entry point of a test build of wslbin (build.ps1 -ExtraSource <this file> -Main Wslbin.FakeWslEntry). It is
// the same program, on a machine whose wsl.exe is the stand-in that WSLBIN_TEST_WSL names (tests\FakeWsl), and
// whose registry says what WSLBIN_TEST_DISTROS (whether WSL has a distribution: 0 or 1) and
// WSLBIN_TEST_DEFAULT_DISTRO (the name of the default one) say; WSLBIN_TEST_QUERY_TIMEOUT_MS shortens how long
// wslbin waits for a wsl.exe whose output it reads. wslbin.exe itself is built without this file (the
// Integration project does not compile it either), so nothing in its environment can change which wsl.exe it runs.
namespace Wslbin;

internal static class FakeWslEntry
{
    static int Main(string[] args)
    {
        string? distros = Environment.GetEnvironmentVariable("WSLBIN_TEST_DISTROS");
        int? timeout = int.TryParse(Environment.GetEnvironmentVariable("WSLBIN_TEST_QUERY_TIMEOUT_MS"), out int ms) ? ms : null;
        var host = new RealHost(
            wslPath: Environment.GetEnvironmentVariable("WSLBIN_TEST_WSL"),
            hasDistribution: distros == null ? null : distros == "1",
            defaultDistribution: Environment.GetEnvironmentVariable("WSLBIN_TEST_DEFAULT_DISTRO"),
            queryTimeoutMs: timeout);
        using IDisposable scope = Host.Use(host);
        return Program.Main(args);
    }
}
