// A stand-in for wsl.exe, for tests of what wslbin does when WSL answers with something other than a working
// bash: its usage text (WSL is not installed), an error in UTF-16, an exit code, no answer.
//
// FAKE_WSL_DIR names a folder. A call whose first argument is "-l" (wsl -l -v) is a "list" call and answers from
// the files list.out, list.err, list.exit, list.sleep and list.hold in it; any other call is a "run" call and
// answers from run.out, run.err, run.exit, run.sleep and run.hold. The calls of each kind are counted
// (list.count, run.count), and call N of a kind, from 1, takes <kind>.N.out, <kind>.N.err and so on instead where
// the folder has them (run.2.out answers the second run call), so that the calls of one command can answer
// differently. The .out and .err files are written byte for byte (UTF-16 like wsl.exe's own messages, or UTF-8
// like bash); .exit holds the exit code and .sleep a number of milliseconds to wait first. A missing file means
// no output, exit code 0, no wait. With .hold (a number of seconds) the stand-in leaves a process behind that
// holds its standard output open that long after it has ended, as a Windows program started from Linux would; its
// process id goes to hold.pid. Every call appends a line to calls.txt in the folder, writes its arguments, each
// followed by a NUL, to args.bin (UTF-8; the last call only), the variables WSLENV, SystemRoot and TEMP as
// NAME=value, each followed by a NUL, to env.bin (the last call only), and its process id to pid.txt.
using System.Diagnostics;
using System.Globalization;
using System.Text;

string dir = Environment.GetEnvironmentVariable("FAKE_WSL_DIR")
    ?? throw new InvalidOperationException("FAKE_WSL_DIR names no folder");
var utf8 = new UTF8Encoding(false);

File.AppendAllText(Path.Combine(dir, "calls.txt"), string.Join(' ', args) + "\n");
File.WriteAllText(Path.Combine(dir, "args.bin"), string.Join('\0', args) + "\0", utf8);
string env = string.Concat(new[] { "WSLENV", "SystemRoot", "TEMP" }.Select(n => $"{n}={Environment.GetEnvironmentVariable(n)}\0"));
File.WriteAllText(Path.Combine(dir, "env.bin"), env, utf8);
File.WriteAllText(Path.Combine(dir, "pid.txt"), Environment.ProcessId.ToString(CultureInfo.InvariantCulture));

string prefix = args.Length > 0 && args[0] == "-l" ? "list" : "run";
string countFile = Path.Combine(dir, prefix + ".count");
int call = File.Exists(countFile) ? int.Parse(File.ReadAllText(countFile).Trim(), CultureInfo.InvariantCulture) + 1 : 1;
File.WriteAllText(countFile, call.ToString(CultureInfo.InvariantCulture));

string Answer(string extension)
{
    string numbered = Path.Combine(dir, $"{prefix}.{call}{extension}");
    return File.Exists(numbered) ? numbered : Path.Combine(dir, prefix + extension);
}

void Copy(string file, Stream to)
{
    if (!File.Exists(file)) return;
    byte[] bytes = File.ReadAllBytes(file);
    to.Write(bytes);
    to.Flush();
}

string sleep = Answer(".sleep");
if (File.Exists(sleep)) Thread.Sleep(int.Parse(File.ReadAllText(sleep).Trim(), CultureInfo.InvariantCulture));
using (Stream stdout = Console.OpenStandardOutput()) Copy(Answer(".out"), stdout);
using (Stream stderr = Console.OpenStandardError()) Copy(Answer(".err"), stderr);

string hold = Answer(".hold");
if (File.Exists(hold))
{
    // cmd.exe inherits the standard handles (no redirection) and keeps them while ping waits
    var psi = new ProcessStartInfo(
        Path.Combine(Environment.SystemDirectory, "cmd.exe"),
        $"/c ping -n {File.ReadAllText(hold).Trim()} 127.0.0.1 >nul")
    {
        UseShellExecute = false
    };
    using Process held = Process.Start(psi)!;
    File.WriteAllText(Path.Combine(dir, "hold.pid"), held.Id.ToString(CultureInfo.InvariantCulture));
}

string exit = Answer(".exit");
return File.Exists(exit) ? int.Parse(File.ReadAllText(exit).Trim(), CultureInfo.InvariantCulture) : 0;
