// wslbin: Windows variables for Linux programs, through WSLENV.

using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;

namespace Wslbin
{
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
        string wslenv;                                   // null: leave WSLENV alone
        readonly List<string> names = new List<string>();
        // Variables with "/p": name -> the value as WSL will see it (wslbin's reading of it,
        // for --wslbin-explain; WSL does the real translation and honours its own mount root).
        readonly Dictionary<string, string> translated = new Dictionary<string, string>();

        public static EnvPlan Create(Config cfg)
        {
            var plan = new EnvPlan();
            if (cfg.PassEnv.Count == 0) return plan;

            string existing = Environment.GetEnvironmentVariable("WSLENV") ?? "";
            var listed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (string item in existing.Split(':'))
            {
                int slash = item.IndexOf('/');
                string name = slash < 0 ? item : item.Substring(0, slash);
                if (name.Length > 0) listed.Add(name);
            }

            var candidates = new List<string>();
            foreach (DictionaryEntry e in Environment.GetEnvironmentVariables())
                candidates.Add((string)e.Key);
            candidates.Sort(StringComparer.OrdinalIgnoreCase);

            var entries = new List<string>();
            foreach (string name in candidates)
            {
                if (!IsPassable(name) || listed.Contains(name) || !MatchesAny(cfg.PassEnv, name)) continue;
                plan.names.Add(name);
                string value = Environment.GetEnvironmentVariable(name) ?? "";
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
                plan.wslenv = (existing.Length > 0 ? existing + ":" : "") + string.Join(":", entries);
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
            {
                string value;
                Out.Error("wslbin: env " + name + (translated.TryGetValue(name, out value) ? "=" + value : ""));
            }
        }

        // PATH must not be replaced by a Windows one; names WSLENV cannot express are skipped.
        static bool IsPassable(string name)
        {
            if (name.Length == 0 || name[0] == '=') return false;
            if (name.IndexOfAny(new[] { ':', '/', '\\' }) >= 0) return false;
            return !name.Equals("PATH", StringComparison.OrdinalIgnoreCase) &&
                   !name.Equals("WSLENV", StringComparison.OrdinalIgnoreCase);
        }

        static bool MatchesAny(IEnumerable<string> patterns, string name)
        {
            foreach (string pattern in patterns)
            {
                if (WildcardMatch(pattern, 0, name, 0)) return true;
            }
            return false;
        }

        // "*" matches any run of characters, "?" any one; case-insensitive like Windows variables.
        static bool WildcardMatch(string p, int pi, string s, int si)
        {
            while (pi < p.Length)
            {
                if (p[pi] == '*')
                {
                    while (pi < p.Length && p[pi] == '*') pi++;
                    if (pi == p.Length) return true;
                    for (int k = si; k <= s.Length; k++)
                    {
                        if (WildcardMatch(p, pi, s, k)) return true;
                    }
                    return false;
                }
                if (si >= s.Length) return false;
                if (p[pi] != '?' && char.ToUpperInvariant(p[pi]) != char.ToUpperInvariant(s[si])) return false;
                pi++;
                si++;
            }
            return si == s.Length;
        }
    }
}
