#!/usr/bin/env python3
"""Evaluate the CHECK lines of a case file against a trace.

Usage: realtime-check.py CASES TRACE [--expect-fail-count]
Trace line: T <hexidx> r=0|1 [m= c= t= p=] f=<composing preedit katakana latin wide> v= raw=
Prints 'checks=N atoms=M failed=K ops=O'; exit 1 on any failure or malformed trace.
"""
import re
import sys

FLAGS = ["composing", "preedit", "katakana", "latin", "wide"]


def main(cases, trace):
    ops = sum(1 for l in open(cases) if l.split(" ")[0] in
              ("NEW", "CONT", "FEED", "BS", "COMMIT", "QUIT", "RESTORE", "KATA", "CKATA", "HIRA", "RESET"))
    tr = {}
    for l in open(trace):
        l = l.rstrip("\r\n")
        if not l.startswith("T "):
            continue
        f = l.split(" ")
        d = dict(x.split("=", 1) for x in f[2:])
        tr[int(f[1], 16)] = d
    if len(tr) != ops or sorted(tr) != list(range(ops)):
        print("trace has %d ops, case file %d" % (len(tr), ops)); return 1
    checks = atoms = bad = 0
    for l in open(cases):
        if not l.startswith("CHECK "):
            continue
        checks += 1
        f = l.split()
        for a in f[2:]:
            atoms += 1
            m = re.fullmatch(r"@(\d+):(\w+)=(.*)", a)
            idx, key, want = int(m[1]), m[2], m[3]
            d = tr[idx]
            if key in FLAGS:
                got = d["f"][FLAGS.index(key)]
            else:
                got = d.get(key, "<absent>")
            if got != want:
                bad += 1
                print("FAIL line %s %s: got %r" % (f[1], a, got))
    print("checks=%d atoms=%d failed=%d ops=%d" % (checks, atoms, bad, ops))
    return 1 if bad else 0


sys.exit(main(sys.argv[1], sys.argv[2]))
