// wslbin: run Linux utilities from WSL as ordinary Windows programs.
//
// C# on .NET 10, published as one self-contained Native AOT program with nothing that ships with it
// (wslbin.csproj, built by build.ps1). DECISIONS.md is the source of truth for behaviour.
//
// The files of src/, and what is in them:
//   wslbin.cs           Program: the entry point, the command line of wrapper copies and wslbin's own
//                       commands
//   Options.cs          Options: the options of wslbin's own commands
//   Config.cs           Config: wslbin.ini next to the .exe
//   Paths.cs            Paths: Windows path -> Linux path
//   Folder.cs           Folder: the current folder, and whether a command can run in it
//   Bash.cs             Bash: one argument -> one bash word (smart / sh / raw)
//   EnvPlan.cs          EnvPlan: Windows variables handed to Linux through WSLENV
//   Launcher.cs         Launcher: wsl.exe command line, starting a child, exit codes;
//                       ChildJob: ending wsl.exe when wslbin ends
//   WslQuery.cs         WslQuery: what wslbin learns about WSL (wsl.exe calls whose output it reads, the registry)
//   Wrappers.cs         Wrappers (copies of wslbin.exe named after utilities), SearchPath (the PATH of
//                       Windows), Conflicts (names that Windows already uses)
//   Elevation.cs        Elevation: administrator rights for --link and --unlink
//   WrapperCommands.cs  WrapperCommands: --link, --unlink, --list
//   Apt.cs              Apt: installing a utility that WSL lacks
//   NativeVersions.cs   NativeVersions: utilities that have a Windows version of their own (data/native-versions.txt)
//   Doctor.cs           Doctor: --doctor
//   Help.cs             Help: --help [topic]
//   Resources.cs        Resources: texts built into the .exe (wslbin.csproj)
//   AiContext.cs        AiContext: --ai-context, --install-ai-context
//   Completion.cs       Completion: --complete, Tab completion for the shells
//   Init.cs             Init: --init pwsh | clink
//   Text.cs             Text: lines, strict UTF-8, files written all or nothing
//   Out.cs              Out: console output that does not depend on the console code page

using System.Reflection;

namespace Wslbin;

/// <summary>An error that is reported to the user as one line, without a stack trace.</summary>
internal sealed class WslbinException(string message) : Exception(message)
{
    /// <summary>What to do about it, when that is not the usual advice (--doctor shows it).</summary>
    public string? Fix { get; init; }
}

internal enum ArgMode
{
    /// <summary>Windows paths translated, globs left to bash, everything else escaped.</summary>
    Smart,
    /// <summary>Smart, plus Linux variables and command substitutions in arguments that contain $ or `.</summary>
    Sh,
    /// <summary>Arguments exactly as typed: nothing translated, nothing expanded.</summary>
    Raw
}

internal static class ExitCodes
{
    // The convention of env, timeout, nice and docker: 125 means the wrapper itself failed.
    // 126 and 127 (cannot run, not found) come from bash unchanged.
    public const int Failed = 125;
    // What a shell reports for a command stopped by Ctrl+C: 128 + SIGINT.
    public const int Interrupted = 130;
}

/// <summary>What the user asked for, before config and escaping are applied.</summary>
internal sealed class Invocation
{
    public string? Utility { get; set; }        // null in the "wslbin -c" form
    public string? Script { get; set; }         // the bash string in the "wslbin -c" form
    public List<string> Args { get; } = [];
    public ArgMode? Mode { get; set; }          // null: take it from the config
    public bool Explain { get; set; }
}

internal static class Program
{
    // The flags of a wrapper copy, in front of the utility's arguments.
    internal const string RawFlag = "--wslbin-raw";
    internal const string ShFlag = "--wslbin-sh";
    internal const string ExplainFlag = "--wslbin-explain";
    internal static readonly string[] WrapperFlags = [RawFlag, ShFlag, ExplainFlag];

    // The options of "wslbin [--raw | --sh] [--explain] <utility>" and "wslbin -c".
    internal const string RawOption = "--raw";
    internal const string ShOption = "--sh";
    internal const string ExplainOption = "--explain";
    internal const string ScriptOption = "-c";
    internal static readonly string[] ModeOptions = [RawOption, ShOption, ExplainOption];
    internal static readonly string[] RunOptions = [RawOption, ShOption, ExplainOption, ScriptOption];

    // The version is the AssemblyInformationalVersion that the build writes into the program: MAJOR.MINOR
    // is VersionPrefix in wslbin.csproj, and get-version.ps1 works out the rest (build.ps1 passes it on).
    internal static readonly string Version =
        typeof(Program).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()!.InformationalVersion;

    /// <summary>The program and its config, read when a command first needs it.</summary>
    sealed class Context(string exePath)
    {
        public string ExePath => exePath;
        public Config Config => field ??= Config.Load(Config.PathFor(exePath), Out.Warn);
    }

    // Hidden: not offered by Tab completion (for shells, or for wslbin itself).
    sealed record Command(string Name, Func<Context, IList<string>, int> Run, bool Hidden = false);

    // wslbin's own commands. Everything else that starts with "-" is an error; a word is a utility.
    static readonly Command[] Commands =
    [
        new("--help", (c, a) => Help.Run(a, c.Config)),
        new("-h", (c, a) => Help.Run(a, c.Config), Hidden: true),
        new("-?", (c, a) => Help.Run(a, c.Config), Hidden: true),
        new("--version", (_, a) => PrintVersion(a)),
        new("--link", (c, a) => WrapperCommands.Link(a, c.ExePath, c.Config)),
        new("--unlink", (c, a) => WrapperCommands.Unlink(a, c.ExePath)),
        new("--list", (c, a) => WrapperCommands.List(a, c.ExePath, c.Config)),
        new("--doctor", (c, a) => Doctor.Run(a, c.ExePath)),
        new("--init", (c, a) => Init.Run(a, c.ExePath)),
        new("--ai-context", (c, a) => AiContext.Print(a, c.Config)),
        new("--install-ai-context", (c, a) => AiContext.Install(a, c.Config)),
        new("--complete", (c, a) => Completion.Run(a, c.ExePath), Hidden: true),
        // the elevated halves of --link and --unlink; not for people
        new("--internal-link", (c, a) => WrapperCommands.InternalLink(a, c.ExePath), Hidden: true),
        new("--internal-unlink", (c, a) => WrapperCommands.InternalUnlink(a, c.ExePath), Hidden: true)
    ];

    // What "wslbin <Tab>" offers.
    internal static List<string> OfferedOptions() =>
        [.. Commands.Where(c => !c.Hidden).Select(c => c.Name), .. RunOptions];

    static int PrintVersion(IList<string> args)
    {
        Options.None(args, "--version");
        Out.Info($"wslbin {Version}");
        return 0;
    }

    internal static int Main(string[] args)
    {
        try
        {
            return Run(args);
        }
        catch (WslbinException ex)
        {
            Out.Fail(ex.Message);
            return ExitCodes.Failed;
        }
        catch (Exception ex)
        {
            Out.Fail($"internal error: {ex}");
            return ExitCodes.Failed;
        }
    }

    static int Run(string[] args)
    {
        // not Assembly.Location: it is empty in a single-file program
        string exePath = Environment.ProcessPath ?? throw new InvalidOperationException("the path of the running program is unknown");
        string exeName = Path.GetFileNameWithoutExtension(exePath);
        var context = new Context(exePath);

        Invocation inv;
        if (exeName.Equals("wslbin", StringComparison.OrdinalIgnoreCase))
        {
            if (args.Length == 0)
            {
                Out.Error(Help.Overview(context.Config).TrimEnd('\n'));
                return ExitCodes.Failed;
            }
            Command? command = Array.Find(Commands, c => c.Name == args[0]);
            if (command != null) return command.Run(context, args[1..]);
            inv = ParseCli(args);
        }
        else
        {
            inv = ParseWrapper(exeName, args);
        }

        Config cfg = context.Config;
        string script = BuildScript(inv, cfg);
        EnvPlan env = EnvPlan.Create(cfg);

        if (inv.Explain)
        {
            Out.Info(script);
            env.Describe();
            string? problem = Folder.Problem(cfg);
            if (problem != null) Out.Warn($"{problem} (so this would not run)");
            return 0;
        }
        // Arguments after "-c <string>" become $0, $1, ... of the bash string, as in "bash -c".
        IList<string> positional = inv.Script != null ? inv.Args : [];
        return Launcher.Run(cfg, script, positional, env);
    }

    // <utility>.exe [--wslbin-*]... [arguments]
    // The flags are recognised only in front of the arguments; anything else belongs to the utility.
    static Invocation ParseWrapper(string utility, string[] args)
    {
        var inv = new Invocation { Utility = utility };
        int i = 0;
        for (; i < args.Length && args[i].StartsWith("--wslbin-", StringComparison.Ordinal); i++)
        {
            switch (args[i])
            {
                case RawFlag: SetMode(inv, ArgMode.Raw); break;
                case ShFlag: SetMode(inv, ArgMode.Sh); break;
                case ExplainFlag: inv.Explain = true; break;
                default:
                    throw new WslbinException(
                        $"unknown option {args[i]} (options starting with --wslbin- in front of the arguments are reserved)");
            }
        }
        inv.Args.AddRange(args[i..]);
        return inv;
    }

    // wslbin [--raw | --sh] [--explain] <utility> [arguments]
    // wslbin [--explain] -c "<bash string>" [positional parameters]
    static Invocation ParseCli(string[] args)
    {
        var inv = new Invocation();
        int i = 0;
        for (; i < args.Length; i++)
        {
            if (args[i] == RawOption) SetMode(inv, ArgMode.Raw);
            else if (args[i] == ShOption) SetMode(inv, ArgMode.Sh);
            else if (args[i] == ExplainOption) inv.Explain = true;
            else break;
        }
        if (i == args.Length)
            throw new WslbinException("no utility given (see wslbin --help)");

        if (args[i] == ScriptOption)
        {
            if (inv.Mode.HasValue)
                throw new WslbinException("-c hands the string to bash as it is; --raw and --sh do not apply");
            if (i + 1 >= args.Length)
                throw new WslbinException("-c needs a bash string");
            inv.Script = args[i + 1];
            inv.Args.AddRange(args[(i + 2)..]);
            return inv;
        }
        if (args[i].StartsWith('-'))
            throw new WslbinException($"unknown option {args[i]} (see wslbin --help)");

        inv.Utility = args[i];
        inv.Args.AddRange(args[(i + 1)..]);
        return inv;
    }

    static void SetMode(Invocation inv, ArgMode mode)
    {
        if (inv.Mode.HasValue && inv.Mode != mode)
            throw new WslbinException("raw and sh modes cannot be combined");
        inv.Mode = mode;
    }

    /// <summary>The bash string that wsl.exe will run.</summary>
    internal static string BuildScript(Invocation inv, Config cfg)
    {
        if (inv.Script != null) return cfg.PathPrefix() + inv.Script;

        string utility = inv.Utility!;
        ArgMode mode = inv.Mode ?? cfg.ModeFor(utility);
        // relative paths are translated only where wsl.exe starts the utility in this folder
        bool relative = Folder.LinuxPath(cfg) != null;
        IEnumerable<string> words = cfg.DefaultArgsFor(utility).Concat(inv.Args).Select(a => ToWord(mode, a, cfg, relative));
        return cfg.PathPrefix() + string.Join(' ', words.Prepend(Bash.CommandWord(utility)));
    }

    static string ToWord(ArgMode mode, string arg, Config cfg, bool relative)
    {
        if (mode == ArgMode.Raw) return Bash.Literal(arg);
        string translated = Paths.TranslateCommandArg(arg, cfg, Out.Warn, relative);
        return mode == ArgMode.Sh ? Bash.Sh(translated) : Bash.Smart(translated);
    }
}
