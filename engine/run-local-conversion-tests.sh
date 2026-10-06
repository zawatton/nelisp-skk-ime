#!/usr/bin/env bash
# GPL-3.0-or-later. Never load dictionaries or initialization from the real HOME.
set -euo pipefail
cd "$(dirname "$0")/.."
private=$(mktemp -d /tmp/lfd1-engine.XXXXXXXX)
trap 'rm -rf "$private"' EXIT
mkdir -p "$private/home" "$private/learning"
test_directory=engine
if [[ ${1:-} == --baseline ]]; then
  mkdir "$private/baseline"
  cp engine/test-local-conversion.el "$private/baseline/"
  git show 28e9882:engine/skk-user-jisyo.el > "$private/baseline/skk-user-jisyo.el"
  git show 28e9882:engine/skk-local-conversion.el > "$private/baseline/skk-local-conversion.el"
  test_directory="$private/baseline"
elif [[ $# != 0 ]]; then
  echo 'usage: bash engine/run-local-conversion-tests.sh [--baseline]' >&2
  exit 2
fi
if [[ ${1:-} == --baseline ]]; then
  set +e
  env HOME="$private/home" LOCALAPPDATA="$private/home" TMPDIR="$private" \
    XDG_CACHE_HOME="$private/cache" DDSKK_USER_JISYO="$private/learning/overlay.jisyo" \
    LOCAL_LEARNING_TEST_DIR="$private/learning" \
    emacs -Q --batch -L vendor/ddskk -L "$test_directory" -l "$test_directory/test-local-conversion.el" \
    --eval '(ert-run-tests-batch-and-exit (quote (or local-candidate-customizations-use-provider local-base-duplicate-first-journal-duplicate-last)))' \
    > "$private/baseline.log" 2>&1
  result=$?
  set -e
  tail -7 "$private/baseline.log"
  python3 - "$private/baseline.log" "$result" <<'PY'
import pathlib, re, sys
log = pathlib.Path(sys.argv[1]).read_text()
assert int(sys.argv[2]) == 1
assert re.search(r'Ran 2 tests, 0 results as expected, 2 unexpected', log)
assert re.search(r'^   FAILED  local-candidate-customizations-use-provider$', log, re.M)
assert re.search(r'^   FAILED  local-base-duplicate-first-journal-duplicate-last$', log, re.M)
print('PASS engine baseline negative control: 2 regressions rejected')
PY
  exit 0
fi
env HOME="$private/home" LOCALAPPDATA="$private/home" TMPDIR="$private" \
  XDG_CACHE_HOME="$private/cache" \
  DDSKK_USER_JISYO="$private/learning/overlay.jisyo" \
  LOCAL_LEARNING_TEST_DIR="$private/learning" \
  emacs -Q --batch -L vendor/ddskk -L "$test_directory" -l "$test_directory/test-local-conversion.el" \
  -f ert-run-tests-batch-and-exit
