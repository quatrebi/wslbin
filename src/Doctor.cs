// wslbin: --doctor.

using System;
using System.Collections.Generic;
using System.IO;
using Microsoft.Win32;

namespace Wslbin
{
    // --doctor: lines "[ ok ]", "[warn]" and "[FAIL]", each problem with a "fix:" line.
    internal static class Doctor
    {
        sealed class Report
        {
            public int Failures;
            public int Warnings;

            public void Ok(string text) { Out.Info("[ ok ] " + text); }
            public void Warn(string text) { Warnings++; Out.Info("[warn] " + text); }
            public void Fail(string text) { Failures++; Out.Info("[FAIL] " + text); }
            public void Hint(string text) { Out.Info("       " + text); }
        }

        public static int Run(IList<string> args, string exePath)
        {
            if (args.Count > 0) throw new WslbinException("--doctor takes no arguments");
            var report = new Report();
            string dir = Path.GetDirectoryName(exePath);
            Out.Info("wslbin " + Program.Version + ", " + exePath);
            report.Ok("install type: " + InstallType(dir));

            var configProblems = new List<string>();
            string configPath = Config.PathFor(exePath);
            Config cfg = Config.Load(configPath, configProblems.Add);
            report.Ok(File.Exists(configPath) ? "config: " + configPath : "config: none (defaults; " + configPath + " does not exist)");
            foreach (string problem in configProblems) report.Warn(problem);

            bool wslWorks = false;
            try
            {
                report.Ok("wsl.exe: " + Launcher.FindWsl());
                wslWorks = CheckWsl(report, cfg);
            }
            catch (WslbinException ex)
            {
                report.Fail(ex.Message);
                report.Hint("fix: " + WslQuery.InstallFix);
            }

            CheckPath(report, dir);
            CheckWrappers(report, cfg, exePath, wslWorks);

            Out.Info("");
            if (report.Failures == 0 && report.Warnings == 0) Out.Info("Everything looks fine.");
            else Out.Info(report.Failures + " problem(s), " + report.Warnings + " warning(s).");
            return report.Failures == 0 ? 0 : ExitCodes.Failed;
        }

        static string InstallType(string dir)
        {
            string programFiles = Environment.GetEnvironmentVariable("ProgramFiles");
            string programFilesX86 = Environment.GetEnvironmentVariable("ProgramFiles(x86)");
            string localAppData = Environment.GetEnvironmentVariable("LOCALAPPDATA");
            if (IsUnder(dir, programFiles) || IsUnder(dir, programFilesX86)) return "system (needs administrator rights to change wrappers)";
            if (localAppData != null && IsUnder(dir, Path.Combine(localAppData, "Programs"))) return "user";
            return "portable (run from " + dir + ")";
        }

        static bool IsUnder(string dir, string root)
        {
            if (string.IsNullOrEmpty(root)) return false;
            string d = Path.GetFullPath(dir).TrimEnd('\\') + "\\";
            string r = Path.GetFullPath(root).TrimEnd('\\') + "\\";
            return d.StartsWith(r, StringComparison.OrdinalIgnoreCase);
        }

        // Returns whether bash runs in WSL. Throws WslbinException when WSL itself is missing.
        static bool CheckWsl(Report report, Config cfg)
        {
            List<Distro> distros = WslQuery.Distros();
            if (distros.Count == 0)
            {
                report.Fail("no WSL distribution is installed");
                report.Hint("fix: wsl --install -d Ubuntu");
                return false;
            }
            var shown = new List<string>();
            foreach (Distro d in distros) shown.Add(d.Name + (d.IsDefault ? " (default)" : ""));
            report.Ok("distributions: " + string.Join(", ", shown));

            Distro target = null;
            foreach (Distro d in distros)
            {
                if (cfg.Distro.Length > 0 ? d.Name.Equals(cfg.Distro, StringComparison.OrdinalIgnoreCase) : d.IsDefault) target = d;
            }
            if (target == null)
            {
                if (cfg.Distro.Length > 0)
                {
                    report.Fail("distro = " + cfg.Distro + " in wslbin.ini is not an installed distribution");
                    report.Hint("fix: use one of the names above, or remove the line to use the default");
                }
                else
                {
                    report.Fail("there is no default distribution");
                    report.Hint("fix: wsl --set-default <name>, or set distro = <name> in wslbin.ini");
                }
                return false;
            }
            report.Ok("wslbin runs in: " + target.Name + (cfg.Distro.Length == 0 ? " (the default)" : ""));
            if (target.Version != "2") report.Warn(target.Name + " runs under WSL " + target.Version + "; wslbin is made for WSL 2");

            WslResult bash = WslQuery.RunBash(cfg, "echo \"$BASH_VERSION\"");
            string version = bash.Output.Trim();
            if (bash.ExitCode != 0 || version.Length == 0)
            {
                report.Fail("cannot run bash in WSL" + WslQuery.Detail(bash));
                return false;
            }
            report.Ok("bash " + version + " starts");

            WslResult completion = WslQuery.RunBash(cfg, "[ -r /usr/share/bash-completion/bash_completion ] && echo yes || echo no");
            if (completion.Output.Trim() == "yes")
            {
                report.Ok("bash-completion is installed in WSL");
            }
            else
            {
                report.Warn("bash-completion is not installed in WSL: Tab completion of wrappers will have nothing to offer");
                report.Hint("fix: wsl -u root apt-get install bash-completion");
            }

            // bash starts without the profile, so the usual per-user tool directories are not in PATH.
            const string script =
                "for d in .local/bin .cargo/bin go/bin; do if [ -d \"$HOME/$d\" ]; then " +
                "case \":$PATH:\" in *\":$HOME/$d:\"*) ;; *) echo \"~/$d\";; esac; fi; done";
            WslResult tools = WslQuery.RunBash(cfg, cfg.PathPrefix() + script);
            var missing = new List<string>();
            foreach (string line in tools.Output.Replace("\r", "").Split('\n'))
            {
                if (line.Length > 0) missing.Add(line);
            }
            if (missing.Count > 0)
            {
                report.Warn("directories with user-installed tools exist in WSL but are not in PATH for wslbin: " +
                            string.Join(", ", missing) + " (bash starts without the profile, so tools there are not found)");
                report.Hint("fix: add to wslbin.ini:  path = " + string.Join(", ", missing));
            }
            return true;
        }

        static void CheckPath(Report report, string dir)
        {
            if (SearchPath.Contains(Environment.GetEnvironmentVariable("PATH"), dir))
            {
                report.Ok("the folder is in PATH");
                return;
            }
            string where = null;
            if (SearchPath.Contains(ReadRegistryPath(Registry.CurrentUser, "Environment"), dir)) where = "user";
            else if (SearchPath.Contains(ReadRegistryPath(Registry.LocalMachine,
                     @"SYSTEM\CurrentControlSet\Control\Session Manager\Environment"), dir)) where = "system";

            if (where != null)
            {
                report.Warn("the folder is in the " + where + " PATH, but not in PATH of this terminal");
                report.Hint("fix: open a new terminal");
            }
            else
            {
                report.Warn("the folder is not in PATH, so wrappers are not found by name: " + dir);
                report.Hint("fix: add it to PATH (the installer does that)");
            }
        }

        static string ReadRegistryPath(RegistryKey root, string subKey)
        {
            using (RegistryKey key = root.OpenSubKey(subKey))
            {
                if (key == null) return "";
                string value = key.GetValue("Path", "", RegistryValueOptions.DoNotExpandEnvironmentNames) as string;
                return Environment.ExpandEnvironmentVariables(value ?? "");
            }
        }

        static void CheckWrappers(Report report, Config cfg, string exePath, bool wslWorks)
        {
            string dir = Path.GetDirectoryName(exePath);
            List<string> wrappers = Wrappers.Enumerate(dir, exePath);
            if (wrappers.Count == 0)
            {
                report.Ok("no wrappers yet (create them with: wslbin --link <utility>...)");
                return;
            }
            Dictionary<string, bool> present = null;
            if (wslWorks)
            {
                try
                {
                    present = WslQuery.Presence(cfg, wrappers);
                }
                catch (WslbinException ex)
                {
                    report.Warn("could not ask WSL which utilities exist: " + ex.Message);
                }
            }
            int bad = 0;
            foreach (string n in wrappers)
            {
                List<string> problems = WrapperCommands.Problems(n, exePath, present);
                if (problems.Count == 0) continue;
                bad++;
                report.Warn(n + ": " + string.Join("; ", problems));
            }
            // "all fine" would claim that the utilities are in WSL, which nobody could check
            if (bad == 0 && present == null) report.Ok(wrappers.Count + " wrapper(s), not checked in WSL: " + string.Join(", ", wrappers));
            else if (bad == 0) report.Ok(wrappers.Count + " wrapper(s), all fine: " + string.Join(", ", wrappers));
        }
    }
}
