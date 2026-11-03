// wslbin: --complete: Tab completion for the shells.

using System.Buffers;
using System.Globalization;

namespace Wslbin;

// wslbin --complete <index> <word>...: the candidates for word number <index> of a command line,
// one per line. Shells call this, never people. Nothing here reports an error: a Tab key that
// prints errors is worse than one that finds nothing (set WSLBIN_DEBUG=1 to see them).
internal static class Completion
{
    static readonly SearchValues<char> PathSeparators = SearchValues.Create("\\/");
    static readonly string[] InitShells = ["pwsh", "clink"];
    static readonly string[] InitOptions = ["--native-fallback", "--dir"];
    static readonly string[] ListOptions = ["--names"];
    static readonly string[] UnlinkOptions = ["--all"];
    static readonly string[] LinkOptions = ["-y", "--yes", "--dry-run"];

    const int MaxCandidates = 1000;
    const int MaxWords = 10000;      // a command line is at most 32767 characters long
    // Tab must not hang the shell: a WSL that has to start its virtual machine answers in a few
    // seconds, one that does not answer at all is given up on.
    const int TimeoutMs = 10000;

    // How the word being completed was typed, so that the candidates can be written the same way.
    enum Style { Plain, Drive, Backslash }

    public static int Run(IList<string> args, string exePath)
    {
        if (args.Count < 1 || !int.TryParse(args[0], CultureInfo.InvariantCulture, out int cword) || cword is < 0 or > MaxWords)
            throw new WslbinException($"--complete needs the number of the word to complete (0 to {MaxWords}) and the words of the command line");

        // args[0] is the index; the words after the cursor do not matter
        List<string> words = [.. args.Skip(1).Take(cword + 1)];
        while (words.Count <= cword) words.Add("");           // the cursor is after the last word

        List<string> result = [];
        try
        {
            result = Candidates(words, cword, exePath);
        }
        catch (Exception ex)
        {
            // Tab must stay quiet whatever goes wrong: a folder that cannot be read, no WSL, a bug
            if (Environment.GetEnvironmentVariable("WSLBIN_DEBUG") == "1") Out.Fail(ex.ToString());
        }
        if (result.Count > 0) Out.Info(string.Join('\n', result));
        return 0;
    }

    static List<string> Candidates(List<string> words, int cword, string exePath)
    {
        if (cword < 1) return [];        // the command itself is not completed
        string command = CommandName(words[0]);
        Config cfg = Config.Load(Config.PathFor(exePath), _ => { });
        if (command.Equals("wslbin", StringComparison.OrdinalIgnoreCase)) return ForCli(words, cword, exePath, cfg);
        return ForUtility(WrapperName(command, exePath), words, cword, cfg);
    }

    // "C:\tools\Rsync.EXE" -> "Rsync": the name as typed, minus the folder and the extension
    static string CommandName(string word)
    {
        string name = word[(word.AsSpan().LastIndexOfAny(PathSeparators) + 1)..];
        return name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? name[..^4] : name;
    }

    // Windows does not mind the case of rsync.exe and Linux does: the command that bash gets is the
    // one that the wrapper's file name spells (Rscript.exe is Rscript, typed in any case).
    static string WrapperName(string typed, string exePath)
    {
        try
        {
            return Wrappers.Enumerate(Path.GetDirectoryName(exePath)!, exePath)
                .FirstOrDefault(n => n.Equals(typed, StringComparison.OrdinalIgnoreCase)) ?? typed;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return typed;
        }
    }

    static List<string> StartingWith(IEnumerable<string> options, string prefix) =>
        [.. options.Where(o => o.StartsWith(prefix, StringComparison.Ordinal))];

    // ---- wslbin itself -------------------------------------------------------------------

    static List<string> ForCli(List<string> words, int cword, string exePath, Config cfg)
    {
        string cur = words[cword];
        if (cword == 1) return WithCommands(StartingWith(Program.OfferedOptions(), cur), cfg, cur);

        switch (words[1])
        {
            case "--init":
                return StartingWith(cword == 2 ? InitShells : InitOptions, cur);
            case "--list":
                return StartingWith(ListOptions, cur);
            case "--help":
                return cword == 2 ? StartingWith(Help.Topics, cur) : [];
            case "--unlink":
                return
                [
                    .. StartingWith(UnlinkOptions, cur),
                    .. Wrappers.Enumerate(Path.GetDirectoryName(exePath)!, exePath).Where(n => n.StartsWith(cur, StringComparison.OrdinalIgnoreCase))
                ];
            case "--link":
                return WithCommands(StartingWith(LinkOptions, cur), cfg, cur);
            case "--install-ai-context":
                // after --claude-dir or --codex-dir comes a folder, which is not wslbin's to offer
                return AiContext.InstallFolderOptions.Contains(words[cword - 1])
                    ? []
                    : StartingWith([.. AiContext.InstallFlags, .. AiContext.InstallFolderOptions], cur);
            case Program.ScriptOption:
                return [];
        }
        // the other commands of wslbin itself (--doctor, --version, ...) take nothing that could be offered;
        // without this they would be taken for a utility named "--doctor"
        if (words[1].StartsWith('-') && !Program.ModeOptions.Contains(words[1])) return [];

        // wslbin [--raw | --sh | --explain] <utility> <arguments...>
        int u = 1;
        ArgMode? mode = null;
        for (; u < words.Count && Program.ModeOptions.Contains(words[u]); u++)
        {
            if (words[u] == Program.RawOption) mode = ArgMode.Raw;
            else if (words[u] == Program.ShOption) mode = ArgMode.Sh;
        }
        if (u >= words.Count || cword < u) return StartingWith(Program.ModeOptions, cur);
        if (cword == u) return cur.StartsWith('-') ? StartingWith(Program.RunOptions, cur) : cur.Length > 0 ? CommandsInWsl(cfg, cur) : [];

        List<string> utilityWords = words.GetRange(u, words.Count - u);
        if (utilityWords[0] == Program.ScriptOption) return [];
        return ForUtility(CommandName(utilityWords[0]), utilityWords, cword - u, cfg, mode);
    }

    // The options, and the commands of WSL when a word (not an option) has been begun.
    static List<string> WithCommands(List<string> options, Config cfg, string cur)
    {
        if (cur.Length > 0 && !cur.StartsWith('-')) options.AddRange(CommandsInWsl(cfg, cur));
        return options;
    }

    // Commands that WSL knows by this beginning, without the Windows programs in its PATH.
    static List<string> CommandsInWsl(Config cfg, string prefix)
    {
        const string Script =
            "compgen -c -- \"$1\" | grep -viE '\\.(exe|com|bat|cmd|dll|msc|cpl|vbs|js)$' | sort -u | head -n 200";
        WslResult r = WslQuery.RunBash(cfg, cfg.PathPrefix() + Script, ["commands", prefix], TimeoutMs);
        return r.ExitCode == 0 ? Text.Lines(r.Output) : [];
    }

    // ---- a wrapper -----------------------------------------------------------------------

    // cliMode: --raw or --sh of "wslbin --raw <utility>", which wins over the config as it does in a run
    static List<string> ForUtility(string utility, List<string> words, int cword, Config cfg, ArgMode? cliMode = null)
    {
        string cur = words[cword];

        // --wslbin-* flags in front of the arguments belong to wslbin, not to the utility.
        int flags = 0;
        ArgMode mode = cliMode ?? cfg.ModeFor(utility);
        while (1 + flags < cword && words[1 + flags].StartsWith("--wslbin-", StringComparison.Ordinal))
        {
            if (words[1 + flags] == Program.RawFlag) mode = ArgMode.Raw;
            else if (words[1 + flags] == Program.ShFlag) mode = ArgMode.Sh;
            flags++;
        }
        bool inFlagPosition = cword == 1 + flags;
        if (inFlagPosition && cur.StartsWith("--wslbin", StringComparison.Ordinal))
        {
            List<string> given = words.GetRange(1, flags);
            return StartingWith(Program.WrapperFlags.Except(given), cur);
        }
        // the utility would run in the Linux home folder (Folder.Problem): its files are not the ones here
        if (Folder.Problem(cfg) != null) return [];

        List<string> shellWords = [utility, .. words.Skip(1 + flags)];
        int shellCword = cword - flags;

        // Windows paths become Linux paths for bash, and the candidates are turned back.
        Style style = Style.Plain;
        bool backslashes = false;
        bool upper = true;
        if (mode != ArgMode.Raw)
        {
            for (int i = 1; i < shellWords.Count; i++)
                shellWords[i] = Paths.TranslateArg(shellWords[i], cfg, _ => { });
            string typed = words[cword];
            if (shellWords[shellCword] != typed)
            {
                style = Style.Drive;
                backslashes = typed.Contains('\\');
                upper = DriveLetterIsUpper(typed);
            }
            else if (typed.Contains('\\'))
            {
                style = Style.Backslash;
                shellWords[shellCword] = typed.Replace('\\', '/');
            }
        }

        List<string> positional = ["complete", shellCword.ToString(CultureInfo.InvariantCulture), .. shellWords];
        WslResult r = WslQuery.RunBash(cfg, Folder.Guard(cfg) + cfg.PathPrefix() + Resources.Text(Resources.CompleteScript),
                                       positional, TimeoutMs);
        // the script itself always exits with 0; anything else is wsl.exe failing (no such
        // distribution, ...), and what it printed is its error message, not candidates
        if (r.ExitCode != 0) return [];

        List<string> candidates = [];
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (string line in Text.Lines(r.Output))
        {
            string candidate = ToWindows(line, style, backslashes, upper);
            if (seen.Add(candidate)) candidates.Add(candidate);
            if (candidates.Count >= MaxCandidates) break;
        }

        // "rsync --w<Tab>" also offers wslbin's own flags
        if (inFlagPosition && cur.Length >= 3 && cur.StartsWith("--", StringComparison.Ordinal))
        {
            foreach (string f in StartingWith(Program.WrapperFlags, cur))
            {
                if (seen.Add(f)) candidates.Add(f);
            }
        }
        return candidates;
    }

    // The first drive letter in the word, as typed ("--file=c:\x" -> lower case).
    static bool DriveLetterIsUpper(string typed)
    {
        for (int i = 0; i + 2 < typed.Length; i++)
        {
            if (typed[i + 1] == ':' && typed[i + 2] is '\\' or '/' && char.IsLetter(typed[i]))
                return char.IsUpper(typed[i]);
        }
        return true;
    }

    // A candidate of bash written the way the word was typed: Windows drive paths, backslashes.
    static string ToWindows(string candidate, Style style, bool backslashes, bool upper)
    {
        if (style == Style.Backslash)
        {
            int eq = candidate.StartsWith('-') ? candidate.IndexOf('=') : -1;
            return string.Concat(candidate.AsSpan(0, eq + 1), candidate[(eq + 1)..].Replace('/', '\\'));
        }
        if (style != Style.Drive) return candidate;

        // /mnt/c/x at the start, after the first "=", or glued to a short option (-I/mnt/c/x)
        int p = 0;
        if (!IsMount(candidate, 0))
        {
            int eq = candidate.IndexOf('=');
            if (eq >= 0 && IsMount(candidate, eq + 1)) p = eq + 1;
            else if (candidate.Length > 2 && candidate[0] == '-' && IsMount(candidate, 2)) p = 2;
            else return candidate;
        }
        int root = Paths.MountRoot.Length;
        char drive = upper ? char.ToUpperInvariant(candidate[p + root]) : char.ToLowerInvariant(candidate[p + root]);
        string rest = candidate[(p + root + 1)..];            // starts with "/" or is empty
        if (backslashes) rest = rest.Replace('/', '\\');
        return $"{candidate[..p]}{drive}:{(rest.Length == 0 ? (backslashes ? "\\" : "/") : rest)}";
    }

    // "/mnt/c" followed by "/" or the end, at position p
    static bool IsMount(string s, int p)
    {
        int root = Paths.MountRoot.Length;
        if (p + root + 1 > s.Length || string.CompareOrdinal(s, p, Paths.MountRoot, 0, root) != 0) return false;
        return char.IsAsciiLetter(s[p + root]) && (p + root + 1 == s.Length || s[p + root + 1] == '/');
    }
}
