# Copyright (C) 2026 Isak Lindgren
# SPDX-License-Identifier: GPL-2.0-or-later
#
# What GNOME says about the installed extension, and what that means for
# whether the user has to log out. Sourced by install.sh after lib/paths.sh,
# and driven against canned answers by tests/test-extension-live.sh.
# shellcheck shell=bash
#
# Every gnome-extensions call runs under LC_ALL=C. Its labels are translated --
# "State:" is "Tillstånd:" in Swedish -- so parsing the user's locale silently
# finds nothing. LC_ALL=C also covers LANGUAGE, which gettext otherwise honours
# on its own but ignores in the C locale.
#
# Over SSH these usually still reach the desktop session: with pam_systemd the
# login gets XDG_RUNTIME_DIR, and GLib falls back to $XDG_RUNTIME_DIR/bus when
# DBUS_SESSION_BUS_ADDRESS is unset. When nothing answers, the advice says so
# and stays conditional rather than guessing.
#
# State names changed in GNOME 46: ENABLED became ACTIVE, DISABLED became
# INACTIVE, ENABLING became ACTIVATING. Both spellings are matched throughout.

# ext_live_query <uuid>: sets EXT_LIVE_STATE and EXT_LIVE_VERSION.
#
# EXT_LIVE_STATE is the state as the C locale prints it (ACTIVE, OUT OF DATE,
# ERROR, INACTIVE, ...); "NOT LOADED" when the shell answered but has never
# scanned this UUID, because it was put on disk after login; or empty when no
# shell answered at all. `list` is asked first because `info` exits 2 both for
# an unknown UUID and for no shell, with nothing on stdout to tell them apart.
# `list` names every extension the shell has scanned, including OUT OF DATE
# and ERROR ones.
#
# EXT_LIVE_VERSION is the version the shell read at login, as `info` prints
# it: the version-name, the integer version, or "name (integer)".
ext_live_query() {
    EXT_LIVE_STATE=""
    EXT_LIVE_VERSION=""
    local list info
    list="$(LC_ALL=C gnome-extensions list 2>/dev/null)" || return 0
    if ! grep -qxF -- "$1" <<<"$list"; then
        EXT_LIVE_STATE="NOT LOADED"
        return 0
    fi
    info="$(LC_ALL=C gnome-extensions info "$1" 2>/dev/null)" || return 0
    # Indented fields only, and the last match: the description is printed
    # unindented and may span lines, and one of them could start "State:".
    EXT_LIVE_STATE="$(sed -n 's/^[[:space:]][[:space:]]*State:[[:space:]]*//p' \
        <<<"$info" | tail -n 1)"
    EXT_LIVE_VERSION="$(sed -n 's/^[[:space:]][[:space:]]*Version:[[:space:]]*//p' \
        <<<"$info" | tail -n 1)"
}

# ext_live_settle <uuid>: ext_live_query, retried for up to two seconds while
# the extension is still on its way up. `gnome-extensions enable` only writes
# enabled-extensions; the shell acts on that from an idle callback after the
# call has returned, so a query straight after it can see the state from
# before. Only for right after an enable that succeeded, and not while user
# extensions are switched off: INACTIVE is then final, not a step on the way.
ext_live_settle() {
    local tries=10
    ext_live_query "$1"
    while (( tries-- > 0 )); do
        case "$EXT_LIVE_STATE" in
        INITIALIZED|INACTIVE|DISABLED|ACTIVATING|ENABLING) ;;
        *) return 0 ;;
        esac
        sleep 0.2
        ext_live_query "$1"
    done
}

# ext_is_running <state>: true for the one state in which the extension's code
# is actually running.
ext_is_running() {
    [[ "$1" == ACTIVE || "$1" == ENABLED ]]
}

# ext_installed_shell_version: the installed GNOME Shell's version, which is
# what the next login runs -- not necessarily the running shell, after an
# upgrade. `gnome-extensions version` answers without a shell to ask.
ext_installed_shell_version() {
    local v
    v="$(LC_ALL=C gnome-extensions version 2>/dev/null)" || v=""
    if [[ -z "$v" ]]; then
        v="$(LC_ALL=C gnome-shell --version 2>/dev/null \
            | sed -n 's/^GNOME Shell \([0-9][0-9.a-z]*\).*/\1/p')" || v=""
    fi
    echo "$v"
}

# ext_disk_facts <metadata.json> <gnome-shell-version>: sets
# EXT_DISK_SUPPORTED to yes or no, and EXT_DISK_VERSION_NAME and
# EXT_DISK_VERSION_NUM to metadata.json's version-name and integer version.
# Each is empty when it cannot be worked out.
#
# "Supported" is GNOME's own rule, _isOutOfDate in ui/extensionSystem.js: some
# shell-version entry starts with the major version, so "52" covers 52.rc and
# 52.1 alike.
ext_disk_facts() {
    EXT_DISK_SUPPORTED=""
    EXT_DISK_VERSION_NAME=""
    EXT_DISK_VERSION_NUM=""
    local facts
    # Heredoc body and terminator stay at column 0, as they must.
    facts="$(/usr/bin/python3 -I - "$1" "$2" 2>/dev/null <<'PY'
import json
import sys

with open(sys.argv[1]) as f:
    meta = json.load(f)

major = sys.argv[2].split(".")[0]
versions = meta.get("shell-version")
if major and isinstance(versions, list):
    print("yes" if any(str(v).startswith(major) for v in versions) else "no")
else:
    print()

name = meta.get("version-name")
print(name.replace("\n", " ") if isinstance(name, str) else "")

num = meta.get("version")
ok = isinstance(num, (int, float)) and not isinstance(num, bool)
print("%.0f" % num if ok else "")
PY
)" || return 0
    EXT_DISK_SUPPORTED="$(sed -n 1p <<<"$facts")"
    EXT_DISK_VERSION_NAME="$(sed -n 2p <<<"$facts")"
    EXT_DISK_VERSION_NUM="$(sed -n 3p <<<"$facts")"
}

# ext_shell_setting <key>: an org.gnome.shell boolean as true or false, or
# empty when gsettings cannot answer. Reading needs no session bus.
ext_shell_setting() {
    gsettings get org.gnome.shell "$1" 2>/dev/null || true
}

# ext_gather <uuid> <metadata.json>: everything ext_advice reads, from the
# running system. ext_advice itself never asks anything, so the test can set
# these by hand.
ext_gather() {
    ext_live_query "$1"
    EXT_SHELL_VERSION="$(ext_installed_shell_version)"
    ext_disk_facts "$2" "$EXT_SHELL_VERSION"
    EXT_USER_OFF="$(ext_shell_setting disable-user-extensions)"
    EXT_CHECK_OFF="$(ext_shell_setting disable-extension-version-validation)"
}

# ext_disk_version: the copy on disk's version, for messages.
ext_disk_version() {
    echo "${EXT_DISK_VERSION_NAME:-$EXT_DISK_VERSION_NUM}"
}

# ext_logout_verdict: one word, the most definite thing the gathered facts
# show about getting the copy on disk running. Earlier checks outrank later.
#
#   unsupported  the installed GNOME Shell will refuse it; a logout cannot help
#   not-loaded   the shell has never scanned it; it loads at the next login
#   out-of-date  GNOME refused it at login; the copy on disk loads at the next
#   error        it failed to load; the next login tries again
#   stale        the session read a different version than the one on disk
#   unsure       none of the above can be shown
ext_logout_verdict() {
    local name="$EXT_DISK_VERSION_NAME" num="$EXT_DISK_VERSION_NUM"
    local live="$EXT_LIVE_VERSION"

    if [[ "$EXT_DISK_SUPPORTED" == no && "$EXT_CHECK_OFF" != true ]]; then
        echo unsupported
        return
    fi
    case "$EXT_LIVE_STATE" in
    "NOT LOADED")  echo not-loaded; return ;;
    "OUT OF DATE") echo out-of-date; return ;;
    ERROR)         echo error; return ;;
    esac
    # `info` prints whichever of the two versions metadata.json has, or both
    # as "name (integer)", so the live string is checked against all three
    # spellings of the copy on disk.
    if [[ -n "$live" && ( -n "$name" || -n "$num" ) &&
          "$live" != "$name" && "$live" != "$num" &&
          "$live" != "$name ($num)" ]]; then
        echo stale
        return
    fi
    echo unsure
}

# ext_advice <who>: the closing paragraph(s) about logging out, from the
# globals ext_gather sets. <who> is:
#
#   new    this run put the extension in place, or repointed it
#   own    this checkout's symlink was already there
#   other  somebody else's copy -- a real directory, or a symlink elsewhere
ext_advice() {
    local who="$1" verdict major disk
    verdict="$(ext_logout_verdict)"
    major="${EXT_SHELL_VERSION%%.*}"
    disk="$(ext_disk_version)"

    if [[ "$verdict" == unsupported ]]; then
        if [[ "$who" == other ]]; then
            cat <<EOF

The installed copy of the extension does not support GNOME Shell $major, the
version installed, so GNOME will not load it -- logging out does not help:

    $EXT_DIR

Update it from wherever it came from, or replace it with this checkout:

    ./install.sh --link-extension
EOF
        else
            cat <<EOF

This version of Input Lock X does not support GNOME Shell $major, the version
installed, so GNOME will not load it -- logging out does not help. Check for
a newer release:

    https://github.com/isalin/input-lock-x/releases
EOF
        fi
        return
    fi

    if [[ "$EXT_USER_OFF" == true ]]; then
        cat <<'EOF'

User extensions are switched off -- the main switch in the Extensions app --
so GNOME runs none of them, this one included. To switch them back on:

    gsettings set org.gnome.shell disable-user-extensions false
EOF
    fi

    # Newly placed: Wayland cannot load an extension in place, whatever the
    # shell says about the copy it read at login.
    if [[ "$who" == new ]]; then
        cat <<'EOF'

Log out and back in before the extension loads -- Wayland cannot reload
extensions in place.
EOF
        return
    fi

    case "$verdict" in
    not-loaded)
        cat <<'EOF'

GNOME has not loaded the extension: it was put in place after you logged in.
Log out and back in to load it -- Wayland cannot load extensions in place.
EOF
        ;;
    out-of-date)
        cat <<'EOF'

GNOME reports the extension as OUT OF DATE, so it is not running. Log out and
back in to load the copy that is installed now -- Wayland cannot reload
extensions in place.
EOF
        ;;
    error)
        cat <<'EOF'

GNOME reports the extension as ERROR, so it is not running. Log out and back in
to try again. If it still fails, the reason is in the shell's log:

    journalctl -b /usr/bin/gnome-shell | grep -i input-lock-x
EOF
        ;;
    stale)
        cat <<EOF

This session is running version $EXT_LIVE_VERSION of the extension, but
version $disk is installed now. Log out and back in to load it -- Wayland
cannot reload extensions in place.
EOF
        ;;
    *)
        ext_advice_unsure "$who"
        ;;
    esac
}

# The facts show neither that a logout is needed nor that it is not.
ext_advice_unsure() {
    local who="$1" state="$EXT_LIVE_STATE"

    # With user extensions off, every extension is INACTIVE; the paragraph
    # above has already said why and what to do.
    if [[ -n "$state" && "$EXT_USER_OFF" != true ]] && ! ext_is_running "$state"; then
        cat <<EOF

GNOME reports the extension as $state, so it is not running. To switch it on:

    gnome-extensions enable $UUID
EOF
    fi

    if [[ "$who" == own ]]; then
        if [[ -z "$state" ]]; then
            cat <<'EOF'

Could not ask GNOME Shell about the extension.
EOF
        fi
        # The version only changes on a release, so between releases a
        # `git pull` that touched extension/ looks exactly like one that did
        # not. Only the user knows which it was.
        cat <<'EOF'

The extension was already linked. If extension/ changed since you last logged
in -- after a git pull, say -- log out and back in to load the new version;
Wayland cannot reload extensions in place. If only the daemon changed, no
logout is needed: the running extension picks it up on its own.
EOF
    elif ext_is_running "$state"; then
        cat <<'EOF'

No logout needed -- the extension that is already installed picks the daemon
up on its own, within a second or so.
EOF
    elif [[ -z "$state" ]]; then
        cat <<'EOF'

Could not ask GNOME Shell about the extension. If the copy that is already
installed is running, it picks the daemon up on its own within a second or
so, and no logout is needed.
EOF
    fi
}
