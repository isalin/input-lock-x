#!/bin/bash
# Install Input Lock X: the GNOME extension (user) plus the daemon, systemd
# unit, polkit rule and CLI scripts (system, needs sudo).
#
# Safe to re-run. /etc/input-lock-x.conf is never overwritten.
#
# Usage: ./install.sh [--no-sudoers]
#   --no-sudoers  do not install the passwordless sudo drop-in. Recovery over
#                 SSH then needs a TTY: ssh -t <host> sudo input-lock-x-emergency-unlock

set -euo pipefail

# pwd -P, not pwd: bash's pwd is logical, so a checkout reached through a
# symlink reports the path taken to get here rather than where it is. The
# "already linked" check below compares this against readlink output, which
# is always physical -- with the logical form that branch is simply dead.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# Both sets of names, and the release sequence, live in files shared with
# uninstall.sh so the two can never disagree about any of them.
for helper in paths legacy-paths release-lock; do
    if [[ ! -r "$REPO/lib/$helper.sh" ]]; then
        echo "missing $REPO/lib/$helper.sh -- run this from a full checkout" >&2
        exit 1
    fi
done
# shellcheck source=lib/paths.sh
source "$REPO/lib/paths.sh"
# shellcheck source=lib/legacy-paths.sh
source "$REPO/lib/legacy-paths.sh"
# shellcheck source=lib/release-lock.sh
source "$REPO/lib/release-lock.sh"

INSTALL_SUDOERS=1

say() { printf '\n== %s\n' "$*"; }

for arg in "$@"; do
    case "$arg" in
        --no-sudoers) INSTALL_SUDOERS=0 ;;
        # Same one-liner the two CLI scripts use, so all three help texts
        # come out looking alike rather than one keeping its '#' prefixes.
        -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $arg (try --help)" >&2; exit 1 ;;
    esac
done

if [[ $EUID -eq 0 ]]; then
    echo "Run this as your normal user; it will call sudo where it needs to." >&2
    exit 1
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
need glib-compile-schemas "Debian/Ubuntu: libglib2.0-bin; Fedora: glib2-devel; Arch: glib2"

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
    echo "   WARNING: you are in none of wheel, sudo or admin." >&2
    echo "   The panel button and shortcut will fail with a permission error." >&2
    echo "   Add yourself to your distro's admin group, or edit the group list" >&2
    echo "   in $POLKIT_RULE after installing." >&2
fi

# --------------------------------------------------------------------------
# Migrate from the pre-rename generation, if this machine has one. Everything
# below is a no-op on a fresh install.

# `if`, not `[[ -e x ]] && flag=1`: under set -e a false test at the end of an
# && list exits the script, which on a fresh install is every one of them.
legacy_present=0
for path in "$LEGACY_CONF" "$LEGACY_EXT_DIR" "${LEGACY_FILES[@]}"; do
    if [[ -e "$path" ]]; then
        legacy_present=1
        break
    fi
done

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
say "Linking the extension into place"
# A symlink rather than a copy, so edits in the repo are live after a re-login.
if [[ -e "$EXT_DIR" || -L "$EXT_DIR" ]]; then
    if [[ -L "$EXT_DIR" && "$(readlink -f "$EXT_DIR")" == "$REPO/extension" ]]; then
        echo "   already linked: $EXT_DIR"
    else
        echo "   replacing existing $EXT_DIR"
        rm -rf "$EXT_DIR"
        ln -s "$REPO/extension" "$EXT_DIR"
    fi
else
    mkdir -p "$(dirname "$EXT_DIR")"
    ln -s "$REPO/extension" "$EXT_DIR"
    echo "   $EXT_DIR -> $REPO/extension"
fi

say "Compiling the GSettings schema"
glib-compile-schemas "$REPO/extension/schemas/"
echo "   done"

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
        echo "   WARNING: sudoers snippet failed visudo validation, skipping it."
        echo "   The SSH recovery path will need: ssh -t <host> sudo input-lock-x-emergency-unlock"
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
systemctl start input-lock-x.service || exit 10
systemctl stop input-lock-x.service && exit 0
/usr/local/bin/input-lock-x-emergency-unlock && exit 11
systemctl kill --signal=KILL input-lock-x.service
rm -f /run/input-lock-x.state
exit 12
VERIFY

case $verify_rc in
    0)
        echo "   service started and stopped cleanly" ;;
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
    *)
        echo "   FAILED -- could not run the check as root (sudo exited $verify_rc)." >&2
        exit 1 ;;
esac

say "Enabling the extension"
# gnome-extensions goes through the running shell, and on a first install the
# shell has never seen this UUID -- the extension directory was linked seconds
# ago -- so this call fails exactly when it matters most.
enabled=0
if command -v gnome-extensions >/dev/null 2>&1 && \
        gnome-extensions enable "$UUID" 2>/dev/null; then
    echo "   enabled"
    enabled=1
fi

if [[ $enabled -eq 0 ]]; then
    # Fall back to the settings the shell reads at startup. Same switch, one
    # layer down, and it does not care whether anything has scanned the
    # directory yet -- which is what turns "installed" into "working" after the
    # log out and back in, instead of leaving a manual step in the fresh-install
    # path for the user to notice in scrollback.
    queue_rc=0
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

cat <<EOF

== Installed.

Log out and back in before the extension loads -- Wayland cannot reload
extensions in place.

Before you rely on it, test the lock from another machine:

    ssh $(hostname) input-lock-x on      # keyboard + touchpad go dead
    # press Ctrl+Esc on the laptop     # they come back
    ssh $(hostname) input-lock-x-emergency-unlock   # the way out if they do not

EOF
