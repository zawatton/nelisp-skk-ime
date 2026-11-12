#!/usr/bin/env bash
# S3d end-to-end: build the shim (with the test export DdskkShimStat), the stub
# core and the Activate clients, then under wine:
#   1. proxy activation (DirectThreadMgr proxy, shim loaded like tsf_host.cpp):
#      stub core activate/destroy counters, AdviseKeyEventSink recorded by the
#      proxy, direct OnSetFocus/OnTestKeyDown/OnKeyDown/OnTestKeyUp/OnKeyUp/
#      OnPreservedKey calls with eaten values and the key_pair state, message
#      window + 50 ms timer created and destroyed, compared with a golden;
#   2. activation through the real msctf (ActivateLanguageProfile, registered
#      class, LANG=ja_JP.UTF-8 so GetUserDefaultLangID is 0x0411): wine's
#      AdviseKeyEventSink rejects the shim's client id (E_INVALIDARG), so the
#      shim must roll back (golden: core activate==1, destroy==1, no window);
#   3. negative controls: bad-ABI core (E_NOINTERFACE), missing core file
#      (HRESULT_FROM_WIN32(126)), relative CoreDll (E_INVALIDARG), a mutant
#      shim that forwards OnKeyDown with the wrong operation (golden diff must
#      fail).
# Env: NELISP_ROOT, WINEPREFIX or NELISP_TSF_WINEPREFIX (default: temp dir),
#      SHIM_ACTIVATE_MUTANT=wrong-slot   the MAIN shim is the mutant, so the run
#                                        must FAIL (negative control of the script),
#      NELISP_TSF_UPDATE_GOLDEN=1        rewrite the goldens from this run.
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
WORK="$(mktemp -d "${TMPDIR:-/tmp}/shim-activate-e2e.XXXXXX")" || exit 1
PFX_TMP=""
if [ -n "${WINEPREFIX:-}" ]; then :
elif [ -n "${NELISP_TSF_WINEPREFIX:-}" ]; then WINEPREFIX="$NELISP_TSF_WINEPREFIX"
else PFX_TMP="$(mktemp -d "${TMPDIR:-/tmp}/shim-activate-wineprefix.XXXXXX")"; WINEPREFIX="$PFX_TMP"; fi
export WINEPREFIX WINEDEBUG=-all WINEARCH=win64
K_NATIVE='HKCU\Software\NativeIME'
wr() { timeout 120 wine reg "$@" </dev/null 2>/dev/null; }
regsvr() { (cd "$1" && shift && timeout 120 wine regsvr32 "$@" </dev/null >/dev/null 2>&1); }
cleanup() {
  [ -f "$WORK/main/ddskk-ime.dll" ] && regsvr "$WORK/main" /u /s ddskk-ime.dll
  wr delete "$K_NATIVE" /v CoreDll /f >/dev/null
  if [ -n "$PFX_TMP" ]; then timeout 60 wineserver -k >/dev/null 2>&1; rm -rf "$PFX_TMP"; fi
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "ok: $*"; }
emacs_run() { (ulimit -v 8388608; timeout 300 emacs -Q --batch -L "$NELISP_ROOT/lisp" -L "$NATIVE" -L "$HERE" "$@"); }

build_shim() { # dir [env assignments...]
  local d="$1"; shift
  mkdir -p "$d"
  ( export NELISP_COM_HIVE=hkcr NELISP_SHIM_TEST_EXPORTS=1
    for a in "$@"; do export "$a"; done
    emacs_run -l ddskk-shim.el --eval "(ddskk-shim-build-from-env \"$d/ddskk-ime.dll\")" ) \
    >"$d/build.log" 2>&1 || { tail -5 "$d/build.log" | cut -c1-300; fail "build shim in $d"; }
}
MAIN_ENV=()
case "${SHIM_ACTIVATE_MUTANT:-}" in
  wrong-slot) MAIN_ENV=(NELISP_SHIM_WRONG_SLOT=1) ;;
  "") ;;
  *) fail "unknown SHIM_ACTIVATE_MUTANT=$SHIM_ACTIVATE_MUTANT" ;;
esac
build_shim "$WORK/main" "${MAIN_ENV[@]}"
build_shim "$WORK/mutant" NELISP_SHIM_WRONG_SLOT=1
emacs_run -l stub-core.el -l shim-activate-client.el --eval "(progn
  (stub-core-build \"$WORK/main/ddskk-ime-core.dll\")
  (stub-core-build \"$WORK/main/bad-core.dll\" t)
  (stub-core-build \"$WORK/mutant/ddskk-ime-core.dll\")
  (shim-activate-client-build \"$WORK/proxy.exe\" 'proxy)
  (shim-activate-client-build \"$WORK/real.exe\" 'real))" >"$WORK/build.log" 2>&1 \
  || { tail -5 "$WORK/build.log" | cut -c1-300; fail "build stub core / clients"; }
ok "built shim (main, wrong-slot mutant), stub core (good, bad-ABI), proxy and real clients"

wr query 'HKCU\Software' >/dev/null   # prefix warm-up
wr delete "$K_NATIVE" /v CoreDll /f >/dev/null

run_proxy() { # shim-dir [core-dir] -> POUT, PRC
  local sd="$1" cd="${2:-$1}"
  POUT="$(cd "$WORK" && DDSKK_HARNESS_DLL_PATH="$(winepath -w "$sd/ddskk-ime.dll")" \
          DDSKK_STUB_CORE_PATH="$(winepath -w "$cd/ddskk-ime-core.dll")" \
          timeout 120 wine proxy.exe </dev/null 2>/dev/null)"; PRC=$?
}
golden() { # name actual-text -> diff against golden/<name>.golden
  local g="$HERE/golden/$1.golden"
  printf '%s\n' "$2" >"$WORK/$1.actual"
  if [ "${NELISP_TSF_UPDATE_GOLDEN:-}" = 1 ] && [ -z "${3:-}" ]; then cp "$WORK/$1.actual" "$g"; fi
  diff -u "$g" "$WORK/$1.actual" >"$WORK/$1.diff" 2>&1
}

# ================= 1. proxy activation (sibling core, no CoreDll value)
run_proxy "$WORK/main"
[ "$PRC" = 0 ] || { echo "$POUT" | head -20; fail "proxy client exit=$PRC"; }
golden shim-activate-proxy "$POUT" || { head -30 "$WORK/shim-activate-proxy.diff"; fail "proxy trace differs from golden"; }
ok "proxy activation matches golden (stub core activate/destroy, sink advise, key forwarding, window+timer, Deactivate)"

# ================= 2. real msctf activation (documents wine's refusal)
regsvr "$WORK/main" /s ddskk-ime.dll || fail "regsvr32 /s"
ROUT="$(cd "$WORK" && LANG=ja_JP.UTF-8 LC_ALL=ja_JP.UTF-8 \
        DDSKK_HARNESS_DLL_PATH="$(winepath -w "$WORK/main/ddskk-ime.dll")" \
        DDSKK_STUB_CORE_PATH="$(winepath -w "$WORK/main/ddskk-ime-core.dll")" \
        timeout 120 wine real.exe </dev/null 2>/dev/null)"; RRC=$?
[ "$RRC" = 0 ] || { echo "$ROUT" | head; fail "real client exit=$RRC"; }
golden shim-activate-real "$ROUT" || { head -30 "$WORK/shim-activate-real.diff"; fail "real-msctf trace differs from golden"; }
ok "real msctf: ActivateLanguageProfile reaches core activate==1; wine's AdviseKeyEventSink=E_INVALIDARG makes the shim roll back (destroy==1, no window)"

# ================= 3. negative controls
wr add "$K_NATIVE" /v CoreDll /t REG_SZ /d "$(winepath -w "$WORK/main/bad-core.dll")" /f >/dev/null
run_proxy "$WORK/main"
echo "$POUT" | grep -q '^HR Activate=80004002$' || { echo "$POUT" | head -5; fail "bad-ABI core: Activate is not E_NOINTERFACE"; }
echo "$POUT" | grep -q '^CORE ' && fail "bad-ABI core: the core must never be created"
ok "negative control: bad-ABI core (version 999) rejected, Activate=E_NOINTERFACE, no window"
wr add "$K_NATIVE" /v CoreDll /t REG_SZ /d 'Z:\nonexistent\ddskk-ime-core.dll' /f >/dev/null
run_proxy "$WORK/main"
echo "$POUT" | grep -q '^HR Activate=8007007e$' || { echo "$POUT" | head -5; fail "missing core: Activate is not HRESULT_FROM_WIN32(126)"; }
ok "negative control: missing core file -> Activate=HRESULT_FROM_WIN32(126)"
wr add "$K_NATIVE" /v CoreDll /t REG_SZ /d 'ddskk-ime-core.dll' /f >/dev/null
run_proxy "$WORK/main"
echo "$POUT" | grep -q '^HR Activate=80070057$' || { echo "$POUT" | head -5; fail "relative CoreDll: Activate is not E_INVALIDARG"; }
ok "negative control: relative CoreDll path -> Activate=E_INVALIDARG"
# CoreDll pointing at the good core must still work (registry route, not the sibling).
wr add "$K_NATIVE" /v CoreDll /t REG_SZ /d "$(winepath -w "$WORK/main/ddskk-ime-core.dll")" /f >/dev/null
run_proxy "$WORK/main"
golden shim-activate-proxy "$POUT" || { head -30 "$WORK/shim-activate-proxy.diff"; fail "registry CoreDll route differs from golden"; }
ok "CoreDll registry value (absolute path) selects the core; trace matches golden"
wr delete "$K_NATIVE" /v CoreDll /f >/dev/null

# ================= 4. mock TSF host with the shim (trace of Activate/Deactivate)
emacs_run -l host-mock.el --eval "(tsf-build-exe \"$WORK/host-mock.exe\" (host-mock-forms))" \
  >"$WORK/mockbuild.log" 2>&1 || { tail -5 "$WORK/mockbuild.log" | cut -c1-300; fail "build host-mock"; }
MOUT="$(cd "$WORK" && DDSKK_HARNESS_DLL_PATH="$(winepath -w "$WORK/main/ddskk-ime.dll")" \
        timeout 120 wine host-mock.exe a b 1 </dev/null 2>/dev/null)"; MRC=$?
[ "$MRC" = 0 ] || { echo "$MOUT" | head; fail "host-mock exit=$MRC"; }
golden shim-activate-mock "$MOUT" || { head -30 "$WORK/shim-activate-mock.diff"; fail "host-mock trace with the shim differs from golden"; }
ok "host-mock + shim + stub core: AdviseKeyEventSink, key forwarding, Deactivate trace matches golden"

run_proxy "$WORK/mutant"
if [ "$PRC" = 0 ] && golden shim-activate-proxy "$POUT" nowrite; then fail "wrong-slot mutant was NOT caught by the golden"; fi
ok "negative control: wrong-slot mutant (OnKeyDown forwards OnTestKeyDown) differs from the golden"
echo "PASS: shim-activate-e2e"
exit 0
