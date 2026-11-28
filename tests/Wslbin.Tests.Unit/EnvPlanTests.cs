using System.Diagnostics;

namespace Wslbin.Tests;

// Windows variables for Linux programs, carried by WSLENV (pass_env).
public class EnvPlanTests
{
    static void Variables(Machine m)
    {
        m.Fake.Env["APPX_PATH"] = @"C:\x\y";
        m.Fake.Env["APPX_LIST"] = @"C:\a;D:\b c";
        m.Fake.Env["APPX_MIXED"] = @"C:\a;not-a-path";
        m.Fake.Env["APPX_PLAIN"] = "hello";
        m.Fake.Env["APPX_REL"] = @"..\rel";
        m.Fake.Env["CI"] = "1";
        m.Fake.Env["OTHER"] = "no";
    }

    static List<string> Lines(Machine m) => [.. m.Err.Split('\n', StringSplitOptions.RemoveEmptyEntries)];

    [Fact]
    public void Variables_of_pass_env_are_named_and_only_paths_are_translated()
    {
        using var m = new Machine();
        Variables(m);
        m.Explain("tool", [], ini: "pass_env = APPX_*, CI");
        List<string> lines = Lines(m);
        Assert.Contains("wslbin: env APPX_PATH=/mnt/c/x/y", lines);
        Assert.Contains("wslbin: env APPX_LIST=/mnt/c/a:/mnt/d/b c", lines);
        Assert.Contains("wslbin: env APPX_MIXED", lines);
        Assert.Contains("wslbin: env APPX_PLAIN", lines);
        Assert.Contains("wslbin: env APPX_REL", lines);
        Assert.Contains("wslbin: env CI", lines);
        Assert.DoesNotContain("OTHER", m.Err, StringComparison.Ordinal);
        Assert.DoesNotContain("hello", m.Err, StringComparison.Ordinal);
    }

    [Fact]
    public void Names_match_without_regard_to_case()
    {
        using var m = new Machine();
        Variables(m);
        m.Explain("tool", [], ini: "pass_env = appx_pl*");
        Assert.Contains("env APPX_PLAIN", m.Err, StringComparison.Ordinal);
    }

    [Fact]
    public void Path_and_wslenv_are_never_passed_even_for_a_pattern_that_matches_everything()
    {
        using var m = new Machine();
        Variables(m);
        m.Fake.Env["PATH"] = @"C:\bin";
        m.Fake.Env["Path"] = @"C:\bin2";
        m.Fake.Env["WSLENV"] = "FOO";
        m.Fake.Env["=C:"] = @"C:\x";
        m.Fake.Env["A/B"] = "x";
        m.Explain("tool", [], ini: "pass_env = *");
        Assert.DoesNotContain("env PATH", m.Err, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("env WSLENV", m.Err, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("env =C:", m.Err, StringComparison.Ordinal);
        Assert.DoesNotContain("env A/B", m.Err, StringComparison.Ordinal);
        Assert.Contains("env APPX_PLAIN", m.Err, StringComparison.Ordinal);
    }

    [Fact]
    public void Variables_that_the_user_listed_in_wslenv_are_left_to_the_user()
    {
        using var m = new Machine();
        Variables(m);
        m.Fake.Env["WSLENV"] = "appx_plain/p";
        m.Explain("tool", [], ini: "pass_env = APPX_*");
        Assert.DoesNotContain("env APPX_PLAIN", m.Err, StringComparison.Ordinal);
        Assert.Contains("env APPX_PATH=", m.Err, StringComparison.Ordinal);
    }

    [Fact]
    public void Nothing_is_printed_without_pass_env()
    {
        using var m = new Machine();
        Variables(m);
        m.Explain();
        Assert.Equal("", m.Err);
    }

    [Fact]
    public void The_plan_goes_into_wslenv_of_the_child_with_a_slash_p_only_on_paths()
    {
        using var m = new Machine();
        Variables(m);
        m.Fake.Env["WSLENV"] = "KEEP/u";
        EnvPlan plan = EnvPlan.Create(m.Config("pass_env = APPX_PATH, APPX_PLAIN, APPX_LIST"));
        var psi = new ProcessStartInfo("x");
        plan.ApplyTo(psi);
        Assert.Equal("KEEP/u:APPX_LIST/p:APPX_PATH/p:APPX_PLAIN", psi.EnvironmentVariables["WSLENV"]);
    }

    [Fact]
    public void Without_a_match_wslenv_is_not_touched()
    {
        using var m = new Machine();
        Variables(m);
        EnvPlan plan = EnvPlan.Create(m.Config("pass_env = NOSUCH_*"));
        var psi = new ProcessStartInfo("x");
        psi.EnvironmentVariables["WSLENV"] = "keep";
        plan.ApplyTo(psi);
        Assert.Equal("keep", psi.EnvironmentVariables["WSLENV"]);
    }
}
