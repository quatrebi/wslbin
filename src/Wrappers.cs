// wslbin: wrapper files, the PATH of Windows, names that Windows uses.

using System.Diagnostics;

namespace Wslbin;

// Wrappers: copies of wslbin.exe, each named after a utility.
internal static class Wrappers
{
    public enum Change { Created, Updated, UpToDate }

    // A name that is safe as a file name, in a bash script and in a command line.
    public static bool IsValidName(string name) =>
        name.Length is > 0 and <= 100 &&
        char.IsAsciiLetterOrDigit(name[0]) &&
        name.All(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '_' or '+' or '-') &&
        !name.EndsWith('.') &&                       // Windows drops trailing dots
        !name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) &&
        !name.Equals("wslbin", StringComparison.OrdinalIgnoreCase) &&
        !IsDeviceName(name);

    // CON, NUL, COM1 ... cannot be file names, with or without an extension.
    static bool IsDeviceName(string name)
    {
        string stem = name.Split('.')[0].ToUpperInvariant();
        return stem is "CON" or "PRN" or "AUX" or "NUL" ||
               (stem.Length == 4 && stem[3] is >= '1' and <= '9' && (stem.StartsWith("COM", StringComparison.Ordinal) || stem.StartsWith("LPT", StringComparison.Ordinal)));
    }

    // Whether this user can make files in the folder, which tells "needs administrator rights"
    // from "this one file is locked".
    public static bool CanWrite(string dir)
    {
        string probe = Path.Combine(dir, $".wslbin-write-test-{Guid.NewGuid():N}");
        try
        {
            File.WriteAllText(probe, "");
            File.Delete(probe);
            return true;
        }
        catch (Exception ex) when (ex is UnauthorizedAccessException or IOException)
        {
            return false;
        }
    }

    public static string PathOf(string dir, string name) => Path.Combine(dir, name + ".exe");

    public static bool IsWrapperFile(string path)
    {
        try
        {
            return FileVersionInfo.GetVersionInfo(path).ProductName == "wslbin";
        }
        catch (IOException)
        {
            return false;
        }
    }

    // Names of the wrappers in dir, sorted. wslbin.exe itself is not one.
    public static List<string> Enumerate(string dir, string exePath)
    {
        string self = Path.GetFileName(exePath);
        // the search pattern also matches longer extensions that start with "exe"
        List<string> names =
        [
            .. Directory.GetFiles(dir, "*.exe")
                .Where(f => Path.GetExtension(f).Equals(".exe", StringComparison.OrdinalIgnoreCase) &&
                            !Path.GetFileName(f).Equals(self, StringComparison.OrdinalIgnoreCase) &&
                            IsWrapperFile(f))
                .Select(f => Path.GetFileNameWithoutExtension(f))
        ];
        names.Sort(StringComparer.OrdinalIgnoreCase);
        return names;
    }

    // Copies wslbin.exe to <its folder>\<name>.exe. Throws UnauthorizedAccessException when the
    // folder is not writable for this user.
    public static Change Create(string exePath, string name)
    {
        string target = PathOf(Path.GetDirectoryName(exePath)!, name);
        bool existed = File.Exists(target);
        if (existed && SameContent(target, File.ReadAllBytes(exePath))) return Change.UpToDate;
        File.Copy(exePath, target, true);
        return existed ? Change.Updated : Change.Created;
    }

    public static string Describe(Change change) => change switch
    {
        Change.Created => "created",
        Change.Updated => "updated",
        _ => "up to date"
    };

    // Whether the file holds exactly these bytes (those of wslbin.exe, read once by the caller).
    public static bool SameContent(string path, byte[] content)
    {
        try
        {
            var info = new FileInfo(path);
            return info.Exists && info.Length == content.Length && File.ReadAllBytes(path).AsSpan().SequenceEqual(content);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    // What is wrong with a wrapper, as short phrases. "present" is null when WSL could not be asked;
    // self is the content of wslbin.exe.
    public static List<string> Check(string name, string dir, byte[] self, Dictionary<string, bool>? present)
    {
        List<string> problems = [];
        if (present != null && present.TryGetValue(name, out bool there) && !there) problems.Add("not found in WSL");
        if (!SameContent(PathOf(dir, name), self)) problems.Add("outdated (run: wslbin --link)");
        if (Conflicts.Find(name, dir) is string conflict) problems.Add($"conflict: {conflict}");
        if (Conflicts.HidesInPowerShell(name))
            problems.Add($"PowerShell runs its own '{name}' first: use {name}.exe there (or: wslbin --init pwsh)");
        return problems;
    }
}

// The PATH of Windows: the folders it lists, and what a name finds in them.
internal static class SearchPath
{
    // Every <name><PATHEXT> in PATH outside skipDir (null: none skipped), in the order of PATH.
    public static IEnumerable<string> FindAll(string name, string? skipDir)
    {
        string? pathext = Environment.GetEnvironmentVariable("PATHEXT");
        string[] extensions = (string.IsNullOrEmpty(pathext) ? ".COM;.EXE;.BAT;.CMD" : pathext).Split(';', StringSplitOptions.RemoveEmptyEntries);
        foreach (string dir in Folders(Environment.GetEnvironmentVariable("PATH")))
        {
            if (skipDir != null && SameFolder(dir, skipDir)) continue;
            foreach (string ext in extensions)
            {
                // (File.Exists says false for an entry with characters that no path can have)
                string candidate = Path.Combine(dir, name + ext);
                if (File.Exists(candidate)) yield return candidate;
            }
        }
    }

    // The first <name><PATHEXT> in PATH outside skipDir, in the order of PATH; null when there is none.
    public static string? Find(string name, string? skipDir) => FindAll(name, skipDir).FirstOrDefault();

    public static bool SameFolder(string a, string b)
    {
        try
        {
            return string.Equals(Path.GetFullPath(a).TrimEnd('\\'), Path.GetFullPath(b).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception ex) when (ex is ArgumentException or IOException)
        {
            return false;
        }
    }

    // Whether a ";"-list of folders (a PATH value) has dir in it, in any spelling.
    public static bool Contains(string? pathList, string dir) => Folders(pathList).Any(e => SameFolder(e, dir));

    // The folders of a ";"-list, without quotes and blanks around them.
    static IEnumerable<string> Folders(string? pathList) =>
        (pathList ?? "").Split(';').Select(e => e.Trim().Trim('"')).Where(e => e.Length > 0);
}

// Names that Windows already uses, so that a wrapper would clash with them.
internal static class Conflicts
{
    // cmd.exe runs these itself; a file with the same name is never started from cmd.
    static readonly HashSet<string> CmdBuiltIn = new(StringComparer.OrdinalIgnoreCase)
    {
        "assoc", "break", "call", "cd", "chdir", "cls", "color", "copy", "date", "del", "dir", "echo",
        "endlocal", "erase", "exit", "for", "ftype", "goto", "graftabl", "if", "md", "mkdir", "mklink",
        "move", "path", "pause", "popd", "prompt", "pushd", "rd", "rem", "ren", "rename", "rmdir", "set",
        "setlocal", "shift", "start", "time", "title", "type", "ver", "verify", "vol"
    };

    // Aliases and functions of Windows PowerShell 5.1 and PowerShell 7 (Get-Alias, Get-Command on
    // 2026-10-21). PowerShell looks at them before it looks at files, so "ls" never starts ls.exe.
    static readonly HashSet<string> PowerShellNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "ac", "asnp", "cat", "cd", "chdir", "clc", "clear", "clhy", "cli", "clp", "cls", "clv", "cnsn",
        "compare", "copy", "cp", "cpi", "cpp", "curl", "cvpa", "dbp", "del", "diff", "dir", "dnsn", "ebp",
        "echo", "epal", "epcsv", "epsn", "erase", "etsn", "exsn", "fc", "fhx", "fl", "foreach", "ft", "fw",
        "gal", "gbp", "gc", "gci", "gcm", "gcs", "gdr", "gerr", "ghy", "gi", "gjb", "gl", "gm", "gmo", "gp",
        "gps", "gpv", "group", "gsn", "gsnp", "gsv", "gu", "gv", "gwmi", "h", "help", "history", "icm",
        "iex", "ihy", "ii", "ipal", "ipcsv", "ipmo", "ipsn", "irm", "ise", "iwmi", "iwr", "kill", "lp",
        "ls", "man", "md", "measure", "mi", "mkdir", "more", "mount", "move", "mp", "mv", "nal", "ndr",
        "ni", "nmo", "npssc", "nsn", "nv", "ogv", "oh", "oss", "pause", "popd", "ps", "pushd", "pwd", "r",
        "rbp", "rcjb", "rcsn", "rd", "rdr", "ren", "ri", "rjb", "rm", "rmdir", "rmo", "rni", "rnp", "rp",
        "rsn", "rsnp", "rujb", "rv", "rvpa", "rwmi", "sajb", "sal", "saps", "sasv", "sbp", "sc", "select",
        "set", "shcm", "si", "sl", "sleep", "sls", "sort", "sp", "spjb", "spps", "spsv", "start", "sujb",
        "sv", "swmi", "tee", "trcm", "type", "wget", "where", "wjb", "write"
    };

    public static bool HidesInPowerShell(string name) => PowerShellNames.Contains(name);

    // Why name.exe cannot be a wrapper, or null. ownDir (where wrappers live) is not searched.
    public static string? Find(string name, string ownDir)
    {
        if (CmdBuiltIn.Contains(name)) return "cmd.exe has a built-in command with that name";
        return SearchPath.Find(name, ownDir) is string found ? $"Windows already has {found}" : null;
    }
}
