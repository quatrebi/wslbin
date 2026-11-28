// wslbin: the machine the program runs on (environment, console, registry, processes), behind IHost.

using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security;
using System.Text;
using Microsoft.Win32;

namespace Wslbin;

// Everything that the program takes from, or does to, the machine outside its own files: environment
// variables, the current folder, the console, the registry, Windows itself, other processes. The code in
// src\ reaches them only through Host.Current (tests\BannedSymbols.Src.txt makes the build refuse the
// APIs themselves anywhere but here), so that a unit test can run a command against a machine of its own
// (tests\Wslbin.Tests.Unit\FakeHost.cs). Files are not behind it: the tests use folders of their own.
internal interface IHost
{
    // ---- environment and Windows ----

    /// <summary>The value of an environment variable, or null.</summary>
    string? GetEnv(string name);

    /// <summary>Every environment variable of this process.</summary>
    IEnumerable<KeyValuePair<string, string>> GetEnvironment();

    /// <summary>The path of the running program, or null when Windows does not say.</summary>
    string? ProcessPath { get; }

    /// <summary>The current folder. May throw IOException or UnauthorizedAccessException.</summary>
    string GetCurrentDirectory();

    string WindowsDirectory { get; }

    string SystemDirectory { get; }

    /// <summary>A 32-bit process on 64-bit Windows, which would be sent to SysWOW64.</summary>
    bool IsWow64 { get; }

    /// <summary>The language of the user interface of Windows (a LANGID).</summary>
    int UserUiLanguage();

    /// <summary>The ProductName of the version resource of a file; null when it has none or cannot be read.</summary>
    string? ProductNameOf(string path);

    // ---- WSL ----

    /// <summary>
    /// A program to run instead of wsl.exe. Always null in wslbin.exe: only the test build of the entry
    /// point tests\Wslbin.Tests.Integration\Shared\FakeWslEntry.cs sets it, so that nothing in the
    /// environment of wslbin.exe can change which program it runs.
    /// </summary>
    string? WslPathOverride { get; }

    /// <summary>How long a call to wsl.exe whose output is read may take.</summary>
    int QueryTimeoutMs { get; }

    /// <summary>
    /// Whether WSL has a distribution for this user: one registry key each under
    /// HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss. A registry that cannot be read says true, so
    /// that the exit code of the utility stands.
    /// </summary>
    bool HasDistribution();

    /// <summary>The name of the default distribution, from the registry; null when it does not say. Read once.</summary>
    string? DefaultDistribution();

    /// <summary>The Path of the environment of the user, or of the machine, from the registry, expanded.</summary>
    string RegistryPath(bool machine);

    // ---- console ----

    /// <summary>Writes the text and a line break to standard output (or standard error).</summary>
    void Write(bool toError, string text);

    /// <summary>Whether a person can answer a question: neither input nor output is redirected.</summary>
    bool IsInteractive { get; }

    /// <summary>Asks a question on the console and reads one line; null at the end of the input.</summary>
    string? Ask(string question);

    /// <summary>The encoding that console programs write in.</summary>
    Encoding ConsoleOutputEncoding { get; }

    /// <summary>
    /// Ctrl+C reaches every process on the console, a child's too. While this is not disposed, this process
    /// survives it, to hand back the exit code of the child.
    /// </summary>
    IDisposable IgnoreCtrlC();

    // ---- processes ----

    /// <summary>Runs a child that shares the console, and returns its exit code as Windows has it.</summary>
    int RunInConsole(ProcessStartInfo psi);

    /// <summary>Runs a child with its streams to itself; null when it did not end within timeoutMs.</summary>
    Launcher.Captured? Capture(ProcessStartInfo psi, int timeoutMs);

    /// <summary>
    /// Starts the program again with administrator rights and waits for it: its exit code, or null when
    /// they were declined.
    /// </summary>
    int? RunElevated(string exePath, string arguments);
}

internal static class Host
{
    static readonly AsyncLocal<IHost?> scope = new();

#if !WSLBIN_TESTABLE
    static readonly RealHost real = new();
#endif

    /// <summary>
    /// The machine that this code runs on. wslbin.exe has the real one. The library that the unit tests
    /// use (WSLBIN_TESTABLE) has none: a test says which machine it means with Host.Use, and one that
    /// forgets fails at once instead of reading or changing the machine it runs on.
    /// </summary>
    public static IHost Current
    {
        get
        {
            if (scope.Value is IHost host) return host;
#if WSLBIN_TESTABLE
            throw new InvalidOperationException("no Host.Use scope: a test must say which machine the code runs on (using var scope = Host.Use(...))");
#else
            return real;
#endif
        }
    }

    /// <summary>
    /// Makes host the machine for the code that runs from here on (and for the tasks it starts), until the
    /// result is disposed. Called by tests, and by the test entry point of the integration tests; never by
    /// wslbin.exe, which has no way to reach it (the trimmer drops it).
    /// </summary>
    public static IDisposable Use(IHost host)
    {
        IHost? previous = scope.Value;
        scope.Value = host;
        return new Restore(previous);
    }

    sealed class Restore(IHost? previous) : IDisposable
    {
        public void Dispose() => scope.Value = previous;
    }
}

// The machine itself. The parameters are for the test entry point (a stand-in for wsl.exe, what the registry
// says); wslbin.exe passes none of them.
internal sealed partial class RealHost(string? wslPath = null, bool? hasDistribution = null,
                                       string? defaultDistribution = null, int? queryTimeoutMs = null) : IHost
{
    const string LxssKey = @"Software\Microsoft\Windows\CurrentVersion\Lxss";
    const int StdOutput = -11;
    const int StdError = -12;
    const int Chunk = 8192;
    const int Cancelled = 1223;      // ERROR_CANCELLED: UAC was declined
    const int PrimaryLanguageMask = 0x3FF;

    // The registry is read once a run, however many arguments ask.
    readonly Lazy<string?> defaultDistributionFromRegistry = new(RegistryDefaultDistribution);

    // ---- environment and Windows ----

    public string? GetEnv(string name) => Environment.GetEnvironmentVariable(name);

    public IEnumerable<KeyValuePair<string, string>> GetEnvironment()
    {
        foreach (System.Collections.DictionaryEntry e in Environment.GetEnvironmentVariables())
            yield return new((string)e.Key, (string?)e.Value ?? "");
    }

    // not Assembly.Location: it is empty in a single-file program
    public string? ProcessPath => Environment.ProcessPath;

    public string GetCurrentDirectory() => Directory.GetCurrentDirectory();

    public string WindowsDirectory => Environment.GetFolderPath(Environment.SpecialFolder.Windows);

    public string SystemDirectory => Environment.SystemDirectory;

    public bool IsWow64 => !Environment.Is64BitProcess && Environment.Is64BitOperatingSystem;

    public int UserUiLanguage() => GetUserDefaultUILanguage() & PrimaryLanguageMask;

    public string? ProductNameOf(string path)
    {
        try
        {
            return FileVersionInfo.GetVersionInfo(path).ProductName;
        }
        catch (IOException)
        {
            return null;
        }
    }

    // The language of the user interface of Windows (a LANGID: the primary language is its low 10
    // bits). Asked of Windows and not of CultureInfo: the program is built with InvariantGlobalization,
    // which makes it smaller, and then CultureInfo knows no language.
    [LibraryImport("kernel32.dll")]
    private static partial ushort GetUserDefaultUILanguage();

    // ---- WSL ----

    public string? WslPathOverride => wslPath;

    // A WSL that has to start its virtual machine answers within seconds, one that is stuck never does, and
    // --doctor, --list and --link must not hang on it. Tab completion waits less (Completion.TimeoutMs).
    public int QueryTimeoutMs => queryTimeoutMs ?? 120_000;

    // WSL keeps one registry key each under Lxss, with the name in DistributionName (WSL 1, WSL 2 and
    // the Store version alike). Asked only after wsl.exe failed. A registry that cannot be read says
    // nothing, and then the exit code of the utility stands.
    public bool HasDistribution()
    {
        if (hasDistribution is bool known) return known;
        try
        {
            using RegistryKey? lxss = Registry.CurrentUser.OpenSubKey(LxssKey);
            if (lxss == null) return false;
            foreach (string name in lxss.GetSubKeyNames())
            {
                using RegistryKey? distro = lxss.OpenSubKey(name);
                if (distro?.GetValue("DistributionName") is string) return true;
            }
            return false;
        }
        catch (Exception ex) when (ex is SecurityException or UnauthorizedAccessException or IOException)
        {
            return true;
        }
    }

    // The Lxss key names the default distribution's key in DefaultDistribution.
    public string? DefaultDistribution() => defaultDistribution ?? defaultDistributionFromRegistry.Value;

    static string? RegistryDefaultDistribution()
    {
        try
        {
            using RegistryKey? lxss = Registry.CurrentUser.OpenSubKey(LxssKey);
            if (lxss?.GetValue("DefaultDistribution") is not string { Length: > 0 } id) return null;
            using RegistryKey? distro = lxss.OpenSubKey(id);
            return distro?.GetValue("DistributionName") as string;
        }
        catch (Exception ex) when (ex is SecurityException or UnauthorizedAccessException or IOException)
        {
            return null;
        }
    }

    public string RegistryPath(bool machine)
    {
        RegistryKey root = machine ? Registry.LocalMachine : Registry.CurrentUser;
        string subKey = machine ? @"SYSTEM\CurrentControlSet\Control\Session Manager\Environment" : "Environment";
        try
        {
            using RegistryKey? key = root.OpenSubKey(subKey);
            string? value = key?.GetValue("Path", "", RegistryValueOptions.DoNotExpandEnvironmentNames) as string;
            return Environment.ExpandEnvironmentVariables(value ?? "");
        }
        catch (Exception ex) when (ex is SecurityException or UnauthorizedAccessException or IOException)
        {
            return "";
        }
    }

    // ---- console ----

    // The console is written to in UTF-16, which any code page of the console can show; going
    // through Console.Out would turn what the code page lacks (Cyrillic under 437) into "?". When the
    // output goes to a file or a pipe it is written as UTF-8, which is also what bash reads.
    [LibraryImport("kernel32.dll", SetLastError = true)]
    private static partial nint GetStdHandle(int standardHandle);

    [LibraryImport("kernel32.dll", EntryPoint = "WriteConsoleW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool WriteConsole(nint console, string buffer, int length, out int written, nint reserved);

    // Writes the text and a line break to the console; returns what is left when that fails part way
    // (all of it when there is no console), or null when it is all written.
    static string? WriteToConsole(bool toError, string text)
    {
        string line = text.Replace("\r\n", "\n").Replace("\n", "\r\n") + "\r\n";
        nint handle = GetStdHandle(toError ? StdError : StdOutput);
        if (handle is 0 or -1) return line;
        int i = 0;
        while (i < line.Length)
        {
            int length = Math.Min(Chunk, line.Length - i);
            // a chunk must not end between the two halves of a surrogate pair
            if (i + length < line.Length && char.IsHighSurrogate(line[i + length - 1])) length--;
            if (!WriteConsole(handle, line.Substring(i, length), length, out int written, 0) || written <= 0) return line[i..];
            i += written;
        }
        return null;
    }

    public void Write(bool toError, string text)
    {
        try
        {
            bool redirected = toError ? Console.IsErrorRedirected : Console.IsOutputRedirected;
            if (!redirected)
            {
                if (WriteToConsole(toError, text) is string rest) (toError ? Console.Error : Console.Out).Write(rest);
                return;
            }
            byte[] bytes = Encoding.UTF8.GetBytes(text + "\n");
            using Stream stream = toError ? Console.OpenStandardError() : Console.OpenStandardOutput();
            stream.Write(bytes);
            stream.Flush();
        }
        catch (IOException)
        {
            // the reader has gone (wslbin --list | Select-Object -First 1): there is no one to tell
        }
    }

    public bool IsInteractive => !Console.IsInputRedirected && !Console.IsOutputRedirected;

    public string? Ask(string question)
    {
        Console.Write($"{question} [y/N] ");
        return Console.ReadLine();
    }

    public Encoding ConsoleOutputEncoding => Console.OutputEncoding;

    public IDisposable IgnoreCtrlC()
    {
        ConsoleCancelEventHandler survive = (_, e) => e.Cancel = true;
        Console.CancelKeyPress += survive;
        return new Unsubscribe(survive);
    }

    sealed class Unsubscribe(ConsoleCancelEventHandler handler) : IDisposable
    {
        public void Dispose() => Console.CancelKeyPress -= handler;
    }

    // ---- processes ----

    public int RunInConsole(ProcessStartInfo psi)
    {
        using Process process = Start(psi);
        ChildJob.Add(process);
        process.WaitForExit();
        return process.ExitCode;
    }

    public Launcher.Captured? Capture(ProcessStartInfo psi, int timeoutMs)
    {
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.RedirectStandardInput = true;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        var watch = Stopwatch.StartNew();
        using Process process = Start(psi);
        ChildJob.Add(process);
        process.StandardInput.Close();
        Task<byte[]> error = ReadAllAsync(process.StandardError.BaseStream);
        Task<byte[]> output = ReadAllAsync(process.StandardOutput.BaseStream);
        if (!process.WaitForExit(timeoutMs) || !Task.WaitAll([output, error], Remaining(watch, timeoutMs)))
        {
            // (the process only: Kill(entireProcessTree) would add a third of a megabyte to every
            // wrapper, and ChildJob ends wsl.exe with wslbin anyway)
            try { process.Kill(); }
            catch (Exception ex) when (ex is InvalidOperationException or Win32Exception) { }
            return null;
        }
        return new Launcher.Captured(process.ExitCode, output.Result, error.Result);
    }

    static int Remaining(Stopwatch watch, int timeoutMs) =>
        timeoutMs == Timeout.Infinite ? Timeout.Infinite : Math.Max(0, timeoutMs - (int)watch.ElapsedMilliseconds);

    static async Task<byte[]> ReadAllAsync(Stream stream)
    {
        using var buffer = new MemoryStream();
        await stream.CopyToAsync(buffer).ConfigureAwait(false);
        return buffer.ToArray();
    }

    static Process Start(ProcessStartInfo psi)
    {
        try
        {
            return Process.Start(psi) ?? throw new WslbinException($"cannot start {psi.FileName}: no process was started");
        }
        catch (Win32Exception ex)
        {
            throw new WslbinException($"cannot start {psi.FileName}: {ex.Message}");
        }
    }

    public int? RunElevated(string exePath, string arguments)
    {
        var psi = new ProcessStartInfo(exePath, arguments)
        {
            UseShellExecute = true,
            Verb = "runas",
            WindowStyle = ProcessWindowStyle.Hidden
        };
        try
        {
            using Process process = Process.Start(psi) ?? throw new WslbinException("cannot ask for administrator rights: no process was started");
            process.WaitForExit();
            return process.ExitCode;
        }
        catch (Win32Exception ex) when (ex.NativeErrorCode == Cancelled)
        {
            return null;
        }
        catch (Win32Exception ex)
        {
            throw new WslbinException($"cannot ask for administrator rights: {ex.Message}");
        }
    }
}
