# Copyright (C) 2026 Isak Lindgren
# SPDX-License-Identifier: GPL-2.0-or-later
#
# What GNOME says about the installed extension, and what that means for
# whether the user has to log out. Sourced by install.sh after lib/paths.sh,
# and driven against canned answers by tests/test-extension-live.sh.
# shellcheck shell=bash
#
# The model, from ui/extensionSystem.js and misc/extensionUtils.js in GNOME
# Shell 51. The shell scans the extension directories once, at login, and
# skips -- without listing it at all -- any extension whose metadata.json is
# missing or broken. An extension that is enabled then is imported, its
# JavaScript read and run, straight away. One that is not stays INITIALIZED,
# with only its metadata read, and is imported from disk the first time it is
# switched on. Once imported, its code stays loaded until the session ends:
# switching it off and on again runs the same code, and Wayland cannot restart
# the shell. So the question is whether the code GNOME has, or will import, is
# the code on disk now.
#
# Every gnome-extensions call runs under LC_ALL=C. Its labels are translated --
# "State:" is "Tillstånd:" in Swedish -- so parsing the user's locale silently
# finds nothing. LC_ALL=C also covers LANGUAGE, which gettext otherwise honours
# on its own but ignores in the C locale. The values are printed as they are,
# in UTF-8, whatever the locale.
#
# Over SSH these usually still reach the desktop session: with pam_systemd the
# login gets XDG_RUNTIME_DIR, and GLib falls back to $XDG_RUNTIME_DIR/bus when
# DBUS_SESSION_BUS_ADDRESS is unset. When nothing answers, the advice says so
# and stays conditional rather than guessing.
#
# State names changed in GNOME 46: ENABLED became ACTIVE, DISABLED became
# INACTIVE, ENABLING became ACTIVATING and DISABLING became DEACTIVATING. Both
# spellings are matched throughout.

# ext_live_query <uuid>: sets EXT_LIVE_STATE, EXT_LIVE_VERSION and
# EXT_LIVE_ENABLED.
#
# EXT_LIVE_STATE is the state as the C locale prints it (ACTIVE, OUT OF DATE,
# ERROR, INACTIVE, ...); "NOT LOADED" when the shell answered but has no such
# extension, because nothing loadable was there at login; or empty when no
# shell answered at all. `info` exits 2 both for an unknown UUID and for no
# shell, so only when it fails is `list` asked which it was: `list` names
# every extension the shell has scanned, OUT OF DATE and ERROR ones included,
# and fails when there is no shell.
#
# EXT_LIVE_VERSION is the version the shell read at login, as `info` prints
# it: the version-name, the integer version, or "name (integer)".
#
# EXT_LIVE_ENABLED is yes or no: whether enabled-extensions lists it, which is
# not the same as running. Empty when `info` does not say.
ext_live_query() {
    EXT_LIVE_STATE=""
    EXT_LIVE_VERSION=""
    EXT_LIVE_ENABLED=""
    local info list line
    if ! info="$(LC_ALL=C gnome-extensions info "$1" 2>/dev/null)"; then
        list="$(LC_ALL=C gnome-extensions list 2>/dev/null)" || return 0
        if ! grep -qxF -- "$1" <<<"$list"; then
            EXT_LIVE_STATE="NOT LOADED"
        fi
        return 0
    fi
    # Fields are indented, as "  Label: value". The description is printed as
    # written, so its later lines are not, and could say anything -- "State:"
    # included. So only indented lines count, and the last of each wins:
    # Version, Enabled and State all come after the description.
    while IFS= read -r line; do
        [[ "$line" == [[:space:]]* ]] || continue
        line="${line#"${line%%[![:space:]]*}"}"
        case "$line" in
        "State: "*)     EXT_LIVE_STATE="${line#State: }" ;;
        "Version: "*)   EXT_LIVE_VERSION="${line#Version: }" ;;
        "Enabled: Yes") EXT_LIVE_ENABLED=yes ;;
        "Enabled: No")  EXT_LIVE_ENABLED=no ;;
        esac
    done <<<"$info"
}

# ext_live_settle <uuid>: ext_live_query, retried for up to two seconds while
# the extension is still on its way up. `gnome-extensions enable` only writes
# enabled-extensions; the shell acts on that from an idle callback after the
# call has returned, so a query straight after it can see the state from
# before. Only for right after an enable that succeeded, and not while user
# extensions are switched off or the screen is locked: INACTIVE is then
# final, not a step on the way.
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

# ext_is_imported <state>: true for the states an extension is only ever in
# once GNOME has imported its code. INACTIVE is one of them: an extension that
# is enabled at login is imported first and enabled second, and one switched
# off after that -- or set aside while the screen is locked -- stays imported.
# One that has never been enabled this session is INITIALIZED instead.
ext_is_imported() {
    case "$1" in
    ACTIVE|INACTIVE|ACTIVATING|DEACTIVATING) return 0 ;;
    ENABLED|DISABLED|ENABLING|DISABLING) return 0 ;;
    esac
    return 1
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

# ext_screen_locked: true or false, or nothing when the shell does not answer.
# GNOME runs an extension only in the session modes its metadata.json lists,
# and this one lists none, which means the normal desktop only. Locking the
# screen disables it -- INACTIVE -- and unlocking enables it again, so
# INACTIVE then is no reason to switch it on, or to log out.
ext_screen_locked() {
    local out
    out="$(gdbus call --session --timeout 5 --dest org.gnome.ScreenSaver \
        --object-path /org/gnome/ScreenSaver \
        --method org.gnome.ScreenSaver.GetActive 2>/dev/null)" || return 0
    case "$out" in
    "(true,)")  echo true ;;
    "(false,)") echo false ;;
    esac
}

# ext_shell_started: when the running GNOME Shell started, in whole seconds
# since the epoch; nothing when that cannot be worked out. The shell reads its
# extensions no earlier than that, so files that have not changed since are
# files it read. The process is whichever owns org.gnome.Shell on the session
# bus, and /proc/<pid>/stat has its start time in clock ticks after boot.
# The boot time and the ticks are both rounded down, so the answer can be up
# to two seconds early: files written just before login then count as written
# after it, and the advice is a logout that was not needed, never the reverse.
ext_shell_started() {
    local out pid stat btime="" key value hz
    local re='^\(uint32 ([0-9]+),\)$'
    local -a fields
    out="$(gdbus call --session --timeout 5 --dest org.freedesktop.DBus \
        --object-path /org/freedesktop/DBus \
        --method org.freedesktop.DBus.GetConnectionUnixProcessID \
        org.gnome.Shell 2>/dev/null)" || return 0
    [[ "$out" =~ $re ]] || return 0
    pid="${BASH_REMATCH[1]}"
    { IFS= read -r stat <"/proc/$pid/stat"; } 2>/dev/null || return 0
    # Field 2, the command name, is in parentheses and may itself contain
    # spaces and parentheses, so counting starts after the last ") ". That
    # makes field 3 fields[0], and field 22, the start time, fields[19].
    read -ra fields <<<"${stat##*) }"
    [[ "${fields[19]:-}" =~ ^[0-9]+$ ]] || return 0
    while read -r key value _; do
        if [[ "$key" == btime ]]; then
            btime="$value"
        fi
    done </proc/stat
    hz="$(getconf CLK_TCK 2>/dev/null)" || return 0
    [[ "$btime" =~ ^[0-9]+$ && "$hz" =~ ^[0-9]+$ && "$hz" -gt 0 ]] || return 0
    echo $(( btime + fields[19] / hz ))
}

# ext_disk_facts <dir> <uuid> <gnome-shell-version> <since>: what GNOME would
# make of the extension in <dir> if it scanned it now. Sets:
#
#   EXT_DISK_PROBLEM       why GNOME would skip it, as a phrase for messages;
#                          empty when it would load it
#   EXT_DISK_SUPPORTED     yes or no: whether it supports that shell version
#   EXT_DISK_VERSION_NAME  metadata.json's version-name
#   EXT_DISK_VERSION_NUM   metadata.json's integer version
#   EXT_DISK_CHANGED       yes when something in it changed after <since>, in
#                          seconds since the epoch, and no when nothing did
#
# Each is empty when it cannot be worked out, and EXT_DISK_CHANGED is empty
# when <since> is.
ext_disk_facts() {
    EXT_DISK_PROBLEM=""
    EXT_DISK_SUPPORTED=""
    EXT_DISK_VERSION_NAME=""
    EXT_DISK_VERSION_NUM=""
    EXT_DISK_CHANGED=""
    local facts
    # Heredoc body and terminator stay at column 0, as they must.
    facts="$(/usr/bin/python3 -I - "$1" "$2" "$3" "$4" 2>/dev/null <<'PY'
import json
import os
import sys

ext_dir, uuid, shell, since = sys.argv[1:5]


def reject(constant):
    # NaN and Infinity: Python's json takes them, JSON.parse does not.
    raise ValueError(constant)


def check():
    """Why loadExtensionMetadata() would throw, if it would, and the metadata.

    Its checks, in its order. A directory GNOME's scan does not see as one is
    skipped before that, and so is a dangling symlink.
    """
    if not os.path.isdir(ext_dir):
        if os.path.islink(ext_dir):
            return "it is a symlink to something that is not there", {}
        if os.path.lexists(ext_dir):
            return "it is not a directory", {}
        return "it is not there", {}
    path = os.path.join(ext_dir, "metadata.json")
    if not os.path.exists(path):
        return "it has no metadata.json", {}
    try:
        # As GNOME's TextDecoder reads it: UTF-8, a byte-order mark dropped,
        # and bad bytes replaced rather than refused.
        with open(path, encoding="utf-8-sig", errors="replace") as f:
            text = f.read()
    except OSError:
        return "its metadata.json cannot be read", {}
    try:
        meta = json.loads(text, parse_constant=reject)
    except ValueError:
        return "its metadata.json is not valid JSON", {}
    if not isinstance(meta, dict):
        meta = {}
    for prop in ("uuid", "name", "description"):
        value = meta.get(prop)
        if not (isinstance(value, str) and value):
            return 'its metadata.json has no "%s"' % prop, meta
    versions = meta.get("shell-version")
    if not (isinstance(versions, list) and versions and
            all(isinstance(v, str) for v in versions)):
        return 'its metadata.json has no "shell-version" list', meta
    if meta["uuid"] != uuid:
        return 'its metadata.json names another UUID, "%s"' % meta["uuid"], meta
    return "", meta


def newest():
    """The latest change to anything GNOME reads from the extension.

    ctime as well as mtime: copies and unpacked archives keep their old
    mtime, but not their ctime. The symlink itself counts, since repointing
    it changes what GNOME reads. gschemas.compiled does not: install.sh
    rebuilds it on every run, from the same XML, and the shell reads it
    afresh each time the extension asks for its settings.
    """
    latest = 0.0

    def note(path):
        nonlocal latest
        try:
            st = os.lstat(path)
        except OSError:
            return
        latest = max(latest, st.st_mtime, st.st_ctime)

    note(ext_dir)
    top = os.path.realpath(ext_dir)
    note(top)
    for root, dirs, files in os.walk(top):
        rel = os.path.relpath(root, top)
        for name in dirs + files:
            # The schemas directory's own times change with every rebuild.
            if (rel, name) in ((".", "schemas"), ("schemas", "gschemas.compiled")):
                continue
            note(os.path.join(root, name))
    return latest


problem, meta = check()

supported = ""
major = shell.split(".")[0]
if not problem and major:
    # _isOutOfDate in ui/extensionSystem.js: some entry starts with the major
    # version, so "52" covers 52.rc and 52.1 alike.
    supported = "yes" if any(v.startswith(major) for v in meta["shell-version"]) else "no"

name = meta.get("version-name")
num = meta.get("version")
num_ok = isinstance(num, (int, float)) and not isinstance(num, bool)

changed = ""
if since and os.path.isdir(ext_dir):
    try:
        changed = "yes" if newest() > float(since) else "no"
    except ValueError:
        pass

lines = [problem, supported, name if isinstance(name, str) else "",
         "%.0f" % num if num_ok else "", changed]
# UTF-8 whatever the locale, as gnome-extensions prints the version.
out = "".join(line.replace("\n", " ") + "\n" for line in lines)
sys.stdout.buffer.write(out.encode("utf-8", "replace"))
PY
)" || return 0
    {
        IFS= read -r EXT_DISK_PROBLEM
        IFS= read -r EXT_DISK_SUPPORTED
        IFS= read -r EXT_DISK_VERSION_NAME
        IFS= read -r EXT_DISK_VERSION_NUM
        IFS= read -r EXT_DISK_CHANGED
    } <<<"$facts" || true
}

# ext_shell_setting <key>: an org.gnome.shell boolean as true or false, or
# empty when gsettings cannot answer. Reading needs no session bus.
ext_shell_setting() {
    gsettings get org.gnome.shell "$1" 2>/dev/null || true
}

# ext_gather <uuid> <ext-dir> <checkout-ext-dir>: everything ext_advice and
# ext_enable_report read, from the running system. Neither of them asks
# anything itself, so the test can set these by hand -- and the line in the
# enable step and the paragraph at the end read the same answers, and cannot
# contradict each other.
#
# EXT_REPO_SUPPORTED is EXT_DISK_SUPPORTED for this checkout's copy, which is
# what --link-extension would install, and empty when that copy is broken.
ext_gather() {
    local since
    ext_live_query "$1"
    EXT_FRESH_IMPORT=0
    EXT_SHELL_VERSION="$(ext_installed_shell_version)"
    EXT_USER_OFF="$(ext_shell_setting disable-user-extensions)"
    EXT_CHECK_OFF="$(ext_shell_setting disable-extension-version-validation)"
    EXT_ALLOW_INSTALL="$(ext_shell_setting allow-extension-installation)"
    EXT_LOCKED="$(ext_screen_locked)"

    # The checkout first, when it is not the installed copy: ext_disk_facts
    # sets the same globals the installed copy's facts end up in.
    EXT_REPO_SUPPORTED=""
    if [[ ! "$2" -ef "$3" ]]; then
        ext_disk_facts "$3" "$1" "$EXT_SHELL_VERSION" ""
        if [[ -z "$EXT_DISK_PROBLEM" ]]; then
            EXT_REPO_SUPPORTED="$EXT_DISK_SUPPORTED"
        fi
    fi
    since="$(ext_shell_started)"
    ext_disk_facts "$2" "$1" "$EXT_SHELL_VERSION" "$since"
    if [[ "$2" -ef "$3" && -z "$EXT_DISK_PROBLEM" ]]; then
        EXT_REPO_SUPPORTED="$EXT_DISK_SUPPORTED"
    fi
}

# ext_switch_on <uuid>: `gnome-extensions enable`, after ext_gather. Fails
# when the shell will not take it: there is no shell, or none that knows the
# UUID. Otherwise updates the live facts to what the shell shows afterwards,
# and sets EXT_FRESH_IMPORT when switching it on is what imported its code --
# an extension that was INITIALIZED is imported from disk now, so the code
# running is the code installed, whatever version the session read at login.
ext_switch_on() {
    local before="$EXT_LIVE_STATE"
    EXT_FRESH_IMPORT=0
    LC_ALL=C gnome-extensions enable "$1" >/dev/null 2>&1 || return 1
    # Exit 0 only means enabled-extensions lists it now. Nothing comes up
    # while user extensions are off or the screen is locked, so there is
    # nothing to wait for -- only Enabled has changed.
    if [[ "$EXT_USER_OFF" == true || "$EXT_LOCKED" == true ]]; then
        ext_live_query "$1"
        return 0
    fi
    ext_live_settle "$1"
    if [[ "$before" == INITIALIZED ]] && ext_is_running "$EXT_LIVE_STATE"; then
        EXT_FRESH_IMPORT=1
    fi
}

# ext_disk_version: the copy on disk's version, for messages.
ext_disk_version() {
    echo "${EXT_DISK_VERSION_NAME:-$EXT_DISK_VERSION_NUM}"
}

# ext_logout_verdict <who>: one word, the most definite thing the gathered
# facts show about getting the copy on disk running. Earlier checks outrank
# later ones. <who> is as for ext_advice.
#
#   no-user-dir   GNOME is set not to load extensions from the home directory
#   broken        GNOME would skip the copy on disk; a logout cannot help
#   unsupported   the installed GNOME Shell will refuse it; nor can a logout
#   new           this run put it in place; it loads at the next login
#   not-loaded    the shell has no such extension; it loads at the next login
#   out-of-date   GNOME refused it at login; the copy on disk loads at the next
#   error         it failed to load; the next login tries again
#   not-imported  GNOME has not imported its code yet, and will import the
#                 copy on disk whenever it is switched on
#   stale         the session loaded another version than the one on disk
#   changed       its files changed after the session started
#   current       what GNOME has loaded is what is on disk
#   unsure        none of the above can be shown
ext_logout_verdict() {
    local who="$1" name="$EXT_DISK_VERSION_NAME" num="$EXT_DISK_VERSION_NUM"
    local live="$EXT_LIVE_VERSION"

    # Read once, at login: when it is off, the per-user directory is not
    # scanned at all, and the extension can only ever be NOT LOADED.
    if [[ "$EXT_ALLOW_INSTALL" == false ]]; then
        echo no-user-dir
        return
    fi
    if [[ -n "$EXT_DISK_PROBLEM" ]]; then
        echo broken
        return
    fi
    if [[ "$EXT_DISK_SUPPORTED" == no && "$EXT_CHECK_OFF" != true ]]; then
        echo unsupported
        return
    fi
    # Newly placed: whatever the shell says is about the copy it read at
    # login, or about nothing.
    if [[ "$who" == new ]]; then
        echo new
        return
    fi
    case "$EXT_LIVE_STATE" in
    "NOT LOADED")  echo not-loaded; return ;;
    "OUT OF DATE") echo out-of-date; return ;;
    ERROR)         echo error; return ;;
    INITIALIZED)   echo not-imported; return ;;
    esac
    if ! ext_is_imported "$EXT_LIVE_STATE"; then
        echo unsure
        return
    fi
    if [[ "$EXT_FRESH_IMPORT" == 1 ]]; then
        echo current
        return
    fi
    # `info` prints whichever of the two versions metadata.json has, or both
    # as "name (integer)", so the live string is checked against all three
    # spellings of the copy on disk.
    if [[ -n "$live" && ( -n "$name" || -n "$num" ) &&
          "$live" != "$name" && "$live" != "$num" &&
          "$live" != "$name ($num)" ]]; then
        echo stale
        return
    fi
    # The version only changes on a release, so between releases a `git pull`
    # that touched extension/ looks exactly like one that did not. The files'
    # times tell them apart.
    case "$EXT_DISK_CHANGED" in
    yes) echo changed ;;
    no)  echo current ;;
    *)   echo unsure ;;
    esac
}

# ext_state_note: why an extension GNOME has, or will have, the right code
# for is not running now, if it is not. Nothing when the state is unknown, or
# when user extensions are off, which ext_advice has already explained.
ext_state_note() {
    local state="$EXT_LIVE_STATE"
    if [[ -z "$state" || "$EXT_USER_OFF" == true ]] || ext_is_running "$state"; then
        return 0
    fi
    if [[ "$EXT_LIVE_ENABLED" == no ]]; then
        cat <<EOF

It is switched off. To switch it on:

    gnome-extensions enable $UUID
EOF
    elif [[ "$EXT_LOCKED" == true ]]; then
        cat <<'EOF'

The screen is locked, and GNOME stops this extension while it is: it starts
again when you unlock the screen.
EOF
    else
        cat <<EOF

GNOME reports the extension as $state, so it is not running right now.
EOF
    fi
}

# ext_advice <who>: the closing paragraph(s) about logging out, from the
# globals ext_gather sets. <who> is:
#
#   new    this run put the extension in place, or repointed it
#   own    this checkout's symlink was already there
#   other  somebody else's copy -- a real directory, or a symlink elsewhere
ext_advice() {
    local who="$1" verdict major disk
    verdict="$(ext_logout_verdict "$who")"
    major="${EXT_SHELL_VERSION%%.*}"
    disk="$(ext_disk_version)"

    # First and whatever else is wrong: it stops this extension as surely as
    # anything below, and the enable step may have pointed here for it.
    if [[ "$EXT_USER_OFF" == true ]]; then
        cat <<'EOF'

User extensions are switched off -- the main switch in the Extensions app --
so GNOME runs none of them, this one included. To switch them back on:

    gsettings set org.gnome.shell disable-user-extensions false
EOF
    fi

    case "$verdict" in
    no-user-dir)
        cat <<'EOF'

GNOME is set not to load extensions from your home directory, which is where
this one is installed, so logging out alone does not help. To allow it, and
then log out and back in:

    gsettings set org.gnome.shell allow-extension-installation true

If an administrator has locked that setting, it stays off.
EOF
        ;;
    broken)
        cat <<EOF

GNOME cannot load the installed copy of the extension -- $EXT_DISK_PROBLEM --
so logging out does not help:

    $EXT_DIR
EOF
        if [[ "$who" == other ]]; then
            ext_advice_replace
        else
            cat <<'EOF'

It is this checkout's extension/ directory; `git status` shows what has
changed in it.
EOF
        fi
        ;;
    unsupported)
        if [[ "$who" == other ]]; then
            cat <<EOF

The installed copy of the extension does not support GNOME Shell $major, the
version installed, so GNOME will not load it -- logging out does not help:

    $EXT_DIR
EOF
            ext_advice_replace
        else
            cat <<EOF

This version of Input Lock X does not support GNOME Shell $major, the version
installed, so GNOME will not load it -- logging out does not help. Check for
a newer release:

    https://github.com/isalin/input-lock-x/releases
EOF
        fi
        ;;
    new)
        cat <<'EOF'

Log out and back in before the extension loads -- Wayland cannot reload
extensions in place.
EOF
        ;;
    not-loaded)
        cat <<'EOF'

GNOME has not loaded the extension: it was not there, or not loadable, when
you logged in. Log out and back in to load it -- Wayland cannot load
extensions in place.
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

This session loaded version $EXT_LIVE_VERSION of the extension, but version
$disk is installed now. Log out and back in to load it -- Wayland cannot
reload extensions in place.
EOF
        ext_state_note
        ;;
    changed)
        cat <<'EOF'

The extension's files have changed since this session started, so GNOME may
still have the old code loaded. Log out and back in to load the new code --
Wayland cannot reload extensions in place.
EOF
        ext_state_note
        ;;
    current)
        if ext_is_running "$EXT_LIVE_STATE"; then
            cat <<'EOF'

No logout needed -- GNOME is running the copy of the extension that is
installed now, and it picks the daemon up on its own within a second or so.
EOF
        else
            cat <<'EOF'

No logout needed -- GNOME has loaded the copy of the extension that is
installed now.
EOF
            ext_state_note
        fi
        ;;
    not-imported)
        cat <<'EOF'

GNOME has not loaded the extension's code yet, so whenever it starts, it
starts the copy that is installed now -- no logout needed.
EOF
        ext_state_note
        ;;
    *)
        ext_advice_unsure "$who"
        ;;
    esac
}

# Somebody else's copy that GNOME will not load: replacing it with this
# checkout is only worth suggesting when GNOME would load this one.
ext_advice_replace() {
    if [[ "$EXT_REPO_SUPPORTED" == yes ||
          ( "$EXT_REPO_SUPPORTED" == no && "$EXT_CHECK_OFF" == true ) ]]; then
        cat <<'EOF'

Update it from wherever it came from, or replace it with this checkout:

    ./install.sh --link-extension
EOF
    else
        cat <<'EOF'

Update it from wherever it came from, or check for a newer release of Input
Lock X:

    https://github.com/isalin/input-lock-x/releases
EOF
    fi
}

# The facts show neither that a logout is needed nor that it is not: there
# was no shell to ask, or no telling when it started.
ext_advice_unsure() {
    local who="$1" state="$EXT_LIVE_STATE"

    if [[ "$who" == own ]]; then
        local daemon="."
        if [[ -z "$state" ]]; then
            cat <<'EOF'

Could not ask GNOME Shell about the extension.
EOF
            daemon=": if the extension is running, it picks the daemon
up on its own."
        elif ext_is_running "$state"; then
            daemon=": the running extension picks it up on its own."
        fi
        cat <<EOF

The extension was already linked. If extension/ changed since you last logged
in -- after a git pull, say -- log out and back in to load the new version;
Wayland cannot reload extensions in place. If only the daemon changed, no
logout is needed$daemon
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
    # Nothing when it is running or there was no shell to ask.
    ext_state_note
}

# ext_enable_report <who> <enabled|queued|failed>: the line under "Enabling
# the extension". <how> is what happened: the shell took the enable, it was
# queued in the settings the next login reads, or neither. Read from the same
# facts as ext_advice, so a "see below" always has something below it.
ext_enable_report() {
    local who="$1" how="$2" head=queued verdict state="$EXT_LIVE_STATE"
    if [[ "$how" == failed ]]; then
        echo "   could not enable it, and could not queue it either." >&2
        echo "   Run this after logging back in:" >&2
        echo "       gnome-extensions enable $UUID" >&2
        return 0
    fi
    if [[ "$how" == enabled ]]; then
        head="switched on"
    fi
    verdict="$(ext_logout_verdict "$who")"

    case "$verdict" in
    no-user-dir|broken|unsupported)
        echo "   $head, but GNOME will not load it -- see below"
        return 0 ;;
    esac
    if [[ "$EXT_USER_OFF" == true ]]; then
        echo "   $head, but user extensions are switched off -- see below"
        return 0
    fi
    case "$verdict" in
    new|not-loaded)
        if [[ "$how" == queued ]]; then
            echo "   queued -- it comes up enabled after you log out and back in"
        else
            echo "   switched on -- it loads after you log out and back in"
        fi ;;
    out-of-date|error)
        echo "   $head, but GNOME reports it as $state -- see below" ;;
    stale|changed)
        echo "   $head -- the new version loads after you log out and back in" ;;
    *)
        if ext_is_running "$state"; then
            echo "   enabled"
        elif [[ -z "$state" && "$how" == queued ]]; then
            echo "   queued -- it comes up enabled at the next login"
        elif [[ -z "$state" ]]; then
            echo "   switched on"
        elif [[ "$EXT_LOCKED" == true ]]; then
            echo "   $head; the screen is locked, so it starts when you unlock it"
        else
            echo "   $head, but GNOME reports it as $state -- see below"
        fi ;;
    esac
}
