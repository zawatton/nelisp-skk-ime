#!/usr/bin/env bash
# S3f end-to-end: the restricted-Elisp engine client (ddskk-engine-client.el)
# built into ec-client.exe talks over a named pipe to ec-stub.exe (a nelisp-built
# engine host replaying the S4.1 TLV goldens or text replies, logging every
# request).  Checks under wine:
#   1. TLV session: HELLO TLV 1, KEY 97 / CONTROL CONVERT / RESET replies decode
#      to the golden dumps; request encoders; ENGINE SET and GC (RAW replies);
#      the request log shows SESSION-prefixed requests.
#   2. text fallback: the stub refuses HELLO; the text STATE replies decode to the
#      same dumps (seq aside).
#   3. engine absent: Connect fails within the 350 ms window (ms reported).
#   4. stub silent: timeout path (status 2, needs_resync), and the next
#      transaction sends RESET before its request (stub log).
#   5. corrupted TLV length: decoder failure (status 4, DECODE 6), no crash,
#      resync, next transaction RESETs first.
#   6. EnsureEngineHost: registry EngineHost -> stub, spawned once (throttle);
#      NELISP_IME_DISABLE_HOST_SPAWN=1 prevents the spawn.
#   Negative controls: mutant client without RESET (EC_MUTANT=1) fails the
#   log assertion; mutant without the spawn throttle (EC_MUTANT=2) starts two
#   hosts; a wrong expectation fails the comparison.
# Env: NELISP_ROOT, WINEPREFIX or NELISP_TSF_WINEPREFIX (default: temp dir).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
GOLD="$REPO/windows/test/golden/tlv"
if [ -z "${NELISP_ROOT:-}" ]; then
  [ -d "$REPO/../nelisp/lisp" ] && NELISP_ROOT="$(cd "$REPO/../nelisp" && pwd)"
fi
if [ -z "${NELISP_ROOT:-}" ] || [ ! -f "$NELISP_ROOT/lisp/nelisp-com-dsl.el" ]; then
  echo "FAIL: NeLisp not found; set NELISP_ROOT"; exit 1
fi
export NELISP_ROOT
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ec-e2e.XXXXXX")" || exit 1
PFX_TMP=""
if [ -n "${WINEPREFIX:-}" ]; then :
elif [ -n "${NELISP_TSF_WINEPREFIX:-}" ]; then WINEPREFIX="$NELISP_TSF_WINEPREFIX"
else PFX_TMP="$(mktemp -d "${TMPDIR:-/tmp}/ec-wineprefix.XXXXXX")"; WINEPREFIX="$PFX_TMP"; fi
export WINEPREFIX WINEDEBUG=-all WINEARCH=win64
K_NATIVE='HKCU\Software\NativeIME'
cleanup() {
  timeout 60 wine reg delete "$K_NATIVE" /v EngineHost /f </dev/null >/dev/null 2>&1
  timeout 60 wine reg delete "$K_NATIVE" /v EngineExecutable /f </dev/null >/dev/null 2>&1
  if [ -n "$PFX_TMP" ]; then timeout 60 wineserver -k >/dev/null 2>&1; rm -rf "$PFX_TMP"; fi
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "ok: $*"; }
wpath() { winepath -w "$1"; }

(ulimit -v 8388608; timeout 900 emacs -Q --batch -L "$NELISP_ROOT/lisp" -L "$NATIVE" -L "$HERE" -l engine-client-hosts.el \
   --eval "(progn (ech-build \"$WORK/ec-client.exe\" 'client) (ech-build \"$WORK/ec-stub.exe\" 'stub))") \
   >"$WORK/build.log" 2>&1 || { tail -5 "$WORK/build.log" | cut -c1-300; fail "build"; }
ok "built ec-client.exe and ec-stub.exe"
timeout 120 wine reg query 'HKCU\Software' </dev/null >/dev/null 2>&1   # prefix warm-up

SEQN=0
# run SCENARIO STUBENV... : starts the stub (unless NOSTUB=1), runs the client,
# output in $WORK/out, normalised request log in $WORK/log.
run() {
  local scen="$1"; shift
  SEQN=$((SEQN + 1))
  local pipe='\\.\pipe\ec-e2e-'"$$-$SEQN"
  rm -f "$WORK/stub.log"
  if [ "${NOSTUB:-0}" != 1 ]; then
    (cd "$WORK" && env DDSKK_PIPE_NAME="$pipe" TLV_GOLDEN_DIR="$(wpath "$GOLD")" ECS_LOG="$(wpath "$WORK/stub.log")" "$@" \
        timeout 60 wine ec-stub.exe </dev/null >/dev/null 2>&1 &)
    sleep 2
  fi
  (cd "$WORK" && env DDSKK_PIPE_NAME="$pipe" EC_SCENARIO="$scen" ${CLIENTENV:-A=1} timeout 90 wine ec-client.exe </dev/null 2>/dev/null | tr -d '\r') >"$WORK/out"
  sleep 1
  [ -f "$WORK/stub.log" ] && sed -e 's/^SESSION [^ ]* //' "$WORK/stub.log" | tr -d '\r' >"$WORK/log" || : >"$WORK/log"
}
val() { grep -m1 "^$1" "$WORK/out" | sed "s/^$1//"; }
D() { cat "$GOLD/$1.dump"; }

# ---- 1. TLV session
run b
[ "$(val 'CONNECT ')" = "ok=1 tlv=1" ] || { cat "$WORK/out"; fail "TLV connect"; }
[ "$(val 'KEY 97: ')" = "$(D state_preedit)" ] || { cat "$WORK/out"; fail "KEY 97 differs from golden"; }
[ "$(val 'CONTROL CONVERT: ')" = "$(D state_candidate)" ] || fail "CONTROL CONVERT differs from golden"
[ "$(val 'RESET: ')" = "$(D state_idle)" ] || fail "RESET differs from golden"
[ "$(val 'SELECT ddskk: ')" = "1" ] || fail "SELECT ddskk"
[ "$(val 'SELECT bad id: ')" = "0" ] || fail "SELECT with an invalid id must be refused locally"
[ "$(val 'PING: ')" = "1" ] || fail "PING"
[ "$(val 'FEED-KEYS: ')" = "NULL status=5 derr=0 resync=0" ] || fail "RAW reply to a state request"
[ "$(val 'ENC KEY 97: ')" = "7 KEY 97" ] && [ "$(val 'ENC KEY 1114112: ')" = "0 (none)" ] \
  && [ "$(val 'ENC CONVERT-KEYS: ')" = "34 CONTROL CONVERT-KEYS 97,98,128512" ] \
  && [ "$(val 'ENC FEED-KEYS 2: ')" = "24 CONTROL FEED-KEYS 97,98" ] \
  && [ "$(val 'ENC FEED-KEYS surrogate: ')" = "0 (none)" ] && [ "$(val 'ENC FEED-KEYS empty: ')" = "0 (none)" ] \
  && [ "$(val 'ENC CONTROL 0: ')" = "18 CONTROL BACKSPACE" ] && [ "$(val 'ENC CONTROL 19: ')" = "15 CONTROL DELETE" ] \
  && [ "$(val 'ENC CONTROL 20: ')" = "0 (none)" ] || { grep '^ENC' "$WORK/out"; fail "request encoders"; }
EXP_LOG="#start
#connect
HELLO TLV 1
KEY 97
CONTROL CONVERT
RESET
ENGINE SET ddskk
GC
CONTROL FEED-KEYS 97,98
SHUTDOWN"
[ "$(cat "$WORK/log")" = "$EXP_LOG" ] || { cat "$WORK/log"; fail "request log of the TLV session"; }
grep -q '^SESSION [0-9]*-[0-9]* KEY 97$' "$WORK/stub.log" || fail "requests lack the SESSION prefix"
ok "TLV session: KEY/CONVERT/RESET decode to the goldens; encoders, SELECT, PING, RAW reply, request log"
[ "$(val 'KEY 97: ')" != "$(D state_candidate)" ] || fail "negative control: comparator accepts a wrong expectation"
ok "negative control: wrong expectation is detected"

# ---- 2. text fallback
run b TLV_STUB_NOTLV=1
[ "$(val 'CONNECT ')" = "ok=1 tlv=0" ] || { cat "$WORK/out"; fail "text connect"; }
nosec() { sed 's/ seq=[0-9a-z]*$/ seq=none/'; }
[ "$(val 'KEY 97: ')" = "$(D state_preedit)" ] || { cat "$WORK/out"; fail "text KEY 97"; }
[ "$(val 'CONTROL CONVERT: ' | cat)" = "$(D state_candidate | nosec)" ] || { val 'CONTROL CONVERT: '; fail "text CONVERT (surrogate pair candidate)"; }
[ "$(val 'RESET: ')" = "$(D state_idle)" ] || fail "text RESET"
[ "$(val 'SELECT ddskk: ')" = "1" ] && [ "$(val 'PING: ')" = "1" ] || fail "text SELECT/PING"
[ "$(val 'FEED-KEYS: ')" = "NULL status=5 derr=0 resync=0" ] || fail "text non-state reply"
grep -q '^HELLO TLV 1$' "$WORK/log" || fail "HELLO not sent"
ok "text fallback: refused HELLO keeps the text protocol; STATE lines decode to the same fields"

# ---- 3. engine absent
NOSTUB=1 run a
MS="$(val 'CONNECT ok=0 status=1 ms=')"
case "$MS" in ''|*[!0-9]*) cat "$WORK/out"; fail "absent: connect did not fail with status 1" ;; esac
[ "$MS" -le 450 ] || fail "absent: connect took ${MS} ms (> 450)"
KMS="$(val 'KEY ms=')"
[ "$KMS" -le 450 ] || fail "absent: KEY took ${KMS} ms (> 450)"
grep -q '^KEY: NULL status=1' "$WORK/out" || fail "absent: KEY must report connect failure"
ok "engine absent: Connect(350) failed in ${MS} ms, SendKey in ${KMS} ms (C++ window 350 ms)"

# ---- 4. stub silent: timeout, needs_resync, RESET first
assert_reset_first() { # log must contain RESET directly before CONTROL CONVERT after the reconnect
  awk 'prev=="RESET" && $0=="CONTROL CONVERT" {ok=1} {prev=$0} END {exit ok?0:1}' "$WORK/log" &&
  awk '/^KEY 97$/ {k=NR} /^RESET$/ && k && !r {r=NR} END {exit (k && r && r>k)?0:1}' "$WORK/log"
}
run s ECS_SILENT_AT=1 ECS_SLEEP_MS=600
grep -q '^KEY 97: NULL status=2 derr=0 resync=1$' "$WORK/out" || { cat "$WORK/out"; fail "silent: timeout path"; }
TMS="$(val 'KEY ms=')"
[ "$TMS" -ge 300 ] && [ "$TMS" -le 700 ] || fail "silent: timeout took ${TMS} ms"
[ "$(val 'RESYNC after: ')" = "1" ] && [ "$(val 'RESYNC end: ')" = "0" ] || fail "silent: needs_resync lifecycle"
[ "$(val 'CONTROL CONVERT: ')" = "$(D state_candidate)" ] || fail "silent: transaction after resync"
assert_reset_first || { cat "$WORK/log"; fail "silent: RESET not sent before the next request"; }
ok "stub silent: SendKey timed out after ${TMS} ms (350 ms budget), needs_resync set, next transaction sent RESET first"
CLIENTENV=EC_MUTANT=1 run s ECS_SILENT_AT=1 ECS_SLEEP_MS=600
if assert_reset_first; then cat "$WORK/log"; fail "negative control: mutant client without RESET passed the log assertion"; fi
grep -q '^RESET$' "$WORK/log" && fail "negative control: mutant still sent RESET"
ok "negative control: mutant client skipping RESET fails the stub-log assertion"

# ---- 5. corrupted TLV length
run s ECS_CORRUPT_AT=1
grep -q '^KEY 97: NULL status=4 derr=6 resync=1$' "$WORK/out" || { cat "$WORK/out"; fail "corrupt: decoder failure not reported"; }
[ "$(val 'CONTROL CONVERT: ')" = "$(D state_candidate)" ] || fail "corrupt: client did not recover"
assert_reset_first || { cat "$WORK/log"; fail "corrupt: RESET not sent after the decode failure"; }
ok "corrupted TLV length: decoder failure reported (status 4, code 6), no crash, resync + RESET, recovered"

# ---- 6. EnsureEngineHost
timeout 60 wine reg add "$K_NATIVE" /v EngineHost /t REG_SZ /d "$(wpath "$WORK/ec-stub.exe")" /f </dev/null >/dev/null 2>&1
timeout 60 wine reg add "$K_NATIVE" /v EngineExecutable /t REG_SZ /d "dummy-nelisp.exe" /f </dev/null >/dev/null 2>&1
spawn() { # extra client env, extra stub-run env
  SEQN=$((SEQN + 1)); local pipe='\\.\pipe\ec-e2e-'"$$-$SEQN"
  rm -f "$WORK/stub.log"
  (cd "$WORK" && env DDSKK_PIPE_NAME="$pipe" TLV_GOLDEN_DIR="$(wpath "$GOLD")" ECS_LOG="$(wpath "$WORK/stub.log")" \
      ECS_DELAY_MS=700 EC_SCENARIO=h "$@" timeout 120 wine ec-client.exe </dev/null 2>/dev/null | tr -d '\r') >"$WORK/out"
  sleep 2
}
spawn
grep -q '^ENSURE1: 1$' "$WORK/out" && grep -q '^ENSURE2: 0$' "$WORK/out" || { cat "$WORK/out"; fail "spawn: ENSURE results"; }
[ "$(val 'KEY 97: ')" = "$(D state_preedit)" ] || fail "spawn: spawned host not reachable"
[ "$(grep -c '^#start' "$WORK/stub.log" | tr -d '\r')" = 1 ] || fail "spawn: expected exactly one host start"
ok "EnsureEngineHost: CreateProcessW via registry EngineHost started the stub once; second call throttled; engine reachable"
spawn EC_MUTANT=2
[ "$(grep -c '^#start' "$WORK/stub.log" | tr -d '\r')" -ge 2 ] || fail "negative control: no-throttle mutant still started one host"
ok "negative control: mutant without the spawn throttle starts two hosts"
spawn NELISP_IME_DISABLE_HOST_SPAWN=1
grep -q '^ENSURE1: 0$' "$WORK/out" && [ ! -s "$WORK/stub.log" ] || { cat "$WORK/out"; fail "spawn: NELISP_IME_DISABLE_HOST_SPAWN ignored"; }
ok "NELISP_IME_DISABLE_HOST_SPAWN=1 prevents the spawn"
echo "PASS: engine-client-e2e"
exit 0
