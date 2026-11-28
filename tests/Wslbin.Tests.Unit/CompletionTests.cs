namespace Wslbin.Tests;

// wslbin --complete <index> <word>...: the candidates for Tab, with a bash in WSL that answers what the test says.
public class CompletionTests
{
    static Machine Setup(string? answer = null)
    {
        var m = new Machine();
        m.MakeExe("wslbin");
        m.Fake.OnWsl = _ => FakeHost.Reply(0, answer ?? "");
        return m;
    }

    static List<string> Complete(Machine m, params string[] args)
    {
        m.Fake.ClearOutput();
        Assert.Equal(0, m.Run("wslbin", ["--complete", .. args]));
        Assert.Equal("", m.Err);
        return [.. m.Out.Split('\n', StringSplitOptions.RemoveEmptyEntries)];
    }

    // ---- wslbin itself, with no WSL ----

    [Theory]
    [InlineData("--l", new[] { "--link", "--list" })]
    [InlineData("--un", new[] { "--unlink" })]
    [InlineData("--ra", new[] { "--raw" })]
    [InlineData("-c", new[] { "-c" })]
    [InlineData("--zzz", new string[0])]
    public void Wslbin_offers_its_commands_that_start_with_the_word(string typed, string[] want)
    {
        using Machine m = Setup();
        Assert.Equal(want, Complete(m, "1", "wslbin", typed));
        Assert.Empty(m.Fake.Calls);
    }

    [Fact]
    public void The_internal_commands_are_not_offered()
    {
        using Machine m = Setup();
        List<string> all = Complete(m, "1", "wslbin", "--");
        Assert.DoesNotContain("--complete", all);
        Assert.DoesNotContain("--internal-link", all);
        Assert.DoesNotContain("--internal-unlink", all);
        Assert.Contains("--doctor", all);
    }

    [Fact]
    public void The_command_word_itself_is_not_completed()
    {
        using Machine m = Setup("junk\n");
        Assert.Empty(Complete(m, "0", "wsl"));
        Assert.Empty(Complete(m, "0"));
        Assert.Empty(m.Fake.Calls);
    }

    [Theory]
    [InlineData(new[] { "2", "wslbin", "--init", "" }, new[] { "pwsh", "clink" })]
    [InlineData(new[] { "2", "wslbin", "--init", "c" }, new[] { "clink" })]
    [InlineData(new[] { "3", "wslbin", "--init", "pwsh", "--n" }, new[] { "--native-fallback" })]
    [InlineData(new[] { "2", "wslbin", "--list", "--" }, new[] { "--names" })]
    [InlineData(new[] { "2", "wslbin", "--help", "co" }, new[] { "completion", "config" })]
    [InlineData(new[] { "3", "wslbin", "--help", "modes", "" }, new string[0])]
    [InlineData(new[] { "2", "wslbin", "--install-ai-context", "--c" }, new[] { "--claude", "--codex", "--claude-dir", "--codex-dir" })]
    [InlineData(new[] { "3", "wslbin", "--install-ai-context", "--claude-dir", "" }, new string[0])]
    [InlineData(new[] { "2", "wslbin", "-c", "" }, new string[0])]
    [InlineData(new[] { "2", "wslbin", "--doctor", "" }, new string[0])]
    [InlineData(new[] { "2", "wslbin", "--version", "" }, new string[0])]
    [InlineData(new[] { "2", "wslbin", "--ai-context", "" }, new string[0])]
    [InlineData(new[] { "2", "wslbin", "--link", "-" }, new[] { "-y", "--yes", "--dry-run" })]
    public void The_options_of_the_commands_of_wslbin_are_offered_without_asking_WSL(string[] args, string[] want)
    {
        using Machine m = Setup("junk\n");
        Assert.Equal(want, Complete(m, args));
        Assert.Empty(m.Fake.Calls);
    }

    [Fact]
    public void Unlink_offers_the_wrappers_and_all()
    {
        using Machine m = Setup();
        m.MakeExe("rsync");
        m.MakeExe("rg");
        Assert.Equal(["rg", "rsync"], Complete(m, "2", "wslbin", "--unlink", "r"));
        Assert.Equal(["--all"], Complete(m, "2", "wslbin", "--unlink", "--a"));
        Assert.Empty(m.Fake.Calls);
    }

    [Fact]
    public void A_word_begun_after_link_asks_WSL_for_commands()
    {
        using Machine m = Setup("jq\njo\n");
        List<string> got = Complete(m, "2", "wslbin", "--link", "j");
        Assert.Equal(["jq", "jo"], got);
        WslCall call = Assert.Single(m.Fake.Calls);
        Assert.Contains("compgen -c", call.Script, StringComparison.Ordinal);
        Assert.Equal(["commands", "j"], call.Positional);
        Assert.Equal(10000, call.TimeoutMs);
    }

    [Fact]
    public void A_utility_after_wslbin_asks_WSL_and_its_mode_flags_come_before_it()
    {
        using Machine m = Setup("rsync\nrsh\n");
        Assert.Equal(["rsync", "rsh"], Complete(m, "1", "wslbin", "rs"));
        Assert.Empty(Complete(m, "2", "wslbin", "--raw", ""));
        Assert.Equal(["--raw", "--sh", "--explain", "-c"], Complete(m, "2", "wslbin", "--raw", "-"));
        Assert.Empty(Complete(m, "2", "wslbin", "--explain", ""));
        Assert.Empty(Complete(m, "3", "wslbin", "--explain", "-c", "x"));
    }

    // ---- a wrapper ----

    static WslCall Last(Machine m) => m.Fake.Calls[^1];

    [Fact]
    public void A_wrapper_gets_the_completion_script_and_the_words_with_Windows_paths_translated()
    {
        using Machine m = Setup("/mnt/c/Windows/\n/mnt/c/Windows.old/\n/mnt/c/Windows/\n");
        m.MakeExe("rsync");
        List<string> got = Complete(m, "2", "rsync", "-av", @"C:\Win");
        Assert.Equal([@"C:\Windows\", @"C:\Windows.old\"], got);
        WslCall call = Last(m);
        Assert.Equal(["complete", "2", "rsync", "-av", "/mnt/c/Win"], call.Positional);
        Assert.Contains("complete", call.Script, StringComparison.Ordinal);
        Assert.StartsWith("if [ \"$PWD\" = \"$HOME\" ]", call.Script, StringComparison.Ordinal);
    }

    [Fact]
    public void Candidates_are_written_the_way_the_word_was_typed_drive_letter_case_and_backslashes()
    {
        using Machine m = Setup("/mnt/c/Windows/win.ini\n");
        m.MakeExe("rsync");
        Assert.Equal([@"C:\Windows\win.ini"], Complete(m, "2", "rsync", "-av", @"C:\Windows\win.i"));
        Assert.Equal([@"c:\windows\win.ini".Replace("windows", "Windows", StringComparison.Ordinal)], Complete(m, "2", "rsync", "-av", @"c:\windows\win.i"));
    }

    [Fact]
    public void A_path_after_an_option_or_glued_to_a_short_option_comes_back_as_a_Windows_path()
    {
        using Machine m = Setup("--exclude-from=/mnt/c/Windows/win.ini\n-I/mnt/c/inc\n/mnt/d\n");
        m.MakeExe("rsync");
        Assert.Equal([@"--exclude-from=C:\Windows\win.ini", @"-IC:\inc", @"D:\"], Complete(m, "1", "rsync", @"--exclude-from=C:\Windows\win.i"));
    }

    [Fact]
    public void A_relative_path_with_backslashes_is_handed_over_with_slashes_and_comes_back_with_backslashes()
    {
        using Machine m = Setup("./alpha one/\n--opt=./x/y\n");
        m.MakeExe("rsync");
        Assert.Equal([@".\alpha one\", @"--opt=.\x\y"], Complete(m, "2", "rsync", "-av", @".\al"));
        Assert.Equal(["complete", "2", "rsync", "-av", "./al"], Last(m).Positional);
    }

    [Fact]
    public void In_raw_mode_a_Windows_path_is_handed_over_as_typed()
    {
        using Machine m = Setup("C:\\Windows\n");
        m.MakeExe("rsync");
        Assert.Equal([@"C:\Windows"], Complete(m, "3", "wslbin", "--raw", "rsync", @"C:\Win"));
        Assert.Contains(@"C:\Win", Last(m).Positional);
        Assert.DoesNotContain("/mnt/c/Win", Last(m).Positional);

        m.Ini("raw = rsync\n");
        Complete(m, "2", "rsync", "-av", @"C:\Win");
        Assert.Contains(@"C:\Win", Last(m).Positional);
    }

    [Fact]
    public void The_name_of_the_command_is_the_one_the_wrapper_file_spells()
    {
        using Machine m = Setup("x\n");
        m.MakeExe("Rscript");
        Complete(m, "1", "RSCRIPT.EXE", "x");
        Assert.Equal("Rscript", Last(m).Positional[2]);
        Complete(m, "1", @"C:\tools\Rscript", "x");
        Assert.Equal("Rscript", Last(m).Positional[2]);
        Complete(m, "1", "unknown", "x");
        Assert.Equal("unknown", Last(m).Positional[2]);
    }

    [Fact]
    public void The_flags_of_wslbin_before_the_arguments_are_not_the_utilitys()
    {
        using Machine m = Setup("--archive\n");
        m.MakeExe("rsync");
        Assert.Equal(["--wslbin-raw", "--wslbin-sh", "--wslbin-explain"], Complete(m, "1", "rsync", "--wslbin"));
        Assert.Equal(["--wslbin-sh", "--wslbin-explain"], Complete(m, "2", "rsync", "--wslbin-raw", "--wslbin"));
        Assert.Empty(m.Fake.Calls);

        // "rsync --w<Tab>" also offers the flags of wslbin after what bash offers
        Assert.Equal(["--archive", "--wslbin-raw", "--wslbin-sh", "--wslbin-explain"], Complete(m, "1", "rsync", "--wsl".Replace("--wsl", "--wsl", StringComparison.Ordinal)));
        Complete(m, "3", "rsync", "--wslbin-raw", "--wslbin-explain", "x");
        Assert.Equal(["complete", "1", "rsync", "x"], Last(m).Positional);
    }

    [Fact]
    public void A_wrapper_in_a_folder_that_has_no_Linux_path_offers_nothing_and_asks_nothing()
    {
        using Machine m = Setup("candidate\n");
        m.MakeExe("rm");
        m.Fake.Cwd = @"\\server\share";
        Assert.Empty(Complete(m, "1", "rm", "x"));
        Assert.Empty(m.Fake.Calls);
    }

    [Fact]
    public void Tab_stays_quiet_when_WSL_fails_and_says_why_with_the_debug_variable()
    {
        using Machine m = Setup();
        m.MakeExe("rm");
        m.Fake.OnWsl = _ => FakeHost.ReplyUtf16(-1, "There is no distribution with the supplied name.\r\n");
        Assert.Empty(Complete(m, "1", "rm", "x"));

        m.Fake.OnWsl = _ => null;
        Assert.Empty(Complete(m, "1", "rm", "x"));

        m.Fake.Env["WSLBIN_DEBUG"] = "1";
        m.Fake.ClearOutput();
        Assert.Equal(0, m.Run("wslbin", "--complete", "1", "rm", "x"));
        Assert.Contains("wsl.exe did not answer", m.Err, StringComparison.Ordinal);
        Assert.Equal("", m.Out);
    }

    [Fact]
    public void The_candidates_are_limited_and_the_words_after_the_cursor_do_not_matter()
    {
        using Machine m = Setup(string.Join('\n', Enumerable.Range(0, 1500).Select(i => $"c{i}")) + "\n");
        m.MakeExe("rm");
        Assert.Equal(1000, Complete(m, "1", "rm", "c", "later", "words").Count);
        Assert.Equal(["complete", "1", "rm", "c"], Last(m).Positional);
    }

    [Theory]
    [InlineData("abc")]
    [InlineData("-1")]
    [InlineData("10001")]
    [InlineData("99999999999999999999")]
    public void A_word_number_that_makes_no_sense_is_refused_in_one_line(string index)
    {
        using Machine m = Setup();
        Assert.Equal(125, m.Run("wslbin", "--complete", index, "wslbin"));
        Assert.StartsWith("wslbin: --complete needs the number of the word to complete (0 to 10000)", m.Err, StringComparison.Ordinal);
        Assert.Equal(1, m.Err.Count(c => c == '\n'));
        Assert.Equal(125, m.Run("wslbin", "--complete"));
    }

    [Fact]
    public void A_word_number_past_the_last_word_completes_an_empty_word()
    {
        using Machine m = Setup("--version\n");
        Assert.Equal(["--version"], Complete(m, "1", "wslbin").Where(c => c == "--version").ToList());
        Assert.Contains("--doctor", Complete(m, "1", "wslbin"));
    }
}
