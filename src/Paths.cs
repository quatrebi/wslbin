// wslbin: Windows paths -> Linux paths.

using System.Diagnostics.CodeAnalysis;

namespace Wslbin;

// Windows path -> Linux path. Rules (DECISIONS.md section 14, "stage 1"):
//   C:\x\y, C:/x/y            -> /mnt/c/x/y
//   --opt=C:\x, VAR=C:\x      -> the value after the first "=" is translated
//   -IC:\inc                  -> a single-letter short option glued to a path
//   \\wsl.localhost\<d>\x     -> /x   (also \\wsl$\<d>\x, if <d> is the distribution wslbin runs in:
//                                      the configured one, or else the default one)
//   \\server\share, C:x       -> unchanged, with a warning
// A relative path is translated only in TranslateCommandArg, and only when it exists (see there).
internal static class Paths
{
    // Where WSL mounts the drives. Fixed: a different automount root in wsl.conf is not read.
    public const string MountRoot = "/mnt/";

    static readonly Action<string> Silent = _ => { };

    // The arguments of a command. Besides the absolute paths of TranslateArg, a relative path that
    // is written with backslashes and exists in the current folder becomes a Linux one: .\file,
    // ..\x, src\a.c are what Tab completion of PowerShell and cmd writes, and bash would read the
    // backslash as an escape. The check is made here, on Windows; WSL is not asked. What does not
    // exist stays as typed, so .\d+ is still a regex and a file that is about to be created is still a
    // name for the utility to take as it is. relative: whether wsl.exe starts the utility in the
    // current folder (Folder.LinuxPath), without which a relative path would mean another file.
    public static string TranslateCommandArg(string arg, Config cfg, Action<string> warn, bool relative)
    {
        string translated = TranslateArg(arg, cfg, warn);
        if (!relative || !string.Equals(translated, arg, StringComparison.Ordinal) || !arg.Contains('\\')) return translated;
        return TranslateParts(arg, TryRelative) ?? arg;
    }

    public static string TranslateArg(string arg, Config cfg, Action<string> warn)
    {
        string? translated = TranslateParts(arg, (string s, [NotNullWhen(true)] out string? result) => TryTranslate(s, cfg, warn, out result));
        if (translated != null) return translated;

        // "C:x" is relative to the current directory of drive C: and has no Linux counterpart.
        // A second colon rules out things like sed's s:a:b:.
        if (arg.Length >= 3 && char.IsAsciiLetter(arg[0]) && arg[1] == ':' && !IsSeparator(arg[2]) && arg.IndexOf(':', 2) < 0)
            warn($"'{arg}' looks like a path relative to a drive; passed unchanged");
        return arg;
    }

    delegate bool Translator(string s, [NotNullWhen(true)] out string? result);

    // The whole argument, the value after its first "=" (--opt=x, VAR=x), or what follows a short
    // option of one letter (-Ix); null when none of them translates.
    static string? TranslateParts(string arg, Translator translate)
    {
        if (translate(arg, out string? result)) return result;

        int eq = arg.IndexOf('=');
        if (eq > 0 && eq + 1 < arg.Length && translate(arg[(eq + 1)..], out result))
            return string.Concat(arg.AsSpan(0, eq + 1), result);

        if (arg.Length > 3 && arg[0] == '-' && char.IsAsciiLetter(arg[1]) && translate(arg[2..], out result))
            return string.Concat(arg.AsSpan(0, 2), result);

        return null;
    }

    static bool TryRelative(string s, [NotNullWhen(true)] out string? result)
    {
        result = null;
        // not rooted (\x is the root of the current drive), no drive (C:x), no stream (a:b), and
        // not a leading ~, which bash would take for a home folder once the backslash is a slash
        if (s.Length == 0 || !s.Contains('\\') || IsSeparator(s[0]) || s[0] == '~' || s.Contains(':'))
            return false;
        // Windows normalises a path before it looks: it drops spaces and dots at the ends of a name,
        // so " \" would be the root and "a.txt." the file "a.txt". What was typed must be the name
        // that exists, so such names are not asked about.
        foreach (string name in s.Split('\\', '/'))
        {
            if (name is "" or "." or "..") continue;
            if (char.IsWhiteSpace(name[0]) || char.IsWhiteSpace(name[^1]) || name[^1] == '.') return false;
        }
        if (!File.Exists(s) && !Directory.Exists(s)) return false;

        result = s.Replace('\\', '/');
        return true;
    }

    // The Linux name of a folder that wsl.exe can start a program in, or null when it has none.
    public static string? LinuxPathOf(string folder, Config cfg) =>
        TryTranslate(folder, cfg, Silent, out string? mapped) ? mapped : null;

    // "Debian" for \\wsl.localhost\Debian\x or \\wsl$\Debian\x; null for any other path.
    public static string? DistributionOf(string path)
    {
        if (!path.StartsWith(@"\\", StringComparison.Ordinal)) return null;
        string[] parts = path[2..].Split('\\');
        return IsWslHost(parts[0]) && parts.Length > 1 && parts[1].Length > 0 ? parts[1] : null;
    }

    // The distribution that wslbin runs in: the one in wslbin.ini, or else the default one (null when
    // the registry does not say). The registry is read once a run, however many arguments ask.
    public static string? RunsIn(Config cfg) => cfg.Distro.Length > 0 ? cfg.Distro : DefaultDistribution.Value;

    static readonly Lazy<string?> DefaultDistribution = new(() => WslQuery.DefaultDistribution());

    // The value of a variable from pass_env: a path, or a list of paths separated by ";".
    // Lists become ":"-separated, as PATH is on Linux, and only when every item is a path.
    // Anything else stays as it is.
    public static string TranslateEnvValue(string value, Config cfg)
    {
        if (!value.Contains(';'))
            return TryTranslate(value, cfg, Silent, out string? translated) ? translated : value;

        List<string> parts = [];
        foreach (string part in value.Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            if (!TryTranslate(part, cfg, Silent, out string? item)) return value;
            parts.Add(item);
        }
        return parts.Count == 0 ? value : string.Join(':', parts);
    }

    static bool TryTranslate(string s, Config cfg, Action<string> warn, [NotNullWhen(true)] out string? result)
    {
        result = null;

        if (s.Length >= 3 && char.IsAsciiLetter(s[0]) && s[1] == ':' && IsSeparator(s[2]))
        {
            result = MountPath(s[0], s[3..]);
            return true;
        }
        // \\?\C:\x, the form that lifts the MAX_PATH limit
        if (s.Length >= 7 && s.StartsWith(@"\\?\", StringComparison.Ordinal) &&
            char.IsAsciiLetter(s[4]) && s[5] == ':' && IsSeparator(s[6]))
        {
            result = MountPath(s[4], s[7..]);
            return true;
        }
        if (s.StartsWith(@"\\", StringComparison.Ordinal))
            return TryTranslateUnc(s, cfg, warn, out result);

        return false;
    }

    static string MountPath(char drive, string rest) => $"{MountRoot}{char.ToLowerInvariant(drive)}/{rest.Replace('\\', '/')}";

    static bool TryTranslateUnc(string s, Config cfg, Action<string> warn, [NotNullWhen(true)] out string? result)
    {
        result = null;
        string body = s[2..];
        int sep = body.IndexOf('\\');
        string host = sep < 0 ? body : body[..sep];
        if (!IsWslHost(host))
        {
            warn($"'{s}' is a network path; passed unchanged");
            return false;
        }

        string tail = sep < 0 ? "" : body[(sep + 1)..];
        int sep2 = tail.IndexOf('\\');
        string distro = sep2 < 0 ? tail : tail[..sep2];
        string path = sep2 < 0 ? "" : tail[sep2..];   // empty, or starts with a backslash
        if (distro.Length == 0)
        {
            warn($"'{s}' names no distribution; passed unchanged");
            return false;
        }
        // a path of another distribution would name a file of this one
        string? runsIn = RunsIn(cfg);
        if (runsIn != null && !distro.Equals(runsIn, StringComparison.OrdinalIgnoreCase))
        {
            warn($"'{s}' is in distribution '{distro}', but wslbin runs in '{runsIn}'; passed unchanged");
            return false;
        }
        result = path.Length == 0 ? "/" : path.Replace('\\', '/');
        return true;
    }

    static bool IsWslHost(string host) =>
        host.Equals("wsl.localhost", StringComparison.OrdinalIgnoreCase) || host.Equals("wsl$", StringComparison.OrdinalIgnoreCase);

    static bool IsSeparator(char c) => c is '\\' or '/';
}
