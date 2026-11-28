namespace Wslbin.Tests;

// The escaping of one argument into one bash word (smart, sh and raw), through the whole command line so that
// the translation of paths in front of it is part of what is checked. The same cases are run by a real bash in
// the Integration tests.
public class BashTests
{
    const string Ru = "\u0444\u0430\u0439\u043B";            // "файл"
    const string RuSpaced = "\u0444 \u0430\u0439\u043B";      // "ф айл"

    public static TheoryData<string, string> SmartCases => new()
    {
        { "plain", "plain" },
        { "a b", @"a\ b" },
        { "x;echo pwned", @"x\;echo\ pwned" },
        { "$(id)", @"\$\(id\)" },
        { "$HOME", @"\$HOME" },
        { "`uname`", @"\`uname\`" },
        { "{print $1, $2}", @"\{print\ \$1,\ \$2\}" },
        { "{a,b}", @"\{a,b\}" },
        { "it's", @"it\'s" },
        { "say \"hi\"", @"say\ \""hi\""" },
        { @"a\b", @"a\\b" },
        { @"trailing\", @"trailing\\" },
        { "a|b&c", @"a\|b\&c" },
        { "a>b<c", @"a\>b\<c" },
        { "(paren)", @"\(paren\)" },
        { "#hash", @"\#hash" },
        { "!bang", @"\!bang" },
        { "^caret", @"\^caret" },
        { "%PATH%", "%PATH%" },
        { "key=value", "key=value" },
        { "", "''" },
        { Ru, Ru },
        { RuSpaced, RuSpaced.Replace(" ", @"\ ", StringComparison.Ordinal) },
        { "a\nb", "a'\n'b" },
        // wildcards stay live: bash expands them in the current directory
        { "*.log", "*.log" },
        { "file?.txt", "file?.txt" },
        { "[abc]*", "[abc]*" },
        { "[!a]*", "[!a]*" },
        { "[^a]*", "[^a]*" },
        { "[a-z]*", "[a-z]*" },
        { "[[:digit:]]*", "[[:digit:]]*" },
        { "a[[:alpha:]]b", "a[[:alpha:]]b" },
        { "[[=e=]x]", "[[=e=]x]" },
        { "[[.-.]]", "[[.-.]]" },
        // what sits between [: and :] reaches bash as it is only when it can be a class
        { "[[:a;id;:]]", @"[\[:a\;id\;:]\]" },
        { "[[:$(id):]]", @"[\[:\$\(id\):]\]" },
        { "[[=$(id)=]]", @"[\[=\$\(id\)=]\]" },
        { "[[.`id`.]]", @"[\[.\`id\`.]\]" },
        { "[[:${x}:]]", @"[\[:\$\{x\}:]\]" },
        { "[[:Alpha:]]", @"[\[:Alpha:]\]" },
        { "[[= =]]", @"[\[=\ =]\]" },
        { "a[b]c", "a[b]c" },
        { "[a b]", @"[a\ b]" },
        { "[]]", @"[\]]" },
        { "--include=*.txt", "--include=*.txt" },
        { "host:/srv/*", "host:/srv/*" },
        // a bracket that never closes is an ordinary character
        { "[", @"\[" },
        { "[abc", @"\[abc" },
        { "a]", @"a\]" },
        { "[]", @"\[\]" },
        // ~ expands only at the start of an argument
        { "~", "~" },
        { "~/x", "~/x" },
        { "~user", "~user" },
        { "a~b", @"a\~b" },
        { "~~", @"~\~" },
    };

    public static TheoryData<string, string> ShCases => new()
    {
        { "$HOME", "\"$HOME\"" },
        { "OUT=$HOME/out", "\"OUT=$HOME/out\"" },
        { "${A:-b c}", "\"${A:-b c}\"" },
        { "$(date)", "\"$(date)\"" },
        { "$((1+2))", "\"$((1+2))\"" },
        { "`uname`", "\"`uname`\"" },
        { "TAG=$(git rev-parse --short HEAD)", "\"TAG=$(git rev-parse --short HEAD)\"" },
        // quotes inside $(...) are bash text and stay as typed; outside they are escaped
        { "X=$(echo \"a b\")", "\"X=$(echo \"a b\")\"" },
        { "X=$(echo ')')", "\"X=$(echo ')')\"" },
        { "a\"b$c", "\"a\\\"b$c\"" },
        { @"a\b$c", "\"a\\\\b$c\"" },
        { "~/$X", "~/\"$X\"" },
        { @"C:\x\$HOME", "\"/mnt/c/x/$HOME\"" },
        // no $ or ` in the argument: same as the smart mode
        { "a;b", @"a\;b" },
        { "*.log", "*.log" },
    };

    public static TheoryData<string, string> RawCases => new()
    {
        { "plain", "plain" },
        { "a*", "'a*'" },
        { "it's", "'it'\\''s'" },
        { @"C:\x", @"'C:\x'" },
        { "$HOME", "'$HOME'" },
        { "", "''" },
        { "key=value", "key=value" },
        { "~", "'~'" },
    };

    [Theory]
    [MemberData(nameof(SmartCases))]
    public void Smart_mode_escapes_what_bash_would_read(string arg, string want)
    {
        using var m = new Machine();
        Assert.Equal($"tool {want}", m.Explain(arg));
    }

    [Theory]
    [MemberData(nameof(ShCases))]
    public void Sh_mode_lets_bash_substitute_but_keeps_one_argument(string arg, string want)
    {
        using var m = new Machine();
        Assert.Equal($"tool {want}", m.Explain("tool", [arg], flags: ["--wslbin-sh"]));
    }

    [Theory]
    [MemberData(nameof(RawCases))]
    public void Raw_mode_passes_the_argument_as_typed(string arg, string want)
    {
        using var m = new Machine();
        Assert.Equal($"tool {want}", m.Explain("tool", [arg], flags: ["--wslbin-raw"]));
    }

    [Fact]
    public void A_dollar_is_left_alone_in_the_default_mode()
    {
        using var m = new Machine();
        Assert.Equal(@"tool OUT=\$HOME/out", m.Explain("OUT=$HOME/out"));
    }

    [Fact]
    public void Several_arguments_are_joined_with_single_spaces()
    {
        using var m = new Machine();
        Assert.Equal("tool -av *.log /mnt/c/backup/", m.Explain("-av", "*.log", @"C:\backup\"));
    }

    [Theory]
    [InlineData("rsync", "rsync")]
    [InlineData("g++", "g++")]
    [InlineData("python3.12", "python3.12")]
    [InlineData("time", @"\time")]
    [InlineData("if", @"\if")]
    [InlineData("a=b", "'a=b'")]
    public void The_utility_name_is_never_a_keyword_or_an_assignment(string utility, string word)
    {
        Assert.Equal(word, Bash.CommandWord(utility));
    }

    [Theory]
    [InlineData("~", "$HOME")]
    [InlineData("~/bin", "$HOME/bin")]
    [InlineData("/a$b\"c", "/a\\$b\\\"c")]
    [InlineData("~x", "~x")]
    [InlineData(@"a\b`c", @"a\\b\`c")]
    public void Text_in_double_quotes_keeps_nothing_special_but_a_leading_tilde(string text, string want)
    {
        Assert.Equal(want, Bash.InDoubleQuotes(text));
    }
}
