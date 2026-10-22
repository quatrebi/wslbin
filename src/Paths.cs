// wslbin: Windows paths -> Linux paths.

using System;
using System.Collections.Generic;
using System.IO;

namespace Wslbin
{
    // Windows path -> Linux path. Rules (DECISIONS.md section 14, "stage 1"):
    //   C:\x\y, C:/x/y            -> /mnt/c/x/y
    //   --opt=C:\x, VAR=C:\x      -> the value after the first "=" is translated
    //   -IC:\inc                  -> a single-letter short option glued to a path
    //   \\wsl.localhost\<d>\x     -> /x   (also \\wsl$\<d>\x, if <d> is the configured distro or none is configured)
    //   \\server\share, C:x       -> unchanged, with a warning
    // A relative path is translated only in TranslateCommandArg, and only when it exists (see there).
    internal static class Paths
    {
        // The arguments of a command. Besides the absolute paths of TranslateArg, a relative path that
        // is written with backslashes and exists in the current folder becomes a Linux one: .\file,
        // ..\x, src\a.c are what Tab completion of PowerShell and cmd writes, and bash would read the
        // backslash as an escape. The check is made here, on Windows, against the folder the child
        // starts in; WSL is not asked. What does not exist stays as typed, so .\d+ is still a regex
        // and a file that is about to be created is still a name for the utility to take as it is.
        public static string TranslateCommandArg(string arg, Config cfg, Action<string> warn)
        {
            string translated = TranslateArg(arg, cfg, warn);
            if (!string.Equals(translated, arg, StringComparison.Ordinal) || arg.IndexOf('\\') < 0) return translated;

            string relative;
            if (TryRelative(arg, cfg, out relative)) return relative;

            int eq = arg.IndexOf('=');
            if (eq > 0 && eq + 1 < arg.Length && TryRelative(arg.Substring(eq + 1), cfg, out relative))
                return arg.Substring(0, eq + 1) + relative;

            if (arg.Length > 3 && arg[0] == '-' && IsLetter(arg[1]) && TryRelative(arg.Substring(2), cfg, out relative))
                return arg.Substring(0, 2) + relative;

            return arg;
        }

        static bool TryRelative(string s, Config cfg, out string result)
        {
            result = null;
            // not rooted (\x is the root of the current drive), no drive (C:x), no stream (a:b), and
            // not a leading ~, which bash would take for a home folder once the backslash is a slash
            if (s.Length == 0 || s.IndexOf('\\') < 0 || IsSeparator(s[0]) || s[0] == '~' || s.IndexOf(':') >= 0)
                return false;
            // Windows normalises a path before it looks: it drops spaces and dots at the ends of a name,
            // so " \" would be the root and "a.txt." the file "a.txt". What was typed must be the name
            // that exists, so such names are not asked about.
            foreach (string name in s.Split('\\', '/'))
            {
                if (name.Length == 0 || name == "." || name == "..") continue;
                if (char.IsWhiteSpace(name[0]) || char.IsWhiteSpace(name[name.Length - 1]) || name[name.Length - 1] == '.')
                    return false;
            }
            if (!File.Exists(s) && !Directory.Exists(s)) return false;

            // wsl.exe starts the child in the folder it is in, when that folder has a Linux name
            string folder = Launcher.CurrentFolder();
            if (folder == null || !HasLinuxPath(folder, cfg)) return false;

            result = s.Replace('\\', '/');
            return true;
        }

        // Whether a folder has a Linux name that wsl.exe can start a program in: a path on a drive, or
        // a path of the configured distribution under \\wsl.localhost.
        public static bool HasLinuxPath(string folder, Config cfg)
        {
            return LinuxPathOf(folder, cfg) != null;
        }

        // The Linux name of a folder, or null when it has none.
        public static string LinuxPathOf(string folder, Config cfg)
        {
            string mapped;
            return TryTranslate(folder, cfg, delegate { }, out mapped) ? mapped : null;
        }

        public static string TranslateArg(string arg, Config cfg, Action<string> warn)
        {
            string translated;
            if (TryTranslate(arg, cfg, warn, out translated)) return translated;

            int eq = arg.IndexOf('=');
            if (eq > 0 && eq + 1 < arg.Length && TryTranslate(arg.Substring(eq + 1), cfg, warn, out translated))
                return arg.Substring(0, eq + 1) + translated;

            if (arg.Length > 3 && arg[0] == '-' && IsLetter(arg[1]) &&
                TryTranslate(arg.Substring(2), cfg, warn, out translated))
                return arg.Substring(0, 2) + translated;

            // "C:x" is relative to the current directory of drive C: and has no Linux counterpart.
            // A second colon rules out things like sed's s:a:b:.
            if (arg.Length >= 3 && IsLetter(arg[0]) && arg[1] == ':' && !IsSeparator(arg[2]) && arg.IndexOf(':', 2) < 0)
                warn("'" + arg + "' looks like a path relative to a drive; passed unchanged");

            return arg;
        }

        // The value of a variable from pass_env: a path, or a list of paths separated by ";".
        // Lists become ":"-separated, as PATH is on Linux, and only when every item is a path.
        // Anything else stays as it is.
        public static string TranslateEnvValue(string value, Config cfg)
        {
            Action<string> silent = delegate { };
            string translated;
            if (value.IndexOf(';') < 0)
                return TryTranslate(value, cfg, silent, out translated) ? translated : value;

            var parts = new List<string>();
            foreach (string part in value.Split(';'))
            {
                if (part.Length == 0) continue;
                if (!TryTranslate(part, cfg, silent, out translated)) return value;
                parts.Add(translated);
            }
            return parts.Count == 0 ? value : string.Join(":", parts);
        }

        static bool TryTranslate(string s, Config cfg, Action<string> warn, out string result)
        {
            result = null;

            if (s.Length >= 3 && IsLetter(s[0]) && s[1] == ':' && IsSeparator(s[2]))
            {
                result = MountPath(s[0], s.Substring(3));
                return true;
            }
            // \\?\C:\x, the form that lifts the MAX_PATH limit
            if (s.Length >= 7 && s.StartsWith(@"\\?\", StringComparison.Ordinal) &&
                IsLetter(s[4]) && s[5] == ':' && IsSeparator(s[6]))
            {
                result = MountPath(s[4], s.Substring(7));
                return true;
            }
            if (s.StartsWith(@"\\", StringComparison.Ordinal))
                return TryTranslateUnc(s, cfg, warn, out result);

            return false;
        }

        // Where WSL mounts the drives. Fixed: a different automount root in wsl.conf is not read.
        public const string MountRoot = "/mnt/";

        static string MountPath(char drive, string rest)
        {
            return MountRoot + char.ToLowerInvariant(drive) + "/" + rest.Replace('\\', '/');
        }

        static bool TryTranslateUnc(string s, Config cfg, Action<string> warn, out string result)
        {
            result = null;
            string body = s.Substring(2);
            int sep = body.IndexOf('\\');
            string host = sep < 0 ? body : body.Substring(0, sep);

            bool isWsl = host.Equals("wsl.localhost", StringComparison.OrdinalIgnoreCase) ||
                         host.Equals("wsl$", StringComparison.OrdinalIgnoreCase);
            if (!isWsl)
            {
                warn("'" + s + "' is a network path; passed unchanged");
                return false;
            }

            string tail = sep < 0 ? "" : body.Substring(sep + 1);
            int sep2 = tail.IndexOf('\\');
            string distro = sep2 < 0 ? tail : tail.Substring(0, sep2);
            string path = sep2 < 0 ? "" : tail.Substring(sep2);   // empty, or starts with a backslash

            if (distro.Length == 0)
            {
                warn("'" + s + "' names no distribution; passed unchanged");
                return false;
            }
            if (cfg.Distro.Length > 0 && !distro.Equals(cfg.Distro, StringComparison.OrdinalIgnoreCase))
            {
                warn("'" + s + "' is in distribution '" + distro + "', but wslbin runs in '" +
                     cfg.Distro + "'; passed unchanged");
                return false;
            }
            result = path.Length == 0 ? "/" : path.Replace('\\', '/');
            return true;
        }

        static bool IsLetter(char c)
        {
            return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
        }

        static bool IsSeparator(char c)
        {
            return c == '\\' || c == '/';
        }
    }
}
