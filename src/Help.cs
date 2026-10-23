// wslbin: the texts that are built into the .exe.

using System.IO;
using System.Reflection;
using System.Text;

namespace Wslbin
{
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
