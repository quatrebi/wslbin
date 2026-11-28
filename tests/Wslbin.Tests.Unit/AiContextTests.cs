using System.Text;

namespace Wslbin.Tests;

// wslbin --ai-context and --install-ai-context, in folders of the test: never in the real ones of Claude Code or Codex.
public class AiContextTests
{
    const string Begin = "<!-- wslbin:begin";
    const string End = "<!-- wslbin:end -->";

    static Machine Setup()
    {
        var m = new Machine();
        m.MakeExe("wslbin");
        return m;
    }

    static string Folder(Machine m, string name)
    {
        string path = Path.Combine(m.Dir, name);
        Directory.CreateDirectory(path);
        return path;
    }

    static int Install(Machine m, params string[] args)
    {
        m.Fake.ClearOutput();
        return m.Run("wslbin", ["--install-ai-context", .. args]);
    }

    [Fact]
    public void The_text_for_an_agent_is_printed_and_takes_no_arguments()
    {
        using Machine m = Setup();
        Assert.Equal(0, m.Run("wslbin", "--ai-context"));
        Assert.Contains("wslbin", m.Out, StringComparison.Ordinal);
        Assert.Equal(Help.Document(m.Config(), "ai-context.md").TrimEnd('\n') + "\n", m.Out);
        Assert.Equal(125, m.Run("wslbin", "--ai-context", "x"));
    }

    [Fact]
    public void The_text_follows_lang_of_the_config()
    {
        using Machine m = Setup();
        m.Ini("lang = ru\n");
        m.Run("wslbin", "--ai-context");
        string russian = m.Out;
        m.Ini("lang = en\n");
        m.Fake.ClearOutput();
        m.Run("wslbin", "--ai-context");
        Assert.NotEqual(m.Out, russian);
    }

    [Fact]
    public void Both_agents_get_their_files_when_their_folders_are_named()
    {
        using Machine m = Setup();
        string claude = Folder(m, "claude");
        string codex = Folder(m, "codex");
        Assert.Equal(0, Install(m, "--claude-dir", claude, "--codex-dir", codex));
        string claudeMd = File.ReadAllText(Path.Combine(claude, "CLAUDE.md"));
        Assert.StartsWith(Begin, claudeMd, StringComparison.Ordinal);
        Assert.Contains("## Linux utilities on this Windows machine", claudeMd, StringComparison.Ordinal);
        Assert.EndsWith(End + "\n", claudeMd, StringComparison.Ordinal);
        Assert.Contains(Begin, File.ReadAllText(Path.Combine(codex, "AGENTS.md")), StringComparison.Ordinal);
        string skill = File.ReadAllText(Path.Combine(claude, "skills", "wslbin", "SKILL.md"));
        Assert.StartsWith("---\nname: wslbin\ndescription: ", skill, StringComparison.Ordinal);
        Assert.Contains("<!-- wslbin:managed", skill, StringComparison.Ordinal);
        Assert.Contains($"created {Path.Combine(claude, "CLAUDE.md")}", m.Out, StringComparison.Ordinal);
        Assert.Contains($"created {Path.Combine(claude, "skills", "wslbin", "SKILL.md")}", m.Out, StringComparison.Ordinal);
    }

    [Fact]
    public void A_second_run_changes_nothing_and_says_up_to_date()
    {
        using Machine m = Setup();
        string claude = Folder(m, "claude");
        Install(m, "--claude-dir", claude, "--codex-dir", Folder(m, "codex"));
        Assert.Equal(0, Install(m, "--claude-dir", claude, "--codex-dir", Path.Combine(m.Dir, "codex")));
        Assert.Contains("the wslbin block in", m.Out, StringComparison.Ordinal);
        Assert.Contains("is up to date", m.Out, StringComparison.Ordinal);
        Assert.Contains("the skill ", m.Out, StringComparison.Ordinal);
    }

    [Fact]
    public void An_existing_file_keeps_its_text_and_its_line_ends_and_a_changed_block_is_replaced()
    {
        using Machine m = Setup();
        string claude = Folder(m, "claude");
        string md = Path.Combine(claude, "CLAUDE.md");
        File.WriteAllText(md, "# Mine\r\n\r\nrules\r\n");
        Assert.Equal(0, Install(m, "--claude", "--claude-dir", claude));
        string text = File.ReadAllText(md);
        Assert.StartsWith("# Mine\r\n\r\nrules\r\n\r\n" + Begin, text, StringComparison.Ordinal);
        Assert.DoesNotContain("\n", text.Replace("\r\n", "", StringComparison.Ordinal), StringComparison.Ordinal);
        Assert.Contains("added the wslbin block to", m.Out, StringComparison.Ordinal);

        // an old block is replaced in place
        File.WriteAllText(md, "top\n" + Begin + " old -->\nold text\n" + End + "\nbottom\n");
        Assert.Equal(0, Install(m, "--claude", "--claude-dir", claude));
        string updated = File.ReadAllText(md);
        Assert.StartsWith("top\n" + Begin, updated, StringComparison.Ordinal);
        Assert.EndsWith(End + "\nbottom\n", updated, StringComparison.Ordinal);
        Assert.DoesNotContain("old text", updated, StringComparison.Ordinal);
        Assert.Contains("updated the wslbin block in", m.Out, StringComparison.Ordinal);
    }

    [Fact]
    public void A_byte_order_mark_is_kept()
    {
        using Machine m = Setup();
        string claude = Folder(m, "claude");
        string md = Path.Combine(claude, "CLAUDE.md");
        File.WriteAllText(md, "# Mine\n", new UTF8Encoding(true));
        Install(m, "--claude", "--claude-dir", claude);
        Assert.Equal([0xEF, 0xBB, 0xBF], File.ReadAllBytes(md).Take(3));
    }

    [Fact]
    public void Remove_takes_the_block_out_and_deletes_a_file_that_held_nothing_else()
    {
        using Machine m = Setup();
        string claude = Folder(m, "claude");
        string md = Path.Combine(claude, "CLAUDE.md");
        File.WriteAllText(md, "# Mine\n\nrules\n");
        Install(m, "--claude-dir", claude);
        Assert.Equal(0, Install(m, "--remove", "--claude-dir", claude));
        Assert.Equal("# Mine\n\nrules\n", File.ReadAllText(md));
        Assert.Contains("removed the wslbin block from", m.Out, StringComparison.Ordinal);
        Assert.False(File.Exists(Path.Combine(claude, "skills", "wslbin", "SKILL.md")));
        Assert.False(Directory.Exists(Path.Combine(claude, "skills", "wslbin")));

        File.Delete(md);
        Install(m, "--claude-dir", claude);
        Assert.Equal(0, Install(m, "--remove", "--claude-dir", claude));
        Assert.False(File.Exists(md));
        Assert.Contains("(it held nothing else)", m.Out, StringComparison.Ordinal);

        Assert.Equal(0, Install(m, "--remove", "--claude-dir", claude));
        Assert.Contains("no wslbin block in", m.Out, StringComparison.Ordinal);
        Assert.Contains("no wslbin skill at", m.Out, StringComparison.Ordinal);
    }

    [Fact]
    public void A_dry_run_writes_nothing()
    {
        using Machine m = Setup();
        string claude = Folder(m, "claude");
        Assert.Equal(0, Install(m, "--dry-run", "--claude-dir", claude));
        Assert.Empty(Directory.GetFileSystemEntries(claude));
        Assert.Contains("would create", m.Out, StringComparison.Ordinal);

        Install(m, "--claude-dir", claude);
        Assert.Equal(0, Install(m, "--dry-run", "--remove", "--claude-dir", claude));
        Assert.Contains("would remove", m.Out, StringComparison.Ordinal);
        Assert.True(File.Exists(Path.Combine(claude, "CLAUDE.md")));
        Assert.Equal(0, Install(m, "--dry-run", "--codex-dir", Path.Combine(m.Dir, "new codex")));
        Assert.False(Directory.Exists(Path.Combine(m.Dir, "new codex")));
    }

    [Fact]
    public void Only_the_agent_that_was_asked_for_is_done_and_a_folder_named_for_the_other_is_refused()
    {
        using Machine m = Setup();
        string claude = Folder(m, "claude");
        string codex = Folder(m, "codex");
        Assert.Equal(0, Install(m, "--codex", "--codex-dir", codex));
        Assert.False(File.Exists(Path.Combine(claude, "CLAUDE.md")));
        Assert.True(File.Exists(Path.Combine(codex, "AGENTS.md")));
    }

    [Theory]
    [InlineData(new[] { "--codex", "--claude-dir", "x" }, "--claude-dir names the folder of Claude Code, which --codex leaves out")]
    [InlineData(new[] { "--claude", "--codex-dir", "x" }, "--codex-dir names the folder of Codex, which --claude leaves out")]
    [InlineData(new[] { "--bogus" }, "unknown option --bogus for --install-ai-context")]
    [InlineData(new[] { "--claude-dir" }, "--claude-dir needs a folder")]
    public void A_command_line_that_makes_no_sense_is_refused(string[] args, string message)
    {
        using Machine m = Setup();
        Assert.Equal(125, Install(m, args));
        Assert.Equal($"wslbin: {message}\n", m.Err);
    }

    [Fact]
    public void The_folders_come_from_the_variables_of_the_agents_and_else_from_the_home_folder()
    {
        using Machine m = Setup();
        string claude = Folder(m, "from-variable");
        string home = Folder(m, "home");
        Folder(m, @"home\.codex");
        m.Fake.Env["CLAUDE_CONFIG_DIR"] = claude;
        m.Fake.Env["USERPROFILE"] = home;
        Assert.Equal(0, Install(m));
        Assert.True(File.Exists(Path.Combine(claude, "CLAUDE.md")));
        Assert.True(File.Exists(Path.Combine(home, ".codex", "AGENTS.md")));
        Assert.False(Directory.Exists(Path.Combine(home, ".claude")));
        Assert.Equal(0, Install(m, "--remove"));
        Assert.False(File.Exists(Path.Combine(home, ".codex", "AGENTS.md")));
    }

    [Fact]
    public void A_folder_that_does_not_exist_is_skipped_unless_it_was_named_and_then_it_is_made()
    {
        using Machine m = Setup();
        m.Fake.Env["USERPROFILE"] = Path.Combine(m.Dir, "nobody");
        Assert.Equal(0, Install(m));
        Assert.Contains("Claude Code: skipped,", m.Out, StringComparison.Ordinal);
        Assert.Contains("(another folder: --claude-dir <folder>)", m.Out, StringComparison.Ordinal);
        Assert.Contains("Codex: skipped,", m.Out, StringComparison.Ordinal);
        Assert.False(Directory.Exists(Path.Combine(m.Dir, "nobody")));

        Assert.Equal(0, Install(m, "--remove"));
        Assert.Contains("does not exist, nothing to remove", m.Out, StringComparison.Ordinal);

        string named = Path.Combine(m.Dir, "named");
        Assert.Equal(0, Install(m, "--codex", "--codex-dir", named));
        Assert.True(File.Exists(Path.Combine(named, "AGENTS.md")));
    }

    [Fact]
    public void Without_a_home_folder_nothing_is_guessed()
    {
        using Machine m = Setup();
        Assert.Equal(0, Install(m));
        Assert.Contains("Claude Code: skipped, USERPROFILE is not set (name the folder: --claude-dir <folder>)", m.Out, StringComparison.Ordinal);
        Assert.Contains("Codex: skipped, USERPROFILE is not set (name the folder: --codex-dir <folder>)", m.Out, StringComparison.Ordinal);
        m.Fake.Env["USERPROFILE"] = "";
        m.Fake.Env["CODEX_HOME"] = "";
        Assert.Equal(0, Install(m));
        Assert.Contains("USERPROFILE is not set", m.Out, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(new byte[] { 0xD4, 0xE0, 0xE9 })]                                  // ANSI
    [InlineData(new byte[] { 0xFF, 0xFE, (byte)'#', 0, (byte)'x', 0 })]            // UTF-16
    public void A_file_that_is_not_UTF8_is_left_alone_and_the_other_agent_is_still_done(byte[] content)
    {
        using Machine m = Setup();
        string claude = Folder(m, "claude");
        string codex = Folder(m, "codex");
        File.WriteAllBytes(Path.Combine(claude, "CLAUDE.md"), content);
        Assert.Equal(125, Install(m, "--claude-dir", claude, "--codex-dir", codex));
        Assert.Contains("Claude Code: ", m.Err, StringComparison.Ordinal);
        Assert.Contains("is not UTF-8 text", m.Err, StringComparison.Ordinal);
        Assert.Equal(content, File.ReadAllBytes(Path.Combine(claude, "CLAUDE.md")));
        Assert.True(File.Exists(Path.Combine(codex, "AGENTS.md")));
    }

    [Theory]
    [InlineData("text\n" + Begin + " (stray) -->\nmore\n")]
    [InlineData("text\n" + End + "\nmore\n")]
    public void A_marker_without_its_other_half_is_left_alone(string content)
    {
        using Machine m = Setup();
        string codex = Folder(m, "codex");
        File.WriteAllText(Path.Combine(codex, "AGENTS.md"), content);
        Assert.Equal(125, Install(m, "--codex", "--codex-dir", codex));
        Assert.Contains("has a wslbin begin or end marker without its other half", m.Err, StringComparison.Ordinal);
        Assert.Equal(content, File.ReadAllText(Path.Combine(codex, "AGENTS.md")));
    }

    [Fact]
    public void A_skill_file_that_wslbin_did_not_write_is_left_alone_and_a_changed_one_is_updated()
    {
        using Machine m = Setup();
        string claude = Folder(m, "claude");
        string skill = Path.Combine(claude, "skills", "wslbin", "SKILL.md");
        Directory.CreateDirectory(Path.GetDirectoryName(skill)!);
        File.WriteAllText(skill, "my own skill\n");
        Assert.Equal(0, Install(m, "--claude-dir", claude));
        Assert.Contains($"left {skill} alone: it is not the one wslbin wrote", m.Out, StringComparison.Ordinal);
        Assert.Equal("my own skill\n", File.ReadAllText(skill));
        Assert.Equal(0, Install(m, "--remove", "--claude-dir", claude));
        Assert.True(File.Exists(skill));

        File.Delete(skill);
        Install(m, "--claude-dir", claude);
        File.AppendAllText(skill, "\nedited <!-- wslbin:managed -->");
        Assert.Equal(0, Install(m, "--claude-dir", claude));
        Assert.Contains($"updated {skill}", m.Out, StringComparison.Ordinal);
    }

    [Fact]
    public void A_read_only_file_is_reported_for_that_agent_and_the_run_goes_on()
    {
        using Machine m = Setup();
        string codex = Folder(m, "codex");
        string agents = Path.Combine(codex, "AGENTS.md");
        File.WriteAllText(agents, "mine\n");
        File.SetAttributes(agents, FileAttributes.ReadOnly);
        try
        {
            Assert.Equal(125, Install(m, "--codex", "--codex-dir", codex));
            Assert.Contains("Codex: ", m.Err, StringComparison.Ordinal);
            Assert.Contains("is read-only", m.Err, StringComparison.Ordinal);
        }
        finally
        {
            File.SetAttributes(agents, FileAttributes.Normal);
        }
        Assert.Equal("mine\n", File.ReadAllText(agents));
    }
}
