#!/usr/bin/env bash
# S3b-2 end-to-end: build host-mock.exe + a compose-mode stub-tip.dll with
# nelisp, run a key script under wine against the mock TSF and compare the
# call trace with golden/host-mock.golden.
# Env: NELISP_ROOT (NeLisp checkout; default ../nelisp next to the repo),
#      WINEPREFIX or NELISP_TSF_WINEPREFIX (default: temp dir),
#      NELISP_TSF_SWAP_GOLDEN=1    negative control: compare against the golden
#                                  with lines 6 and 7 swapped (must FAIL).
#      NELISP_TSF_UPDATE_GOLDEN=1  rewrite golden/host-mock.golden from this run
#                                  (review the diff before keeping it).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
if [ -z "${NELISP_ROOT:-}" ]; then
  [ -d "$REPO/../nelisp/lisp" ] && NELISP_ROOT="$(cd "$REPO/../nelisp" && pwd)"
fi
if [ -z "${NELISP_ROOT:-}" ] || [ ! -f "$NELISP_ROOT/lisp/nelisp-com-dsl.el" ]; then
  echo "FAIL: NeLisp not found; set NELISP_ROOT to a checkout with lisp/nelisp-com-dsl.el"; exit 1
fi
export NELISP_ROOT
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tsf-host-mock.XXXXXX")" || exit 1
PFX_TMP=""
if [ -n "${WINEPREFIX:-}" ]; then :
elif [ -n "${NELISP_TSF_WINEPREFIX:-}" ]; then WINEPREFIX="$NELISP_TSF_WINEPREFIX"
else PFX_TMP="$(mktemp -d "${TMPDIR:-/tmp}/tsf-wineprefix.XXXXXX")"; WINEPREFIX="$PFX_TMP"; fi
export WINEPREFIX WINEDEBUG=-all WINEARCH=win64
cleanup() {
  # Only stop the wineserver of a prefix this run created; a caller-supplied
  # prefix may be shared with other processes.
  if [ -n "$PFX_TMP" ]; then timeout 60 wineserver -k >/dev/null 2>&1; rm -rf "$PFX_TMP"; fi
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; exit 1; }

(ulimit -v 8388608; timeout 300 emacs -Q --batch -L "$NELISP_ROOT/lisp" -L "$HERE" \
   -l host-mock.el --eval "(host-mock-build-all \"$WORK\")") >"$WORK/build.log" 2>&1 \
  || { head -c 600 "$WORK/build.log"; fail "build"; }

WDLL="$(cd "$WORK" && winepath -w "$WORK/stub-tip.dll" 2>/dev/null)" || fail "winepath"
SCRIPT="a b"
(cd "$WORK" && DDSKK_HARNESS_DLL_PATH="$WDLL" timeout 120 wine host-mock.exe $SCRIPT \
   </dev/null >"$WORK/out.txt" 2>"$WORK/err.txt"); rc=$?
[ "$rc" = 0 ] || { head -20 "$WORK/out.txt"; fail "host exit=$rc"; }
cp "$WORK/out.txt" "$WORK/actual.txt"
if [ "${NELISP_TSF_UPDATE_GOLDEN:-}" = 1 ]; then cp "$WORK/actual.txt" "$HERE/golden/host-mock.golden"; fi
GOLD="$HERE/golden/host-mock.golden"
if [ "${NELISP_TSF_SWAP_GOLDEN:-}" = 1 ]; then
  awk 'NR==6{h=$0;next} NR==7{print;print h;next} {print}' "$GOLD" >"$WORK/golden-swapped.txt"
  GOLD="$WORK/golden-swapped.txt"
fi
diff -u "$GOLD" "$WORK/actual.txt" >"$WORK/diff.txt" \
  || { head -30 "$WORK/diff.txt"; fail "trace differs from golden"; }
echo "PASS: host-mock trace matches golden"
exit 0
