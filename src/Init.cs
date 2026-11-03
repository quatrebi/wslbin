// wslbin: --init pwsh | clink.

using System.Diagnostics;
using System.Text;

namespace Wslbin;

// wslbin --init pwsh | clink: the code that hooks wslbin into a shell.
internal static class Init
{
    // The first line of shell/wslbin.lua: how wslbin (and setup\uninstall.ps1) know the file as theirs.
    internal const string ClinkScriptMark = "-- wslbin for cmd (Clink)";

    public static int Run(IList<string> args, string exePath)
    {
        if (args.Count == 0) throw new WslbinException("--init needs a shell: pwsh or clink");
        IList<string> rest = [.. args.Skip(1)];
        return args[0] switch
        {
            "pwsh" => PowerShell(rest, exePath),
            "clink" => Clink(rest, exePath),
            _ => throw new WslbinException($"unknown shell '{args[0]}': use pwsh or clink")
        };
    }

    static int PowerShell(IList<string> args, string exePath)
    {
        bool fallback = Options.Parse(args, "--init pwsh", ["--native-fallback"]).Has("--native-fallback");
        // a file that someone copied by hand under a name that cannot be a wrapper name must not
        // reach the code that every new shell runs
        IEnumerable<string> names = Wrappers.Enumerate(Path.GetDirectoryName(exePath)!, exePath)
            .Where(Wrappers.IsValidName)
            .Select(n => $"'{n.Replace("'", "''")}'");

        string code = Resources.Text(Resources.PowerShellInit)
            .Replace("@EXE@", PowerShellString(exePath))
            .Replace("@NAMES@", string.Join(", ", names))
            .Replace("@FALLBACK@", fallback ? "$true" : "$false");
        // "wslbin --init pwsh | Invoke-Expression" hands every line of the output to Invoke-Expression as a
        // command of its own, and the code is many lines: so it goes out as one line that decodes it and runs
        // it in the scope of the caller (ASCII only, whatever the code page). No comment line: in
        // "Invoke-Expression (wslbin --init pwsh)" the lines are joined with blanks, and a comment would swallow
        // the rest.
        string encoded = Convert.ToBase64String(Encoding.UTF8.GetBytes(code));
        Out.Info($"Invoke-Expression ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{encoded}')))");
        return 0;
    }

    // A string literal that survives any code page between wslbin and the shell that reads
    // its output: characters outside ASCII are written as [char] codes.
    internal static string PowerShellString(string s)
    {
        List<string> parts = [];
        var run = new StringBuilder();
        foreach (char c in s)
        {
            if (char.IsAscii(c))
            {
                run.Append(c == '\'' ? "''" : c.ToString());
                continue;
            }
            if (run.Length > 0)
            {
                parts.Add($"'{run}'");
                run.Clear();
            }
            parts.Add($"[char]{(int)c}");
        }
        if (run.Length > 0 || parts.Count == 0) parts.Add($"'{run}'");
        return parts.Count == 1 ? parts[0] : $"({string.Join(" + ", parts)})";
    }

    static int Clink(IList<string> args, string exePath)
    {
        string dir = Options.Parse(args, "--init clink", [], folders: ["--dir"]).Value("--dir") ?? ClinkScriptsDirectory();
        if (!Directory.Exists(dir))
            throw new WslbinException($"the Clink scripts folder {dir} does not exist; is Clink installed? " +
                                      "(or name the folder: wslbin --init clink --dir <folder>)");

        string target = Path.Combine(dir, "wslbin.lua");
        if (File.Exists(target) && !File.ReadAllText(target).StartsWith(ClinkScriptMark, StringComparison.Ordinal))
            throw new WslbinException($"{target} was not written by wslbin; left alone (remove it, or name another folder with --dir)");
        string lua = Resources.Text(Resources.ClinkInit).Replace("@EXE@", LuaString(exePath));
        Text.WriteAllAtomic(target, lua);
        Out.Info($"wrote {target}; open a new cmd window to use it");
        return 0;
    }

    static string LuaString(string s) => $"\"{s.Replace("\\", "\\\\").Replace("\"", "\\\"")}\"";

    // Where Clink looks for scripts of the user: its state folder, which "clink info" prints.
    static string ClinkScriptsDirectory()
    {
        string? clink = SearchPath.Find("clink", null);
        if (clink == null) return DefaultClinkDirectory();
        // clink is a .bat or .cmd file, so cmd.exe runs it: the one of Windows, named by its full path
        var psi = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "cmd.exe"), $"/c \"\"{clink}\" info\"");
        try
        {
            Launcher.Captured? r = Launcher.Capture(psi, 10_000);
            if (r == null) return DefaultClinkDirectory();
            foreach (string line in Text.Lines(Console.OutputEncoding.GetString(r.Output)))
            {
                int colon = line.IndexOf(':');
                if (line.StartsWith("state", StringComparison.Ordinal) && colon > 0) return line[(colon + 1)..].Trim();
            }
        }
        catch (WslbinException)
        {
            // cmd.exe did not start: the default folder will do
        }
        return DefaultClinkDirectory();
    }

    static string DefaultClinkDirectory() => Path.Combine(Environment.GetEnvironmentVariable("LOCALAPPDATA") ?? "", "clink");
}
