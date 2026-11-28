using System.Text;

namespace Wslbin.Tests;

// Wrappers that run real utilities in a real distribution: a copy of the program named after the utility.
public class UtilityTests(ExeFixture fixture)
{
    const string Ru = "\u0444\u0430\u0439\u043B";

    static readonly string[] Nasty =
    [
        "plain", "a b", "x;echo pwned", "$(id)", "$HOME", "`uname`", "{print $1, $2}", "it's", "say \"hi\"",
        @"back\slash", @"trail\", @"two\\", "a|b&c", "a>b<c", "#hash", "!bang", "(paren)", "{a,b}", "", " ",
        "[[:$(id):]]", "line1\nline2", "--opt=value with spaces", "\u0444 \u0430\u0439\u043B"
    ];

    async Task<RunResult> Run(string utility, params string[] args)
    {
        Wsl.Require();
        string exe = Runner.Place(fixture, utility);
        return await Runner.RunAsync(exe, args);
    }

    [Fact]
    public async Task The_output_of_a_utility_comes_back_with_its_exit_code()
    {
        RunResult r = await Run("echo", "hello", "world");
        Assert.Equal(0, r.ExitCode);
        Assert.Equal("hello world\n", r.Out);
        Assert.Equal("", r.Err);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(7)]
    [InlineData(126)]
    [InlineData(255)]
    public async Task The_exit_code_of_the_utility_is_the_exit_code_of_the_wrapper(int code)
    {
        RunResult r = await Run("sh", "-c", $"exit {code}");
        Assert.Equal(code, r.ExitCode);
        Assert.Equal("", r.Err);
    }

    [Fact]
    public async Task A_utility_that_does_not_exist_gives_127()
    {
        RunResult r = await Run("wslbin-no-such-utility");
        Assert.Equal(127, r.ExitCode);
    }

    [Fact]
    public async Task Standard_input_goes_to_the_utility_and_standard_error_stays_apart_from_standard_output()
    {
        Wsl.Require();
        string exe = Runner.Place(fixture, "sh");
        RunResult r = await Runner.RunAsync(exe, ["-c", "cat; echo to-stderr >&2"], stdin: Encoding.UTF8.GetBytes($"input {Ru}\n"));
        Assert.Equal(0, r.ExitCode);
        Assert.Equal($"input {Ru}\n", r.Out);
        Assert.Equal("to-stderr\n", r.Err);
    }

    [Fact]
    public async Task Output_in_UTF8_arrives_byte_for_byte()
    {
        RunResult r = await Run("printf", "%s\n", $"{Ru} \u65E5\u672C");
        Assert.Equal(Encoding.UTF8.GetBytes($"{Ru} \u65E5\u672C\n"), r.OutBytes);
    }

    [Fact]
    public async Task Every_argument_arrives_as_exactly_one_argument_as_typed()
    {
        RunResult r = await Run("printf", [@"%s\0", .. Nasty]);
        Assert.Equal(0, r.ExitCode);
        List<string> got = [.. r.Out.Split('\0')];
        got.RemoveAt(got.Count - 1);
        Assert.Equal(Nasty, got);
    }

    [Fact]
    public async Task A_windows_path_becomes_the_path_Linux_sees_and_the_file_is_found()
    {
        Wsl.Require();
        string folder = Runner.NewDir(fixture);
        string file = Path.Combine(folder, $"{Ru} name.txt");
        await File.WriteAllTextAsync(file, "content\n", TestContext.Current.CancellationToken);
        string exe = Runner.Place(fixture, "cat");
        RunResult r = await Runner.RunAsync(exe, [file]);
        Assert.Equal("content\n", r.Out);
        RunResult relative = await Runner.RunAsync(exe, [$@".\{Ru} name.txt"], folder);
        Assert.Equal("content\n", relative.Out);
    }

    [Fact]
    public async Task Bash_expands_wildcards_in_the_current_folder_by_Linux_rules()
    {
        Wsl.Require();
        string folder = Runner.NewDir(fixture);
        foreach (string f in new[] { "b.log", "a.log", "c.txt" }) await File.WriteAllTextAsync(Path.Combine(folder, f), "x", TestContext.Current.CancellationToken);
        string exe = Runner.Place(fixture, "ls");
        Assert.Equal("a.log\nb.log\n", (await Runner.RunAsync(exe, ["*.log"], folder)).Out);
        Assert.Equal(2, (await Runner.RunAsync(exe, ["*.nothing"], folder)).ExitCode);
        string raw = Runner.Place(fixture, "ls", dir: Path.GetDirectoryName(exe));
        Assert.Equal(2, (await Runner.RunAsync(raw, ["--wslbin-raw", "*.log"], folder)).ExitCode);
    }

    [Fact]
    public async Task The_rest_of_a_c_command_line_is_dollar_zero_and_up_and_empty_ones_stay_empty()
    {
        Wsl.Require();
        string exe = Runner.Place(fixture, "wslbin");
        RunResult r = await Runner.RunAsync(exe, ["-c", @"printf '[%s]' ""$0"" ""$@""", "", "", "x", ""]);
        Assert.Equal("[][][x][]", r.Out);
    }

    [Fact]
    public async Task Variables_of_pass_env_reach_Linux_with_paths_translated()
    {
        Wsl.Require();
        string exe = Runner.Place(fixture, "sh", ini: "pass_env = WSLBIN_E2E_*\n");
        RunResult r = await Runner.RunAsync(exe, ["-c", "printf '%s|%s' \"$WSLBIN_E2E_PATH\" \"$WSLBIN_E2E_TEXT\""],
            env: new Dictionary<string, string?> { ["WSLBIN_E2E_PATH"] = @"C:\Windows", ["WSLBIN_E2E_TEXT"] = "hello" });
        Assert.Equal("/mnt/c/Windows|hello", r.Out);
    }

    [Fact]
    public async Task Doctor_passes_for_a_working_setup()
    {
        Wsl.Require();
        string dir = Runner.NewDir(fixture);
        string exe = Runner.Place(fixture, "wslbin", dir: dir);
        RunResult r = await Runner.RunAsync(exe, ["--doctor"], env: new Dictionary<string, string?> { ["PATH"] = dir + ";" + Environment.GetEnvironmentVariable("PATH") });
        Assert.Contains("[ ok ] bash ", r.Out, StringComparison.Ordinal);
        Assert.DoesNotContain("[FAIL]", r.Out, StringComparison.Ordinal);
        Assert.Equal(0, r.ExitCode);
    }

    [Fact]
    public async Task Link_makes_a_working_wrapper_for_a_utility_that_exists_and_none_for_one_that_does_not()
    {
        Wsl.Require();
        string dir = Runner.NewDir(fixture);
        string exe = Runner.Place(fixture, "wslbin", dir: dir);
        var env = new Dictionary<string, string?> { ["PATH"] = dir + ";" + Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32") };
        RunResult made = await Runner.RunAsync(exe, ["--link", "tac"], env: env);
        Assert.Equal(0, made.ExitCode);
        Assert.True(File.Exists(Path.Combine(dir, "tac.exe")));
        RunResult used = await Runner.RunAsync(Path.Combine(dir, "tac.exe"), [], stdin: "a\nb\n"u8.ToArray());
        Assert.Equal("b\na\n", used.Out);

        RunResult none = await Runner.RunAsync(exe, ["--link", "wslbin-no-such-utility"], env: env);
        Assert.Equal(125, none.ExitCode);
        Assert.False(File.Exists(Path.Combine(dir, "wslbin-no-such-utility.exe")));
    }

    [Fact]
    public async Task Tab_completion_offers_options_from_bash_completion_and_takes_Windows_paths_in_and_gives_them_out()
    {
        Wsl.Require();
        Assert.SkipUnless(Wsl.Run("[ -r /usr/share/bash-completion/bash_completion ] && echo yes").Trim() == "yes", "bash-completion is not installed in WSL");
        string exe = Runner.Place(fixture, "ls");
        string wslbin = Runner.Place(fixture, "wslbin", dir: Path.GetDirectoryName(exe));
        RunResult options = await Runner.RunAsync(wslbin, ["--complete", "2", "ls", "-l", "--al"]);
        Assert.Contains("--all", options.Out.Split((char)10));

        RunResult paths = await Runner.RunAsync(wslbin, ["--complete", "2", "ls", "-l", @"C:\Window"]);
        Assert.Contains(@"C:\Windows\", paths.Out.Split((char)10));
    }
}
