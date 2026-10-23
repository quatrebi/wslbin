// wslbin: run Linux utilities from WSL as ordinary Windows programs.
//
// C# 5, no dependencies: it has to build with the compiler that ships with Windows (build.ps1, and the
// command line in AGENTS.md). DECISIONS.md is the source of truth for behaviour.
//
// The files of src/, and what is in them:
//   wslbin.cs           Program: the entry point, the command line of wrapper copies and wslbin's own
//                       commands; the version (the assembly attributes below)
//   Config.cs           Config: wslbin.ini next to the .exe
//   Paths.cs            Paths: Windows path -> Linux path
//   Bash.cs             Bash: one argument -> one bash word (smart / sh / raw)
//   EnvPlan.cs          EnvPlan: Windows variables handed to Linux through WSLENV
//   Launcher.cs         Launcher: wsl.exe command line, starting a child in the console, exit codes;
//                       ChildJob: ending wsl.exe when wslbin ends
//   WslQuery.cs         WslQuery: what wslbin learns about WSL (wsl.exe calls whose output it reads, the registry)
//   Wrappers.cs         Wrappers (copies of wslbin.exe named after utilities), SearchPath (the PATH of
//                       Windows), Conflicts (names that Windows already uses), Elevation (administrator rights)
//   WrapperCommands.cs  WrapperCommands: --link, --unlink, --list; Apt: installing a utility that WSL lacks
//   Doctor.cs           Doctor: --doctor
//   Help.cs             Resources: texts built into the .exe (build.ps1)
//   Completion.cs       Completion: --complete, Tab completion for the shells
//   Init.cs             Init: --init pwsh | clink
//   Out.cs              Out: console output that does not depend on the console code page

using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;

[assembly: AssemblyTitle("wslbin")]
// ProductName is how wslbin recognises its own wrappers (copies of wslbin.exe) among other .exe files.
[assembly: AssemblyProduct("wslbin")]
[assembly: AssemblyDescription("Run Linux utilities from WSL as ordinary Windows programs")]
[assembly: AssemblyVersion("0.1.0.0")]
[assembly: AssemblyFileVersion("0.1.0.0")]
[assembly: AssemblyInformationalVersion("0.1.0-dev")]

namespace Wslbin
{
    /// <summary>An error that is reported to the user as one line, without a stack trace.</summary>
    internal sealed class WslbinException : Exception
    {
        public WslbinException(string message) : base(message) { }
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
        public string Utility;                 // null in the "wslbin -c" form
        public string Script;                  // the bash string in the "wslbin -c" form
        public readonly List<string> Args = new List<string>();
        public ArgMode? Mode;                  // null: take it from the config
        public bool Explain;
    }

    internal static class Program
    {
        // The flags of a wrapper copy, in front of the utility's arguments.
        internal const string RawFlag = "--wslbin-raw";
        internal const string ShFlag = "--wslbin-sh";
        internal const string ExplainFlag = "--wslbin-explain";
        internal static readonly string[] WrapperFlags = { RawFlag, ShFlag, ExplainFlag };

        // The options of "wslbin [--raw | --sh] [--explain] <utility>" and "wslbin -c".
        internal const string RawOption = "--raw";
        internal const string ShOption = "--sh";
        internal const string ExplainOption = "--explain";
        internal const string ScriptOption = "-c";
        internal static readonly string[] ModeOptions = { RawOption, ShOption, ExplainOption };
        internal static readonly string[] RunOptions = { RawOption, ShOption, ExplainOption, ScriptOption };

        // The version is the one in AssemblyInformationalVersion above, so a release changes it there only
        // (and in the two numeric attributes next to it).
        internal static readonly string Version =
            ((AssemblyInformationalVersionAttribute)Attribute.GetCustomAttribute(
                Assembly.GetExecutingAssembly(), typeof(AssemblyInformationalVersionAttribute))).InformationalVersion;

        sealed class Command
        {
            public string Name;
            public bool Hidden;                     // not offered by Tab completion: for shells, or for wslbin itself
            public Func<IList<string>, int> Run;    // gets the arguments after the name
        }

        // wslbin's own commands. Everything else that starts with "-" is an error; a word is a utility.
        static List<Command> Commands(string exePath)
        {
            Func<Config> config = () => Config.Load(Config.PathFor(exePath), Out.Warn);
            return new List<Command>
            {
                new Command { Name = "--version", Run = PrintVersion },
                new Command { Name = "--link", Run = a => WrapperCommands.Link(a, exePath, config()) },
                new Command { Name = "--unlink", Run = a => WrapperCommands.Unlink(a, exePath) },
                new Command { Name = "--list", Run = a => WrapperCommands.List(a, exePath, config()) },
                new Command { Name = "--doctor", Run = a => Doctor.Run(a, exePath) },
                new Command { Name = "--init", Run = a => Init.Run(a, exePath) },
                new Command { Name = "--complete", Hidden = true, Run = a => Completion.Run(a, exePath) },
                // the elevated halves of --link and --unlink; not for people
                new Command { Name = "--internal-link", Hidden = true, Run = a => WrapperCommands.InternalLink(a, exePath) },
                new Command { Name = "--internal-unlink", Hidden = true, Run = a => WrapperCommands.InternalUnlink(a, exePath) }
            };
        }

        // What "wslbin <Tab>" offers.
        internal static List<string> OfferedOptions()
        {
            var names = new List<string>();
            foreach (Command c in Commands(""))
            {
                if (!c.Hidden) names.Add(c.Name);
            }
            names.AddRange(RunOptions);
            return names;
        }

        static int PrintVersion(IList<string> args)
        {
            if (args.Count > 0) throw new WslbinException("--version takes no arguments");
            Out.Info("wslbin " + Version);
            return 0;
        }

        const string Usage =
            "Usage: <utility>.exe [--wslbin-raw | --wslbin-sh] [--wslbin-explain] [arguments]\n" +
            "       wslbin [--raw | --sh] [--explain] <utility> [arguments]\n" +
            "       wslbin [--explain] -c \"<bash string>\" [arguments]\n" +
            "       wslbin --version";

        internal static int Main(string[] args)
        {
            try
            {
                return Run(args);
            }
            catch (WslbinException ex)
            {
                Out.Error("wslbin: " + ex.Message);
                return ExitCodes.Failed;
            }
            catch (Exception ex)
            {
                Out.Error("wslbin: internal error: " + ex);
                return ExitCodes.Failed;
            }
        }

        static int Run(string[] args)
        {
            string exePath = Assembly.GetExecutingAssembly().Location;
            string exeName = Path.GetFileNameWithoutExtension(exePath);
            bool isCli = string.Equals(exeName, "wslbin", StringComparison.OrdinalIgnoreCase);

            Invocation inv;
            if (isCli)
            {
                if (args.Length == 0)
                {
                    Out.Error(Usage);
                    return ExitCodes.Failed;
                }
                foreach (Command command in Commands(exePath))
                {
                    if (command.Name == args[0]) return command.Run(new List<string>(args).GetRange(1, args.Length - 1));
                }
                inv = ParseCli(args);
            }
            else
            {
                inv = ParseWrapper(exeName, args);
            }

            Config cfg = Config.Load(Config.PathFor(exePath), Out.Warn);
            string script = BuildScript(inv, cfg);
            EnvPlan env = EnvPlan.Create(cfg);

            if (inv.Explain)
            {
                Out.Info(script);
                env.Describe();
                string problem = Launcher.FolderProblem(cfg);
                if (problem != null) Out.Warn(problem + " (so this would not run)");
                return 0;
            }
            // Arguments after "-c <string>" become $0, $1, ... of the bash string, as in "bash -c".
            IList<string> positional = inv.Script != null ? inv.Args : new List<string>();
            return Launcher.Run(cfg, script, positional, env);
        }

        // <utility>.exe [--wslbin-*]... [arguments]
        // The flags are recognised only in front of the arguments; anything else belongs to the utility.
        static Invocation ParseWrapper(string utility, string[] args)
        {
            var inv = new Invocation();
            inv.Utility = utility;
            int i = 0;
            while (i < args.Length && args[i].StartsWith("--wslbin-", StringComparison.Ordinal))
            {
                switch (args[i])
                {
                    case RawFlag: SetMode(inv, ArgMode.Raw); break;
                    case ShFlag: SetMode(inv, ArgMode.Sh); break;
                    case ExplainFlag: inv.Explain = true; break;
                    default:
                        throw new WslbinException("unknown option " + args[i] +
                            " (options starting with --wslbin- in front of the arguments are reserved)");
                }
                i++;
            }
            for (; i < args.Length; i++) inv.Args.Add(args[i]);
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
                throw new WslbinException("no utility given (wslbin without arguments shows the usage)");

            if (args[i] == ScriptOption)
            {
                if (inv.Mode.HasValue)
                    throw new WslbinException("-c hands the string to bash as it is; --raw and --sh do not apply");
                if (i + 1 >= args.Length)
                    throw new WslbinException("-c needs a bash string");
                inv.Script = args[i + 1];
                for (i += 2; i < args.Length; i++) inv.Args.Add(args[i]);
                return inv;
            }
            if (args[i].StartsWith("-", StringComparison.Ordinal))
                throw new WslbinException("unknown option " + args[i] + " (wslbin without arguments shows the usage)");

            inv.Utility = args[i];
            for (i++; i < args.Length; i++) inv.Args.Add(args[i]);
            return inv;
        }

        static void SetMode(Invocation inv, ArgMode mode)
        {
            if (inv.Mode.HasValue && inv.Mode.Value != mode)
                throw new WslbinException("raw and sh modes cannot be combined");
            inv.Mode = mode;
        }

        /// <summary>The bash string that wsl.exe will run.</summary>
        internal static string BuildScript(Invocation inv, Config cfg)
        {
            if (inv.Script != null) return cfg.PathPrefix() + inv.Script;

            ArgMode mode = inv.Mode.HasValue ? inv.Mode.Value : cfg.ModeFor(inv.Utility);
            var words = new List<string>();
            words.Add(Bash.CommandWord(inv.Utility));
            foreach (string a in cfg.DefaultArgsFor(inv.Utility)) words.Add(Word(mode, a, cfg));
            foreach (string a in inv.Args) words.Add(Word(mode, a, cfg));
            return cfg.PathPrefix() + string.Join(" ", words);
        }

        static string Word(ArgMode mode, string arg, Config cfg)
        {
            if (mode == ArgMode.Raw) return Bash.Literal(arg);
            string translated = Paths.TranslateCommandArg(arg, cfg, Out.Warn);
            return mode == ArgMode.Sh ? Bash.Sh(translated) : Bash.Smart(translated);
        }
    }
}
