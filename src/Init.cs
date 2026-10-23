// wslbin: --init pwsh | clink.

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading.Tasks;

namespace Wslbin
{
    // wslbin --init pwsh | clink: the code that hooks wslbin into a shell.
    internal static class Init
    {
        public static int Run(IList<string> args, string exePath)
        {
            if (args.Count == 0) throw new WslbinException("--init needs a shell: pwsh or clink");
            var rest = new List<string>(args);
            rest.RemoveAt(0);
            switch (args[0])
            {
                case "pwsh": return PowerShell(rest, exePath);
                case "clink": return Clink(rest, exePath);
            }
            throw new WslbinException("unknown shell '" + args[0] + "': use pwsh or clink");
        }

        static int PowerShell(IList<string> args, string exePath)
        {
            bool fallback = false;
            foreach (string a in args)
            {
                if (a == "--native-fallback") fallback = true;
                else throw new WslbinException("unknown option " + a + " for --init pwsh");
            }
            var names = new List<string>();
            foreach (string n in Wrappers.Enumerate(Path.GetDirectoryName(exePath), exePath))
            {
                // a file that someone copied by hand under a name that cannot be a wrapper name must not
                // reach the code that every new shell runs
                if (Wrappers.IsValidName(n)) names.Add("'" + n.Replace("'", "''") + "'");
            }

            string code = Resources.Text(Resources.PowerShellInit)
                .Replace("@EXE@", PowerShellString(exePath))
                .Replace("@NAMES@", string.Join(", ", names))
                .Replace("@FALLBACK@", fallback ? "$true" : "$false");
            Out.Info(code.TrimEnd('\n'));
            return 0;
        }

        // A string literal that survives any code page between wslbin and the shell that reads
        // its output: characters outside ASCII are written as [char] codes.
        internal static string PowerShellString(string s)
        {
            var parts = new List<string>();
            var run = new StringBuilder();
            foreach (char c in s)
            {
                if (c < 128)
                {
                    run.Append(c == '\'' ? "''" : c.ToString());
                    continue;
                }
                if (run.Length > 0) { parts.Add("'" + run + "'"); run.Length = 0; }
                parts.Add("[char]" + (int)c);
            }
            if (run.Length > 0 || parts.Count == 0) parts.Add("'" + run + "'");
            return parts.Count == 1 ? parts[0] : "(" + string.Join(" + ", parts) + ")";
        }

        // The first line of shell/wslbin.lua: how wslbin (and install.ps1 -Uninstall) know the file as theirs.
        internal const string ClinkScriptMark = "-- wslbin for cmd (Clink)";

        static int Clink(IList<string> args, string exePath)
        {
            string dir = null;
            for (int i = 0; i < args.Count; i++)
            {
                if (args[i] != "--dir")
                    throw new WslbinException("unknown option " + args[i] + " for --init clink (--dir <folder> is the only one)");
                if (i + 1 >= args.Count) throw new WslbinException("--dir needs a folder");
                dir = args[++i];
            }
            if (dir == null) dir = ClinkScriptsDirectory();
            if (!Directory.Exists(dir))
                throw new WslbinException("the Clink scripts folder " + dir + " does not exist; is Clink installed? " +
                                          "(or name the folder: wslbin --init clink --dir <folder>)");

            string target = Path.Combine(dir, "wslbin.lua");
            if (File.Exists(target) && !File.ReadAllText(target).StartsWith(ClinkScriptMark, StringComparison.Ordinal))
                throw new WslbinException(target + " was not written by wslbin; left alone (remove it, or name another folder with --dir)");
            string lua = Resources.Text(Resources.ClinkInit).Replace("@EXE@", LuaString(exePath));
            File.WriteAllText(target, lua, new UTF8Encoding(false));
            Out.Info("wrote " + target + "; open a new cmd window to use it");
            return 0;
        }

        static string LuaString(string s)
        {
            return "\"" + s.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
        }

        // Where Clink looks for scripts of the user: its state folder, which "clink info" prints.
        static string ClinkScriptsDirectory()
        {
            string clink = SearchPath.Find("clink", "");
            if (clink != null)
            {
                try
                {
                    var psi = new ProcessStartInfo("cmd.exe", "/c \"\"" + clink + "\" info\"");
                    psi.UseShellExecute = false;
                    psi.CreateNoWindow = true;
                    // all three streams its own, so that nothing it leaves running holds those of wslbin
                    psi.RedirectStandardInput = true;
                    psi.RedirectStandardOutput = true;
                    psi.RedirectStandardError = true;
                    using (Process p = Process.Start(psi))
                    {
                        p.StandardInput.Close();
                        p.StandardError.ReadToEndAsync();
                        Task<string> read = p.StandardOutput.ReadToEndAsync();
                        if (!p.WaitForExit(10000))
                        {
                            try { p.Kill(); }
                            catch (InvalidOperationException) { }
                            catch (Win32Exception) { }
                            return DefaultClinkDirectory();
                        }
                        foreach (string line in read.Result.Replace("\r", "").Split('\n'))
                        {
                            if (!line.StartsWith("state", StringComparison.Ordinal)) continue;
                            int colon = line.IndexOf(':');
                            if (colon > 0) return line.Substring(colon + 1).Trim();
                        }
                    }
                }
                catch (Win32Exception)
                {
                    // fall through to the default
                }
            }
            return DefaultClinkDirectory();
        }

        static string DefaultClinkDirectory()
        {
            return Path.Combine(Environment.GetEnvironmentVariable("LOCALAPPDATA") ?? "", "clink");
        }
    }
}
