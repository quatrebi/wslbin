// wslbin: --link, --unlink, --list, and installing a utility that WSL lacks.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;

namespace Wslbin
{
    // --link, --unlink, --list, and the halves of --link and --unlink that run with administrator rights.
    internal static class WrapperCommands
    {
        // ---- --link -------------------------------------------------------------------------

        public static int Link(IList<string> args, string exePath, Config cfg)
        {
            bool yes = false;
            bool dryRun = false;
            var requested = new List<string>();
            foreach (string a in args)
            {
                if (a == "-y" || a == "--yes") yes = true;
                else if (a == "--dry-run") dryRun = true;
                else if (a.StartsWith("-", StringComparison.Ordinal)) throw new WslbinException("unknown option " + a + " for --link");
                else requested.Add(a);
            }

            string dir = Path.GetDirectoryName(exePath);
            bool refreshing = requested.Count == 0;
            if (refreshing)
            {
                requested = Wrappers.Enumerate(dir, exePath);
                if (requested.Count == 0)
                {
                    Out.Info("no wrappers in " + dir + " yet; create them with: wslbin --link <utility>...");
                    return 0;
                }
            }

            var names = new List<string>();
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (string n in requested)
            {
                // names typed by the user must be good; names of wrapper files that are there already are
                // whatever they are, and a refresh has to cope with them
                if (!refreshing && !Wrappers.IsValidName(n))
                    throw new WslbinException("'" + n + "' cannot be a wrapper name: use letters, digits and . _ + - " +
                                              "(no .exe, not wslbin, not a device name like con)");
                if (seen.Add(n)) names.Add(n);
            }

            var failed = new List<string>();
            var candidates = new List<string>();
            foreach (string n in names)
            {
                string target = Wrappers.PathOf(dir, n);
                bool exists = File.Exists(target);
                if (exists && !Wrappers.IsWrapperFile(target))
                {
                    failed.Add(n + ": " + target + " exists and is not a wslbin wrapper");
                    continue;
                }
                string conflict = Conflicts.Hard(n, dir);
                if (conflict != null && !exists)
                {
                    failed.Add(n + ": " + conflict);
                    continue;
                }
                // A wrapper that is there already is brought up to date even when a Windows program of the
                // same name has turned up since: an old copy of wslbin.exe would keep the old faults.
                if (conflict != null) Out.Warn(n + ": " + conflict + " (the wrapper is brought up to date all the same; see wslbin --list)");
                candidates.Add(n);
            }

            // A wrapper for a utility that is not in WSL would only ever print "command not found".
            // Wrappers that already exist are only refreshed, which needs no check.
            if (!refreshing && candidates.Count > 0)
            {
                Dictionary<string, bool> present = WslQuery.Presence(cfg, candidates);
                foreach (string n in new List<string>(candidates))
                {
                    bool there;
                    if (present.TryGetValue(n, out there) && there) continue;
                    string reason = Apt.MakeAvailable(cfg, n, yes, dryRun);
                    if (reason != null)
                    {
                        failed.Add(n + ": " + reason);
                        candidates.Remove(n);
                    }
                }
            }

            var denied = new List<string>();
            foreach (string n in candidates)
            {
                if (dryRun)
                {
                    Out.Info((File.Exists(Wrappers.PathOf(dir, n)) ? "would update " : "would create ") + Wrappers.PathOf(dir, n));
                    continue;
                }
                try
                {
                    Out.Info(Wrappers.Describe(Wrappers.Create(exePath, n)) + " " + n + ".exe");
                }
                catch (UnauthorizedAccessException ex)
                {
                    // "access denied" is also what a program that is running or a read-only file gives
                    if (Wrappers.CanWrite(dir)) failed.Add(n + ": " + ex.Message);
                    else denied.Add(n);
                }
                catch (IOException ex)
                {
                    failed.Add(n + ": " + ex.Message);
                }
            }

            if (denied.Count > 0)
            {
                Out.Info(dir + " needs administrator rights; asking for them (UAC)...");
                int? code = Elevation.Run(exePath, "--internal-link", denied);
                foreach (string n in denied)
                {
                    string target = Wrappers.PathOf(dir, n);
                    if (File.Exists(target) && Wrappers.IsWrapperFile(target) && Wrappers.SameContent(target, exePath))
                        Out.Info("created " + n + ".exe");
                    else
                        failed.Add(n + ": could not write " + target + Elevation.Outcome(code));
                }
            }

            foreach (string f in failed) Out.Error("wslbin: " + f);
            if (!dryRun && candidates.Count > 0 && !SearchPath.Contains(Environment.GetEnvironmentVariable("PATH"), dir))
                Out.Warn(dir + " is not in PATH of this terminal, so the wrappers are not found by name yet (see: wslbin --doctor)");
            return failed.Count == 0 ? 0 : ExitCodes.Failed;
        }

        // The half that runs elevated: creates or refreshes what it is asked to, after the same name and
        // conflict checks. Exit code 0 when every name ended up as an up-to-date wrapper.
        public static int InternalLink(IList<string> names, string exePath)
        {
            string dir = Path.GetDirectoryName(exePath);
            int bad = 0;
            foreach (string n in names)
            {
                try
                {
                    string target = Wrappers.PathOf(dir, n);
                    bool exists = File.Exists(target);
                    if (!Wrappers.IsValidName(n)) bad++;
                    else if (exists && !Wrappers.IsWrapperFile(target)) bad++;
                    else if (!exists && Conflicts.Hard(n, dir) != null) bad++;
                    else Wrappers.Create(exePath, n);
                }
                catch (IOException) { bad++; }
                catch (UnauthorizedAccessException) { bad++; }
            }
            return bad == 0 ? 0 : ExitCodes.Failed;
        }

        // ---- --unlink -----------------------------------------------------------------------

        public static int Unlink(IList<string> args, string exePath)
        {
            bool all = false;
            var requested = new List<string>();
            foreach (string a in args)
            {
                if (a == "--all") all = true;
                else if (a.StartsWith("-", StringComparison.Ordinal)) throw new WslbinException("unknown option " + a + " for --unlink");
                else requested.Add(a);
            }
            if (all && requested.Count > 0)
                throw new WslbinException("--unlink takes the names of utilities or --all, not both");
            if (!all && requested.Count == 0)
                throw new WslbinException("--unlink needs the names of utilities, or --all (wslbin --list shows them)");
            // every name is checked before anything is removed
            foreach (string n in requested)
            {
                if (!Wrappers.IsValidName(n)) throw new WslbinException("'" + n + "' is not a wrapper name");
            }

            string dir = Path.GetDirectoryName(exePath);
            if (all) requested = Wrappers.Enumerate(dir, exePath);
            if (requested.Count == 0)
            {
                Out.Info("no wrappers in " + dir);
                return 0;
            }

            var failed = new List<string>();
            var denied = new List<string>();
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (string n in requested)
            {
                if (!seen.Add(n)) continue;
                string target = Wrappers.PathOf(dir, n);
                if (!File.Exists(target))
                {
                    Out.Info("no wrapper " + n + ".exe");
                }
                else if (!Wrappers.IsWrapperFile(target))
                {
                    failed.Add(n + ": " + target + " is not a wslbin wrapper; left alone");
                }
                else
                {
                    try
                    {
                        File.Delete(target);
                        Out.Info("removed " + n + ".exe");
                    }
                    catch (UnauthorizedAccessException ex)
                    {
                        // a wrapper that is running cannot be deleted either, and that is not a matter of rights
                        if (Wrappers.CanWrite(dir)) failed.Add(n + ": " + ex.Message);
                        else denied.Add(n);
                    }
                    catch (IOException ex) { failed.Add(n + ": " + ex.Message); }
                }
            }

            if (denied.Count > 0)
            {
                Out.Info(dir + " needs administrator rights; asking for them (UAC)...");
                int? code = Elevation.Run(exePath, "--internal-unlink", denied);
                foreach (string n in denied)
                {
                    if (!File.Exists(Wrappers.PathOf(dir, n))) Out.Info("removed " + n + ".exe");
                    else failed.Add(n + ": could not remove it" + Elevation.Outcome(code));
                }
            }
            foreach (string f in failed) Out.Error("wslbin: " + f);
            return failed.Count == 0 ? 0 : ExitCodes.Failed;
        }

        public static int InternalUnlink(IList<string> names, string exePath)
        {
            string dir = Path.GetDirectoryName(exePath);
            int bad = 0;
            foreach (string n in names)
            {
                string target = Wrappers.PathOf(dir, n);
                try
                {
                    if (!Wrappers.IsValidName(n)) bad++;
                    else if (File.Exists(target) && Wrappers.IsWrapperFile(target)) File.Delete(target);
                }
                catch (IOException) { bad++; }
                catch (UnauthorizedAccessException) { bad++; }
            }
            return bad == 0 ? 0 : ExitCodes.Failed;
        }

        // ---- --list -------------------------------------------------------------------------

        public static int List(IList<string> args, string exePath, Config cfg)
        {
            bool namesOnly = false;
            foreach (string a in args)
            {
                if (a == "--names") namesOnly = true;
                else throw new WslbinException("unknown option " + a + " for --list");
            }
            string dir = Path.GetDirectoryName(exePath);
            List<string> wrappers = Wrappers.Enumerate(dir, exePath);
            if (namesOnly)
            {
                foreach (string n in wrappers) Out.Info(n);
                return 0;
            }
            if (wrappers.Count == 0)
            {
                Out.Info("no wrappers in " + dir + "; create them with: wslbin --link <utility>...");
                return 0;
            }

            Dictionary<string, bool> present = null;
            string wslProblem = null;
            try
            {
                present = WslQuery.Presence(cfg, wrappers);
            }
            catch (WslbinException ex)
            {
                wslProblem = ex.Message;
            }

            int width = 0;
            foreach (string n in wrappers) width = Math.Max(width, n.Length);
            foreach (string n in wrappers)
            {
                List<string> problems = Problems(n, exePath, present);
                // "ok" would claim that the utility is in WSL, which nobody could check
                if (present == null) problems.Insert(0, "not checked in WSL");
                Out.Info(n.PadRight(width + 2) + (problems.Count == 0 ? "ok" : string.Join("; ", problems)));
            }
            if (wslProblem != null) Out.Warn("could not ask WSL which utilities exist: " + wslProblem);
            return 0;
        }

        // What is wrong with a wrapper, as short phrases. "present" is null when WSL could not be asked.
        public static List<string> Problems(string name, string exePath, Dictionary<string, bool> present)
        {
            var problems = new List<string>();
            string dir = Path.GetDirectoryName(exePath);
            bool there;
            if (present != null && present.TryGetValue(name, out there) && !there) problems.Add("not found in WSL");
            if (!Wrappers.SameContent(Wrappers.PathOf(dir, name), exePath)) problems.Add("outdated (run: wslbin --link)");
            string conflict = Conflicts.Hard(name, dir);
            if (conflict != null) problems.Add("conflict: " + conflict);
            if (Conflicts.HidesInPowerShell(name))
                problems.Add("PowerShell runs its own '" + name + "' first: use " + name + ".exe there (or: wslbin --init pwsh)");
            return problems;
        }
    }

    // A utility that --link is asked for and WSL lacks: its apt package, installed when the user agrees.
    internal static class Apt
    {
        // Returns null when the utility is (or, in a dry run, would be) there, or the reason why it is not.
        public static string MakeAvailable(Config cfg, string name, bool yes, bool dryRun)
        {
            if (!WslQuery.HasAptGet(cfg))
                return "not found in WSL, and this distribution has no apt: install it with its own package manager";
            string package = WslQuery.SuggestPackage(cfg, name);
            if (package == null)
                return "not found in WSL, and apt knows no package that provides it (try: wsl -u root apt-get update)";

            string command = "wsl.exe " + Arguments(cfg, package);
            if (dryRun)
            {
                Out.Info("would run: " + command);
                return null;
            }
            bool go = yes;
            if (!go && IsInteractive())
                go = Confirm("'" + name + "' is not installed in WSL. Install the apt package '" + package + "' now?");
            if (!go)
                return "not found in WSL; install it with: " + command + "   (or repeat with --yes)";

            Out.Info("running: " + command);
            // apt talks to the user, so it shares the console like a wrapper's utility does
            var psi = new ProcessStartInfo(Launcher.FindWsl(), Arguments(cfg, package));
            psi.UseShellExecute = false;
            if (Launcher.RunInConsole(psi) != 0)
                return "installing '" + package + "' failed (if apt cannot find packages, try: wsl -u root apt-get update)";
            bool there;
            return WslQuery.Presence(cfg, new[] { name }).TryGetValue(name, out there) && there
                ? null
                : "'" + package + "' is installed, but it does not provide '" + name + "'";
        }

        static string Arguments(Config cfg, string package)
        {
            var sb = new StringBuilder();
            if (cfg.Distro.Length > 0)
            {
                sb.Append("-d ");
                Launcher.AppendWindowsArg(sb, cfg.Distro);
                sb.Append(' ');
            }
            sb.Append("-u root --exec apt-get install -y ");
            Launcher.AppendWindowsArg(sb, package);
            return sb.ToString();
        }

        static bool IsInteractive()
        {
            return !Console.IsInputRedirected && !Console.IsOutputRedirected;
        }

        static bool Confirm(string question)
        {
            Console.Write(question + " [y/N] ");
            string answer = Console.ReadLine();
            if (answer == null) return false;
            answer = answer.Trim();
            return answer.Equals("y", StringComparison.OrdinalIgnoreCase) || answer.Equals("yes", StringComparison.OrdinalIgnoreCase);
        }
    }
}
