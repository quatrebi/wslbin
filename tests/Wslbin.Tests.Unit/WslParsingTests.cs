using System.Text;

namespace Wslbin.Tests;

// What wslbin makes of the bytes and the text that wsl.exe and bash write, and of the command line it builds.
public class WslParsingTests
{
    const string Usage =
        "Copyright (c) Microsoft Corporation. All rights reserved.\r\n\r\nUsage: wsl.exe [Argument] [Options...] [CommandLine]\r\n\r\n" +
        "    --install [Distro] [Options...]\r\n        Install additional Windows Subsystem for Linux distributions.\r\n" +
        "    --list, -l [Options]\r\n        Lists distributions.\r\n    --shutdown\r\n        Immediately terminates all running distributions and the WSL 2\r\n" +
        "        lightweight utility virtual machine.\r\n    --status\r\n        Show the status of Windows Subsystem for Linux.\r\n";

    static byte[] Utf16(string s) => Encoding.Unicode.GetBytes(s);

    [Fact]
    public void Utf16_with_a_byte_order_mark_is_decoded()
    {
        Assert.Equal("hi\r\n", WslQuery.Decode([0xFF, 0xFE, .. Utf16("hi\r\n")]));
    }

    [Fact]
    public void Utf16_without_a_mark_is_told_from_utf8_by_its_nul_bytes()
    {
        Assert.Equal("Distro\r\n", WslQuery.Decode(Utf16("Distro\r\n")));
        Assert.Equal("h\u00E9llo\n", WslQuery.Decode([.. "h\u00E9llo\n"u8]));
        Assert.Equal("x", WslQuery.Decode([0xEF, 0xBB, 0xBF, (byte)'x']));
        Assert.Equal("", WslQuery.Decode([]));
    }

    [Fact]
    public void Text_of_bash_after_a_message_of_wsl_in_utf16_on_the_same_stream_is_read_as_both()
    {
        byte[] bytes = [.. Utf16("wsl: a warning of wsl.exe\r\n"), .. "ok jq\n"u8];
        Assert.Equal("wsl: a warning of wsl.exe\r\nok jq\n", WslQuery.Decode(bytes));
    }

    [Fact]
    public void Another_language_is_shown_as_it_is()
    {
        const string text = "\u041D\u0435\u0442 \u0434\u0438\u0441\u0442\u0440\u0438\u0431\u0443\u0442\u0438\u0432\u0430.\r\n";
        Assert.Equal(text, WslQuery.Decode(Utf16(text)));
    }

    [Fact]
    public void The_usage_text_of_a_failed_call_means_that_WSL_is_not_installed()
    {
        Assert.True(WslQuery.IsUsage(new WslResult(1, Usage, "")));
        Assert.True(WslQuery.IsUsage(new WslResult(1, "", Usage)));
        // a call that worked may print these words (completion of dpkg offers all three names)
        Assert.False(WslQuery.IsUsage(new WslResult(0, Usage, "")));
        Assert.False(WslQuery.IsUsage(new WslResult(1, "--install --list", "")));
    }

    [Theory]
    [InlineData(1, "", "boom\r\n", ": boom")]
    [InlineData(1, "from stdout\n", "", ": from stdout")]
    [InlineData(1, "a\nb\n", "", ": a b")]
    [InlineData(3, "", "", " (exit code 3)")]
    public void The_detail_of_a_failed_call_is_what_it_wrote_on_one_line(int code, string output, string error, string want)
    {
        Assert.Equal(want, WslQuery.Detail(new WslResult(code, output, error)));
    }

    [Fact]
    public void The_detail_of_the_usage_text_names_the_fix()
    {
        Assert.Equal(
            ": WSL is not installed (wsl.exe answers with its usage text) (fix: run 'wsl --install' as administrator)",
            WslQuery.Detail(new WslResult(1, Usage, "")));
    }

    static List<Distro> Distros(string listing)
    {
        using var m = new Machine();
        m.Fake.OnWsl = _ => FakeHost.ReplyUtf16(0, listing);
        return WslQuery.Distros();
    }

    [Fact]
    public void The_list_has_the_default_the_state_and_the_version_of_each_distribution_and_nothing_else()
    {
        List<Distro> list = Distros(
            "  NAME              STATE           VERSION\r\n* Ubuntu-24.04      Running         2\r\n  docker-desktop    Stopped         2\r\n  Old               Stopped         1\r\n");
        Assert.Equal(
        [
            new Distro("Ubuntu-24.04", true, "Running", "2"),
            new Distro("docker-desktop", false, "Stopped", "2"),
            new Distro("Old", false, "Stopped", "1"),
        ], list);
    }

    [Fact]
    public void A_state_of_several_words_and_a_line_of_the_usage_text_are_told_apart()
    {
        List<Distro> list = Distros(
            "  NAME      STATE           VERSION\r\n* Ubuntu    Wird ausgef\u00FChrt    2\r\n        Immediately terminates all running distributions and the WSL 2\r\n");
        Distro only = Assert.Single(list);
        Assert.Equal(("Ubuntu", "Wird ausgef\u00FChrt"), (only.Name, only.State));
    }

    [Fact]
    public void A_byte_order_mark_in_front_of_the_list_is_ignored()
    {
        Assert.Single(Distros("\uFEFF* Debian   Running   2\r\n"));
    }

    [Fact]
    public void Distros_says_that_WSL_is_not_installed_when_the_call_answers_with_usage()
    {
        using var m = new Machine();
        m.Fake.OnWsl = _ => FakeHost.ReplyUtf16(1, Usage);
        var ex = Assert.Throws<WslbinException>(WslQuery.Distros);
        Assert.Equal(WslQuery.NotInstalled, ex.Message);
    }

    // ---- the command line of wsl.exe ----

    [Fact]
    public void The_command_line_of_wsl_runs_bash_without_profile_in_the_configured_distribution()
    {
        using var m = new Machine();
        Config cfg = m.Config("distro = Ubuntu 24");
        Assert.Equal("-d \"Ubuntu 24\" --exec bash --noprofile --norc -c \"echo hi\"", Launcher.WslArguments(cfg, "echo hi", []));
        Assert.Equal("--exec bash --noprofile --norc -c x", Launcher.WslArguments(m.Config(""), "x", []));
    }

    [Fact]
    public void An_empty_positional_parameter_travels_as_SOH_and_the_script_turns_it_back()
    {
        using var m = new Machine();
        List<string> words = WindowsCommandLine.Split(Launcher.WslArguments(m.Config(), "echo $1", ["zero", "", "two"]));
        Assert.Equal(["zero", "\u0001", "two"], words.Skip(6));
        Assert.StartsWith("a=(\"$@\")", words[5], StringComparison.Ordinal);
        Assert.EndsWith("echo $1", words[5], StringComparison.Ordinal);
        // without an empty one the script is not touched
        Assert.Equal("echo $1", WindowsCommandLine.Split(Launcher.WslArguments(m.Config(), "echo $1", ["a"]))[5]);
    }

    [Theory]
    [InlineData("plain")]
    [InlineData("a b")]
    [InlineData("")]
    [InlineData("say \"hi\"")]
    [InlineData(@"trail\")]
    [InlineData(@"two\\")]
    [InlineData(@"\""")]
    [InlineData(@"a\\""b c")]
    [InlineData("tab\there")]
    [InlineData("line1\nline2")]
    [InlineData("\u0444\u0430\u0439\u043B \u044F")]
    public void An_argument_survives_the_command_line_of_a_Windows_program(string arg)
    {
        var sb = new StringBuilder();
        Launcher.AppendWindowsArg(sb, "first");
        sb.Append(' ');
        Launcher.AppendWindowsArg(sb, arg);
        sb.Append(' ');
        Launcher.AppendWindowsArg(sb, "last");
        Assert.Equal(["first", arg, "last"], WindowsCommandLine.Split(sb.ToString()));
    }

    [Fact]
    public void Three_thousand_random_arguments_survive_the_command_line()
    {
        var random = new Random(4242);
        const string alphabet = " \t\"\\\\'a$b*?\n\u0444";
        for (int n = 0; n < 3000; n++)
        {
            string arg = string.Create(random.Next(0, 12), random, (span, r) =>
            {
                for (int i = 0; i < span.Length; i++) span[i] = alphabet[r.Next(alphabet.Length)];
            });
            var sb = new StringBuilder();
            Launcher.AppendWindowsArg(sb, arg);
            Assert.Equal([arg], WindowsCommandLine.Split(sb.ToString()));
        }
    }

    [Theory]
    [InlineData(0, 0)]
    [InlineData(1, 1)]
    [InlineData(255, 255)]
    [InlineData(256, 125)]
    [InlineData(-1, 125)]
    [InlineData(unchecked((int)0xC000013A), 130)]
    [InlineData(unchecked((int)0xC0000005), 125)]
    public void Exit_codes_of_Linux_programs_pass_through_and_those_of_wsl_become_125_or_130(int raw, int want)
    {
        Assert.Equal(want, Launcher.MapExitCode(raw));
    }

    // ---- names of wrappers, names that Windows uses ----

    [Theory]
    [InlineData("rsync", true)]
    [InlineData("g++", true)]
    [InlineData("python3.12", true)]
    [InlineData("a_b-c+d", true)]
    [InlineData("7z", true)]
    [InlineData("", false)]
    [InlineData(".hidden", false)]
    [InlineData("-x", false)]
    [InlineData("a b", false)]
    [InlineData("a/b", false)]
    [InlineData(@"..\evil", false)]
    [InlineData("tool.", false)]
    [InlineData("tool.exe", false)]
    [InlineData("TOOL.EXE", false)]
    [InlineData("wslbin", false)]
    [InlineData("WSLBIN", false)]
    [InlineData("con", false)]
    [InlineData("NUL.txt", false)]
    [InlineData("com1", false)]
    [InlineData("LPT9", false)]
    [InlineData("com0", true)]
    [InlineData("caf\u00E9", false)]
    public void A_wrapper_name_is_safe_as_a_file_name_in_bash_and_on_a_command_line(string name, bool valid)
    {
        Assert.Equal(valid, Wrappers.IsValidName(name));
    }

    [Fact]
    public void A_name_of_a_hundred_and_one_characters_is_too_long()
    {
        Assert.True(Wrappers.IsValidName(new string('a', 100)));
        Assert.False(Wrappers.IsValidName(new string('a', 101)));
    }

    [Fact]
    public void Names_that_cmd_and_PowerShell_run_themselves_are_known()
    {
        using var m = new Machine();
        Assert.Contains("cmd.exe has a built-in command", Conflicts.Find("echo", m.Dir), StringComparison.Ordinal);
        Assert.Contains("cmd.exe has a built-in command", Conflicts.Find("ECHO", m.Dir), StringComparison.Ordinal);
        Assert.True(Conflicts.HidesInPowerShell("ls"));
        Assert.True(Conflicts.HidesInPowerShell("LS"));
        Assert.False(Conflicts.HidesInPowerShell("rsync"));
    }

    [Fact]
    public void A_program_in_PATH_outside_the_own_folder_is_a_conflict_and_the_own_folder_is_not()
    {
        using var m = new Machine();
        string other = Path.Combine(m.Dir, "other");
        Directory.CreateDirectory(other);
        File.WriteAllText(Path.Combine(other, "find.exe"), "x");
        File.WriteAllText(Path.Combine(m.Dir, "own.exe"), "x");
        m.Fake.Env["PATH"] = $"{m.Dir};\"{other}\";;";
        Assert.Equal($"Windows already has {Path.Combine(other, "find.exe")}", Conflicts.Find("find", m.Dir), StringComparer.OrdinalIgnoreCase);
        Assert.Null(Conflicts.Find("own", m.Dir));
        Assert.Null(Conflicts.Find("nothing", m.Dir));
    }

    [Fact]
    public void PATHEXT_decides_which_files_are_programs()
    {
        using var m = new Machine();
        File.WriteAllText(Path.Combine(m.Dir, "a.cmd"), "x");
        File.WriteAllText(Path.Combine(m.Dir, "b.xyz"), "x");
        m.Fake.Env["PATH"] = m.Dir;
        Assert.NotNull(SearchPath.Find("a", null));
        Assert.Null(SearchPath.Find("b", null));
        m.Fake.Env["PATHEXT"] = ".XYZ";
        Assert.Null(SearchPath.Find("a", null));
        Assert.NotNull(SearchPath.Find("b", null));
        Assert.Empty(SearchPath.FindAll("a", null));
    }

    [Fact]
    public void Folders_of_a_path_list_are_compared_in_any_spelling()
    {
        Assert.True(SearchPath.SameFolder(@"C:\Tools\", @"c:\tools"));
        Assert.True(SearchPath.SameFolder(@"C:\a\..\Tools", @"C:\tools"));
        Assert.False(SearchPath.SameFolder(@"C:\a", @"C:\b"));
        Assert.False(SearchPath.SameFolder("\0", @"C:\b"));
        Assert.True(SearchPath.Contains(@"C:\x; ""C:\Tools"" ;D:\y", @"c:\tools\"));
        Assert.False(SearchPath.Contains(null, @"C:\tools"));
    }

    [Fact]
    public void A_PowerShell_string_is_ASCII_whatever_the_path()
    {
        Assert.Equal("'C:\\it''s'", Init.PowerShellString(@"C:\it's"));
        Assert.Equal("('C:\\' + [char]1092 + [char]1072 + '\\x')", Init.PowerShellString("C:\\\u0444\u0430\\x"));
        Assert.Equal("''", Init.PowerShellString(""));
        Assert.Equal("[char]1092", Init.PowerShellString("\u0444"));
    }
}
