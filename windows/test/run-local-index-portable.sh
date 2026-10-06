#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
binary=$(mktemp /tmp/local-index-portable.XXXXXX)
trap 'rm -f "$binary"' EXIT
g++ -std=c++20 -Wall -Wextra -Werror -pedantic \
  -I"$repo_root/windows/src" \
  "$repo_root/windows/test/local_index_portable_test.cpp" -o "$binary"
"$binary" "$@"
