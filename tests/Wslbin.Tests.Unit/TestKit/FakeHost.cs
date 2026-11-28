using System.Diagnostics;
using System.Text;

namespace Wslbin.Tests;

/// <summary>
/// A machine for the program to run on: an environment, a current folder, a console and a WSL of its own.
/// Use it as: using var scope = Host.Use(fake). Nothing reaches the real machine through it.
/// </summary>
internal sealed class FakeHost : IHost
{
    public const string WrapperProduct = "wslbin";
    public const string ExeText = "FAKE-WSLBIN-EXE";

    readonly StringBuilder stdout = new();
    readonly StringBuilder stderr = new();
    readonly Queue<string?> answers = new();

    public Dictionary<string, string> Env { get; } = new(StringComparer.OrdinalIgnoreCase);
    public string? ProcessPathValue { get; set; } = @"C:\fake\wslbin.exe";
    public string? Cwd { get; set; } = @"C:\work";
    public string WindowsDirectoryValue { get; set; } = @"C:\Windows";
    public string SystemDirectoryValue { get; set; } = @"C:\Windows\System32";
    public bool IsWow64Value { get; set; }
    public int UiLanguage { get; set; } = 0x0409;
    public string? WslPathValue { get; set; } = @"C:\fake\wsl.exe";
    public int QueryTimeout { get; set; } = 5000;
    public bool HasDistributionValue { get; set; } = true;
    public string? DefaultDistributionValue { get; set; }
    public string UserPath { get; set; } = "";
    public string MachinePath { get; set; } = "";
    public bool Interactive { get; set; }
    public Encoding ConsoleEncoding { get; set; } = Encoding.UTF8;
    public bool CtrlCIgnored { get; private set; }
    public int CtrlCSubscriptions { get; private set; }
    public int? ElevatedResult { get; set; }
    /// <summary>What the elevated copy does (it runs in this process); its exit code. Null: nothing happens.</summary>
    public Func<string, string, int?>? OnElevated { get; set; }

    /// <summary>Which files are wrappers: the product name of a file whose content starts with ExeText.</summary>
    public Func<string, string?> ProductName { get; set; } = DefaultProductName;

    public List<ProcessStartInfo> ConsoleRuns { get; } = [];
    /// <summary>Every call of wsl.exe that the program read the answer of, in order.</summary>
    public List<WslCall> Calls { get; } = [];
    public List<(string Exe, string Arguments)> ElevatedCalls { get; } = [];
    public List<string> Questions { get; } = [];

    public Func<ProcessStartInfo, int> OnRunInConsole { get; set; } = _ => 0;
    public Func<WslCall, Launcher.Captured?> OnWsl { get; set; } = _ => Reply(0, "");

    public string Out => stdout.ToString();
    public string Err => stderr.ToString();

    public static Launcher.Captured Reply(int exit, string output = "", string error = "") =>
        new(exit, Encoding.UTF8.GetBytes(output), Encoding.UTF8.GetBytes(error));

    public static Launcher.Captured ReplyUtf16(int exit, string output = "", string error = "") =>
        new(exit, Encoding.Unicode.GetBytes(output), Encoding.Unicode.GetBytes(error));

    public void Answer(string? line) => answers.Enqueue(line);

    public void ClearOutput()
    {
        stdout.Clear();
        stderr.Clear();
    }

    static string? DefaultProductName(string path)
    {
        try
        {
            return File.ReadAllText(path).StartsWith(ExeText, StringComparison.Ordinal) ? WrapperProduct : null;
        }
        catch (IOException)
        {
            return null;
        }
    }

    // ---- IHost ----

    public string? GetEnv(string name) => Env.GetValueOrDefault(name);

    public IEnumerable<KeyValuePair<string, string>> GetEnvironment() => Env;

    public string? ProcessPath => ProcessPathValue;

    public string GetCurrentDirectory() => Cwd ?? throw new IOException("no current folder");

    public string WindowsDirectory => WindowsDirectoryValue;

    public string SystemDirectory => SystemDirectoryValue;

    public bool IsWow64 => IsWow64Value;

    public int UserUiLanguage() => UiLanguage & 0x3FF;

    public string? ProductNameOf(string path) => ProductName(path);

    public string? WslPathOverride => WslPathValue;

    public int QueryTimeoutMs => QueryTimeout;

    public bool HasDistribution() => HasDistributionValue;

    public string? DefaultDistribution() => DefaultDistributionValue;

    public string RegistryPath(bool machine) => machine ? MachinePath : UserPath;

    public void Write(bool toError, string text) => (toError ? stderr : stdout).Append(text).Append('\n');

    public bool IsInteractive => Interactive;

    public string? Ask(string question)
    {
        Questions.Add(question);
        return answers.Count > 0 ? answers.Dequeue() : null;
    }

    public Encoding ConsoleOutputEncoding => ConsoleEncoding;

    public IDisposable IgnoreCtrlC()
    {
        CtrlCSubscriptions++;
        CtrlCIgnored = true;
        return new Release(this);
    }

    sealed class Release(FakeHost host) : IDisposable
    {
        public void Dispose() => host.CtrlCSubscriptions--;
    }

    public int RunInConsole(ProcessStartInfo psi)
    {
        ConsoleRuns.Add(psi);
        return OnRunInConsole(psi);
    }

    public Launcher.Captured? Capture(ProcessStartInfo psi, int timeoutMs)
    {
        var call = new WslCall(psi, timeoutMs) { Number = Calls.Count + 1 };
        Calls.Add(call);
        return OnWsl(call);
    }

    public int? RunElevated(string exePath, string arguments)
    {
        ElevatedCalls.Add((exePath, arguments));
        return OnElevated != null ? OnElevated(exePath, arguments) : ElevatedResult;
    }
}

/// <summary>One call of wsl.exe that the program reads the answer of, taken apart.</summary>
internal sealed class WslCall
{
    public WslCall(ProcessStartInfo psi, int timeoutMs)
    {
        Psi = psi;
        TimeoutMs = timeoutMs;
        Args = WindowsCommandLine.Split(psi.Arguments);
        int c = Args.IndexOf("-c");
        Script = c >= 0 && c + 1 < Args.Count ? Args[c + 1] : null;
        Positional = c >= 0 ? [.. Args.Skip(c + 2)] : [];
    }

    public ProcessStartInfo Psi { get; }
    /// <summary>1 for the first call of the run.</summary>
    public int Number { get; init; }
    public int TimeoutMs { get; }
    public List<string> Args { get; }
    /// <summary>The bash string of a "bash -c" call, null for a call of wsl.exe's own (-l -v).</summary>
    public string? Script { get; }
    public List<string> Positional { get; }
    public bool IsList => Args.Count > 0 && Args[0] == "-l";
}

/// <summary>CommandLineToArgvW and the C runtime: what wsl.exe makes of its command line.</summary>
internal static class WindowsCommandLine
{
    public static List<string> Split(string commandLine)
    {
        List<string> result = [];
        var current = new StringBuilder();
        bool inWord = false, quoted = false;
        for (int i = 0; i < commandLine.Length; i++)
        {
            char c = commandLine[i];
            if (c == '\\')
            {
                int n = 0;
                while (i < commandLine.Length && commandLine[i] == '\\') { n++; i++; }
                if (i < commandLine.Length && commandLine[i] == '"')
                {
                    current.Append('\\', n / 2);
                    if (n % 2 == 1) { current.Append('"'); inWord = true; continue; }
                    i--;
                    inWord = true;
                    continue;
                }
                current.Append('\\', n);
                inWord = true;
                i--;
            }
            else if (c == '"')
            {
                quoted = !quoted;
                inWord = true;
            }
            else if ((c == ' ' || c == '\t') && !quoted)
            {
                if (inWord) result.Add(current.ToString());
                current.Clear();
                inWord = false;
            }
            else
            {
                current.Append(c);
                inWord = true;
            }
        }
        if (inWord) result.Add(current.ToString());
        return result;
    }
}
