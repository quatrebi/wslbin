// wslbin: --help, and the texts that are built into the .exe.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Text;

namespace Wslbin
{
    // wslbin --help [topic]: the texts are files in docs/en and docs/ru, built into the .exe.
    internal static class Help
    {
        // The topics of "wslbin --help <topic>": one file docs/<language>/<topic>.txt each.
        public static readonly string[] Topics =
        {
            "modes", "paths", "globs", "env", "completion", "config", "troubleshooting"
        };

        // "en" or "ru": lang in wslbin.ini, and when that is absent or "auto", the language of Windows.
        public static string Language(Config cfg)
        {
            if (cfg.Lang == "en" || cfg.Lang == "ru") return cfg.Lang;
            return CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "ru" ? "ru" : "en";
        }

        // docs/<language>/<file>, or the English one when a language lacks it.
        public static string Document(Config cfg, string file)
        {
            string text = Resources.TryText("wslbin.docs." + Language(cfg) + "." + file);
            return text ?? Resources.Text("wslbin.docs.en." + file);
        }

        public static string Overview(Config cfg)
        {
            return Document(cfg, "help.txt");
        }

        public static int Run(IList<string> args, Config cfg)
        {
            if (args.Count == 0)
            {
                Out.Info(Overview(cfg).TrimEnd('\n'));
                return 0;
            }
            string topic = args[0].ToLowerInvariant();
            if (args.Count > 1 || Array.IndexOf(Topics, topic) < 0)
                throw new WslbinException("--help takes one topic, one of: " + string.Join(", ", Topics));
            Out.Info(Document(cfg, topic + ".txt").TrimEnd('\n'));
            return 0;
        }
    }

    // Texts that live in files of the repository and are built into wslbin.exe (see build.ps1).
    internal static class Resources
    {
        public const string CompleteScript = "wslbin.wsl.complete.sh";
        public const string PowerShellInit = "wslbin.shell.wslbin.ps1";
        public const string ClinkInit = "wslbin.shell.wslbin.lua";
        public const string NativeVersions = "wslbin.data.native-versions.txt";

        public static string Text(string name)
        {
            string text = TryText(name);
            if (text == null) throw new WslbinException("internal error: wslbin.exe was built without " + name);
            return text;
        }

        // null when there is no such resource.
        public static string TryText(string name)
        {
            using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(name))
            {
                if (stream == null) return null;
                using (var reader = new StreamReader(stream, new UTF8Encoding(false)))
                    return reader.ReadToEnd().Replace("\r\n", "\n");
            }
        }
    }
}
