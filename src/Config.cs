// wslbin: wslbin.ini, the settings next to the .exe.

using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace Wslbin
{
    // wslbin.ini: "key = value" lines, "#" or ";" at the start of a line for comments. UTF-8.
    //   distro = Ubuntu-24.04         distribution to run in (default: the WSL default one)
    //   lang = ru                     language of the help texts: en, ru or auto (the language of Windows)
    //   raw = grep, sed               utilities that always get arguments untouched
    //   sh = make                     utilities that always get Linux variables and $(...)
    //   pass_env = KENV_*, APP_*, CI  Windows variables that Linux programs should see
    //   path = ~/.local/bin, ~/go/bin directories added to the front of PATH inside WSL
    //   args.ls = --color=auto        arguments put in front of the user's
    // List keys (raw, sh, pass_env, path) add up when repeated; the other keys keep the last value.
    internal sealed class Config
    {
        public string Distro = "";
        public string Lang = "";
        public readonly List<string> PassEnv = new List<string>();
        public readonly List<string> ExtraPath = new List<string>();

        public static string PathFor(string exePath)
        {
            return Path.Combine(Path.GetDirectoryName(exePath), "wslbin.ini");
        }

        // "export PATH=...;" in front of the script when wslbin.ini asks for more directories.
        // bash is started without the profile (that keeps the start fast), so ~/.local/bin,
        // ~/.cargo/bin and the like are not in PATH by themselves.
        public string PathPrefix()
        {
            if (ExtraPath.Count == 0) return "";
            var dirs = new List<string>();
            foreach (string dir in ExtraPath) dirs.Add(InDoubleQuotes(dir));
            return "export PATH=\"" + string.Join(":", dirs) + ":$PATH\"; ";
        }

        // "~" and "~/x" become $HOME and $HOME/x; anything else is literal text inside double quotes.
        static string InDoubleQuotes(string dir)
        {
            var sb = new StringBuilder();
            int i = 0;
            if (dir == "~" || dir.StartsWith("~/", StringComparison.Ordinal))
            {
                sb.Append("$HOME");
                i = 1;
            }
            for (; i < dir.Length; i++)
            {
                char c = dir[i];
                if (c == '"' || c == '\\' || c == '$' || c == '`') sb.Append('\\');
                sb.Append(c);
            }
            return sb.ToString();
        }

        readonly HashSet<string> raw = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        readonly HashSet<string> sh = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        readonly Dictionary<string, List<string>> defaultArgs =
            new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);

        public ArgMode ModeFor(string utility)
        {
            if (raw.Contains(utility)) return ArgMode.Raw;
            if (sh.Contains(utility)) return ArgMode.Sh;
            return ArgMode.Smart;
        }

        public IList<string> DefaultArgsFor(string utility)
        {
            List<string> list;
            return defaultArgs.TryGetValue(utility, out list) ? list : new List<string>();
        }

        // Problems in the file go to "warn" and never stop the load.
        public static Config Load(string path, Action<string> warn)
        {
            var cfg = new Config();
            if (!File.Exists(path)) return cfg;

            byte[] bytes;
            try
            {
                bytes = File.ReadAllBytes(path);
            }
            catch (IOException ex)
            {
                warn("cannot read " + path + ": " + ex.Message);
                return cfg;
            }
            catch (UnauthorizedAccessException ex)
            {
                warn("cannot read " + path + ": " + ex.Message);
                return cfg;
            }
            int skip = bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF ? 3 : 0;
            string text;
            try
            {
                text = new UTF8Encoding(false, true).GetString(bytes, skip, bytes.Length - skip);
            }
            catch (ArgumentException)
            {
                // ANSI from an old editor: the keys still read, values with other letters come out wrong
                warn(path + " is not UTF-8 text: letters outside ASCII are misread (save it as UTF-8)");
                text = new UTF8Encoding(false, false).GetString(bytes, skip, bytes.Length - skip);
            }
            string[] lines = text.Replace("\r", "").Split('\n');

            for (int n = 0; n < lines.Length; n++)
            {
                string line = lines[n].Trim();
                if (line.Length == 0 || line[0] == '#' || line[0] == ';') continue;

                int eq = line.IndexOf('=');
                if (eq <= 0)
                {
                    Warn(warn, n, "expected 'key = value'");
                    continue;
                }
                string key = line.Substring(0, eq).Trim().ToLowerInvariant();
                string value = line.Substring(eq + 1).Trim();

                if (key == "distro") cfg.Distro = Unquote(value);
                else if (key == "lang")
                {
                    cfg.Lang = Unquote(value).ToLowerInvariant();
                    if (cfg.Lang != "en" && cfg.Lang != "ru" && cfg.Lang != "auto")
                        Warn(warn, n, "lang must be en, ru or auto, not '" + cfg.Lang + "'");
                }
                else if (key == "raw") AddAll(cfg.raw, value);
                else if (key == "sh") AddAll(cfg.sh, value);
                else if (key == "pass_env") cfg.PassEnv.AddRange(SplitList(value));
                else if (key == "path") AddPathDirs(cfg, SplitCommas(value), warn, n);
                else if (key.StartsWith("args.", StringComparison.Ordinal) && key.Length > 5)
                    cfg.defaultArgs[key.Substring(5)] = SplitWords(value);
                else Warn(warn, n, "unknown key '" + key + "'");
            }
            return cfg;
        }

        static void AddPathDirs(Config cfg, List<string> entries, Action<string> warn, int line)
        {
            foreach (string entry in entries)
            {
                string dir = Unquote(entry);      // "/opt/my tools" as in distro = "..."
                // ":" separates PATH entries, so a directory with one cannot be expressed.
                if (dir.IndexOf(':') >= 0) Warn(warn, line, "path entry '" + dir + "' contains ':' and is ignored");
                else cfg.ExtraPath.Add(dir);
            }
        }

        static void Warn(Action<string> warn, int zeroBasedLine, string message)
        {
            warn("wslbin.ini line " + (zeroBasedLine + 1) + ": " + message);
        }

        static void AddAll(HashSet<string> set, string value)
        {
            foreach (string item in SplitList(value)) set.Add(item);
        }

        static string Unquote(string s)
        {
            if (s.Length >= 2 && s[0] == '"' && s[s.Length - 1] == '"') return s.Substring(1, s.Length - 2);
            return s;
        }

        // "a b, c" -> "a b", "c": for values that may hold spaces, like directories.
        static List<string> SplitCommas(string value)
        {
            var result = new List<string>();
            foreach (string item in value.Split(','))
            {
                string trimmed = item.Trim();
                if (trimmed.Length > 0) result.Add(trimmed);
            }
            return result;
        }

        // "a, b  c" -> a, b, c
        static List<string> SplitList(string value)
        {
            var result = new List<string>();
            foreach (string item in value.Split(new[] { ',', ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries))
                result.Add(item);
            return result;
        }

        // Words separated by blanks; single or double quotes group a word. No escape characters.
        static List<string> SplitWords(string value)
        {
            var result = new List<string>();
            var current = new StringBuilder();
            bool inWord = false;
            char quote = '\0';
            foreach (char c in value)
            {
                if (quote != '\0')
                {
                    if (c == quote) quote = '\0';
                    else current.Append(c);
                }
                else if (c == '"' || c == '\'')
                {
                    quote = c;
                    inWord = true;
                }
                else if (c == ' ' || c == '\t')
                {
                    if (inWord) result.Add(current.ToString());
                    current.Length = 0;
                    inWord = false;
                }
                else
                {
                    current.Append(c);
                    inWord = true;
                }
            }
            if (inWord) result.Add(current.ToString());
            return result;
        }
    }
}
