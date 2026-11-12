#!/usr/bin/env bash
# S3e end-to-end: settings parsing, fingerprint, registry watcher, published
# state and the publication locks, under wine.  A nelisp-built EXE
# (settings-client.el) writes registry values with RegSetValueExW into a
# private key (NATIVEIME_REGISTRY_KEY, never the live HKCU\Software\NativeIME),
# calls the exports of settings-probe.dll (ddskk-core-settings.el) and prints
# facts that this script checks.  Negative controls: lock-less probe build
# (per-service publication lock), lock-less shim build (cb_publock), the golden
# diff against a mutated settings run (NELISP_IME_ENGINE), and an oracle check.
# Env: NELISP_ROOT, WINEPREFIX or NELISP_TSF_WINEPREFIX (default: temp dir),
#      NELISP_TSF_UPDATE_GOLDEN=1 rewrites test/golden/settings.txt.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
if [ -z "${NELISP_ROOT:-}" ]; then
  [ -d "$REPO/../nelisp/lisp" ] && NELISP_ROOT="$(cd "$REPO/../nelisp" && pwd)"
fi
if [ -z "${NELISP_ROOT:-}" ] || [ ! -f "$NELISP_ROOT/lisp/nelisp-com-dsl.el" ]; then
  echo "FAIL: NeLisp not found; set NELISP_ROOT"; exit 1
fi
export NELISP_ROOT
WORK="$(mktemp -d "${TMPDIR:-/tmp}/settings-e2e.XXXXXX")" || exit 1
PFX_TMP=""
if [ -n "${WINEPREFIX:-}" ]; then :
elif [ -n "${NELISP_TSF_WINEPREFIX:-}" ]; then WINEPREFIX="$NELISP_TSF_WINEPREFIX"
else PFX_TMP="$(mktemp -d "${TMPDIR:-/tmp}/settings-wineprefix.XXXXXX")"; WINEPREFIX="$PFX_TMP"; fi
export WINEPREFIX WINEDEBUG=-all WINEARCH=win64
export NATIVEIME_REGISTRY_KEY='Software\NativeIMETestS3e'
cleanup() {
  timeout 60 wine reg delete "HKCU\\$NATIVEIME_REGISTRY_KEY" /f </dev/null >/dev/null 2>&1
  if [ -n "$PFX_TMP" ]; then timeout 60 wineserver -k >/dev/null 2>&1; rm -rf "$PFX_TMP"; fi
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "ok: $*"; }
emacs_run() { (ulimit -v 8388608; timeout 600 emacs -Q --batch -L "$NELISP_ROOT/lisp" -L "$NATIVE" -L "$HERE" "$@"); }
B() { emacs_run -l "$1" --eval "$2" >"$WORK/build.log" 2>&1 || { tail -5 "$WORK/build.log" | cut -c1-300; fail "build $3"; }; }

B settings-client.el "(progn (settings-probe-build \"$WORK/probe.dll\") (settings-probe-build \"$WORK/probe-nolock.dll\" t) (settings-client-build \"$WORK/Settings-Client.EXE\"))" probe
( export NELISP_SHIM_TEST_EXPORTS=1 NELISP_COM_HIVE=hkcr
  emacs_run -l ddskk-shim.el --eval "(ddskk-shim-build-from-env \"$WORK/shim.dll\")" >"$WORK/b2.log" 2>&1 \
  && NELISP_SHIM_NOLOCK=1 emacs_run -l ddskk-shim.el --eval "(ddskk-shim-build-from-env \"$WORK/shim-nolock.dll\")" >"$WORK/b3.log" 2>&1 ) \
  || fail "build shim"
ok "built probe DLL (+lock-less mutant), client EXE, shim (+lock-less mutant)"
timeout 120 wine reg query 'HKCU\Software' </dev/null >/dev/null 2>&1   # prefix warm-up

run() { # mode dll [env...] -> stdout
  local mode="$1" dll="$2"; shift 2
  (cd "$WORK" && env "$@" SETTINGS_MODE="$mode" SETTINGS_PROBE_DLL="$(winepath -w "$dll")" \
     timeout 120 wine Settings-Client.EXE </dev/null 2>/dev/null | tr -d '\r')
}
getv() { # text key line-prefix -> value after key=
  echo "$1" | grep "^$2" | head -1 | sed -n "s/.*$3=\([^ ]*\).*/\1/p"
}

# ---- 1. settings parsing vs golden (+ env override and negative controls)
S="$(run s "$WORK/probe.dll" X=1)"
GOLD="$HERE/golden/settings.txt"
if [ "${NELISP_TSF_UPDATE_GOLDEN:-}" = 1 ]; then echo "$S" >"$GOLD"; fi
[ "$(echo "$S" | wc -l)" = 15 ] || fail "settings run produced $(echo "$S" | wc -l) lines: $S"
echo "$S" | diff - "$GOLD" >"$WORK/d.txt" || { head -5 "$WORK/d.txt"; fail "settings output differs from golden"; }
ok "settings: 15 scenarios (defaults, all values, clamps, per-engine kana, colour edge cases, Apps overrides) match the golden"
S2="$(run s "$WORK/probe.dll" NELISP_IME_ENGINE=passthrough)"
echo "$S2" | diff - "$GOLD" >/dev/null && fail "negative control: NELISP_IME_ENGINE=passthrough did not change the output"
echo "$S2" | grep -q '^S0 absent engine=passthrough ddskk=0 kana=0 ' || fail "NELISP_IME_ENGINE override not applied: $(echo "$S2" | head -1)"
ok "NELISP_IME_ENGINE=passthrough overrides the engine (golden diff fails as it must)"
S3="$(run s "$WORK/probe.dll" NELISP_IME_ENGINE=0123456789012345678901234567890123456789)"
echo "$S3" | diff - "$GOLD" >/dev/null || fail "over-long NELISP_IME_ENGINE must be ignored"
ok "over-long NELISP_IME_ENGINE (>=32 chars) is ignored, as C++"

# ---- 2. fingerprint oracle (independent bignum implementation of the C++ mix)
F="$(run f "$WORK/probe.dll" X=1)"
ORA="$(emacs -Q --batch --eval '(require (quote cl-lib))' --eval '
(let* ((mask (1- (ash 1 64))) (prime 1099511628211) (basis 14695981039346656037))
  (cl-flet* ((mix (h bytes) (dolist (b bytes) (setq h (logand mask (* (logxor h b) prime)))) h)
             (w (s) (apply (quote append) (mapcar (lambda (c) (list c 0)) (string-to-list s))))
             (d (n) (list (logand n 255) 0 0 0)))
    (let* ((child (mix (mix (mix basis (w "B")) (d 1)) (append (w "hi") (list 0 0))))
           (h (mix (mix (mix basis (w "A")) (d 4)) (d 5)))
           (h (mix h (w "S")))
           (h (mix h (let (r) (dotimes (i 8) (push (logand 255 (ash child (* -8 i))) r)) (nreverse r)))))
      (princ (format "%016x %016x" basis h)))))' 2>/dev/null)"
[ "$(getv "$F" 'FP empty' 'FP empty')" = "" ] || true
EMPTY="$(echo "$F" | sed -n 's/^FP empty=//p')"; ONE="$(echo "$F" | sed -n 's/^FP one=//p')"
[ "$EMPTY $ONE" = "$ORA" ] || fail "fingerprint differs from the oracle: got '$EMPTY $ONE', expected '$ORA'"
[ "$(echo "$F" | sed -n 's/^FP clients=//p')" = "$ONE" ] || fail "Clients subtree changed the fingerprint"
[ "$(echo "$F" | sed -n 's/^FP core_excl=//p')" = "$ONE" ] || fail "CoreDll changed the core-excluding fingerprint"
[ "$(echo "$F" | sed -n 's/^FP core_incl=//p')" != "$ONE" ] || fail "CoreDll did not change the core-including fingerprint"
ok "fingerprint equals the independent FNV oracle (empty, value+subkey); Clients ignored; CoreDll ignored only when excluded"

# ---- 3. watcher
W="$(run w "$WORK/probe.dll" X=1)"; echo "$W" | sed 's/^/   /'
chk() { echo "$W" | grep -qx "$1" || fail "watcher: expected line '$1'"; }
chk 'WK start=1,1'; chk 'WK ready=1,1'; chk 'WK initial_take=1,1'; chk 'WK after_take=0,0'
chk 'WK clients_dirty=0,0'; chk 'WK clients_woke=1,1'
chk 'WK coredll_dirty=1,0'; chk 'WK coredll_w2_woke=1'
chk 'WK engine_dirty=1,1'; chk 'WK fp_changed=1'
chk 'WK stop=0,0'; chk 'WK exited=1,1 thread/stop=0,0'; chk 'WK cycles bad=0 handle_delta=0'
ok "watcher: dirty on Engine change; NOT on Clients\\x (thread woke, fingerprint unchanged); CoreDll dirties only the core-including watcher; initial dirty cover; Stop joins (WaitForSingleObject=0), thread exited, handles closed, 20 start/stop cycles leak no handle"

# ---- 4. publication
P="$(run p "$WORK/probe.dll" X=1)"; echo "$P" | sed 's/^/   /'
chp() { echo "$P" | grep -qx "$1" || fail "publication: expected line '$1'"; }
chp 'PUB registered=1,1 publishers=2'; chp 'PUB q1=1'; chp 'PUB q2=2'; chp 'PUB q2dup=0'; chp 'PUB q3=3'
chp 'PUB ring_count=3'; chp 'PUB trace=1,2,3 n=3 flushed=3 ring=0'
chp 'PUB reg open=0 composing=0 sequence=3 revision=6'; chp 'PUB reg mode=katakana'
chp 'PUB skip seqs=4,5 trace4=5 n=4 reg_sequence=5'
chp 'PUB remove1 key=1 publishers=1 registered=0'; chp 'PUB remove2 key=0 publishers=0'
chp 'PUB q_after_remove=0'; chp 'PUB reregistered=1 key=1'; chp 'PUB disabled registered=0 key=0 publish=0'
ok "publication: ordered queue (dedupe, increasing sequence), flush order 1,2,3 with even revision, skip of already flushed, two publishers (key kept until the last Remove), PublishState=0 removes"

# ---- 5. concurrent queue + locks
C="$(run c "$WORK/probe.dll" X=1)"; echo "$C" | sed 's/^/   /'
echo "$C" | grep -qx 'CONC count=258 dense=1 order=1' || fail "concurrent queue with lock: $C"
ok "2 threads x 300 queues (Sleep(0) inside the push): 600 entries, dense sequence, per-thread order kept"
bad=0
for i in 1 2 3 4 5 6; do
  M="$(run c "$WORK/probe-nolock.dll" X=1)"
  echo "$M" | grep -qx 'CONC count=258 dense=1 order=1' || { bad=1; break; }
done
[ "$bad" = 1 ] || fail "negative control: lock-less probe survived 6 concurrent runs"
ok "negative control: lock-less probe build is detected ($(echo "$M" | grep CONC.count | head -1))"
L="$(cd "$WORK" && SETTINGS_MODE=l SETTINGS_PROBE_DLL="$(winepath -w "$WORK/probe.dll")" DDSKK_HARNESS_DLL_PATH="$(winepath -w "$WORK/shim.dll")" timeout 120 wine Settings-Client.EXE </dev/null 2>/dev/null | tr -d '\r')"
echo "$L" | grep -qx 'LOCK counter=1770 expected=1770' || fail "shim publication lock: $L"
L2="$(cd "$WORK" && SETTINGS_MODE=l SETTINGS_PROBE_DLL="$(winepath -w "$WORK/probe.dll")" DDSKK_HARNESS_DLL_PATH="$(winepath -w "$WORK/shim-nolock.dll")" timeout 120 wine Settings-Client.EXE </dev/null 2>/dev/null | tr -d '\r')"
echo "$L2" | grep -qx 'LOCK counter=1770 expected=1770' && fail "negative control: lock-less shim passed"
ok "shim cb_publock: 2 threads x 3000 read-modify-write = 0x1770 with the lock; lock-less shim build loses updates ($L2)"
echo "PASS: settings-e2e"
