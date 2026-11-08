#!/bin/bash
# Copyright (C) 2026 Isak Lindgren
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Exercise lib/extension-live.sh -- what install.sh says about logging out --
# against canned gnome-extensions, gnome-shell and gsettings answers. Nothing
# here talks to a real shell or reads the user's settings: the stubs come
# first on PATH, and each answers only from files under $FAKE.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# Relative to the repo root, where the Makefile runs shellcheck; see
# tests/test-path-ownership.sh.
# shellcheck source=lib/paths.sh
source "$REPO/lib/paths.sh"
# shellcheck source=lib/extension-live.sh
source "$REPO/lib/extension-live.sh"
EXT_DIR="$TEST_ROOT/extensions/$UUID"

# The stub translates whenever LC_ALL is not C, so an unset LC_ALL here makes
# every query that forgets to force the C locale come back empty.
unset LC_ALL

export FAKE="$TEST_ROOT/fake"
mkdir -p "$TEST_ROOT/bin" "$FAKE"
PATH="$TEST_ROOT/bin:$PATH"

# $FAKE/list: what `list` prints; absent means no shell answered.
# $FAKE/states: one state per `info` call, the last one repeating.
# $FAKE/live-version: the Version line, absent for none.
# $FAKE/version: what `version` prints; absent means it fails.
# Labels come out in Swedish unless LC_ALL=C, as they do on a Swedish desktop.
cat >"$TEST_ROOT/bin/gnome-extensions" <<'EOF'
#!/bin/bash
case "$1" in
list)
    [[ -f "$FAKE/list" ]] || exit 2
    cat "$FAKE/list" ;;
info)
    [[ -f "$FAKE/list" ]] && grep -qxF -- "$2" "$FAKE/list" || exit 2
    state="$(head -n 1 "$FAKE/states")"
    if [[ "$(wc -l <"$FAKE/states")" -gt 1 ]]; then
        sed -i 1d "$FAKE/states"
    fi
    label_state="State" label_desc="Description"
    if [[ "${LC_ALL:-}" != C ]]; then
        label_state="Tillstånd" label_desc="Beskrivning"
    fi
    printf '%s\n  Name: Input Lock X\n  %s: First line.\n' "$2" "$label_desc"
    printf 'State: a description line, not a field\n'
    if [[ -f "$FAKE/live-version" ]]; then
        printf '  Version: %s\n' "$(cat "$FAKE/live-version")"
    fi
    printf '  Enabled: Yes\n  %s: %s\n' "$label_state" "$state" ;;
version)
    [[ -f "$FAKE/version" ]] || exit 1
    cat "$FAKE/version" ;;
*)
    exit 1 ;;
esac
EOF
cat >"$TEST_ROOT/bin/gnome-shell" <<'EOF'
#!/bin/bash
[[ "$1" == --version && -f "$FAKE/shell-version" ]] || exit 1
echo "GNOME Shell $(cat "$FAKE/shell-version")"
EOF
# $FAKE/gs-<key>: the value of org.gnome.shell <key>; absent means it fails.
cat >"$TEST_ROOT/bin/gsettings" <<'EOF'
#!/bin/bash
[[ "$1" == get && "$2" == org.gnome.shell && -f "$FAKE/gs-$3" ]] || exit 1
cat "$FAKE/gs-$3"
EOF
chmod +x "$TEST_ROOT/bin/"*

# The settle loop's pauses are not what is under test.
sleep() { :; }

fail() {
    echo "extension live state: FAILED: $*" >&2
    exit 1
}
expect() {  # expect <label> <actual> <expected>
    [[ "$2" == "$3" ]] || fail "$1: got '$2', expected '$3'"
}
says() {  # says <label> <text> <needle>
    grep -qF -- "$3" <<<"$2" || fail "$1: missing '$3' in:$2"
}
never_says() {  # never_says <label> <text> <needle>
    if grep -qF -- "$3" <<<"$2"; then
        fail "$1: unexpected '$3' in:$2"
    fi
}

# --- ext_live_query ---------------------------------------------------------

ext_live_query "$UUID"
expect "no shell" "$EXT_LIVE_STATE" ""

printf 'other@example.com\n' >"$FAKE/list"
ext_live_query "$UUID"
expect "unknown UUID" "$EXT_LIVE_STATE" "NOT LOADED"

printf 'other@example.com\n%s\n' "$UUID" >"$FAKE/list"
echo "OUT OF DATE" >"$FAKE/states"
echo "1.0.0" >"$FAKE/live-version"
ext_live_query "$UUID"
expect "state in a Swedish session" "$EXT_LIVE_STATE" "OUT OF DATE"
expect "version" "$EXT_LIVE_VERSION" "1.0.0"
# And the stub really does translate, so the lines above prove something.
never_says "stub locale" "$(gnome-extensions info "$UUID")" "  State:"

rm "$FAKE/live-version"
echo ACTIVE >"$FAKE/states"
ext_live_query "$UUID"
expect "active" "$EXT_LIVE_STATE" "ACTIVE"
expect "no version line" "$EXT_LIVE_VERSION" ""

# --- ext_live_settle --------------------------------------------------------

printf 'INITIALIZED\nACTIVATING\nACTIVE\n' >"$FAKE/states"
ext_live_settle "$UUID"
expect "settles to active" "$EXT_LIVE_STATE" "ACTIVE"

printf 'DISABLED\nENABLED\n' >"$FAKE/states"
ext_live_settle "$UUID"
expect "settles, GNOME 45 names" "$EXT_LIVE_STATE" "ENABLED"

echo INACTIVE >"$FAKE/states"
ext_live_settle "$UUID"
expect "gives up" "$EXT_LIVE_STATE" "INACTIVE"

echo ERROR >"$FAKE/states"
ext_live_settle "$UUID"
expect "error is final" "$EXT_LIVE_STATE" "ERROR"

# --- ext_installed_shell_version --------------------------------------------

echo "51.1" >"$FAKE/version"
expect "from gnome-extensions" "$(ext_installed_shell_version)" "51.1"
rm "$FAKE/version"
echo "52.rc" >"$FAKE/shell-version"
expect "from gnome-shell" "$(ext_installed_shell_version)" "52.rc"
rm "$FAKE/shell-version"
expect "neither" "$(ext_installed_shell_version)" ""

# --- ext_disk_facts ---------------------------------------------------------

meta="$TEST_ROOT/metadata.json"
printf '{"shell-version": ["45", "51"], "version-name": "1.0.1"}\n' >"$meta"
ext_disk_facts "$meta" "51.1"
expect "51.1 listed" "$EXT_DISK_SUPPORTED" yes
expect "version-name" "$EXT_DISK_VERSION_NAME" "1.0.1"
expect "no integer version" "$EXT_DISK_VERSION_NUM" ""
ext_disk_facts "$meta" "52.1"
expect "52.1 not listed" "$EXT_DISK_SUPPORTED" no
ext_disk_facts "$meta" ""
expect "shell version unknown" "$EXT_DISK_SUPPORTED" ""

# GNOME matches on the major version, so a bare "52" covers a release
# candidate too -- an exact-membership check would wrongly call it unsupported.
printf '{"shell-version": ["52"], "version": 7}\n' >"$meta"
ext_disk_facts "$meta" "52.rc"
expect "52.rc under 52" "$EXT_DISK_SUPPORTED" yes
expect "integer version" "$EXT_DISK_VERSION_NUM" "7"
expect "no version-name" "$EXT_DISK_VERSION_NAME" ""

ext_disk_facts "$TEST_ROOT/missing.json" "51.1"
expect "no metadata" "$EXT_DISK_SUPPORTED$EXT_DISK_VERSION_NAME$EXT_DISK_VERSION_NUM" ""

# --- ext_logout_verdict -----------------------------------------------------

# A healthy, current install: the defaults each case below departs from.
reset_facts() {
    EXT_LIVE_STATE=ACTIVE
    EXT_LIVE_VERSION="1.0.1"
    EXT_SHELL_VERSION="51.1"
    EXT_DISK_SUPPORTED=yes
    EXT_DISK_VERSION_NAME="1.0.1"
    EXT_DISK_VERSION_NUM=""
    EXT_USER_OFF=false
    EXT_CHECK_OFF=false
}

reset_facts
expect "current" "$(ext_logout_verdict)" unsure

reset_facts; EXT_DISK_SUPPORTED=no
expect "unsupported" "$(ext_logout_verdict)" unsupported
EXT_CHECK_OFF=true
expect "unsupported, check off" "$(ext_logout_verdict)" unsure

reset_facts; EXT_LIVE_STATE="NOT LOADED"; EXT_LIVE_VERSION=""
expect "not loaded" "$(ext_logout_verdict)" not-loaded
reset_facts; EXT_LIVE_STATE="OUT OF DATE"
expect "out of date" "$(ext_logout_verdict)" out-of-date
reset_facts; EXT_LIVE_STATE=ERROR
expect "error" "$(ext_logout_verdict)" error

reset_facts; EXT_LIVE_VERSION="1.0.0"
expect "older version loaded" "$(ext_logout_verdict)" stale
EXT_LIVE_STATE=INACTIVE
expect "older version, switched off" "$(ext_logout_verdict)" stale

# Every spelling `info` uses for the version on disk is the same version.
reset_facts; EXT_DISK_VERSION_NUM=7; EXT_LIVE_VERSION="1.0.1 (7)"
expect "name (integer)" "$(ext_logout_verdict)" unsure
EXT_LIVE_VERSION="7"
expect "integer only" "$(ext_logout_verdict)" unsure
EXT_LIVE_VERSION="1.0.1 (6)"
expect "integer bumped" "$(ext_logout_verdict)" stale

reset_facts; EXT_LIVE_STATE=""; EXT_LIVE_VERSION=""
expect "no shell" "$(ext_logout_verdict)" unsure
reset_facts; EXT_DISK_VERSION_NAME=""
expect "nothing to compare" "$(ext_logout_verdict)" unsure

# --- ext_advice -------------------------------------------------------------

reset_facts
out="$(ext_advice new)"
says "new" "$out" "Log out and back in before the extension loads"
never_says "new" "$out" "No logout needed"

reset_facts; EXT_DISK_SUPPORTED=no; EXT_SHELL_VERSION="52.1"
out="$(ext_advice new)"
says "new, unsupported" "$out" "does not support GNOME Shell 52,"
says "new, unsupported" "$out" "/releases"
never_says "new, unsupported" "$out" "Log out and back in"
out="$(ext_advice other)"
says "other, unsupported" "$out" "--link-extension"

reset_facts
out="$(ext_advice own)"
says "own, current" "$out" "If extension/ changed since you last logged"
says "own, current" "$out" "If only the daemon changed, no"

reset_facts; EXT_LIVE_STATE="OUT OF DATE"
out="$(ext_advice own)"
says "own, out of date" "$out" "OUT OF DATE, so it is not running"
never_says "own, out of date" "$out" "no logout is needed"

reset_facts; EXT_LIVE_VERSION="1.0.0"
out="$(ext_advice own)"
says "own, stale" "$out" "running version 1.0.0 of the extension"
says "own, stale" "$out" "version 1.0.1 is installed now"

reset_facts; EXT_LIVE_STATE=""; EXT_LIVE_VERSION=""
out="$(ext_advice own)"
says "own, no shell" "$out" "Could not ask GNOME Shell"
says "own, no shell" "$out" "If extension/ changed"

reset_facts; EXT_LIVE_STATE=INACTIVE
out="$(ext_advice own)"
says "own, inactive" "$out" "reports the extension as INACTIVE"
says "own, inactive" "$out" "gnome-extensions enable $UUID"

# Somebody else's copy: "No logout needed" only while it is shown running.
reset_facts
out="$(ext_advice other)"
says "other, active" "$out" "No logout needed"
reset_facts; EXT_LIVE_STATE=ENABLED
out="$(ext_advice other)"
says "other, GNOME 45 active" "$out" "No logout needed"
for state in "OUT OF DATE" ERROR "NOT LOADED" INACTIVE ""; do
    reset_facts; EXT_LIVE_STATE="$state"
    out="$(ext_advice other)"
    never_says "other, '$state'" "$out" "No logout needed"
done
reset_facts; EXT_LIVE_STATE=""
says "other, no shell" "$(ext_advice other)" "Could not ask GNOME Shell"

# User extensions off: said once, and not followed by advice to enable this
# one extension, which would not help.
reset_facts; EXT_USER_OFF=true; EXT_LIVE_STATE=INACTIVE
out="$(ext_advice own)"
says "user off" "$out" "disable-user-extensions false"
never_says "user off" "$out" "gnome-extensions enable"
out="$(ext_advice other)"
never_says "user off, other" "$out" "No logout needed"
out="$(ext_advice new)"
says "user off, new" "$out" "disable-user-extensions false"
says "user off, new" "$out" "Log out and back in before"

echo "extension live state: ok"
