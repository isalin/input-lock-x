#!/bin/bash
# Install the Minibook X input toggle: GNOME extension (user) + hid-lock daemon,
# systemd unit, polkit rule and CLI scripts (system, needs sudo).
#
# Safe to re-run. /etc/minibookx-hid-lock.conf is never overwritten.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UUID="minibookx-input-toggle@isalin.github.com"
EXT_DIR="${HOME}/.local/share/gnome-shell/extensions/${UUID}"
# /usr/local/bin so SELinux labels it bin_t. From /usr/local/lib (lib_t) there
# is no domain transition, the service runs as init_t, and every
# /dev/input/event* open fails with EACCES even though the service is root.
DAEMON_BIN="/usr/local/bin/hid-lock-daemon"
OLD_LIB_DIR="/usr/local/lib/minibookx-hid-lock"
CONF="/etc/minibookx-hid-lock.conf"

say() { printf '\n== %s\n' "$*"; }

if [[ $EUID -eq 0 ]]; then
    echo "Run this as your normal user; it will call sudo where it needs to." >&2
    exit 1
fi

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
sudo install -m 0755 "$REPO/daemon/hid-lock-daemon.py" "$DAEMON_BIN"
echo "   $DAEMON_BIN"

# Clean up the pre-0.2 location, which SELinux labels lib_t. Leaving it behind
# would just be a broken duplicate.
if [[ -e "$OLD_LIB_DIR" ]]; then
    sudo rm -rf "$OLD_LIB_DIR"
    echo "   removed obsolete $OLD_LIB_DIR"
fi

# install(1) gives the file the target directory's default context, which is
# what we want, but relabel explicitly so a previously mislabelled
# /usr/local/bin cannot silently reintroduce the bug.
if command -v restorecon >/dev/null 2>&1; then
    sudo restorecon -F "$DAEMON_BIN" || true
fi

if [[ -e "$CONF" ]]; then
    echo "   $CONF exists, leaving it alone"
else
    sudo install -m 0644 "$REPO/daemon/minibookx-hid-lock.conf" "$CONF"
    echo "   $CONF"
fi

sudo install -m 0644 "$REPO/daemon/minibookx-hid-lock.service" \
    /etc/systemd/system/minibookx-hid-lock.service
echo "   /etc/systemd/system/minibookx-hid-lock.service"

# No `install -d` here: polkit ships /etc/polkit-1/rules.d as 0750 root:polkitd,
# and GNU install -d applies its mode to an existing directory too -- which
# would silently make it world-readable and never put it back.
sudo install -m 0644 "$REPO/daemon/49-minibookx-hid-lock.rules" \
    /etc/polkit-1/rules.d/49-minibookx-hid-lock.rules
echo "   /etc/polkit-1/rules.d/49-minibookx-hid-lock.rules"

sudo install -m 0755 "$REPO/scripts/hid-toggle" /usr/local/bin/hid-toggle
sudo install -m 0755 "$REPO/scripts/hid-emergency-unlock" /usr/local/bin/hid-emergency-unlock
echo "   /usr/local/bin/hid-toggle"
echo "   /usr/local/bin/hid-emergency-unlock"

# Without this, `ssh laptop hid-emergency-unlock` has no TTY for sudo to prompt
# on and the emergency path fails exactly when it is needed. Validated first --
# an invalid file in sudoers.d can break sudo entirely.
if sudo visudo -cf "$REPO/daemon/minibookx-hid-lock.sudoers" >/dev/null 2>&1; then
    sudo install -m 0440 "$REPO/daemon/minibookx-hid-lock.sudoers" \
        /etc/sudoers.d/minibookx-hid-lock
    echo "   /etc/sudoers.d/minibookx-hid-lock (passwordless SSH recovery)"
else
    echo "   WARNING: sudoers snippet failed visudo validation, skipping it."
    echo "   The SSH recovery path will need: ssh -t <host> sudo hid-emergency-unlock"
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
if sudo systemctl start minibookx-hid-lock.service; then
    sudo systemctl stop minibookx-hid-lock.service
    echo "   service started and stopped cleanly"
else
    echo "   FAILED -- the unit could not start. Diagnose with:"
    echo "     sudo journalctl -u minibookx-hid-lock.service -b | tail -30"
    exit 1
fi

say "Enabling the extension"
if gnome-extensions enable "$UUID" 2>/dev/null; then
    echo "   enabled"
else
    echo "   could not enable yet -- normal on a first install."
    echo "   Run 'gnome-extensions enable $UUID' after logging back in."
fi

cat <<EOF

== Installed.

Log out and back in before the extension loads -- Wayland cannot reload
extensions in place.

Before you rely on it, test the lock from another machine:

    ssh $(hostname) hid-toggle on      # keyboard + touchpad go dead
    # press Ctrl+Esc on the laptop     # they come back
    ssh $(hostname) hid-emergency-unlock   # the way out if they do not

EOF
