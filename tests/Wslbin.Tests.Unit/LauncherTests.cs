using System.Diagnostics;

namespace Wslbin.Tests;

// A wrapper's run: what is handed to wsl.exe, what comes back of it, when nothing is started at all.
public class LauncherTests
{
    static List<string> Words(Machine m) => WindowsCommandLine.Split(Assert.Single(m.Fake.ConsoleRuns).Arguments);

    [Fact]
    public void A_wrapper_starts_wsl_with_bash_without_profile_and_the_command()
    {
        using var m = new Machine();
        Assert.Equal(0, m.Run("grep", "-n", "a b", "file"));
        ProcessStartInfo psi = Assert.Single(m.Fake.ConsoleRuns);
        Assert.Equal(m.Fake.WslPathValue, psi.FileName);
        Assert.False(psi.UseShellExecute);
        List<string> words = Words(m);
        Assert.Equal(["--exec", "bash", "--noprofile", "--norc", "-c"], words.Take(5));
        Assert.EndsWith(@"grep -n a\ b file", words[5], StringComparison.Ordinal);
        Assert.Equal(6, words.Count);
        Assert.Equal("", m.Out + m.Err);
    }

    [Fact]
    public void The_script_first_checks_that_bash_started_in_the_folder_and_not_in_the_home_folder()
    {
        using var m = new Machine();
        m.Run("grep", "x");
        string script = Words(m)[5];
        Assert.StartsWith("if [ \"$PWD\" = \"$HOME\" ] && ! [ \"$PWD\" -ef ", script, StringComparison.Ordinal);
        Assert.Contains("it was not run", script, StringComparison.Ordinal);
        Assert.Contains("exit 125; fi; grep x", script, StringComparison.Ordinal);
    }

    [Fact]
    public void The_configured_distribution_goes_in_front()
    {
        using var m = new Machine();
        m.Ini("distro = Debian");
        m.Run("grep", "x");
        Assert.Equal(["-d", "Debian"], Words(m).Take(2));
    }

    [Theory]
    [InlineData(2, 2)]
    [InlineData(3, 3)]
    [InlineData(126, 126)]
    [InlineData(127, 127)]
    [InlineData(255, 255)]
    public void The_exit_code_of_the_utility_comes_back_as_it_is_with_nothing_added_on_standard_error(int code, int want)
    {
        using var m = new Machine();
        m.Fake.OnRunInConsole = _ => code;
        Assert.Equal(want, m.Run("grep", "x", "file"));
        Assert.Equal("", m.Err);
    }

    [Theory]
    [InlineData(-1, 125)]
    [InlineData(1056, 125)]
    [InlineData(-1073741510, 130)]     // STATUS_CONTROL_C_EXIT
    public void The_failures_of_wsl_itself_become_125_and_a_Ctrl_C_130(int code, int want)
    {
        using var m = new Machine();
        m.Fake.OnRunInConsole = _ => code;
        Assert.Equal(want, m.Run("grep", "x"));
    }

    [Fact]
    public void Without_a_distribution_the_wrapper_says_so_instead_of_passing_on_the_exit_code_of_wsl()
    {
        using var m = new Machine();
        m.Fake.HasDistributionValue = false;
        m.Fake.OnRunInConsole = _ => 1;
        Assert.Equal(125, m.Run("grep", "x", "file"));
        Assert.Contains("WSL is not installed, or has no distribution, so wsl.exe answered instead of running the command " +
                        "(fix: run 'wsl --install' as administrator)", m.Err, StringComparison.Ordinal);
    }

    [Fact]
    public void The_registry_is_not_asked_when_the_command_worked()
    {
        using var m = new Machine();
        m.Fake.HasDistributionValue = false;
        Assert.Equal(0, m.Run("grep", "x"));
        Assert.Equal("", m.Err);
    }

    [Fact]
    public void Ctrl_C_is_ignored_while_the_child_runs_and_the_subscription_is_taken_back()
    {
        using var m = new Machine();
        int during = -1;
        m.Fake.OnRunInConsole = _ =>
        {
            during = m.Fake.CtrlCSubscriptions;
            return 0;
        };
        m.Run("grep", "x");
        Assert.True(during >= 1);
        Assert.True(m.Fake.CtrlCIgnored);
        Assert.Equal(0, m.Fake.CtrlCSubscriptions);
    }

    [Fact]
    public void A_folder_that_has_no_Linux_path_runs_nothing()
    {
        using var m = new Machine();
        m.Fake.Cwd = @"\\server\share\dir";
        Assert.Equal(125, m.Run("rm", "*.log"));
        Assert.Contains("has no Linux path, so the command would run in your Linux home folder", m.Err, StringComparison.Ordinal);
        Assert.Empty(m.Fake.ConsoleRuns);
    }

    [Fact]
    public void A_folder_of_another_distribution_runs_nothing_unless_it_is_the_default_one()
    {
        using var m = new Machine();
        m.Fake.Cwd = @"\\wsl.localhost\Debian\tmp";
        m.Fake.DefaultDistributionValue = "Other";
        Assert.Equal(125, m.Run("rm", "*.log"));
        Assert.Contains("is in the distribution Debian, but wslbin runs in Other", m.Err, StringComparison.Ordinal);
        Assert.Empty(m.Fake.ConsoleRuns);

        m.Fake.DefaultDistributionValue = "debian";
        Assert.Equal(0, m.Run("rm", "*.log"));
        Assert.Single(m.Fake.ConsoleRuns);
        // in the folder of its distribution there is no guard to the Windows side: the folder is /tmp
        Assert.Contains("/tmp", Words(m)[5], StringComparison.Ordinal);
    }

    [Fact]
    public void An_unreadable_current_folder_does_not_stop_the_run()
    {
        using var m = new Machine();
        m.Fake.Cwd = null;
        Assert.Equal(0, m.Run("grep", "x"));
        Assert.StartsWith("grep x", Words(m)[5], StringComparison.Ordinal);
    }

    [Fact]
    public void The_variables_of_pass_env_go_into_WSLENV_of_wsl_after_those_of_the_user()
    {
        using var m = new Machine();
        m.Fake.Env["APP_DIR"] = @"C:\x";
        m.Fake.Env["APP_TEXT"] = "hello";
        m.Fake.Env["WSLENV"] = "MINE/u";
        m.Ini("pass_env = APP_*\n");
        m.Run("printf", "x");
        ProcessStartInfo psi = Assert.Single(m.Fake.ConsoleRuns);
        Assert.Equal("MINE/u:APP_DIR/p:APP_TEXT", psi.EnvironmentVariables["WSLENV"]);
    }

    // ---- which wsl.exe ----

    [Fact]
    public void Wsl_is_the_one_of_System32_and_a_32_bit_process_is_sent_to_Sysnative()
    {
        using var m = new Machine();
        m.Fake.WslPathValue = null;
        m.Fake.WindowsDirectoryValue = Path.Combine(m.Dir, "Windows");
        Directory.CreateDirectory(Path.Combine(m.Dir, "Windows", "System32"));
        File.WriteAllText(Path.Combine(m.Dir, "Windows", "System32", "wsl.exe"), "x");
        Assert.Equal(Path.Combine(m.Dir, "Windows", "System32", "wsl.exe"), Launcher.FindWsl());

        m.Fake.IsWow64Value = true;
        var ex = Assert.Throws<WslbinException>(Launcher.FindWsl);
        Assert.Contains("wsl.exe not found, so WSL is not installed (fix: run 'wsl --install' as administrator)", ex.Message, StringComparison.Ordinal);
        Directory.CreateDirectory(Path.Combine(m.Dir, "Windows", "Sysnative"));
        File.WriteAllText(Path.Combine(m.Dir, "Windows", "Sysnative", "wsl.exe"), "x");
        Assert.Equal(Path.Combine(m.Dir, "Windows", "Sysnative", "wsl.exe"), Launcher.FindWsl());
    }

    [Fact]
    public void A_wrapper_without_wsl_says_so_and_exits_with_125()
    {
        using var m = new Machine();
        m.Fake.WslPathValue = null;
        m.Fake.WindowsDirectoryValue = Path.Combine(m.Dir, "NoWindows");
        Assert.Equal(125, m.Run("grep", "x"));
        Assert.Contains("wsl.exe not found", m.Err, StringComparison.Ordinal);
    }
}
