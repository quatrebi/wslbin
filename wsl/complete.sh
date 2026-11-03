# wslbin completion helper. It runs inside WSL: "wslbin --complete" passes this text to
#   bash --noprofile --norc -c "<this text>" complete <cword> <word0> <word1> ...
# and reads the candidates for words[cword] from the output, one per line. The exit status is 0.
#
# The candidates come from bash-completion, the code that bash itself runs when you press Tab,
# so they are the same as in a Linux terminal. wslbin has already turned Windows paths into
# Linux paths and turns the candidates back.

cword=$1
shift
words=("$@")
cmd=${words[0]}

if [ -r /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion >/dev/null 2>&1
fi

# Readline splits a word at these characters (COMP_WORDBREAKS without blanks and quotes), and
# completion functions expect each separator to be a word of its own: "--file=x" is "--file",
# "=", "x". The words arrive from the shell already split at blanks.
breaks='@><=;|&(:'

split_word() {
    pieces=()
    local s=$1 piece='' sep='' c i
    for ((i = 0; i < ${#s}; i++)); do
        c=${s:i:1}
        if [[ $breaks == *"$c"* ]]; then
            if [[ -n $piece ]]; then pieces+=("$piece"); piece=''; fi
            sep+=$c
        else
            if [[ -n $sep ]]; then pieces+=("$sep"); sep=''; fi
            piece+=$c
        fi
    done
    if [[ -n $piece ]]; then pieces+=("$piece"); fi
    if [[ -n $sep ]]; then pieces+=("$sep"); fi
}

COMP_WORDS=()
new_cword=0
cur=''
prefix=''
for i in "${!words[@]}"; do
    w=${words[i]}
    split_word "$w"
    if (( i == cword )); then
        # the word being completed ends with the piece after the last separator (possibly empty)
        if [[ -z $w || $breaks == *"${w: -1}"* ]]; then pieces+=(''); fi
        COMP_WORDS+=("${pieces[@]}")
        new_cword=$(( ${#COMP_WORDS[@]} - 1 ))
        cur=${pieces[${#pieces[@]} - 1]}
        prefix=${w%"$cur"}
    elif (( ${#pieces[@]} )); then
        COMP_WORDS+=("${pieces[@]}")
    else
        COMP_WORDS+=('')
    fi
done
prev=''
if (( new_cword > 0 )); then prev=${COMP_WORDS[new_cword - 1]}; fi

COMP_CWORD=$new_cword
COMP_LINE="${words[*]:0:cword + 1}"
COMP_POINT=${#COMP_LINE}
COMP_TYPE=9
COMP_KEY=9
COMPREPLY=()

# Removes shell quoting: backslash + character -> character. Sets REPLY.
unquote() {
    local s=$1 out=''
    while [[ -n $s ]]; do
        if [[ $s == \\?* ]]; then
            out+=${s:1:1}
            s=${s:2}
        else
            out+=${s:0:1}
            s=${s:1}
        fi
    done
    REPLY=$out
}

# In a real completion readline removes the quoting from the word before compgen looks for
# files. In a plain "bash -c" nothing does, and bash-completion's _filedir, which quotes the
# word first ("./sub\ dir/"), then finds nothing for a name with a space.
compgen() {
    local n=$# args=("$@")
    if (( n >= 2 )) && [[ ${args[n - 2]} == -- ]]; then
        unquote "${args[n - 1]}"
        args[n - 1]=$REPLY
    fi
    builtin compgen "${args[@]}"
}

# Functions ask for these through compopt, which only works inside real completion.
opt_filenames=0
opt_fallback=0
compopt() {
    local a
    for a in "$@"; do
        case $a in
            filenames) opt_filenames=1 ;;
            default | bashdefault) opt_fallback=1 ;;
        esac
    done
    return 0
}

# What bash does on the first Tab for a command that has no completion yet: load completions/<cmd>
# and register it. Some commands are registered by bash_completion itself (ls, grep, cat and sort
# use _longopt), and the loader would replace those with the minimal completion: so it is only
# asked for the others.
spec=$(complete -p "$cmd" 2>/dev/null)
if [[ -z $spec ]]; then
    _completion_loader "$cmd" >/dev/null 2>&1
    spec=$(complete -p "$cmd" 2>/dev/null)
fi

if [[ $spec == *' -o '* ]]; then
    [[ $spec == *'-o filenames'* ]] && opt_filenames=1
    [[ $spec == *'-o default'* || $spec == *'-o bashdefault'* ]] && opt_fallback=1
fi

if [[ $spec =~ ' -F '([^ ]+) ]]; then
    fn=${BASH_REMATCH[1]}
    { "$fn" "$cmd" "$cur" "$prev"; } >/dev/null 2>&1
elif [[ -n $spec ]]; then
    # complete -W "..." / -f / -d / -A action ... cmd: the same options go to compgen
    opts=${spec#complete }
    opts=${opts% "$cmd"}
    mapfile -t COMPREPLY < <(eval "compgen $opts -- \"\$cur\"" 2>/dev/null)
else
    opt_filenames=1
    mapfile -t COMPREPLY < <(compgen -f -- "$cur" 2>/dev/null)
fi

if (( ${#COMPREPLY[@]} == 0 && opt_fallback )); then
    opt_filenames=1
    mapfile -t COMPREPLY < <(compgen -f -- "$cur" 2>/dev/null)
fi

# Functions that do not use "-o filenames" quote the candidates themselves (rsync gives
# "Program\ Files"), because readline inserts them as they are. The shells that call wslbin do
# their own quoting, so the backslashes go.
declare -A seen
for c in "${COMPREPLY[@]}"; do
    if (( ! opt_filenames )); then
        # a space after the word means "this word is finished" to readline; the callers add their own
        [[ $c == *' ' && $c != *'\ ' ]] && c=${c% }
        unquote "$c"
        c=$REPLY
    fi
    [[ -z $c || -n ${seen[$c]+x} ]] && continue
    seen[$c]=1
    # readline puts a slash after a directory when the completion is for file names; a leading
    # ~ has to be expanded before the test can see the directory
    d=$c
    if [[ $d == '~' || $d == '~/'* ]]; then d=$HOME${d:1}; fi
    if (( opt_filenames )) && [[ -d $d && $c != */ ]]; then c+=/; fi
    # the function completed only the last piece; the caller replaces the whole word
    if [[ -n $prefix && $c != "$prefix"* ]]; then c=$prefix$c; fi
    printf '%s\n' "$c"
done
exit 0
