using System.Diagnostics;
using System.Text;

namespace Wslbin.Tests;

/// <summary>What a program wrote, as bytes and as UTF-8 text, and its exit code.</summary>
public sealed record RunResult(int ExitCode, byte[] OutBytes, byte[] ErrBytes)
{
    public string Out => Encoding.UTF8.GetString(OutBytes);

    public string Err => Encoding.UTF8.GetString(ErrBytes);
}

/// <summary>Runs programs of the tests with an environment of their own (never the real folders of Claude Code and Codex).</summary>
public static class Runner
{
    /// <summary>A new folder inside the folder of this run.</summary>
    public static string NewDir(ExeFixture fixture)
    {
        string dir = Path.Combine(fixture.Work, Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        return dir;
    }

    /// <summary>A copy of the program named after a utility ("rsync" becomes rsync.exe) in a folder of its own, with its wslbin.ini.</summary>
    public static string Place(ExeFixture fixture, string name, string? ini = null, string? from = null, string? dir = null)
    {
        dir ??= NewDir(fixture);
        string exe = Path.Combine(dir, name + ".exe");
        if (!File.Exists(exe)) File.Copy(from ?? fixture.Exe, exe);
        if (ini != null) File.WriteAllText(Path.Combine(dir, "wslbin.ini"), ini, new UTF8Encoding(false));
        return exe;
    }

    public static async Task<RunResult> RunAsync(string exe, IEnumerable<string> args, string? workingDirectory = null,
                                                 IDictionary<string, string?>? env = null, byte[]? stdin = null,
                                                 TimeSpan? timeout = null)
    {
        var psi = new ProcessStartInfo(exe)
        {
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = workingDirectory ?? Path.GetDirectoryName(exe)!
        };
        foreach (string a in args) psi.ArgumentList.Add(a);
        psi.Environment.Remove("WSLENV");
        // a test never puts the question for administrator rights on the screen, and --install-ai-context never
        // finds the real folders of the agents
        psi.Environment["WSLBIN_NO_ELEVATION"] = "1";
        psi.Environment["CLAUDE_CONFIG_DIR"] = Path.Combine(Path.GetTempPath(), "wslbin-no-claude-folder-here");
        psi.Environment["CODEX_HOME"] = Path.Combine(Path.GetTempPath(), "wslbin-no-codex-folder-here");
        foreach ((string key, string? value) in env ?? new Dictionary<string, string?>())
        {
            if (value == null) psi.Environment.Remove(key);
            else psi.Environment[key] = value;
        }

        using Process p = Process.Start(psi)!;
        Task<byte[]> stdout = ReadAll(p.StandardOutput.BaseStream);
        Task<byte[]> stderr = ReadAll(p.StandardError.BaseStream);
        if (stdin != null) await p.StandardInput.BaseStream.WriteAsync(stdin, TestContext.Current.CancellationToken);
        p.StandardInput.Close();
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        cts.CancelAfter(timeout ?? TimeSpan.FromMinutes(2));
        try
        {
            await p.WaitForExitAsync(cts.Token);
        }
        catch (OperationCanceledException)
        {
            p.Kill(true);
            throw;
        }
        return new RunResult(p.ExitCode, await stdout, await stderr);
    }

    static async Task<byte[]> ReadAll(Stream stream)
    {
        using var buffer = new MemoryStream();
        await stream.CopyToAsync(buffer);
        return buffer.ToArray();
    }
}

/// <summary>
/// Tools that the tests need from the machine. Where one is missing the test is skipped, except when
/// WSLBIN_REQUIRE_TOOLS=1 (CI): then a missing tool is a failure, so that a runner without it cannot make a test
/// pass by not running it.
/// </summary>
public static class Tools
{
    static readonly Lazy<string?> GitBashPath = new(FindGitBash);

    public static bool Required => Environment.GetEnvironmentVariable("WSLBIN_REQUIRE_TOOLS") == "1";

    /// <summary>bash.exe of Git for Windows. Never the bash of PATH: that may be System32\bash.exe, which is WSL.</summary>
    public static string GitBash()
    {
        if (GitBashPath.Value is string path) return path;
        const string Why = "Git Bash (bash.exe of Git for Windows) was not found";
        if (Required) Assert.Fail($"{Why}, and WSLBIN_REQUIRE_TOOLS=1 says that it must be there");
        Assert.Skip(Why);
        return "";
    }

    static string? FindGitBash()
    {
        try
        {
            var psi = new ProcessStartInfo("git", "--exec-path") { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
            using Process p = Process.Start(psi)!;
            string execPath = p.StandardOutput.ReadToEnd().Trim();
            p.WaitForExit();
            if (p.ExitCode == 0 && execPath.Length > 0)
            {
                // <git>\mingw64\libexec\git-core -> <git>\bin\bash.exe
                string candidate = Path.GetFullPath(Path.Combine(execPath.Replace('/', '\\'), "..", "..", "..", "bin", "bash.exe"));
                if (File.Exists(candidate)) return candidate;
                candidate = Path.GetFullPath(Path.Combine(execPath.Replace('/', '\\'), "..", "..", "bin", "bash.exe"));
                if (File.Exists(candidate)) return candidate;
            }
        }
        catch (System.ComponentModel.Win32Exception)
        {
            // no git in PATH: the usual places will do
        }
        foreach (string? root in new[] { Environment.GetEnvironmentVariable("ProgramFiles"), Environment.GetEnvironmentVariable("ProgramFiles(x86)") })
        {
            if (string.IsNullOrEmpty(root)) continue;
            string candidate = Path.Combine(root, "Git", "bin", "bash.exe");
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }

    /// <summary>Runs a bash script, given on standard input as UTF-8, in Git Bash in a folder.</summary>
    public static async Task<RunResult> RunGitBashAsync(string script, string workingDirectory, IDictionary<string, string?>? env = null) =>
        await Runner.RunAsync(GitBash(), ["--noprofile", "--norc", "-s"], workingDirectory, env, new UTF8Encoding(false).GetBytes(script + "\n"));
}
