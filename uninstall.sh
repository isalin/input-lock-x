#!/bin/bash
# Copyright (C) 2026 Isak Lindgren
# SPDX-License-Identifier: GPL-2.0-or-later
# Remove everything install.sh put in place, from either generation of names.
#
# Releases any active lock first, so it is impossible to uninstall yourself
# into a dead keyboard.
#
# Usage: ./uninstall.sh
#   No options. -h/--help prints this and does nothing else.

set -euo pipefail

# pwd -P, not pwd: bash's pwd is logical, so a checkout reached through a
# symlink reports the path taken to get here rather than where it is.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# Someone can land here having installed the pre-rename version and never run
# the migrating install.sh, so uninstall has to know about both sets of names.
# All four helpers are shared with install.sh so the two can never drift apart
# -- on the release path in particular, a disagreement means a dead keyboard
# and a deleted recovery script.
for helper in output usage paths legacy-paths release-lock; do
    if [[ ! -r "$REPO/lib/$helper.sh" ]]; then
        echo "missing $REPO/lib/$helper.sh -- run this from a full checkout" >&2
        exit 1
    fi
done
# shellcheck source=lib/output.sh
source "$REPO/lib/output.sh"
# shellcheck source=lib/usage.sh
source "$REPO/lib/usage.sh"
# shellcheck source=lib/paths.sh
source "$REPO/lib/paths.sh"
# shellcheck source=lib/legacy-paths.sh
source "$REPO/lib/legacy-paths.sh"
# shellcheck source=lib/release-lock.sh
source "$REPO/lib/release-lock.sh"

# Parsed even though there are no options to parse: without this loop
# `./uninstall.sh --help` fell straight through to the uninstall and removed
# everything, which is a spectacular answer to a request for documentation.
for arg in "$@"; do
    case "$arg" in
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $arg (try --help)" >&2; exit 1 ;;
    esac
done

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

# The same predicate install.sh uses, from the same file, so this removes only
# a symlink that resolves to this checkout. A symlink by itself is not proof of
# ownership: it may belong to another checkout or another tool, and it may be
# dangling.
EXT_STATE="$(ext_state)"
EXT_REMOVED=0

if ext_links_to_repo "$REPO"; then
    say "Disabling the extension"
    gnome-extensions disable "$UUID" 2>/dev/null || true
    # Plain -f: the branch guarantees a symlink, and rm removes the link rather
    # than following it, so the checkout it points at is untouched.
    rm -f "$EXT_DIR"
    echo "   removed $EXT_DIR"
    EXT_REMOVED=1
elif [[ "$EXT_STATE" == foreign ]]; then
    say "Leaving the installed extension alone"
    warn_box \
        "This script did not install the extension at:" \
        "" \
        "    $EXT_DIR" \
        "" \
        "so it has been left exactly as it was -- still installed, still" \
        "enabled, shortcut setting intact. Without the daemon it now shows" \
        "the 'daemon not installed' icon, which is what it is designed to" \
        "do; reinstall the daemon and it starts working again by itself." \
        "" \
        "To remove it, use the Extensions app, or:" \
        "" \
        "    gnome-extensions uninstall $UUID"
elif [[ "$EXT_STATE" == symlink ]]; then
    say "Leaving the extension symlink alone"
    warn_box \
        "This symlink does not resolve to this checkout:" \
        "" \
        "    $EXT_DIR" \
        "      -> $(readlink "$EXT_DIR")" \
        "" \
        "It may belong to another checkout or another installer, so it has" \
        "been left alone. Remove it or uninstall its owner separately."
fi

# Unconditional, unlike the above: the pre-rename installer only ever made its
# own copy here, so there is no one else's install to mistake this for.
say "Removing the pre-rename extension, if any"
gnome-extensions disable "$LEGACY_UUID" 2>/dev/null || true
rm -rf "$LEGACY_EXT_DIR"
echo "   done"

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
# a stray key referring to an extension that is no longer installed -- but only
# when the extension really is gone. One we left in place is still using that
# key, and resetting it would silently change a setting on somebody else's
# install. So reset it when the path was absent or when we removed our own
# symlink. An unknown symlink and a foreign directory keep their settings.
# The pre-rename path always goes: its extension always does.
if command -v dconf >/dev/null 2>&1; then
    if [[ "$EXT_STATE" == absent || $EXT_REMOVED -eq 1 ]]; then
        dconf reset -f "$DCONF_PATH" 2>/dev/null || true
        echo "   shortcut setting cleared"
    fi
    dconf reset -f "$LEGACY_DCONF_PATH" 2>/dev/null || true
fi

cat <<EOF

== Uninstalled.

Config files were left in place in case you edited them:
    sudo rm -f "$CONF" "$LEGACY_CONF"

EOF
