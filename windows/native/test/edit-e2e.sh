#!/usr/bin/env bash
# S3i end-to-end (mock host): the native core (ddskk-core.el with the edit
# module and the CoreApplyState test exports) is driven through the real
# NativeImeGetCoreApi table by edit-e2e.exe, which owns the mock TSF objects of
# host-mock.el.  Scripted engine states run through StateEditSession ->
# ApplyEngineState; the mock method trace must match golden/edit-e2e.golden
# (derivation: golden/edit-e2e.derivation.txt).  Checks:
#   1. golden comparison of the full trace;
#   2. negative controls: core mutants skip-end (never calls EndComposition)
#      and wrong-guid (preedit gets the candidate attribute GUID) must differ
#      from the golden; EDIT_E2E_MUTANT=<name> makes the MAIN core the mutant
#      so the whole script must FAIL.
# Env: NELISP_ROOT, NELISP_TSF_UPDATE_GOLDEN=1 rewrites the golden (review it!).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
if [ -z "${NELISP_ROOT:-}" ]; then
  [ -d "$REPO/../nelisp/lisp" ] && NELISP_ROOT="$(cd "$REPO/../nelisp" && pwd)"
fi
if [ -z "${NELISP_ROOT:-}" ] || [ ! -f "$NELISP_ROOT/lisp/nelisp-com-dsl.el" ]; then
  echo "FAIL: NeLisp not found; set NELISP_ROOT to a checkout with lisp/nelisp-com-dsl.el"; exit 1
fi
export NELISP_ROOT
WORK="$(mktemp -d "${TMPDIR:-/tmp}/edit-e2e.XXXXXX")" || exit 1
PFX_TMP=""
if [ -n "${WINEPREFIX:-}" ]; then :
elif [ -n "${NELISP_TSF_WINEPREFIX:-}" ]; then WINEPREFIX="$NELISP_TSF_WINEPREFIX"
else PFX_TMP="$(mktemp -d "${TMPDIR:-/tmp}/edit-e2e-wineprefix.XXXXXX")"; WINEPREFIX="$PFX_TMP"; fi
export WINEPREFIX WINEDEBUG=-all WINEARCH=win64
cleanup() {
  if [ -n "$PFX_TMP" ]; then timeout 60 wineserver -k >/dev/null 2>&1; rm -rf "$PFX_TMP"; fi
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "ok: $*"; }
emacs_run() { (ulimit -v 8388608; timeout 600 emacs -Q --batch -L "$NELISP_ROOT/lisp" -L "$NATIVE" -L "$HERE" "$@"); }

build_core() { # dir [env assignments...]
  local d="$1"; shift
  mkdir -p "$d"
  ( export NELISP_CORE_TEST_EXPORTS=1
    for a in "$@"; do export "$a"; done
    emacs_run -l ddskk-core.el --eval "(ddskk-core-build-from-env \"$d/ddskk-ime-core.dll\")" ) \
    >"$d/core-build.log" 2>&1 || { tail -5 "$d/core-build.log" | cut -c1-300; fail "build core in $d"; }
}
MAIN_ENV=()
case "${EDIT_E2E_MUTANT:-}" in
  skip-end|wrong-guid) MAIN_ENV=(NELISP_CORE_MUTANT="$EDIT_E2E_MUTANT") ;;
  "") ;;
  *) fail "unknown EDIT_E2E_MUTANT=$EDIT_E2E_MUTANT" ;;
esac
build_core "$WORK/main" "${MAIN_ENV[@]}"
build_core "$WORK/skipend" NELISP_CORE_MUTANT=skip-end
build_core "$WORK/wrongguid" NELISP_CORE_MUTANT=wrong-guid
emacs_run -l edit-e2e-client.el --eval "(edit-e2e-client-build \"$WORK/edit-e2e.exe\")" \
  >"$WORK/client-build.log" 2>&1 || { tail -5 "$WORK/client-build.log" | cut -c1-300; fail "build client"; }
ok "built core (main, skip-end mutant, wrong-guid mutant) and the mock-host client"

run_client() { # dir
  COUT="$(cd "$WORK" && DDSKK_CORE_PATH="$(winepath -w "$1/ddskk-ime-core.dll")" \
          timeout 120 wine edit-e2e.exe </dev/null 2>/dev/null)"; CRC=$?
}
golden() { # name actual [nowrite]
  local g="$HERE/golden/$1.golden"
  printf '%s\n' "$2" >"$WORK/$1.actual"
  if [ "${NELISP_TSF_UPDATE_GOLDEN:-}" = 1 ] && [ -z "${3:-}" ]; then cp "$WORK/$1.actual" "$g"; fi
  diff -u "$g" "$WORK/$1.actual" >"$WORK/$1.diff" 2>&1
}

run_client "$WORK/main"
[ "$CRC" = 0 ] || { echo "$COUT" | head -20; fail "client exit=$CRC"; }
golden edit-e2e "$COUT" || { head -50 "$WORK/edit-e2e.diff"; fail "edit trace differs from golden"; }
ok "edit sessions, ApplyEngineState, display attributes, caret, composition termination match the golden"

for m in skipend wrongguid; do
  run_client "$WORK/$m"
  [ "$CRC" = 0 ] || { echo "$COUT" | tail -8 | cut -c1-150; fail "$m mutant run crashed (exit=$CRC); a crash is not a golden mismatch"; }
  if golden edit-e2e "$COUT" nowrite; then fail "$m mutant was NOT caught by the golden"; fi
  ok "negative control: $m core differs from the golden ($(grep -c '^[-+][^-+]' "$WORK/edit-e2e.diff") changed lines)"
  [ -n "${EDIT_E2E_SHOW_DIFF:-}" ] && grep '^[-+][^-+]' "$WORK/edit-e2e.diff" | head -6
done
# ===== real msctf host: RequestEditSession + GetSelection (wine stubs ITfRange::SetText)
emacs_run -l edit-e2e-client.el --eval "(edit-wine-client-build \"$WORK/edit-wine.exe\")" \
  >"$WORK/wine-build.log" 2>&1 || { tail -5 "$WORK/wine-build.log" | cut -c1-300; fail "build wine client"; }
WOUT="$(cd "$WORK" && DDSKK_CORE_PATH="$(winepath -w "$WORK/main/ddskk-ime-core.dll")" \
        timeout 120 wine edit-wine.exe </dev/null 2>/dev/null)"; WRC=$?
[ "$WRC" = 0 ] || { echo "$WOUT" | tail -8 | cut -c1-150; fail "wine client exit=$WRC"; }
golden edit-wine "$WOUT" || { head -30 "$WORK/edit-wine.diff"; fail "real-msctf trace differs from golden"; }
ok "real msctf host: RequestEditSession(SYNC|READWRITE) reaches DoEditSession and ITfContext::GetSelection"
echo "PASS: edit-e2e"
exit 0
