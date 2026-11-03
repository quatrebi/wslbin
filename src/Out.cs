// wslbin: output to the console and to pipes.

using System.Runtime.InteropServices;
using System.Text;

namespace Wslbin;

// The console code page (OEM by default) cannot hold every character of an argument. When the
// output goes to a file or a pipe it is written as UTF-8, which is also what bash reads.
internal static partial class Out
{
    const int StdOutput = -11;
    const int StdError = -12;
    const int Chunk = 8192;

    public static void Info(string text) => Write(false, text);

    public static void Error(string text) => Write(true, text);

    /// <summary>A line of wslbin's own on standard error: "wslbin: text".</summary>
    public static void Fail(string text) => Write(true, $"wslbin: {text}");

    public static void Warn(string text) => Write(true, $"wslbin: warning: {text}");

    // The console is written to in UTF-16, which any code page of the console can show; going
    // through Console.Out would turn what the code page lacks (Cyrillic under 437) into "?".
    [LibraryImport("kernel32.dll", SetLastError = true)]
    private static partial nint GetStdHandle(int standardHandle);

    [LibraryImport("kernel32.dll", EntryPoint = "WriteConsoleW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool WriteConsole(nint console, string buffer, int length, out int written, nint reserved);

    // Writes the text and a line break to the console; returns what is left when that fails part way
    // (all of it when there is no console), or null when it is all written.
    static string? WriteToConsole(bool toError, string text)
    {
        string line = text.Replace("\r\n", "\n").Replace("\n", "\r\n") + "\r\n";
        nint handle = GetStdHandle(toError ? StdError : StdOutput);
        if (handle is 0 or -1) return line;
        int i = 0;
        while (i < line.Length)
        {
            int length = Math.Min(Chunk, line.Length - i);
            // a chunk must not end between the two halves of a surrogate pair
            if (i + length < line.Length && char.IsHighSurrogate(line[i + length - 1])) length--;
            if (!WriteConsole(handle, line.Substring(i, length), length, out int written, 0) || written <= 0) return line[i..];
            i += written;
        }
        return null;
    }

    static void Write(bool toError, string text)
    {
        try
        {
            bool redirected = toError ? Console.IsErrorRedirected : Console.IsOutputRedirected;
            if (!redirected)
            {
                if (WriteToConsole(toError, text) is string rest) (toError ? Console.Error : Console.Out).Write(rest);
                return;
            }
            byte[] bytes = Encoding.UTF8.GetBytes(text + "\n");
            using Stream stream = toError ? Console.OpenStandardError() : Console.OpenStandardOutput();
            stream.Write(bytes);
            stream.Flush();
        }
        catch (IOException)
        {
            // the reader has gone (wslbin --list | Select-Object -First 1): there is no one to tell
        }
    }
}
