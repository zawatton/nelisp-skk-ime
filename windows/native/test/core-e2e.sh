#!/usr/bin/env bash
# S3h end-to-end: the real native shim (ddskk-shim.el) loads the real native
# core (ddskk-core.el, built with the CoreProbe* test exports) through the
# DirectThreadMgr proxy path of shim-activate-e2e.sh and a key/compartment
# script runs through the TIP's ITfKeyEventSink.  Checks:
#   1. golden core-e2e.golden: Activate, compartment open/close (SetValue on the
#      real wine ITfCompartment + OnChange on the shim's sink -> NI_COMPARTMENT),
#      WouldClaimKey/OnTestKeyDown decisions, OnTestKeyUp/OnKeyUp/OnPreservedKey,
#      TranslateKey under the US layout, NI_ENGINE_ID.  How every expectation
#      follows from text_service.cpp is in golden/core-e2e.derivation.txt.
#   2. registry Engine=passthrough before Activate (settings loaded by Activate):
#      golden core-e2e-passthrough.golden.
#   3. negative controls: core mutants vk-table (Z -> Y in the VK ranges) and
#      open-inverted (OnTestKeyDown open check inverted) must differ from the
#      golden; a core reporting ABI version 999 is rejected by the shim
#      (Activate = E_NOINTERFACE); CORE_E2E_MUTANT=<name> makes the MAIN core the
#      mutant so the whole script must FAIL.
# Env: NELISP_ROOT, WINEPREFIX or NELISP_TSF_WINEPREFIX (default: temp dir),
#      NELISP_TSF_UPDATE_GOLDEN=1 rewrites the goldens (review the diff!).
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
WORK="$(mktemp -d "${TMPDIR:-/tmp}/core-e2e.XXXXXX")" || exit 1
PFX_TMP=""
if [ -n "${WINEPREFIX:-}" ]; then :
elif [ -n "${NELISP_TSF_WINEPREFIX:-}" ]; then WINEPREFIX="$NELISP_TSF_WINEPREFIX"
else PFX_TMP="$(mktemp -d "${TMPDIR:-/tmp}/core-e2e-wineprefix.XXXXXX")"; WINEPREFIX="$PFX_TMP"; fi
export WINEPREFIX WINEDEBUG=-all WINEARCH=win64
K_NATIVE='HKCU\Software\NativeIME'
wr() { timeout 120 wine reg "$@" </dev/null 2>/dev/null; }
cleanup() {
  wr delete "$K_NATIVE" /v Engine /f >/dev/null
  wr delete "$K_NATIVE" /v CoreDll /f >/dev/null
  if [ -n "$PFX_TMP" ]; then timeout 60 wineserver -k >/dev/null 2>&1; rm -rf "$PFX_TMP"; fi
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "ok: $*"; }
emacs_run() { (ulimit -v 8388608; timeout 600 emacs -Q --batch -L "$NELISP_ROOT/lisp" -L "$NATIVE" -L "$HERE" "$@"); }

build_shim() {
  mkdir -p "$1"
  ( export NELISP_COM_HIVE=hkcr
    emacs_run -l ddskk-shim.el --eval "(ddskk-shim-build-from-env \"$1/ddskk-ime.dll\")" ) \
    >"$1/build.log" 2>&1 || { tail -5 "$1/build.log" | cut -c1-300; fail "build shim in $1"; }
}
build_core() { # dir [env assignments...]
  local d="$1"; shift
  mkdir -p "$d"
  ( export NELISP_CORE_TEST_EXPORTS=1
    for a in "$@"; do export "$a"; done
    emacs_run -l ddskk-core.el --eval "(ddskk-core-build-from-env \"$d/ddskk-ime-core.dll\")" ) \
    >"$d/core-build.log" 2>&1 || { tail -5 "$d/core-build.log" | cut -c1-300; fail "build core in $d"; }
}
MAIN_ENV=()
case "${CORE_E2E_MUTANT:-}" in
  vk-table|open-inverted) MAIN_ENV=(NELISP_CORE_MUTANT="$CORE_E2E_MUTANT") ;;
  "") ;;
  *) fail "unknown CORE_E2E_MUTANT=$CORE_E2E_MUTANT" ;;
esac
for d in main vkmut openmut badabi; do build_shim "$WORK/$d"; done
build_core "$WORK/main" "${MAIN_ENV[@]}"
build_core "$WORK/vkmut" NELISP_CORE_MUTANT=vk-table
build_core "$WORK/openmut" NELISP_CORE_MUTANT=open-inverted
build_core "$WORK/badabi" NELISP_CORE_BAD_ABI=1
emacs_run -l core-e2e-client.el --eval "(core-e2e-client-build \"$WORK/core-e2e.exe\")" \
  >"$WORK/client-build.log" 2>&1 || { tail -5 "$WORK/client-build.log" | cut -c1-300; fail "build client"; }
ok "built shim, core (main, vk-table mutant, open-inverted mutant, bad-ABI) and client"

wr query 'HKCU\Software' >/dev/null
wr delete "$K_NATIVE" /v Engine /f >/dev/null
wr delete "$K_NATIVE" /v CoreDll /f >/dev/null

run_client() { # dir [short]
  local d="$1"
  COUT="$(cd "$WORK" && DDSKK_HARNESS_DLL_PATH="$(winepath -w "$d/ddskk-ime.dll")" \
          DDSKK_CORE_PATH="$(winepath -w "$d/ddskk-ime-core.dll")" \
          DDSKK_CE_SHORT="${2:-0}" \
          timeout 120 wine core-e2e.exe </dev/null 2>/dev/null)"; CRC=$?
}
golden() { # name actual [nowrite]
  local g="$HERE/golden/$1.golden"
  printf '%s\n' "$2" >"$WORK/$1.actual"
  if [ "${NELISP_TSF_UPDATE_GOLDEN:-}" = 1 ] && [ -z "${3:-}" ]; then cp "$WORK/$1.actual" "$g"; fi
  diff -u "$g" "$WORK/$1.actual" >"$WORK/$1.diff" 2>&1
}

# ===== 1. full script
run_client "$WORK/main"
[ "$CRC" = 0 ] || { echo "$COUT" | head -20; fail "client exit=$CRC"; }
golden core-e2e "$COUT" || { head -40 "$WORK/core-e2e.diff"; fail "core trace differs from golden"; }
ok "native shim + native core: Activate, compartment open/close, claim decisions, key up/down, TranslateKey, engine id match the golden"

# ===== 2. settings loaded at Activate (registry Engine=passthrough)
wr add "$K_NATIVE" /v Engine /t REG_SZ /d passthrough /f >/dev/null
run_client "$WORK/main" 1
wr delete "$K_NATIVE" /v Engine /f >/dev/null
[ "$CRC" = 0 ] || { echo "$COUT" | head -20; fail "short client exit=$CRC"; }
golden core-e2e-passthrough "$COUT" || { head -30 "$WORK/core-e2e-passthrough.diff"; fail "passthrough trace differs from golden"; }
ok "registry Engine=passthrough: Activate loads it, no key is claimed"

# ===== 3. negative controls
for m in vkmut openmut; do
  run_client "$WORK/$m"
  if [ "$CRC" = 0 ] && golden core-e2e "$COUT" nowrite; then fail "$m was NOT caught by the golden"; fi
  ok "negative control: $m core differs from the golden"
done
run_client "$WORK/badabi"
echo "$COUT" | grep -q '^HR Activate=80004002$' || { echo "$COUT" | head -5; fail "bad-ABI core: Activate is not E_NOINTERFACE"; }
ok "negative control: ABI version 999 core rejected by the shim (E_NOINTERFACE)"
echo "PASS: core-e2e"
exit 0
