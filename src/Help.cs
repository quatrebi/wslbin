// wslbin: --help.

using System.Runtime.InteropServices;

namespace Wslbin;

// wslbin --help [topic]: the texts are files in docs/en and docs/ru, built into the .exe.
internal static partial class Help
{
    // The topics of "wslbin --help <topic>": one file docs/<language>/<topic>.txt each.
    public static readonly string[] Topics = ["modes", "paths", "globs", "env", "completion", "config", "troubleshooting"];

    // The language of the user interface of Windows (a LANGID: the primary language is its low 10
    // bits). Asked of Windows and not of CultureInfo: the program is built with InvariantGlobalization,
    // which makes it smaller, and then CultureInfo knows no language.
    [LibraryImport("kernel32.dll")]
    private static partial ushort GetUserDefaultUILanguage();

    const int PrimaryLanguageMask = 0x3FF;
    const int LangRussian = 0x19;

    // "en" or "ru": lang in wslbin.ini, and when that is absent or "auto", the language of Windows.
    public static string Language(Config cfg) =>
        cfg.Lang is "en" or "ru" ? cfg.Lang : (GetUserDefaultUILanguage() & PrimaryLanguageMask) == LangRussian ? "ru" : "en";

    // docs/<language>/<file>, or the English one when a language lacks it.
    public static string Document(Config cfg, string file) =>
        Resources.TryText($"wslbin.docs.{Language(cfg)}.{file}") ?? Resources.Text($"wslbin.docs.en.{file}");

    public static string Overview(Config cfg) => Document(cfg, "help.txt");

    public static int Run(IList<string> args, Config cfg)
    {
        if (args.Count == 0)
        {
            Out.Info(Overview(cfg).TrimEnd('\n'));
            return 0;
        }
        string topic = args[0].ToLowerInvariant();
        if (args.Count > 1 || !Topics.Contains(topic))
            throw new WslbinException($"--help takes one topic, one of: {string.Join(", ", Topics)}");
        Out.Info(Document(cfg, topic + ".txt").TrimEnd('\n'));
        return 0;
    }
}
