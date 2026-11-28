using System.Diagnostics;
using System.Text;

namespace Wslbin.Tests;

/// <summary>What the tests need to know of the WSL of this machine.</summary>
public static class Wsl
{
    static readonly Lazy<bool> Present = new(() =>
    {
        try
        {
            var psi = new ProcessStartInfo("wsl.exe", "-l -q") { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
            using Process p = Process.Start(psi)!;
            p.StandardOutput.ReadToEnd();
            p.StandardError.ReadToEnd();
            p.WaitForExit();
            return p.ExitCode == 0;
        }
        catch (System.ComponentModel.Win32Exception)
        {
            return false;
        }
    });

    /// <summary>Skips the test when this machine has no WSL distribution.</summary>
    public static void Require() => Assert.SkipUnless(Present.Value, "no WSL distribution on this machine");

    /// <summary>Runs a command in WSL directly (no wslbin) and returns what it printed.</summary>
    public static string Run(string script)
    {
        var psi = new ProcessStartInfo("wsl.exe") { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true, StandardOutputEncoding = Encoding.UTF8 };
        foreach (string a in new[] { "--exec", "bash", "--noprofile", "--norc", "-c", script }) psi.ArgumentList.Add(a);
        using Process p = Process.Start(psi)!;
        string output = p.StandardOutput.ReadToEnd();
        p.StandardError.ReadToEnd();
        p.WaitForExit();
        return output;
    }
}
