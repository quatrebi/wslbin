// wslbin: the current folder, and whether a command can run in it.

namespace Wslbin;

// wsl.exe starts the child in the Linux name of the current folder, and in the Linux home folder
// when the folder has none (a network path \\server\share, a folder of another distribution):
// "rm *.log" would then work on files that the user is not looking at.
internal static class Folder
{
    // The folder this process runs in, or null in the unlikely case that it cannot be read.
    public static string? Current()
    {
        try { return Directory.GetCurrentDirectory(); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return null; }
    }

    // The Linux name of the current folder, or null when wsl.exe cannot start a program there.
    public static string? LinuxPath(Config cfg) => Current() is string folder ? Paths.LinuxPathOf(folder, cfg) : null;

    // Why the command cannot run here, or null.
    public static string? Problem(Config cfg)
    {
        string? folder = Current();
        if (folder == null) return null;
        // without distro in wslbin.ini wsl.exe runs the default distribution, which cannot enter a folder
        // of another one (asked first: the registry is read only for such a folder)
        string? distro = Paths.DistributionOf(folder);
        string? runsIn = distro != null ? Paths.RunsIn(cfg) : null;
        if (distro != null && runsIn != null && !distro.Equals(runsIn, StringComparison.OrdinalIgnoreCase))
            return $"the current folder {folder} is in the distribution {distro}, but wslbin runs in {runsIn}, so the command " +
                   $"would run in your Linux home folder there; set distro = {distro} in wslbin.ini, or change to another folder";
        if (Paths.LinuxPathOf(folder, cfg) == null)
            return $"the current folder {folder} has no Linux path, so the command would run in your Linux home folder " +
                   "instead; change to a folder on a drive (C:\\...) first";
        return null;
    }

    // A drive that WSL has not mounted (subst, a network drive) looks to wslbin like any other: wsl.exe
    // then says "Failed to translate" and runs the command in the Linux home folder (checked). So the
    // script itself checks first: to be in $HOME when the folder is not $HOME means that wsl.exe could
    // not enter it. Not in --wslbin-explain: like the handling of empty arguments, it is plumbing.
    public static string Guard(Config cfg)
    {
        string? folder = Current();
        string? linux = folder != null ? Paths.LinuxPathOf(folder, cfg) : null;
        if (linux == null) return "";
        return $"if [ \"$PWD\" = \"$HOME\" ] && ! [ \"$PWD\" -ef {Bash.Literal(linux)} ]; then " +
               "printf 'wslbin: WSL cannot enter %s (a drive that WSL has not mounted?), so the command would run in your " +
               $"Linux home folder instead; it was not run\\n' {Bash.Literal(folder!)} >&2; exit 125; fi; ";
    }
}
