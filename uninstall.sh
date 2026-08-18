#!/bin/bash
# Remove everything install.sh put in place.
#
# Releases any active lock first, so it is impossible to uninstall yourself
# into a dead keyboard.

set -euo pipefail

UUID="minibookx-input-toggle@isalin.github.com"
EXT_DIR="${HOME}/.local/share/gnome-shell/extensions/${UUID}"
DAEMON_BIN="/usr/local/bin/hid-lock-daemon"
OLD_LIB_DIR="/usr/local/lib/minibookx-hid-lock"

say() { printf '\n== %s\n' "$*"; }

if [[ $EUID -eq 0 ]]; then
    echo "Run this as your normal user; it will call sudo where it needs to." >&2
    exit 1
fi

say "Releasing any active lock first"
if [[ -x /usr/local/bin/hid-emergency-unlock ]]; then
    if ! sudo /usr/local/bin/hid-emergency-unlock; then
        echo
        echo "Recovery reported failure -- refusing to continue while input may" >&2
        echo "still be locked, since uninstalling would delete the very tools" >&2
        echo "needed to unlock it. Fix that first, then re-run." >&2
        exit 1
    fi
else
    sudo systemctl stop minibookx-hid-lock.service 2>/dev/null || true
    # systemctl kill rather than pkill: `sudo pkill -f hid-lock-daemon.py`
    # matches its own sudo parent's command line and SIGTERMs it.
    sudo systemctl kill --signal=KILL minibookx-hid-lock.service 2>/dev/null || true
    sudo rm -f /run/minibookx-hid-lock.state
fi

say "Disabling the extension"
gnome-extensions disable "$UUID" 2>/dev/null || true
# -rf, not -f: if a previous install left a real directory here rather than our
# symlink, plain rm -f fails on it and set -e would abort the uninstall halfway.
rm -rf "$EXT_DIR"
echo "   removed $EXT_DIR"

say "Removing system components (sudo)"
sudo systemctl disable minibookx-hid-lock.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/minibookx-hid-lock.service
sudo rm -f /etc/polkit-1/rules.d/49-minibookx-hid-lock.rules
sudo rm -f /etc/sudoers.d/minibookx-hid-lock
sudo rm -f /usr/local/bin/hid-toggle
sudo rm -f /usr/local/bin/hid-emergency-unlock
sudo rm -f "$DAEMON_BIN"
sudo rm -rf "$OLD_LIB_DIR"
sudo systemctl daemon-reload
echo "   done"

cat <<EOF

== Uninstalled.

/etc/minibookx-hid-lock.conf was left in place in case you edited it.
Remove it with: sudo rm /etc/minibookx-hid-lock.conf

EOF
