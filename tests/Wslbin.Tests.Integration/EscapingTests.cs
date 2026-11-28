using System.Text;

namespace Wslbin.Tests;

// The bash command that --wslbin-explain prints, run by a real bash without WSL: Git Bash, which GitHub's Windows
// runners have, so the escaping is checked by bash in CI and not only on a machine with WSL. Every argument must
// reach printf exactly as typed. Without Git Bash the tests are skipped, unless WSLBIN_REQUIRE_TOOLS=1.
public class EscapingTests(ExeFixture fixture)
{
    const string Ru = "файл";

    // Arguments that each must arrive as exactly one argument, as typed.
    static readonly string[] Nasty =
    [
        "plain", "a b", "x;echo pwned", "$(id)", "$HOME", "`uname`", "{print $1, $2}", "it's", "say \"hi\"",
        @"back\slash", @"trail\", @"two\\", "\\\"", "a|b&c", "a>b<c", "#hash", "!bang", "~tilde-mid", "a~b",
        "ф айл", "", " ", "tab\there", "line1\nline2", "%PATH%", "^caret", "(paren)", "{a,b}",
        "[bracket", "br]acket", "--opt=value with spaces",
        "[[:$(id):]]", "[[=`id`=]]", "[[.;.]]", "a[[:x;y:]]b", Ru
    ];

    // Characters that hurt: shell syntax, wildcards, quotes, brackets, non-ASCII. The marks of [:class:], [=e=] and
    // [.s.] are pieces of their own, so that such shapes turn up.
    static readonly string[] Alphabet =
    [
        " ", " ", "a", "b", "x", "1", "[", "]", "[", "*", "?", "!", "^", "-", "\\", "\\", "\"", "'", "$", "(", ")", "{", "}", ";", "|", "&",
        "<", ">", "~", "`", "#", "%", "=", ",", ":", "@", "/", ".", "\t", "\n", "я", "日",
        "[[:", ":]]", "[[=", "=]]", "[[.", ".]]", "$(", "alpha"
    ];

    // Left out, because wslbin changes them by design: a leading ~ (bash expands it), $ or ` in sh mode
    // (substituted), a wildcard in a path with a slash (it matches real files), a Windows drive path (translated)
    // and a relative path made of dots and backslashes (it exists in any folder, so it is translated).
    static List<string> Hostile(Random random, int count, string mode)
    {
        List<string> list = [];
        while (list.Count < count)
        {
            string s = string.Concat(Enumerable.Range(0, random.Next(1, 13)).Select(_ => Alphabet[random.Next(Alphabet.Length)]));
            if (s.IndexOfAny(['*', '?', '[']) >= 0 && s.Contains('/', StringComparison.Ordinal)) continue;
            if (System.Text.RegularExpressions.Regex.IsMatch(s, @"[A-Za-z]:[\\/]") ||
                System.Text.RegularExpressions.Regex.IsMatch(s, @"\.\\|\\\.")) continue;
            if (mode != "raw" && s.StartsWith('~')) continue;
            if (mode == "sh" && (s.Contains('$', StringComparison.Ordinal) || s.Contains('`', StringComparison.Ordinal))) continue;
            list.Add(s);
        }
        return list;
    }

    // The arguments that printf got, one per NUL.
    async Task<List<string>> Delivered(string[] flags, IReadOnlyList<string> arguments)
    {
        string empty = Runner.NewDir(fixture);
        string exe = Runner.Place(fixture, "printf");
        RunResult explain = await Runner.RunAsync(exe, ["--wslbin-explain", .. flags, @"%s\0", .. arguments], empty);
        Assert.True(explain.ExitCode == 0, explain.Err);
        RunResult r = await Tools.RunGitBashAsync(explain.Out, empty);
        Assert.True(r.ExitCode == 0, r.Err);
        List<string> got = [.. Encoding.UTF8.GetString(r.OutBytes).Split('\0')];
        if (got[^1] == "") got.RemoveAt(got.Count - 1);
        return got;
    }

    static void AssertDelivered(IReadOnlyList<string> sent, List<string> got, string label)
    {
        Assert.True(got.Count == sent.Count, $"{label}: sent {sent.Count} arguments, printf got {got.Count}");
        for (int i = 0; i < sent.Count; i++)
        {
            Assert.True(string.Equals(got[i], sent[i], StringComparison.Ordinal),
                $"{label}: sent <{sent[i].Replace("\n", "\\n", StringComparison.Ordinal)}> but printf got <{got[i].Replace("\n", "\\n", StringComparison.Ordinal)}>");
        }
    }

    [Theory]
    [InlineData("smart", "")]
    [InlineData("raw", "--wslbin-raw")]
    public async Task Every_argument_is_delivered_as_typed(string mode, string flag)
    {
        Tools.GitBash();
        AssertDelivered(Nasty, await Delivered(flag.Length == 0 ? [] : [flag], Nasty), mode);
    }

    [Fact]
    public async Task Arguments_without_a_dollar_or_a_backtick_are_delivered_as_typed_in_sh_mode()
    {
        Tools.GitBash();
        string[] plain = [.. Nasty.Where(a => !a.Contains('$', StringComparison.Ordinal) && !a.Contains('`', StringComparison.Ordinal))];
        Assert.True(plain.Length > 20);
        AssertDelivered(plain, await Delivered(["--wslbin-sh"], plain), "sh");
    }

    [Theory]
    [InlineData("smart", "")]
    [InlineData("raw", "--wslbin-raw")]
    [InlineData("sh", "--wslbin-sh")]
    public async Task One_thousand_random_hostile_arguments_are_delivered_as_typed(string mode, string flag)
    {
        Tools.GitBash();
        var random = new Random(20261022);
        for (int round = 0; round < 10; round++)
        {
            List<string> sent = Hostile(random, 100, mode);
            AssertDelivered(sent, await Delivered(flag.Length == 0 ? [] : [flag], sent), $"{mode} round {round}");
        }
    }

    [Fact]
    public async Task A_command_with_a_variable_is_substituted_in_sh_mode_and_not_in_the_default_mode()
    {
        Tools.GitBash();
        string empty = Runner.NewDir(fixture);
        string exe = Runner.Place(fixture, "printf");
        Assert.Equal("[hi]", await Output(exe, empty, ["--wslbin-sh"], "[$(echo hi)]"));
        Assert.Equal("[$(echo hi)]", await Output(exe, empty, [], "[$(echo hi)]"));

        async Task<string> Output(string e, string cwd, string[] flags, string arg)
        {
            RunResult explain = await Runner.RunAsync(e, ["--wslbin-explain", .. flags, "%s", arg], cwd);
            return (await Tools.RunGitBashAsync(explain.Out, cwd)).Out;
        }
    }

    [Fact]
    public async Task A_wildcard_is_expanded_by_bash_in_the_current_folder_and_passed_on_when_nothing_matches()
    {
        Tools.GitBash();
        string folder = Runner.NewDir(fixture);
        foreach (string f in new[] { "a.log", "b.log", "c.txt" }) await File.WriteAllTextAsync(Path.Combine(folder, f), "x", TestContext.Current.CancellationToken);
        string exe = Runner.Place(fixture, "printf");
        RunResult hit = await Runner.RunAsync(exe, ["--wslbin-explain", @"%s\n", "*.log"], folder);
        Assert.Equal("a.log\nb.log\n", (await Tools.RunGitBashAsync(hit.Out, folder)).Out);
        RunResult miss = await Runner.RunAsync(exe, ["--wslbin-explain", @"%s\n", "*.nothing"], folder);
        Assert.Equal("*.nothing\n", (await Tools.RunGitBashAsync(miss.Out, folder)).Out);
        RunResult raw = await Runner.RunAsync(exe, ["--wslbin-explain", "--wslbin-raw", @"%s\n", "*.log"], folder);
        Assert.Equal("*.log\n", (await Tools.RunGitBashAsync(raw.Out, folder)).Out);
    }
}
