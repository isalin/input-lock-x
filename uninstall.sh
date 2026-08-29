#!/bin/bash
# Remove everything install.sh put in place, from either generation of names.
#
# Releases any active lock first, so it is impossible to uninstall yourself
# into a dead keyboard.

set -euo pipefail

# pwd -P, not pwd: bash's pwd is logical, so a checkout reached through a
# symlink reports the path taken to get here rather than where it is.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# Someone can land here having installed the pre-rename version and never run
# the migrating install.sh, so uninstall has to know about both sets of names.
# All three helpers are shared with install.sh so the two can never drift apart
# -- on the release path in particular, a disagreement means a dead keyboard
# and a deleted recovery script.
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

say() { printf '\n== %s\n' "$*"; }

if [[ $EUID -eq 0 ]]; then
    echo "Run this as your normal user; it will call sudo where it needs to." >&2
    exit 1
fi

say "Releasing any active lock first"
if ! release_lock "$UNIT" "$STATE" "$UNLOCK" "$DAEMON_PATTERN"; then
    echo
    echo "Recovery reported failure -- refusing to continue while input may" >&2
    echo "still be locked, since uninstalling would delete the very tools" >&2
    echo "needed to unlock it. Fix that first, then re-run." >&2
    exit 1
fi

# Same again for an old install that was never migrated. Its daemon holds the
# grab under a different unit name, so stopping ours would not have touched it.
if ! release_lock "$LEGACY_UNIT" "$LEGACY_STATE" "$LEGACY_UNLOCK" \
        "$LEGACY_DAEMON_PATTERN"; then
    echo
    echo "The old recovery script reported failure -- refusing to continue" >&2
    echo "while input may still be locked by the previous version." >&2
    exit 1
fi
echo "   released"

say "Disabling the extension"
gnome-extensions disable "$UUID" 2>/dev/null || true
gnome-extensions disable "$LEGACY_UUID" 2>/dev/null || true
# -rf, not -f: if a previous install left a real directory here rather than our
# symlink, plain rm -f fails on it and set -e would abort the uninstall halfway.
rm -rf "$EXT_DIR"
rm -rf "$LEGACY_EXT_DIR"
echo "   removed $EXT_DIR"

say "Removing system components (sudo)"
sudo systemctl disable "$UNIT" 2>/dev/null || true
for path in "${FILES[@]}"; do
    sudo rm -f "$path"
done

sudo systemctl disable "$LEGACY_UNIT" 2>/dev/null || true
for path in "${LEGACY_FILES[@]}"; do
    sudo rm -f "$path"
done
sudo rm -rf "$LEGACY_LIB_DIR"

sudo systemctl daemon-reload
echo "   done"

# The shortcut is stored in dconf, which outlives the schema. Left behind it is
# a stray key referring to an extension that is no longer installed.
if command -v dconf >/dev/null 2>&1; then
    dconf reset -f "$DCONF_PATH" 2>/dev/null || true
    dconf reset -f "$LEGACY_DCONF_PATH" 2>/dev/null || true
    echo "   shortcut setting cleared"
fi

cat <<EOF

== Uninstalled.

Config files were left in place in case you edited them:
    sudo rm -f "$CONF" "$LEGACY_CONF"

EOF
