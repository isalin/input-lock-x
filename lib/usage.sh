# Copyright (C) 2026 Isak Lindgren
# SPDX-License-Identifier: GPL-2.0-or-later
#
# --help text, shared by install.sh and uninstall.sh.
# shellcheck shell=bash
#
# The help text is the comment block at the top of the calling script.
# Extracted by shape rather than by line number: `sed -n '2,9p'` was correct
# only until someone added a line above it, and nothing in `make check` can
# catch a window that has slid. Skip the shebang, strip the leading '# ', drop
# the licence and copyright lines, and stop at the first line that is not a
# comment.
#
# Shared for the same reason lib/paths.sh is. The filter regex has already been
# edited once -- when the copyright line was added, it had to learn to drop
# that too -- and a second edit landing in one copy and not the other means a
# script quietly printing its own licence header at users.
#
# scripts/input-lock-x deliberately keeps its own copy: it is installed
# standalone into /usr/local/bin with no lib/ beside it, so it cannot source
# this and has to carry the function itself.
usage() {
    awk 'NR == 1 { next }
         /^#/ {
             sub(/^# ?/, "")
             if ($0 !~ /^(SPDX-License-Identifier:|Copyright )/)
                 print
             next
         }
         { exit }' "$0"
}
