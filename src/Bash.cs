// wslbin: one argument -> one bash word, in the smart, sh and raw modes.

using System;
using System.Text;

namespace Wslbin
{
    // One argument -> one bash word.
    internal static class Bash
    {
        // Words that bash treats specially in command position. "\time" is the utility, not the keyword.
        static readonly string[] Reserved =
        {
            "!", "{", "}", "[[", "]]", "case", "coproc", "do", "done", "elif", "else", "esac", "fi",
            "for", "function", "if", "in", "select", "then", "time", "until", "while"
        };

        // Characters that mean nothing to bash anywhere in a word. "=" is safe except in command
        // position, where NAME=value would be an assignment; "~" and "#" only at the start of a word.
        static bool IsSafe(char c, bool allowEquals)
        {
            return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
                   c == '_' || c == '.' || c == '/' || c == '-' || c == '+' || c == ',' || c == ':' ||
                   c == '@' || c == '%' || (allowEquals && c == '=') || c >= '\u0080';
        }

        /// <summary>The first word of the command. Never a keyword, never an assignment.</summary>
        public static string CommandWord(string utility)
        {
            if (Array.IndexOf(Reserved, utility) >= 0) return "\\" + utility;
            return Quote(utility, false);
        }

        /// <summary>The word reaches the utility exactly as given: no globs, no expansions.</summary>
        public static string Literal(string s)
        {
            return Quote(s, true);
        }

        static string Quote(string s, bool allowEquals)
        {
            if (s.Length == 0) return "''";
            bool plain = true;
            foreach (char c in s)
            {
                if (!IsSafe(c, allowEquals)) { plain = false; break; }
            }
            if (plain) return s;
            return "'" + s.Replace("'", "'\\''") + "'";
        }

        /// <summary>
        /// The smart mode: * ? [...] and a leading ~ are left for bash to expand,
        /// everything else (spaces, quotes, $, `, ;, |, &amp;, braces, ...) is escaped.
        /// </summary>
        public static string Smart(string s)
        {
            if (s.Length == 0) return "''";
            var sb = new StringBuilder(s.Length + 8);
            int i = 0;
            if (s[0] == '~')
            {
                sb.Append('~');
                i = 1;
            }
            for (; i < s.Length; i++)
            {
                char c = s[i];
                if (c == '*' || c == '?')
                {
                    sb.Append(c);
                }
                else if (c == '[')
                {
                    int close = BracketEnd(s, i);
                    if (close < 0)
                    {
                        sb.Append("\\[");
                    }
                    else
                    {
                        AppendBracket(sb, s, i, close);
                        i = close;
                    }
                }
                else
                {
                    AppendEscaped(sb, c, true);
                }
            }
            return sb.ToString();
        }

        static void AppendEscaped(StringBuilder sb, char c, bool allowEquals)
        {
            if (IsSafe(c, allowEquals)) sb.Append(c);
            // A backslash before a newline is a line continuation and vanishes; only quotes keep it.
            else if (c == '\n') sb.Append("'\n'");
            else sb.Append('\\').Append(c);
        }

        // Index of the "]" that closes the bracket expression opened at s[open], or -1 when there
        // is none, in which case "[" is an ordinary character. POSIX rules: after an optional "!"
        // or "^" a "]" is a member, and [:class:], [.sym.], [=equiv=] are skipped as a whole.
        static int BracketEnd(string s, int open)
        {
            int i = open + 1;
            if (i < s.Length && (s[i] == '!' || s[i] == '^')) i++;
            if (i < s.Length && s[i] == ']') i++;
            for (; i < s.Length; i++)
            {
                if (s[i] == ']') return i;
                int classEnd = ClassEnd(s, i);
                if (classEnd >= 0) i = classEnd;
            }
            return -1;
        }

        // [:alpha:], [=e=] or [.a.] at s[i], inside a bracket expression: the index of its last "]",
        // or -1 when there is none there. Such a part reaches bash as it is, so only what bash can
        // know is taken: a class name is lower-case letters, an equivalence class or a collating
        // symbol one character that is safe anywhere. Anything else is ordinary members, escaped
        // one by one ([[:$(id):]] must not become a command substitution).
        static int ClassEnd(string s, int i)
        {
            if (s[i] != '[' || i + 1 >= s.Length || !IsClassMark(s[i + 1])) return -1;
            char mark = s[i + 1];
            int start = i + 2;
            int term = s.IndexOf(mark.ToString() + "]", start, StringComparison.Ordinal);
            if (term <= start) return -1;
            if (mark != ':') return term == start + 1 && IsSafe(s[start], true) ? term + 1 : -1;
            for (int k = start; k < term; k++)
            {
                if (s[k] < 'a' || s[k] > 'z') return -1;
            }
            return term + 1;
        }

        static bool IsClassMark(char c)
        {
            return c == ':' || c == '.' || c == '=';
        }

        // The members of a bracket expression keep their meaning (ranges, negation, classes);
        // every other character that bash would read specially is escaped.
        static void AppendBracket(StringBuilder sb, string s, int open, int close)
        {
            sb.Append('[');
            int i = open + 1;
            if (s[i] == '!' || s[i] == '^')
            {
                sb.Append(s[i]);
                i++;
            }
            for (; i < close; i++)
            {
                char c = s[i];
                int classEnd = ClassEnd(s, i);
                if (classEnd >= 0 && classEnd < close)
                {
                    sb.Append(s, i, classEnd + 1 - i);
                    i = classEnd;
                    continue;
                }
                if (c == '!' || c == '^') sb.Append(c);
                else AppendEscaped(sb, c, true);
            }
            sb.Append(']');
        }

        /// <summary>
        /// The sh mode: an argument with $ or ` goes in double quotes, so bash substitutes
        /// variables and commands but still passes the result as one argument. Anything
        /// else is the smart mode.
        /// </summary>
        public static string Sh(string s)
        {
            if (s.IndexOf('$') < 0 && s.IndexOf('`') < 0) return Smart(s);

            var sb = new StringBuilder(s.Length + 8);
            int i = 0;
            // "~" and "~user" expand only outside quotes, so they stay in front of them.
            if (s[0] == '~')
            {
                int slash = s.IndexOf('/');
                if (slash > 0 && IsTildePrefix(s.Substring(0, slash)))
                {
                    sb.Append(s, 0, slash + 1);
                    i = slash + 1;
                }
            }

            sb.Append('"');
            while (i < s.Length)
            {
                char c = s[i];
                int end = -1;
                if (c == '$' && i + 1 < s.Length && s[i + 1] == '(') end = FindClose(s, i + 1, '(', ')');
                else if (c == '$' && i + 1 < s.Length && s[i + 1] == '{') end = FindClose(s, i + 1, '{', '}');
                else if (c == '`') end = FindBacktickClose(s, i);

                if (end >= 0)
                {
                    // $(...), ${...}, `...`: bash text, so quotes and backslashes inside are the user's.
                    sb.Append(s, i, end - i + 1);
                    i = end + 1;
                    continue;
                }
                // A $ that opens nothing valid stays: bash keeps a lone $ literal, and an
                // unterminated $( or ` is for bash to report.
                if (c == '"') sb.Append("\\\"");
                else if (c == '\\') sb.Append("\\\\");
                else sb.Append(c);
                i++;
            }
            sb.Append('"');
            return sb.ToString();
        }

        static bool IsTildePrefix(string s)
        {
            for (int i = 1; i < s.Length; i++)
            {
                char c = s[i];
                if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
                      c == '_' || c == '.' || c == '-'))
                    return false;
            }
            return true;
        }

        // Index of the bracket that closes the one at s[open], skipping quoted text and escapes.
        static int FindClose(string s, int open, char inc, char dec)
        {
            int depth = 0;
            for (int i = open; i < s.Length; i++)
            {
                char c = s[i];
                if (c == '\\')
                {
                    i++;
                }
                else if (c == '\'')
                {
                    i = s.IndexOf('\'', i + 1);
                    if (i < 0) return -1;
                }
                else if (c == '"')
                {
                    i = FindDoubleQuoteClose(s, i);
                    if (i < 0) return -1;
                }
                else if (c == inc)
                {
                    depth++;
                }
                else if (c == dec)
                {
                    depth--;
                    if (depth == 0) return i;
                }
            }
            return -1;
        }

        static int FindDoubleQuoteClose(string s, int open)
        {
            for (int i = open + 1; i < s.Length; i++)
            {
                if (s[i] == '\\') i++;
                else if (s[i] == '"') return i;
            }
            return -1;
        }

        static int FindBacktickClose(string s, int open)
        {
            for (int i = open + 1; i < s.Length; i++)
            {
                if (s[i] == '\\') i++;
                else if (s[i] == '`') return i;
            }
            return -1;
        }
    }
}
