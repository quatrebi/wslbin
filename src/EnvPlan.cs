// wslbin: Windows variables for Linux programs, through WSLENV.

using System.Buffers;
using System.Collections;
using System.Diagnostics;
using System.IO.Enumeration;

namespace Wslbin;

// Windows variables for Linux programs: names from pass_env, carried by WSLENV.
//
// Two things found by experiment shape this:
//  * WSLENV's "/p" flag makes WSL drop the value of a variable that is not a path (hello, 1,
//    true, foo/bar all arrive empty). So "/p" goes only on variables whose value wslbin
//    recognises as a path or a ";"-list of paths; the rest are listed without flags.
//  * The environment of wsl.exe must stay as it is: it reads SystemRoot, TEMP and the like from
//    it, and with SystemRoot=/mnt/c/Windows it fails to start. So wslbin never rewrites a
//    value; WSL translates it on the Linux side.
internal sealed class EnvPlan
{
    static readonly SearchValues<char> NotPassable = SearchValues.Create(":/\\");

    string? wslenv;                                  // null: leave WSLENV alone
    readonly List<string> names = [];
    // Variables with "/p": name -> the value as WSL will see it (wslbin's reading of it,
    // for --wslbin-explain; WSL does the real translation and honours its own mount root).
    readonly Dictionary<string, string> translated = [];

    public static EnvPlan Create(Config cfg)
    {
        var plan = new EnvPlan();
        if (cfg.PassEnv.Count == 0) return plan;

        string existing = Environment.GetEnvironmentVariable("WSLENV") ?? "";
        var listed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (string item in existing.Split(':'))
        {
            int slash = item.IndexOf('/');
            string name = slash < 0 ? item : item[..slash];
            if (name.Length > 0) listed.Add(name);
        }

        var candidates = new SortedDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (DictionaryEntry e in Environment.GetEnvironmentVariables())
            candidates[(string)e.Key] = (string?)e.Value ?? "";

        List<string> entries = [];
        foreach ((string name, string value) in candidates)
        {
            if (!IsPassable(name) || listed.Contains(name) || !cfg.PassEnv.Any(p => Matches(p, name))) continue;
            plan.names.Add(name);
            string converted = Paths.TranslateEnvValue(value, cfg);
            if (converted != value)
            {
                plan.translated[name] = converted;
                entries.Add(name + "/p");
            }
            else
            {
                entries.Add(name);
            }
        }

        if (entries.Count > 0)
            plan.wslenv = (existing.Length > 0 ? existing + ":" : "") + string.Join(':', entries);
        return plan;
    }

    public void ApplyTo(ProcessStartInfo psi)
    {
        if (wslenv != null) psi.EnvironmentVariables["WSLENV"] = wslenv;
    }

    // For --wslbin-explain: names only, values only where wslbin changed them (paths, never secrets).
    public void Describe()
    {
        foreach (string name in names)
            Out.Fail(translated.TryGetValue(name, out string? value) ? $"env {name}={value}" : $"env {name}");
    }

    // PATH must not be replaced by a Windows one; names WSLENV cannot express are skipped.
    static bool IsPassable(string name) =>
        name.Length > 0 && name[0] != '=' && !name.AsSpan().ContainsAny(NotPassable) &&
        !name.Equals("PATH", StringComparison.OrdinalIgnoreCase) && !name.Equals("WSLENV", StringComparison.OrdinalIgnoreCase);

    // "*" matches any run of characters, "?" any one; case-insensitive like Windows variables.
    static bool Matches(string pattern, string name) => FileSystemName.MatchesSimpleExpression(pattern, name, ignoreCase: true);
}
