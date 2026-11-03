// wslbin: wslbin.ini, the settings next to the .exe.

using System.Text;

namespace Wslbin;

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
    static readonly char[] ListSeparators = [',', ' ', '\t'];

    public string Distro { get; private set; } = "";
    public string Lang { get; private set; } = "";
    public List<string> PassEnv { get; } = [];
    public List<string> ExtraPath { get; } = [];

    readonly HashSet<string> raw = new(StringComparer.OrdinalIgnoreCase);
    readonly HashSet<string> sh = new(StringComparer.OrdinalIgnoreCase);
    readonly Dictionary<string, List<string>> defaultArgs = new(StringComparer.OrdinalIgnoreCase);

    public static string PathFor(string exePath) => Path.Combine(Path.GetDirectoryName(exePath)!, "wslbin.ini");

    // "export PATH=...;" in front of the script when wslbin.ini asks for more directories.
    // bash is started without the profile (that keeps the start fast), so ~/.local/bin,
    // ~/.cargo/bin and the like are not in PATH by themselves.
    public string PathPrefix() =>
        ExtraPath.Count == 0 ? "" : $"export PATH=\"{string.Join(':', ExtraPath.Select(Bash.InDoubleQuotes))}:$PATH\"; ";

    public ArgMode ModeFor(string utility) =>
        raw.Contains(utility) ? ArgMode.Raw : sh.Contains(utility) ? ArgMode.Sh : ArgMode.Smart;

    public IList<string> DefaultArgsFor(string utility) => defaultArgs.GetValueOrDefault(utility) ?? [];

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
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            warn($"cannot read {path}: {ex.Message}");
            return cfg;
        }
        string? text = Text.DecodeUtf8(bytes, out _);
        if (text == null)
        {
            // ANSI from an old editor: the keys still read, values with other letters come out wrong
            warn($"{path} is not UTF-8 text: letters outside ASCII are misread (save it as UTF-8)");
            text = Text.DecodeUtf8(bytes, out _, strict: false)!;
        }

        string[] lines = text.Replace("\r", "").Split('\n');
        for (int n = 0; n < lines.Length; n++)
        {
            string line = lines[n].Trim();
            if (line.Length == 0 || line[0] is '#' or ';') continue;

            int eq = line.IndexOf('=');
            if (eq <= 0)
            {
                Warn(warn, n, "expected 'key = value'");
                continue;
            }
            string key = line[..eq].Trim().ToLowerInvariant();
            string value = line[(eq + 1)..].Trim();

            switch (key)
            {
                case "distro":
                    cfg.Distro = Unquote(value);
                    break;
                case "lang":
                    cfg.Lang = Unquote(value).ToLowerInvariant();
                    if (cfg.Lang is not ("en" or "ru" or "auto"))
                        Warn(warn, n, $"lang must be en, ru or auto, not '{cfg.Lang}'");
                    break;
                case "raw":
                    cfg.raw.UnionWith(SplitList(value));
                    break;
                case "sh":
                    cfg.sh.UnionWith(SplitList(value));
                    break;
                case "pass_env":
                    cfg.PassEnv.AddRange(SplitList(value));
                    break;
                case "path":
                    AddPathDirs(cfg, value, warn, n);
                    break;
                case not null when key.Length > 5 && key.StartsWith("args.", StringComparison.Ordinal):
                    cfg.defaultArgs[key[5..]] = SplitWords(value);
                    break;
                default:
                    Warn(warn, n, $"unknown key '{key}'");
                    break;
            }
        }
        return cfg;
    }

    // "a b, c" -> "a b", "c": directories may hold spaces, so only commas separate them.
    static void AddPathDirs(Config cfg, string value, Action<string> warn, int line)
    {
        foreach (string entry in value.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
        {
            string dir = Unquote(entry);      // "/opt/my tools" as in distro = "..."
            // ":" separates PATH entries, so a directory with one cannot be expressed.
            if (dir.Contains(':')) Warn(warn, line, $"path entry '{dir}' contains ':' and is ignored");
            else cfg.ExtraPath.Add(dir);
        }
    }

    static void Warn(Action<string> warn, int zeroBasedLine, string message) =>
        warn($"wslbin.ini line {zeroBasedLine + 1}: {message}");

    static string Unquote(string s) => s.Length >= 2 && s[0] == '"' && s[^1] == '"' ? s[1..^1] : s;

    // "a, b  c" -> a, b, c
    static string[] SplitList(string value) => value.Split(ListSeparators, StringSplitOptions.RemoveEmptyEntries);

    // Words separated by blanks; single or double quotes group a word. No escape characters.
    static List<string> SplitWords(string value)
    {
        List<string> result = [];
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
            else if (c is '"' or '\'')
            {
                quote = c;
                inWord = true;
            }
            else if (c is ' ' or '\t')
            {
                if (inWord) result.Add(current.ToString());
                current.Clear();
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
