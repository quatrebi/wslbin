using System.Security.AccessControl;
using System.Security.Principal;

namespace Wslbin.Tests;

// --link, --unlink, --list and the elevated halves, in a folder of the test with files that the fake host takes for
// copies of wslbin.exe.
public class WrapperCommandsTests
{
    // PATH of the test: its own folder only, so that no program of this machine is a name conflict
    static Machine Setup(string which = "ok", string? extraPath = null)
    {
        var m = new Machine();
        m.MakeExe("wslbin", "-v1");
        m.Fake.Env["PATH"] = extraPath == null ? m.Dir : $"{m.Dir};{extraPath}";
        // every name in the question is answered the same way
        m.Fake.OnWsl = call =>
        {
            if (call.Script != null && call.Script.Contains("command -v \"$n\"", StringComparison.Ordinal))
            {
                int start = call.Script.IndexOf("for n in ", StringComparison.Ordinal) + "for n in ".Length;
                string names = call.Script[start..call.Script.IndexOf(';', start)];
                return FakeHost.Reply(0, string.Join('\n', names.Split(' ').Select(n => $"{which} {n}")) + "\n");
            }
            return FakeHost.Reply(0);
        };
        return m;
    }

    static string Contents(Machine m, string name) => File.ReadAllText(m.Exe(name));

    [Theory]
    [InlineData("..\\evil")]
    [InlineData("a b")]
    [InlineData("x.exe")]
    [InlineData("wslbin")]
    [InlineData("con")]
    [InlineData("a/b")]
    [InlineData("tool.")]
    public void A_name_that_cannot_be_a_wrapper_is_refused_and_nothing_is_written(string name)
    {
        using Machine m = Setup();
        Assert.Equal(125, m.Run("wslbin", "--link", "ok", name));
        Assert.Contains($"'{name}' cannot be a wrapper name", m.Err, StringComparison.Ordinal);
        Assert.False(File.Exists(m.Exe("ok")));
        Assert.Empty(m.Fake.Calls);
    }

    [Fact]
    public void An_unknown_option_is_refused()
    {
        using Machine m = Setup();
        Assert.Equal(125, m.Run("wslbin", "--link", "--bogus"));
        Assert.Contains("unknown option --bogus for --link", m.Err, StringComparison.Ordinal);
    }

    [Fact]
    public void Link_makes_exact_copies_says_so_and_is_up_to_date_the_next_time()
    {
        using Machine m = Setup();
        Assert.Equal(0, m.Run("wslbin", "--link", "jq", "yq", "JQ"));
        Assert.Equal("created jq.exe\ncreated yq.exe\n", m.Out);
        Assert.Equal(Contents(m, "wslbin"), Contents(m, "jq"));
        Assert.Equal("", m.Err);

        m.Fake.ClearOutput();
        Assert.Equal(0, m.Run("wslbin", "--link", "jq"));
        Assert.Equal("up to date jq.exe\n", m.Out);

        File.WriteAllText(m.Exe("wslbin"), FakeHost.ExeText + "-v2");
        m.Fake.ClearOutput();
        Assert.Equal(0, m.Run("wslbin", "--link", "jq"));
        Assert.Equal("updated jq.exe\n", m.Out);
        Assert.Equal(Contents(m, "wslbin"), Contents(m, "jq"));
    }

    [Fact]
    public void Link_warns_when_the_folder_is_not_in_PATH_of_the_terminal()
    {
        using Machine m = Setup();
        m.Fake.Env["PATH"] = @"C:\elsewhere";
        Assert.Equal(0, m.Run("wslbin", "--link", "jq"));
        Assert.Contains("is not in PATH of this terminal", m.Err, StringComparison.Ordinal);
        m.Fake.Env["PATH"] = m.Dir.ToUpperInvariant() + "\\";
        m.Fake.ClearOutput();
        Assert.Equal(0, m.Run("wslbin", "--link", "jq"));
        Assert.Equal("", m.Err);
    }

    [Fact]
    public void Link_without_names_refreshes_only_the_wrappers_that_are_out_of_date_and_asks_nothing_of_WSL()
    {
        using Machine m = Setup();
        m.Run("wslbin", "--link", "a", "b");
        File.WriteAllText(m.Exe("wslbin"), FakeHost.ExeText + "-v2");
        File.WriteAllText(m.Exe("b"), FakeHost.ExeText + "-v2");
        m.Fake.ClearOutput();
        m.Fake.Calls.Clear();
        Assert.Equal(0, m.Run("wslbin", "--link"));
        Assert.Equal("updated a.exe\nup to date b.exe\n", m.Out);
        Assert.Empty(m.Fake.Calls);
    }

    [Fact]
    public void Link_without_names_and_without_wrappers_has_nothing_to_do()
    {
        using Machine m = Setup();
        Assert.Equal(0, m.Run("wslbin", "--link"));
        Assert.Contains("no wrappers in", m.Out, StringComparison.Ordinal);
    }

    [Fact]
    public void A_file_that_is_not_a_wrapper_is_never_overwritten()
    {
        using Machine m = Setup();
        File.WriteAllText(m.Exe("jq"), "somebody else");
        Assert.Equal(125, m.Run("wslbin", "--link", "jq"));
        Assert.Contains("jq: ", m.Err, StringComparison.Ordinal);
        Assert.Contains("exists and is not a wslbin wrapper", m.Err, StringComparison.Ordinal);
        Assert.Equal("somebody else", Contents(m, "jq"));
    }

    [Theory]
    [InlineData("echo")]
    [InlineData("ECHO")]
    [InlineData("dir")]
    public void A_name_that_cmd_has_built_in_is_refused(string name)
    {
        using Machine m = Setup();
        Assert.Equal(125, m.Run("wslbin", "--link", name));
        Assert.Contains($"{name}: cmd.exe has a built-in command with that name", m.Err, StringComparison.Ordinal);
        Assert.False(File.Exists(m.Exe(name)));
    }

    [Fact]
    public void A_name_that_another_folder_in_PATH_has_is_refused_naming_that_folder()
    {
        string other = Path.Combine(Path.GetTempPath(), "wslbin-other-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(other);
        try
        {
            File.WriteAllText(Path.Combine(other, "find.exe"), "x");
            using Machine m = Setup(extraPath: other);
            Assert.Equal(125, m.Run("wslbin", "--link", "find"));
            Assert.Contains("Windows already has", m.Err, StringComparison.Ordinal);
            Assert.Contains(other, m.Err, StringComparison.OrdinalIgnoreCase);
            Assert.False(File.Exists(m.Exe("find")));

            // a wrapper that is there already is refreshed all the same, with a warning
            m.MakeExe("find", "-old");
            m.Fake.ClearOutput();
            Assert.Equal(0, m.Run("wslbin", "--link", "find"));
            Assert.Contains("the wrapper is brought up to date all the same", m.Err, StringComparison.Ordinal);
            Assert.Equal(Contents(m, "wslbin"), Contents(m, "find"));
        }
        finally
        {
            Directory.Delete(other, true);
        }
    }

    [Fact]
    public void A_dry_run_changes_nothing_and_says_what_it_would_do()
    {
        using Machine m = Setup();
        m.MakeExe("old", "-v0");
        Assert.Equal(0, m.Run("wslbin", "--link", "--dry-run", "new", "old"));
        Assert.Contains("would create " + m.Exe("new"), m.Out, StringComparison.Ordinal);
        Assert.Contains("would update " + m.Exe("old"), m.Out, StringComparison.Ordinal);
        Assert.False(File.Exists(m.Exe("new")));
        Assert.EndsWith("-v0", Contents(m, "old"), StringComparison.Ordinal);
    }

    // ---- a utility that WSL lacks ----

    static Machine Missing(string name, bool apt, string? package)
    {
        Machine m = Setup();
        m.Fake.OnWsl = call =>
        {
            string script = call.Script ?? "";
            if (script.Contains("command -v \"$n\"", StringComparison.Ordinal)) return FakeHost.Reply(0, $"missing {name}\n");
            if (script.Contains("bash -lc", StringComparison.Ordinal)) return FakeHost.Reply(0, "@@wslbin@@:HOME=/home/u\n");
            if (script.Contains("command -v apt-get", StringComparison.Ordinal)) return FakeHost.Reply(apt ? 0 : 1);
            if (script.Contains("command-not-found", StringComparison.Ordinal))
                return FakeHost.Reply(0, "", package == null ? "" : $"sudo apt install {package}\n");
            return FakeHost.Reply(1);
        };
        return m;
    }

    [Fact]
    public void Without_apt_the_reason_is_that_the_package_manager_is_its_own()
    {
        using Machine m = Missing("k9s", apt: false, package: null);
        Assert.Equal(125, m.Run("wslbin", "--link", "k9s"));
        Assert.Equal("wslbin: k9s: not found in WSL, and this distribution has no apt: install it with its own package manager\n", m.Err);
    }

    [Fact]
    public void Without_a_package_the_reason_is_that_apt_knows_none()
    {
        using Machine m = Missing("k9s", apt: true, package: null);
        m.Fake.OnWsl = Wrap(m.Fake.OnWsl, c => c.Script!.Contains("apt-cache", StringComparison.Ordinal) ? FakeHost.Reply(0) : null);
        Assert.Equal(125, m.Run("wslbin", "--link", "k9s"));
        Assert.Equal("wslbin: k9s: not found in WSL, and apt knows no package that provides it (try: wsl -u root apt-get update)\n", m.Err);
    }

    static Func<WslCall, Launcher.Captured?> Wrap(Func<WslCall, Launcher.Captured?> inner, Func<WslCall, Launcher.Captured?> first) =>
        call => first(call) ?? inner(call);

    [Fact]
    public void A_dry_run_shows_the_apt_command()
    {
        using Machine m = Missing("k9s", apt: true, package: "k9s");
        Assert.Equal(0, m.Run("wslbin", "--link", "--dry-run", "k9s"));
        Assert.Contains("would run: wsl.exe -u root --exec apt-get install -y k9s", m.Out, StringComparison.Ordinal);
        Assert.Contains("would create", m.Out, StringComparison.Ordinal);
        Assert.Empty(m.Fake.ConsoleRuns);
    }

    [Fact]
    public void Without_yes_and_without_a_person_apt_is_not_run_and_the_command_is_shown()
    {
        using Machine m = Missing("k9s", apt: true, package: "k9s");
        Assert.Equal(125, m.Run("wslbin", "--link", "k9s"));
        Assert.Contains("not found in WSL; install it with: wsl.exe -u root --exec apt-get install -y k9s   (or repeat with --yes)", m.Err, StringComparison.Ordinal);
        Assert.Empty(m.Fake.ConsoleRuns);
        Assert.Empty(m.Fake.Questions);
    }

    [Theory]
    [InlineData("y", true)]
    [InlineData(" YES ", true)]
    [InlineData("n", false)]
    [InlineData("", false)]
    [InlineData(null, false)]
    public void A_person_is_asked_and_the_answer_decides(string? answer, bool installs)
    {
        using Machine m = Missing("k9s", apt: true, package: "k9s");
        m.Fake.Interactive = true;
        m.Fake.Answer(answer);
        int code = m.Run("wslbin", "--link", "k9s");
        if (!installs) Assert.Equal(125, code);
        Assert.Equal("'k9s' is not installed in WSL. Install the apt package 'k9s' now?", Assert.Single(m.Fake.Questions));
        Assert.Equal(installs ? 1 : 0, m.Fake.ConsoleRuns.Count);
    }

    [Fact]
    public void With_yes_apt_runs_in_the_console_and_the_wrapper_is_made_when_the_utility_is_there_afterwards()
    {
        using Machine m = Missing("k9s", apt: true, package: "k9s");
        int asked = 0;
        Func<WslCall, Launcher.Captured?> before = m.Fake.OnWsl;
        m.Fake.OnWsl = call =>
        {
            if (call.Script!.Contains("command -v \"$n\"", StringComparison.Ordinal) && ++asked > 1) return FakeHost.Reply(0, "ok k9s\n");
            return before(call);
        };
        Assert.Equal(0, m.Run("wslbin", "--link", "--yes", "k9s"));
        Assert.Contains("running: wsl.exe -u root --exec apt-get install -y k9s", m.Out, StringComparison.Ordinal);
        Assert.Equal("-u root --exec apt-get install -y k9s", Assert.Single(m.Fake.ConsoleRuns).Arguments);
        Assert.True(File.Exists(m.Exe("k9s")));
    }

    [Fact]
    public void A_failed_install_and_a_package_without_the_utility_are_said_so()
    {
        using Machine m = Missing("k9s", apt: true, package: "k9s-pkg");
        m.Fake.OnRunInConsole = _ => 100;
        Assert.Equal(125, m.Run("wslbin", "--link", "-y", "k9s"));
        Assert.Contains("installing 'k9s-pkg' failed", m.Err, StringComparison.Ordinal);

        m.Fake.ClearOutput();
        m.Fake.OnRunInConsole = _ => 0;
        Assert.Equal(125, m.Run("wslbin", "--link", "-y", "k9s"));
        Assert.Contains("'k9s-pkg' is installed, but it does not provide 'k9s'", m.Err, StringComparison.Ordinal);
    }

    [Fact]
    public void A_utility_that_only_a_login_shell_finds_gets_no_apt_and_the_line_for_the_config()
    {
        using Machine m = Setup();
        m.Fake.OnWsl = call => call.Script!.Contains("bash -lc", StringComparison.Ordinal)
            ? FakeHost.Reply(0, "@@wslbin@@:HOME=/home/u\n@@wslbin@@k9s=/home/u/.local/bin/k9s\n")
            : FakeHost.Reply(0, "missing k9s\n");
        Assert.Equal(125, m.Run("wslbin", "--link", "--dry-run", "k9s"));
        Assert.Equal(
            "wslbin: k9s: not found in WSL without your profile (wslbin does not read it), but a login shell finds it at " +
            $"/home/u/.local/bin/k9s (fix: add the line  path = ~/.local/bin  to {m.IniPath}, then repeat: wslbin --link k9s)\n", m.Err);
        Assert.Equal(2, m.Fake.Calls.Count);
        Assert.False(File.Exists(m.IniPath));

        // a folder that wslbin.ini cannot name
        m.Fake.OnWsl = call => call.Script!.Contains("bash -lc", StringComparison.Ordinal)
            ? FakeHost.Reply(0, "@@wslbin@@:HOME=/home/u\n@@wslbin@@k9s=/home/u/a,b/k9s\n")
            : FakeHost.Reply(0, "missing k9s\n");
        m.Fake.ClearOutput();
        Assert.Equal(125, m.Run("wslbin", "--link", "--dry-run", "k9s"));
        Assert.Contains("in a folder that wslbin.ini cannot name, as it has ':' or ','", m.Err, StringComparison.Ordinal);
        Assert.Contains($"(fix: link the program into another folder, add that folder to {m.IniPath} with a path line, then repeat: wslbin --link k9s)", m.Err, StringComparison.Ordinal);
    }

    [Fact]
    public void Link_says_one_line_when_WSL_is_not_installed()
    {
        using Machine m = Setup();
        m.Fake.OnWsl = _ => FakeHost.ReplyUtf16(1, "Usage\r\n --install\r\n --list\r\n --status\r\n");
        Assert.Equal(125, m.Run("wslbin", "--link", "jq"));
        Assert.Equal("wslbin: cannot run bash in WSL: WSL is not installed (wsl.exe answers with its usage text) (fix: run 'wsl --install' as administrator)\n", m.Err);
    }

    // ---- when the file cannot be changed ----

    [Fact]
    public void A_read_only_wrapper_is_a_failure_of_that_file_and_not_a_question_for_administrator_rights()
    {
        using Machine m = Setup();
        m.Run("wslbin", "--link", "jq", "yq");
        File.WriteAllText(m.Exe("wslbin"), FakeHost.ExeText + "-v2");
        File.SetAttributes(m.Exe("jq"), FileAttributes.ReadOnly);
        try
        {
            m.Fake.ClearOutput();
            Assert.Equal(125, m.Run("wslbin", "--link"));
            Assert.Contains("jq: ", m.Err, StringComparison.Ordinal);
            Assert.Empty(m.Fake.ElevatedCalls);
            Assert.Contains("updated yq.exe", m.Out, StringComparison.Ordinal);
        }
        finally
        {
            File.SetAttributes(m.Exe("jq"), FileAttributes.Normal);
        }
    }

    // A folder that this user may read but not write, as C:\Program Files is.
    sealed class LockedFolder : IDisposable
    {
        readonly DirectoryInfo dir;
        readonly FileSystemAccessRule rule;

        public LockedFolder(string path)
        {
            Path = path;
            dir = Directory.CreateDirectory(path);
            SecurityIdentifier me = WindowsIdentity.GetCurrent().User!;
            rule = new FileSystemAccessRule(me, FileSystemRights.CreateFiles | FileSystemRights.Delete | FileSystemRights.DeleteSubdirectoriesAndFiles | FileSystemRights.AppendData,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Deny);
        }

        public string Path { get; }

        public void Lock()
        {
            DirectorySecurity security = dir.GetAccessControl();
            security.AddAccessRule(rule);
            dir.SetAccessControl(security);
        }

        public void Unlock()
        {
            DirectorySecurity security = dir.GetAccessControl();
            security.RemoveAccessRule(rule);
            dir.SetAccessControl(security);
        }

        public void Dispose()
        {
            Unlock();
            dir.Delete(true);
        }
    }

    [Fact]
    public void A_folder_that_cannot_be_written_hands_the_names_to_the_copy_with_administrator_rights()
    {
        using Machine m = Setup();
        using var folder = new LockedFolder(Path.Combine(m.Dir, "program files"));
        string exe = Path.Combine(folder.Path, "wslbin.exe");
        File.WriteAllText(exe, FakeHost.ExeText);
        folder.Lock();
        m.Fake.Env["PATH"] = folder.Path;
        // the elevated copy: it is the same program, run here with the rights back
        m.Fake.OnElevated = (path, args) =>
        {
            folder.Unlock();
            return WrapperCommands.InternalLink([.. WindowsCommandLine.Split(args).Skip(1)], path);
        };

        Assert.Equal(0, Program.Execute(exe, ["--link", "-y", "jq"]));
        Assert.Contains("needs administrator rights; asking for them (UAC)", m.Out, StringComparison.Ordinal);
        Assert.Contains("created jq.exe", m.Out, StringComparison.Ordinal);
        Assert.Equal(("--internal-link jq"), Assert.Single(m.Fake.ElevatedCalls).Arguments);
        Assert.True(File.Exists(Path.Combine(folder.Path, "jq.exe")));
    }

    [Fact]
    public void Declined_administrator_rights_are_reported_per_name()
    {
        using Machine m = Setup();
        using var folder = new LockedFolder(Path.Combine(m.Dir, "program files"));
        string exe = Path.Combine(folder.Path, "wslbin.exe");
        File.WriteAllText(exe, FakeHost.ExeText);
        folder.Lock();
        m.Fake.Env["PATH"] = folder.Path;
        m.Fake.ElevatedResult = null;
        Assert.Equal(125, Program.Execute(exe, ["--link", "jq"]));
        Assert.Contains("jq: could not write", m.Err, StringComparison.Ordinal);
        Assert.Contains("(administrator rights were declined)", m.Err, StringComparison.Ordinal);

        m.Fake.ClearOutput();
        m.Fake.ElevatedResult = 125;
        Assert.Equal(125, Program.Execute(exe, ["--link", "jq"]));
        Assert.Contains("(exit code 125)", m.Err, StringComparison.Ordinal);
    }

    [Fact]
    public void A_wrapper_file_with_a_name_the_elevated_copy_would_refuse_is_left_to_the_user()
    {
        using Machine m = Setup();
        using var folder = new LockedFolder(Path.Combine(m.Dir, "program files"));
        string exe = Path.Combine(folder.Path, "wslbin.exe");
        File.WriteAllText(exe, FakeHost.ExeText);
        File.WriteAllText(Path.Combine(folder.Path, "odd name.exe"), FakeHost.ExeText + "-old");
        folder.Lock();
        m.Fake.Env["PATH"] = folder.Path;
        Assert.Equal(125, Program.Execute(exe, ["--link"]));
        Assert.Contains("needs administrator rights, and wslbin hands only valid wrapper names to its copy with those rights", m.Err, StringComparison.Ordinal);
        Assert.Empty(m.Fake.ElevatedCalls);
    }

    [Fact]
    public void Elevation_asks_nothing_when_the_variable_says_not_to_and_names_are_quoted_for_the_command_line()
    {
        using var m = new Machine();
        m.Fake.Env["WSLBIN_NO_ELEVATION"] = "1";
        Assert.Null(Elevation.Run(m.Exe("wslbin"), "--internal-link", ["a"]));
        Assert.Empty(m.Fake.ElevatedCalls);

        m.Fake.Env.Remove("WSLBIN_NO_ELEVATION");
        m.Fake.ElevatedResult = 0;
        Assert.Equal(0, Elevation.Run(m.Exe("wslbin"), "--internal-link", ["a", "b c"]));
        Assert.Equal("--internal-link a \"b c\"", Assert.Single(m.Fake.ElevatedCalls).Arguments);
    }

    // ---- --internal-link and --internal-unlink ----

    [Fact]
    public void The_elevated_link_repeats_every_check()
    {
        using Machine m = Setup();
        File.WriteAllText(m.Exe("other"), "not a wrapper");
        string[] names = ["fine", "..\\evil", "wslbin", "a b", "x.exe", "echo", "other"];
        Assert.Equal(125, WrapperCommands.InternalLink(names, m.Exe("wslbin")));
        Assert.True(File.Exists(m.Exe("fine")));
        Assert.Equal("not a wrapper", Contents(m, "other"));
        Assert.False(File.Exists(m.Exe("echo")));
        Assert.Equal(0, WrapperCommands.InternalLink(["fine"], m.Exe("wslbin")));
    }

    [Fact]
    public void The_elevated_unlink_removes_wrappers_only_and_refuses_bad_names()
    {
        using Machine m = Setup();
        m.Run("wslbin", "--link", "a", "b");
        File.WriteAllText(m.Exe("c"), "not a wrapper");
        Assert.Equal(0, WrapperCommands.InternalUnlink(["a", "c", "nothing"], m.Exe("wslbin")));
        Assert.False(File.Exists(m.Exe("a")));
        Assert.True(File.Exists(m.Exe("c")));
        Assert.True(File.Exists(m.Exe("b")));
        foreach (string bad in new[] { "..\\evil", "wslbin", "a b", "x.exe" })
        {
            Assert.Equal(125, WrapperCommands.InternalUnlink([bad, "b"], m.Exe("wslbin")));
        }
        Assert.False(File.Exists(m.Exe("b")));
    }

    // ---- --unlink ----

    [Fact]
    public void Unlink_removes_the_named_wrappers_and_leaves_the_rest()
    {
        using Machine m = Setup();
        m.Run("wslbin", "--link", "a", "b");
        m.Fake.ClearOutput();
        Assert.Equal(0, m.Run("wslbin", "--unlink", "a", "A", "nothing"));
        Assert.Equal("removed a.exe\nno wrapper nothing.exe\n", m.Out);
        Assert.False(File.Exists(m.Exe("a")));
        Assert.True(File.Exists(m.Exe("b")));
    }

    [Fact]
    public void Unlink_all_removes_the_wrappers_but_not_wslbin_or_other_programs()
    {
        using Machine m = Setup();
        m.Run("wslbin", "--link", "a", "b");
        File.WriteAllText(m.Exe("other"), "not a wrapper");
        Assert.Equal(0, m.Run("wslbin", "--unlink", "--all"));
        Assert.False(File.Exists(m.Exe("a")));
        Assert.False(File.Exists(m.Exe("b")));
        Assert.True(File.Exists(m.Exe("wslbin")));
        Assert.True(File.Exists(m.Exe("other")));
        m.Fake.ClearOutput();
        Assert.Equal(0, m.Run("wslbin", "--unlink", "--all"));
        Assert.Contains("no wrappers in", m.Out, StringComparison.Ordinal);
    }

    [Fact]
    public void Unlink_refuses_a_program_that_is_not_a_wrapper()
    {
        using Machine m = Setup();
        File.WriteAllText(m.Exe("other"), "not a wrapper");
        Assert.Equal(125, m.Run("wslbin", "--unlink", "other"));
        Assert.Contains("other: ", m.Err, StringComparison.Ordinal);
        Assert.Contains("is not a wslbin wrapper; left alone", m.Err, StringComparison.Ordinal);
        Assert.True(File.Exists(m.Exe("other")));
    }

    [Theory]
    [InlineData(new string[0], "--unlink needs the names of utilities, or --all")]
    [InlineData(new[] { "a", "--all" }, "--unlink takes the names of utilities or --all, not both")]
    [InlineData(new[] { "..\\x" }, "'..\\x' is not a wrapper name")]
    [InlineData(new[] { "--bogus" }, "unknown option --bogus for --unlink")]
    public void Unlink_wants_names_or_all_and_checks_every_name_before_it_removes_anything(string[] args, string message)
    {
        using Machine m = Setup();
        m.Run("wslbin", "--link", "a");
        Assert.Equal(125, m.Run("wslbin", ["--unlink", .. args]));
        Assert.Contains(message, m.Err, StringComparison.Ordinal);
        Assert.True(File.Exists(m.Exe("a")));
    }

    [Fact]
    public void A_wrapper_file_that_is_read_only_is_a_failure_and_the_rest_goes_on()
    {
        using Machine m = Setup();
        m.Run("wslbin", "--link", "a", "b");
        File.SetAttributes(m.Exe("a"), FileAttributes.ReadOnly);
        try
        {
            Assert.Equal(125, m.Run("wslbin", "--unlink", "a", "b"));
            Assert.Contains("a: ", m.Err, StringComparison.Ordinal);
            Assert.False(File.Exists(m.Exe("b")));
            Assert.Empty(m.Fake.ElevatedCalls);
        }
        finally
        {
            File.SetAttributes(m.Exe("a"), FileAttributes.Normal);
        }
    }

    // ---- --list ----

    [Fact]
    public void List_names_only_gives_the_sorted_wrappers_and_not_wslbin_or_other_programs()
    {
        using Machine m = Setup();
        m.Run("wslbin", "--link", "zed", "Alpha", "mid");
        File.WriteAllText(m.Exe("other"), "not a wrapper");
        File.WriteAllText(Path.Combine(m.Dir, "notes.exe.txt"), "x");
        m.Fake.ClearOutput();
        m.Fake.Calls.Clear();
        Assert.Equal(0, m.Run("wslbin", "--list", "--names"));
        Assert.Equal("Alpha\nmid\nzed\n", m.Out);
        Assert.Empty(m.Fake.Calls);
    }

    [Fact]
    public void List_shows_what_is_wrong_with_each_wrapper()
    {
        using Machine m = Setup();
        m.Run("wslbin", "--link", "good", "gone", "old", "ls");
        File.WriteAllText(m.Exe("old"), FakeHost.ExeText + "-older");
        m.Fake.OnWsl = _ => FakeHost.Reply(0, "ok good\nmissing gone\nok old\nok ls\n");
        m.Fake.ClearOutput();
        Assert.Equal(0, m.Run("wslbin", "--list"));
        string[] lines = m.Out.Split('\n', StringSplitOptions.RemoveEmptyEntries);
        Assert.Matches(@"^gone\s+not found in WSL$", lines[0]);
        Assert.Matches(@"^good\s+ok$", lines[1]);
        Assert.Matches(@"^ls\s+PowerShell runs its own 'ls' first: use ls\.exe there \(or: wslbin --init pwsh\)$", lines[2]);
        Assert.Matches(@"^old\s+outdated \(run: wslbin --link\)$", lines[3]);
    }

    [Fact]
    public void List_does_not_call_a_wrapper_ok_when_WSL_could_not_be_asked()
    {
        using Machine m = Setup();
        m.Run("wslbin", "--link", "grep");
        m.Fake.OnWsl = _ => FakeHost.ReplyUtf16(-1, "There is no distribution with the supplied name.\r\n");
        m.Fake.ClearOutput();
        Assert.Equal(0, m.Run("wslbin", "--list"));
        Assert.Matches(@"^grep\s+not checked in WSL", m.Out);
        Assert.DoesNotContain(" ok", m.Out, StringComparison.Ordinal);
        Assert.Contains("could not ask WSL which utilities exist", m.Err, StringComparison.Ordinal);
    }

    [Fact]
    public void List_with_no_wrappers_says_how_to_make_one()
    {
        using Machine m = Setup();
        Assert.Equal(0, m.Run("wslbin", "--list"));
        Assert.Contains("no wrappers in", m.Out, StringComparison.Ordinal);
        Assert.Equal(125, m.Run("wslbin", "--list", "x"));
    }

    [Fact]
    public void List_says_where_a_login_shell_finds_what_wsl_without_a_profile_lacks()
    {
        using Machine m = Setup();
        m.Run("wslbin", "--link", "jq", "k9s");
        m.Fake.OnWsl = call => call.Script!.Contains("bash -lc", StringComparison.Ordinal)
            ? FakeHost.Reply(0, "@@wslbin@@:HOME=/home/u\n@@wslbin@@k9s=/home/u/.local/bin/k9s\n")
            : FakeHost.Reply(0, "ok jq\nmissing k9s\n");
        m.Fake.ClearOutput();
        m.Fake.Calls.Clear();
        Assert.Equal(0, m.Run("wslbin", "--list"));
        string[] lines = m.Out.Split('\n', StringSplitOptions.RemoveEmptyEntries);
        Assert.Matches(@"^jq\s+ok$", lines[0]);
        Assert.Matches(@"^k9s\s+not found in WSL without your profile, but a login shell finds it at ~/\.local/bin/k9s \(fix: path = ~/\.local/bin in wslbin\.ini\)$", lines[1]);
        Assert.Equal(2, m.Fake.Calls.Count);
        Assert.EndsWith("' _ k9s </dev/null 2>/dev/null", m.Fake.Calls[1].Script, StringComparison.Ordinal);
    }

    [Fact]
    public void A_file_that_the_fake_host_cannot_read_is_no_wrapper()
    {
        using Machine m = Setup();
        Assert.Empty(Wrappers.Enumerate(m.Dir, m.Exe("wslbin")));
        m.Fake.ProductName = _ => "other";
        m.Run("wslbin", "--link", "a");
        Assert.Empty(Wrappers.Enumerate(m.Dir, m.Exe("wslbin")));
        Assert.Equal(Wrappers.Change.Created, Wrappers.Create(m.Exe("wslbin"), "zz"));
        Assert.Equal("created", Wrappers.Describe(Wrappers.Change.Created));
        Assert.Equal("updated", Wrappers.Describe(Wrappers.Change.Updated));
        Assert.Equal("up to date", Wrappers.Describe(Wrappers.Change.UpToDate));
    }
}
