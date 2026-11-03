// wslbin: --doctor.

using Microsoft.Win32;

namespace Wslbin;

// --doctor: lines "[ ok ]", "[warn]" and "[FAIL]", each problem with a "fix:" line.
internal static class Doctor
{
    sealed class Report(Action<string> write)
    {
        public int Failures { get; private set; }
        public int Warnings { get; private set; }

        public void Ok(string text) => write($"[ ok ] {text}");
        public void Warn(string text) { Warnings++; write($"[warn] {text}"); }
        public void Fail(string text) { Failures++; write($"[FAIL] {text}"); }
        public void Hint(string text) => write($"       {text}");
        // advice, not a problem: it changes neither the counts nor the exit code
        public void Info(string text) => write($"[info] {text}");
    }

    public static int Run(IList<string> args, string exePath)
    {
        Options.None(args, "--doctor");
        var report = new Report(Out.Info);
        string dir = Path.GetDirectoryName(exePath)!;
        Out.Info($"wslbin {Program.Version}, {exePath}");
        report.Ok($"install type: {InstallType(dir)}");

        List<string> configProblems = [];
        string configPath = Config.PathFor(exePath);
        Config cfg = Config.Load(configPath, configProblems.Add);
        report.Ok(File.Exists(configPath) ? $"config: {configPath}" : $"config: none (defaults; {configPath} does not exist)");
        foreach (string problem in configProblems) report.Warn(problem);

        bool wslWorks = false;
        try
        {
            report.Ok($"wsl.exe: {Launcher.FindWsl()}");
            wslWorks = CheckWsl(report, cfg);
        }
        catch (WslbinException ex)
        {
            report.Fail(ex.Message);
            report.Hint($"fix: {ex.Fix ?? WslQuery.InstallFix}");
        }

        CheckPath(report, exePath);
        CheckWrappers(report, cfg, exePath, wslWorks);

        Out.Info("");
        Out.Info(report.Failures == 0 && report.Warnings == 0
            ? "Everything looks fine."
            : $"{report.Failures} problem(s), {report.Warnings} warning(s).");
        return report.Failures == 0 ? 0 : ExitCodes.Failed;
    }

    static string InstallType(string dir)
    {
        string? localAppData = Environment.GetEnvironmentVariable("LOCALAPPDATA");
        if (IsUnder(dir, Environment.GetEnvironmentVariable("ProgramFiles")) || IsUnder(dir, Environment.GetEnvironmentVariable("ProgramFiles(x86)")))
            return "system (needs administrator rights to change wrappers)";
        if (localAppData != null && IsUnder(dir, Path.Combine(localAppData, "Programs"))) return "user";
        return $"portable (run from {dir})";
    }

    static bool IsUnder(string dir, string? root)
    {
        if (string.IsNullOrEmpty(root)) return false;
        try
        {
            string d = Path.GetFullPath(dir).TrimEnd('\\') + "\\";
            string r = Path.GetFullPath(root).TrimEnd('\\') + "\\";
            return d.StartsWith(r, StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception ex) when (ex is ArgumentException or IOException)
        {
            return false;      // a variable that holds no path
        }
    }

    // Returns whether bash runs in WSL. Throws WslbinException when WSL itself is missing or stuck.
    static bool CheckWsl(Report report, Config cfg)
    {
        List<Distro> distros = WslQuery.Distros();
        if (distros.Count == 0)
        {
            report.Fail("no WSL distribution is installed");
            report.Hint("fix: wsl --install -d Ubuntu");
            return false;
        }
        report.Ok($"distributions: {string.Join(", ", distros.Select(d => d.Name + (d.IsDefault ? " (default)" : "")))}");

        Distro? target = distros.LastOrDefault(d => cfg.Distro.Length > 0 ? d.Name.Equals(cfg.Distro, StringComparison.OrdinalIgnoreCase) : d.IsDefault);
        if (target == null)
        {
            if (cfg.Distro.Length > 0)
            {
                report.Fail($"distro = {cfg.Distro} in wslbin.ini is not an installed distribution");
                report.Hint("fix: use one of the names above, or remove the line to use the default");
            }
            else
            {
                report.Fail("there is no default distribution");
                report.Hint("fix: wsl --set-default <name>, or set distro = <name> in wslbin.ini");
            }
            return false;
        }
        report.Ok($"wslbin runs in: {target.Name}{(cfg.Distro.Length == 0 ? " (the default)" : "")}");
        if (target.Version != "2") report.Warn($"{target.Name} runs under WSL {target.Version}; wslbin is made for WSL 2");

        WslResult bash = WslQuery.RunBash(cfg, "echo \"$BASH_VERSION\"");
        string version = bash.Output.Trim();
        if (bash.ExitCode != 0 || version.Length == 0)
        {
            report.Fail("cannot run bash in WSL" + WslQuery.Detail(bash));
            return false;
        }
        report.Ok($"bash {version} starts");
        CheckMountRoot(report, cfg);

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
        const string Script =
            "for d in .local/bin .cargo/bin go/bin; do if [ -d \"$HOME/$d\" ]; then " +
            "case \":$PATH:\" in *\":$HOME/$d:\"*) ;; *) echo \"~/$d\";; esac; fi; done";
        List<string> missing = Text.Lines(WslQuery.RunBash(cfg, cfg.PathPrefix() + Script).Output);
        if (missing.Count > 0)
        {
            report.Warn("directories with user-installed tools exist in WSL but are not in PATH for wslbin: " +
                        $"{string.Join(", ", missing)} (bash starts without the profile, so tools there are not found)");
            report.Hint($"fix: add to wslbin.ini:  path = {string.Join(", ", missing)}");
        }
        return true;
    }

    // wslbin writes C:\x as /mnt/c/x (Paths.MountRoot), while WSL mounts the drives where automount.root
    // in /etc/wsl.conf says. wslpath knows where that is; the line is marked, so that nothing else that
    // the call prints is taken for it.
    static void CheckMountRoot(Report report, Config cfg)
    {
        const string Mark = "wslbin-mount:";
        WslResult r = WslQuery.RunBash(cfg, $"p=$(wslpath -u 'C:\\' 2>/dev/null) && printf '{Mark}%s\\n' \"$p\"");
        string? line = Text.Lines(r.Output).FirstOrDefault(l => l.StartsWith(Mark, StringComparison.Ordinal));
        if (line == null) return;      // no wslpath: nothing to compare with
        string drive = line[Mark.Length..].Trim();
        string expected = Paths.MountRoot + "c/";
        if (drive == expected)
        {
            report.Ok($"drives are mounted at {Paths.MountRoot}");
            return;
        }
        report.Fail($"WSL mounts drive C: at {drive}, but wslbin writes Windows paths as {expected}..., " +
                    "so the paths it translates do not exist in Linux");
        report.Hint("fix: set root = /mnt/ under [automount] in /etc/wsl.conf, then run: wsl --shutdown");
    }

    static void CheckPath(Report report, string exePath)
    {
        string dir = Path.GetDirectoryName(exePath)!;
        if (SearchPath.Contains(Environment.GetEnvironmentVariable("PATH"), dir))
        {
            report.Ok("the folder is in PATH");
        }
        else
        {
            string? where =
                SearchPath.Contains(ReadRegistryPath(Registry.CurrentUser, "Environment"), dir) ? "user" :
                SearchPath.Contains(ReadRegistryPath(Registry.LocalMachine, @"SYSTEM\CurrentControlSet\Control\Session Manager\Environment"), dir) ? "system" :
                null;
            if (where != null)
            {
                report.Warn($"the folder is in the {where} PATH, but not in PATH of this terminal");
                report.Hint("fix: open a new terminal");
            }
            else
            {
                report.Warn($"the folder is not in PATH, so wrappers are not found by name: {dir}");
                report.Hint("fix: add it to PATH (the installer does that)");
            }
        }
        CheckOtherCopies(report, exePath);
    }

    // Another wslbin in PATH (an older installation in the other scope, a portable copy): "wslbin"
    // in a terminal starts whichever comes first, and wrappers of the same name compete the same way.
    static void CheckOtherCopies(Report report, string exePath)
    {
        string dir = Path.GetDirectoryName(exePath)!;
        bool ownSeen = false;
        foreach (string found in SearchPath.FindAll("wslbin", null))
        {
            if (SearchPath.SameFolder(Path.GetDirectoryName(found)!, dir))
            {
                ownSeen = true;
                continue;
            }
            report.Warn(ownSeen
                ? $"another wslbin is in PATH: {found} (this one comes first)"
                : $"another wslbin comes first in PATH: {found}, so \"wslbin\" in a terminal starts that one");
            report.Hint("fix: uninstall the copy that is not wanted (Settings > Apps), or take its folder out of PATH");
        }
    }

    static string ReadRegistryPath(RegistryKey root, string subKey)
    {
        try
        {
            using RegistryKey? key = root.OpenSubKey(subKey);
            string? value = key?.GetValue("Path", "", RegistryValueOptions.DoNotExpandEnvironmentNames) as string;
            return Environment.ExpandEnvironmentVariables(value ?? "");
        }
        catch (Exception ex) when (ex is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
            return "";
        }
    }

    static void CheckWrappers(Report report, Config cfg, string exePath, bool wslWorks)
    {
        string dir = Path.GetDirectoryName(exePath)!;
        List<string> wrappers = Wrappers.Enumerate(dir, exePath);
        if (wrappers.Count == 0)
        {
            report.Ok("no wrappers yet (create them with: wslbin --link <utility>...)");
            return;
        }
        Dictionary<string, bool>? present = null;
        if (wslWorks)
        {
            try
            {
                present = WslQuery.Which(cfg, wrappers);
            }
            catch (WslbinException ex)
            {
                report.Warn($"could not ask WSL which utilities exist: {ex.Message}");
            }
        }
        byte[] self = File.ReadAllBytes(exePath);
        int bad = 0;
        foreach (string n in wrappers)
        {
            List<string> problems = Wrappers.Check(n, dir, self, present);
            if (problems.Count == 0) continue;
            bad++;
            report.Warn($"{n}: {string.Join("; ", problems)}");
        }
        // "all fine" would claim that the utilities are in WSL, which nobody could check
        string list = string.Join(", ", wrappers);
        if (bad == 0) report.Ok($"{wrappers.Count} wrapper(s), {(present == null ? "not checked in WSL" : "all fine")}: {list}");

        // A Windows version that is installed already clashes with the wrapper, and that is reported above.
        Dictionary<string, string> native = NativeVersions.Load();
        foreach (string n in wrappers)
        {
            if (!native.TryGetValue(n, out string? package) || Conflicts.Find(n, dir) != null) continue;
            report.Info($"{n} has a Windows version of its own, which starts faster and needs no WSL: winget install --exact --id {package}");
        }
    }
}
