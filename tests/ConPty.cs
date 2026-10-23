// A minimal driver for a program that needs a real console: starts it in a Windows pseudo console
// (ConPTY, Windows 10 1809 and later), lets the test type into it and read what it prints. Used by
// tests/clink.Tests.ps1 to press Tab in a cmd.exe that has Clink in it. Loaded with Add-Type -Path.
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

public sealed class ConPty : IDisposable
{
    const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    const int STARTF_USESTDHANDLES = 0x00000100;
    static readonly IntPtr PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = (IntPtr)0x00020016;

    [StructLayout(LayoutKind.Sequential)]
    struct COORD
    {
        public short X;
        public short Y;
        public COORD(short x, short y) { X = x; Y = y; }
    }

    // Only blittable fields (no strings), so that the structure reaches CreateProcess as it is laid out here.
    [StructLayout(LayoutKind.Sequential)]
    struct STARTUPINFO
    {
        public int cb;
        public IntPtr lpReserved;
        public IntPtr lpDesktop;
        public IntPtr lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct STARTUPINFOEX
    {
        public STARTUPINFO StartupInfo;
        public IntPtr lpAttributeList;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION
    {
        public IntPtr hProcess, hThread;
        public int dwProcessId, dwThreadId;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CreatePipe(out SafeFileHandle hReadPipe, out SafeFileHandle hWritePipe, IntPtr lpPipeAttributes, int nSize);
    [DllImport("kernel32.dll")]
    static extern int CreatePseudoConsole(COORD size, SafeFileHandle hInput, SafeFileHandle hOutput, uint dwFlags, out IntPtr phPC);
    [DllImport("kernel32.dll")]
    static extern void ClosePseudoConsole(IntPtr hPC);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool InitializeProcThreadAttributeList(IntPtr lpAttributeList, int dwAttributeCount, int dwFlags, ref IntPtr lpSize);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool UpdateProcThreadAttribute(IntPtr lpAttributeList, uint dwFlags, IntPtr attribute, IntPtr lpValue, IntPtr cbSize, IntPtr lpPreviousValue, IntPtr lpReturnSize);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcess(string lpApplicationName, string lpCommandLine, IntPtr lpProcessAttributes, IntPtr lpThreadAttributes,
        bool bInheritHandles, uint dwCreationFlags, IntPtr lpEnvironment, string lpCurrentDirectory,
        ref STARTUPINFOEX lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);
    [DllImport("kernel32.dll")]
    static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr handle);

    readonly object sync = new object();
    readonly StringBuilder text = new StringBuilder();
    IntPtr pseudoConsole;
    IntPtr process;
    IntPtr attributeList;
    FileStream input;
    FileStream output;
    Thread reader;
    volatile bool disposed;

    ConPty() { }

    public static ConPty Start(string commandLine, string workingDirectory, short columns, short rows)
    {
        var pty = new ConPty();
        SafeFileHandle inRead, inWrite, outRead, outWrite;
        if (!CreatePipe(out inRead, out inWrite, IntPtr.Zero, 0) || !CreatePipe(out outRead, out outWrite, IntPtr.Zero, 0))
            throw new InvalidOperationException("CreatePipe failed: " + Marshal.GetLastWin32Error());

        int hr = CreatePseudoConsole(new COORD(columns, rows), inRead, outWrite, 0, out pty.pseudoConsole);
        if (hr != 0) throw new InvalidOperationException("CreatePseudoConsole failed: 0x" + hr.ToString("x"));

        IntPtr size = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
        pty.attributeList = Marshal.AllocHGlobal(size);
        if (!InitializeProcThreadAttributeList(pty.attributeList, 1, 0, ref size))
            throw new InvalidOperationException("InitializeProcThreadAttributeList failed: " + Marshal.GetLastWin32Error());
        if (!UpdateProcThreadAttribute(pty.attributeList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, pty.pseudoConsole,
                (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero))
            throw new InvalidOperationException("UpdateProcThreadAttribute failed: " + Marshal.GetLastWin32Error());

        var startup = new STARTUPINFOEX();
        startup.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
        startup.lpAttributeList = pty.attributeList;
        // If this process has redirected standard handles (as under a test runner), the child would
        // write to them instead of to the pseudo console. Naming no handles at all makes it use
        // the console that it was given.
        startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
        PROCESS_INFORMATION info;
        if (!CreateProcess(null, commandLine, IntPtr.Zero, IntPtr.Zero, false, EXTENDED_STARTUPINFO_PRESENT,
                IntPtr.Zero, workingDirectory, ref startup, out info))
            throw new InvalidOperationException("CreateProcess failed: " + Marshal.GetLastWin32Error());
        pty.process = info.hProcess;
        CloseHandle(info.hThread);

        // the other ends belong to the pseudo console now
        inRead.Dispose();
        outWrite.Dispose();
        pty.input = new FileStream(inWrite, FileAccess.Write, 4096, false);
        pty.output = new FileStream(outRead, FileAccess.Read, 4096, false);

        pty.reader = new Thread(pty.ReadLoop);
        pty.reader.IsBackground = true;
        pty.reader.Start();
        return pty;
    }

    void ReadLoop()
    {
        var buffer = new byte[4096];
        var decoder = new UTF8Encoding(false).GetDecoder();
        var chars = new char[8192];
        try
        {
            while (!disposed)
            {
                int n = output.Read(buffer, 0, buffer.Length);
                if (n <= 0) break;
                int count = decoder.GetChars(buffer, 0, n, chars, 0);
                string chunk = new string(chars, 0, count);
                lock (sync) { text.Append(chunk); }
                // The pseudo console asks where the cursor is, and may wait for the answer.
                if (chunk.IndexOf("\u001b[6n", StringComparison.Ordinal) >= 0) Write("\u001b[1;1R");
            }
        }
        catch (IOException) { }
        catch (ObjectDisposedException) { }
    }

    // Everything printed so far, as raw terminal text (escape sequences included).
    public string Raw
    {
        get { lock (sync) { return text.ToString(); } }
    }

    public void Write(string s)
    {
        byte[] bytes = new UTF8Encoding(false).GetBytes(s);
        lock (sync)
        {
            if (disposed) return;
            input.Write(bytes, 0, bytes.Length);
            input.Flush();
        }
    }

    // Waits until the output contains the text (after "from" characters), or the time is up.
    public bool WaitFor(string expected, int timeoutMilliseconds, int from)
    {
        DateTime end = DateTime.UtcNow.AddMilliseconds(timeoutMilliseconds);
        while (DateTime.UtcNow < end)
        {
            string snapshot = Raw;
            if (snapshot.Length > from && snapshot.IndexOf(expected, from, StringComparison.Ordinal) >= 0) return true;
            Thread.Sleep(50);
        }
        return false;
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        if (process != IntPtr.Zero) { TerminateProcess(process, 1); CloseHandle(process); }
        if (pseudoConsole != IntPtr.Zero) ClosePseudoConsole(pseudoConsole);
        try { if (input != null) input.Dispose(); } catch (IOException) { }
        try { if (output != null) output.Dispose(); } catch (IOException) { }
        if (attributeList != IntPtr.Zero) Marshal.FreeHGlobal(attributeList);
    }
}
