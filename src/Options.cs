// wslbin: the options of wslbin's own commands.

namespace Wslbin;

// The words after a command such as --link: flags, options followed by a folder, and the other words.
internal sealed class Options
{
    readonly HashSet<string> flags = [];
    readonly Dictionary<string, string> folders = [];

    /// <summary>The words that are not options, in order.</summary>
    public List<string> Words { get; } = [];

    /// <param name="command">the command, for messages ("--link")</param>
    /// <param name="flags">options that stand alone</param>
    /// <param name="folders">options that take the next word as a folder</param>
    /// <param name="words">whether words that are not options are allowed</param>
    public static Options Parse(IList<string> args, string command, string[] flags,
                                string[]? folders = null, bool words = false)
    {
        var options = new Options();
        for (int i = 0; i < args.Count; i++)
        {
            string a = args[i];
            if (flags.Contains(a))
            {
                options.flags.Add(a);
            }
            else if (folders != null && folders.Contains(a))
            {
                if (i + 1 >= args.Count) throw new WslbinException($"{a} needs a folder");
                options.folders[a] = args[++i];
            }
            else if (words && !a.StartsWith('-'))
            {
                options.Words.Add(a);
            }
            else
            {
                throw new WslbinException($"unknown option {a} for {command}");
            }
        }
        return options;
    }

    /// <summary>For a command that takes nothing.</summary>
    public static void None(IList<string> args, string command)
    {
        if (args.Count > 0) throw new WslbinException($"{command} takes no arguments");
    }

    public bool Has(string flag) => flags.Contains(flag);

    /// <summary>The folder given after an option, or null when the option was not given.</summary>
    public string? Value(string option) => folders.GetValueOrDefault(option);
}
