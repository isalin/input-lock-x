# Copyright (C) 2026 Isak Lindgren
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Everything the pre-rename generation of this tool installed.
# shellcheck shell=bash
#
# Every name below is read by the script that sources this file, never by this
# file itself -- which is precisely what SC2034 cannot see across a `source`.
# shellcheck disable=SC2034
#
# Sourced by both install.sh (which migrates off these) and uninstall.sh (which
# has to clean them up even when the migrating install.sh was never run). One
# definition, because the failure mode of two is a root-owned file left behind
# by an uninstall that thought it was finished.

LEGACY_UUID="minibookx-input-toggle@isalin.github.com"
LEGACY_UNIT="minibookx-hid-lock.service"
LEGACY_CONF="/etc/minibookx-hid-lock.conf"
LEGACY_STATE="/run/minibookx-hid-lock.state"
LEGACY_UNLOCK="/usr/local/bin/hid-emergency-unlock"
LEGACY_LIB_DIR="/usr/local/lib/minibookx-hid-lock"
LEGACY_DCONF_PATH="/org/gnome/shell/extensions/minibookx-input-toggle/"
LEGACY_EXT_DIR="${HOME}/.local/share/gnome-shell/extensions/${LEGACY_UUID}"
# Matched against full command lines. Deliberately just the basename, with no
# directory: this generation moved its daemon from LEGACY_LIB_DIR to
# /usr/local/bin part-way through, and a machine can still be running either.
LEGACY_DAEMON_PATTERN="hid-lock-daemon"

# Removable files. Not LEGACY_CONF: a config may have been edited by hand, so
# it is left on disk and only mentioned in the closing message.
LEGACY_FILES=(
    "/etc/systemd/system/${LEGACY_UNIT}"
    /etc/polkit-1/rules.d/49-minibookx-hid-lock.rules
    /etc/sudoers.d/minibookx-hid-lock
    /usr/local/bin/hid-toggle
    /usr/local/bin/hid-emergency-unlock
    /usr/local/bin/hid-lock-daemon
)
