// wslbin: what wslbin learns about WSL: calls to wsl.exe whose output it reads, and the registry.

using System.Diagnostics;
using System.Text;

namespace Wslbin;

internal sealed record Distro(string Name, bool IsDefault, string State, string Version);

internal sealed record WslResult(int ExitCode, string Output, string Error);

// A utility that bash without the profile does not find and a login shell does (WslQuery.FindInLoginShell):
// FullPath where; Shown the same with ~ for the home folder; Entry the value of a path line of wslbin.ini
// that adds its folder, or null when wslbin.ini cannot name that folder.
internal sealed record LoginShellHit(string FullPath, string Shown, string? Entry);

// What wslbin learns about WSL itself: calls to wsl.exe whose output it reads (management commands
// and Tab completion; a wrapper never captures anything), and the registry.
internal static class WslQuery
{
    static readonly char[] SpaceOrTab = [' ', '\t'];

    // The advice for every message that says WSL itself is missing.
    public const string InstallFix = "run 'wsl --install' as administrator";
    public const string NotInstalled = "WSL is not installed (wsl.exe answers with its usage text)";

    // How long a call whose output wslbin reads may take, and what the registry says about the
    // distributions of WSL, are the host's to say (IHost.QueryTimeoutMs, HasDistribution, DefaultDistribution).

    // bash -c <script> in the configured distribution. With positional parameters the first becomes
    // $0, the next $1, ... A call that takes longer than timeoutMs (default: TimeoutMs) is an error.
    public static WslResult RunBash(Config cfg, string script, IList<string>? positional = null, int? timeoutMs = null) =>
        Capture(Launcher.WslArguments(cfg, script, positional ?? []), timeoutMs ?? Host.Current.QueryTimeoutMs);

    // wsl.exe's own commands, like -l -v.
    public static WslResult RunWsl(string arguments) => Capture(arguments, Host.Current.QueryTimeoutMs);

    static WslResult Capture(string arguments, int timeoutMs)
    {
        Launcher.Captured? r = Launcher.Capture(new ProcessStartInfo(Launcher.FindWsl(), arguments), timeoutMs)
            ?? throw new WslbinException($"wsl.exe did not answer within {timeoutMs / 1000} seconds")
            {
                Fix = "wsl --shutdown, then try again (WSL may be stuck)"
            };
        return new WslResult(r.ExitCode, Decode(r.Output), Decode(r.Error));
    }

    // bash writes UTF-8. wsl.exe writes its own messages (its errors, its usage text, -l -v) in
    // UTF-16, or in UTF-8 when WSL_UTF8=1 is set. UTF-16 text always has NUL bytes (every ASCII
    // letter, blank and line break carries one) and the text of bash here never has, which tells
    // the two apart. A message of wsl.exe may come in front of what bash writes on the same stream:
    // the UTF-16 part then ends with the last line break in UTF-16 (0A 00) after which no NUL follows.
    internal static string Decode(byte[] bytes)
    {
        if (bytes.AsSpan().StartsWith((ReadOnlySpan<byte>)[0xFF, 0xFE])) return Encoding.Unicode.GetString(bytes, 2, bytes.Length - 2);
        if (!bytes.AsSpan().Contains((byte)0)) return Decode8(bytes, 0);
        int split = -1;
        for (int i = 0; i + 1 < bytes.Length; i += 2)
        {
            if (bytes[i] == 0x0A && bytes[i + 1] == 0) split = i + 2;
        }
        if (split > 0 && !bytes.AsSpan(split).Contains((byte)0))
            return Encoding.Unicode.GetString(bytes, 0, split) + Decode8(bytes, split);
        return Encoding.Unicode.GetString(bytes);
    }

    static string Decode8(byte[] bytes, int start)
    {
        if (bytes.AsSpan(start).StartsWith((ReadOnlySpan<byte>)[0xEF, 0xBB, 0xBF])) start += 3;
        return Encoding.UTF8.GetString(bytes, start, bytes.Length - start);
    }

    // Whether wsl.exe printed its usage text instead of doing what it was asked. That is how the
    // wsl.exe of Windows 10 answers every command when WSL is not installed (seen in Windows
    // Sandbox; exit code 1). The text is in the language of Windows, but the names of the options are
    // not translated. Only a failed call counts: Tab completion may well offer these three names as
    // candidates (dpkg has all of them).
    public static bool IsUsage(WslResult r)
    {
        if (r.ExitCode == 0) return false;
        string text = r.Output + "\n" + r.Error;
        return text.Contains("--install") && text.Contains("--list") && text.Contains("--status");
    }

    // ": what went wrong", for a message about a call that failed: what wsl.exe or bash wrote,
    // standard error first, on one line.
    public static string Detail(WslResult r)
    {
        if (IsUsage(r)) return $": {NotInstalled} (fix: {InstallFix})";
        string text = OneLine(r.Error);
        if (text.Length == 0) text = OneLine(r.Output);
        return text.Length == 0 ? $" (exit code {r.ExitCode})" : $": {text}";
    }

    static string OneLine(string text) => text.Replace("\r", "").Trim().Replace("\n", " ");

    // "wsl -l -v": a header, then "* Ubuntu-24.04   Running   2" or "  Debian   Stopped   2", one
    // distribution a line: the name, the state (more than one word where it is translated) and the
    // version. A name is letters, digits and . _ - (the rule of WSL itself, s_ValidateDistroName), and
    // a line of the list is indented by two blanks at most, so neither the header nor a message nor
    // a line of the usage text is taken for one. Throws when WSL is not installed.
    public static List<Distro> Distros()
    {
        WslResult r = RunWsl("-l -v");
        if (IsUsage(r)) throw new WslbinException(NotInstalled);
        List<Distro> list = [];
        foreach (string raw in Text.Lines(r.Output))
        {
            string line = raw.TrimStart('\uFEFF').TrimEnd();
            bool isDefault = line.StartsWith('*');
            if (isDefault) line = line[1..];
            string trimmed = line.TrimStart(' ', '\t');
            if (line.Length - trimmed.Length > 2) continue;
            string[] t = trimmed.Split(SpaceOrTab, StringSplitOptions.RemoveEmptyEntries);
            if (t.Length < 3 || !IsDistroName(t[0]) || t[^1] is not ("1" or "2")) continue;
            list.Add(new Distro(t[0], isDefault, string.Join(' ', t[1..^1]), t[^1]));
        }
        return list;
    }

    static bool IsDistroName(string s) =>
        s.Length > 0 && s.All(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '_' or '-');

    // Whether each name is a command in WSL (command -v). Throws when bash cannot be run at all.
    public static Dictionary<string, bool> Which(Config cfg, IList<string> names)
    {
        var result = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
        if (names.Count == 0) return result;

        string script = cfg.PathPrefix() + $"for n in {string.Join(' ', names.Select(Bash.Literal))}" +
            "; do if command -v \"$n\" >/dev/null 2>&1; then echo \"ok $n\"; else echo \"missing $n\"; fi; done";
        WslResult r = RunBash(cfg, script);
        foreach (string line in Text.Lines(r.Output))
        {
            if (line.StartsWith("ok ", StringComparison.Ordinal)) result[line[3..]] = true;
            else if (line.StartsWith("missing ", StringComparison.Ordinal)) result[line[8..]] = false;
        }
        if (result.Count == 0) throw new WslbinException("cannot run bash in WSL" + Detail(r));
        return result;
    }

    // Whether a name is a command in WSL.
    public static bool Has(Config cfg, string name) => Which(cfg, [name]).GetValueOrDefault(name);

    // The lines of the answer of FindInLoginShell start with Mark. ":HOME" is no utility: a file name of
    // Windows has no ':', so no wrapper has one.
    const string Mark = "@@wslbin@@";
    const string HomeMark = Mark + ":HOME=";

    // Where a login shell finds the names that Which said are missing (false in present; a name that its
    // answer lacks is not asked about). wslbin starts bash without the profile, and on Ubuntu it is
    // ~/.profile that puts ~/.local/bin in PATH: a utility there is "not found in WSL" for wslbin while the
    // terminal of the user runs it. bash -l reads /etc/profile and the first of ~/.bash_profile,
    // ~/.bash_login and ~/.profile; without -i a .bashrc that the profile sources stops at its interactive
    // guard (one without a guard runs in full). One call for all the names, and only this call reads the profile: the utilities
    // still run without it. What the profile prints is not read: only lines that start with Mark count, and
    // each answer starts a line of its own, also after text without a line end. type -P finds files only
    // (no alias, no function); builtin and if keep a function or set -e of the profile out of the way. A call
    // that fails, or that a profile keeps longer than 10 seconds, finds nothing: the caller says what it
    // said before.
    public static Dictionary<string, LoginShellHit> FindInLoginShell(Config cfg, IEnumerable<string> names, Dictionary<string, bool> present)
    {
        var found = new Dictionary<string, LoginShellHit>(StringComparer.Ordinal);
        List<string> asked = [.. names.Where(n => present.TryGetValue(n, out bool there) && !there).Distinct(StringComparer.Ordinal)];
        if (asked.Count == 0) return found;

        string script =
            "printf '" + HomeMark + "%s\\n' \"$HOME\"; " +
            "bash -lc 'for n; do if p=$(builtin type -P -- \"$n\"); then builtin printf \"\\n" + Mark + "%s=%s\\n\" \"$n\" \"$p\"; fi; done' _ " +
            string.Join(' ', asked.Select(Bash.Literal)) + " </dev/null 2>/dev/null";
        WslResult r;
        try
        {
            r = RunBash(cfg, script, timeoutMs: Math.Min(Host.Current.QueryTimeoutMs, 10_000));
        }
        catch (WslbinException)
        {
            return found;
        }

        // (the exit code tells nothing: whatever the profile did decides it)
        string? home = null;
        List<(string Name, string FullPath)> answers = [];
        foreach (string line in Text.Lines(r.Output))
        {
            if (line.StartsWith(HomeMark, StringComparison.Ordinal))
            {
                home ??= line[HomeMark.Length..];
            }
            else if (line.StartsWith(Mark, StringComparison.Ordinal))
            {
                string answer = line[Mark.Length..];
                int eq = answer.IndexOf('=');
                if (eq > 0) answers.Add((answer[..eq], answer[(eq + 1)..]));
            }
        }
        home = home?.TrimEnd('/');
        if (home != null && (!home.StartsWith('/') || home.Any(char.IsControl))) home = null;
        foreach ((string name, string fullPath) in answers)
        {
            // the first answer for a name counts
            if (asked.Contains(name) && IsProgramPath(fullPath, name)) found.TryAdd(name, Hit(fullPath, home));
        }
        return found;
    }

    // An absolute path of a program named name, outside the drives of Windows (wslbin.ini is for folders of
    // Linux), with nothing in it that a line cannot hold or that was not UTF-8.
    static bool IsProgramPath(string path, string name) =>
        path.StartsWith('/') && path.EndsWith($"/{name}", StringComparison.Ordinal) &&
        !path.StartsWith(Paths.MountRoot, StringComparison.Ordinal) &&
        !path.Any(c => char.IsControl(c) || c == '�');

    // The folder of the program as a path line of wslbin.ini writes it. wslbin.ini splits the value at ','
    // and leaves out an entry with ':' (Config.AddPathDirs), so such a folder has no line; it trims the
    // blanks around an entry, so a name that ends in a blank goes in quotes.
    static LoginShellHit Hit(string fullPath, string? home)
    {
        string dir = fullPath[..fullPath.LastIndexOf('/')];
        string folder = WithTilde(dir.Length == 0 ? "/" : dir, home);
        string? entry = folder.Contains(',') || folder.Contains(':') ? null
            : char.IsWhiteSpace(folder[^1]) ? $"\"{folder}\"" : folder;
        return new LoginShellHit(fullPath, WithTilde(fullPath, home), entry);
    }

    // A path in the home folder with ~ in front, as wslbin.ini writes it (Bash.InDoubleQuotes makes it $HOME).
    static string WithTilde(string path, string? home) =>
        home == null ? path :
        path == home ? "~" :
        path.StartsWith($"{home}/", StringComparison.Ordinal) ? $"~{path[home.Length..]}" :
        path;

    public static bool HasAptGet(Config cfg) => RunBash(cfg, "command -v apt-get >/dev/null 2>&1").ExitCode == 0;

    // The apt package that provides a command: command-not-found knows (it prints to stderr),
    // else a package of the same name, else null.
    public static string? SuggestPackage(Config cfg, string command)
    {
        const string Install = "sudo apt install ";
        WslResult r = RunBash(cfg, $"/usr/lib/command-not-found --no-failure-msg {Bash.Literal(command)} 2>&1");
        foreach (string raw in Text.Lines(r.Output + "\n" + r.Error))
        {
            string line = raw.Trim();
            if (!line.StartsWith(Install, StringComparison.Ordinal)) continue;
            string package = line[Install.Length..].Trim().Split(SpaceOrTab)[0];
            if (IsPackageName(package)) return package;
        }
        r = RunBash(cfg, $"apt-cache policy {Bash.Literal(command)} 2>/dev/null | grep -m1 Candidate:");
        return r.Output.Contains("Candidate:") && !r.Output.Contains("(none)") && IsPackageName(command) ? command : null;
    }

    // A Debian package name: lower-case letters, digits, + - . and at least two of them, starting with
    // a letter or digit.
    static bool IsPackageName(string s) =>
        s.Length >= 2 && char.IsAsciiLetterOrDigit(s[0]) &&
        s.All(c => char.IsAsciiLetterLower(c) || char.IsAsciiDigit(c) || c is '+' or '-' or '.');
}
