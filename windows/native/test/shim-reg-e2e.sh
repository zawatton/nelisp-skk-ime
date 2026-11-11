#!/usr/bin/env bash
# S3c end-to-end: build ddskk-shim (windows/native/ddskk-shim.el), register it
# with regsvr32 under wine and verify COM class, NativeIME values, TSF profile
# and categories; unregister and verify everything is gone; negative controls
# (client after /u, one category dropped, wrong profile langid); the default
# HKCU build; and the S3b hosts against the new DLL.
#
# Wine facts handled here: CoCreateInstance reads only HKCR/HKLM, so the main
# runs use NELISP_COM_HIVE=hkcr; wine's ITfInputProcessorProfiles::
# GetLanguageProfileDescription and ITfCategoryMgr::EnumCategoriesInItem return
# E_NOTIMPL, so description and categories are verified in the registry here
# (the client checks them through the API when the API exists, e.g. on Windows).
#
# Env: NELISP_ROOT (NeLisp checkout; default ../nelisp next to the repo),
#      WINEPREFIX or NELISP_TSF_WINEPREFIX (default: temp dir),
#      SHIM_E2E_MUTANT=dropcat|langid   the MAIN build is the mutant, so the run
#                                       must FAIL (negative control of the script),
#      SHIM_E2E_SKIP_S3B=1              skip the S3b host regression runs.
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
WORK="$(mktemp -d "${TMPDIR:-/tmp}/shim-reg-e2e.XXXXXX")" || exit 1
PFX_TMP=""
if [ -n "${WINEPREFIX:-}" ]; then :
elif [ -n "${NELISP_TSF_WINEPREFIX:-}" ]; then WINEPREFIX="$NELISP_TSF_WINEPREFIX"
else PFX_TMP="$(mktemp -d "${TMPDIR:-/tmp}/shim-reg-wineprefix.XXXXXX")"; WINEPREFIX="$PFX_TMP"; fi
export WINEPREFIX WINEDEBUG=-all WINEARCH=win64

CLSID='{80b44b14-b866-4ef4-a394-4ff1d87d5185}'
CLSIDU='{80B44B14-B866-4EF4-A394-4FF1D87D5185}'
PROFILE='{EE0012D5-8306-4388-B071-5C3C3E38F7CE}'
CATS='{34745C63-B2F0-4784-8B67-5E12C8701A31} {046B8C80-1647-40F7-9B21-B93B81AABC1B} {49D2F9CF-1F5E-11D7-A6D3-00065B84435C} {CCF05DD7-4A87-11D7-A6E2-00065B84435C} {25504FB4-7BAB-4BC1-9C69-CF81890F0EF5} {13A016DF-560B-46CD-947A-4C3AF1E0E35D}'
K_HKLM_CLASS="HKLM\\Software\\Classes\\CLSID\\$CLSID"
K_HKCU_CLASS="HKCU\\Software\\Classes\\CLSID\\$CLSID"
K_TIP_U="HKCU\\Software\\Microsoft\\CTF\\TIP\\$CLSIDU"
K_TIP_M="HKLM\\Software\\Microsoft\\CTF\\TIP\\$CLSIDU"
K_NATIVE='HKCU\Software\NativeIME'

wr() { timeout 120 wine reg "$@" </dev/null 2>/dev/null; }
has() { wr query "$1" >/dev/null; }
# rv KEY NAME -> value text (empty for an empty REG_SZ, nothing if missing)
rv() {
  local sel=(/v "$2"); [ "$2" = '(Default)' ] && sel=(/ve)
  wr query "$1" "${sel[@]}" | tr -d '\r' | sed -n "s/^ *$2 *REG_[A-Z_]* *//p"
}
wclean() { # remove every key this test can leave behind
  local k
  for k in "$K_HKLM_CLASS" "$K_HKCU_CLASS" "$K_TIP_U" "$K_TIP_M" "$K_NATIVE"; do
    wr delete "$k" /f >/dev/null
  done
}
cleanup() {
  wclean
  if [ -n "$PFX_TMP" ]; then timeout 60 wineserver -k >/dev/null 2>&1; rm -rf "$PFX_TMP"; fi
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "ok: $*"; }
emacs_run() { (ulimit -v 8388608; timeout 300 emacs -Q --batch -L "$NELISP_ROOT/lisp" -L "$NATIVE" -L "$HERE" "$@") ; }

# ---- builds
build_shim() { # dir hive-or-empty [env assignments...]
  local d="$1" hive="$2"; shift 2
  mkdir -p "$d"
  ( if [ -n "$hive" ]; then export NELISP_COM_HIVE="$hive"; else unset NELISP_COM_HIVE; fi
    for a in "$@"; do export "$a"; done
    emacs_run -l ddskk-shim.el --eval "(ddskk-shim-build-from-env \"$d/ddskk-ime.dll\")" ) \
    >"$d/build.log" 2>&1 || { tail -5 "$d/build.log" | cut -c1-300; fail "build shim in $d"; }
}
MAIN_ENV=()
case "${SHIM_E2E_MUTANT:-}" in
  dropcat) MAIN_ENV=(NELISP_SHIM_DROP_CATEGORY=1) ;;
  langid) MAIN_ENV=(NELISP_SHIM_BAD_LANGID=1) ;;
  "") ;;
  *) fail "unknown SHIM_E2E_MUTANT=$SHIM_E2E_MUTANT" ;;
esac
MAIN="$WORK/a/b/main"
build_shim "$MAIN" hkcr "${MAIN_ENV[@]}"
build_shim "$WORK/a/b/dropcat" hkcr NELISP_SHIM_DROP_CATEGORY=1
build_shim "$WORK/a/b/badlang" hkcr NELISP_SHIM_BAD_LANGID=1
build_shim "$WORK/a/b/hkcu" ""
emacs_run -l shim-reg-client.el --eval \
  "(progn (shim-reg-client-build \"$WORK/present.exe\" 'present) (shim-reg-client-build \"$WORK/absent.exe\" 'absent))" \
  >"$WORK/client-build.log" 2>&1 || { tail -5 "$WORK/client-build.log" | cut -c1-300; fail "build client"; }
ok "built shim (main/dropcat/badlang/hkcu) and checker clients"

wine_run() { (cd "$WORK" && timeout 120 wine "$@" </dev/null 2>/dev/null); }
regsvr() { (cd "$1" && shift && timeout 120 wine regsvr32 "$@" </dev/null >/dev/null 2>&1); }
client() { # present|absent -> sets CRC and COUT
  COUT="$(wine_run "$WORK/$1.exe")"; CRC=$?
}

wclean
# Prefix warm-up (first wine start creates the prefix).
wr query 'HKCU\Software' >/dev/null

# ================= 1. main registration (HKCR switch build)
regsvr "$MAIN" /s ddskk-ime.dll; rc=$?
[ "$rc" = 0 ] || fail "regsvr32 /s exit=$rc"
WDLL="$(winepath -w "$MAIN/ddskk-ime.dll")"
got="$(rv "$K_HKLM_CLASS\\InprocServer32" '(Default)')"
[ "$got" = "$WDLL" ] || fail "InprocServer32 default is '$got', expected '$WDLL'"
[ "$(rv "$K_HKLM_CLASS\\InprocServer32" ThreadingModel)" = Apartment ] || fail "ThreadingModel != Apartment"
[ "$(rv "$K_HKLM_CLASS" '(Default)')" = "NeLisp IME" ] || fail "class description"
has "$K_HKCU_CLASS" && fail "HKCR build wrote HKCU\\Software\\Classes"
ok "COM class: InprocServer32=$WDLL ThreadingModel=Apartment"

DLL_UNIX="$MAIN/ddskk-ime.dll"
EXP_HOST="$(winepath -w "$MAIN/ddskk-engine-host.exe")"
REPO_UNIX="$(dirname "$(dirname "$(dirname "$(dirname "$DLL_UNIX")")")")"
EXP_REPO="$(winepath -w "$REPO_UNIX")"
EXP_NELISP="$(winepath -w "$(dirname "$REPO_UNIX")/nelisp/target/nelisp.exe")"
[ "$(rv "$K_NATIVE" EngineHost)" = "$EXP_HOST" ] || fail "EngineHost '$(rv "$K_NATIVE" EngineHost)' != '$EXP_HOST'"
[ "$(rv "$K_NATIVE" EngineExecutable)" = "$EXP_NELISP" ] || fail "EngineExecutable '$(rv "$K_NATIVE" EngineExecutable)' != '$EXP_NELISP'"
[ "$(rv "$K_NATIVE" Repository)" = "$EXP_REPO" ] || fail "Repository '$(rv "$K_NATIVE" Repository)' != '$EXP_REPO'"
[ "$(rv "$K_NATIVE" InitialKanaMode)" = "0x1" ] || fail "InitialKanaMode != 0x1"
ok "NativeIME: EngineHost, EngineExecutable(nelisp.exe), Repository, InitialKanaMode=1"

has "$K_TIP_U\\LanguageProfile\\0x00000411\\$PROFILE" || fail "HKCU CTF profile key missing"
[ "$(rv "$K_TIP_M\\LanguageProfile\\0x00000411\\$PROFILE" Description)" = "NeLisp IME" ] || fail "profile Description in registry"
for c in $CATS; do
  has "$K_TIP_M\\Category\\Category\\$c\\$CLSIDU" || fail "category $c not registered (registry)"
done
ok "TSF registry: profile 0x0411 Description=NeLisp IME, 6 categories"

client present
echo "$COUT" | sed 's/^/   client: /'
[ "$CRC" = 0 ] || fail "present client exit=$CRC (see check codes in shim-reg-client.el)"
ok "client (real msctf): EnumLanguageProfiles lists CLSID/0x0411/profile; CoCreateInstance + Activate/Deactivate + Ex alias via registered class"

# ---- S3b hosts load the new DLL (Activate must be S_OK; the placeholder TIP has
# no ITfKeyEventSink yet, so the host stops with 'FAIL no ITfKeyEventSink' rc 4).
emacs_run -l host-wine.el --eval "(host-wine-build \"$WORK/host-wine.exe\")" \
  >"$WORK/hostbuild.log" 2>&1 || { tail -5 "$WORK/hostbuild.log" | cut -c1-300; fail "build host-wine"; }
HOUT="$(cd "$WORK" && DDSKK_HARNESS_DLL_PATH="$WDLL" timeout 120 wine host-wine.exe a </dev/null 2>/dev/null)"; hrc=$?
echo "$HOUT" | grep -q '^TIP_DIRECT loaded' || fail "host-wine did not load the shim: $HOUT"
echo "$HOUT" | grep -q '^HR Activate=00000000' || fail "Activate != S_OK: $HOUT"
[ "$hrc" = 4 ] || fail "host-wine exit=$hrc (expected 4: no ITfKeyEventSink yet)"
ok "host-wine loads the shim DLL via DDSKK_HARNESS_DLL_PATH; Activate=S_OK (key sink arrives with S3d)"

# ================= 2. unregister
regsvr "$MAIN" /u /s ddskk-ime.dll; rc=$?
[ "$rc" = 0 ] || fail "regsvr32 /u exit=$rc"
has "$K_HKLM_CLASS" && fail "class key still present after /u"
has "$K_TIP_U" && fail "HKCU CTF TIP key still present after /u"
has "$K_TIP_M" && fail "HKLM CTF TIP key (profile/categories) still present after /u"
has "$K_NATIVE" || fail "NativeIME settings must survive /u (dllmain.cpp parity)"
ok "regsvr32 /u removed class, profile and categories (NativeIME kept, as dllmain.cpp)"
client absent
echo "$COUT" | sed 's/^/   client: /'
[ "$CRC" = 0 ] || fail "absent client exit=$CRC (expected 0: REGDB_E_CLASSNOTREG, no profile, no category)"
echo "$COUT" | grep -q '^T09 80040154$' || fail "CoCreateInstance after /u did not return REGDB_E_CLASSNOTREG"
ok "after /u: CoCreateInstance=REGDB_E_CLASSNOTREG, profile not listed"
# Negative control: the 'present' checker must FAIL on the unregistered state.
client present
[ "$CRC" = 20 ] || [ "$CRC" = 11 ] || fail "negative control: present client after /u exit=$CRC (expected 20 or 11)"
ok "negative control: present client after /u fails with $CRC"
# ...and the 'absent' checker must FAIL on a registered state.
regsvr "$MAIN" /s ddskk-ime.dll || fail "re-register"
client absent
[ "$CRC" = 60 ] || fail "negative control: absent client while registered exit=$CRC (expected 60)"
ok "negative control: absent client while registered fails with 60"
regsvr "$MAIN" /u /s ddskk-ime.dll || fail "unregister after control"

# ================= 3. mutant builds must be caught by the present checker
regsvr "$WORK/a/b/dropcat" /s ddskk-ime.dll || fail "dropcat regsvr32"
has "$K_TIP_M\\Category\\Category\\{13A016DF-560B-46CD-947A-4C3AF1E0E35D}\\$CLSIDU" \
  && fail "dropcat build still registered the dropped category"
for c in $CATS; do
  [ "$c" = '{13A016DF-560B-46CD-947A-4C3AF1E0E35D}' ] && continue
  has "$K_TIP_M\\Category\\Category\\$c\\$CLSIDU" || fail "dropcat build lost category $c"
done
ok "negative control: dropcat registry has exactly 5 of 6 categories"
regsvr "$WORK/a/b/dropcat" /u /s ddskk-ime.dll
has "$K_TIP_M" && fail "dropcat /u left CTF keys"

regsvr "$WORK/a/b/badlang" /s ddskk-ime.dll || fail "badlang regsvr32"
client present
echo "$COUT" | tail -2 | sed 's/^/   client: /'
{ [ "$CRC" = 20 ] || [ "$CRC" = 21 ]; } || fail "negative control: wrong-langid build exit=$CRC (expected 20/21)"
ok "negative control: wrong-langid build rejected by the present client ($CRC)"
regsvr "$WORK/a/b/badlang" /u /s ddskk-ime.dll
has "$K_TIP_U" && fail "badlang /u left CTF keys"
has "$K_HKLM_CLASS" && fail "badlang /u left class key"

# ================= 4. default (HKCU) build: parity registration path
touch "$WORK/a/b/hkcu/nelisp-ddskk.exe"
regsvr "$WORK/a/b/hkcu" /s ddskk-ime.dll; rc=$?
[ "$rc" = 0 ] || fail "hkcu regsvr32 exit=$rc"
HDLL="$(winepath -w "$WORK/a/b/hkcu/ddskk-ime.dll")"
[ "$(rv "$K_HKCU_CLASS\\InprocServer32" '(Default)')" = "$HDLL" ] || fail "HKCU InprocServer32 default"
[ "$(rv "$K_HKCU_CLASS\\InprocServer32" ThreadingModel)" = Apartment ] || fail "HKCU ThreadingModel"
has "$K_HKLM_CLASS" && fail "HKCU build wrote HKLM class key"
[ "$(rv "$K_NATIVE" EngineExecutable)" = "$(winepath -w "$WORK/a/b/hkcu/nelisp-ddskk.exe")" ] \
  || fail "standalone branch: EngineExecutable '$(rv "$K_NATIVE" EngineExecutable)'"
[ -z "$(rv "$K_NATIVE" Repository)" ] || fail "standalone branch: Repository must be empty"
has "$K_NATIVE" || fail "NativeIME missing"
has "$K_TIP_U\\LanguageProfile\\0x00000411\\$PROFILE" || fail "HKCU build: profile missing"
ok "default build: HKCU\\Software\\Classes\\CLSID\\{...}\\InprocServer32=$HDLL, standalone EngineExecutable, empty Repository"
regsvr "$WORK/a/b/hkcu" /u /s ddskk-ime.dll; rc=$?
[ "$rc" = 0 ] || fail "hkcu regsvr32 /u exit=$rc"
has "$K_HKCU_CLASS" && fail "HKCU class key present after /u"
has "$K_TIP_U" && fail "HKCU build /u left CTF keys"
ok "default build: /u removed the HKCU class key and TSF registration"

# ================= 5. S3b hosts unchanged
if [ "${SHIM_E2E_SKIP_S3B:-}" != 1 ]; then
  for t in host-wine-e2e.sh host-mock-e2e.sh; do
    out="$(WINEPREFIX="$WINEPREFIX" bash "$HERE/$t" 2>&1)"; rc=$?
    [ "$rc" = 0 ] || { echo "$out" | tail -8; fail "$t exit=$rc"; }
    ok "$t: $(echo "$out" | tail -1)"
  done
fi
echo "PASS: shim-reg-e2e"
exit 0
