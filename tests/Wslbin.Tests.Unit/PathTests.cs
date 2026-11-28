namespace Wslbin.Tests;

public class PathTests
{
    public static TheoryData<string, string> TranslatedCases => new()
    {
        { @"C:\x\y", "/mnt/c/x/y" },
        { "c:/x/y", "/mnt/c/x/y" },
        { @"C:\x/y\z", "/mnt/c/x/y/z" },
        { @"C:\", "/mnt/c/" },
        { @"C:\backup\", "/mnt/c/backup/" },
        { @"D:\a b\c", @"/mnt/d/a\ b/c" },
        { @"C:\proj\*.log", "/mnt/c/proj/*.log" },
        { @"--file=D:\a", "--file=/mnt/d/a" },
        { @"OUT=C:\out", "OUT=/mnt/c/out" },
        { @"-IC:\inc", "-I/mnt/c/inc" },
        { @"\\?\C:\long\path", "/mnt/c/long/path" },
        { @"\\wsl.localhost\Ubuntu\home\u\f", "/home/u/f" },
        { @"\\wsl$\Ubuntu\etc\hosts", "/etc/hosts" },
        { @"\\wsl.localhost\Ubuntu", "/" },
        // not paths, or not absolute: left alone (and escaped like any other text)
        { @"src\main.c", @"src\\main.c" },
        { @".\a", @".\\a" },
        { "https://example.com/a", "https://example.com/a" },
        { "s:a:b:", "s:a:b:" },
        { "C:", "C:" },
        { @"-C:\x", @"-C:\\x" },
        { "--name=C:", "--name=C:" },
        { @"--k=v=C:\x", @"--k=v=C:\\x" },
        { "-Ifoo", "-Ifoo" },
    };

    [Theory]
    [MemberData(nameof(TranslatedCases))]
    public void A_Windows_path_becomes_the_path_Linux_sees(string arg, string want)
    {
        using var m = new Machine();
        // a path under \\wsl.localhost is translated only in the distribution wslbin runs in: named here
        Assert.Equal($"tool {want}", m.Explain("tool", [arg], ini: "distro = Ubuntu\n"));
    }

    [Fact]
    public void A_network_path_is_left_alone_with_a_warning()
    {
        using var m = new Machine();
        Assert.Equal(@"tool \\\\server\\share\\x", m.Explain(@"\\server\share\x"));
        Assert.Contains("network path", m.Err, StringComparison.Ordinal);
    }

    [Fact]
    public void A_path_relative_to_a_drive_is_left_alone_with_a_warning()
    {
        using var m = new Machine();
        Assert.Equal("tool C:x", m.Explain("C:x"));
        Assert.Contains("relative to a drive", m.Err, StringComparison.Ordinal);
    }

    [Fact]
    public void Arguments_like_those_of_sed_get_no_warning()
    {
        using var m = new Machine();
        m.Explain("s:a:b:");
        Assert.Equal("", m.Err);
    }

    [Fact]
    public void A_path_of_another_distribution_is_left_alone_when_a_distribution_is_configured()
    {
        using var m = new Machine();
        string script = m.Explain("tool", [@"\\wsl.localhost\Other\x", @"\\wsl.localhost\ubuntu\x"], ini: "distro = Ubuntu");
        Assert.Equal(@"tool \\\\wsl.localhost\\Other\\x /x", script);
        Assert.Contains("distribution 'Other'", m.Err, StringComparison.Ordinal);
    }

    [Fact]
    public void Without_a_configured_distribution_the_default_one_of_the_registry_counts()
    {
        using var m = new Machine();
        m.Fake.DefaultDistributionValue = "Debian";
        Assert.Equal("tool /x", m.Explain(@"\\wsl.localhost\Debian\x"));
        Assert.Equal(@"tool \\\\wsl.localhost\\Ubuntu\\x", m.Explain(@"\\wsl.localhost\Ubuntu\x"));
    }

    [Fact]
    public void A_UNC_path_without_a_distribution_is_left_alone()
    {
        using var m = new Machine();
        Assert.Equal(@"tool \\\\wsl.localhost\\", m.Explain(@"\\wsl.localhost\"));
        Assert.Contains("names no distribution", m.Err, StringComparison.Ordinal);
    }

    // ---- relative paths: translated only when they exist in the folder the child starts in ----

    static Machine WithFolders()
    {
        var m = new Machine();
        Directory.CreateDirectory(Path.Combine(m.Dir, "sub dir"));
        File.WriteAllText(Path.Combine(m.Dir, "a.txt"), "x\n");
        File.WriteAllText(Path.Combine(m.Dir, "sub dir", "b.c"), "x\n");
        return m;
    }

    [Theory]
    [InlineData(@".\a.txt", "tool ./a.txt")]
    [InlineData(@".\sub dir", @"tool ./sub\ dir")]
    [InlineData(@".\sub dir\", @"tool ./sub\ dir/")]
    [InlineData(@".\sub dir\b.c", @"tool ./sub\ dir/b.c")]
    [InlineData(@"sub dir\b.c", @"tool sub\ dir/b.c")]
    [InlineData(@".\sub dir\..\a.txt", @"tool ./sub\ dir/../a.txt")]
    [InlineData(@"--file=.\a.txt", "tool --file=./a.txt")]
    [InlineData(@"OUT=.\sub dir\b.c", @"tool OUT=./sub\ dir/b.c")]
    [InlineData(@"-I.\sub dir", @"tool -I./sub\ dir")]
    public void A_relative_path_that_exists_becomes_a_Linux_one(string arg, string want)
    {
        using Machine m = WithFolders();
        Assert.Equal(want, m.Explain(arg));
    }

    [Fact]
    public void Dot_dot_is_looked_up_from_the_folder_the_child_starts_in()
    {
        using Machine m = WithFolders();
        m.Fake.Cwd = Path.Combine(m.Dir, "sub dir");
        Assert.Equal("tool ../a.txt", m.Explain(@"..\a.txt"));
        Assert.Equal("tool ../", m.Explain(@"..\"));
    }

    [Theory]
    [InlineData(@".\d+", @"tool .\\d+")]
    [InlineData(@".\new.txt", @"tool .\\new.txt")]
    [InlineData(@".\*.txt", @"tool .\\*.txt")]
    [InlineData(@".\sub dir\new", @"tool .\\sub\ dir\\new")]
    [InlineData(@"--file=.\new", @"tool --file=.\\new")]
    [InlineData(@"\a.txt", @"tool \\a.txt")]
    [InlineData(@"\sub dir\b.c", @"tool \\sub\ dir\\b.c")]
    [InlineData(@"~\a.txt", @"tool ~\\a.txt")]
    [InlineData("a.txt:stream", "tool a.txt:stream")]
    // Windows would look past spaces and dots at the ends of a name (" \" is the root, "a.txt." is a.txt)
    [InlineData(@" \", @"tool \ \\")]
    [InlineData(@"--k= \", @"tool --k=\ \\")]
    [InlineData(@" .\a.txt", @"tool \ .\\a.txt")]
    [InlineData(@".\a.txt ", @"tool .\\a.txt\ ")]
    [InlineData(@".\a.txt.", @"tool .\\a.txt.")]
    [InlineData(@".\sub dir.\b.c", @"tool .\\sub\ dir.\\b.c")]
    [InlineData(@".\ \", @"tool .\\\ \\")]
    public void A_relative_path_that_does_not_exist_is_left_as_typed(string arg, string want)
    {
        using Machine m = WithFolders();
        Assert.Equal(want, m.Explain(arg));
    }

    [Fact]
    public void The_folder_of_the_child_decides_not_the_folder_where_a_file_of_that_name_happens_to_be()
    {
        using Machine m = WithFolders();
        string elsewhere = Path.Combine(m.Dir, "elsewhere");
        Directory.CreateDirectory(elsewhere);
        m.Fake.Cwd = elsewhere;
        Assert.Equal(@"tool .\\a.txt", m.Explain(@".\a.txt"));
    }

    [Fact]
    public void Sh_translates_and_raw_never_does()
    {
        using Machine m = WithFolders();
        Assert.Equal("tool ./a.txt", m.Explain("tool", [@".\a.txt"], flags: ["--wslbin-sh"]));
        Assert.Equal(@"tool '.\a.txt'", m.Explain("tool", [@".\a.txt"], flags: ["--wslbin-raw"]));
    }

    [Fact]
    public void Nothing_is_said_on_standard_error_about_relative_paths()
    {
        using Machine m = WithFolders();
        m.Explain(@".\a.txt", @".\nope");
        Assert.Equal("", m.Err);
    }

    [Theory]
    [InlineData("\u0001")]
    [InlineData("\"")]
    [InlineData("|")]
    [InlineData("?")]
    [InlineData("nul")]
    [InlineData("con")]
    public void Names_that_Windows_cannot_have_as_files_do_not_trip_the_check(string name)
    {
        using Machine m = WithFolders();
        string script = m.Explain(@".\" + name);
        Assert.DoesNotContain("./", script, StringComparison.Ordinal);
    }

    [Fact]
    public void A_folder_with_no_Linux_path_translates_no_relative_path_and_cannot_run_a_command()
    {
        using Machine m = WithFolders();
        m.Fake.Cwd = @"\\server\share\dir";
        Assert.Equal(@"tool .\\a.txt", m.Explain(@".\a.txt"));
        Assert.Contains("has no Linux path", Folder.Problem(m.Config()), StringComparison.Ordinal);
    }

    // ---- the value of a variable of pass_env ----

    [Theory]
    [InlineData(@"C:\x\y", "/mnt/c/x/y")]
    [InlineData(@"C:\a;D:\b c", "/mnt/c/a:/mnt/d/b c")]
    [InlineData(@"C:\a;not-a-path", @"C:\a;not-a-path")]
    [InlineData("hello", "hello")]
    [InlineData(@"..\rel", @"..\rel")]
    [InlineData(";;", ";;")]
    public void A_variable_value_is_translated_only_when_it_is_a_path_or_a_list_of_paths(string value, string want)
    {
        using var m = new Machine();
        Assert.Equal(want, Paths.TranslateEnvValue(value, m.Config()));
    }

    [Fact]
    public void The_distribution_of_a_wsl_path_is_named()
    {
        Assert.Equal("Debian", Paths.DistributionOf(@"\\wsl.localhost\Debian\x"));
        Assert.Equal("Debian", Paths.DistributionOf(@"\\wsl$\Debian"));
        Assert.Null(Paths.DistributionOf(@"\\server\share"));
        Assert.Null(Paths.DistributionOf(@"C:\x"));
        Assert.Null(Paths.DistributionOf(@"\\wsl.localhost\"));
    }
}
