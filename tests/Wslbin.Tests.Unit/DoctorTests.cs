namespace Wslbin.Tests;

// wslbin --doctor against a WSL that says what the test says.
public class DoctorTests
{
    const string Usage = "Usage: wsl.exe\r\n    --install [Distro]\r\n    --list, -l\r\n    --status\r\n";
    const string Healthy = "  NAME              STATE           VERSION\r\n* Ubuntu-24.04      Running         2\r\n  docker-desktop    Stopped         2\r\n";

    sealed class Wsl
    {
        public string List { get; set; } = Healthy;
        public int ListExit { get; set; }
        public string Bash { get; set; } = "5.2.21(1)-release";
        public int BashExit { get; set; }
        public string? Mount { get; set; } = "/mnt/c/";
        public bool BashCompletion { get; set; } = true;
        public string MissingDirectories { get; set; } = "";
        public string Which { get; set; } = "";
    }

    static Machine Setup(Wsl? wsl = null, string? ini = null)
    {
        wsl ??= new Wsl();
        var m = new Machine();
        m.MakeExe("wslbin");
        m.Fake.Env["PATH"] = m.Dir;
        if (ini != null) m.Ini(ini);
        m.Fake.OnWsl = call =>
        {
            if (call.IsList) return FakeHost.ReplyUtf16(wsl.ListExit, wsl.List);
            string script = call.Script ?? "";
            if (script.Contains("BASH_VERSION", StringComparison.Ordinal)) return FakeHost.Reply(wsl.BashExit, wsl.Bash + "\n");
            if (script.Contains("wslpath", StringComparison.Ordinal)) return FakeHost.Reply(0, wsl.Mount == null ? "" : $"wslbin-mount:{wsl.Mount}\n");
            if (script.Contains("bash_completion", StringComparison.Ordinal)) return FakeHost.Reply(0, wsl.BashCompletion ? "yes\n" : "no\n");
            if (script.Contains(".cargo/bin", StringComparison.Ordinal)) return FakeHost.Reply(0, wsl.MissingDirectories);
            if (script.Contains("command -v \"$n\"", StringComparison.Ordinal)) return FakeHost.Reply(0, wsl.Which);
            if (script.Contains("bash -lc", StringComparison.Ordinal)) return FakeHost.Reply(0, "");
            return FakeHost.Reply(0);
        };
        return m;
    }

    static int Doctor(Machine m)
    {
        m.Fake.ClearOutput();
        return m.Run("wslbin", "--doctor");
    }

    [Fact]
    public void A_healthy_setup_passes_and_says_so()
    {
        using Machine m = Setup();
        Assert.Equal(0, Doctor(m));
        Assert.Contains($"wslbin {Program.Version}, {m.Exe("wslbin")}", m.Out, StringComparison.Ordinal);
        Assert.Contains("[ ok ] install type: portable", m.Out, StringComparison.Ordinal);
        Assert.Contains("[ ok ] config: none (defaults;", m.Out, StringComparison.Ordinal);
        Assert.Contains("[ ok ] distributions: Ubuntu-24.04 (default), docker-desktop", m.Out, StringComparison.Ordinal);
        Assert.Contains("[ ok ] wslbin runs in: Ubuntu-24.04 (the default)", m.Out, StringComparison.Ordinal);
        Assert.Contains("[ ok ] bash 5.2.21(1)-release starts", m.Out, StringComparison.Ordinal);
        Assert.Contains("[ ok ] drives are mounted at /mnt/", m.Out, StringComparison.Ordinal);
        Assert.Contains("[ ok ] bash-completion is installed in WSL", m.Out, StringComparison.Ordinal);
        Assert.Contains("[ ok ] the folder is in PATH", m.Out, StringComparison.Ordinal);
        Assert.Contains("[ ok ] no wrappers yet", m.Out, StringComparison.Ordinal);
        Assert.EndsWith("Everything looks fine.\n", m.Out, StringComparison.Ordinal);
    }

    [Fact]
    public void WSL_that_is_not_installed_is_said_with_the_fix_and_no_line_of_the_usage_text_is_a_distribution()
    {
        using Machine m = Setup(new Wsl { List = Usage, ListExit = 1 });
        Assert.Equal(125, Doctor(m));
        Assert.Contains("[FAIL] WSL is not installed", m.Out, StringComparison.Ordinal);
        Assert.Contains("fix: run 'wsl --install' as administrator", m.Out, StringComparison.Ordinal);
        Assert.DoesNotContain("distributions:", m.Out, StringComparison.Ordinal);
        Assert.DoesNotContain("default distribution", m.Out, StringComparison.Ordinal);
    }

    [Fact]
    public void A_wsl_that_does_not_answer_is_given_up_on_with_a_fix()
    {
        using Machine m = Setup();
        m.Fake.QueryTimeout = 2000;
        m.Fake.OnWsl = _ => null;
        Assert.Equal(125, Doctor(m));
        Assert.Contains("[FAIL] wsl.exe did not answer within 2 seconds", m.Out, StringComparison.Ordinal);
        Assert.Contains("fix: wsl --shutdown, then try again (WSL may be stuck)", m.Out, StringComparison.Ordinal);
    }

    [Fact]
    public void A_missing_wsl_exe_is_a_failure()
    {
        using Machine m = Setup();
        m.Fake.WslPathValue = null;
        m.Fake.WindowsDirectoryValue = Path.Combine(m.Dir, "nowhere");
        Assert.Equal(125, Doctor(m));
        Assert.Contains("[FAIL] wsl.exe not found", m.Out, StringComparison.Ordinal);
    }

    [Fact]
    public void No_distribution_at_all_is_a_failure()
    {
        using Machine m = Setup(new Wsl { List = "  NAME   STATE   VERSION\r\n" });
        Assert.Equal(125, Doctor(m));
        Assert.Contains("[FAIL] no WSL distribution is installed", m.Out, StringComparison.Ordinal);
        Assert.Contains("fix: wsl --install -d Ubuntu", m.Out, StringComparison.Ordinal);
    }

    [Fact]
    public void A_configured_distribution_must_be_installed_in_any_case_of_its_name()
    {
        using (Machine m = Setup(ini: "distro = ubuntu-24.04\n"))
        {
            Assert.Equal(0, Doctor(m));
            Assert.Contains("[ ok ] wslbin runs in: Ubuntu-24.04\n", m.Out, StringComparison.Ordinal);
        }
        using (Machine m = Setup(ini: "distro = Nope\n"))
        {
            Assert.Equal(125, Doctor(m));
            Assert.Contains("[FAIL] distro = Nope in wslbin.ini is not an installed distribution", m.Out, StringComparison.Ordinal);
            Assert.Contains("fix: use one of the names above, or remove the line to use the default", m.Out, StringComparison.Ordinal);
        }
    }

    [Fact]
    public void No_default_distribution_is_a_failure()
    {
        using Machine m = Setup(new Wsl { List = "  NAME   STATE   VERSION\r\n  Debian   Stopped   2\r\n" });
        Assert.Equal(125, Doctor(m));
        Assert.Contains("[FAIL] there is no default distribution", m.Out, StringComparison.Ordinal);
        Assert.Contains("fix: wsl --set-default <name>", m.Out, StringComparison.Ordinal);
    }

    [Fact]
    public void A_distribution_under_WSL_1_is_a_warning()
    {
        using Machine m = Setup(new Wsl { List = "* Old   Running   1\r\n" });
        Assert.Equal(0, Doctor(m));
        Assert.Contains("[warn] Old runs under WSL 1; wslbin is made for WSL 2", m.Out, StringComparison.Ordinal);
        Assert.Contains("1 problem(s), 0 warning(s).", m.Out.Replace("0 problem(s), 1 warning(s).", "1 problem(s), 0 warning(s)."), StringComparison.Ordinal);
    }

    [Fact]
    public void Bash_that_does_not_start_is_a_failure_with_what_it_said()
    {
        using Machine m = Setup(new Wsl { Bash = "", BashExit = 1 });
        Assert.Equal(125, Doctor(m));
        Assert.Contains("[FAIL] cannot run bash in WSL (exit code 1)", m.Out, StringComparison.Ordinal);
    }

    [Fact]
    public void Drives_mounted_elsewhere_than_mnt_are_a_failure_with_the_fix()
    {
        using Machine m = Setup(new Wsl { Mount = "/c/" });
        Assert.Equal(125, Doctor(m));
        Assert.Contains("[FAIL] WSL mounts drive C: at /c/, but wslbin writes Windows paths as /mnt/c/", m.Out, StringComparison.Ordinal);
        Assert.Contains("fix: set root = /mnt/ under [automount] in /etc/wsl.conf, then run: wsl --shutdown", m.Out, StringComparison.Ordinal);
    }

    [Fact]
    public void Nothing_is_said_of_the_mount_when_wslpath_gives_no_answer()
    {
        using Machine m = Setup(new Wsl { Mount = null });
        Assert.Equal(0, Doctor(m));
        Assert.DoesNotContain("mount", m.Out, StringComparison.Ordinal);
    }

    [Fact]
    public void Missing_bash_completion_and_unlisted_tool_folders_are_warnings_with_fixes()
    {
        using Machine m = Setup(new Wsl { BashCompletion = false, MissingDirectories = "~/.local/bin\n~/go/bin\n" });
        Assert.Equal(0, Doctor(m));
        Assert.Contains("[warn] bash-completion is not installed in WSL", m.Out, StringComparison.Ordinal);
        Assert.Contains("fix: wsl -u root apt-get install bash-completion", m.Out, StringComparison.Ordinal);
        Assert.Contains("[warn] directories with user-installed tools exist in WSL but are not in PATH for wslbin: ~/.local/bin, ~/go/bin", m.Out, StringComparison.Ordinal);
        Assert.Contains("fix: add to wslbin.ini:  path = ~/.local/bin, ~/go/bin", m.Out, StringComparison.Ordinal);
        Assert.Contains("0 problem(s), 2 warning(s).", m.Out, StringComparison.Ordinal);
    }

    [Fact]
    public void A_bad_line_in_the_config_is_a_warning()
    {
        using Machine m = Setup(ini: "bogus = 1\n");
        Assert.Equal(0, Doctor(m));
        Assert.Contains("[ ok ] config: " + m.IniPath, m.Out, StringComparison.Ordinal);
        Assert.Contains("[warn] wslbin.ini line 1: unknown key 'bogus'", m.Out, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("ProgramFiles", "system (needs administrator rights to change wrappers)")]
    [InlineData("ProgramFiles(x86)", "system (needs administrator rights to change wrappers)")]
    public void A_folder_under_Program_Files_is_a_system_installation(string variable, string type)
    {
        using Machine m = Setup();
        m.Fake.Env[variable] = Path.GetDirectoryName(m.Dir)!;
        Assert.Equal(0, Doctor(m));
        Assert.Contains($"[ ok ] install type: {type}", m.Out, StringComparison.Ordinal);
    }

    [Fact]
    public void A_folder_under_the_programs_of_the_user_is_a_user_installation()
    {
        using Machine m = Setup();
        string programs = Path.Combine(m.Dir, "Programs");
        Directory.CreateDirectory(Path.Combine(programs, "wslbin"));
        m.Fake.Env["LOCALAPPDATA"] = m.Dir;
        string exe = Path.Combine(programs, "wslbin", "wslbin.exe");
        File.WriteAllText(exe, FakeHost.ExeText);
        m.Fake.Env["PATH"] = Path.GetDirectoryName(exe)!;
        Assert.Equal(0, Program.Execute(exe, ["--doctor"]));
        Assert.Contains("[ ok ] install type: user", m.Out, StringComparison.Ordinal);
    }

    [Fact]
    public void A_variable_that_holds_no_path_does_not_stop_it()
    {
        using Machine m = Setup();
        m.Fake.Env["ProgramFiles"] = "\0";
        Assert.Equal(0, Doctor(m));
        Assert.Contains("install type: portable", m.Out, StringComparison.Ordinal);
    }

    [Fact]
    public void A_folder_that_is_not_in_PATH_is_a_warning_and_the_registry_says_which_kind_of_PATH_has_it()
    {
        using Machine m = Setup();
        m.Fake.Env["PATH"] = @"C:\elsewhere";
        Assert.Equal(0, Doctor(m));
        Assert.Contains($"[warn] the folder is not in PATH, so wrappers are not found by name: {m.Dir}", m.Out, StringComparison.Ordinal);
        Assert.Contains("fix: add it to PATH (the installer does that)", m.Out, StringComparison.Ordinal);

        m.Fake.UserPath = $@"C:\x;{m.Dir}";
        Assert.Equal(0, Doctor(m));
        Assert.Contains("[warn] the folder is in the user PATH, but not in PATH of this terminal", m.Out, StringComparison.Ordinal);
        Assert.Contains("fix: open a new terminal", m.Out, StringComparison.Ordinal);

        m.Fake.UserPath = "";
        m.Fake.MachinePath = m.Dir;
        Assert.Equal(0, Doctor(m));
        Assert.Contains("[warn] the folder is in the system PATH, but not in PATH of this terminal", m.Out, StringComparison.Ordinal);
    }

    [Fact]
    public void Another_wslbin_in_PATH_is_named_whether_it_comes_first_or_later()
    {
        using Machine m = Setup();
        string other = Path.Combine(m.Dir, "other");
        Directory.CreateDirectory(other);
        File.WriteAllText(Path.Combine(other, "wslbin.exe"), "x");
        m.Fake.Env["PATH"] = $"{other};{m.Dir}";
        Doctor(m);
        Assert.Contains($"[warn] another wslbin comes first in PATH: {Path.Combine(other, "wslbin.EXE")}", m.Out, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("fix: uninstall the copy that is not wanted", m.Out, StringComparison.Ordinal);

        m.Fake.Env["PATH"] = $"{m.Dir};{other}";
        Doctor(m);
        Assert.Contains($"[warn] another wslbin is in PATH: {Path.Combine(other, "wslbin.EXE")} (this one comes first)", m.Out, StringComparison.OrdinalIgnoreCase);
    }

    // ---- the wrappers ----

    [Fact]
    public void Wrappers_that_are_fine_are_counted_and_a_utility_with_a_Windows_version_is_advice_only()
    {
        using Machine m = Setup(new Wsl { Which = "ok jq\nok ripgrep\n" });
        m.MakeExe("jq");
        Dictionary<string, string> native = NativeVersions.Load();
        string withNative = native.Keys.First(k => !k.Equals("jq", StringComparison.OrdinalIgnoreCase) && Wrappers.IsValidName(k));
        m.MakeExe(withNative);
        m.Fake.OnWsl = Wrap(m.Fake.OnWsl, $"ok jq\nok {withNative}\n");
        Assert.Equal(0, Doctor(m));
        Assert.Contains($"[ ok ] 2 wrapper(s), all fine: jq, {withNative}", m.Out.Replace($"{withNative}, jq", $"jq, {withNative}"), StringComparison.Ordinal);
        Assert.Contains($"[info] {withNative} has a Windows version of its own", m.Out, StringComparison.Ordinal);
        Assert.Contains($"winget install --exact --id {native[withNative]}", m.Out, StringComparison.Ordinal);
        Assert.EndsWith("Everything looks fine.\n", m.Out, StringComparison.Ordinal);
    }

    static Func<WslCall, Launcher.Captured?> Wrap(Func<WslCall, Launcher.Captured?> inner, string which) =>
        call => call.Script?.Contains("command -v \"$n\"", StringComparison.Ordinal) == true ? FakeHost.Reply(0, which) : inner(call);

    [Fact]
    public void A_wrapper_with_problems_is_a_warning_with_the_words_of_list()
    {
        using Machine m = Setup(new Wsl { Which = "missing gone\n" });
        m.MakeExe("gone");
        Assert.Equal(0, Doctor(m));
        Assert.Contains("[warn] gone: not found in WSL", m.Out, StringComparison.Ordinal);
        Assert.Contains("0 problem(s), 1 warning(s).", m.Out, StringComparison.Ordinal);
    }

    [Fact]
    public void Wrappers_are_not_called_all_fine_when_WSL_could_not_be_asked()
    {
        using Machine m = Setup(new Wsl { List = Usage, ListExit = 1 });
        m.MakeExe("grep");
        Doctor(m);
        Assert.Contains("1 wrapper(s), not checked in WSL: grep", m.Out, StringComparison.Ordinal);
        Assert.DoesNotContain("all fine", m.Out, StringComparison.Ordinal);
    }

    [Fact]
    public void A_wrapper_whose_utility_only_a_login_shell_finds_is_a_warning_with_the_same_words_as_list()
    {
        using Machine m = Setup(new Wsl { Which = "missing k9s\n" });
        m.MakeExe("k9s");
        Func<WslCall, Launcher.Captured?> before = m.Fake.OnWsl;
        m.Fake.OnWsl = call => call.Script?.Contains("bash -lc", StringComparison.Ordinal) == true
            ? FakeHost.Reply(0, "@@wslbin@@:HOME=/home/u\n@@wslbin@@k9s=/home/u/.local/bin/k9s\n")
            : before(call);
        Doctor(m);
        Assert.Contains("[warn] k9s: not found in WSL without your profile, but a login shell finds it at ~/.local/bin/k9s (fix: path = ~/.local/bin in wslbin.ini)", m.Out, StringComparison.Ordinal);
    }

    [Fact]
    public void A_wsl_that_fails_when_the_wrappers_are_asked_is_a_warning()
    {
        using Machine m = Setup();
        m.MakeExe("grep");
        Func<WslCall, Launcher.Captured?> before = m.Fake.OnWsl;
        m.Fake.OnWsl = call => call.Script?.Contains("command -v \"$n\"", StringComparison.Ordinal) == true
            ? FakeHost.ReplyUtf16(-1, "There is no distribution with the supplied name.\r\n")
            : before(call);
        Doctor(m);
        Assert.Contains("[warn] could not ask WSL which utilities exist: cannot run bash in WSL: There is no distribution", m.Out, StringComparison.Ordinal);
    }
}
