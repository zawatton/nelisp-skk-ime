#!/usr/bin/env python3
"""Mechanically extract the test cases of windows/test/realtime_frontend_test.cpp.

Output (stdout) is the case-file format shared by realtime-client.el (compiles
the OP lines into the test EXE), realtime-oracle.cpp and realtime-check.py:

  NEW name | CONT name 0/1 | FEED name KEYHEX | BS|COMMIT|QUIT|RESTORE|KATA|CKATA|HIRA|RESET name
  CHECK srcline @opidx:key=value ...      (opidx = 0-based index of the OP lines)

CHECK keys: r (state present), m (mode 0 hira 1 kata 2 latin 3 wide 4 preedit),
c (composition_start), t (UTF-16 units hex, '.'-joined, '-' empty), p (pending
romaji), composing/preedit/katakana/latin/wide (flag after that op).
Every statement and every CHECK atom must be understood; anything else aborts
(nothing is skipped).  Usage: extract-realtime-cases.py TEST.cpp > cases.txt
"""
import re
import sys

# U+3000 is real data here: never use the Unicode-aware str.strip()/\s.
WS = " \t\r\n"
MODES = {"hiragana": 0, "katakana": 1, "latin": 2, "wide-latin": 3, "preedit": 4}
METHODS = {"Backspace": "BS", "Commit": "COMMIT", "Quit": "QUIT",
           "RestorePreedit": "RESTORE", "ToKatakana": "KATA",
           "CommitKatakana": "CKATA", "ToHiragana": "HIRA", "Reset": "RESET"}


def units(s):
    if s == "":
        return "-"
    out = []
    for ch in s:
        cp = ord(ch)
        if cp > 0xFFFF:
            cp -= 0x10000
            out += ["%04x" % (0xD800 + (cp >> 10)), "%04x" % (0xDC00 + (cp & 0x3FF))]
        else:
            out.append("%04x" % cp)
    return ".".join(out)


def main(path):
    src = open(path, encoding="utf-8").read()
    start = src.index("int main() {") + len("int main() {")
    body = src[start:src.rindex("}")]
    base_line = src[:start].count("\n") + 1
    n_check_src = len(re.findall(r"\bCHECK\(", body))
    lines = []
    ops = 0
    objs = {}           # name -> last op index
    state_op = None
    checks = atoms = 0
    pos = 0
    for raw in body.split(";"):
        stmt = raw.strip(WS)
        lead = len(raw) - len(raw.lstrip(WS))
        line = base_line + body[:pos + lead].count("\n")
        pos += len(raw) + 1
        if not stmt or stmt == "return 0":
            continue
        m = re.fullmatch(r"ddskk::RealtimeFrontend (\w+)", stmt)
        if m:
            lines.append("NEW %s" % m[1]); objs[m[1]] = ops; ops += 1; continue
        m = re.fullmatch(r"(\w+)\.SetContinuousPreedit\((true|false)\)", stmt)
        if m:
            lines.append("CONT %s %d" % (m[1], m[2] == "true")); objs[m[1]] = ops; ops += 1; continue
        m = re.fullmatch(r"(?:auto )?(?:(state) = )?(\w+)\.(\w+)\((.*)\)", stmt, re.S)
        if m and m[3] in METHODS | {"Feed": 1} and not stmt.startswith("CHECK"):
            name, meth, arg = m[2], m[3], m[4]
            if meth == "Feed":
                a = re.fullmatch(r"U'(.)'", arg)
                if not a:
                    sys.exit("unparsed Feed argument: %r" % arg)
                lines.append("FEED %s %02x" % (name, ord(a[1])))
            else:
                if arg:
                    sys.exit("unexpected argument in %r" % stmt)
                lines.append("%s %s" % (METHODS[meth], name))
            if m[1]:
                state_op = ops
            objs[name] = ops
            ops += 1
            continue
        m = re.fullmatch(r"CHECK\((.*)\)", stmt, re.S)
        if m:
            cond = re.sub(r"[ \t\r\n]+", " ", m[1]).strip(WS)
            parts = [x.strip(WS) for x in cond.split("&&")]
            out = []
            for a in parts:
                if state_op is None and a.find("state") >= 0:
                    sys.exit("state used before assignment: %r" % a)
                s = "@%s:" % state_op
                if a == "state": out.append(s + "r=1")
                elif a == "!state": out.append(s + "r=0")
                elif a == "state->text.empty()": out.append(s + "t=-")
                elif (x := re.fullmatch(r'state->text == L"(.*)"', a)): out.append(s + "t=" + units(x[1]))
                elif (x := re.fullmatch(r'state->mode == L"(.*)"', a)): out.append(s + "m=%d" % MODES[x[1]])
                elif a == "state->pending_romaji.empty()": out.append(s + "p=-")
                elif (x := re.fullmatch(r'state->pending_romaji == L"(.*)"', a)): out.append(s + "p=" + (x[1] or "-"))
                elif (x := re.fullmatch(r"state->composition_start == (-?\d+)", a)): out.append(s + "c=" + x[1])
                elif (x := re.fullmatch(r"(!?)(\w+)\.(composing|katakana|latin|wide_latin|preedit)\(\)", a)):
                    key = "wide" if x[3] == "wide_latin" else x[3]
                    out.append("@%d:%s=%d" % (objs[x[2]], key, 0 if x[1] else 1))
                else:
                    sys.exit("unparsed CHECK atom: %r (line %d)" % (a, line))
            lines.append("CHECK %d %s" % (line, " ".join(out)))
            checks += 1; atoms += len(out)
            continue
        sys.exit("unparsed statement: %r" % stmt)
    if checks != n_check_src:
        sys.exit("CHECK count mismatch: %d extracted vs %d in source" % (checks, n_check_src))
    print("# extracted from %s by extract-realtime-cases.py: %d ops, %d checks, %d atoms"
          % ("windows/test/realtime_frontend_test.cpp", ops, checks, atoms))
    print("\n".join(lines))


main(sys.argv[1])
