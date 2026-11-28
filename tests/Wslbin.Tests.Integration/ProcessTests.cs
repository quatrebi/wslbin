using System.Text;

namespace Wslbin.Tests;

// The program as a process, as Windows starts it: console encoding, exit codes, what it says where. Nothing
// here needs WSL: the commands that would call wsl.exe are covered by the unit tests.
public class ProcessTests(ExeFixture fixture)
{
    [Fact]
    public async Task Version_is_one_line_with_a_semantic_version_and_exit_code_0()
    {
        string exe = Runner.Place(fixture, "wslbin");
        RunResult r = await Runner.RunAsync(exe, ["--version"]);
        Assert.Equal(0, r.ExitCode);
        Assert.Matches(@"^wslbin \d+\.\d+\.\d+\S*\n$", r.Out);
        Assert.Equal("", r.Err);
    }

    [Fact]
    public async Task Help_goes_to_standard_output_and_usage_without_arguments_to_standard_error_with_125()
    {
        string exe = Runner.Place(fixture, "wslbin");
        RunResult help = await Runner.RunAsync(exe, ["--help"]);
        Assert.Equal(0, help.ExitCode);
        Assert.Contains("Usage", help.Out, StringComparison.Ordinal);

        RunResult none = await Runner.RunAsync(exe, []);
        Assert.Equal(125, none.ExitCode);
        Assert.Contains("Usage", none.Err, StringComparison.Ordinal);
        Assert.Equal("", none.Out);
    }

    [Theory]
    [InlineData(new[] { "--bogus" }, "unknown option --bogus")]
    [InlineData(new[] { "--raw", "-c", "x" }, "-c hands the string to bash")]
    [InlineData(new[] { "--link", "con" }, "'con' cannot be a wrapper name")]
    public async Task A_command_that_makes_no_sense_ends_with_125_and_one_line_without_a_stack_trace(string[] args, string message)
    {
        string exe = Runner.Place(fixture, "wslbin");
        RunResult r = await Runner.RunAsync(exe, args);
        Assert.Equal(125, r.ExitCode);
        Assert.Contains(message, r.Err, StringComparison.Ordinal);
        Assert.StartsWith("wslbin: ", r.Err, StringComparison.Ordinal);
        Assert.Equal(1, r.Err.Count(c => c == '\n'));
    }

    [Fact]
    public async Task A_wrapper_flag_that_does_not_exist_is_refused_with_125()
    {
        string exe = Runner.Place(fixture, "tool");
        RunResult r = await Runner.RunAsync(exe, ["--wslbin-bogus"]);
        Assert.Equal(125, r.ExitCode);
        Assert.Contains("unknown option --wslbin-bogus", r.Err, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Output_that_is_redirected_is_UTF8_whatever_the_code_page_with_a_line_feed_at_the_end()
    {
        const string Ru = "\u0444\u0430\u0439\u043B \u65E5\u672C";
        string exe = Runner.Place(fixture, "tool");
        RunResult r = await Runner.RunAsync(exe, ["--wslbin-explain", Ru]);
        Assert.Equal(0, r.ExitCode);
        Assert.Equal(Encoding.UTF8.GetBytes("tool " + Ru.Replace(" ", @"\ ", StringComparison.Ordinal) + "\n"), r.OutBytes);
        Assert.NotEqual(0xEF, r.OutBytes[0]);     // no byte order mark
    }

    [Fact]
    public async Task Warnings_go_to_standard_error_and_do_not_change_the_script_on_standard_output()
    {
        string exe = Runner.Place(fixture, "tool", ini: "bogus = 1\n");
        RunResult r = await Runner.RunAsync(exe, ["--wslbin-explain", "x"]);
        Assert.Equal(0, r.ExitCode);
        Assert.Equal("tool x\n", r.Out);
        Assert.Equal("wslbin: warning: wslbin.ini line 1: unknown key 'bogus'\n", r.Err);
    }

    [Fact]
    public async Task The_name_of_the_utility_is_the_name_of_the_file_in_the_case_the_folder_spells_it()
    {
        string dir = Runner.NewDir(fixture);
        string exe = Runner.Place(fixture, "rsync", dir: dir);
        RunResult r = await Runner.RunAsync(Path.Combine(dir, "RSYNC.EXE"), ["--wslbin-explain", "-av", "x"]);
        Assert.Equal("rsync -av x\n", r.Out);
        Assert.True(File.Exists(exe));
    }

    [Fact]
    public async Task Windows_variables_are_named_through_pass_env_and_values_only_when_they_are_paths()
    {
        string exe = Runner.Place(fixture, "tool", ini: "pass_env = APPX_*\n");
        RunResult r = await Runner.RunAsync(exe, ["--wslbin-explain"], env: new Dictionary<string, string?>
        {
            ["APPX_PATH"] = @"C:\x\y",
            ["APPX_TEXT"] = "hello",
        });
        Assert.Equal(0, r.ExitCode);
        Assert.Contains("wslbin: env APPX_PATH=/mnt/c/x/y\n", r.Err, StringComparison.Ordinal);
        Assert.Contains("wslbin: env APPX_TEXT\n", r.Err, StringComparison.Ordinal);
        Assert.DoesNotContain("hello", r.Err, StringComparison.Ordinal);
    }

    [Fact]
    public async Task A_relative_path_is_translated_only_when_it_exists_in_the_folder_the_process_starts_in()
    {
        string exe = Runner.Place(fixture, "tool");
        string work = Runner.NewDir(fixture);
        Directory.CreateDirectory(Path.Combine(work, "sub dir"));
        await File.WriteAllTextAsync(Path.Combine(work, "sub dir", "b.c"), "x\n", TestContext.Current.CancellationToken);
        RunResult r = await Runner.RunAsync(exe, ["--wslbin-explain", @".\sub dir\b.c", @".\nope.c"], workingDirectory: work);
        Assert.Equal("tool ./sub\\ dir/b.c .\\\\nope.c\n", r.Out);
    }

    [Fact]
    public async Task The_wrappers_made_by_link_are_copies_of_the_program_and_work_as_wrappers()
    {
        string dir = Runner.NewDir(fixture);
        string exe = Runner.Place(fixture, "wslbin", dir: dir);
        RunResult made = await Runner.RunAsync(exe, ["--internal-link", "mytool"], env: new Dictionary<string, string?> { ["PATH"] = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32") });
        Assert.Equal(0, made.ExitCode);
        Assert.Equal(File.ReadAllBytes(exe), File.ReadAllBytes(Path.Combine(dir, "mytool.exe")));

        RunResult listed = await Runner.RunAsync(exe, ["--list", "--names"]);
        Assert.Equal("mytool\n", listed.Out);
        RunResult explained = await Runner.RunAsync(Path.Combine(dir, "mytool.exe"), ["--wslbin-explain", "a b"]);
        Assert.Equal("mytool a\\ b\n", explained.Out);

        RunResult removed = await Runner.RunAsync(exe, ["--internal-unlink", "mytool"]);
        Assert.Equal(0, removed.ExitCode);
        Assert.False(File.Exists(Path.Combine(dir, "mytool.exe")));
    }

    [Fact]
    public async Task The_text_for_agents_and_the_help_topics_are_built_into_the_program()
    {
        string exe = Runner.Place(fixture, "wslbin");
        RunResult ai = await Runner.RunAsync(exe, ["--ai-context"]);
        Assert.Equal(0, ai.ExitCode);
        Assert.Contains("wslbin", ai.Out, StringComparison.Ordinal);
        foreach (string topic in new[] { "modes", "paths", "globs", "env", "completion", "config", "troubleshooting" })
        {
            RunResult r = await Runner.RunAsync(exe, ["--help", topic]);
            Assert.Equal(0, r.ExitCode);
            Assert.NotEmpty(r.Out);
        }
    }

    [Fact]
    public async Task The_PowerShell_code_is_one_line_of_ASCII()
    {
        string exe = Runner.Place(fixture, "wslbin");
        RunResult r = await Runner.RunAsync(exe, ["--init", "pwsh"]);
        Assert.Equal(0, r.ExitCode);
        string line = r.Out.TrimEnd('\n');
        Assert.DoesNotContain('\n', line);
        Assert.True(line.All(char.IsAscii));
        Assert.StartsWith("Invoke-Expression (", line, StringComparison.Ordinal);
    }
}
