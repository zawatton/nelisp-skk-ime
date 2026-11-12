#!/usr/bin/env bash
# S3g end-to-end: the RealtimeFrontend port (ddskk-realtime.el) under wine.
#  1. golden/realtime-cases.txt is re-extracted from windows/test/realtime_frontend_test.cpp
#     (tools/extract-realtime-cases.py) and must equal the checked-in copy;
#  2. a nelisp-built EXE runs every extracted op under wine, prints one trace
#     line per op, and tools/realtime-check.py evaluates every CHECK atom of the
#     C++ test against it (100% required);
#  3. extra scenarios (golden/realtime-extra.txt) and every rule of kRules in
#     hiragana/katakana (golden/realtime-rules.txt) must give a trace identical
#     to the golden, which is the output of the real C++ RealtimeFrontend
#     (realtime-oracle.cpp, g++ on Linux; re-run here when g++ exists);
#  4. negative controls: a rule-table mutation (DDSKK_REALTIME_MUTATE) and a
#     tampered trace must both fail the checks.
# Env: NELISP_ROOT, WINEPREFIX or NELISP_TSF_WINEPREFIX (default: temp dir),
#      NELISP_TSF_UPDATE_GOLDEN=1 rewrites the golden traces from the oracle.
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
G="$HERE/golden"; T="$HERE/tools"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/realtime-e2e.XXXXXX")" || exit 1
PFX_TMP=""
if [ -n "${WINEPREFIX:-}" ]; then :
elif [ -n "${NELISP_TSF_WINEPREFIX:-}" ]; then WINEPREFIX="$NELISP_TSF_WINEPREFIX"
else PFX_TMP="$(mktemp -d "${TMPDIR:-/tmp}/realtime-wineprefix.XXXXXX")"; WINEPREFIX="$PFX_TMP"; fi
export WINEPREFIX WINEDEBUG=-all WINEARCH=win64
cleanup() {
  if [ -n "$PFX_TMP" ]; then timeout 60 wineserver -k >/dev/null 2>&1; rm -rf "$PFX_TMP"; fi
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "ok: $*"; }
build() { # out cases [env...]
  local out="$1" cases="$2"; shift 2
  (ulimit -v 8388608; env "$@" timeout 600 emacs -Q --batch -L "$NELISP_ROOT/lisp" -L "$NATIVE" -L "$HERE" \
     -l realtime-client.el --eval "(realtime-client-build \"$out\" \"$cases\")") >"$WORK/build.log" 2>&1 \
    || { cut -c1-300 "$WORK/build.log" | head -5; fail "build $out"; }
}
runexe() { (cd "$WORK" && timeout 120 wine "$1" </dev/null 2>/dev/null | tr -d '\r'); }

# ---- 1. extraction is current; the C++ test itself passes against the C++ code
python3 -I "$T/extract-realtime-cases.py" "$REPO/windows/test/realtime_frontend_test.cpp" >"$WORK/cases.txt" \
  || fail "extraction"
diff "$WORK/cases.txt" "$G/realtime-cases.txt" >/dev/null || fail "golden/realtime-cases.txt is stale (re-run tools/extract-realtime-cases.py)"
python3 -I "$T/make-extra-cases.py" | diff - "$G/realtime-extra.txt" >/dev/null || fail "golden/realtime-extra.txt is stale"
python3 -I "$T/make-rule-cases.py" "$REPO/windows/src/realtime_frontend.cpp" | diff - "$G/realtime-rules.txt" >/dev/null \
  || fail "golden/realtime-rules.txt is stale"
HAVE_GXX=0
if command -v g++ >/dev/null 2>&1; then
  g++ -std=c++20 -I "$REPO/windows/src" "$REPO/windows/test/realtime_frontend_test.cpp" \
      "$REPO/windows/src/realtime_frontend.cpp" -o "$WORK/cpp-test" 2>"$WORK/g.log" \
    && g++ -std=c++20 -I "$REPO/windows/src" "$HERE/realtime-oracle.cpp" \
      "$REPO/windows/src/realtime_frontend.cpp" -o "$WORK/oracle" 2>>"$WORK/g.log" \
    && HAVE_GXX=1
  [ "$HAVE_GXX" = 1 ] || { head -5 "$WORK/g.log"; fail "g++ build of the C++ frontend failed"; }
  "$WORK/cpp-test" || fail "the original C++ test fails against the C++ frontend"
fi
if [ "$HAVE_GXX" = 1 ]; then ok "extraction current; original C++ test passes (g++ oracle available)"
else ok "extraction current; g++ not available: oracle comparison uses the checked-in golden traces"; fi

# ---- 2. goldens
for n in cases extra rules; do
  if [ "$HAVE_GXX" = 1 ]; then
    "$WORK/oracle" "$G/realtime-$n.txt" >"$WORK/oracle-$n.trace" || fail "oracle $n"
    if [ "${NELISP_TSF_UPDATE_GOLDEN:-}" = 1 ]; then cp "$WORK/oracle-$n.trace" "$G/realtime-$n.trace"; fi
    diff "$WORK/oracle-$n.trace" "$G/realtime-$n.trace" >/dev/null || fail "golden trace $n differs from the C++ oracle"
  fi
done
python3 -I "$T/realtime-check.py" "$G/realtime-cases.txt" "$G/realtime-cases.trace" >/dev/null \
  || fail "the C++ oracle trace does not satisfy the extracted C++ test (extraction bug)"
python3 -I "$T/realtime-check.py" "$G/realtime-extra.txt" "$G/realtime-extra.trace" >/dev/null \
  || fail "the C++ oracle trace does not satisfy the extra expectations"
ok "golden traces equal the C++ oracle and satisfy every CHECK of both case files"

# ---- 3. nelisp EXE under wine
timeout 120 wine reg query 'HKCU\Software' </dev/null >/dev/null 2>&1   # prefix warm-up
for n in cases extra rules; do
  build "$WORK/rt-$n.exe" "$G/realtime-$n.txt"
  runexe "rt-$n.exe" >"$WORK/wine-$n.trace"
  diff "$WORK/wine-$n.trace" "$G/realtime-$n.trace" >"$WORK/d.txt" \
    || { head -5 "$WORK/d.txt"; fail "$n: wine trace differs from the C++ oracle"; }
  R="$(python3 -I "$T/realtime-check.py" "$G/realtime-$n.txt" "$WORK/wine-$n.trace")" || fail "$n: $R"
  ok "$n: $(wc -l <"$WORK/wine-$n.trace") ops identical to the C++ oracle; $R"
done

# ---- 4. negative controls
build "$WORK/rt-mut.exe" "$G/realtime-cases.txt" DDSKK_REALTIME_MUTATE='ka=き'
runexe rt-mut.exe >"$WORK/mut.trace"
if python3 -I "$T/realtime-check.py" "$G/realtime-cases.txt" "$WORK/mut.trace" >"$WORK/mut.out"; then
  fail "negative control: mutated rule ka=き still passes the C++ test checks"
fi
diff "$WORK/mut.trace" "$G/realtime-cases.trace" >/dev/null && fail "negative control: mutated table gave the golden trace"
ok "negative control: rule ka=き makes the extracted C++ test fail ($(tail -1 "$WORK/mut.out"))"
build "$WORK/rt-mut2.exe" "$G/realtime-rules.txt" DDSKK_REALTIME_MUTATE='kyo=きゅ'
runexe rt-mut2.exe >"$WORK/mut2.trace"
diff "$WORK/mut2.trace" "$G/realtime-rules.trace" >/dev/null && fail "negative control: mutated kyo not detected by the rules trace"
ok "negative control: rule kyo mutation (no CHECK involved) is detected by the oracle trace diff"
sed 's/ t=304b / t=304d /' "$WORK/wine-cases.trace" >"$WORK/tamper.trace"
python3 -I "$T/realtime-check.py" "$G/realtime-cases.txt" "$WORK/tamper.trace" >/dev/null \
  && fail "negative control: tampered trace passes the checker"
ok "negative control: the checker rejects a tampered trace"
echo "PASS: realtime-e2e"
