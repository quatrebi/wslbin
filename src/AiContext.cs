// wslbin: --ai-context and --install-ai-context.

using System.Text;

namespace Wslbin;

// wslbin --ai-context prints the instructions for an AI agent. wslbin --install-ai-context
// puts them where the agents read their instructions: a short block, marked so that it can
// be found again and taken out, in CLAUDE.md of Claude Code and AGENTS.md of Codex, and a
// skill with the full text for Claude Code.
internal static class AiContext
{
    const string BeginMarker = "<!-- wslbin:begin";
    const string EndMarker = "<!-- wslbin:end -->";
    const string SkillMarker = "<!-- wslbin:managed";

    // The block is in English whatever the language of the machine: the agents read it, not the user.
    // The skill is the text of --ai-context, which follows lang in wslbin.ini (a test checks both).
    const string BlockBody =
        "## Linux utilities on this Windows machine\n" +
        "\n" +
        "Linux utilities (make, rsync, dig, nc, man, ...) are available here through wslbin. Call them by " +
        "name from PowerShell or cmd, with no `wsl` prefix. For how to pass paths, wildcards and quotes, " +
        "run `wslbin --ai-context`.\n";

    const string SkillDescription =
        "Call Linux utilities (make, rsync, dig, nc, man, grep, sed, ...) from PowerShell or cmd on this " +
        "Windows machine through wslbin, with Windows paths, wildcards and quoting handled. Use when a task " +
        "needs a Linux tool, or when a command fails because a Linux utility is missing on Windows.";

    public static int Print(IList<string> args, Config cfg)
    {
        Options.None(args, "--ai-context");
        Out.Info(Help.Document(cfg, "ai-context.md").TrimEnd('\n'));
        return 0;
    }

    /// <param name="Option">the command line option that names its folder</param>
    /// <param name="Folder">null when there is no home folder to look in</param>
    /// <param name="Explicit">named on the command line, so it is created when missing</param>
    sealed record Target(string Name, string Option, string? Folder, bool Explicit, bool IsCodex);

    // The options of --install-ai-context (Tab completion offers them too).
    internal static readonly string[] InstallFlags = ["--remove", "--dry-run", "--claude", "--codex"];
    internal static readonly string[] InstallFolderOptions = ["--claude-dir", "--codex-dir"];

    public static int Install(IList<string> args, Config cfg)
    {
        var options = Options.Parse(args, "--install-ai-context", InstallFlags, folders: InstallFolderOptions);
        bool remove = options.Has("--remove");
        bool dryRun = options.Has("--dry-run");
        bool onlyClaude = options.Has("--claude");
        bool onlyCodex = options.Has("--codex");
        string? claudeDir = options.Value("--claude-dir");
        string? codexDir = options.Value("--codex-dir");
        // a folder named for the agent that the other option leaves out would be ignored without a word
        if (claudeDir != null && onlyCodex && !onlyClaude)
            throw new WslbinException("--claude-dir names the folder of Claude Code, which --codex leaves out");
        if (codexDir != null && onlyClaude && !onlyCodex)
            throw new WslbinException("--codex-dir names the folder of Codex, which --claude leaves out");

        // Where each agent keeps its instructions: the folder that its own variable names, or its
        // usual place in the home folder. (Claude Code: CLAUDE_CONFIG_DIR, else ~/.claude; Codex:
        // CODEX_HOME, else ~/.codex.) Without a home folder, ".claude" would be a folder relative to
        // wherever this runs.
        string? home = Environment.GetEnvironmentVariable("USERPROFILE");
        List<Target> targets = [];
        if (!onlyCodex || onlyClaude)
            targets.Add(new("Claude Code", "--claude-dir", claudeDir ?? EnvOr("CLAUDE_CONFIG_DIR", InHome(home, ".claude")), claudeDir != null, false));
        if (!onlyClaude || onlyCodex)
            targets.Add(new("Codex", "--codex-dir", codexDir ?? EnvOr("CODEX_HOME", InHome(home, ".codex")), codexDir != null, true));

        bool failed = false;
        foreach (Target target in targets)
        {
            if (target.Folder == null)
            {
                Out.Info($"{target.Name}: skipped, USERPROFILE is not set (name the folder: {target.Option} <folder>)");
                continue;
            }
            if (!Directory.Exists(target.Folder))
            {
                if (remove)
                {
                    Out.Info($"{target.Name}: {target.Folder} does not exist, nothing to remove");
                    continue;
                }
                if (!target.Explicit)
                {
                    // not installed, or its folder is somewhere else: not for wslbin to create
                    Out.Info($"{target.Name}: skipped, {target.Folder} does not exist (another folder: {target.Option} <folder>)");
                    continue;
                }
                if (!dryRun) Directory.CreateDirectory(target.Folder);
            }
            try
            {
                if (target.IsCodex)
                {
                    ApplyBlock(Path.Combine(target.Folder, "AGENTS.md"), remove, dryRun);
                }
                else
                {
                    ApplyBlock(Path.Combine(target.Folder, "CLAUDE.md"), remove, dryRun);
                    ApplySkill(Path.Combine(target.Folder, "skills", "wslbin", "SKILL.md"), remove, dryRun, cfg);
                }
            }
            catch (Exception ex) when (ex is WslbinException or IOException or UnauthorizedAccessException)
            {
                // one agent's file that cannot be written leaves the other agent's to be done
                Out.Fail($"{target.Name}: {ex.Message}");
                failed = true;
            }
        }
        return failed ? ExitCodes.Failed : 0;
    }

    static string? EnvOr(string variable, string? fallback) =>
        Environment.GetEnvironmentVariable(variable) is { Length: > 0 } value ? value : fallback;

    static string? InHome(string? home, string folder) => string.IsNullOrEmpty(home) ? null : Path.Combine(home, folder);

    static string BlockText(string newline)
    {
        string text = $"{BeginMarker} (written by \"wslbin --install-ai-context\"; " +
                      $"\"wslbin --install-ai-context --remove\" takes it out) -->\n{BlockBody}{EndMarker}\n";
        return text.Replace("\n", newline);
    }

    // The text of an instructions file. Only UTF-8 (with or without a byte order mark) is read: a file
    // in ANSI or UTF-16 would come back damaged if it were decoded and written as UTF-8.
    static string ReadUtf8(string path, out bool bom)
    {
        string? text = Text.DecodeUtf8(File.ReadAllBytes(path), out bom);
        // UTF-16 without a mark is valid UTF-8 with a NUL between the letters
        if (text == null || text.Contains('\0'))
            throw new WslbinException($"{path} is not UTF-8 text (is it ANSI or UTF-16?): left alone. " +
                                      "Save it as UTF-8, or put the block in by hand.");
        return text;
    }

    // Where the block is: the first end marker, and the last begin marker in front of it (a begin
    // marker that has lost its end is left alone). A marker with no partner is an error: guessing
    // would cut text that belongs to the user.
    static bool FindBlock(string path, string text, out int begin, out int end)
    {
        end = text.IndexOf(EndMarker, StringComparison.Ordinal);
        begin = end < 0 ? -1 : text.LastIndexOf(BeginMarker, end, StringComparison.Ordinal);
        if (end < 0 && !text.Contains(BeginMarker, StringComparison.Ordinal)) return false;
        if (end < 0 || begin < 0)
            throw new WslbinException($"{path} has a wslbin begin or end marker without its other half; " +
                                      "left alone. Delete the stray marker line and run this again.");
        return true;
    }

    // What was done, or in a dry run what would be done.
    static void Report(bool dryRun, string done, string wouldDo) => Out.Info(dryRun ? wouldDo : done);

    static void ApplyBlock(string path, bool remove, bool dryRun)
    {
        bool exists = File.Exists(path);
        bool bom = false;
        string existing = exists ? ReadUtf8(path, out bom) : "";
        // the line ending of the file is the one its first line has; a new file gets "\n"
        int firstBreak = existing.IndexOf('\n');
        string newline = firstBreak > 0 && existing[firstBreak - 1] == '\r' ? "\r\n" : "\n";
        bool hasBlock = FindBlock(path, existing, out int begin, out int end);

        if (remove)
        {
            if (!hasBlock)
            {
                Out.Info($"no wslbin block in {path}");
                return;
            }
            int after = end + EndMarker.Length;
            while (after < existing.Length && existing[after] is '\r' or '\n') after++;
            int before = begin;
            // take the blank line that was put in front of the block with it
            while (before > 0 && existing[before - 1] is '\r' or '\n' && begin - before < 2 * newline.Length) before--;
            string left = existing[..before];
            string right = existing[after..];
            string joint = left.Length == 0 ? "" : right.Length > 0 ? newline + newline : newline;
            string result = left + joint + right;
            if (result.Trim().Length == 0)
            {
                if (!dryRun) File.Delete(path);
                Report(dryRun, $"removed {path} (it held nothing else)", $"would remove {path} (it holds nothing else)");
            }
            else
            {
                if (!dryRun) Text.WriteAllAtomic(path, result, bom);
                Report(dryRun, $"removed the wslbin block from {path}", $"would remove the wslbin block from {path}");
            }
            return;
        }

        string block = BlockText(newline);
        if (hasBlock)
        {
            int after = end + EndMarker.Length;
            if (after < existing.Length && existing[after] == '\r') after++;
            if (after < existing.Length && existing[after] == '\n') after++;
            string updated = string.Concat(existing.AsSpan(0, begin), block, existing.AsSpan(after));
            if (updated == existing)
            {
                Out.Info($"the wslbin block in {path} is up to date");
                return;
            }
            if (!dryRun) Text.WriteAllAtomic(path, updated, bom);
            Report(dryRun, $"updated the wslbin block in {path}", $"would update the wslbin block in {path}");
            return;
        }

        string separator = existing.Length == 0 ? "" : existing.EndsWith('\n') ? newline : newline + newline;
        if (!dryRun) Text.WriteAllAtomic(path, existing + separator + block, bom);
        if (exists) Report(dryRun, $"added the wslbin block to {path}", $"would add the wslbin block to {path}");
        else Report(dryRun, $"created {path}", $"would create {path}");
    }

    static void ApplySkill(string path, bool remove, bool dryRun, Config cfg)
    {
        bool exists = File.Exists(path);
        string existing = exists ? File.ReadAllText(path, new UTF8Encoding(false)) : "";
        if (exists && !existing.Contains(SkillMarker, StringComparison.Ordinal))
        {
            Out.Info($"left {path} alone: it is not the one wslbin wrote");
            return;
        }

        if (remove)
        {
            if (!exists)
            {
                Out.Info($"no wslbin skill at {path}");
                return;
            }
            if (!dryRun)
            {
                File.Delete(path);
                string folder = Path.GetDirectoryName(path)!;
                if (Directory.GetFileSystemEntries(folder).Length == 0) Directory.Delete(folder);
            }
            Report(dryRun, $"removed {path}", $"would remove {path}");
            return;
        }

        string skill = $"---\nname: wslbin\ndescription: {SkillDescription}\n---\n\n" +
                       $"{SkillMarker} (written by \"wslbin --install-ai-context\"; " +
                       "\"wslbin --install-ai-context --remove\" deletes this file) -->\n\n" +
                       Help.Document(cfg, "ai-context.md").TrimEnd('\n') + "\n";
        if (existing == skill)
        {
            Out.Info($"the skill {path} is up to date");
            return;
        }
        if (!dryRun)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            Text.WriteAllAtomic(path, skill);
        }
        if (exists) Report(dryRun, $"updated {path}", $"would update {path}");
        else Report(dryRun, $"created {path}", $"would create {path}");
    }
}
