using System.Text;

namespace Wslbin.Tests;

/// <summary>
/// A fake machine (FakeHost) that is the machine of the code that runs in the test, and a folder of its own
/// on the real disk: the folder of wslbin.exe, its wrappers and wslbin.ini, and the current folder.
/// Create it inside the test (using var m = new Machine()), never in a field: the host is bound to the
/// flow of the test.
/// </summary>
internal sealed class Machine : IDisposable
{
    readonly IDisposable scope;

    public Machine()
    {
        Dir = Path.Combine(Path.GetTempPath(), "wslbin-unit-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Dir);
        Fake.Cwd = Dir;
        Fake.ProcessPathValue = Exe("wslbin");
        scope = Host.Use(Fake);
    }

    public FakeHost Fake { get; } = new();

    /// <summary>The folder of wslbin.exe and the current folder.</summary>
    public string Dir { get; }

    public string Exe(string name) => Path.Combine(Dir, name + ".exe");

    public string IniPath => Path.Combine(Dir, "wslbin.ini");

    public string Out => Fake.Out;

    public string Err => Fake.Err;

    public void Ini(string text) => File.WriteAllText(IniPath, text, new UTF8Encoding(false));

    /// <summary>A file that the fake host takes for a copy of wslbin.exe (a wrapper, or wslbin.exe itself).</summary>
    public string MakeExe(string name, string suffix = "")
    {
        string path = Exe(name);
        File.WriteAllText(path, FakeHost.ExeText + suffix);
        return path;
    }

    public Config Config(string? ini = null)
    {
        if (ini != null) Ini(ini);
        return Wslbin.Config.Load(IniPath, _ => { });
    }

    /// <summary>Runs wslbin.exe, or a wrapper of the given name, with the arguments; returns the exit code.</summary>
    public int Run(string name, params string[] args)
    {
        if (!File.Exists(Exe(name))) MakeExe(name);
        return Program.Execute(Exe(name), args);
    }

    /// <summary>What --wslbin-explain says to a wrapper of this name: the bash command.</summary>
    public string Explain(string name, string[] args, string? ini = null, string[]? flags = null)
    {
        if (ini != null) Ini(ini);
        Fake.ClearOutput();
        int code = Run(name, ["--wslbin-explain", .. flags ?? [], .. args]);
        Assert.True(code == 0, $"explain failed with {code}: {Err}");
        return Out.TrimEnd('\n');
    }

    public string Explain(params string[] args) => Explain("tool", args);

    public void Dispose()
    {
        scope.Dispose();
        try
        {
            Directory.Delete(Dir, true);
        }
        catch (IOException)
        {
            // the next run of the system cleans the temporary folder
        }
    }
}
