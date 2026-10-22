// wslbin: starting wsl.exe for a utility: its command line, the console, the exit code.

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Text;

namespace Wslbin
{
    // wsl.exe -d <distro> --exec bash --noprofile --norc -c <script>
    // No profile and no rc files: that keeps the start fast. Standard input and output are not
    // touched: the child inherits the console, so TUIs, colours, pipes and Ctrl+C work.
    internal static class Launcher
    {
        // Set only by the entry point of the test build (tests/FakeWslEntry.cs), which puts a stand-in
        // for wsl.exe here; wslbin.exe is built without that file and always runs the real one.
        internal static string WslPathOverride = null;

        public static int Run(Config cfg, string script, IList<string> positional, EnvPlan env)
        {
            string problem = FolderProblem(cfg);
            if (problem != null) throw new WslbinException(problem);

            var psi = new ProcessStartInfo(FindWsl(), WslArguments(cfg, FolderGuard(cfg) + script, positional));
            psi.UseShellExecute = false;
            env.ApplyTo(psi);
            // A wrapper ignores Ctrl+C for good, not only while wsl.exe runs: the event reaches this process
            // on a thread of its own, possibly after wsl.exe has ended, and must not end it before it hands
            // back the exit code of the utility.
            Console.CancelKeyPress += delegate(object sender, ConsoleCancelEventArgs e) { e.Cancel = true; };
            int code = RunInConsole(psi);

            // Without WSL, wsl.exe answers with its usage text and an exit code (1 on Windows 10) that a
            // script would take for the utility's own. With no distribution there was no utility.
            if (code != 0 && !WslQuery.HasDistribution())
            {
                Out.Error("wslbin: WSL is not installed, or has no distribution, so wsl.exe answered instead of " +
                          "running the command (fix: " + WslQuery.InstallFix + ")");
                return ExitCodes.Failed;
            }
            return code;
        }

        // wsl.exe starts the child in the Linux name of the current folder, and in the Linux home folder
        // when the folder has none (a network path \\server\share, a folder of another distribution):
        // "rm *.log" would then work on files that the user is not looking at. Why the command cannot
        // run here, or null.
        internal static string FolderProblem(Config cfg)
        {
            string folder = CurrentFolder();
            if (folder == null) return null;
            if (!Paths.HasLinuxPath(folder, cfg))
                return "the current folder " + folder + " has no Linux path, so the command would run in your Linux " +
                       "home folder instead; change to a folder on a drive (C:\\...) first";
            // without distro in wslbin.ini wsl.exe runs the default distribution, which cannot enter a folder of another one
            string distro = Paths.DistributionOf(folder);
            string runsIn = cfg.Distro.Length > 0 ? cfg.Distro : WslQuery.DefaultDistribution();
            if (distro != null && runsIn != null && !distro.Equals(runsIn, StringComparison.OrdinalIgnoreCase))
                return "the current folder " + folder + " is in the distribution " + distro + ", but wslbin runs in " + runsIn +
                       ", so the command would run in your Linux home folder there; set distro = " + distro +
                       " in wslbin.ini, or change to another folder";
            return null;
        }

        // A drive that WSL has not mounted (subst, a network drive) looks to wslbin like any other: wsl.exe
        // then says "Failed to translate" and runs the command in the Linux home folder (checked). So the
        // script itself checks first: to be in $HOME when the folder is not $HOME means that wsl.exe could
        // not enter it. Not in --wslbin-explain: like the handling of empty arguments, it is plumbing.
        internal static string FolderGuard(Config cfg)
        {
            string folder = CurrentFolder();
            string linux = folder == null ? null : Paths.LinuxPathOf(folder, cfg);
            if (linux == null) return "";
            return "if [ \"$PWD\" = \"$HOME\" ] && ! [ \"$PWD\" -ef " + Bash.Literal(linux) + " ]; then " +
                   "printf 'wslbin: WSL cannot enter %s (a drive that WSL has not mounted?), so the command would run in your " +
                   "Linux home folder instead; it was not run\\n' " + Bash.Literal(folder) + " >&2; exit 125; fi; ";
        }

        // The folder this process runs in, or null in the unlikely case that it cannot be read.
        internal static string CurrentFolder()
        {
            try { return Directory.GetCurrentDirectory(); }
            catch (IOException) { return null; }
            catch (UnauthorizedAccessException) { return null; }
        }

        // Runs a child that shares the console and returns its exit code.
        public static int RunInConsole(ProcessStartInfo psi)
        {
            // Ctrl+C reaches every process on the console, wsl.exe and the Linux side included. While the
            // child runs, this process must survive it to hand back the child's exit code; afterwards
            // Ctrl+C stops wslbin again.
            ConsoleCancelEventHandler survive = delegate(object sender, ConsoleCancelEventArgs e) { e.Cancel = true; };
            Console.CancelKeyPress += survive;
            try
            {
                using (Process process = Process.Start(psi))
                {
                    process.WaitForExit();
                    return MapExitCode(process.ExitCode);
                }
            }
            catch (Win32Exception ex)
            {
                throw new WslbinException("cannot start " + psi.FileName + ": " + ex.Message);
            }
            finally
            {
                Console.CancelKeyPress -= survive;
            }
        }

        // Exit codes of Linux programs are 0..255 and pass through. wsl.exe reports its own
        // failures (no such distribution, WSL not set up) as -1 or an NTSTATUS: those become 125.
        internal static int MapExitCode(int code)
        {
            if (code >= 0 && code <= 255) return code;
            if (code == unchecked((int)0xC000013A)) return ExitCodes.Interrupted;   // STATUS_CONTROL_C_EXIT
            return ExitCodes.Failed;
        }

        internal static string FindWsl()
        {
            if (WslPathOverride != null) return WslPathOverride;
            string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            // A 32-bit process would be sent to SysWOW64, which has no wsl.exe.
            string system32 = !Environment.Is64BitProcess && Environment.Is64BitOperatingSystem ? "Sysnative" : "System32";
            string path = Path.Combine(Path.Combine(windows, system32), "wsl.exe");
            if (!File.Exists(path))
                throw new WslbinException("wsl.exe not found, so WSL is not installed (fix: " + WslQuery.InstallFix + ")");
            return path;
        }

        const string EmptyArgumentPrefix =
            "a=(\"$@\"); for i in \"${!a[@]}\"; do [[ ${a[i]} == $'\\001' ]] && a[i]=''; done; set -- \"${a[@]}\"; " +
            "[[ $0 == $'\\001' ]] && BASH_ARGV0=''; unset a i; ";

        internal static string WslArguments(Config cfg, string script, IList<string> positional)
        {
            var sb = new StringBuilder();
            if (cfg.Distro.Length > 0)
            {
                sb.Append("-d ");
                AppendWindowsArg(sb, cfg.Distro);
                sb.Append(' ');
            }
            sb.Append("--exec bash --noprofile --norc -c ");

            // wsl.exe refuses an empty argument (E_INVALIDARG), so an empty positional parameter travels
            // as the control character SOH, and the script turns each of them back into an empty string
            // first: $1 and up through set --, $0 through BASH_ARGV0 (assigning to it sets $0).
            bool anyEmpty = false;
            foreach (string p in positional)
            {
                if (p.Length == 0) anyEmpty = true;
            }
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
            if (arg.Length > 0 && arg.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '"' }) < 0)
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
                    sb.Append('\\', backslashes * 2 + 1);
                    sb.Append('"');
                }
                else
                {
                    sb.Append('\\', backslashes);
                    sb.Append(c);
                }
                backslashes = 0;
            }
            // Backslashes before the closing quote are doubled so that they do not escape it.
            sb.Append('\\', backslashes * 2);
            sb.Append('"');
        }
    }
}
