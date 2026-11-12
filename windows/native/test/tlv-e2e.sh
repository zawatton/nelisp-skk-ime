#!/usr/bin/env bash
# S4.1 end-to-end: the restricted-Elisp TLV decoder (ddskk-tlv.el), built into a
# nelisp EXE, decodes the golden windows/test/golden/tlv/*.bin under wine to
# exactly the dump lines the C++ unit test (test/engine_tlv_test.cpp) checks in
# the *.dump files.  Also drives a nelisp-built stub engine host over a named
# pipe (HELLO TLV negotiation, TLV replies, text fallback) and runs negative
# controls (corrupted length/magic/version/truncation must be rejected; a
# mismatching expectation must fail the comparison).
# Env: NELISP_ROOT (NeLisp checkout), WINEPREFIX or NELISP_TSF_WINEPREFIX
#      (default: temp dir).
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
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tlv-e2e.XXXXXX")" || exit 1
PFX_TMP=""
if [ -n "${WINEPREFIX:-}" ]; then :
elif [ -n "${NELISP_TSF_WINEPREFIX:-}" ]; then WINEPREFIX="$NELISP_TSF_WINEPREFIX"
else PFX_TMP="$(mktemp -d "${TMPDIR:-/tmp}/tlv-wineprefix.XXXXXX")"; WINEPREFIX="$PFX_TMP"; fi
export WINEPREFIX WINEDEBUG=-all WINEARCH=win64
STUB_PID=""
cleanup() {
  [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null
  if [ -n "$PFX_TMP" ]; then timeout 60 wineserver -k >/dev/null 2>&1; rm -rf "$PFX_TMP"; fi
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "ok: $*"; }

(ulimit -v 8388608; timeout 600 emacs -Q --batch -L "$NELISP_ROOT/lisp" -L "$NATIVE" -L "$HERE" -l tlv-hosts.el \
   --eval "(progn (th-build \"$WORK/tlv-client.exe\" 'client) (th-build \"$WORK/tlv-stub-host.exe\" 'stub))") \
   >"$WORK/build.log" 2>&1 || { tail -5 "$WORK/build.log" | cut -c1-300; fail "build"; }
ok "built tlv-client.exe and tlv-stub-host.exe"
timeout 120 wine reg query 'HKCU\Software' </dev/null >/dev/null 2>&1   # prefix warm-up

decode() { # file -> dump line on stdout
  (cd "$WORK" && TLV_MODE=file TLV_FILE="$(winepath -w "$1")" timeout 60 wine tlv-client.exe </dev/null 2>/dev/null | tr -d '\r')
}

# ---- 1. every golden decodes to the C++ dump
n=0
for bin in "$GOLD"/*.bin; do
  name="$(basename "$bin" .bin)"
  got="$(decode "$bin")"
  want="$(cat "$GOLD/$name.dump")"
  [ "$got" = "$want" ] || { echo "got:  $got"; echo "want: $want"; fail "golden $name decodes differently from the C++ dump"; }
  n=$((n + 1))
done
[ "$n" -ge 6 ] || fail "expected >= 6 golden files, saw $n"
ok "$n golden files decode to the same field values as the C++ test"

# ---- 2. oracle: comparing against a different golden's dump must differ
got="$(decode "$GOLD/state_candidate.bin")"
[ "$got" != "$(cat "$GOLD/state_preedit.dump")" ] || fail "negative control: comparator accepts a wrong expectation"
ok "negative control: wrong expectation is detected"

# ---- 3. corrupted inputs are rejected with the documented error codes
mut() { # name expected-code  (reads $WORK/m.bin)
  got="$(decode "$WORK/m.bin")"
  [ "$got" = "DECODE-ERR $2" ] || fail "negative control $1: got '$got', want DECODE-ERR $2"
  ok "negative control $1 rejected (DECODE-ERR $2)"
}
SRC="$GOLD/state_candidate.bin"
SIZE="$(stat -c %s "$SRC")"
cp "$SRC" "$WORK/m.bin"; printf '\x7d' | dd of="$WORK/m.bin" bs=1 seek=4 conv=notrunc 2>/dev/null; mut "total length +1" 3
head -c $((SIZE - 3)) "$SRC" >"$WORK/m.bin"; mut "truncated by 3 bytes" 3
head -c 11 "$SRC" >"$WORK/m.bin"; mut "truncated inside header" 1
head -c 0 "$SRC" >"$WORK/m.bin"; mut "empty input" 1
cp "$SRC" "$WORK/m.bin"; printf 'X' | dd of="$WORK/m.bin" bs=1 seek=0 conv=notrunc 2>/dev/null; mut "bad magic" 2
cp "$SRC" "$WORK/m.bin"; printf '\x02' | dd of="$WORK/m.bin" bs=1 seek=8 conv=notrunc 2>/dev/null; mut "future version" 4
cp "$SRC" "$WORK/m.bin"; printf '\x09' | dd of="$WORK/m.bin" bs=1 seek=9 conv=notrunc 2>/dev/null; mut "unknown kind" 5
cp "$SRC" "$WORK/m.bin"; printf '\xff\xff\xff\x7f' | dd of="$WORK/m.bin" bs=1 seek=14 conv=notrunc 2>/dev/null; mut "record length overruns message" 6
cp "$SRC" "$WORK/m.bin"; printf '\x11' | dd of="$WORK/m.bin" bs=1 seek=14 conv=notrunc 2>/dev/null; mut "odd UTF-16 length" 7
# Oversized: valid header claiming > 65536 bytes.
head -c 70000 /dev/zero >"$WORK/m.bin"; printf 'DSTV' | dd of="$WORK/m.bin" bs=1 conv=notrunc 2>/dev/null; mut "oversized input" 1
# Missing required tags: header only plus one unknown record.
printf 'DSTV\x12\x00\x00\x00\x01\x01\x00\x00\x01\x7f\x00\x00\x00\x00' >"$WORK/m.bin"; mut "required tags missing" 9

# ---- 4. named-pipe round trip against the stub engine host
PIPE='\\.\pipe\ddskk-tlv-test-'"$$"
pipe_run() { # extra env... -> client output
  (cd "$WORK" && env DDSKK_PIPE_NAME="$PIPE" TLV_GOLDEN_DIR="$(winepath -w "$GOLD")" "$@" \
      timeout 60 wine tlv-stub-host.exe </dev/null >/dev/null 2>&1 &
   echo $! >"$WORK/stub.pid")
  STUB_PID="$(cat "$WORK/stub.pid")"
  sleep 1
  (cd "$WORK" && DDSKK_PIPE_NAME="$PIPE" TLV_MODE=pipe timeout 90 wine tlv-client.exe </dev/null 2>/dev/null | tr -d '\r')
  wait 2>/dev/null; STUB_PID=""
}
OUT="$(pipe_run)"
EXP="HELLO tlv=1
REPLY KEY 97: $(cat "$GOLD/state_preedit.dump")
REPLY CONTROL CONVERT: $(cat "$GOLD/state_candidate.dump")
REPLY RESET: $(cat "$GOLD/state_idle.dump")
REPLY PING: $(cat "$GOLD/raw_ok.dump")"
[ "$OUT" = "$EXP" ] || { echo "$OUT" | head -8; fail "pipe session differs from expectation"; }
ok "pipe: HELLO TLV negotiated; KEY/CONTROL/RESET/PING replies decode to the golden values"
OUT2="$(pipe_run TLV_STUB_NOTLV=1)"
EXP2="HELLO tlv=0
REPLY KEY 97: TEXT STATE hiragana 0 -1 - - -1 -
REPLY CONTROL CONVERT: TEXT STATE hiragana 0 -1 - - -1 -
REPLY RESET: TEXT STATE hiragana 0 -1 - - -1 -
REPLY PING: TEXT STATE hiragana 0 -1 - - -1 -"
[ "$OUT2" = "$EXP2" ] || { echo "$OUT2" | head -8; fail "text fallback session differs"; }
ok "pipe: host refusing TLV falls back to the unchanged text protocol"
[ "$OUT" != "$OUT2" ] || fail "negative control: TLV and text sessions are identical"
echo "PASS: tlv-e2e"
exit 0
