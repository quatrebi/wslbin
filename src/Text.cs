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
    /// place. A file that belongs to the user is never left cut short.
    /// </summary>
    public static void WriteAllAtomic(string path, string text, bool bom = false)
    {
        string temp = $"{path}.wslbin-{Guid.NewGuid():N}.tmp";
        try
        {
            File.WriteAllText(temp, text, new UTF8Encoding(bom));
            File.Move(temp, path, overwrite: true);
        }
        finally
        {
            File.Delete(temp);
        }
    }
}
