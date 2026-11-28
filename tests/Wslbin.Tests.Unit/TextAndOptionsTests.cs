using System.Text;

namespace Wslbin.Tests;

public class TextAndOptionsTests
{
    [Fact]
    public void Lines_drops_empty_lines_and_carriage_returns()
    {
        Assert.Equal(["a", "b", " c"], Text.Lines("a\r\n\r\nb\n\n c\r\n"));
        Assert.Empty(Text.Lines(""));
    }

    [Fact]
    public void Utf8_is_decoded_strictly_with_or_without_a_byte_order_mark()
    {
        Assert.Equal("h\u00E9", Text.DecodeUtf8([.. "h\u00E9"u8], out bool bom));
        Assert.False(bom);
        Assert.Equal("x", Text.DecodeUtf8([0xEF, 0xBB, 0xBF, (byte)'x'], out bom));
        Assert.True(bom);
        Assert.Null(Text.DecodeUtf8([0xD4, 0xE0], out _));
        Assert.Equal("\uFFFD\uFFFD", Text.DecodeUtf8([0xD4, 0xE0], out _, strict: false));
    }

    [Fact]
    public void A_file_is_written_all_or_nothing_and_keeps_its_byte_order_mark_if_asked()
    {
        using var m = new Machine();
        string path = Path.Combine(m.Dir, "f.txt");
        Text.WriteAllAtomic(path, "one");
        Assert.Equal("one"u8.ToArray(), File.ReadAllBytes(path));
        Text.WriteAllAtomic(path, "two", bom: true);
        Assert.Equal([0xEF, 0xBB, 0xBF, .. "two"u8], File.ReadAllBytes(path));
        Assert.Equal([path], Directory.GetFiles(m.Dir, "f.txt*"));
    }

    [Fact]
    public void A_read_only_file_is_refused_and_left_as_it_is()
    {
        using var m = new Machine();
        string path = Path.Combine(m.Dir, "ro.txt");
        File.WriteAllText(path, "keep");
        File.SetAttributes(path, FileAttributes.ReadOnly);
        try
        {
            Assert.Throws<UnauthorizedAccessException>(() => Text.WriteAllAtomic(path, "new"));
            Assert.Equal("keep", File.ReadAllText(path));
            Assert.Equal([path], Directory.GetFiles(m.Dir, "ro.txt*"));
        }
        finally
        {
            File.SetAttributes(path, FileAttributes.Normal);
        }
    }

    [Fact]
    public void A_symbolic_link_stays_a_link_and_the_file_it_points_to_is_written()
    {
        using var m = new Machine();
        string target = Path.Combine(m.Dir, "target.txt");
        string link = Path.Combine(m.Dir, "link.txt");
        File.WriteAllText(target, "old");
        try
        {
            File.CreateSymbolicLink(link, "target.txt");
        }
        catch (IOException)
        {
            return;                // no right to make links on this machine: nothing to check
        }
        Text.WriteAllAtomic(link, "new");
        Assert.NotNull(new FileInfo(link).LinkTarget);
        Assert.Equal("new", File.ReadAllText(target));
    }

    [Fact]
    public void Resources_are_built_into_the_program()
    {
        Assert.Contains("Usage", Resources.Text("wslbin.docs.en.help.txt"), StringComparison.Ordinal);
        Assert.Null(Resources.TryText("wslbin.nothing"));
        Assert.Contains("internal error", Assert.Throws<WslbinException>(() => Resources.Text("wslbin.nothing")).Message, StringComparison.Ordinal);
        Assert.DoesNotContain('\r', Resources.Text(Resources.CompleteScript));
        Assert.Contains("@EXE@", Resources.Text(Resources.PowerShellInit), StringComparison.Ordinal);
        Assert.StartsWith(Init.ClinkScriptMark, Resources.Text(Resources.ClinkInit), StringComparison.Ordinal);
    }

    [Fact]
    public void Native_versions_name_a_package_for_a_utility()
    {
        Dictionary<string, string> native = NativeVersions.Load();
        Assert.NotEmpty(native);
        Assert.All(native, kv => Assert.DoesNotContain(' ', kv.Value));
        // names compare without case
        string first = native.Keys.First();
        Assert.True(native.ContainsKey(first.ToUpperInvariant()));
    }

    // ---- options of wslbin's own commands ----

    [Fact]
    public void Options_collect_flags_folders_and_words()
    {
        var o = Options.Parse(["-y", "jq", "--dry-run", "yq"], "--link", ["-y", "--yes", "--dry-run"], words: true);
        Assert.True(o.Has("-y"));
        Assert.True(o.Has("--dry-run"));
        Assert.False(o.Has("--yes"));
        Assert.Equal(["jq", "yq"], o.Words);

        var f = Options.Parse(["--dir", @"C:\x", "--remove"], "--cmd", ["--remove"], folders: ["--dir"]);
        Assert.Equal(@"C:\x", f.Value("--dir"));
        Assert.Null(f.Value("--other"));
    }

    [Theory]
    [InlineData(new[] { "-z" }, "unknown option -z for --link")]
    [InlineData(new[] { "--dir" }, "--dir needs a folder")]
    public void Options_refuse_what_they_do_not_know(string[] args, string message)
    {
        var ex = Assert.Throws<WslbinException>(() =>
            Options.Parse(args, "--link", ["-y"], folders: ["--dir"], words: true));
        Assert.Equal(message, ex.Message);
    }

    [Fact]
    public void A_word_is_refused_where_none_is_allowed_and_none_takes_nothing()
    {
        Assert.Equal("unknown option x for --list", Assert.Throws<WslbinException>(() => Options.Parse(["x"], "--list", [])).Message);
        Assert.Equal("--version takes no arguments", Assert.Throws<WslbinException>(() => Options.None(["x"], "--version")).Message);
        Options.None([], "--version");
    }
}
