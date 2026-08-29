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
    # look at, not the state file.
    #
    # pgrep, never pkill: `sudo pkill -f <pattern>` matches its own sudo
    # parent's command line and SIGTERMs it. -f either way, because the daemon
    # is a script and its $0 is the interpreter.
    local stray=""
    if command -v pgrep >/dev/null 2>&1; then
        stray="$(pgrep -f -- "$pattern" 2>/dev/null || true)"
    elif [[ -e "$state" ]]; then
        # No pgrep, so the state file is the only evidence there is. The daemon
        # removes it on the way out and the unit's ExecStopPost removes it
        # after a kill, so one still here means nothing we control cleared it.
        stray="unknown"
    fi

    if [[ -n "$stray" ]]; then
        echo >&2
        echo "$unlock is not installed, and something matching '$pattern' is" >&2
        echo "still running (${stray//$'\n'/ }). It may still hold the" >&2
        echo "keyboard and touchpad exclusively." >&2
        echo >&2
        echo "Stop it first -- over SSH or from another VT if the keyboard is" >&2
        echo "already dead -- then re-run this. To see what it is:" >&2
        echo "    ps -ef | grep -F -- '$pattern'" >&2
        echo "    sudo kill -9 <pid>" >&2
        return 1
    fi

    # Nothing is left to hold a grab, so a state file still here is a leftover
    # from a daemon that died badly, not a live lock. Safe to clear.
    sudo rm -f "$state"
    return 0
}
