#!/bin/bash
# Install Input Lock X: the GNOME extension (user) plus the daemon, systemd
# unit, polkit rule and CLI scripts (system, needs sudo).
#
# Safe to re-run. /etc/input-lock-x.conf is never overwritten.
#
# By default the extension is only linked in when nothing else has installed
# it. A copy from extensions.gnome.org is left exactly where it is and only the
# daemon goes in -- see --link-extension to override that.
#
# Usage: ./install.sh [--no-sudoers] [--daemon-only] [--link-extension]
#   --no-sudoers      do not install the passwordless sudo drop-in. Recovery over
#                     SSH then needs a TTY: ssh -t <host> sudo input-lock-x-emergency-unlock
#   --daemon-only     install the daemon, unit, polkit rule and CLI only. Never
#                     touches ~/.local/share/gnome-shell/extensions at all. Use
#                     this when the extension came from extensions.gnome.org.
#   --link-extension  replace whatever is at the extension path with a symlink
#                     to this checkout, even if something else installed it.
#                     For developing on the extension itself.

set -euo pipefail

# pwd -P, not pwd: bash's pwd is logical, so a checkout reached through a
# symlink reports the path taken to get here rather than where it is. The
# "already linked" check below compares this against readlink output, which
# is always physical -- with the logical form that branch is simply dead.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# Both sets of names, the release sequence and the warning formatting live in
# files shared with uninstall.sh so the two can never disagree about any of
# them.
for helper in output paths legacy-paths release-lock; do
    if [[ ! -r "$REPO/lib/$helper.sh" ]]; then
        echo "missing $REPO/lib/$helper.sh -- run this from a full checkout" >&2
        exit 1
    fi
done
# shellcheck source=lib/output.sh
source "$REPO/lib/output.sh"
# shellcheck source=lib/paths.sh
source "$REPO/lib/paths.sh"
# shellcheck source=lib/legacy-paths.sh
source "$REPO/lib/legacy-paths.sh"
# shellcheck source=lib/release-lock.sh
source "$REPO/lib/release-lock.sh"

INSTALL_SUDOERS=1
# auto: link only if nothing else owns the extension directory.
# link: always link, replacing whatever is there.
# none: never touch the extensions directory.
LINK_MODE=auto

# The help text is the comment block at the top of this file. Extracted by
# shape rather than by line number: `sed -n '2,9p'` was correct only until
# someone added a line above it, and nothing in `make check` can catch a window
# that has slid. Skip the shebang, strip the leading '# ', drop an SPDX line if
# one is ever added here, and stop at the first line that is not a comment.
# scripts/input-lock-x carries the same function verbatim, which is the point:
# with ranges the two copies had already drifted to different numbers.
usage() {
    awk 'NR == 1 { next }
         /^#/ {
             sub(/^# ?/, "")
             if ($0 !~ /^SPDX-License-Identifier:/)
                 print
             next
         }
         { exit }' "$0"
}

for arg in "$@"; do
    case "$arg" in
        --no-sudoers) INSTALL_SUDOERS=0 ;;
        # Refused rather than last-wins. These two are exact opposites, and the
        # wrong one winning quietly is how an extensions.gnome.org install gets
        # replaced by a symlink -- the thing this flag pair exists to prevent.
        --daemon-only)
            if [[ "$LINK_MODE" == link ]]; then
                echo "--daemon-only and --link-extension contradict each other" >&2
                exit 1
            fi
            LINK_MODE=none ;;
        --link-extension)
            if [[ "$LINK_MODE" == none ]]; then
                echo "--daemon-only and --link-extension contradict each other" >&2
                exit 1
            fi
            LINK_MODE=link ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $arg (try --help)" >&2; exit 1 ;;
    esac
done

if [[ $EUID -eq 0 ]]; then
    echo "Run this as your normal user; it will call sudo where it needs to." >&2
    exit 1
fi

# --------------------------------------------------------------------------
# Decide what happens to the extension directory before anything else, because
# the prerequisite check below depends on the answer: glib-compile-schemas is
# only needed when this checkout is the copy the shell loads.
#
# Only the `foreign` case is new. A fresh clone has nothing at $EXT_DIR and
# gets the symlink exactly as it always has; a re-run finds our own symlink and
# leaves it. What used to be wrong is everything else: a real directory means
# somebody else installed the extension -- almost certainly
# extensions.gnome.org -- and `rm -rf` on it silently swapped a managed install
# for a checkout the Extensions app cannot update, and that breaks outright if
# this directory is ever moved or deleted.
#
# Nothing between here and the linking block can change the answer: the legacy
# migration below touches $LEGACY_EXT_DIR, which is a different path.
EXT_PRESENT=0
if [[ -e "$EXT_DIR" || -L "$EXT_DIR" ]]; then
    EXT_PRESENT=1
fi

if [[ "$LINK_MODE" == none ]]; then
    EXT_ACTION=skip
elif [[ $EXT_PRESENT -eq 0 ]]; then
    EXT_ACTION=link
elif [[ -L "$EXT_DIR" && "$(readlink -f "$EXT_DIR")" == "$REPO/extension" ]]; then
    EXT_ACTION=keep
elif [[ "$LINK_MODE" == link ]]; then
    EXT_ACTION=link
else
    EXT_ACTION=foreign
fi

# True when the shell ends up loading this checkout, whether we linked it just
# now or found our own symlink already in place. Gates the schema compile: the
# schema has to be compiled where the shell reads it from.
EXT_IS_REPO=0
if [[ "$EXT_ACTION" == link || "$EXT_ACTION" == keep ]]; then
    EXT_IS_REPO=1
fi

# --------------------------------------------------------------------------
say "Checking prerequisites"

fatal=0
need() {  # need <command> <hint>
    if command -v "$1" >/dev/null 2>&1; then
        echo "   $1"
    else
        echo "   MISSING: $1 -- $2" >&2
        fatal=1
    fi
}

need systemctl "this installs a systemd service, and there is no other backend"
need sudo "this refuses to run as root and reaches for sudo instead; without it, run the sudo lines by hand as root"
# Only needed when this checkout is the copy the shell loads, because then the
# schema has to be compiled in place. An extension installed from
# extensions.gnome.org carries its own compiled schema, so a daemon-only
# install has no use for the tool and must not fail for want of it.
if [[ $EXT_IS_REPO -eq 1 ]]; then
    need glib-compile-schemas "Debian/Ubuntu: libglib2.0-bin; Fedora: glib2-devel; Arch: glib2"
fi
# Only used by usage() above, so a machine without it has already got this far.
# Listed anyway: this loop is the one place that says what the script needs.
need awk "Debian/Ubuntu: mawk or gawk; Fedora: gawk; Arch: gawk"

# The unit's ExecStart runs the daemon directly and its shebang is
# /usr/bin/python3, so a python3 that only exists elsewhere in PATH is not
# enough. No third-party modules are used -- the stdlib is all it needs.
if [[ -x /usr/bin/python3 ]]; then
    echo "   /usr/bin/python3"
else
    echo "   MISSING: /usr/bin/python3 -- the daemon's interpreter" >&2
    fatal=1
fi

# JS rules need polkit >= 0.106. Anything running GNOME 45+ has it, but a
# missing directory means the rule would be installed where nothing reads it,
# and every toggle would fail with a permission error and no clue why.
if [[ -d /etc/polkit-1/rules.d ]]; then
    echo "   /etc/polkit-1/rules.d"
else
    echo "   MISSING: /etc/polkit-1/rules.d -- polkit is too old or not installed" >&2
    fatal=1
fi

if command -v gnome-extensions >/dev/null 2>&1; then
    echo "   gnome-extensions"
else
    echo "   note: gnome-extensions not found; enable the extension by hand later"
fi

if [[ $fatal -ne 0 ]]; then
    echo >&2
    echo "Install the missing pieces and re-run." >&2
    exit 1
fi

# The polkit rule and the sudoers drop-in grant to wheel, sudo and admin --
# whichever of them the distro actually uses. Being in none of them is not
# fatal (the CLI still works under sudo), but the panel button will not.
ADMIN_GROUP=""
for group in wheel sudo admin; do
    if id -nG | tr ' ' '\n' | grep -qx "$group"; then
        ADMIN_GROUP="$group"
        break
    fi
done
if [[ -n "$ADMIN_GROUP" ]]; then
    echo "   admin group: $ADMIN_GROUP"
else
    warn "you are in none of wheel, sudo or admin." \
         "The panel button and shortcut will fail with a permission error." \
         "Add yourself to your distro's admin group, or edit the group list" \
         "in $POLKIT_RULE after installing."
fi

# --------------------------------------------------------------------------
# Migrate from the pre-rename generation, if this machine has one. Everything
# below is a no-op on a fresh install.

# `if`, not `[[ -e x ]] && flag=1`: under set -e a false test at the end of an
# && list exits the script, which on a fresh install is every one of them.
legacy_present=0
for path in "$LEGACY_CONF" "$LEGACY_EXT_DIR" "$LEGACY_LIB_DIR" "$LEGACY_STATE" \
        "${LEGACY_FILES[@]}"; do
    if [[ -e "$path" ]]; then
        legacy_present=1
        break
    fi
done

# LEGACY_DCONF_PATH is a dconf path, not a filesystem one, so it cannot join the
# loop above -- but the block below is the only thing that carries the old
# keybinding across and resets the old path, and a machine whose files were
# removed by hand would otherwise keep those keys forever.
if [[ $legacy_present -eq 0 ]] && command -v dconf >/dev/null 2>&1 && \
        [[ -n "$(dconf list "$LEGACY_DCONF_PATH" 2>/dev/null || true)" ]]; then
    legacy_present=1
fi

if [[ $legacy_present -eq 1 ]]; then
    say "Migrating from the previous install (minibookx-hid-lock)"

    # Release first. Deleting the old unit file while an orphaned daemon still
    # holds an EVIOCGRAB would strand the keyboard with none of the tooling
    # that knows how to let go of it -- so a failure here stops the install.
    if ! release_lock "$LEGACY_UNIT" "$LEGACY_STATE" "$LEGACY_UNLOCK" \
            "$LEGACY_DAEMON_PATTERN"; then
        echo >&2
        echo "The old recovery script reported failure. Refusing to continue" >&2
        echo "while input may still be locked: removing the old daemon now" >&2
        echo "would delete the only thing that can release it." >&2
        exit 1
    fi
    echo "   old lock released"

    # Copy rather than move, and only when the target is absent: the old file
    # carries explicit `patterns`, which the new daemon reads as patterns mode,
    # so this machine keeps grabbing exactly the devices it grabbed before.
    if [[ -e "$LEGACY_CONF" && ! -e "$CONF" ]]; then
        sudo install -m 0644 "$LEGACY_CONF" "$CONF"
        echo "   config carried over: $LEGACY_CONF -> $CONF"
    fi

    # dconf, not gsettings: the old schema is about to stop existing, and dconf
    # addresses keys by path without needing one.
    if command -v dconf >/dev/null 2>&1; then
        old_binding="$(dconf read "${LEGACY_DCONF_PATH}toggle-hid" 2>/dev/null || true)"
        if [[ -n "$old_binding" ]]; then
            dconf write "${DCONF_PATH}toggle-hid" "$old_binding"
            echo "   keybinding carried over: $old_binding"
        fi
        dconf reset -f "$LEGACY_DCONF_PATH" 2>/dev/null || true
    fi

    gnome-extensions disable "$LEGACY_UUID" 2>/dev/null || true
    rm -rf "$LEGACY_EXT_DIR"

    sudo systemctl disable "$LEGACY_UNIT" 2>/dev/null || true
    for path in "${LEGACY_FILES[@]}"; do
        sudo rm -f "$path"
    done
    sudo rm -rf "$LEGACY_LIB_DIR"
    sudo systemctl daemon-reload
    echo "   old unit, scripts, polkit rule and extension removed"
    echo "   $LEGACY_CONF left in place; remove it once you are happy"
fi

# --------------------------------------------------------------------------
case "$EXT_ACTION" in
link)
    say "Linking the extension into place"
    # A symlink rather than a copy, so edits in the repo are live after a
    # re-login.
    if [[ $EXT_PRESENT -eq 1 ]]; then
        echo "   replacing existing $EXT_DIR"
        rm -rf "$EXT_DIR"
    else
        mkdir -p "$(dirname "$EXT_DIR")"
    fi
    ln -s "$REPO/extension" "$EXT_DIR"
    echo "   $EXT_DIR -> $REPO/extension"
    EXT_PRESENT=1
    ;;
keep)
    say "Linking the extension into place"
    echo "   already linked: $EXT_DIR"
    ;;
foreign)
    say "Leaving the installed extension alone"
    warn_box \
        "Something else installed the extension, so this did not touch it:" \
        "" \
        "    $EXT_DIR" \
        "" \
        "Almost certainly extensions.gnome.org. Replacing it with a symlink" \
        "to this checkout would leave the Extensions app unable to update" \
        "it, and would break the extension outright if this directory is" \
        "ever moved or deleted. So only the daemon is being installed." \
        "" \
        "The extension/ directory in this checkout is NOT what your shell" \
        "loads. Edits here will do nothing until you run:" \
        "" \
        "    ./install.sh --link-extension" \
        "" \
        "No logout needed: the installed extension notices the daemon within" \
        "a second of the systemd reload further down, and the panel icon" \
        "starts working on its own."
    ;;
skip)
    say "Leaving the extensions directory alone (--daemon-only)"
    if [[ $EXT_PRESENT -eq 1 ]]; then
        echo "   untouched: $EXT_DIR"
    else
        echo "   nothing installed at $EXT_DIR"
    fi
    ;;
esac

if [[ $EXT_IS_REPO -eq 1 ]]; then
    say "Compiling the GSettings schema"
    glib-compile-schemas "$REPO/extension/schemas/"
    echo "   done"
fi

say "Installing system components (sudo)"
sudo install -m 0755 "$REPO/daemon/input-lock-x-daemon.py" "$DAEMON_BIN"
echo "   $DAEMON_BIN"


# install(1) gives the file the target directory's default context, which is
# what we want, but relabel explicitly so a previously mislabelled
# /usr/local/bin cannot silently reintroduce the bug.
if command -v restorecon >/dev/null 2>&1; then
    sudo restorecon -F "$DAEMON_BIN" || true
fi

if [[ -e "$CONF" ]]; then
    echo "   $CONF exists, leaving it alone"
else
    sudo install -m 0644 "$REPO/daemon/input-lock-x.conf" "$CONF"
    echo "   $CONF"
fi

sudo install -m 0644 "$REPO/daemon/input-lock-x.service" "$UNIT_FILE"
echo "   $UNIT_FILE"

# No `install -d` here: polkit ships /etc/polkit-1/rules.d as 0750 root:polkitd,
# and GNU install -d applies its mode to an existing directory too -- which
# would silently make it world-readable and never put it back.
sudo install -m 0644 "$REPO/daemon/49-input-lock-x.rules" "$POLKIT_RULE"
echo "   $POLKIT_RULE (wheel, sudo or admin may toggle)"

sudo install -m 0755 "$REPO/scripts/input-lock-x" "$CLI"
sudo install -m 0755 "$REPO/scripts/input-lock-x-emergency-unlock" "$UNLOCK"
echo "   $CLI"
echo "   $UNLOCK"

if [[ $INSTALL_SUDOERS -eq 1 ]]; then
    # Without this, `ssh laptop input-lock-x-emergency-unlock` has no TTY for sudo to
    # prompt on and the emergency path fails exactly when it is needed. Validated
    # first -- an invalid file in sudoers.d can break sudo entirely.
    if sudo visudo -cf "$REPO/daemon/input-lock-x.sudoers" >/dev/null 2>&1; then
        sudo install -m 0440 "$REPO/daemon/input-lock-x.sudoers" "$SUDOERS"
        echo "   $SUDOERS"
        echo "     -> members of wheel, sudo or admin may run input-lock-x and"
        echo "        input-lock-x-emergency-unlock as root without a password."
        echo "        Decline this with: ./install.sh --no-sudoers"
    else
        warn "sudoers snippet failed visudo validation, skipping it." \
             "The SSH recovery path will need:" \
             "  ssh -t <host> sudo input-lock-x-emergency-unlock"
    fi
else
    sudo rm -f "$SUDOERS"
    echo "   sudoers drop-in skipped (--no-sudoers)"
    echo "     -> recover over SSH with: ssh -t <host> sudo input-lock-x-emergency-unlock"
fi

say "Reloading systemd"
sudo systemctl daemon-reload
echo "   done"

say "Checking device matching"
sudo "$DAEMON_BIN" --list

# A shell sudo runs as unconfined_t and can open input devices even when the
# service domain cannot, so --list passing proves nothing about the service.
# Start the unit for real, which is the check that actually matters.
say "Verifying the service can grab (engages the lock briefly)"

# Was input already locked before this install touched anything? Nothing above
# starts or stops this unit, and the block below ends with it stopped whichever
# way it goes -- so a user who had the lock engaged loses it here, and without
# this flag nothing would tell them apart from the test lock we engage
# ourselves.
lock_was_engaged=0
if systemctl is-active --quiet "$UNIT" || [[ -e "$STATE" ]]; then
    lock_was_engaged=1
fi

# One sudo, not three or four. This is the only moment in the install where
# input is genuinely locked, and the credential cache is not guaranteed to be
# warm -- `Defaults timestamp_timeout=0` is a real configuration, and under it
# a second sudo would prompt for a password on the very keyboard it is holding
# shut. So everything that might need to run while the grab is live runs inside
# this single invocation, which exits with a code saying how far it got.
#
# Order matters below: stop, then the recovery script, then SIGKILL. The kernel
# drops an EVIOCGRAB when the fd closes, so the last one always works.
verify_rc=0
sudo bash -s <<'VERIFY' || verify_rc=$?
set -u
# restart, not start: `start` on an already-active unit returns 0 without doing
# anything, so it would say nothing about the daemon this install just wrote --
# which is the entire point of the check. Restart:no and no RefuseManualStart,
# so a restart here is always allowed.
systemctl restart input-lock-x.service || exit 10
# A 0 from restart only says the unit reached active. Ask for the same evidence
# `input-lock-x status` trusts: the state file. This is not a race -- the unit
# is Type=notify with NotifyAccess=main, and the daemon writes the state file
# before it calls sd_notify(READY=1), so restart cannot have returned until the
# grab was real.
[ -e /run/input-lock-x.state ] || { systemctl stop input-lock-x.service; exit 13; }
systemctl stop input-lock-x.service && exit 0
/usr/local/bin/input-lock-x-emergency-unlock && exit 11
systemctl kill --signal=KILL input-lock-x.service
rm -f /run/input-lock-x.state
exit 12
VERIFY

# Before the case, because every outcome below -- including the ones that exit
# -- has left a pre-existing lock released: restart stops the running daemon
# before it starts a new one, and each failure path ends with the unit down.
if [[ $lock_was_engaged -eq 1 ]]; then
    echo "   NOTE: input was already locked when this install started."
    echo "   Verifying restarted the daemon, so that lock is gone and the"
    echo "   keyboard and touchpad are live again. Re-engage it with:"
    echo "     input-lock-x on"
fi

case $verify_rc in
    0)
        echo "   service started, grabbed, and stopped cleanly" ;;
    10)
        echo "   FAILED -- the unit could not start. Diagnose with:" >&2
        echo "     sudo journalctl -u input-lock-x.service -b | tail -30" >&2
        exit 1 ;;
    11)
        echo "   input was released, but the unit does not stop cleanly. Check:" >&2
        echo "     sudo journalctl -u input-lock-x.service -b | tail -30" >&2
        exit 1 ;;
    12)
        echo >&2
        echo "The unit would not stop and recovery reported failure. The daemon" >&2
        echo "was killed, which the kernel treats as a release, but confirm it:" >&2
        echo "    ssh $(hostname) input-lock-x status" >&2
        exit 1 ;;
    13)
        echo "   FAILED -- the unit started but grabbed nothing: it reported" >&2
        echo "   ready and $STATE never appeared. Most likely no device" >&2
        echo "   matched, or the grab was refused. Diagnose with:" >&2
        echo "     sudo journalctl -u input-lock-x.service -b | tail -30" >&2
        echo "     sudo $DAEMON_BIN --list" >&2
        exit 1 ;;
    *)
        echo "   FAILED -- could not run the check as root (sudo exited $verify_rc)." >&2
        exit 1 ;;
esac

# Nothing to enable when there is no extension at all -- a --daemon-only run on
# a machine that has not installed it yet. Everything else falls through: the
# calls below are idempotent, so running them against a copy someone else
# installed just confirms it is switched on.
if [[ $EXT_PRESENT -eq 0 ]]; then
    say "No extension to enable"
    echo "   nothing at $EXT_DIR."
    echo "   Install it from extensions.gnome.org, or re-run without"
    echo "   --daemon-only to link this checkout into place."
else
    say "Enabling the extension"
    # gnome-extensions goes through the running shell, and on a first install
    # the shell has never seen this UUID -- the extension directory was linked
    # seconds ago -- so this call fails exactly when it matters most.
    enabled=0
    if command -v gnome-extensions >/dev/null 2>&1 && \
            gnome-extensions enable "$UUID" 2>/dev/null; then
        echo "   enabled"
        enabled=1
    fi

    if [[ $enabled -eq 0 ]]; then
        # Fall back to the settings the shell reads at startup. Same switch,
        # one layer down, and it does not care whether anything has scanned the
        # directory yet -- which is what turns "installed" into "working" after
        # the log out and back in, instead of leaving a manual step in the
        # fresh-install path for the user to notice in scrollback.
        queue_rc=0
        # Heredoc body and terminator stay at column 0, as they must.
        /usr/bin/python3 - "$UUID" <<'PY' || queue_rc=$?
import ast
import subprocess
import sys

uuid = sys.argv[1]


def read(key):
    out = subprocess.run(["gsettings", "get", "org.gnome.shell", key],
                         stdout=subprocess.PIPE, check=True).stdout
    out = out.decode("utf-8", "replace").strip()
    # An empty list comes back type-annotated, as `@as []`.
    if out.startswith("@as "):
        out = out[4:]
    return list(ast.literal_eval(out))


def write(key, values):
    body = ", ".join("'" + v.replace("\\", "\\\\").replace("'", "\\'") + "'"
                     for v in values)
    subprocess.run(["gsettings", "set", "org.gnome.shell", key, "[" + body + "]"],
                   check=True)


# disabled-extensions first, and not as an afterthought: it takes precedence
# over enabled-extensions, so an entry left there by an earlier `gnome-extensions
# disable` silently outranks anything written below and the extension stays dark
# with both lists looking right at a glance.
disabled = read("disabled-extensions")
if uuid in disabled:
    write("disabled-extensions", [u for u in disabled if u != uuid])

enabled = read("enabled-extensions")
if uuid not in enabled:
    write("enabled-extensions", enabled + [uuid])
PY

        if [[ $queue_rc -eq 0 ]]; then
            echo "   queued -- it comes up enabled after the log out and back in"
        else
            echo "   could not enable it, and could not queue it either." >&2
            echo "   Run this after logging back in:" >&2
            echo "       gnome-extensions enable $UUID" >&2
        fi
    fi
fi

printf '\n== Installed.\n'

# The relogin is only needed for an extension we just put on disk: Wayland
# cannot load one in place. A copy that was already installed is already
# loaded, and it finds the daemon by itself -- extension.js subscribes to
# systemd's Reloading signal, which the daemon-reload above emits.
if [[ $EXT_IS_REPO -eq 1 ]]; then
    cat <<'EOF'

Log out and back in before the extension loads -- Wayland cannot reload
extensions in place.
EOF
elif [[ $EXT_PRESENT -eq 1 ]]; then
    cat <<'EOF'

No logout needed -- the extension that is already installed picks the daemon
up on its own, within a second or so.
EOF
fi

cat <<EOF

Before you rely on it, test the lock from another machine:

    ssh $(hostname) input-lock-x on      # keyboard + touchpad go dead
    # press Ctrl+Esc on the laptop     # they come back
    ssh $(hostname) input-lock-x-emergency-unlock   # the way out if they do not

EOF
