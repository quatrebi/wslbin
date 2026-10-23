// wslbin: --ai-context and --install-ai-context.

using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace Wslbin
{
    // wslbin --ai-context prints the instructions for an AI agent. wslbin --install-ai-context
    // puts them where the agents read their instructions: a short block, marked so that it can
    // be found again and taken out, in CLAUDE.md of Claude Code and AGENTS.md of Codex, and a
    // skill with the full text for Claude Code.
    internal static class AiContext
    {
        const string BeginMarker = "<!-- wslbin:begin";
        const string EndMarker = "<!-- wslbin:end -->";
        const string SkillMarker = "<!-- wslbin:managed";

        // In English whatever the language of the machine: the agents read it, not the user.
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
            if (args.Count > 0) throw new WslbinException("--ai-context takes no arguments");
            Out.Info(Help.Document(cfg, "ai-context.md").TrimEnd('\n'));
            return 0;
        }

        enum Agent { ClaudeCode, Codex }

        sealed class Target
        {
            public Agent Agent;
            public string Name;
            public string Option;       // the command line option that names its folder
            public string Folder;       // null when there is no home folder to look in
            public bool Explicit;       // named on the command line, so it is created when missing
        }

        public static int Install(IList<string> args, Config cfg)
        {
            bool remove = false, dryRun = false, onlyClaude = false, onlyCodex = false;
            string claudeDir = null, codexDir = null;
            for (int i = 0; i < args.Count; i++)
            {
                switch (args[i])
                {
                    case "--remove": remove = true; break;
                    case "--dry-run": dryRun = true; break;
                    case "--claude": onlyClaude = true; break;
                    case "--codex": onlyCodex = true; break;
                    case "--claude-dir":
                    case "--codex-dir":
                        if (i + 1 >= args.Count) throw new WslbinException(args[i] + " needs a folder");
                        if (args[i] == "--claude-dir") claudeDir = args[++i];
                        else codexDir = args[++i];
                        break;
                    default:
                        throw new WslbinException("unknown option " + args[i] + " for --install-ai-context");
                }
            }

            // Where each agent keeps its instructions: the folder that its own variable names, or its
            // usual place in the home folder. (Claude Code: CLAUDE_CONFIG_DIR, else ~/.claude; Codex:
            // CODEX_HOME, else ~/.codex.)
            bool failed = false;
            // without a home folder, ".claude" would be a folder relative to wherever this runs
            string home = Environment.GetEnvironmentVariable("USERPROFILE");
            var targets = new List<Target>();
            if (!onlyCodex || onlyClaude)
                targets.Add(new Target
                {
                    Agent = Agent.ClaudeCode,
                    Name = "Claude Code",
                    Option = "--claude-dir",
                    Folder = claudeDir ?? EnvOr("CLAUDE_CONFIG_DIR", InHome(home, ".claude")),
                    Explicit = claudeDir != null
                });
            if (!onlyClaude || onlyCodex)
                targets.Add(new Target
                {
                    Agent = Agent.Codex,
                    Name = "Codex",
                    Option = "--codex-dir",
                    Folder = codexDir ?? EnvOr("CODEX_HOME", InHome(home, ".codex")),
                    Explicit = codexDir != null
                });

            foreach (Target target in targets)
            {
                if (target.Folder == null)
                {
                    Out.Info(target.Name + ": skipped, USERPROFILE is not set (name the folder: " + target.Option + " <folder>)");
                    continue;
                }
                if (!Directory.Exists(target.Folder))
                {
                    if (remove)
                    {
                        Out.Info(target.Name + ": " + target.Folder + " does not exist, nothing to remove");
                        continue;
                    }
                    if (!target.Explicit)
                    {
                        // not installed, or its folder is somewhere else: not for wslbin to create
                        Out.Info(target.Name + ": skipped, " + target.Folder + " does not exist (another folder: " +
                                 target.Option + " <folder>)");
                        continue;
                    }
                    if (!dryRun) Directory.CreateDirectory(target.Folder);
                }
                try
                {
                    if (target.Agent == Agent.Codex)
                    {
                        ApplyBlock(Path.Combine(target.Folder, "AGENTS.md"), remove, dryRun);
                    }
                    else
                    {
                        ApplyBlock(Path.Combine(target.Folder, "CLAUDE.md"), remove, dryRun);
                        ApplySkill(Path.Combine(target.Folder, "skills", "wslbin", "SKILL.md"), remove, dryRun, cfg);
                    }
                }
                catch (WslbinException ex)
                {
                    Out.Error("wslbin: " + target.Name + ": " + ex.Message);
                    failed = true;
                }
            }
            return failed ? ExitCodes.Failed : 0;
        }

        static string EnvOr(string variable, string fallback)
        {
            string value = Environment.GetEnvironmentVariable(variable);
            return string.IsNullOrEmpty(value) ? fallback : value;
        }

        static string InHome(string home, string folder)
        {
            return string.IsNullOrEmpty(home) ? null : Path.Combine(home, folder);
        }

        static string BlockText(string newline)
        {
            string text = BeginMarker + " (written by \"wslbin --install-ai-context\"; " +
                          "\"wslbin --install-ai-context --remove\" takes it out) -->\n" + BlockBody + EndMarker + "\n";
            return text.Replace("\n", newline);
        }

        // The text of an instructions file. Only UTF-8 (with or without a byte order mark) is read: a file
        // in ANSI or UTF-16 would come back damaged if it were decoded and written as UTF-8.
        static string ReadUtf8(string path, out bool bom)
        {
            byte[] bytes = File.ReadAllBytes(path);
            bom = bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF;
            int skip = bom ? 3 : 0;
            string text;
            try
            {
                text = new UTF8Encoding(false, true).GetString(bytes, skip, bytes.Length - skip);
            }
            catch (ArgumentException)
            {
                text = null;
            }
            // UTF-16 without a mark is valid UTF-8 with a NUL between the letters
            if (text == null || text.IndexOf('\0') >= 0)
                throw new WslbinException(path + " is not UTF-8 text (is it ANSI or UTF-16?): left alone. " +
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
            bool anyBegin = text.IndexOf(BeginMarker, StringComparison.Ordinal) >= 0;
            if (end < 0 && !anyBegin) return false;
            if (end < 0 || begin < 0)
                throw new WslbinException(path + " has a wslbin begin or end marker without its other half; " +
                                          "left alone. Delete the stray marker line and run this again.");
            return true;
        }

        static void ApplyBlock(string path, bool remove, bool dryRun)
        {
            string prefix = dryRun ? "would " : "";
            bool exists = File.Exists(path);
            bool bom = false;
            string existing = exists ? ReadUtf8(path, out bom) : "";
            // the line ending of the file is the one its first line has; a new file gets "\n"
            int firstBreak = existing.IndexOf('\n');
            string newline = firstBreak > 0 && existing[firstBreak - 1] == '\r' ? "\r\n" : "\n";

            int begin, end;
            bool hasBlock = FindBlock(path, existing, out begin, out end);

            if (remove)
            {
                if (!hasBlock)
                {
                    Out.Info("no wslbin block in " + path);
                    return;
                }
                int after = end + EndMarker.Length;
                while (after < existing.Length && (existing[after] == '\r' || existing[after] == '\n')) after++;
                int before = begin;
                // take the blank line that was put in front of the block with it
                while (before > 0 && (existing[before - 1] == '\r' || existing[before - 1] == '\n') &&
                       (begin - before) < 2 * newline.Length) before--;
                string left = existing.Substring(0, before);
                string right = existing.Substring(after);
                string result = left + (left.Length > 0 && right.Length > 0 ? newline + newline : (left.Length > 0 ? newline : "")) + right;
                if (result.Trim().Length == 0)
                {
                    Out.Info(prefix + "removed " + path + " (it held nothing else)");
                    if (!dryRun) File.Delete(path);
                }
                else
                {
                    Out.Info(prefix + "removed the wslbin block from " + path);
                    if (!dryRun) Write(path, result, bom);
                }
                return;
            }

            string block = BlockText(newline);
            if (hasBlock)
            {
                int after = end + EndMarker.Length;
                if (after < existing.Length && existing[after] == '\r') after++;
                if (after < existing.Length && existing[after] == '\n') after++;
                string updated = existing.Substring(0, begin) + block + existing.Substring(after);
                if (updated == existing)
                {
                    Out.Info("the wslbin block in " + path + " is up to date");
                    return;
                }
                Out.Info(prefix + "updated the wslbin block in " + path);
                if (!dryRun) Write(path, updated, bom);
                return;
            }

            string separator = existing.Length == 0 ? "" :
                               (existing.EndsWith("\n", StringComparison.Ordinal) ? newline : newline + newline);
            Out.Info(prefix + (exists ? "added the wslbin block to " : "created ") + path);
            if (!dryRun) Write(path, existing + separator + block, bom);
        }

        static void ApplySkill(string path, bool remove, bool dryRun, Config cfg)
        {
            string prefix = dryRun ? "would " : "";
            bool exists = File.Exists(path);
            string existing = exists ? File.ReadAllText(path, new UTF8Encoding(false)) : "";

            if (remove)
            {
                if (!exists)
                {
                    Out.Info("no wslbin skill at " + path);
                    return;
                }
                if (!existing.Contains(SkillMarker))
                {
                    Out.Info("left " + path + " alone: it is not the one wslbin wrote");
                    return;
                }
                Out.Info(prefix + "removed " + path);
                if (dryRun) return;
                File.Delete(path);
                string folder = Path.GetDirectoryName(path);
                if (Directory.GetFileSystemEntries(folder).Length == 0) Directory.Delete(folder);
                return;
            }

            if (exists && !existing.Contains(SkillMarker))
            {
                Out.Info("left " + path + " alone: it is not the one wslbin wrote");
                return;
            }
            string skill = "---\nname: wslbin\ndescription: " + SkillDescription + "\n---\n\n" +
                           SkillMarker + " (written by \"wslbin --install-ai-context\"; " +
                           "\"wslbin --install-ai-context --remove\" deletes this file) -->\n\n" +
                           Help.Document(cfg, "ai-context.md").TrimEnd('\n') + "\n";
            if (exists && existing == skill)
            {
                Out.Info("the skill " + path + " is up to date");
                return;
            }
            Out.Info(prefix + (exists ? "updated " : "created ") + path);
            if (dryRun) return;
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            File.WriteAllText(path, skill, new UTF8Encoding(false));
        }

        static void Write(string path, string text, bool bom)
        {
            File.WriteAllText(path, text, new UTF8Encoding(bom));
        }
    }
}
