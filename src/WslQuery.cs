// wslbin: what wslbin learns about WSL: calls to wsl.exe whose output it reads, and the registry.

using System.Diagnostics;
using System.Security;
using System.Text;
using Microsoft.Win32;

namespace Wslbin;

internal sealed record Distro(string Name, bool IsDefault, string State, string Version);

internal sealed record WslResult(int ExitCode, string Output, string Error);

// What wslbin learns about WSL itself: calls to wsl.exe whose output it reads (management commands
// and Tab completion; a wrapper never captures anything), and the registry.
internal static class WslQuery
{
    static readonly char[] SpaceOrTab = [' ', '\t'];

    // The advice for every message that says WSL itself is missing.
    public const string InstallFix = "run 'wsl --install' as administrator";
    public const string NotInstalled = "WSL is not installed (wsl.exe answers with its usage text)";

    // How long a call whose output wslbin reads may take: a WSL that has to start its virtual machine
    // answers within seconds, one that is stuck never does, and --doctor, --list and --link must not
    // hang on it. Tab completion waits less (Completion.TimeoutMs). The test build shortens it.
    internal static int TimeoutMs = 120_000;

    // Whether WSL has a distribution for this user. WSL keeps one registry key each under
    // HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss, with the name in DistributionName (WSL 1,
    // WSL 2 and the Store version alike). Asked only after wsl.exe failed. The test build replaces it.
    internal static Func<bool> HasDistribution = RegistryHasDistribution;

    // The name of the default distribution: the Lxss key names its key in DefaultDistribution. Null
    // when the registry does not say. The test build replaces it.
    internal static Func<string?> DefaultDistribution = RegistryDefaultDistribution;

    const string LxssKey = @"Software\Microsoft\Windows\CurrentVersion\Lxss";

    static string? RegistryDefaultDistribution()
    {
        try
        {
            using RegistryKey? lxss = Registry.CurrentUser.OpenSubKey(LxssKey);
            if (lxss?.GetValue("DefaultDistribution") is not string { Length: > 0 } id) return null;
            using RegistryKey? distro = lxss.OpenSubKey(id);
            return distro?.GetValue("DistributionName") as string;
        }
        catch (Exception ex) when (ex is SecurityException or UnauthorizedAccessException or IOException)
        {
            return null;
        }
    }

    // A registry that cannot be read says nothing, and then the exit code of the utility stands.
    static bool RegistryHasDistribution()
    {
        try
        {
            using RegistryKey? lxss = Registry.CurrentUser.OpenSubKey(LxssKey);
            if (lxss == null) return false;
            foreach (string name in lxss.GetSubKeyNames())
            {
                using RegistryKey? distro = lxss.OpenSubKey(name);
                if (distro?.GetValue("DistributionName") is string) return true;
            }
            return false;
        }
        catch (Exception ex) when (ex is SecurityException or UnauthorizedAccessException or IOException)
        {
            return true;
        }
    }

    // bash -c <script> in the configured distribution. With positional parameters the first becomes
    // $0, the next $1, ... A call that takes longer than timeoutMs (default: TimeoutMs) is an error.
    public static WslResult RunBash(Config cfg, string script, IList<string>? positional = null, int? timeoutMs = null) =>
        Capture(Launcher.WslArguments(cfg, script, positional ?? []), timeoutMs ?? TimeoutMs);

    // wsl.exe's own commands, like -l -v.
    public static WslResult RunWsl(string arguments) => Capture(arguments, TimeoutMs);

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
            string line = raw.TrimStart('﻿').TrimEnd();
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
