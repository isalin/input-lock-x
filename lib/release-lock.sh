# Copyright (C) 2026 Isak Lindgren
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Make certain nothing is still holding an EVIOCGRAB on this machine's input.
# shellcheck shell=bash
#
# Sourced by install.sh (which releases the previous generation's lock before
# deleting its daemon) and uninstall.sh (which does the same for both
# generations). This was three copies of the same sequence; the failure mode of
# three copies of *this* sequence is a machine with a dead keyboard whose
# recovery script has just been deleted by the copy that got it wrong.
#
# Returns the honest status: 0 only if input is believed released.

# Which processes could still be holding a grab? Read out of /proc rather than
# asked of pgrep, for the two reasons scripts/input-lock-x-emergency-unlock
# already learned the hard way at its daemon_pids helper:
#
#   - `input-lock-x status` really does run the daemon binary, with --list.
#     That instance grabs nothing, so counting it makes every caller report a
#     failed release while input is perfectly fine -- and deciding that needs
#     the command line, which pgrep will not hand back on its own.
#   - pgrep is procps, not coreutils. Without it the old code fell back to "the
#     state file exists, so assume a stray", which turned a leftover file from a
#     daemon that died badly into a permanent failure no re-run could clear --
#     and uninstall.sh treats that as fatal.
#
# The third false positive that script names -- `vim daemon/input-lock-x-daemon.py`,
# `make check`'s py_compile, anything that merely *mentions* the daemon -- is
# not solved here but in lib/paths.sh, by anchoring DAEMON_PATTERN on the full
# install path. Hence substring matching rather than an anchor of our own:
# LEGACY_DAEMON_PATTERN is deliberately still a bare basename, because that
# generation moved its daemon between two directories part-way through and a
# machine can be running either.
stray_daemon_pids() {  # stray_daemon_pids <daemon-pattern>
    local pattern="$1" dir pid cmdline

    for dir in /proc/[0-9]*; do
        pid="${dir#/proc/}"
        # Ourselves. Both, not just $$: callers assign this in a command
        # substitution, and that subshell inherits the caller's command line
        # verbatim -- so a caller invoked with the pattern anywhere in its own
        # argv would find its own fork. $$ is the caller, $BASHPID the subshell.
        [[ "$pid" == "$$" || "$pid" == "$BASHPID" ]] && continue
        # The process can exit between the glob and the read, and kernel
        # threads have no cmdline at all. Either way, not a daemon.
        #
        # 2>/dev/null before the input redirect, not after: redirections are
        # applied left to right, and a failing `<` on a vanished /proc entry is
        # reported by the shell to whatever fd 2 is at that moment. Written the
        # usual way round it prints "No such file or directory" for every
        # process that exits mid-scan.
        cmdline="$(tr '\0' ' ' 2>/dev/null <"$dir/cmdline")" || continue
        [[ "$cmdline" == *"$pattern"* ]] || continue
        [[ "$cmdline" == *--list* ]] && continue
        echo "$pid"
    done

    # Explicit, because callers assign this in a command substitution under
    # `set -e`: a non-zero status from the last loop iteration would abort them.
    return 0
}

release_lock() {  # release_lock <unit> <state-file> <unlock-script> <daemon-pattern>
    local unit="$1" state="$2" unlock="$3" pattern="$4"

    # Prefer the installed recovery script. It does more than systemctl can: it
    # TERMs then KILLs an orphaned daemon systemd has lost track of, clears
    # sysfs inhibit flags, and verifies the result. Its exit status is designed
    # to be trusted by exactly these callers, so pass it straight through.
    if [[ -x "$unlock" ]]; then
        sudo "$unlock"
        return
    fi

    # No recovery script: an install that never finished, or one already
    # half-removed by hand. Do the same thing directly, best effort -- each
    # step is idempotent, and the kernel drops the grab as soon as the daemon's
    # fds close, so a KILL is a complete release even when nothing else works.
    sudo systemctl stop "$unit" 2>/dev/null || true
    sudo systemctl kill --signal=KILL "$unit" 2>/dev/null || true

    # Then check, rather than assume. Both systemctl calls above are best
    # effort, so their status says nothing: on a daemon orphaned from its unit
    # they both fail and the release has not happened. Every caller deletes the
    # recovery tooling on a 0 from here, so a 0 has to be earned.
    #
    # A grab lives on the fd that took it, so "no daemon process" and "no grab"
    # are the same statement -- which makes the process list the evidence to
    # look at, not the state file. Read it, never act on it in bulk: the reason
    # this is not `sudo pkill -f <pattern>` is that pkill matches its own sudo
    # parent's command line and SIGTERMs it.
    local stray
    stray="$(stray_daemon_pids "$pattern")"

    if [[ -n "$stray" ]]; then
        echo >&2
        echo "$unlock is not installed, and something matching '$pattern' is" >&2
        echo "still running (${stray//$'\n'/ }). It may still hold the" >&2
        echo "keyboard and touchpad exclusively." >&2
        echo >&2
        echo "Stop it first -- over SSH or from another VT if the keyboard is" >&2
        echo "already dead -- then re-run this. To see what they are:" >&2
        echo "    ps -fp ${stray//$'\n'/,}" >&2
        echo "    sudo kill -9 ${stray//$'\n'/ }" >&2
        return 1
    fi

    # Nothing is left to hold a grab, so a state file still here is a leftover
    # from a daemon that died badly, not a live lock. Safe to clear.
    sudo rm -f "$state"
    return 0
}
