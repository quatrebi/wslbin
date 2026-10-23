// wslbin: --complete: Tab completion for the shells.

using System;
using System.Collections.Generic;
using System.IO;

namespace Wslbin
{
    // wslbin --complete <index> <word>...: the candidates for word number <index> of a command line,
    // one per line. Shells call this, never people. Nothing here reports an error: a Tab key that
    // prints errors is worse than one that finds nothing (set WSLBIN_DEBUG=1 to see them).
    internal static class Completion
    {
        const int MaxCandidates = 1000;
        const int MaxWords = 10000;      // a command line is at most 32767 characters long
        // Tab must not hang the shell: a WSL that has to start its virtual machine answers in a few
        // seconds, one that does not answer at all is given up on.
        const int TimeoutMs = 10000;

        // How the word being completed was typed, so that the candidates can be written the same way.
        enum Style { Plain, Drive, Backslash }

        public static int Run(IList<string> args, string exePath)
        {
            int cword;
            if (args.Count < 1 || !int.TryParse(args[0], out cword) || cword < 0 || cword > MaxWords)
                throw new WslbinException("--complete needs the number of the word to complete (0 to " + MaxWords +
                                          ") and the words of the command line");

            var words = new List<string>();
            // args[0] is the index; the words after the cursor do not matter
            for (int i = 1; i < args.Count && i <= cword + 1; i++) words.Add(args[i]);
            while (words.Count <= cword) words.Add("");           // the cursor is after the last word

            var result = new List<string>();
            try
            {
                result = Candidates(words, cword, exePath);
            }
            catch (Exception ex)
            {
                // Tab must stay quiet whatever goes wrong: a folder that cannot be read, no WSL, a bug
                if (Environment.GetEnvironmentVariable("WSLBIN_DEBUG") == "1") Out.Error("wslbin: " + ex);
            }
            if (result.Count > 0) Out.Info(string.Join("\n", result));
            return 0;
        }

        static List<string> Candidates(List<string> words, int cword, string exePath)
        {
            if (cword < 1) return new List<string>();        // the command itself is not completed
            string command = CommandName(words[0]);
            Config cfg = Config.Load(Config.PathFor(exePath), delegate { });
            if (command.Equals("wslbin", StringComparison.OrdinalIgnoreCase)) return ForCli(words, cword, exePath, cfg);
            return ForUtility(WrapperName(command, exePath), words, cword, cfg);
        }

        // "C:\tools\Rsync.EXE" -> "Rsync": the name as typed, minus the folder and the extension
        static string CommandName(string word)
        {
            string name = word.Substring(word.LastIndexOfAny(new[] { '\\', '/' }) + 1);
            if (name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) name = name.Substring(0, name.Length - 4);
            return name;
        }

        // Windows does not mind the case of rsync.exe and Linux does: the command that bash gets is the
        // one that the wrapper's file name spells (Rscript.exe is Rscript, typed in any case).
        static string WrapperName(string typed, string exePath)
        {
            try
            {
                foreach (string name in Wrappers.Enumerate(Path.GetDirectoryName(exePath), exePath))
                {
                    if (string.Equals(name, typed, StringComparison.OrdinalIgnoreCase)) return name;
                }
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            return typed;
        }

        static List<string> StartingWith(IEnumerable<string> options, string prefix)
        {
            var list = new List<string>();
            foreach (string o in options)
            {
                if (o.StartsWith(prefix, StringComparison.Ordinal)) list.Add(o);
            }
            return list;
        }

        // ---- wslbin itself -------------------------------------------------------------------

        static List<string> ForCli(List<string> words, int cword, string exePath, Config cfg)
        {
            string cur = words[cword];
            if (cword == 1)
            {
                var options = StartingWith(Program.OfferedOptions(), cur);
                if (!cur.StartsWith("-", StringComparison.Ordinal) && cur.Length > 0) options.AddRange(CommandsInWsl(cfg, cur));
                return options;
            }

            string first = words[1];
            switch (first)
            {
                case "--init":
                    return cword == 2 ? StartingWith(new[] { "pwsh", "clink" }, cur)
                                      : StartingWith(new[] { "--native-fallback", "--dir" }, cur);
                case "--list":
                    return StartingWith(new[] { "--names" }, cur);
                case "--unlink":
                    {
                        var names = StartingWith(new[] { "--all" }, cur);
                        string dir = Path.GetDirectoryName(exePath);
                        foreach (string n in Wrappers.Enumerate(dir, exePath))
                        {
                            if (n.StartsWith(cur, StringComparison.OrdinalIgnoreCase)) names.Add(n);
                        }
                        return names;
                    }
                case "--link":
                    {
                        var options = StartingWith(new[] { "-y", "--yes", "--dry-run" }, cur);
                        if (!cur.StartsWith("-", StringComparison.Ordinal) && cur.Length > 0) options.AddRange(CommandsInWsl(cfg, cur));
                        return options;
                    }
                case Program.ScriptOption:
                    return new List<string>();
            }

            // wslbin [--raw | --sh | --explain] <utility> <arguments...>
            int u = 1;
            while (u < words.Count && Array.IndexOf(Program.ModeOptions, words[u]) >= 0) u++;
            if (u >= words.Count || cword < u) return StartingWith(Program.ModeOptions, cur);
            if (cword == u) return cur.Length > 0 ? CommandsInWsl(cfg, cur) : new List<string>();

            var utilityWords = words.GetRange(u, words.Count - u);
            if (utilityWords[0] == Program.ScriptOption) return new List<string>();
            return ForUtility(CommandName(utilityWords[0]), utilityWords, cword - u, cfg);
        }

        // Commands that WSL knows by this beginning, without the Windows programs in its PATH.
        static List<string> CommandsInWsl(Config cfg, string prefix)
        {
            const string script =
                "compgen -c -- \"$1\" | grep -viE '\\.(exe|com|bat|cmd|dll|msc|cpl|vbs|js)$' | sort -u | head -n 200";
            var positional = new List<string> { "commands", prefix };
            WslResult r = WslQuery.RunBash(cfg, cfg.PathPrefix() + script, positional, TimeoutMs);
            return r.ExitCode == 0 ? Lines(r.Output) : new List<string>();
        }

        static List<string> Lines(string text)
        {
            var list = new List<string>();
            foreach (string line in text.Replace("\r", "").Split('\n'))
            {
                if (line.Length > 0) list.Add(line);
            }
            return list;
        }

        // ---- a wrapper -----------------------------------------------------------------------

        static List<string> ForUtility(string utility, List<string> words, int cword, Config cfg)
        {
            string cur = words[cword];

            // --wslbin-* flags in front of the arguments belong to wslbin, not to the utility.
            int flags = 0;
            ArgMode mode = cfg.ModeFor(utility);
            while (1 + flags < cword && words[1 + flags].StartsWith("--wslbin-", StringComparison.Ordinal))
            {
                if (words[1 + flags] == Program.RawFlag) mode = ArgMode.Raw;
                else if (words[1 + flags] == Program.ShFlag) mode = ArgMode.Sh;
                flags++;
            }
            bool inFlagPosition = cword == 1 + flags;
            if (inFlagPosition && cur.StartsWith("--wslbin", StringComparison.Ordinal))
            {
                var unused = new List<string>();
                foreach (string f in Program.WrapperFlags)
                {
                    if (!words.GetRange(1, flags).Contains(f)) unused.Add(f);
                }
                return StartingWith(unused, cur);
            }
            // the utility would run in the Linux home folder (Launcher.FolderProblem): its files are not the ones here
            if (Launcher.FolderProblem(cfg) != null) return new List<string>();

            var shellWords = new List<string> { utility };
            for (int i = 1 + flags; i < words.Count; i++) shellWords.Add(words[i]);
            int shellCword = cword - flags;

            // Windows paths become Linux paths for bash, and the candidates are turned back.
            Style style = Style.Plain;
            bool backslashes = false;
            bool upper = true;
            if (mode != ArgMode.Raw)
            {
                for (int i = 1; i < shellWords.Count; i++)
                    shellWords[i] = Paths.TranslateArg(shellWords[i], cfg, delegate { });
                string typed = words[cword];
                if (shellWords[shellCword] != typed)
                {
                    style = Style.Drive;
                    backslashes = typed.IndexOf('\\') >= 0;
                    upper = DriveLetterIsUpper(typed);
                }
                else if (typed.IndexOf('\\') >= 0)
                {
                    style = Style.Backslash;
                    shellWords[shellCword] = typed.Replace('\\', '/');
                }
            }

            var positional = new List<string> { "complete", shellCword.ToString() };
            positional.AddRange(shellWords);
            WslResult r = WslQuery.RunBash(cfg, Launcher.FolderGuard(cfg) + cfg.PathPrefix() + Resources.Text(Resources.CompleteScript),
                                           positional, TimeoutMs);
            // the script itself always exits with 0; anything else is wsl.exe failing (no such
            // distribution, ...), and what it printed is its error message, not candidates
            if (r.ExitCode != 0) return new List<string>();

            var candidates = new List<string>();
            var seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (string line in Lines(r.Output))
            {
                string candidate = Back(line, style, backslashes, upper);
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
                if (typed[i + 1] == ':' && (typed[i + 2] == '\\' || typed[i + 2] == '/') && char.IsLetter(typed[i]))
                    return char.IsUpper(typed[i]);
            }
            return true;
        }

        static string Back(string candidate, Style style, bool backslashes, bool upper)
        {
            if (style == Style.Backslash)
            {
                int eq = candidate.StartsWith("-", StringComparison.Ordinal) ? candidate.IndexOf('=') : -1;
                return candidate.Substring(0, eq + 1) + candidate.Substring(eq + 1).Replace('/', '\\');
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
            char drive = candidate[p + root];
            string rest = candidate.Substring(p + root + 1);            // starts with "/" or is empty
            if (backslashes) rest = rest.Replace('/', '\\');
            return candidate.Substring(0, p) + (upper ? char.ToUpperInvariant(drive) : char.ToLowerInvariant(drive)) +
                   ":" + (rest.Length == 0 ? (backslashes ? "\\" : "/") : rest);
        }

        // "/mnt/c" followed by "/" or the end, at position p
        static bool IsMount(string s, int p)
        {
            int root = Paths.MountRoot.Length;
            if (p + root + 1 > s.Length || string.CompareOrdinal(s, p, Paths.MountRoot, 0, root) != 0) return false;
            char drive = s[p + root];
            bool letter = (drive >= 'a' && drive <= 'z') || (drive >= 'A' && drive <= 'Z');
            return letter && (p + root + 1 == s.Length || s[p + root + 1] == '/');
        }
    }
}
