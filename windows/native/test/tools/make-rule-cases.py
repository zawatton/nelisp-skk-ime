#!/usr/bin/env python3
"""Generate golden/realtime-rules.txt: every rule of kRules typed through the
frontend (hiragana and katakana mode), with no CHECK lines; the verdict is the
trace diff against the C++ oracle.  Rules are read from the C++ source itself.
Usage: make-rule-cases.py windows/src/realtime_frontend.cpp > realtime-rules.txt
"""
import re
import sys

src = open(sys.argv[1], encoding="utf-8").read()
body = src[src.index("kRules{"):]
body = body[:body.index("};")]
keys = []
for k in re.findall(r'Rule\{"([^"]+)", L"[^"]+"\}', body):
    if k not in keys:
        keys.append(k)
if len(keys) < 100:
    sys.exit("too few rules")
print("# every rule key typed in preedit (Ka + key, QUIT), then katakana mode; %d rules" % len(keys))
print("NEW pre")
for k in keys:
    for ch in "Ka" + k:
        print("FEED pre %x" % ord(ch))
    print("QUIT pre")
print("NEW kata")
print("FEED kata 71")
for k in keys:
    if k[0] == "l":      # 'l' at the start of a word is the latin toggle
        continue
    for ch in k:
        print("FEED kata %x" % ord(ch))
print("NEW hira")
for k in keys:
    if k[0] == "l":
        continue
    for ch in k:
        print("FEED hira %x" % ord(ch))
