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
        public static int Run(Config cfg, string script, IList<string> positional)
        {
            var psi = new ProcessStartInfo(FindWsl(), WslArguments(cfg, script, positional));
            psi.UseShellExecute = false;
            // A wrapper ignores Ctrl+C for good, not only while wsl.exe runs: the event reaches this process
            // on a thread of its own, possibly after wsl.exe has ended, and must not end it before it hands
            // back the exit code of the utility.
            Console.CancelKeyPress += delegate(object sender, ConsoleCancelEventArgs e) { e.Cancel = true; };
            return RunInConsole(psi);
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
            string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            // A 32-bit process would be sent to SysWOW64, which has no wsl.exe.
            string system32 = !Environment.Is64BitProcess && Environment.Is64BitOperatingSystem ? "Sysnative" : "System32";
            string path = Path.Combine(Path.Combine(windows, system32), "wsl.exe");
            if (!File.Exists(path))
                throw new WslbinException("wsl.exe not found, so WSL is not installed (fix: run 'wsl --install' as administrator)");
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
