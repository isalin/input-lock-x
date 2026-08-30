#!/bin/bash
# Copyright (C) 2026 Isak Lindgren
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Exercise the extension-path predicates without touching the user's home
# directory. The installer and uninstaller use these same predicates before
# they remove or replace anything at this path.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# Relative to shellcheck's working directory -- the repo root, where the
# Makefile runs it -- not to this script. `../lib/paths.sh` points outside the
# repo from there, so shellcheck stops following it and reports SC1091.
# shellcheck source=lib/paths.sh
source "$REPO/lib/paths.sh"
EXT_DIR="$TEST_ROOT/home/.local/share/gnome-shell/extensions/$UUID"
mkdir -p "$(dirname "$EXT_DIR")"

[[ "$(ext_state)" == absent ]]

ln -s "$TEST_ROOT/missing-extension" "$EXT_DIR"
[[ "$(ext_state)" == symlink ]]
# `! ext_links_to_repo ...` is the obvious spelling and a trap: bash exempts a
# negated command from errexit (SC2251), so this line could not fail the run --
# a predicate that wrongly claimed a foreign path as ours would pass the test.
# `&& exit 1` is checked, and matches the bare `[[ ]]` asserts above.
ext_links_to_repo "$REPO" && exit 1

rm -f "$EXT_DIR"
mkdir "$EXT_DIR"
[[ "$(ext_state)" == foreign ]]
ext_links_to_repo "$REPO" && exit 1

rm -rf "$EXT_DIR"
ln -s "$REPO/extension" "$EXT_DIR"
[[ "$(ext_state)" == symlink ]]
ext_links_to_repo "$REPO"

echo "path ownership: ok"
