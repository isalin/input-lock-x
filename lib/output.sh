# Terminal output shared by install.sh and uninstall.sh.
# shellcheck shell=bash
#
# Sourced by both for the same reason lib/paths.sh is. say() had already been
# written out twice, and the boxed warning below has to look identical from
# either script: it is the one message that tells a user which copy of the
# extension their shell is actually loading, and it is worth nothing if it
# scrolls past looking like progress output.

# Colour only when someone is there to see it. `./install.sh | tee log` and
# `ssh host ./install.sh` both leave stdout a pipe, and escape codes in a log
# file outlive the install. NO_COLOR is the de-facto opt-out (no-color.org);
# TERM=dumb is what emacs shell-mode and some CI runners set.
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != dumb ]]; then
    _C_WARN=$'\033[1;33m'   # bold yellow -- orange on most terminal palettes
    _C_OFF=$'\033[0m'
else
    _C_WARN=""
    _C_OFF=""
fi

say() { printf '\n== %s\n' "$*"; }

# A warning, one argument per line, coloured as a block so a multi-line warning
# reads as one thing rather than four unrelated shouts. To stderr, like every
# other warning in these scripts, so `./install.sh >/dev/null` still shows it.
warn() {
    local first=1 line
    printf '%s' "$_C_WARN" >&2
    for line in "$@"; do
        if [[ $first -eq 1 ]]; then
            printf '   WARNING: %s\n' "$line" >&2
            first=0
        else
            printf '            %s\n' "$line" >&2
        fi
    done
    printf '%s' "$_C_OFF" >&2
}

# A bordered block, for a warning that must not be skimmed. One argument per
# line; an empty argument is a blank line. The rule is sized to the longest
# line so the box cannot come apart when someone edits the text later --
# capped, because one of the lines is a $HOME-derived path and an
# unusually long one would otherwise draw a rule wider than the terminal and
# wrap it into nonsense. A path that overshoots the rule is far more readable
# than a border that has wrapped twice.
warn_box() {
    local line width=0 rule
    for line in "$@"; do
        # `if`, not `(( ... )) && width=...`: under set -e a false test at the
        # end of an && list exits the script, and here that is every line that
        # is not the longest one.
        if (( ${#line} > width )); then
            width=${#line}
        fi
    done
    if (( width > 72 )); then
        width=72
    fi
    printf -v rule '%*s' "$((width + 4))" ''
    rule=${rule// /-}

    printf '\n%s%s\n' "$_C_WARN" "$rule" >&2
    for line in "$@"; do
        if [[ -n "$line" ]]; then
            printf '  %s\n' "$line" >&2
        else
            printf '\n' >&2
        fi
    done
    printf '%s%s\n' "$rule" "$_C_OFF" >&2
}
