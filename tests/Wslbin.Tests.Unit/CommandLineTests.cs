namespace Wslbin.Tests;

// How the command line of a wrapper copy and of wslbin.exe itself is read (Program.Execute).
public class CommandLineTests
{
    [Fact]
    public void Wslbin_flags_are_recognised_only_in_front_of_the_arguments()
    {
        using var m = new Machine();
        Assert.Equal("tool -a --wslbin-raw", m.Explain("-a", "--wslbin-raw"));
    }

    [Fact]
    public void The_mode_flag_may_come_before_or_after_explain()
    {
        using var m = new Machine();
        Assert.Equal(0, m.Run("tool", "--wslbin-raw", "--wslbin-explain", "a*"));
        Assert.Equal("tool 'a*'\n", m.Out);
        m.Fake.ClearOutput();
        Assert.Equal(0, m.Run("tool", "--wslbin-explain", "--wslbin-raw", "a*"));
        Assert.Equal("tool 'a*'\n", m.Out);
    }

    [Fact]
    public void An_unknown_wslbin_flag_is_refused_with_125()
    {
        using var m = new Machine();
        Assert.Equal(125, m.Run("tool", "--wslbin-bogus"));
        Assert.Contains("unknown option --wslbin-bogus", m.Err, StringComparison.Ordinal);
    }

    [Fact]
    public void Raw_and_sh_cannot_be_combined()
    {
        using var m = new Machine();
        Assert.Equal(125, m.Run("tool", "--wslbin-raw", "--wslbin-sh", "--wslbin-explain"));
        Assert.Contains("cannot be combined", m.Err, StringComparison.Ordinal);
    }

    [Fact]
    public void Help_and_version_belong_to_the_utility_of_a_wrapper()
    {
        using var m = new Machine();
        Assert.Equal("tool --help --version", m.Explain("--help", "--version"));
    }

    [Fact]
    public void Explaining_ends_with_0_and_never_starts_anything()
    {
        using var m = new Machine();
        Assert.Equal(0, m.Run("tool", "--wslbin-explain", "x"));
        Assert.Empty(m.Fake.ConsoleRuns);
    }

    [Fact]
    public void A_folder_that_cannot_run_a_command_is_said_so_when_explaining()
    {
        using var m = new Machine();
        m.Fake.Cwd = @"\\server\share";
        Assert.Equal(0, m.Run("tool", "--wslbin-explain", "x"));
        Assert.Contains("(so this would not run)", m.Err, StringComparison.Ordinal);
    }

    [Fact]
    public void The_utility_is_spelt_as_the_folder_spells_the_file()
    {
        using var m = new Machine();
        m.MakeExe("rsync");
        // the path as a program may give it to CreateProcess: ...\RSYNC.EXE for rsync.exe
        Assert.Equal(0, Program.Execute(Path.Combine(m.Dir, "RSYNC.EXE"), ["--wslbin-explain", "-av", "x"]));
        Assert.Equal("rsync -av x\n", m.Out);
    }

    [Fact]
    public void A_wrapper_whose_file_cannot_be_listed_is_named_as_started()
    {
        using var m = new Machine();
        Assert.Equal(0, Program.Execute(Path.Combine(m.Dir, "nowhere", "Grep.exe"), ["--wslbin-explain", "x"]));
        Assert.Equal("Grep x\n", m.Out);
    }

    // ---- wslbin.exe itself ----

    [Fact]
    public void Version_is_printed()
    {
        using var m = new Machine();
        Assert.Equal(0, m.Run("wslbin", "--version"));
        Assert.Equal($"wslbin {Program.Version}\n", m.Out);
        Assert.Equal(125, m.Run("wslbin", "--version", "x"));
        Assert.Contains("--version takes no arguments", m.Err, StringComparison.Ordinal);
    }

    [Fact]
    public void Help_is_printed_and_a_topic_too()
    {
        using var m = new Machine();
        Assert.Equal(0, m.Run("wslbin", "--help"));
        Assert.Contains("Usage", m.Out, StringComparison.Ordinal);
        m.Fake.ClearOutput();
        Assert.Equal(0, m.Run("wslbin", "--help", "MODES"));
        Assert.NotEmpty(m.Out);
        Assert.Equal(125, m.Run("wslbin", "--help", "nonsense"));
        Assert.Contains("--help takes one topic", m.Err, StringComparison.Ordinal);
    }

    [Fact]
    public void Help_follows_lang_of_the_config_and_otherwise_the_language_of_Windows()
    {
        using var m = new Machine();
        string english = Help.Overview(m.Config());
        m.Fake.UiLanguage = 0x0419;
        string russian = Help.Overview(m.Config());
        Assert.NotEqual(english, russian);
        Assert.Equal(english, Help.Overview(m.Config("lang = en")));
        Assert.Equal(russian, Help.Overview(m.Config("lang = auto")));
        m.Fake.UiLanguage = 0x0409;
        Assert.Equal(russian, Help.Overview(m.Config("lang = ru")));
    }

    [Fact]
    public void Without_arguments_the_usage_goes_to_standard_error_with_125()
    {
        using var m = new Machine();
        Assert.Equal(125, m.Run("wslbin"));
        Assert.Contains("Usage", m.Err, StringComparison.Ordinal);
        Assert.Equal("", m.Out);
    }

    [Fact]
    public void Any_utility_runs_through_wslbin()
    {
        using var m = new Machine();
        Assert.Equal(0, m.Run("wslbin", "--explain", "rsync", "-av", @"C:\x", "*.log"));
        Assert.Equal("rsync -av /mnt/c/x *.log\n", m.Out);
    }

    [Fact]
    public void Raw_and_sh_come_before_the_utility()
    {
        using var m = new Machine();
        m.Run("wslbin", "--explain", "--raw", "grep", "a*");
        Assert.Equal("grep 'a*'\n", m.Out);
        m.Fake.ClearOutput();
        m.Run("wslbin", "--sh", "--explain", "make", "V=$X");
        Assert.Equal("make \"V=$X\"\n", m.Out);
    }

    [Fact]
    public void A_whole_string_goes_to_bash_with_c_and_its_paths_are_not_translated()
    {
        using var m = new Machine();
        m.Run("wslbin", "--explain", "-c", "ls *.log | wc -l");
        Assert.Equal("ls *.log | wc -l\n", m.Out);
        m.Fake.ClearOutput();
        m.Run("wslbin", "--explain", "-c", @"cat C:\x");
        Assert.Equal("cat C:\\x\n", m.Out);
    }

    [Theory]
    [InlineData(new[] { "--raw", "-c", "x" }, "-c hands the string to bash")]
    [InlineData(new[] { "-c" }, "-c needs a bash string")]
    [InlineData(new[] { "--bogus" }, "unknown option --bogus")]
    [InlineData(new[] { "--raw" }, "no utility given")]
    [InlineData(new[] { "--raw", "--sh", "ls" }, "raw and sh modes cannot be combined")]
    public void A_command_line_that_makes_no_sense_is_refused_with_125(string[] args, string message)
    {
        using var m = new Machine();
        Assert.Equal(125, m.Run("wslbin", args));
        Assert.Contains(message, m.Err, StringComparison.Ordinal);
    }

    [Fact]
    public void The_arguments_after_c_become_positional_parameters()
    {
        using var m = new Machine();
        m.Fake.OnRunInConsole = _ => 0;
        Assert.Equal(0, m.Run("wslbin", "-c", "echo $1", "zero", "", "two"));
        string line = Assert.Single(m.Fake.ConsoleRuns).Arguments;
        List<string> args = WindowsCommandLine.Split(line);
        Assert.Equal(["--exec", "bash", "--noprofile", "--norc", "-c"], args.Take(5));
        Assert.Contains("BASH_ARGV0=''", args[5], StringComparison.Ordinal);
        Assert.Equal(["zero", "\u0001", "two"], args.Skip(6));
    }

    [Fact]
    public void The_offered_options_are_the_visible_commands_and_the_run_options()
    {
        List<string> offered = Program.OfferedOptions();
        Assert.Contains("--link", offered);
        Assert.Contains("--raw", offered);
        Assert.Contains("-c", offered);
        Assert.DoesNotContain("--complete", offered);
        Assert.DoesNotContain("--internal-link", offered);
        Assert.DoesNotContain("-h", offered);
    }

    // ---- what goes wrong is one line, with 125 ----

    [Fact]
    public void An_error_is_one_line_with_125()
    {
        using var m = new Machine();
        Assert.Equal(125, m.Run("wslbin", "--link", "-z"));
        Assert.Equal("wslbin: unknown option -z for --link\n", m.Err);
    }

    [Fact]
    public void A_file_that_cannot_be_written_is_a_fact_about_the_machine_not_a_stack_trace()
    {
        using var m = new Machine();
        string claude = Path.Combine(m.Dir, "claude");
        Directory.CreateDirectory(claude);
        // CLAUDE.md is a folder: writing it fails with an IOException or UnauthorizedAccessException
        Directory.CreateDirectory(Path.Combine(claude, "CLAUDE.md"));
        Assert.Equal(125, m.Run("wslbin", "--install-ai-context", "--claude", "--claude-dir", claude));
        Assert.DoesNotContain("internal error", m.Err, StringComparison.Ordinal);
        Assert.DoesNotContain(" at Wslbin.", m.Err, StringComparison.Ordinal);
    }

    [Fact]
    public void The_path_of_the_running_program_is_asked_of_the_host()
    {
        using var m = new Machine();
        m.Fake.ProcessPathValue = null;
        Assert.Equal(125, Program.Main(["--version"]));
        Assert.Contains("the path of the running program is unknown", m.Err, StringComparison.Ordinal);

        m.Fake.ProcessPathValue = m.Exe("wslbin");
        m.Fake.ClearOutput();
        Assert.Equal(0, Program.Main(["--version"]));
        Assert.StartsWith("wslbin ", m.Out, StringComparison.Ordinal);
    }
}
