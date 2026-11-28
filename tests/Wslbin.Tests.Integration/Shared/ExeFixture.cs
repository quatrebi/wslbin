using System.Diagnostics;
using System.Reflection;

[assembly: AssemblyFixture(typeof(Wslbin.Tests.ExeFixture))]

namespace Wslbin.Tests;

/// <summary>
/// The program under test, as a file: WSLBIN_TEST_EXE when that names one (CI builds once and sets it), otherwise
/// the result of build.ps1, made once for the whole run under the named mutex Global\wslbin-build (two runs at
/// once share obj\ of the repository and must not build at the same time). Also the test build with the stand-in
/// for wsl.exe as its entry point, made the first time a test asks for it.
/// </summary>
public sealed class ExeFixture : IAsyncLifetime
{
    readonly string work = Path.Combine(Path.GetTempPath(), "wslbin-integration-" + Guid.NewGuid().ToString("N"));
    readonly Lazy<string> variant;

    public ExeFixture()
    {
        variant = new(() =>
        {
            string exe = Path.Combine(work, "variant", "wslbin.exe");
            string entry = Path.Combine(RepositoryRoot, "tests", "Wslbin.Tests.Integration", "Shared", "FakeWslEntry.cs");
            Build(exe, ["-ExtraSource", entry, "-Main", "Wslbin.FakeWslEntry"]);
            return exe;
        });
    }

    /// <summary>The folder of the repository, from the metadata that the project writes.</summary>
    public static string RepositoryRoot => Metadata("RepositoryRoot");

    /// <summary>The stand-in for wsl.exe (tests\FakeWsl).</summary>
    public static string FakeWslExe => Metadata("FakeWslExe");

    /// <summary>A folder of this run, deleted at its end.</summary>
    public string Work => work;

    /// <summary>The program: wslbin.exe as built (or given).</summary>
    public string Exe { get; private set; } = "";

    /// <summary>The program built with tests\...\FakeWslEntry.cs as its entry point (see FakeWslEntry.cs).</summary>
    public string FakeWslBuild => variant.Value;

    static string Metadata(string key) =>
        typeof(ExeFixture).Assembly.GetCustomAttributes<AssemblyMetadataAttribute>().Single(a => a.Key == key).Value
        ?? throw new InvalidOperationException($"no assembly metadata {key}");

    public ValueTask InitializeAsync()
    {
        Directory.CreateDirectory(work);
        Exe = Path.Combine(work, "wslbin.exe");
        string? given = Environment.GetEnvironmentVariable("WSLBIN_TEST_EXE");
        if (!string.IsNullOrEmpty(given))
        {
            if (!File.Exists(given)) throw new FileNotFoundException($"WSLBIN_TEST_EXE names no file: {given}");
            File.Copy(given, Exe);
            Log($"program: {given} (WSLBIN_TEST_EXE), {new FileInfo(Exe).Length} bytes");
        }
        else
        {
            Build(Exe, []);
        }
        return ValueTask.CompletedTask;
    }

    public ValueTask DisposeAsync()
    {
        try
        {
            Directory.Delete(work, true);
        }
        catch (IOException)
        {
            // a stand-in that is still running keeps its folder: the system cleans the temporary folder later
        }
        catch (UnauthorizedAccessException)
        {
        }
        return ValueTask.CompletedTask;
    }

    static void Log(string message) => TestContext.Current.SendDiagnosticMessage(message);

    static void Build(string output, string[] extra)
    {
        var watch = Stopwatch.StartNew();
        using var mutex = new Mutex(false, @"Global\wslbin-build");
        bool owned = false;
        try
        {
            try
            {
                owned = mutex.WaitOne(TimeSpan.FromMinutes(20));
            }
            catch (AbandonedMutexException)
            {
                owned = true;     // whoever held it died: the build is ours now
            }
            if (!owned) throw new TimeoutException("another build of wslbin held Global\\wslbin-build for 20 minutes");
            Directory.CreateDirectory(Path.GetDirectoryName(output)!);
            var psi = new ProcessStartInfo(Powershell())
            {
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                WorkingDirectory = RepositoryRoot
            };
            string[] fixedArguments = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", Path.Combine(RepositoryRoot, "build.ps1"), "-Output", output];
            foreach (string a in fixedArguments.Concat(extra)) psi.ArgumentList.Add(a);
            using Process p = Process.Start(psi)!;
            Task<string> stdout = p.StandardOutput.ReadToEndAsync();
            Task<string> stderr = p.StandardError.ReadToEndAsync();
            p.WaitForExit();
            if (p.ExitCode != 0 || !File.Exists(output))
                throw new InvalidOperationException($"build.ps1 failed ({p.ExitCode}): {stderr.Result}{stdout.Result}");
        }
        finally
        {
            if (owned) mutex.ReleaseMutex();
        }
        string version = FileVersionInfo.GetVersionInfo(output).ProductVersion ?? "?";
        Log($"program: built {output}, version {version}, {new FileInfo(output).Length} bytes, {watch.Elapsed.TotalSeconds:F1} s");
    }

    static string Powershell()
    {
        foreach (string dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            string candidate = Path.Combine(dir.Trim().Trim('"'), "pwsh.exe");
            if (File.Exists(candidate)) return candidate;
        }
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
    }
}
