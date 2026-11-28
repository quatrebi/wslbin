// wslbin: output to the console and to pipes.

namespace Wslbin;

// Lines of wslbin's own. The console itself (UTF-16 to a console whatever its code page, UTF-8 to a file or a
// pipe, which is also what bash reads) is behind the host: Host.cs.
internal static class Out
{
    public static void Info(string text) => Host.Current.Write(false, text);

    public static void Error(string text) => Host.Current.Write(true, text);

    /// <summary>A line of wslbin's own on standard error: "wslbin: text".</summary>
    public static void Fail(string text) => Host.Current.Write(true, $"wslbin: {text}");

    public static void Warn(string text) => Host.Current.Write(true, $"wslbin: warning: {text}");
}
