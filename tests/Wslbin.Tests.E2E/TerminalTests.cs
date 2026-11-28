using System.Text.RegularExpressions;

namespace Wslbin.Tests;

// Interactive use: what a wrapper does when a person sits at the terminal. A real cmd.exe runs in a Windows pseudo
// console (ConPty.cs) and the test types into it: the utility must see a terminal of the size of the window, take what
// is typed, show colours, and give up on Ctrl+C without leaving anything behind.
public sealed partial class TerminalTests(ExeFixture fixture) : IDisposable
{
    const string Prompt = "@@@>";
    static readonly TimeSpan Wait = TimeSpan.FromSeconds(10);

    ConPty? pty;

    [GeneratedRegex(@"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\r")]
    private static partial Regex Escapes();

    static string Plain(string raw) => Escapes().Replace(raw, "");

    // the lines that a command printed, without the echo of the typed line and without the prompt
    static List<string> Lines(string raw) =>
        [.. Plain(raw).Split('\n').Where(l => l.Trim().Length > 0 && !l.StartsWith(Prompt, StringComparison.Ordinal)).Skip(1)];

    ConPty Session()
    {
        Wsl.Require();
        if (pty != null) return pty;
        string dir = Runner.NewDir(fixture);
        Runner.Place(fixture, "wslbin", dir: dir);
        pty = ConPty.Start("cmd.exe /d /q", dir, 100, 30);
        Assert.True(pty.WaitFor(">", Wait, 0));
        ConPty.Pause(TimeSpan.FromMilliseconds(500));
        pty.Write($"set \"PATH={dir};%PATH%\"\r");
        ConPty.Pause(TimeSpan.FromMilliseconds(400));
        pty.Write("prompt @@@$G\r");
        ConPty.Pause(TimeSpan.FromMilliseconds(600));
        return pty;
    }

    string InSession(string line)
    {
        ConPty p = Session();
        int mark = p.Raw.Length;
        p.Write(line + "\r");
        p.WaitFor(Prompt, Wait, mark + line.Length);
        ConPty.Pause(TimeSpan.FromMilliseconds(300));
        return p.Raw[mark..];
    }

    [Fact]
    public void The_utility_gets_a_terminal_of_the_size_of_the_window_on_all_three_streams()
    {
        List<string> lines = Lines(InSession("wslbin -c \"tty; stty size; test -t 0 && test -t 1 && test -t 2 && echo all-three\""));
        Assert.Matches(@"^/dev/pts/\d+$", lines[0]);
        Assert.Equal("30 100", lines[1].TrimEnd());
        Assert.Contains("all-three", lines);
    }

    [Fact]
    public void What_is_typed_reaches_the_utility_and_colours_come_through()
    {
        ConPty p = Session();
        int mark = p.Raw.Length;
        p.Write("wslbin -c \"read -p 'name: ' n; echo hello-$n\"\r");
        p.WaitFor("name: ", Wait, mark + 20);
        ConPty.Pause(TimeSpan.FromMilliseconds(300));
        p.Write("Anna\r");
        p.WaitFor(Prompt, Wait, mark + 60);
        ConPty.Pause(TimeSpan.FromMilliseconds(300));
        Assert.Contains("hello-Anna", Plain(p.Raw[mark..]), StringComparison.Ordinal);

        Assert.Matches(@"\x1b\[[0-9;]*mRED", InSession("wslbin -c \"printf '\\e[31mRED\\e[0m plain\\n'\""));
    }

    [Fact]
    public void Ctrl_C_stops_the_utility_at_once_gives_its_exit_code_and_leaves_the_wrapper_working()
    {
        ConPty p = Session();
        int mark = p.Raw.Length;
        p.Write("wslbin sleep 60\r");
        ConPty.Pause(TimeSpan.FromMilliseconds(2500));
        p.Write("\u0003");
        Assert.True(p.WaitFor(Prompt, Wait, mark + 20));
        ConPty.Pause(TimeSpan.FromMilliseconds(500));
        // wsl.exe reports a utility that a signal ended as the number of the signal (2 for Ctrl+C)
        Assert.Contains("code=2", Lines(InSession("echo code=%errorlevel%")));
        Assert.Contains("still-works", Lines(InSession("wslbin -c \"echo still-works\"")));
    }

    public void Dispose() => pty?.Dispose();
}
