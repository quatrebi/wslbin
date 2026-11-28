using System.Text;

namespace Wslbin.Tests;

public class InitTests
{
    static Machine Setup()
    {
        var m = new Machine();
        m.MakeExe("wslbin");
        m.Fake.Env["PATH"] = m.Dir;
        return m;
    }

    static string Code(Machine m, params string[] extra)
    {
        m.Fake.ClearOutput();
        Assert.Equal(0, m.Run("wslbin", ["--init", "pwsh", .. extra]));
        string line = m.Out.TrimEnd('\n');
        Assert.DoesNotContain('\n', line);
        Assert.True(line.All(char.IsAscii));
        const string Prefix = "Invoke-Expression ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('";
        Assert.StartsWith(Prefix, line, StringComparison.Ordinal);
        Assert.EndsWith("')))", line, StringComparison.Ordinal);
        return Encoding.UTF8.GetString(Convert.FromBase64String(line[Prefix.Length..^4]));
    }

    [Fact]
    public void Pwsh_prints_one_line_of_ASCII_with_the_program_and_the_wrappers_filled_in()
    {
        using Machine m = Setup();
        m.MakeExe("rsync");
        m.MakeExe("jq");
        string code = Code(m);
        Assert.Contains(m.Exe("wslbin").Replace("'", "''", StringComparison.Ordinal), code, StringComparison.Ordinal);
        Assert.Contains("'jq', 'rsync'", code, StringComparison.Ordinal);
        Assert.DoesNotContain("@EXE@", code, StringComparison.Ordinal);
        Assert.DoesNotContain("@NAMES@", code, StringComparison.Ordinal);
        Assert.DoesNotContain("@FALLBACK@", code, StringComparison.Ordinal);
        Assert.Contains("$false", code, StringComparison.Ordinal);
        Assert.Contains("$true", Code(m, "--native-fallback"), StringComparison.Ordinal);
    }

    [Fact]
    public void A_file_whose_name_could_not_be_a_wrapper_name_stays_out_of_the_code_every_shell_runs()
    {
        using Machine m = Setup();
        m.MakeExe("rsync");
        m.MakeExe("it's");
        m.MakeExe("bad name");
        string code = Code(m);
        Assert.Contains("'rsync'", code, StringComparison.Ordinal);
        Assert.DoesNotContain("'it''s'", code, StringComparison.Ordinal);
        Assert.DoesNotContain("'bad name'", code, StringComparison.Ordinal);
    }

    [Fact]
    public void A_path_with_a_quote_or_a_letter_outside_ASCII_is_written_so_that_any_code_page_reads_it_back()
    {
        using var m = new Machine();
        string dir = Path.Combine(m.Dir, "it's \u0444");
        Directory.CreateDirectory(dir);
        string exe = Path.Combine(dir, "wslbin.exe");
        File.WriteAllText(exe, FakeHost.ExeText);
        Assert.Equal(0, Program.Execute(exe, ["--init", "pwsh"]));
        string line = m.Out;
        Assert.True(line.TrimEnd('\n').All(char.IsAscii));
        string code = Encoding.UTF8.GetString(Convert.FromBase64String(line.Split('\'')[1]));
        Assert.Contains("[char]1092", code, StringComparison.Ordinal);
        Assert.Contains("it''s", code, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(new string[0], "--init needs a shell: pwsh or clink")]
    [InlineData(new[] { "bash" }, "unknown shell 'bash': use pwsh or clink")]
    [InlineData(new[] { "pwsh", "--bogus" }, "unknown option --bogus for --init pwsh")]
    [InlineData(new[] { "clink", "--dir" }, "--dir needs a folder")]
    [InlineData(new[] { "clink", "--bogus" }, "unknown option --bogus for --init clink")]
    public void A_command_line_that_makes_no_sense_is_refused(string[] args, string message)
    {
        using Machine m = Setup();
        Assert.Equal(125, m.Run("wslbin", ["--init", .. args]));
        Assert.Equal($"wslbin: {message}\n", m.Err);
    }

    // ---- clink ----

    [Fact]
    public void Clink_writes_wslbin_lua_into_the_folder_it_is_told_to_with_the_program_path_filled_in()
    {
        using Machine m = Setup();
        string scripts = Path.Combine(m.Dir, "scripts");
        Directory.CreateDirectory(scripts);
        Assert.Equal(0, m.Run("wslbin", "--init", "clink", "--dir", scripts));
        string lua = File.ReadAllText(Path.Combine(scripts, "wslbin.lua"));
        Assert.StartsWith(Init.ClinkScriptMark, lua, StringComparison.Ordinal);
        Assert.Contains("\"" + m.Exe("wslbin").Replace("\\", "\\\\", StringComparison.Ordinal) + "\"", lua, StringComparison.Ordinal);
        Assert.DoesNotContain("@EXE@", lua, StringComparison.Ordinal);
        Assert.Equal($"wrote {Path.Combine(scripts, "wslbin.lua")}; open a new cmd window to use it\n", m.Out);

        m.Fake.ClearOutput();
        Assert.Equal(0, m.Run("wslbin", "--init", "clink", "--dir", scripts));
        Assert.Equal(lua, File.ReadAllText(Path.Combine(scripts, "wslbin.lua")));
    }

    [Fact]
    public void Clink_refuses_a_folder_that_does_not_exist_and_a_file_that_it_did_not_write()
    {
        using Machine m = Setup();
        Assert.Equal(125, m.Run("wslbin", "--init", "clink", "--dir", Path.Combine(m.Dir, "nope")));
        Assert.Contains("does not exist; is Clink installed?", m.Err, StringComparison.Ordinal);

        string scripts = Path.Combine(m.Dir, "scripts");
        Directory.CreateDirectory(scripts);
        File.WriteAllText(Path.Combine(scripts, "wslbin.lua"), "-- mine\n");
        Assert.Equal(125, m.Run("wslbin", "--init", "clink", "--dir", scripts));
        Assert.Contains("was not written by wslbin; left alone", m.Err, StringComparison.Ordinal);
        Assert.Equal("-- mine\n", File.ReadAllText(Path.Combine(scripts, "wslbin.lua")));
    }

    [Fact]
    public void Without_clink_in_PATH_the_folder_is_clink_in_the_local_app_data()
    {
        using Machine m = Setup();
        m.Fake.Env["LOCALAPPDATA"] = m.Dir;
        Directory.CreateDirectory(Path.Combine(m.Dir, "clink"));
        Assert.Equal(0, m.Run("wslbin", "--init", "clink"));
        Assert.True(File.Exists(Path.Combine(m.Dir, "clink", "wslbin.lua")));
        Assert.Empty(m.Fake.Calls);
    }

    [Fact]
    public void Clink_is_asked_for_its_folder_through_the_cmd_of_Windows_and_never_one_in_the_current_folder()
    {
        using Machine m = Setup();
        string clinkBat = Path.Combine(m.Dir, "clink.bat");
        File.WriteAllText(clinkBat, "@echo off");
        string state = Path.Combine(m.Dir, "state");
        Directory.CreateDirectory(state);
        m.Fake.SystemDirectoryValue = @"C:\Windows\System32";
        m.Fake.ConsoleEncoding = Encoding.UTF8;
        m.Fake.OnWsl = call => FakeHost.Reply(0, $"binaries : C:\\clink\nstate    : {state}\nscripts  : x\n");
        Assert.Equal(0, m.Run("wslbin", "--init", "clink"));
        Assert.True(File.Exists(Path.Combine(state, "wslbin.lua")));
        WslCall call = Assert.Single(m.Fake.Calls);
        Assert.Equal(@"C:\Windows\System32\cmd.exe", call.Psi.FileName);
        Assert.Equal($"/c \"\"{clinkBat}\" info\"", call.Psi.Arguments, StringComparer.OrdinalIgnoreCase);
    }

    [Fact]
    public void When_clink_does_not_answer_or_says_no_state_the_default_folder_is_used()
    {
        using Machine m = Setup();
        File.WriteAllText(Path.Combine(m.Dir, "clink.bat"), "@echo off");
        m.Fake.Env["LOCALAPPDATA"] = m.Dir;
        string fallback = Path.Combine(m.Dir, "clink");
        Directory.CreateDirectory(fallback);
        m.Fake.OnWsl = _ => null;
        Assert.Equal(0, m.Run("wslbin", "--init", "clink"));
        Assert.True(File.Exists(Path.Combine(fallback, "wslbin.lua")));

        File.Delete(Path.Combine(fallback, "wslbin.lua"));
        m.Fake.OnWsl = _ => FakeHost.Reply(0, "binaries : C:\\clink\n");
        Assert.Equal(0, m.Run("wslbin", "--init", "clink"));
        Assert.True(File.Exists(Path.Combine(fallback, "wslbin.lua")));

        File.Delete(Path.Combine(fallback, "wslbin.lua"));
        m.Fake.OnWsl = _ => throw new WslbinException("cannot start cmd.exe");
        Assert.Equal(0, m.Run("wslbin", "--init", "clink"));
        Assert.True(File.Exists(Path.Combine(fallback, "wslbin.lua")));
    }
}
