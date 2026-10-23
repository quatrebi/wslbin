// wslbin: administrator rights for --link and --unlink.

using System.ComponentModel;
using System.Diagnostics;
using System.Text;

namespace Wslbin;

// Writing into C:\Program Files needs administrator rights. wslbin asks for them by starting
// itself again with the "runas" verb (a UAC prompt) and a hidden command that takes names only.
// The elevated copy prints nothing and takes no file names or paths from the command line, so
// the caller reads the result from the folder afterwards.
internal static class Elevation
{
    const int Cancelled = 1223;      // ERROR_CANCELLED: UAC was declined

    // The exit code of the elevated copy, or null when there was none: the rights were declined,
    // or WSLBIN_NO_ELEVATION=1 says not to ask (scripts and tests never see the UAC prompt).
    public static int? Run(string exePath, string command, IEnumerable<string> names)
    {
        if (Environment.GetEnvironmentVariable("WSLBIN_NO_ELEVATION") == "1") return null;
        var sb = new StringBuilder(command);
        foreach (string name in names)
        {
            sb.Append(' ');
            Launcher.AppendWindowsArg(sb, name);
        }
        var psi = new ProcessStartInfo(exePath, sb.ToString())
        {
            UseShellExecute = true,
            Verb = "runas",
            WindowStyle = ProcessWindowStyle.Hidden
        };
        try
        {
            using Process process = Process.Start(psi) ?? throw new WslbinException("cannot ask for administrator rights: no process was started");
            process.WaitForExit();
            return process.ExitCode;
        }
        catch (Win32Exception ex) when (ex.NativeErrorCode == Cancelled)
        {
            return null;
        }
        catch (Win32Exception ex)
        {
            throw new WslbinException($"cannot ask for administrator rights: {ex.Message}");
        }
    }

    // Hands the names that this user may not change in dir to the elevated copy (command), then asks
    // outcome(name) what became of each: the line to print, or null when it was not done, which
    // failure(name) then explains.
    public static void Finish(string exePath, string dir, string command, List<string> denied,
                              Func<string, string?> outcome, Func<string, string> failure, List<string> failed)
    {
        if (denied.Count == 0) return;
        Out.Info($"{dir} needs administrator rights; asking for them (UAC)...");
        int? code = Run(exePath, command, denied);
        string why = code.HasValue ? $" (exit code {code})" : " (administrator rights were declined)";
        foreach (string n in denied)
        {
            if (outcome(n) is string done) Out.Info(done);
            else failed.Add($"{n}: {failure(n)}{why}");
        }
    }
}
