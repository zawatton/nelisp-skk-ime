#!/usr/bin/env bash
# GPL-3.0-or-later. Build/test production portable helpers against vendor DDSKK.
set -euo pipefail
cd "$(dirname "$0")/.."
private=$(mktemp -d /tmp/lfd1-oracle.XXXXXXXX)
trap 'rm -rf "$private"' EXIT
mkdir -p "$private/home" "$private/learning"
g++ -std=c++20 -Wall -Wextra -Werror -pedantic -Iwindows/src \
  windows/test/local_index_portable_test.cpp -o "$private/local-index-portable"
env HOME="$private/home" LOCALAPPDATA="$private/home" TMPDIR="$private" \
  XDG_CACHE_HOME="$private/cache" DDSKK_USER_JISYO="$private/learning/overlay.jisyo" \
  LOCAL_ORACLE_DIR="$private/home" LOCAL_ORACLE_BINARY="$private/local-index-portable" \
  emacs -Q --batch -L vendor/ddskk -L engine \
  -l engine/test-local-conversion-oracle.el -f ert-run-tests-batch-and-exit
