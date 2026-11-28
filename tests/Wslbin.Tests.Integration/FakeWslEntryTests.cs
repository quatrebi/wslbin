using System.Diagnostics;
using System.Text;

namespace Wslbin.Tests;

// The two things that only a separate process can show, on the test build of the program whose wsl.exe is the
// stand-in (FakeWslEntry.cs): that wsl.exe does not outlive the wrapper, and what a wrapper says without WSL.
// Everything else about a failing WSL is a unit test.
public class FakeWslEntryTests(ExeFixture fixture)
{
    static readonly byte[] Usage = Encoding.Unicode.GetBytes(
        "Usage: wsl.exe [Argument] [Options...] [CommandLine]\r\n    --install [Distro]\r\n    --list, -l [Options]\r\n    --status\r\n");

    static string FakeWslFolder(Dictionary<string, byte[]> files)
    {
        string dir = Path.Combine(Path.GetTempPath(), "wslbin-fake-wsl-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        foreach ((string name, byte[] bytes) in files) File.WriteAllBytes(Path.Combine(dir, name), bytes);
        return dir;
    }

    static Dictionary<string, string?> Environment(string fakeDir, bool hasDistribution) => new()
    {
        ["WSLBIN_TEST_WSL"] = ExeFixture.FakeWslExe,
        ["WSLBIN_TEST_DISTROS"] = hasDistribution ? "1" : "0",
        ["FAKE_WSL_DIR"] = fakeDir,
        // a PATH with nothing of this machine's programs in it
        ["PATH"] = System.IO.Path.Combine(System.Environment.GetFolderPath(System.Environment.SpecialFolder.Windows), "System32"),
    };

    [Fact]
    public async Task A_wrapper_without_WSL_exits_with_125_and_says_why_instead_of_passing_on_the_exit_code_of_wsl()
    {
        string fakeDir = FakeWslFolder(new() { ["run.out"] = Usage, ["run.exit"] = "1"u8.ToArray() });
        try
        {
            string exe = Runner.Place(fixture, "grep", from: fixture.FakeWslBuild);
            RunResult r = await Runner.RunAsync(exe, ["x", "file"], env: Environment(fakeDir, hasDistribution: false));
            Assert.Equal(125, r.ExitCode);
            Assert.Contains("WSL is not installed, or has no distribution, so wsl.exe answered instead of running the command " +
                            "(fix: run 'wsl --install' as administrator)", r.Err, StringComparison.Ordinal);
            Assert.Single(await File.ReadAllLinesAsync(Path.Combine(fakeDir, "calls.txt"), TestContext.Current.CancellationToken));
        }
        finally
        {
            Directory.Delete(fakeDir, true);
        }
    }

    [Fact]
    public async Task Wsl_is_stopped_when_the_wrapper_is_stopped_by_a_timeout_of_its_caller_say()
    {
        string fakeDir = FakeWslFolder(new() { ["run.sleep"] = "60000"u8.ToArray() });
        try
        {
            string exe = Runner.Place(fixture, "sleep", from: fixture.FakeWslBuild);
            var psi = new ProcessStartInfo(exe) { UseShellExecute = false, RedirectStandardInput = true };
            psi.ArgumentList.Add("60");
            foreach ((string key, string? value) in Environment(fakeDir, hasDistribution: true)) psi.Environment[key] = value;
            using Process wrapper = Process.Start(psi)!;
            string pidFile = Path.Combine(fakeDir, "pid.txt");
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
            deadline.CancelAfter(TimeSpan.FromSeconds(30));
            while (!File.Exists(pidFile) || new FileInfo(pidFile).Length == 0) await Task.Delay(50, deadline.Token);
            using Process fake = Process.GetProcessById(int.Parse(await File.ReadAllTextAsync(pidFile, deadline.Token), System.Globalization.CultureInfo.InvariantCulture));

            wrapper.Kill();
            await fake.WaitForExitAsync(deadline.Token);
            Assert.True(fake.HasExited, "wsl.exe must not outlive the wrapper");
        }
        finally
        {
            try
            {
                Directory.Delete(fakeDir, true);
            }
            catch (IOException)
            {
            }
        }
    }
}
