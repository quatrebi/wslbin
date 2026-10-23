// wslbin: --link, --unlink, --list.

namespace Wslbin;

// --link, --unlink, --list, and the halves of --link and --unlink that run with administrator rights.
internal static class WrapperCommands
{
    // ---- --link -------------------------------------------------------------------------

    public static int Link(IList<string> args, string exePath, Config cfg)
    {
        var options = Options.Parse(args, "--link", ["-y", "--yes", "--dry-run"], words: true);
        bool yes = options.Has("-y") || options.Has("--yes");
        bool dryRun = options.Has("--dry-run");
        string dir = Path.GetDirectoryName(exePath)!;

        // No names: bring the wrappers that are there up to date. Their names are whatever they are,
        // and a refresh has to cope with them; names typed by the user must be good.
        bool refreshing = options.Words.Count == 0;
        List<string> names = refreshing ? Wrappers.Enumerate(dir, exePath) : ValidNames(options.Words);
        if (names.Count == 0)
        {
            Out.Info($"no wrappers in {dir} yet; create them with: wslbin --link <utility>...");
            return 0;
        }

        List<string> failed = [];
        List<string> candidates = Writable(names, dir, failed);
        // A wrapper for a utility that is not in WSL would only ever print "command not found".
        // Wrappers that already exist are only refreshed, which needs no check.
        if (!refreshing) candidates = InWsl(cfg, candidates, yes, dryRun, failed);

        if (dryRun)
        {
            foreach (string n in candidates)
            {
                string target = Wrappers.PathOf(dir, n);
                Out.Info($"{(File.Exists(target) ? "would update" : "would create")} {target}");
            }
        }
        else
        {
            Write(exePath, dir, candidates, failed);
        }

        foreach (string f in failed) Out.Fail(f);
        if (!dryRun && candidates.Count > 0 && !SearchPath.Contains(Environment.GetEnvironmentVariable("PATH"), dir))
            Out.Warn($"{dir} is not in PATH of this terminal, so the wrappers are not found by name yet (see: wslbin --doctor)");
        return failed.Count == 0 ? 0 : ExitCodes.Failed;
    }

    // The names typed by the user, each once.
    static List<string> ValidNames(List<string> words)
    {
        foreach (string n in words)
        {
            if (!Wrappers.IsValidName(n))
                throw new WslbinException($"'{n}' cannot be a wrapper name: use letters, digits and . _ + - " +
                                          "(no .exe, not wslbin, not a device name like con)");
        }
        return [.. words.Distinct(StringComparer.OrdinalIgnoreCase)];
    }

    // The names whose wrapper may be written: not a file that is something else, not a name that
    // Windows uses (unless the wrapper is there already).
    static List<string> Writable(List<string> names, string dir, List<string> failed)
    {
        List<string> result = [];
        foreach (string n in names)
        {
            string target = Wrappers.PathOf(dir, n);
            bool exists = File.Exists(target);
            string? conflict = Conflicts.Find(n, dir);
            if (exists && !Wrappers.IsWrapperFile(target))
            {
                failed.Add($"{n}: {target} exists and is not a wslbin wrapper");
            }
            else if (conflict != null && !exists)
            {
                failed.Add($"{n}: {conflict}");
            }
            else
            {
                // A wrapper that is there already is brought up to date even when a Windows program of the
                // same name has turned up since: an old copy of wslbin.exe would keep the old faults.
                if (conflict != null) Out.Warn($"{n}: {conflict} (the wrapper is brought up to date all the same; see wslbin --list)");
                result.Add(n);
            }
        }
        return result;
    }

    // The names whose utility is in WSL, or has been installed with apt now.
    static List<string> InWsl(Config cfg, List<string> names, bool yes, bool dryRun, List<string> failed)
    {
        if (names.Count == 0) return names;
        Dictionary<string, bool> present = WslQuery.Which(cfg, names);
        List<string> result = [];
        foreach (string n in names)
        {
            string? reason = present.GetValueOrDefault(n) ? null : Apt.MakeAvailable(cfg, n, yes, dryRun);
            if (reason == null) result.Add(n);
            else failed.Add($"{n}: {reason}");
        }
        return result;
    }

    static void Write(string exePath, string dir, List<string> names, List<string> failed)
    {
        List<string> denied = [];
        var existed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (string n in names)
        {
            if (File.Exists(Wrappers.PathOf(dir, n))) existed.Add(n);
            Change(dir, n, () => Out.Info($"{Wrappers.Describe(Wrappers.Create(exePath, n))} {n}.exe"), denied, failed);
        }

        byte[] self = File.ReadAllBytes(exePath);
        Elevation.Finish(exePath, dir, "--internal-link", denied,
            n => Wrappers.IsWrapperFile(Wrappers.PathOf(dir, n)) && Wrappers.SameContent(Wrappers.PathOf(dir, n), self)
                ? $"{(existed.Contains(n) ? "updated" : "created")} {n}.exe"
                : null,
            n => $"could not write {Wrappers.PathOf(dir, n)}", failed);
    }

    // Makes one change in dir. "Access denied" in a folder that this user cannot write to means that
    // it needs administrator rights (denied); it is also what a running program or a read-only file
    // gives, and that is not a matter of rights (failed).
    static void Change(string dir, string name, Action change, List<string> denied, List<string> failed)
    {
        try
        {
            change();
        }
        catch (UnauthorizedAccessException ex)
        {
            if (Wrappers.CanWrite(dir)) failed.Add($"{name}: {ex.Message}");
            else denied.Add(name);
        }
        catch (IOException ex)
        {
            failed.Add($"{name}: {ex.Message}");
        }
    }

    // The half that runs elevated: creates or refreshes what it is asked to, after the same name and
    // conflict checks. Exit code 0 when every name ended up as an up-to-date wrapper.
    public static int InternalLink(IList<string> names, string exePath)
    {
        string dir = Path.GetDirectoryName(exePath)!;
        int bad = 0;
        foreach (string n in names)
        {
            try
            {
                string target = Wrappers.PathOf(dir, n);
                bool exists = File.Exists(target);
                if (!Wrappers.IsValidName(n)) bad++;
                else if (exists && !Wrappers.IsWrapperFile(target)) bad++;
                else if (!exists && Conflicts.Find(n, dir) != null) bad++;
                else Wrappers.Create(exePath, n);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                bad++;
            }
        }
        return bad == 0 ? 0 : ExitCodes.Failed;
    }

    // ---- --unlink -----------------------------------------------------------------------

    public static int Unlink(IList<string> args, string exePath)
    {
        var options = Options.Parse(args, "--unlink", ["--all"], words: true);
        bool all = options.Has("--all");
        List<string> requested = options.Words;
        if (all && requested.Count > 0)
            throw new WslbinException("--unlink takes the names of utilities or --all, not both");
        if (!all && requested.Count == 0)
            throw new WslbinException("--unlink needs the names of utilities, or --all (wslbin --list shows them)");
        // every name is checked before anything is removed
        foreach (string n in requested)
        {
            if (!Wrappers.IsValidName(n)) throw new WslbinException($"'{n}' is not a wrapper name");
        }

        string dir = Path.GetDirectoryName(exePath)!;
        if (all) requested = Wrappers.Enumerate(dir, exePath);
        if (requested.Count == 0)
        {
            Out.Info($"no wrappers in {dir}");
            return 0;
        }

        List<string> failed = [];
        List<string> denied = [];
        foreach (string n in requested.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            string target = Wrappers.PathOf(dir, n);
            if (!File.Exists(target))
            {
                Out.Info($"no wrapper {n}.exe");
            }
            else if (!Wrappers.IsWrapperFile(target))
            {
                failed.Add($"{n}: {target} is not a wslbin wrapper; left alone");
            }
            else
            {
                Change(dir, n, () =>
                {
                    File.Delete(target);
                    Out.Info($"removed {n}.exe");
                }, denied, failed);
            }
        }

        Elevation.Finish(exePath, dir, "--internal-unlink", denied,
            n => File.Exists(Wrappers.PathOf(dir, n)) ? null : $"removed {n}.exe",
            _ => "could not remove it", failed);
        foreach (string f in failed) Out.Fail(f);
        return failed.Count == 0 ? 0 : ExitCodes.Failed;
    }

    public static int InternalUnlink(IList<string> names, string exePath)
    {
        string dir = Path.GetDirectoryName(exePath)!;
        int bad = 0;
        foreach (string n in names)
        {
            string target = Wrappers.PathOf(dir, n);
            try
            {
                if (!Wrappers.IsValidName(n)) bad++;
                else if (File.Exists(target) && Wrappers.IsWrapperFile(target)) File.Delete(target);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                bad++;
            }
        }
        return bad == 0 ? 0 : ExitCodes.Failed;
    }

    // ---- --list -------------------------------------------------------------------------

    public static int List(IList<string> args, string exePath, Config cfg)
    {
        bool namesOnly = Options.Parse(args, "--list", ["--names"]).Has("--names");
        string dir = Path.GetDirectoryName(exePath)!;
        List<string> wrappers = Wrappers.Enumerate(dir, exePath);
        if (namesOnly)
        {
            foreach (string n in wrappers) Out.Info(n);
            return 0;
        }
        if (wrappers.Count == 0)
        {
            Out.Info($"no wrappers in {dir}; create them with: wslbin --link <utility>...");
            return 0;
        }

        Dictionary<string, bool>? present = null;
        string? wslProblem = null;
        try
        {
            present = WslQuery.Which(cfg, wrappers);
        }
        catch (WslbinException ex)
        {
            wslProblem = ex.Message;
        }

        byte[] self = File.ReadAllBytes(exePath);
        int width = wrappers.Max(n => n.Length) + 2;
        foreach (string n in wrappers)
        {
            List<string> problems = Wrappers.Check(n, dir, self, present);
            // "ok" would claim that the utility is in WSL, which nobody could check
            if (present == null) problems.Insert(0, "not checked in WSL");
            Out.Info(n.PadRight(width) + (problems.Count == 0 ? "ok" : string.Join("; ", problems)));
        }
        if (wslProblem != null) Out.Warn($"could not ask WSL which utilities exist: {wslProblem}");
        return 0;
    }
}
