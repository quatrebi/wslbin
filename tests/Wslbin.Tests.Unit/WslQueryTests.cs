using System.Text;

namespace Wslbin.Tests;

// What wslbin asks WSL, and what it makes of the answers, with a wsl.exe that answers what the test says.
public class WslQueryTests
{
    const string Usage =
        "Usage: wsl.exe [Argument]\r\n    --install [Distro]\r\n    --list, -l\r\n    --status\r\n";

    static Launcher.Captured? Never(WslCall call) => throw new InvalidOperationException($"wsl.exe must not be asked: {call.Psi.Arguments}");

    [Fact]
    public void Which_asks_one_call_for_all_the_names_and_reads_ok_and_missing()
    {
        using var m = new Machine();
        m.Fake.OnWsl = _ => FakeHost.Reply(0, "ok jq\nmissing k9s\nok my tool\n");
        Dictionary<string, bool> present = WslQuery.Which(m.Config(), ["jq", "k9s", "my tool"]);
        Assert.True(present["jq"]);
        Assert.False(present["k9s"]);
        Assert.True(present["MY TOOL"]);
        WslCall call = Assert.Single(m.Fake.Calls);
        Assert.StartsWith("for n in jq k9s 'my tool'; do if command -v", call.Script, StringComparison.Ordinal);
    }

    [Fact]
    public void Which_puts_the_path_of_the_config_in_front_and_asks_nothing_for_no_names()
    {
        using var m = new Machine();
        m.Fake.OnWsl = _ => FakeHost.Reply(0, "ok jq\n");
        WslQuery.Which(m.Config("path = ~/.local/bin"), ["jq"]);
        Assert.StartsWith("export PATH=\"$HOME/.local/bin:$PATH\"; for n in jq;", m.Fake.Calls[0].Script, StringComparison.Ordinal);
        m.Fake.OnWsl = Never;
        Assert.Empty(WslQuery.Which(m.Config(), []));
    }

    [Fact]
    public void Which_says_why_when_bash_cannot_be_run()
    {
        using var m = new Machine();
        m.Fake.OnWsl = _ => FakeHost.ReplyUtf16(-1, "There is no distribution with the supplied name.\r\n");
        var ex = Assert.Throws<WslbinException>(() => WslQuery.Which(m.Config(), ["jq"]));
        Assert.Equal("cannot run bash in WSL: There is no distribution with the supplied name.", ex.Message);
    }

    [Fact]
    public void Which_names_the_missing_wsl_in_one_line()
    {
        using var m = new Machine();
        m.Fake.OnWsl = _ => FakeHost.ReplyUtf16(1, Usage);
        var ex = Assert.Throws<WslbinException>(() => WslQuery.Which(m.Config(), ["jq"]));
        Assert.Equal("cannot run bash in WSL: WSL is not installed (wsl.exe answers with its usage text) (fix: run 'wsl --install' as administrator)", ex.Message);
    }

    [Fact]
    public void The_usage_text_is_found_on_standard_output_when_standard_error_holds_only_a_line_break()
    {
        using var m = new Machine();
        m.Fake.OnWsl = _ => new Launcher.Captured(1, Encoding.Unicode.GetBytes(Usage), [0, 13, 10]);
        Assert.Contains("WSL is not installed", Assert.Throws<WslbinException>(() => WslQuery.Which(m.Config(), ["jq"])).Message, StringComparison.Ordinal);
    }

    [Fact]
    public void A_long_message_is_kept_to_the_error_code_at_its_end()
    {
        using var m = new Machine();
        string text = string.Concat(Enumerable.Repeat("Windows Subsystem for Linux has no installed distributions. ", 5)) +
                      "Error code: Wsl/Service/CreateInstance/GetDefaultDistro/WSL_E_DEFAULT_DISTRO_NOT_FOUND";
        m.Fake.OnWsl = _ => FakeHost.ReplyUtf16(-1, text + "\r\n");
        Assert.EndsWith("GetDefaultDistro/WSL_E_DEFAULT_DISTRO_NOT_FOUND",
            Assert.Throws<WslbinException>(() => WslQuery.Which(m.Config(), ["jq"])).Message, StringComparison.Ordinal);
    }

    [Fact]
    public void A_message_in_another_language_is_shown_as_it_is()
    {
        using var m = new Machine();
        const string text = "Нет дистрибутива.";
        const string code = "Код ошибки: Wsl/Service/WSL_E_DISTRO_NOT_FOUND";
        m.Fake.OnWsl = _ => FakeHost.ReplyUtf16(-1, $"{text}\r\n{code}\r\n");
        var ex = Assert.Throws<WslbinException>(() => WslQuery.Which(m.Config(), ["jq"]));
        Assert.Equal($"cannot run bash in WSL: {text} {code}", ex.Message);
    }

    [Fact]
    public void A_wsl_that_does_not_answer_is_an_error_with_a_fix()
    {
        using var m = new Machine();
        m.Fake.QueryTimeout = 2000;
        m.Fake.OnWsl = _ => null;
        var ex = Assert.Throws<WslbinException>(() => WslQuery.Which(m.Config(), ["jq"]));
        Assert.Equal("wsl.exe did not answer within 2 seconds", ex.Message);
        Assert.Equal("wsl --shutdown, then try again (WSL may be stuck)", ex.Fix);
        Assert.Equal(2000, m.Fake.Calls[0].TimeoutMs);
    }

    [Fact]
    public void Has_and_the_apt_checks_use_one_call_each()
    {
        using var m = new Machine();
        m.Fake.OnWsl = _ => FakeHost.Reply(0, "ok jq\n");
        Assert.True(WslQuery.Has(m.Config(), "jq"));
        Assert.False(WslQuery.Has(m.Config(), "other"));

        m.Fake.OnWsl = c => FakeHost.Reply(c.Script!.Contains("apt-get", StringComparison.Ordinal) ? 0 : 1);
        Assert.True(WslQuery.HasAptGet(m.Config()));
        m.Fake.OnWsl = _ => FakeHost.Reply(1);
        Assert.False(WslQuery.HasAptGet(m.Config()));
    }

    [Fact]
    public void A_package_comes_from_command_not_found_or_from_a_package_of_the_same_name()
    {
        using var m = new Machine();
        m.Fake.OnWsl = _ => FakeHost.Reply(0, "", "Command 'k9s' not found, but can be installed with:\nsudo apt install k9s-bin\n");
        Assert.Equal("k9s-bin", WslQuery.SuggestPackage(m.Config(), "k9s"));

        m.Fake.OnWsl = c => c.Script!.Contains("command-not-found", StringComparison.Ordinal)
            ? FakeHost.Reply(127)
            : FakeHost.Reply(0, "  Candidate: 1.2-3\n");
        Assert.Equal("jq", WslQuery.SuggestPackage(m.Config(), "jq"));

        m.Fake.OnWsl = c => c.Script!.Contains("command-not-found", StringComparison.Ordinal)
            ? FakeHost.Reply(127)
            : FakeHost.Reply(0, "  Candidate: (none)\n");
        Assert.Null(WslQuery.SuggestPackage(m.Config(), "jq"));
    }

    [Fact]
    public void A_package_name_that_is_not_one_is_not_suggested()
    {
        using var m = new Machine();
        m.Fake.OnWsl = _ => FakeHost.Reply(0, "", "sudo apt install evil;rm\n");
        Assert.Null(WslQuery.SuggestPackage(m.Config(), "x"));
    }

    // ---- the login shell ----

    static Dictionary<string, LoginShellHit> Login(Machine m, string answer, params string[] names)
    {
        m.Fake.OnWsl = _ => FakeHost.Reply(0, answer);
        return WslQuery.FindInLoginShell(m.Config(), names, names.ToDictionary(n => n, _ => false));
    }

    [Theory]
    [InlineData("Welcome to Ubuntu 24.04\n@@wslbin@@:HOME=/home/u\n * Documentation:  https://help.ubuntu.com\n@@wslbin@@k9s=/home/u/.local/bin/k9s\nbye\n", "/home/u/.local/bin/k9s", "~/.local/bin/k9s", "~/.local/bin")]
    [InlineData("@@wslbin@@:HOME=/home/u\nno line end@@wslbin@@k9s=/tmp/evil/k9s\n@@wslbin@@k9s=/home/u/.local/bin/k9s\n", "/home/u/.local/bin/k9s", "~/.local/bin/k9s", "~/.local/bin")]
    [InlineData("@@wslbin@@:HOME=/home/u\r\n@@wslbin@@k9s=/home/u/.local/bin/k9s\r\n", "/home/u/.local/bin/k9s", "~/.local/bin/k9s", "~/.local/bin")]
    [InlineData("@@wslbin@@k9s=/home/u/.local/bin/k9s\n@@wslbin@@:HOME=/home/u/\n", "/home/u/.local/bin/k9s", "~/.local/bin/k9s", "~/.local/bin")]
    [InlineData("@@wslbin@@:HOME=/home/u\n@@wslbin@@k9s=/home/u/bin/k9s\n@@wslbin@@k9s=/home/u/.local/bin/k9s\n", "/home/u/bin/k9s", "~/bin/k9s", "~/bin")]
    [InlineData("@@wslbin@@:HOME=/home/u\n@@wslbin@@k9s=/home/u/my tools/k9s\n", "/home/u/my tools/k9s", "~/my tools/k9s", "~/my tools")]
    [InlineData("@@wslbin@@:HOME=/home/u\n@@wslbin@@k9s=/home/u/tools /k9s\n", "/home/u/tools /k9s", "~/tools /k9s", "\"~/tools \"")]
    [InlineData("@@wslbin@@:HOME=/home/u\n@@wslbin@@k9s=/opt/k9s/bin/k9s\n", "/opt/k9s/bin/k9s", "/opt/k9s/bin/k9s", "/opt/k9s/bin")]
    [InlineData("@@wslbin@@k9s=/home/u/.local/bin/k9s\n", "/home/u/.local/bin/k9s", "/home/u/.local/bin/k9s", "/home/u/.local/bin")]
    [InlineData("@@wslbin@@:HOME=/home/u\n@@wslbin@@k9s=/home/u/a,b/k9s\n", "/home/u/a,b/k9s", "~/a,b/k9s", null)]
    [InlineData("@@wslbin@@:HOME=/home/u\n@@wslbin@@k9s=/home/u/a:b/k9s\n", "/home/u/a:b/k9s", "~/a:b/k9s", null)]
    [InlineData("@@wslbin@@:HOME=relative\n@@wslbin@@k9s=/home/u/bin/k9s\n", "/home/u/bin/k9s", "/home/u/bin/k9s", "/home/u/bin")]
    [InlineData("@@wslbin@@:HOME=/\n@@wslbin@@k9s=/k9s\n", "/k9s", "/k9s", "/")]
    public void A_utility_that_only_a_login_shell_finds_is_named_with_its_folder_and_the_line_for_the_config(
        string answer, string fullPath, string shown, string? entry)
    {
        using var m = new Machine();
        LoginShellHit hit = Assert.Single(Login(m, answer, "k9s")).Value;
        Assert.Equal(new LoginShellHit(fullPath, shown, entry), hit);
    }

    [Theory]
    [InlineData("@@wslbin@@:HOME=/home/u\n")]
    [InlineData("@@wslbin@@:HOME=/home/u\n@@wslbin@@k9s=/mnt/c/tools/k9s\n")]
    [InlineData("@@wslbin@@:HOME=/home/u\n@@wslbin@@k9s=k9s\n@@wslbin@@k9s=./k9s\n")]
    [InlineData("@@wslbin@@:HOME=/home/u\n@@wslbin@@k9s=/home/u/bin/k9s-old\n@@wslbin@@jq=/home/u/bin/jq\n@@wslbin@@K9S=/home/u/bin/K9S\n")]
    [InlineData("k9s=/home/u/.local/bin/k9s\n/home/u/.local/bin/k9s\n")]
    [InlineData("@@wslbin@@k9s=/home/u/bin/\u0001/k9s\n")]
    [InlineData("@@wslbin@@k9s\n@@wslbin@@=/x/k9s\n")]
    public void Nothing_is_taken_from_an_answer_that_is_not_a_program_of_that_name(string answer)
    {
        using var m = new Machine();
        Assert.Empty(Login(m, answer, "k9s"));
    }

    [Fact]
    public void The_login_shell_is_asked_once_for_the_missing_names_only_and_never_for_the_others()
    {
        using var m = new Machine();
        m.Fake.OnWsl = _ => FakeHost.Reply(0, "@@wslbin@@:HOME=/home/u\n@@wslbin@@k9s=/home/u/bin/k9s\n");
        Dictionary<string, LoginShellHit> found = WslQuery.FindInLoginShell(m.Config(), ["jq", "k9s", "k9s", "nope"],
            new() { ["jq"] = true, ["k9s"] = false });
        Assert.Equal(["k9s"], found.Keys);
        WslCall call = Assert.Single(m.Fake.Calls);
        Assert.Contains("bash -lc 'for n; do if p=$(builtin type -P -- \"$n\")", call.Script, StringComparison.Ordinal);
        Assert.EndsWith("' _ k9s </dev/null 2>/dev/null", call.Script, StringComparison.Ordinal);

        m.Fake.OnWsl = Never;
        Assert.Empty(WslQuery.FindInLoginShell(m.Config(), ["jq"], new() { ["jq"] = true }));
    }

    [Theory]
    [InlineData(3000, 3000)]
    [InlineData(60000, 10000)]
    public void The_login_shell_is_waited_for_no_longer_than_ten_seconds(int timeout, int waited)
    {
        using var m = new Machine();
        m.Fake.QueryTimeout = timeout;
        m.Fake.OnWsl = _ => null;
        Assert.Empty(WslQuery.FindInLoginShell(m.Config(), ["k9s"], new() { ["k9s"] = false }));
        Assert.Equal(waited, m.Fake.Calls[0].TimeoutMs);
    }
}
