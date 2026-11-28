using System.Text;

namespace Wslbin.Tests;

public class ConfigTests
{
    static (Config Config, List<string> Warnings) Load(Machine m, string ini)
    {
        m.Ini(ini);
        List<string> warnings = [];
        Config cfg = Config.Load(m.IniPath, warnings.Add);
        return (cfg, warnings);
    }

    [Fact]
    public void A_file_that_is_not_UTF8_warns_and_still_reads_its_keys()
    {
        using var m = new Machine();
        // "raw = tool" and a comment in Windows-1251 (0xD4 0xE0 0xE9 0xEB, "файл"): not UTF-8
        byte[] bytes = [.. "# "u8, 0xD4, 0xE0, 0xE9, 0xEB, .. "\nraw = tool\n"u8];
        File.WriteAllBytes(m.IniPath, bytes);
        List<string> warnings = [];
        Config cfg = Config.Load(m.IniPath, warnings.Add);
        Assert.Equal(ArgMode.Raw, cfg.ModeFor("tool"));
        Assert.Contains("is not UTF-8 text", Assert.Single(warnings), StringComparison.Ordinal);
    }

    [Fact]
    public void A_missing_file_gives_the_defaults_without_a_word()
    {
        using var m = new Machine();
        List<string> warnings = [];
        Config cfg = Config.Load(m.IniPath, warnings.Add);
        Assert.Empty(warnings);
        Assert.Equal(ArgMode.Smart, cfg.ModeFor("tool"));
        Assert.Equal("", cfg.PathPrefix());
        Assert.Equal("", cfg.Distro);
    }

    [Fact]
    public void Raw_and_sh_name_the_utilities_that_get_that_mode()
    {
        using var m = new Machine();
        (Config cfg, _) = Load(m, "raw = tool, other\nsh = make\n");
        Assert.Equal(ArgMode.Raw, cfg.ModeFor("tool"));
        Assert.Equal(ArgMode.Raw, cfg.ModeFor("OTHER"));
        Assert.Equal(ArgMode.Sh, cfg.ModeFor("make"));
        Assert.Equal(ArgMode.Smart, cfg.ModeFor("ls"));
    }

    [Fact]
    public void A_flag_overrides_the_configured_mode()
    {
        using var m = new Machine();
        Assert.Equal("tool \"$HOME\"", m.Explain("tool", ["$HOME"], ini: "raw = tool\n", flags: ["--wslbin-sh"]));
    }

    [Fact]
    public void Keys_and_names_are_matched_without_regard_to_case_and_list_keys_add_up()
    {
        using var m = new Machine();
        Assert.Equal("tool 'a*'", m.Explain("tool", ["a*"], ini: "RAW = TOOL\n"));
        Assert.Equal("tool 'a*'", m.Explain("tool", ["a*"], ini: "raw = one\nraw = tool\n"));
    }

    [Fact]
    public void Default_arguments_go_in_front_of_the_typed_ones_and_follow_the_mode()
    {
        using var m = new Machine();
        Assert.Equal("tool --color=auto -x dir", m.Explain("tool", ["dir"], ini: "args.tool = --color=auto -x"));
        Assert.Equal(@"tool a\ b c", m.Explain("tool", [], ini: "args.tool = \"a b\" c"));
        Assert.Equal("tool 'a*'", m.Explain("tool", [], ini: "raw = tool\nargs.tool = a*"));
        Assert.Equal("tool 'x y' z", m.Explain("tool", [], ini: "raw = tool\nargs.tool = 'x y' \"z\""));
    }

    [Fact]
    public void Comments_blank_lines_and_a_byte_order_mark_are_read()
    {
        using var m = new Machine();
        string ini = "# comment\n; another\n\n  raw = tool  \n";
        Assert.Equal("tool 'a*'", m.Explain("tool", ["a*"], ini: ini));
        File.WriteAllText(m.IniPath, ini, new UTF8Encoding(true));
        Assert.Equal("tool 'a*'", m.Explain("tool", ["a*"]));
    }

    [Fact]
    public void Bad_lines_and_unknown_keys_warn_with_line_numbers_and_the_rest_is_read()
    {
        using var m = new Machine();
        (Config cfg, List<string> warnings) = Load(m, "raw = tool\nnot a setting\nfrobnicate = 1\nlang = fr\n");
        Assert.Equal(ArgMode.Raw, cfg.ModeFor("tool"));
        Assert.Contains("wslbin.ini line 2: expected 'key = value'", warnings);
        Assert.Contains("wslbin.ini line 3: unknown key 'frobnicate'", warnings);
        Assert.Contains("wslbin.ini line 4: lang must be en, ru or auto, not 'fr'", warnings);
    }

    [Fact]
    public void Warnings_reach_standard_error_and_do_not_stop_the_run()
    {
        using var m = new Machine();
        m.Explain("tool", ["a*"], ini: "raw = tool\nnot a setting\n");
        Assert.Contains("wslbin: warning: wslbin.ini line 2: expected 'key = value'", m.Err, StringComparison.Ordinal);
    }

    [Fact]
    public void Distro_and_lang_are_read_with_quotes_taken_off()
    {
        using var m = new Machine();
        (Config cfg, _) = Load(m, "distro = \"Ubuntu 24\"\nlang = RU\n");
        Assert.Equal("Ubuntu 24", cfg.Distro);
        Assert.Equal("ru", cfg.Lang);
    }

    [Fact]
    public void Path_adds_directories_to_PATH_inside_WSL()
    {
        using var m = new Machine();
        Assert.Equal("export PATH=\"$HOME/.local/bin:/opt/my tools:$PATH\"; tool x",
            m.Explain("tool", ["x"], ini: "path = ~/.local/bin, /opt/my tools"));
    }

    [Fact]
    public void The_PATH_change_goes_in_front_of_a_c_string_too()
    {
        using var m = new Machine();
        m.Ini("path = ~/bin");
        Assert.Equal(0, m.Run("wslbin", "--explain", "-c", "a | b"));
        Assert.Equal("export PATH=\"$HOME/bin:$PATH\"; a | b\n", m.Out);
    }

    [Theory]
    [InlineData("path = /a$b\"c", "export PATH=\"/a\\$b\\\"c:$PATH\"; tool")]
    [InlineData("path = \"/opt/my tools\", ~/bin", "export PATH=\"/opt/my tools:$HOME/bin:$PATH\"; tool")]
    [InlineData("path = $HOME/.local/bin", "export PATH=\"\\$HOME/.local/bin:$PATH\"; tool")]
    [InlineData("path = \"~/tools \"", "export PATH=\"$HOME/tools :$PATH\"; tool")]
    public void A_path_entry_is_text_for_bash_inside_double_quotes(string ini, string want)
    {
        using var m = new Machine();
        Assert.Equal(want, m.Explain("tool", [], ini: ini));
    }

    [Fact]
    public void A_path_entry_with_a_colon_is_ignored_with_a_warning()
    {
        using var m = new Machine();
        Assert.Equal("export PATH=\"/c:$PATH\"; tool", m.Explain("tool", [], ini: "path = /a:b, /c"));
        Assert.Contains("line 1: path entry '/a:b' contains ':'", m.Err, StringComparison.Ordinal);
    }

    [Fact]
    public void The_PATH_is_left_alone_without_the_path_key()
    {
        using var m = new Machine();
        Assert.Equal("tool x", m.Explain("x"));
    }

    [Fact]
    public void An_unreadable_file_is_a_warning_not_an_error()
    {
        using var m = new Machine();
        m.Ini("raw = tool\n");
        using var locked = new FileStream(m.IniPath, FileMode.Open, FileAccess.Read, FileShare.None);
        List<string> warnings = [];
        Config cfg = Config.Load(m.IniPath, warnings.Add);
        Assert.Equal(ArgMode.Smart, cfg.ModeFor("tool"));
        Assert.StartsWith("cannot read ", Assert.Single(warnings), StringComparison.Ordinal);
    }

    [Fact]
    public void The_pass_env_list_splits_at_commas_blanks_and_tabs()
    {
        using var m = new Machine();
        (Config cfg, _) = Load(m, "pass_env = A_*, B\tC  D\npass_env = E\n");
        Assert.Equal(["A_*", "B", "C", "D", "E"], cfg.PassEnv);
    }
}
