# Copyright (C) 2026 Isak Lindgren
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Everything the current generation of this tool installs.
# shellcheck shell=bash
#
# Every name below is read by the script that sources this file, never by this
# file itself -- which is precisely what SC2034 cannot see across a `source`.
# shellcheck disable=SC2034
#
# Sourced by both install.sh and uninstall.sh, for the same reason
# lib/legacy-paths.sh exists: the failure mode of two lists is a root-owned
# file left behind by an uninstall that thought it was finished.

UUID="input-lock-x@isalin.github.io"
UNIT="input-lock-x.service"
CONF="/etc/input-lock-x.conf"
STATE="/run/input-lock-x.state"
DCONF_PATH="/org/gnome/shell/extensions/input-lock-x/"
EXT_DIR="${HOME}/.local/share/gnome-shell/extensions/${UUID}"

UNIT_FILE="/etc/systemd/system/${UNIT}"
POLKIT_RULE="/etc/polkit-1/rules.d/49-input-lock-x.rules"
SUDOERS="/etc/sudoers.d/input-lock-x"
CLI="/usr/local/bin/input-lock-x"
UNLOCK="/usr/local/bin/input-lock-x-emergency-unlock"
# /usr/local/bin so SELinux labels it bin_t. From /usr/local/lib (lib_t) there
# is no domain transition, the service runs as init_t, and every
# /dev/input/event* open fails with EACCES even though the service is root.
DAEMON_BIN="/usr/local/bin/input-lock-x-daemon"
# Matched as a substring of full command lines, so it has to be what shows up
# in ps: the daemon is a python script, so $0 is the interpreter and this path
# is argv[1]. Anchored on the install path, not the bare basename, for the
# reason scripts/input-lock-x-emergency-unlock spells out at its daemon_pids
# helper -- `vim daemon/input-lock-x-daemon.py` and `make check`'s py_compile
# both contain the basename, and mistaking either for a live daemon reports a
# failed release while input is perfectly fine.
DAEMON_PATTERN="$DAEMON_BIN"

# Removable files. Not CONF: a config may have been edited by hand, so it is
# left on disk and only mentioned in the closing message.
FILES=(
    "$UNIT_FILE"
    "$POLKIT_RULE"
    "$SUDOERS"
    "$CLI"
    "$UNLOCK"
    "$DAEMON_BIN"
)

# What is at $EXT_DIR:
#
#   absent   nothing at that path
#   symlink  a symlink, whose target still needs to be checked before it is
#            treated as belonging to this checkout
#   foreign  a real directory somebody else installed
#
# Shared rather than written out twice, because the two scripts disagreeing
# about the path is how somebody else's extension disappears.
ext_state() {
    if [[ -L "$EXT_DIR" ]]; then
        echo "symlink"
    elif [[ -e "$EXT_DIR" ]]; then
        echo "foreign"
    else
        echo "absent"
    fi
}

# True when $EXT_DIR is a symlink resolving into the given checkout -- i.e. the
# shell loads *this* copy, so this is the tree whose schema has to be compiled.
#
# Deliberately not folded into ext_state: a symlink into a second clone, or one
# left dangling because its target was removed, is not proof that this checkout
# owns it. Only a link that resolves to this checkout may be removed silently
# by uninstall.sh; every other symlink is treated as somebody else's path.
ext_links_to_repo() {  # ext_links_to_repo <repo-root>
    [[ -L "$EXT_DIR" && "$(readlink -f "$EXT_DIR")" == "$1/extension" ]]
}
