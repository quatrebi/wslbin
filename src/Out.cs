// wslbin: output to the console and to pipes.

using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace Wslbin
{
    // The console code page (OEM by default) cannot hold every character of an argument. When the
    // output goes to a file or a pipe it is written as UTF-8, which is also what bash reads.
    internal static class Out
    {
        public static void Info(string text)
        {
            Write(false, text);
        }

        public static void Error(string text)
        {
            Write(true, text);
        }

        public static void Warn(string text)
        {
            Write(true, "wslbin: warning: " + text);
        }

        // The console is written to in UTF-16, which any code page of the console can show; going
        // through Console.Out would turn what the code page lacks (Cyrillic under 437) into "?".
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr GetStdHandle(int standardHandle);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool WriteConsoleW(IntPtr console, string buffer, int length, out int written, IntPtr reserved);

        // Writes the text and a line break to the console; returns what is left when that fails part way
        // (all of it when there is no console), or null when it is all written.
        static string WriteToConsole(bool toError, string text)
        {
            string line = text.Replace("\r\n", "\n").Replace("\n", "\r\n") + "\r\n";
            IntPtr handle = GetStdHandle(toError ? -12 : -11);
            if (handle == IntPtr.Zero || handle == new IntPtr(-1)) return line;
            int i = 0;
            while (i < line.Length)
            {
                int length = Math.Min(8192, line.Length - i);
                // a chunk must not end between the two halves of a surrogate pair
                if (i + length < line.Length && char.IsHighSurrogate(line[i + length - 1])) length--;
                int written;
                if (!WriteConsoleW(handle, line.Substring(i, length), length, out written, IntPtr.Zero)) return line.Substring(i);
                i += length;
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
                    string rest = WriteToConsole(toError, text);
                    if (rest != null) (toError ? Console.Error : Console.Out).Write(rest);
                    return;
                }
                byte[] bytes = new UTF8Encoding(false).GetBytes(text + "\n");
                Stream stream = toError ? Console.OpenStandardError() : Console.OpenStandardOutput();
                stream.Write(bytes, 0, bytes.Length);
                stream.Flush();
            }
            catch (IOException)
            {
                // the reader has gone (wslbin --list | Select-Object -First 1): there is no one to tell
            }
        }
    }
}
