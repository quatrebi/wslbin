# wslbin for PowerShell: Tab completion for the wrappers, and the PowerShell names that would
# otherwise hide them. "wslbin --init pwsh" fills in the @...@ values and prints this; load it from
# the profile with
#     wslbin --init pwsh | Invoke-Expression
# Works in Windows PowerShell 5.1 and in PowerShell 7.
# PowerShell looks at aliases and functions before it looks for programs, so "man" would run
# Get-Help and never man.exe. A wrapper is something the user asked for: its name wins.
# This block is dot-sourced, so that it runs in the scope of the caller (the profile): an alias
# that has the AllScope option is copied into every scope, and removing it from a nested one
# would leave the real one in place.
. {
    foreach ($wslbinName in @(@NAMES@)) {
        if (Test-Path -LiteralPath "Alias:$wslbinName") { Remove-Item -LiteralPath "Alias:$wslbinName" -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath "Function:$wslbinName") { Remove-Item -LiteralPath "Function:$wslbinName" -Force -ErrorAction SilentlyContinue }
    }
}
Remove-Variable wslbinName -ErrorAction SilentlyContinue

& {
    $exe = @EXE@
    $wrappers = @(@NAMES@)
    $useFallback = @FALLBACK@

    # Before PowerShell 7.3 a quoted argument that ends in a backslash loses its closing quote.
    $doubleTrailingBackslash = $PSVersionTable.PSVersion -lt [version]'7.3'

    # 'a b' or "a b" -> a b. For the word being completed PowerShell hands over the quotes it has
    # seen so far and closes them itself: 'C:\Program F' for the text 'C:\Program F
    # (A block in a variable, not a function: the completer below is a closure, and a closure
    # keeps the variables around it but not the functions.)
    $removeQuotes = {
        param([string]$text)
        if ($text.Length -gt 0 -and ($text[0] -eq "'" -or $text[0] -eq '"')) {
            $quote = $text[0]
            $text = $text.Substring(1)
            if ($text.Length -gt 0 -and $text[$text.Length - 1] -eq $quote) { $text = $text.Substring(0, $text.Length - 1) }
            if ($quote -eq "'") { $text = $text.Replace("''", "'") }
        }
        return $text
    }

    $complete = {
        param($wordToComplete, $commandAst, $cursorPosition)

        # The words of the command as PowerShell sees them, without quotes; the one under the
        # cursor comes from $wordToComplete (the part before the cursor).
        $words = New-Object System.Collections.Generic.List[string]
        $cword = -1
        $elements = $commandAst.CommandElements
        for ($i = 0; $i -lt $elements.Count; $i++) {
            $extent = $elements[$i].Extent
            $text = & $removeQuotes $extent.Text
            if ($cursorPosition -ge $extent.StartOffset -and $cursorPosition -le $extent.EndOffset) {
                $cword = $i
                $text = & $removeQuotes $wordToComplete
            }
            $words.Add($text)
        }
        # the cursor is after the last word: the word being completed is empty and is not passed
        if ($cword -lt 0) { $cword = $words.Count }

        $arguments = @()
        foreach ($word in $words) {
            if ($doubleTrailingBackslash -and $word -match '\s' -and $word.EndsWith('\')) { $word = $word + '\' }
            $arguments += $word
        }

        # wslbin writes UTF-8 into a pipe, whatever the code page of the console is
        $previous = [Console]::OutputEncoding
        try {
            [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
            $lines = & $exe --complete $cword $arguments 2>$null
        }
        finally {
            [Console]::OutputEncoding = $previous
        }

        foreach ($line in $lines) {
            if (-not $line) { continue }
            $completion = $line
            # What goes into the line must be read by PowerShell as text, never as code: a file name can
            # hold ; & | $ ( ) or a quote, also one of the typographic single quotes that PowerShell takes
            # for ' as well. So anything but a plain word goes in single quotes, with every kind of single
            # quote doubled inside them.
            if ($completion -notmatch '^[\p{L}\p{N}_.+/\\:=%-][\p{L}\p{N}_.+/\\:=%@-]*$' -or $completion.StartsWith('--%')) {
                $completion = "'" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($completion) + "'"
                # A closing quote after a backslash would be lost on the way to the program. Only an argument
                # with a blank gets quotes there, so only then is the backslash doubled (as above).
                if ($doubleTrailingBackslash -and $line -match '\s' -and $line.EndsWith('\')) { $completion = $completion.Insert($completion.Length - 1, '\') }
            }
            [System.Management.Automation.CompletionResult]::new($completion, $line, 'ParameterValue', $line)
        }
    }.GetNewClosure()

    Register-ArgumentCompleter -Native -CommandName (@($wrappers) + 'wslbin') -ScriptBlock $complete

    # Optional (wslbin --init pwsh --native-fallback), PowerShell 7.6 and later: one handler for
    # every native command that has none of its own, which answers for wrappers made after this
    # session started. A handler registered later replaces an earlier one (checked in 7.6.7), so
    # this one would push out the fallback of another tool: that is why it is not the default.
    if ($useFallback -and $PSVersionTable.PSVersion -ge [version]'7.6') {
        $folder = Split-Path -Parent $exe
        $fallback = {
            param($wordToComplete, $commandAst, $cursorPosition)
            $first = $commandAst.CommandElements[0].Extent.Text.Trim('"', "'")
            $name = [System.IO.Path]::GetFileNameWithoutExtension($first)
            if ($name -and (Test-Path -LiteralPath (Join-Path $folder "$name.exe"))) {
                & $complete $wordToComplete $commandAst $cursorPosition
            }
        }.GetNewClosure()
        Register-ArgumentCompleter -NativeFallback -ScriptBlock $fallback
    }
}
