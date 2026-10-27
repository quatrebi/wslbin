// wslbin: lines, strict UTF-8, and files written all or nothing.

using System.Text;

namespace Wslbin;

internal static class Text
{
    static readonly UTF8Encoding Strict = new(false, true);
    static readonly UTF8Encoding Lenient = new(false, false);

    /// <summary>The non-empty lines of a text, whatever its line ends.</summary>
    public static List<string> Lines(string text) =>
        [.. text.Replace("\r", "").Split('\n', StringSplitOptions.RemoveEmptyEntries)];

    /// <summary>
    /// UTF-8 text, with or without a byte order mark (bom says which). Strict: null when the bytes are
    /// not UTF-8, so that a file in ANSI is never damaged by being decoded and written back.
    /// </summary>
    public static string? DecodeUtf8(byte[] bytes, out bool bom, bool strict = true)
    {
        bom = bytes.AsSpan().StartsWith((ReadOnlySpan<byte>)[0xEF, 0xBB, 0xBF]);
        int skip = bom ? 3 : 0;
        try
        {
            return (strict ? Strict : Lenient).GetString(bytes, skip, bytes.Length - skip);
        }
        catch (DecoderFallbackException)
        {
            return null;
        }
    }

    /// <summary>
    /// Writes a file all or nothing: the text goes to a file beside it first, which then takes its
    /// place. A file that belongs to the user is never left cut short. A symbolic link (a CLAUDE.md
    /// kept in a repository of dotfiles) stays a link: the file it points to is the one written. A file
    /// that is there keeps its attributes and its access rights (File.Replace), and one that is
    /// read-only is refused, as any editor would refuse it.
    /// </summary>
    public static void WriteAllAtomic(string path, string text, bool bom = false)
    {
        string target = FinalPath(path);
        string temp = $"{target}.wslbin-{Guid.NewGuid():N}.tmp";
        try
        {
            File.WriteAllText(temp, text, new UTF8Encoding(bom));
            if (!File.Exists(target)) File.Move(temp, target);
            else if (File.GetAttributes(target).HasFlag(FileAttributes.ReadOnly))
                throw new UnauthorizedAccessException($"{target} is read-only: left as it is");
            else File.Replace(temp, target, null);
        }
        finally
        {
            File.Delete(temp);
        }
    }

    // The file that a path names in the end: the target of a symbolic link (of a chain of them), or
    // the path itself. A link whose target is relative is resolved against the folder of the link.
    static string FinalPath(string path)
    {
        var info = new FileInfo(path);
        if (info.LinkTarget == null) return path;
        return info.ResolveLinkTarget(returnFinalTarget: true)?.FullName ?? path;
    }
}
