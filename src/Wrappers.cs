// wslbin: wrapper files, the PATH of Windows, names that Windows uses, administrator rights.

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Text;

namespace Wslbin
{
    // Wrappers: copies of wslbin.exe, each named after a utility.
    internal static class Wrappers
    {
        public enum Change { Created, Updated, UpToDate }

        // A name that is safe as a file name, in a bash script and in a command line.
        public static bool IsValidName(string name)
        {
            if (name.Length == 0 || name.Length > 100) return false;
            if (!IsAlnum(name[0])) return false;
            foreach (char c in name)
            {
                if (!(IsAlnum(c) || c == '.' || c == '_' || c == '+' || c == '-')) return false;
            }
            if (name.EndsWith(".", StringComparison.Ordinal)) return false;      // Windows drops trailing dots
            if (name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) return false;
            if (name.Equals("wslbin", StringComparison.OrdinalIgnoreCase)) return false;
            return !IsDeviceName(name);
        }

        static bool IsAlnum(char c)
        {
            return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
        }

        // CON, NUL, COM1 ... cannot be file names, with or without an extension.
        static bool IsDeviceName(string name)
        {
            int dot = name.IndexOf('.');
            string stem = (dot < 0 ? name : name.Substring(0, dot)).ToUpperInvariant();
            if (stem == "CON" || stem == "PRN" || stem == "AUX" || stem == "NUL") return true;
            return (stem.StartsWith("COM", StringComparison.Ordinal) || stem.StartsWith("LPT", StringComparison.Ordinal)) &&
                   stem.Length == 4 && stem[3] >= '1' && stem[3] <= '9';
        }

        // Whether this user can make files in the folder, which tells "needs administrator rights"
        // from "this one file is locked".
        public static bool CanWrite(string dir)
        {
            string probe = Path.Combine(dir, ".wslbin-write-test-" + Guid.NewGuid().ToString("N"));
            try
            {
                File.WriteAllText(probe, "");
                File.Delete(probe);
                return true;
            }
            catch (UnauthorizedAccessException) { return false; }
            catch (IOException) { return false; }
        }

        public static string PathOf(string dir, string name)
        {
            return Path.Combine(dir, name + ".exe");
        }

        public static bool IsWrapperFile(string path)
        {
            try
            {
                return string.Equals(FileVersionInfo.GetVersionInfo(path).ProductName, "wslbin", StringComparison.Ordinal);
            }
            catch (IOException)
            {
                return false;
            }
        }

        // Names of the wrappers in dir, sorted. wslbin.exe itself is not one.
        public static List<string> Enumerate(string dir, string exePath)
        {
            var names = new List<string>();
            string self = Path.GetFileName(exePath);
            foreach (string file in Directory.GetFiles(dir, "*.exe"))
            {
                // The search pattern also matches longer extensions that start with "exe".
                if (!string.Equals(Path.GetExtension(file), ".exe", StringComparison.OrdinalIgnoreCase)) continue;
                if (string.Equals(Path.GetFileName(file), self, StringComparison.OrdinalIgnoreCase)) continue;
                if (IsWrapperFile(file)) names.Add(Path.GetFileNameWithoutExtension(file));
            }
            names.Sort(StringComparer.OrdinalIgnoreCase);
            return names;
        }

        // Copies wslbin.exe to <its folder>\<name>.exe. Throws UnauthorizedAccessException when the
        // folder is not writable for this user.
        public static Change Create(string exePath, string name)
        {
            string target = PathOf(Path.GetDirectoryName(exePath), name);
            bool existed = File.Exists(target);
            if (existed && SameContent(target, exePath)) return Change.UpToDate;
            File.Copy(exePath, target, true);
            return existed ? Change.Updated : Change.Created;
        }

        public static string Describe(Change change)
        {
            return change == Change.Created ? "created" : change == Change.Updated ? "updated" : "up to date";
        }

        public static bool SameContent(string a, string b)
        {
            try
            {
                var fa = new FileInfo(a);
                var fb = new FileInfo(b);
                if (!fa.Exists || !fb.Exists || fa.Length != fb.Length) return false;
                byte[] x = File.ReadAllBytes(a);
                byte[] y = File.ReadAllBytes(b);
                for (int i = 0; i < x.Length; i++)
                {
                    if (x[i] != y[i]) return false;
                }
                return true;
            }
            catch (IOException)
            {
                return false;
            }
        }
    }

    // The PATH of Windows: the folders it lists, and what a name finds in them.
    internal static class SearchPath
    {
        // The first <name><PATHEXT> in PATH outside skipDir, in the order of PATH; null when there is none.
        public static string Find(string name, string skipDir)
        {
            string pathext = Environment.GetEnvironmentVariable("PATHEXT");
            if (string.IsNullOrEmpty(pathext)) pathext = ".COM;.EXE;.BAT;.CMD";
            string[] extensions = pathext.Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries);

            string path = Environment.GetEnvironmentVariable("PATH") ?? "";
            foreach (string entry in path.Split(';'))
            {
                string dir = entry.Trim().Trim('"');
                if (dir.Length == 0 || SameFolder(dir, skipDir)) continue;
                foreach (string ext in extensions)
                {
                    string candidate;
                    try
                    {
                        candidate = Path.Combine(dir, name + ext);
                    }
                    catch (ArgumentException)
                    {
                        break;      // an entry with characters that no path can have
                    }
                    if (File.Exists(candidate)) return candidate;
                }
            }
            return null;
        }

        public static bool SameFolder(string a, string b)
        {
            try
            {
                return string.Equals(Path.GetFullPath(a).TrimEnd('\\'), Path.GetFullPath(b).TrimEnd('\\'),
                                     StringComparison.OrdinalIgnoreCase);
            }
            catch (ArgumentException) { return false; }
            catch (NotSupportedException) { return false; }
            catch (IOException) { return false; }
        }

        // Whether a ";"-list of folders (a PATH value) has dir in it, in any spelling.
        public static bool Contains(string pathList, string dir)
        {
            if (pathList == null) return false;
            foreach (string entry in pathList.Split(';'))
            {
                string e = entry.Trim().Trim('"');
                if (e.Length > 0 && SameFolder(e, dir)) return true;
            }
            return false;
        }
    }

    // Names that Windows already uses, so that a wrapper would clash with them.
    internal static class Conflicts
    {
        // cmd.exe runs these itself; a file with the same name is never started from cmd.
        static readonly HashSet<string> CmdBuiltIn = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "assoc", "break", "call", "cd", "chdir", "cls", "color", "copy", "date", "del", "dir", "echo",
            "endlocal", "erase", "exit", "for", "ftype", "goto", "graftabl", "if", "md", "mkdir", "mklink",
            "move", "path", "pause", "popd", "prompt", "pushd", "rd", "rem", "ren", "rename", "rmdir", "set",
            "setlocal", "shift", "start", "time", "title", "type", "ver", "verify", "vol"
        };

        // Aliases and functions of Windows PowerShell 5.1 and PowerShell 7 (Get-Alias, Get-Command on
        // 2026-10-21). PowerShell looks at them before it looks at files, so "ls" never starts ls.exe.
        static readonly HashSet<string> PowerShellNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "ac", "asnp", "cat", "cd", "chdir", "clc", "clear", "clhy", "cli", "clp", "cls", "clv", "cnsn",
            "compare", "copy", "cp", "cpi", "cpp", "curl", "cvpa", "dbp", "del", "diff", "dir", "dnsn", "ebp",
            "echo", "epal", "epcsv", "epsn", "erase", "etsn", "exsn", "fc", "fhx", "fl", "foreach", "ft", "fw",
            "gal", "gbp", "gc", "gci", "gcm", "gcs", "gdr", "gerr", "ghy", "gi", "gjb", "gl", "gm", "gmo", "gp",
            "gps", "gpv", "group", "gsn", "gsnp", "gsv", "gu", "gv", "gwmi", "h", "help", "history", "icm",
            "iex", "ihy", "ii", "ipal", "ipcsv", "ipmo", "ipsn", "irm", "ise", "iwmi", "iwr", "kill", "lp",
            "ls", "man", "md", "measure", "mi", "mkdir", "more", "mount", "move", "mp", "mv", "nal", "ndr",
            "ni", "nmo", "npssc", "nsn", "nv", "ogv", "oh", "oss", "pause", "popd", "ps", "pushd", "pwd", "r",
            "rbp", "rcjb", "rcsn", "rd", "rdr", "ren", "ri", "rjb", "rm", "rmdir", "rmo", "rni", "rnp", "rp",
            "rsn", "rsnp", "rujb", "rv", "rvpa", "rwmi", "sajb", "sal", "saps", "sasv", "sbp", "sc", "select",
            "set", "shcm", "si", "sl", "sleep", "sls", "sort", "sp", "spjb", "spps", "spsv", "start", "sujb",
            "sv", "swmi", "tee", "trcm", "type", "wget", "where", "wjb", "write"
        };

        public static bool HidesInPowerShell(string name)
        {
            return PowerShellNames.Contains(name);
        }

        // Why name.exe cannot be a wrapper, or null. ownDir (where wrappers live) is not searched.
        public static string Hard(string name, string ownDir)
        {
            if (CmdBuiltIn.Contains(name)) return "cmd.exe has a built-in command with that name";
            string found = SearchPath.Find(name, ownDir);
            return found == null ? null : "Windows already has " + found;
        }
    }

    // Writing into C:\Program Files needs administrator rights. wslbin asks for them by starting
    // itself again with the "runas" verb (a UAC prompt) and a hidden command that takes names only.
    // The elevated copy prints nothing and takes no file names or paths from the command line, so
    // the caller reads the result from the folder afterwards.
    internal static class Elevation
    {
        // The exit code of the elevated copy, or null when there was none: the rights were declined,
        // or WSLBIN_NO_ELEVATION=1 says not to ask (scripts and tests never see the UAC prompt).
        public static int? Run(string exePath, string command, IEnumerable<string> names)
        {
            if (Environment.GetEnvironmentVariable("WSLBIN_NO_ELEVATION") == "1") return null;
            var sb = new StringBuilder(command);
            foreach (string name in names)
            {
                sb.Append(' ');
                Launcher.AppendWindowsArg(sb, name);
            }
            var psi = new ProcessStartInfo(exePath, sb.ToString());
            psi.UseShellExecute = true;
            psi.Verb = "runas";
            psi.WindowStyle = ProcessWindowStyle.Hidden;
            try
            {
                using (Process process = Process.Start(psi))
                {
                    process.WaitForExit();
                    return process.ExitCode;
                }
            }
            catch (Win32Exception ex)
            {
                if (ex.NativeErrorCode == 1223) return null;      // ERROR_CANCELLED: UAC was declined
                throw new WslbinException("cannot ask for administrator rights: " + ex.Message);
            }
        }

        public static string Outcome(int? code)
        {
            return code.HasValue ? " (exit code " + code.Value + ")" : " (administrator rights were declined)";
        }
    }
}
