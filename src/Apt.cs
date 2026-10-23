// wslbin: installing a utility that WSL lacks, with apt.

using System.Diagnostics;
using System.Text;

namespace Wslbin;

// A utility that --link is asked for and WSL lacks: its apt package, installed when the user agrees.
internal static class Apt
{
    // Returns null when the utility is (or, in a dry run, would be) there, or the reason why it is not.
    public static string? MakeAvailable(Config cfg, string name, bool yes, bool dryRun)
    {
        if (!WslQuery.HasAptGet(cfg))
            return "not found in WSL, and this distribution has no apt: install it with its own package manager";
        string? package = WslQuery.SuggestPackage(cfg, name);
        if (package == null)
            return "not found in WSL, and apt knows no package that provides it (try: wsl -u root apt-get update)";

        string arguments = Arguments(cfg, package);
        string command = $"wsl.exe {arguments}";
        if (dryRun)
        {
            Out.Info($"would run: {command}");
            return null;
        }
        bool go = yes || (IsInteractive() && Confirm($"'{name}' is not installed in WSL. Install the apt package '{package}' now?"));
        if (!go)
            return $"not found in WSL; install it with: {command}   (or repeat with --yes)";

        Out.Info($"running: {command}");
        // apt talks to the user, so it shares the console like a wrapper's utility does
        if (Launcher.RunInConsole(new ProcessStartInfo(Launcher.FindWsl(), arguments) { UseShellExecute = false }) != 0)
            return $"installing '{package}' failed (if apt cannot find packages, try: wsl -u root apt-get update)";
        return WslQuery.Has(cfg, name) ? null : $"'{package}' is installed, but it does not provide '{name}'";
    }

    static string Arguments(Config cfg, string package)
    {
        var sb = new StringBuilder();
        Launcher.AppendDistro(sb, cfg);
        sb.Append("-u root --exec apt-get install -y ");
        Launcher.AppendWindowsArg(sb, package);
        return sb.ToString();
    }

    static bool IsInteractive() => !Console.IsInputRedirected && !Console.IsOutputRedirected;

    static bool Confirm(string question)
    {
        Console.Write($"{question} [y/N] ");
        string? answer = Console.ReadLine()?.Trim();
        return answer != null && (answer.Equals("y", StringComparison.OrdinalIgnoreCase) || answer.Equals("yes", StringComparison.OrdinalIgnoreCase));
    }
}
