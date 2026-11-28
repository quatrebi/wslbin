// wslbin: starting wsl.exe for a utility: its command line, the console, the exit code.

using System.Buffers;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace Wslbin;

// wsl.exe -d <distro> --exec bash --noprofile --norc -c <script>
// No profile and no rc files: that keeps the start fast. Standard input and output are not
// touched: the child inherits the console, so TUIs, colours, pipes and Ctrl+C work.
internal static class Launcher
{
    // what makes a Windows command-line argument need quotes
    static readonly SearchValues<char> NeedsQuotes = SearchValues.Create(" \t\n\v\"");

    public static int Run(Config cfg, string script, IList<string> positional, EnvPlan env)
    {
        string? problem = Folder.Problem(cfg);
        if (problem != null) throw new WslbinException(problem);

        IHost host = Host.Current;
        var psi = new ProcessStartInfo(FindWsl(), WslArguments(cfg, Folder.Guard(cfg) + script, positional)) { UseShellExecute = false };
        env.ApplyTo(psi);
        // A wrapper ignores Ctrl+C until it ends, not only while wsl.exe runs: the event reaches this process
        // on a thread of its own, possibly after wsl.exe has ended, and must not end it before it hands
        // back the exit code of the utility.
        using IDisposable ignoreCtrlC = host.IgnoreCtrlC();
        int code = RunInConsole(psi);

        // Without WSL, wsl.exe answers with its usage text and an exit code (1 on Windows 10) that a
        // script would take for the utility's own. With no distribution there was no utility.
        if (code != 0 && !host.HasDistribution())
        {
            Out.Fail("WSL is not installed, or has no distribution, so wsl.exe answered instead of " +
                     $"running the command (fix: {WslQuery.InstallFix})");
            return ExitCodes.Failed;
        }
        return code;
    }

    // Runs a child that shares the console (a wrapper's utility, apt) and returns its exit code.
    public static int RunInConsole(ProcessStartInfo psi)
    {
        IHost host = Host.Current;
        // Ctrl+C reaches every process on the console, wsl.exe and the Linux side included. While the
        // child runs, this process must survive it to hand back the child's exit code; afterwards
        // (the next question of --link, say) Ctrl+C stops wslbin again.
        using IDisposable survive = host.IgnoreCtrlC();
        return MapExitCode(host.RunInConsole(psi));
    }

    /// <summary>What a child wrote, and its exit code.</summary>
    public sealed record Captured(int ExitCode, byte[] Output, byte[] Error);

    // Runs a child with all three streams its own (input closed at once) and returns what it wrote.
    // A child that has not ended, or whose streams are still held open (by a process it left behind),
    // after timeoutMs is given up on: null.
    public static Captured? Capture(ProcessStartInfo psi, int timeoutMs) => Host.Current.Capture(psi, timeoutMs);

    // Exit codes of Linux programs are 0..255 and pass through. wsl.exe reports its own
    // failures (no such distribution, WSL not set up) as -1 or an NTSTATUS: those become 125.
    internal static int MapExitCode(int code) => code switch
    {
        >= 0 and <= 255 => code,
        unchecked((int)0xC000013A) => ExitCodes.Interrupted,   // STATUS_CONTROL_C_EXIT
        _ => ExitCodes.Failed
    };

    internal static string FindWsl()
    {
        IHost host = Host.Current;
        // a stand-in for wsl.exe: set by the test entry point only, never in wslbin.exe
        if (host.WslPathOverride != null) return host.WslPathOverride;
        // A 32-bit process would be sent to SysWOW64, which has no wsl.exe.
        string system32 = host.IsWow64 ? "Sysnative" : "System32";
        string path = Path.Combine(host.WindowsDirectory, system32, "wsl.exe");
        if (!File.Exists(path))
            throw new WslbinException($"wsl.exe not found, so WSL is not installed (fix: {WslQuery.InstallFix})");
        return path;
    }

    const string EmptyArgumentPrefix =
        "a=(\"$@\"); for i in \"${!a[@]}\"; do [[ ${a[i]} == $'\\001' ]] && a[i]=''; done; set -- \"${a[@]}\"; " +
        "[[ $0 == $'\\001' ]] && BASH_ARGV0=''; unset a i; ";

    // "-d <distro> " when wslbin.ini names a distribution, for the command line of wsl.exe.
    internal static void AppendDistro(StringBuilder sb, Config cfg)
    {
        if (cfg.Distro.Length == 0) return;
        sb.Append("-d ");
        AppendWindowsArg(sb, cfg.Distro);
        sb.Append(' ');
    }

    internal static string WslArguments(Config cfg, string script, IList<string> positional)
    {
        var sb = new StringBuilder();
        AppendDistro(sb, cfg);
        sb.Append("--exec bash --noprofile --norc -c ");

        // wsl.exe refuses an empty argument (E_INVALIDARG), so an empty positional parameter travels
        // as the control character SOH, and the script turns each of them back into an empty string
        // first: $1 and up through set --, $0 through BASH_ARGV0 (assigning to it sets $0).
        bool anyEmpty = positional.Any(p => p.Length == 0);
        AppendWindowsArg(sb, (anyEmpty ? EmptyArgumentPrefix : "") + script);

        // The "wslbin -c" form and the completion helper have these. As with "bash -c", the
        // first becomes $0, the next $1, ...
        foreach (string p in positional)
        {
            sb.Append(' ');
            AppendWindowsArg(sb, p.Length == 0 ? "\u0001" : p);
        }
        return sb.ToString();
    }

    // Quoting for CommandLineToArgvW and the C runtime, which wsl.exe uses to read its arguments.
    internal static void AppendWindowsArg(StringBuilder sb, string arg)
    {
        if (arg.Length > 0 && !arg.AsSpan().ContainsAny(NeedsQuotes))
        {
            sb.Append(arg);
            return;
        }
        sb.Append('"');
        int backslashes = 0;
        foreach (char c in arg)
        {
            if (c == '\\')
            {
                backslashes++;
                continue;
            }
            if (c == '"')
            {
                // Backslashes before a quote are doubled, and the quote itself is escaped.
                sb.Append('\\', backslashes * 2 + 1).Append('"');
            }
            else
            {
                sb.Append('\\', backslashes).Append(c);
            }
            backslashes = 0;
        }
        // Backslashes before the closing quote are doubled so that they do not escape it.
        sb.Append('\\', backslashes * 2).Append('"');
    }
}

// A job object that ends what is in it when wslbin ends, however it ends: a caller that stops a
// wrapper (a timeout in a script, the stop button of an IDE) stops wsl.exe with it, and when wsl.exe
// ends, so does the Linux program (checked). Without it both would go on running and keep the
// caller's pipes open. Only wsl.exe itself is put in: what it starts may leave the job (silent
// breakaway), so a Windows program that the Linux one opened stays open.
internal static partial class ChildJob
{
    const int ExtendedLimitInformation = 9;
    const uint KillOnJobClose = 0x2000;
    const uint SilentBreakawayOk = 0x1000;

    [StructLayout(LayoutKind.Sequential)]
    struct BasicLimits
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public nuint MinimumWorkingSetSize;
        public nuint MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public nuint Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct ExtendedLimits
    {
        public BasicLimits Basic;
        public ulong ReadOperations, WriteOperations, OtherOperations, ReadBytes, WriteBytes, OtherBytes;
        public nuint ProcessMemoryLimit;
        public nuint JobMemoryLimit;
        public nuint PeakProcessMemoryUsed;
        public nuint PeakJobMemoryUsed;
    }

    [LibraryImport("kernel32.dll", EntryPoint = "CreateJobObjectW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    private static partial nint CreateJobObject(nint attributes, string? name);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetInformationJobObject(nint job, int infoClass, ref ExtendedLimits info, int length);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool AssignProcessToJobObject(nint job, nint process);

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CloseHandle(nint handle);

    // Never closed by wslbin: Windows closes it when this process ends, and that is what ends the job.
    // Not inheritable, or wsl.exe would hold it open itself.
    static nint job;
    // Add may be called from several threads at once (the unit tests run in parallel); one job is made
    static readonly Lock gate = new();

    // A failure here is not an error: the child then does not end with wslbin, as it never used to.
    public static void Add(Process process)
    {
        nint handle;
        lock (gate)
        {
            if (job == 0)
            {
                nint created = CreateJobObject(0, null);
                if (created == 0) return;
                var limits = new ExtendedLimits();
                limits.Basic.LimitFlags = KillOnJobClose | SilentBreakawayOk;
                if (!SetInformationJobObject(created, ExtendedLimitInformation, ref limits, Marshal.SizeOf<ExtendedLimits>()))
                {
                    CloseHandle(created);
                    return;
                }
                job = created;
            }
            handle = job;
        }
        try
        {
            AssignProcessToJobObject(handle, process.Handle);
        }
        catch (InvalidOperationException)
        {
            // it has ended already
        }
    }
}
