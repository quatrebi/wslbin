using System.Diagnostics;
using System.Text;

namespace Wslbin.Tests;

// The command line that the program hands to wsl.exe, read back as wsl.exe and bash read it, with the bash of Git for
// Windows (GitHub's Windows runners have it): every argument must come out as it went in (Launcher.AppendWindowsArg and
// the handling of empty arguments), and the guard in front of the script must refuse a folder that WSL could not enter.
// Without Git Bash the tests are skipped, unless WSLBIN_REQUIRE_TOOLS=1.
public class GitBashTests
{
    static readonly Lazy<string?> BashPath = new(FindBash);

    static readonly string[] Nasty =
    [
        "plain", "a b", "x;echo pwned", "$(id)", "$HOME", "`uname`", "{print $1, $2}", "it's", "say \"hi\"",
        @"back\slash", @"trail\", @"two\\", "\\\"", "a|b&c", "a>b<c", "#hash", "!bang", "~tilde-mid", "a~b",
        "", " ", "tab\there", "line1\nline2", "%PATH%", "^caret", "(paren)", "{a,b}", "[bracket",
        "--opt=value with spaces", "[[:$(id):]]", "\u0444 \u0430\u0439\u043B", "x\u0001y"
    ];

    static string Bash()
    {
        if (BashPath.Value is string path) return path;
        if (Environment.GetEnvironmentVariable("WSLBIN_REQUIRE_TOOLS") == "1")
            Assert.Fail("Git Bash was not found, and WSLBIN_REQUIRE_TOOLS=1 says that it must be there");
        Assert.Skip("Git Bash (bash.exe of Git for Windows) was not found");
        return "";
    }

    // never the bash of PATH: that may be System32\bash.exe, which is WSL
    static string? FindBash()
    {
        try
        {
            var psi = new ProcessStartInfo("git", "--exec-path") { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
            using Process p = Process.Start(psi)!;
            string execPath = p.StandardOutput.ReadToEnd().Trim();
            p.WaitForExit();
            if (p.ExitCode == 0 && execPath.Length > 0)
            {
                foreach (string up in new[] { @"..\..\..\bin\bash.exe", @"..\..\bin\bash.exe" })
                {
                    string candidate = Path.GetFullPath(Path.Combine(execPath.Replace('/', '\\'), up));
                    if (File.Exists(candidate)) return candidate;
                }
            }
        }
        catch (System.ComponentModel.Win32Exception)
        {
            // no git in PATH
        }
        foreach (string? root in new[] { Environment.GetEnvironmentVariable("ProgramFiles"), Environment.GetEnvironmentVariable("ProgramFiles(x86)") })
        {
            if (string.IsNullOrEmpty(root)) continue;
            string candidate = Path.Combine(root, "Git", "bin", "bash.exe");
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }

    // What wsl.exe does with its command line: bash --noprofile --norc -c <script> <positional parameters>. The words go
    // through a file and an exec inside bash, not through the command line of Git Bash: the MSYS runtime reads a Windows
    // command line by rules of its own, and that is not what is under test.
    static (int ExitCode, string Out, string Err) AsWsl(WindowsCommandLineWords words, string folder, string home)
    {
        string handed = Path.Combine(folder, "handed.bin");
        File.WriteAllText(handed, string.Concat(new[] { words.Script }.Concat(words.Positional).Select(w => w + "\0")), new UTF8Encoding(false));
        var psi = new ProcessStartInfo(Bash())
        {
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = folder,
            StandardInputEncoding = new UTF8Encoding(false),
            StandardOutputEncoding = new UTF8Encoding(false),
            StandardErrorEncoding = new UTF8Encoding(false)
        };
        foreach (string a in new[] { "--noprofile", "--norc", "-s" }) psi.ArgumentList.Add(a);
        psi.Environment["HOME"] = home;
        using Process p = Process.Start(psi)!;
        Task<string> err = p.StandardError.ReadToEndAsync();
        Task<string> output = p.StandardOutput.ReadToEndAsync();
        p.StandardInput.Write("mapfile -d \"\" w < handed.bin; exec bash --noprofile --norc -c \"${w[0]}\" \"${w[@]:1}\"" + (char)10);
        p.StandardInput.Close();
        p.WaitForExit();
        return (p.ExitCode, output.Result, err.Result);
    }

    sealed record WindowsCommandLineWords(string Script, List<string> Positional);

    static WindowsCommandLineWords Words(Machine m)
    {
        List<string> args = WindowsCommandLine.Split(Assert.Single(m.Fake.ConsoleRuns).Arguments);
        int c = args.IndexOf("-c");
        return new(args[c + 1], [.. args.Skip(c + 2)]);
    }

    static List<string> Split(string output)
    {
        List<string> got = [.. output.Split('\0')];
        got.RemoveAt(got.Count - 1);
        return got;
    }

    [Fact]
    public void The_arguments_of_a_raw_wrapper_come_out_of_bash_as_typed()
    {
        Bash();
        using var m = new Machine();
        var random = new Random(4242);
        const string Alphabet = " \t\"\\\\'$*?[]{}();|&<>~`#%=,:@/.\n\u044F";
        List<string> sent = [.. Nasty];
        for (int i = 0; i < 200; i++)
            sent.Add(string.Create(random.Next(1, 13), random, (span, r) => { for (int k = 0; k < span.Length; k++) span[k] = Alphabet[r.Next(Alphabet.Length)]; }));
        Assert.Equal(0, m.Run("printf", ["--wslbin-raw", @"%s\0", .. sent]));
        // HOME elsewhere: the guard at the start of the script must see that bash is in the folder
        string other = Path.Combine(m.Dir, "other-home");
        Directory.CreateDirectory(other);
        (int code, string output, string err) = AsWsl(Words(m), m.Dir, other);
        Assert.True(code == 0, err);
        Assert.Equal(sent, Split(output));
    }

    [Fact]
    public void The_positional_parameters_of_wslbin_c_come_out_as_typed_and_empty_ones_stay_empty()
    {
        Bash();
        using var m = new Machine();
        Assert.Equal(0, m.Run("wslbin", ["-c", "printf \"%s\\0\" \"$0\" \"$@\"", "", .. Nasty]));
        string other = Path.Combine(m.Dir, "other-home");
        Directory.CreateDirectory(other);
        (int code, string output, string err) = AsWsl(Words(m), m.Dir, other);
        Assert.True(code == 0, err);
        Assert.Equal(["", .. Nasty], Split(output));
    }

    [Fact]
    public void The_command_is_not_run_when_bash_started_in_the_home_folder_instead_of_the_folder()
    {
        Bash();
        using var m = new Machine();
        Assert.Equal(0, m.Run("printf", "%s", "ran"));
        WindowsCommandLineWords words = Words(m);

        // HOME is the folder: bash "started in the home folder", which is what WSL does with a drive it has not mounted
        (int code, string output, string err) = AsWsl(words, m.Dir, m.Dir);
        Assert.Equal(125, code);
        Assert.Matches("wslbin: WSL cannot enter .* it was not run", err);
        Assert.Equal("", output);

        string other = Path.Combine(m.Dir, "other-home");
        Directory.CreateDirectory(other);
        (code, output, err) = AsWsl(words, m.Dir, other);
        Assert.True(code == 0, err);
        Assert.Equal("ran", output);
    }
}
