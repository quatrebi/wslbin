using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Wslbin.Tests;

// A minimal driver for a program that needs a real console: starts it in a Windows pseudo console (ConPTY,
// Windows 10 1809 and later), lets the test type into it and read what it prints.
internal sealed partial class ConPty : IDisposable
{
    const uint ExtendedStartupInfoPresent = 0x00080000;
    const int UseStdHandles = 0x00000100;
    static readonly nint PseudoConsoleAttribute = 0x00020016;

    [StructLayout(LayoutKind.Sequential)]
    readonly struct Coord(short x, short y)
    {
        readonly short x = x;
        readonly short y = y;

        public override string ToString() => $"{x},{y}";
    }

    // Only blittable fields (no strings), so that the structure reaches CreateProcess as it is laid out here.
    [StructLayout(LayoutKind.Sequential)]
    struct StartupInfo
    {
        public int Size;
        public nint Reserved;
        public nint Desktop;
        public nint Title;
        public int X, Y, XSize, YSize, XCountChars, YCountChars, FillAttribute, Flags;
        public short ShowWindow, Reserved2Size;
        public nint Reserved2, StdInput, StdOutput, StdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct StartupInfoEx
    {
        public StartupInfo Startup;
        public nint AttributeList;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct ProcessInformation
    {
        public nint Process, Thread;
        public int ProcessId, ThreadId;
    }

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CreatePipe(out SafeFileHandle read, out SafeFileHandle write, nint attributes, int size);

    [LibraryImport("kernel32.dll")]
    private static partial int CreatePseudoConsole(Coord size, SafeFileHandle input, SafeFileHandle output, uint flags, out nint console);

    [LibraryImport("kernel32.dll")]
    private static partial void ClosePseudoConsole(nint console);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool InitializeProcThreadAttributeList(nint list, int count, int flags, ref nint size);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool UpdateProcThreadAttribute(nint list, uint flags, nint attribute, nint value, nint size, nint previous, nint returned);

    [LibraryImport("kernel32.dll", EntryPoint = "CreateProcessW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CreateProcess(string? application, string commandLine, nint processAttributes, nint threadAttributes,
        [MarshalAs(UnmanagedType.Bool)] bool inheritHandles, uint creationFlags, nint environment, string? currentDirectory,
        ref StartupInfoEx startup, out ProcessInformation information);

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool TerminateProcess(nint process, uint exitCode);

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CloseHandle(nint handle);

    readonly object sync = new();
    readonly StringBuilder text = new();
    nint pseudoConsole;
    nint process;
    nint attributeList;
    FileStream? input;
    FileStream? output;
    volatile bool disposed;

    ConPty()
    {
    }

    public static ConPty Start(string commandLine, string workingDirectory, short columns, short rows)
    {
        var pty = new ConPty();
        if (!CreatePipe(out SafeFileHandle inRead, out SafeFileHandle inWrite, 0, 0) ||
            !CreatePipe(out SafeFileHandle outRead, out SafeFileHandle outWrite, 0, 0))
            throw new Win32Exception(Marshal.GetLastPInvokeError(), "CreatePipe failed");

        int hr = CreatePseudoConsole(new Coord(columns, rows), inRead, outWrite, 0, out pty.pseudoConsole);
        if (hr != 0) throw new InvalidOperationException($"CreatePseudoConsole failed: 0x{hr:x}");

        nint size = 0;
        InitializeProcThreadAttributeList(0, 1, 0, ref size);
        pty.attributeList = Marshal.AllocHGlobal(size);
        if (!InitializeProcThreadAttributeList(pty.attributeList, 1, 0, ref size))
            throw new Win32Exception(Marshal.GetLastPInvokeError(), "InitializeProcThreadAttributeList failed");
        if (!UpdateProcThreadAttribute(pty.attributeList, 0, PseudoConsoleAttribute, pty.pseudoConsole, nint.Size, 0, 0))
            throw new Win32Exception(Marshal.GetLastPInvokeError(), "UpdateProcThreadAttribute failed");

        var startup = new StartupInfoEx { AttributeList = pty.attributeList };
        startup.Startup.Size = Marshal.SizeOf<StartupInfoEx>();
        // If this process has redirected standard handles (as under a test runner), the child would write to them
        // instead of to the pseudo console. Naming no handles at all makes it use the console that it was given.
        startup.Startup.Flags = UseStdHandles;
        if (!CreateProcess(null, commandLine, 0, 0, false, ExtendedStartupInfoPresent, 0, workingDirectory, ref startup, out ProcessInformation info))
            throw new Win32Exception(Marshal.GetLastPInvokeError(), "CreateProcess failed");
        pty.process = info.Process;
        CloseHandle(info.Thread);

        // the other ends belong to the pseudo console now
        inRead.Dispose();
        outWrite.Dispose();
        pty.input = new FileStream(inWrite, FileAccess.Write, 4096, false);
        pty.output = new FileStream(outRead, FileAccess.Read, 4096, false);

        new Thread(pty.ReadLoop) { IsBackground = true }.Start();
        return pty;
    }

    void ReadLoop()
    {
        var buffer = new byte[4096];
        Decoder decoder = new UTF8Encoding(false).GetDecoder();
        var chars = new char[8192];
        try
        {
            while (!disposed)
            {
                int n = output!.Read(buffer, 0, buffer.Length);
                if (n <= 0) break;
                int count = decoder.GetChars(buffer, 0, n, chars, 0);
                var chunk = new string(chars, 0, count);
                lock (sync)
                {
                    text.Append(chunk);
                    Monitor.PulseAll(sync);
                }
                // The pseudo console asks where the cursor is, and may wait for the answer.
                if (chunk.Contains("\u001b[6n", StringComparison.Ordinal)) Write("\u001b[1;1R");
            }
        }
        catch (IOException)
        {
        }
        catch (ObjectDisposedException)
        {
        }
    }

    /// <summary>Everything printed so far, as raw terminal text (escape sequences included).</summary>
    public string Raw
    {
        get
        {
            lock (sync) return text.ToString();
        }
    }

    public void Write(string s)
    {
        byte[] bytes = new UTF8Encoding(false).GetBytes(s);
        lock (sync)
        {
            if (disposed) return;
            input!.Write(bytes, 0, bytes.Length);
            input.Flush();
        }
    }

    /// <summary>Waits until the output contains the text (after "from" characters), or the time is up.</summary>
    public bool WaitFor(string expected, TimeSpan timeout, int from)
    {
        var watch = Stopwatch.StartNew();
        lock (sync)
        {
            while (true)
            {
                if (text.Length > from && text.ToString().IndexOf(expected, from, StringComparison.Ordinal) >= 0) return true;
                TimeSpan left = timeout - watch.Elapsed;
                if (left <= TimeSpan.Zero) return false;
                Monitor.Wait(sync, left);
            }
        }
    }

    /// <summary>Waits for a time, without holding anything: what a person does between two keys.</summary>
    public static void Pause(TimeSpan time) => new ManualResetEventSlim(false).Wait(time);

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        if (process != 0)
        {
            TerminateProcess(process, 1);
            CloseHandle(process);
        }
        if (pseudoConsole != 0) ClosePseudoConsole(pseudoConsole);
        try { input?.Dispose(); } catch (IOException) { }
        try { output?.Dispose(); } catch (IOException) { }
        if (attributeList != 0) Marshal.FreeHGlobal(attributeList);
    }
}
