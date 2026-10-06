#!/usr/bin/env bash
# GPL-3.0-or-later. Explicit public dictionary path; never a personal source.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# != 2 ]]; then
  echo 'usage: bash engine/run-local-conversion-classification.sh PUBLIC_L OUTPUT_JSON' >&2
  exit 2
fi
private=$(mktemp -d /tmp/lfd1-classification.XXXXXXXX)
trap 'rm -rf "$private"' EXIT
mkdir -p "$private/home" "$private/learning"
env HOME="$private/home" LOCALAPPDATA="$private/home" TMPDIR="$private" \
  XDG_CACHE_HOME="$private/cache" DDSKK_USER_JISYO="$private/learning/overlay.jisyo" \
  LOCAL_ORACLE_DIR="$private/home" \
  emacs -Q --batch -L vendor/ddskk -L engine -l engine/test-local-conversion-oracle.el \
  --eval '(lfd1-oracle--profile-overlay "classification-overlay.jisyo")'
g++ -std=c++20 -Wall -Wextra -Werror -pedantic -Iwindows/src \
  windows/test/local_index_portable_test.cpp -o "$private/local-index-portable"
python3 engine/classify-local-conversion.py --dictionary "$1" --output "$2" \
  --binary "$private/local-index-portable" --overlay "$private/home/classification-overlay.jisyo"
