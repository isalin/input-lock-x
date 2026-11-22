#!/bin/bash
# Copyright (C) 2026 Isak Lindgren
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Exercise lib/extension-live.sh -- what install.sh says about logging out --
# against canned gnome-extensions, gnome-shell, gsettings and gdbus answers.
# Nothing here talks to a real shell or reads the user's settings: the stubs
# come first on PATH, and each answers only from files under $FAKE.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT="$(mktemp -d)"
# BG_PID: a process the start-time check runs, if it is still running.
BG_PID=""
trap '[[ -z "$BG_PID" ]] || kill "$BG_PID" 2>/dev/null; rm -rf "$TEST_ROOT"' EXIT

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
# $FAKE/enabled: the Enabled line, Yes or No; absent for Yes. `enable` sets it.
# $FAKE/enable-rc: what `enable` exits with, for a UUID the shell knows.
# $FAKE/version: what `version` prints; absent means it fails.
# $FAKE/calls: each subcommand, one per line, as it is called.
# Labels come out in Swedish unless LC_ALL=C, as they do on a Swedish desktop.
cat >"$TEST_ROOT/bin/gnome-extensions" <<'EOF'
#!/bin/bash
echo "$1" >>"$FAKE/calls"
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
    enabled="$(cat "$FAKE/enabled" 2>/dev/null || echo Yes)"
    label_state="State" label_desc="Description" label_enabled="Enabled"
    if [[ "${LC_ALL:-}" != C ]]; then
        label_state="Tillstånd" label_desc="Beskrivning" label_enabled="Aktiverad"
    fi
    # The description is printed as written, later lines and all, so it can
    # hold anything that looks like a field -- indented or not.
    printf '%s\n  Name: Input Lock X\n  %s: First line.\n' "$2" "$label_desc"
    printf '  State: bogus, a description line\nState: bogus too\n'
    if [[ -f "$FAKE/live-version" ]]; then
        printf '  Version: %s\n' "$(cat "$FAKE/live-version")"
    fi
    printf '  %s: %s\n  %s: %s\n' "$label_enabled" "$enabled" "$label_state" "$state"
    # Not real output -- State is the last field -- but the indent check is
    # all that tells a field from a line like this one.
    printf 'State: bogus as well\n' ;;
enable)
    [[ -f "$FAKE/list" ]] && grep -qxF -- "$2" "$FAKE/list" || exit 2
    rc="$(cat "$FAKE/enable-rc" 2>/dev/null || echo 0)"
    if [[ "$rc" -eq 0 ]]; then
        echo Yes >"$FAKE/enabled"
    fi
    exit "$rc" ;;
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
# $FAKE/locked: what ScreenSaver.GetActive returns, as `(<that>,)`.
# $FAKE/shell-pid: the PID that owns org.gnome.Shell.
# Either absent means the call fails.
cat >"$TEST_ROOT/bin/gdbus" <<'EOF'
#!/bin/bash
case " $* " in
*" --method org.gnome.ScreenSaver.GetActive "*)
    [[ -f "$FAKE/locked" ]] || exit 1
    echo "($(cat "$FAKE/locked"),)" ;;
*" --method org.freedesktop.DBus.GetConnectionUnixProcessID org.gnome.Shell "*)
    [[ -f "$FAKE/shell-pid" ]] || exit 1
    echo "(uint32 $(cat "$FAKE/shell-pid"),)" ;;
*)
    exit 1 ;;
esac
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

# mkext <dir> <metadata.json contents>: an extension directory, laid out as
# install.sh leaves this checkout's: code, and a compiled schema beside the
# XML.
mkext() {
    mkdir -p "$1/schemas"
    printf '%s\n' "$2" >"$1/metadata.json"
    echo "// code" >"$1/extension.js"
    echo "<schemalist/>" >"$1/schemas/org.example.gschema.xml"
    echo "compiled" >"$1/schemas/gschemas.compiled"
}
meta() {  # meta <shell-version list> [more JSON members]: valid metadata
    printf '{"uuid": "%s", "name": "Input Lock X", "description": "d", "shell-version": %s%s}' \
        "$UUID" "$1" "${2:+, $2}"
}

# --- ext_live_query ---------------------------------------------------------

ext_live_query "$UUID"
expect "no shell" "$EXT_LIVE_STATE" ""

printf 'other@example.com\n' >"$FAKE/list"
ext_live_query "$UUID"
expect "unknown UUID" "$EXT_LIVE_STATE" "NOT LOADED"

printf 'other@example.com\n%s\n' "$UUID" >"$FAKE/list"
echo "OUT OF DATE" >"$FAKE/states"
echo "1.1 β" >"$FAKE/live-version"
rm -f "$FAKE/calls"
ext_live_query "$UUID"
expect "state in a Swedish session" "$EXT_LIVE_STATE" "OUT OF DATE"
expect "version" "$EXT_LIVE_VERSION" "1.1 β"
expect "enabled" "$EXT_LIVE_ENABLED" yes
# `info` alone answers for an extension the shell has: no `list` first.
expect "one call" "$(cat "$FAKE/calls")" info
# And the stub really does translate, so the lines above prove something.
out="$(gnome-extensions info "$UUID")"
says "stub locale" "$out" "  Tillstånd: OUT OF DATE"
never_says "stub locale" "$out" "  State: OUT OF DATE"

rm "$FAKE/live-version"
echo ACTIVE >"$FAKE/states"
echo No >"$FAKE/enabled"
ext_live_query "$UUID"
expect "active" "$EXT_LIVE_STATE" "ACTIVE"
expect "no version line" "$EXT_LIVE_VERSION" ""
expect "switched off" "$EXT_LIVE_ENABLED" no
rm "$FAKE/enabled"

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

# --- ext_is_imported --------------------------------------------------------

for state in ACTIVE INACTIVE ACTIVATING DEACTIVATING ENABLED DISABLED; do
    ext_is_imported "$state" || fail "imported: $state"
done
for state in INITIALIZED "OUT OF DATE" ERROR "NOT LOADED" ""; do
    if ext_is_imported "$state"; then
        fail "not imported: '$state'"
    fi
done

# --- ext_installed_shell_version --------------------------------------------

echo "51.1" >"$FAKE/version"
expect "from gnome-extensions" "$(ext_installed_shell_version)" "51.1"
rm "$FAKE/version"
echo "52.rc" >"$FAKE/shell-version"
expect "from gnome-shell" "$(ext_installed_shell_version)" "52.rc"
rm "$FAKE/shell-version"
expect "neither" "$(ext_installed_shell_version)" ""

# --- ext_screen_locked ------------------------------------------------------

expect "no screensaver" "$(ext_screen_locked)" ""
echo true >"$FAKE/locked"
expect "locked" "$(ext_screen_locked)" true
echo false >"$FAKE/locked"
expect "unlocked" "$(ext_screen_locked)" false
echo maybe >"$FAKE/locked"
expect "nonsense" "$(ext_screen_locked)" ""
rm "$FAKE/locked"

# --- ext_shell_started ------------------------------------------------------

expect "no shell" "$(ext_shell_started)" ""
echo 999999999 >"$FAKE/shell-pid"
expect "no such process" "$(ext_shell_started)" ""
echo "x" >"$FAKE/shell-pid"
expect "not a PID" "$(ext_shell_started)" ""

# A command name with a space and parentheses in it, which is what
# /proc/<pid>/stat is hard to split around.
mkdir -p "$TEST_ROOT/odd"
cp "$(type -P sleep)" "$TEST_ROOT/odd/x) y (z"
"$TEST_ROOT/odd/x) y (z" 60 &
BG_PID=$!
echo "$BG_PID" >"$FAKE/shell-pid"
started="$(ext_shell_started)"
now="$(date +%s)"
[[ "$started" =~ ^[0-9]+$ ]] || fail "start time: got '$started'"
(( started <= now && started >= now - 10 )) ||
    fail "start time: $started, now $now"
kill "$BG_PID"
wait "$BG_PID" 2>/dev/null || true
BG_PID=""
rm "$FAKE/shell-pid"

# --- ext_disk_facts ---------------------------------------------------------

d="$TEST_ROOT/disk/$UUID"
mkext "$d" "$(meta '["45", "51"]' '"version-name": "1.0.1"')"
ext_disk_facts "$d" "$UUID" "51.1" ""
expect "loadable" "$EXT_DISK_PROBLEM" ""
expect "51.1 listed" "$EXT_DISK_SUPPORTED" yes
expect "version-name" "$EXT_DISK_VERSION_NAME" "1.0.1"
expect "no integer version" "$EXT_DISK_VERSION_NUM" ""
expect "no start time" "$EXT_DISK_CHANGED" ""
ext_disk_facts "$d" "$UUID" "52.1" ""
expect "52.1 not listed" "$EXT_DISK_SUPPORTED" no
ext_disk_facts "$d" "$UUID" "" ""
expect "shell version unknown" "$EXT_DISK_SUPPORTED" ""

# GNOME matches on the major version, so a bare "52" covers a release
# candidate too -- an exact-membership check would wrongly call it unsupported.
mkext "$d" "$(meta '["52"]' '"version": 7')"
ext_disk_facts "$d" "$UUID" "52.rc" ""
expect "52.rc under 52" "$EXT_DISK_SUPPORTED" yes
expect "integer version" "$EXT_DISK_VERSION_NUM" "7"
expect "no version-name" "$EXT_DISK_VERSION_NAME" ""

# UTF-8 in, UTF-8 out, whatever the locale -- as gnome-extensions prints it,
# so that the two compare equal. A byte-order mark is fine by GNOME too.
mkext "$d" "$(printf '\xef\xbb\xbf%s' "$(meta '["51"]' '"version-name": "1.1 β"')")"
LC_ALL=C ext_disk_facts "$d" "$UUID" "51" ""
expect "BOM" "$EXT_DISK_PROBLEM" ""
expect "non-ASCII version" "$EXT_DISK_VERSION_NAME" "1.1 β"

# Through a symlink, as install.sh installs it.
ln -s "$d" "$TEST_ROOT/disk/link"
ext_disk_facts "$TEST_ROOT/disk/link" "$UUID" "51" ""
expect "symlink" "$EXT_DISK_PROBLEM$EXT_DISK_SUPPORTED" yes

# What GNOME's scan would skip, and say nothing about.
problem() {  # problem <label> <metadata.json contents> <expected>
    mkext "$d" "$2"
    ext_disk_facts "$d" "$UUID" "51" ""
    expect "$1" "$EXT_DISK_PROBLEM" "$3"
    expect "$1, no support verdict" "$EXT_DISK_SUPPORTED" ""
}
problem "invalid JSON" '{"uuid": ' "its metadata.json is not valid JSON"
problem "NaN" "$(meta '["51"]' '"version": NaN')" "its metadata.json is not valid JSON"
problem "not an object" '["51"]' 'its metadata.json has no "uuid"'
problem "no name" "{\"uuid\": \"$UUID\", \"description\": \"d\", \"shell-version\": [\"51\"]}" \
    'its metadata.json has no "name"'
problem "empty description" "{\"uuid\": \"$UUID\", \"name\": \"n\", \"description\": \"\", \"shell-version\": [\"51\"]}" \
    'its metadata.json has no "description"'
problem "empty shell-version" "$(meta '[]')" 'its metadata.json has no "shell-version" list'
problem "numeric shell-version" "$(meta '[51]')" 'its metadata.json has no "shell-version" list'
problem "another UUID" '{"uuid": "x@y", "name": "n", "description": "d", "shell-version": ["51"]}' \
    'its metadata.json names another UUID, "x@y"'

rm "$d/metadata.json"
ext_disk_facts "$d" "$UUID" "51" ""
expect "no metadata" "$EXT_DISK_PROBLEM" "it has no metadata.json"
ext_disk_facts "$TEST_ROOT/nowhere" "$UUID" "51" ""
expect "nothing there" "$EXT_DISK_PROBLEM" "it is not there"
ln -s "$TEST_ROOT/nowhere" "$TEST_ROOT/disk/dangling"
ext_disk_facts "$TEST_ROOT/disk/dangling" "$UUID" "51" "1"
expect "dangling" "$EXT_DISK_PROBLEM" "it is a symlink to something that is not there"
expect "dangling, no change time" "$EXT_DISK_CHANGED" ""
touch "$TEST_ROOT/disk/file"
ext_disk_facts "$TEST_ROOT/disk/file" "$UUID" "51" ""
expect "a file" "$EXT_DISK_PROBLEM" "it is not a directory"

# Changed since the shell started. ctime counts, so a copy that kept its old
# mtime still shows up as new.
rm -rf "$d"
mkext "$d" "$(meta '["51"]')"
now="$(date +%s)"
ext_disk_facts "$d" "$UUID" "51" "$(( now + 100 ))"
expect "nothing since" "$EXT_DISK_CHANGED" no
ext_disk_facts "$d" "$UUID" "51" "$(( now - 100 ))"
expect "changed since" "$EXT_DISK_CHANGED" yes
touch -d "2020-01-01" "$d" "$d/"* "$d/schemas" "$d/schemas/"*
ext_disk_facts "$d" "$UUID" "51" "$(( now - 100 ))"
expect "old mtime, new ctime" "$EXT_DISK_CHANGED" yes

# The compiled schema is not: install.sh rebuilds it on every run. The wait
# makes everything above older than the start time, and the start time older
# than the rebuild.
since=$(( $(date +%s) + 1 ))
command sleep 1.2
echo "recompiled" >"$d/schemas/gschemas.compiled.tmp"
mv "$d/schemas/gschemas.compiled.tmp" "$d/schemas/gschemas.compiled"
ext_disk_facts "$d" "$UUID" "51" "$since"
expect "schema rebuilt" "$EXT_DISK_CHANGED" no
echo "// more code" >>"$d/extension.js"
ext_disk_facts "$d" "$UUID" "51" "$since"
expect "code changed" "$EXT_DISK_CHANGED" yes

# --- ext_gather -------------------------------------------------------------

checkout="$TEST_ROOT/checkout/extension"
mkext "$checkout" "$(meta '["51"]' '"version-name": "1.0.1"')"
mkdir -p "$(dirname "$EXT_DIR")"
ln -s "$checkout" "$EXT_DIR"
printf '%s\n' "$UUID" >"$FAKE/list"
echo ACTIVE >"$FAKE/states"
echo "1.0.1" >"$FAKE/live-version"
echo "51.1" >"$FAKE/version"
echo false >"$FAKE/gs-disable-user-extensions"
echo false >"$FAKE/gs-disable-extension-version-validation"
echo true >"$FAKE/gs-allow-extension-installation"
echo false >"$FAKE/locked"
# This test's own process: it started before the files above were written.
echo "$$" >"$FAKE/shell-pid"

ext_gather "$UUID" "$EXT_DIR" "$checkout"
expect "gather: state" "$EXT_LIVE_STATE" ACTIVE
expect "gather: live version" "$EXT_LIVE_VERSION" "1.0.1"
expect "gather: shell" "$EXT_SHELL_VERSION" "51.1"
expect "gather: user off" "$EXT_USER_OFF" false
expect "gather: check off" "$EXT_CHECK_OFF" false
expect "gather: home dir allowed" "$EXT_ALLOW_INSTALL" true
expect "gather: locked" "$EXT_LOCKED" false
expect "gather: supported" "$EXT_DISK_SUPPORTED" yes
expect "gather: checkout supported" "$EXT_REPO_SUPPORTED" yes
expect "gather: changed since login" "$EXT_DISK_CHANGED" yes
expect "gather: fresh import" "$EXT_FRESH_IMPORT" 0
expect "gather: verdict" "$(ext_logout_verdict own)" changed

# Somebody else's copy, which does not support the shell, beside a checkout
# that does: the facts are the installed copy's, and the checkout is still
# worth suggesting.
rm "$EXT_DIR"
mkext "$EXT_DIR" "$(meta '["50"]' '"version-name": "0.9"')"
ext_gather "$UUID" "$EXT_DIR" "$checkout"
expect "gather other: supported" "$EXT_DISK_SUPPORTED" no
expect "gather other: version" "$EXT_DISK_VERSION_NAME" "0.9"
expect "gather other: checkout supported" "$EXT_REPO_SUPPORTED" yes
says "gather other: advice" "$(ext_advice other)" "--link-extension"
mkext "$checkout" '{'
ext_gather "$UUID" "$EXT_DIR" "$checkout"
expect "gather other: checkout broken" "$EXT_REPO_SUPPORTED" ""
never_says "gather other: advice" "$(ext_advice other)" "--link-extension"

# Nothing answers: everything unknown, nothing claimed.
rm -f "$FAKE/list" "$FAKE/version" "$FAKE/gs-"* "$FAKE/locked" "$FAKE/shell-pid"
ext_gather "$UUID" "$EXT_DIR" "$checkout"
expect "gather nothing: state" "$EXT_LIVE_STATE" ""
expect "gather nothing: settings" "$EXT_USER_OFF$EXT_CHECK_OFF$EXT_ALLOW_INSTALL$EXT_LOCKED" ""
expect "gather nothing: changed" "$EXT_DISK_CHANGED" ""
expect "gather nothing: verdict" "$(ext_logout_verdict other)" unsure
rm -rf "$EXT_DIR"

# --- ext_switch_on ----------------------------------------------------------

EXT_USER_OFF=false
EXT_LOCKED=false
EXT_LIVE_STATE=""
if ext_switch_on "$UUID"; then
    fail "switch on with no shell"
fi

printf '%s\n' "$UUID" >"$FAKE/list"
echo 1 >"$FAKE/enable-rc"
if ext_switch_on "$UUID"; then
    fail "switch on, refused"
fi
rm "$FAKE/enable-rc"

# Never imported before: switching it on imports the code on disk, whatever
# version the session read at login.
EXT_LIVE_STATE=INITIALIZED
printf 'INITIALIZED\nACTIVATING\nACTIVE\n' >"$FAKE/states"
echo "1.0.0" >"$FAKE/live-version"
ext_switch_on "$UUID" || fail "switch on"
expect "switch on: state" "$EXT_LIVE_STATE" ACTIVE
expect "switch on: fresh import" "$EXT_FRESH_IMPORT" 1
EXT_DISK_PROBLEM="" EXT_DISK_SUPPORTED=yes EXT_DISK_VERSION_NAME="1.0.1"
EXT_DISK_VERSION_NUM="" EXT_DISK_CHANGED=yes EXT_ALLOW_INSTALL=true
EXT_CHECK_OFF=false
expect "switch on: verdict" "$(ext_logout_verdict own)" current

EXT_LIVE_STATE=INACTIVE
echo ACTIVE >"$FAKE/states"
ext_switch_on "$UUID" || fail "switch on, imported"
expect "switch on, imported: fresh import" "$EXT_FRESH_IMPORT" 0

# Off or locked: nothing comes up, so one look, not two seconds of waiting.
for why in EXT_USER_OFF EXT_LOCKED; do
    EXT_USER_OFF=false EXT_LOCKED=false
    printf -v "$why" true
    EXT_LIVE_STATE=INITIALIZED
    echo No >"$FAKE/enabled"
    printf 'INITIALIZED\nACTIVE\n' >"$FAKE/states"
    ext_switch_on "$UUID" || fail "switch on, $why"
    expect "switch on, $why: state" "$EXT_LIVE_STATE" INITIALIZED
    expect "switch on, $why: enabled" "$EXT_LIVE_ENABLED" yes
    expect "switch on, $why: fresh import" "$EXT_FRESH_IMPORT" 0
done
rm -f "$FAKE/list" "$FAKE/live-version" "$FAKE/enabled"

# --- ext_logout_verdict -----------------------------------------------------

# A healthy, current install: the defaults each case below departs from.
reset_facts() {
    EXT_LIVE_STATE=ACTIVE
    EXT_LIVE_VERSION="1.0.1"
    EXT_LIVE_ENABLED=yes
    EXT_FRESH_IMPORT=0
    EXT_SHELL_VERSION="51.1"
    EXT_DISK_PROBLEM=""
    EXT_DISK_SUPPORTED=yes
    EXT_DISK_VERSION_NAME="1.0.1"
    EXT_DISK_VERSION_NUM=""
    EXT_DISK_CHANGED=no
    EXT_REPO_SUPPORTED=yes
    EXT_USER_OFF=false
    EXT_CHECK_OFF=false
    EXT_ALLOW_INSTALL=true
    EXT_LOCKED=false
}

reset_facts
expect "current" "$(ext_logout_verdict own)" current
EXT_DISK_CHANGED=yes
expect "changed" "$(ext_logout_verdict own)" changed
EXT_DISK_CHANGED=""
expect "no start time" "$(ext_logout_verdict own)" unsure

reset_facts; EXT_ALLOW_INSTALL=false; EXT_DISK_PROBLEM="it is not there"
expect "home dir not scanned" "$(ext_logout_verdict own)" no-user-dir
reset_facts; EXT_DISK_PROBLEM="it is not there"; EXT_DISK_SUPPORTED=""
expect "broken" "$(ext_logout_verdict own)" broken
expect "broken, new" "$(ext_logout_verdict new)" broken

reset_facts; EXT_DISK_SUPPORTED=no
expect "unsupported" "$(ext_logout_verdict own)" unsupported
expect "unsupported, new" "$(ext_logout_verdict new)" unsupported
EXT_CHECK_OFF=true
expect "unsupported, check off" "$(ext_logout_verdict own)" current

# Newly placed: what the shell reports is about whatever it read at login.
reset_facts
expect "new, old copy running" "$(ext_logout_verdict new)" new

reset_facts; EXT_LIVE_STATE="NOT LOADED"; EXT_LIVE_VERSION=""
expect "not loaded" "$(ext_logout_verdict own)" not-loaded
reset_facts; EXT_LIVE_STATE="OUT OF DATE"
expect "out of date" "$(ext_logout_verdict own)" out-of-date
reset_facts; EXT_LIVE_STATE=ERROR
expect "error" "$(ext_logout_verdict own)" error
reset_facts; EXT_LIVE_STATE=INITIALIZED; EXT_LIVE_VERSION="1.0.0"; EXT_DISK_CHANGED=yes
expect "never imported" "$(ext_logout_verdict own)" not-imported
for state in DOWNLOADING UNINSTALLED ""; do
    reset_facts; EXT_LIVE_STATE="$state"
    expect "state '$state'" "$(ext_logout_verdict own)" unsure
done

reset_facts; EXT_LIVE_VERSION="1.0.0"
expect "older version loaded" "$(ext_logout_verdict own)" stale
EXT_LIVE_STATE=INACTIVE
expect "older version, switched off" "$(ext_logout_verdict own)" stale
EXT_FRESH_IMPORT=1
expect "imported just now" "$(ext_logout_verdict own)" current

# Every spelling `info` uses for the version on disk is the same version.
reset_facts; EXT_DISK_VERSION_NUM=7; EXT_LIVE_VERSION="1.0.1 (7)"
expect "name (integer)" "$(ext_logout_verdict own)" current
EXT_LIVE_VERSION="7"
expect "integer only" "$(ext_logout_verdict own)" current
EXT_LIVE_VERSION="1.0.1 (6)"
expect "integer bumped" "$(ext_logout_verdict own)" stale

reset_facts; EXT_DISK_VERSION_NAME=""
expect "nothing to compare" "$(ext_logout_verdict own)" current

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
# Replacing it with this checkout only helps if GNOME would load this one.
EXT_REPO_SUPPORTED=no
out="$(ext_advice other)"
never_says "other, checkout unsupported too" "$out" "--link-extension"
says "other, checkout unsupported too" "$out" "/releases"
EXT_REPO_SUPPORTED=""
never_says "other, checkout broken" "$(ext_advice other)" "--link-extension"

reset_facts; EXT_ALLOW_INSTALL=false
out="$(ext_advice own)"
says "home dir off" "$out" "allow-extension-installation true"
never_says "home dir off" "$out" "No logout needed"

reset_facts; EXT_DISK_PROBLEM='its metadata.json has no "name"'
out="$(ext_advice other)"
says "broken" "$out" 'its metadata.json has no "name"'
says "broken" "$out" "logging out does not help"
says "broken" "$out" "--link-extension"
says "broken, own" "$(ext_advice own)" "git status"

# Current, and running: the one case that needs nothing at all.
reset_facts
out="$(ext_advice own)"
says "own, current" "$out" "No logout needed -- GNOME is running"
never_says "own, current" "$out" "If extension/ changed"

reset_facts; EXT_DISK_CHANGED=yes
out="$(ext_advice own)"
says "own, changed" "$out" "changed since this session started"
says "own, changed" "$out" "Log out and back in"

reset_facts; EXT_DISK_CHANGED=""
out="$(ext_advice own)"
says "own, unsure" "$out" "If extension/ changed since you last logged"
says "own, unsure" "$out" "the running extension picks it up on its own"

# Not running: the daemon line must not say a running extension picks it up.
reset_facts; EXT_DISK_CHANGED=""; EXT_LIVE_STATE=INACTIVE
out="$(ext_advice own)"
says "own, unsure, inactive" "$out" "If only the daemon changed, no"
never_says "own, unsure, inactive" "$out" "picks it up"
says "own, unsure, inactive" "$out" "reports the extension as INACTIVE"

reset_facts; EXT_LIVE_STATE=""; EXT_LIVE_VERSION=""; EXT_DISK_CHANGED=""
out="$(ext_advice own)"
says "own, no shell" "$out" "Could not ask GNOME Shell"
says "own, no shell" "$out" "if the extension is running"

reset_facts; EXT_LIVE_STATE="OUT OF DATE"
out="$(ext_advice own)"
says "own, out of date" "$out" "OUT OF DATE, so it is not running"
never_says "own, out of date" "$out" "no logout is needed"

reset_facts; EXT_LIVE_STATE="NOT LOADED"
says "own, not loaded" "$(ext_advice own)" "it was not there, or not loadable"

reset_facts; EXT_LIVE_VERSION="1.0.0"
out="$(ext_advice own)"
says "own, stale" "$out" "This session loaded version 1.0.0 of the extension"
says "own, stale" "$out" "1.0.1 is installed now"
never_says "own, stale" "$out" "running version"

reset_facts; EXT_LIVE_STATE=INACTIVE
out="$(ext_advice own)"
says "own, inactive" "$out" "No logout needed"
says "own, inactive" "$out" "reports the extension as INACTIVE"
EXT_LIVE_ENABLED=no
out="$(ext_advice own)"
says "own, switched off" "$out" "It is switched off"
says "own, switched off" "$out" "gnome-extensions enable $UUID"

# Locked: GNOME sets the extension aside until the screen is unlocked, which
# switching it on would not change.
reset_facts; EXT_LIVE_STATE=INACTIVE; EXT_LOCKED=true
for who in own other; do
    out="$(ext_advice "$who")"
    says "locked, $who" "$out" "No logout needed"
    says "locked, $who" "$out" "The screen is locked"
    never_says "locked, $who" "$out" "gnome-extensions enable"
done

reset_facts; EXT_LIVE_STATE=INITIALIZED; EXT_LIVE_ENABLED=no; EXT_DISK_CHANGED=yes
out="$(ext_advice other)"
says "never imported" "$out" "no logout needed"
says "never imported" "$out" "gnome-extensions enable $UUID"

# Somebody else's copy: "No logout needed" only once that is shown.
reset_facts
out="$(ext_advice other)"
says "other, active" "$out" "No logout needed"
reset_facts; EXT_LIVE_STATE=ENABLED; EXT_DISK_CHANGED=""
out="$(ext_advice other)"
says "other, GNOME 45 active" "$out" "No logout needed"
for state in "OUT OF DATE" ERROR "NOT LOADED" INACTIVE ""; do
    reset_facts; EXT_LIVE_STATE="$state"; EXT_DISK_CHANGED=""
    out="$(ext_advice other)"
    never_says "other, '$state'" "$out" "No logout needed"
done
reset_facts; EXT_LIVE_STATE=""; EXT_DISK_CHANGED=""
says "other, no shell" "$(ext_advice other)" "Could not ask GNOME Shell"

# User extensions off: said, whatever else is wrong, and not followed by advice
# to enable this one extension, which would not help.
reset_facts; EXT_USER_OFF=true; EXT_LIVE_STATE=INACTIVE
out="$(ext_advice own)"
says "user off" "$out" "disable-user-extensions false"
never_says "user off" "$out" "gnome-extensions enable"
out="$(ext_advice other)"
says "user off, other" "$out" "disable-user-extensions false"
out="$(ext_advice new)"
says "user off, new" "$out" "disable-user-extensions false"
says "user off, new" "$out" "Log out and back in before"
EXT_DISK_SUPPORTED=no
out="$(ext_advice own)"
says "user off, unsupported" "$out" "disable-user-extensions false"
says "user off, unsupported" "$out" "does not support GNOME Shell"

# --- ext_enable_report ------------------------------------------------------

reset_facts
out="$(ext_enable_report own failed 2>&1 >/dev/null)"
says "failed" "$out" "could not enable it, and could not queue it either"
expect "failed, stdout" "$(ext_enable_report own failed 2>/dev/null)" ""

reset_facts
expect "running" "$(ext_enable_report own enabled)" "   enabled"
# A new copy over an old one that is running: the old one is what is enabled.
expect "new over a running copy" "$(ext_enable_report new enabled)" \
    "   switched on -- it loads after you log out and back in"
expect "new, queued" "$(ext_enable_report new queued)" \
    "   queued -- it comes up enabled after you log out and back in"
EXT_DISK_SUPPORTED=no
expect "new, unsupported, queued" "$(ext_enable_report new queued)" \
    "   queued, but GNOME will not load it -- see below"
reset_facts; EXT_LIVE_VERSION="1.0.0"
expect "stale" "$(ext_enable_report own enabled)" \
    "   switched on -- the new version loads after you log out and back in"
reset_facts; EXT_LIVE_STATE=""
expect "no shell" "$(ext_enable_report own enabled)" "   switched on"
expect "no shell, queued" "$(ext_enable_report own queued)" \
    "   queued -- it comes up enabled at the next login"
reset_facts; EXT_LIVE_STATE=INACTIVE; EXT_LOCKED=true
expect "locked" "$(ext_enable_report own enabled)" \
    "   switched on; the screen is locked, so it starts when you unlock it"

# Every "see below" has something below it to see, because both read the
# same facts.
for who in new own; do
for state in ACTIVE INACTIVE INITIALIZED "OUT OF DATE" ERROR "NOT LOADED" ""; do
for user_off in false true; do
for supported in yes no; do
for locked in false true; do
for how in enabled queued; do
    reset_facts
    EXT_LIVE_STATE="$state" EXT_USER_OFF="$user_off"
    EXT_DISK_SUPPORTED="$supported" EXT_LOCKED="$locked"
    case_="$who/$state/$user_off/$supported/$locked/$how"
    report="$(ext_enable_report "$who" "$how")"
    advice="$(ext_advice "$who")"
    case "$report" in
    *"GNOME will not load it -- see below")
        says "$case_" "$advice" "does not help" ;;
    *"user extensions are switched off -- see below")
        says "$case_" "$advice" "disable-user-extensions false" ;;
    *"GNOME reports it as "*" -- see below")
        reported="${report#*GNOME reports it as }"
        says "$case_" "$advice" "reports the extension as ${reported% -- see below}" ;;
    *"see below"*)
        fail "$case_: unexpected report: $report" ;;
    "   enabled")
        says "$case_" "$advice" "No logout needed" ;;
    esac
    # And the line never says it is enabled when the paragraph says to log
    # out, or that nothing will help.
    if [[ "$report" == "   enabled" ]]; then
        never_says "$case_" "$advice" "Log out and back in"
    fi
done; done; done; done; done; done

echo "extension live state: ok"
