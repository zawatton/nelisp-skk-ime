#!/usr/bin/env python3
"""Classify a public SKK dictionary through the portable production CLI.

The before column is the frozen 28e9882 reading/Plain policy, used only for
forensics. The after column comes from the compiled production helpers.
Never pass a personal dictionary to this tool.
"""
import argparse
import collections
import hashlib
import json
import pathlib
import subprocess


def utf16_units(value):
    return len(value.encode("utf-16-le")) // 2


def kana(value):
    return bool(value) and all("\u3041" <= c <= "\u3096" or c == "ー" for c in value)


def scalar_hex(value):
    return "".join(f"{ord(c):06x}" for c in value) or "-"


def before_reason(reading, raw, okuri):
    if not reading or utf16_units(reading) > 256:
        return "reading-limit"
    stem = reading[:-1] if okuri else reading
    if not kana(stem):
        return "numeric-reading" if any(c in "0123456789#" for c in reading) else "non-kana-reading"
    if len(raw.encode("utf-8")) > 65536:
        return "raw-limit"
    block = False
    count = 0
    reason = "supported"
    for field in raw.split("/"):
        if not field:
            continue
        if field.startswith("["):
            block = True
            if not okuri or len(field) == 1:
                reason = "okuri-block"
            continue
        if block:
            if field == "]":
                block = False
            continue
        word = field.split(";", 1)[0]
        if not word:
            reason = "empty-word"
        elif word.startswith("("):
            reason = "candidate-lisp-prefix"
        elif "#" in word:
            reason = "candidate-hash"
        elif any(c in word for c in "\t\n\r"):
            reason = "candidate-control"
        units = utf16_units(field)
        if units > 1024:
            reason = "candidate-limit"
        if (units + utf16_units(reading) + utf16_units(okuri)) * 6 + 128 > 8192:
            reason = "wire-limit"
        count += 1
        if count > 1024:
            return "candidate-count"
    return "okuri-block" if block else reason


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dictionary", required=True, type=pathlib.Path)
    parser.add_argument("--binary", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--overlay", type=pathlib.Path,
                        help="private engine snapshot fixture carrying optional annotation certification")
    args = parser.parse_args()
    source_bytes = args.dictionary.read_bytes()
    entries = {}
    mode = None
    malformed = 0
    duplicates = 0
    for line in source_bytes.decode("utf-8-sig").splitlines():
        if line == ";; okuri-ari entries.":
            mode = "ari"
        elif line == ";; okuri-nasi entries.":
            mode = "nasi"
        elif not line or line.startswith(";"):
            continue
        elif " /" not in line or not line.endswith("/"):
            malformed += 1
        else:
            key, raw = line.split(" ", 1)
            if key in entries:
                duplicates += 1
                continue
            # Complete okuri is supplied only for ari-section entries. In a
            # headerless public source infer the ordinary kana-stem shape.
            ari = mode == "ari" or (mode is None and key[-1:] in "abcdefghijklmnopqrstuvwxyz" and kana(key[:-1]))
            entries[key] = (raw, "あ" if ari else "", line)
    requests = "".join(f"{scalar_hex(key)} {scalar_hex(okuri)}\n"
                       for key, (_, okuri, _) in entries.items())
    result = subprocess.run([str(args.binary.resolve()), "--lookup",
                             str(args.overlay.resolve()) if args.overlay else "-", str(args.dictionary.resolve())],
                            input=requests, text=True, capture_output=True, check=True, timeout=120)
    rows = result.stdout.splitlines()
    if len(rows) != len(entries):
        raise ValueError(f"CLI rows={len(rows)} entries={len(entries)}")
    counts = {"before": collections.Counter(), "after": collections.Counter()}
    examples = {"before": {}, "after": {}}
    targets = {}
    for (key, (raw, okuri, line)), row in zip(entries.items(), rows):
        fields = row.split("\t")
        if len(fields) != 4 or fields[0] not in ("OK", "NO"):
            raise ValueError(f"invalid production CLI record for {key!r}: {row[:120]!r}")
        old = before_reason(key, raw, okuri)
        new = "supported" if fields[0] == "OK" else fields[1]
        # The mapped Index checks the reading before candidate payloads. A
        # numeric key with a Lisp candidate therefore has numeric priority,
        # even though the CLI can also report the compile-time expression.
        if new != "supported" and any(c in "0123456789#" for c in key):
            new = "numeric-reading"
        for column, reason in (("before", old), ("after", new)):
            counts[column][reason] += 1
            samples = examples[column].setdefault(reason, [])
            if len(samples) < 3:
                samples.append(line)
        if key in ("おーむ", "いどう"):
            targets[key] = {"before": old, "after": new, "source_line": line}
    for column in counts:
        assert sum(counts[column].values()) == len(entries)
    report = {"source_name": args.dictionary.name,
              "source_sha256": hashlib.sha256(source_bytes).hexdigest(),
              "source_bytes": len(source_bytes),
              "source_lines": len(source_bytes.splitlines()),
              "entries": len(entries), "duplicates": duplicates, "malformed_lines": malformed,
              "engine_capabilities": 3, "annotation_profile": bool(args.overlay),
              "okuri_probe": "あ for ari entries; no okuri for nasi entries",
              "before_policy": "28e9882 reading/Plain checks, last observed failing candidate reason",
              "after_policy": "production source compilation and entry certification; numeric reading takes reader priority",
              "counts": {column: dict(counter.most_common()) for column, counter in counts.items()},
              "examples": examples, "reported_readings": targets}
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(f"PASS whole-L classification entries={len(entries)} duplicates={duplicates} malformed={malformed}")
    for column in ("before", "after"):
        print(column + ": " + ", ".join(f"{reason}={count}" for reason, count in counts[column].most_common()))
    for key, values in targets.items():
        print(f"{key}: before={values['before']} after={values['after']}")
    print("source_sha256=" + report["source_sha256"])


if __name__ == "__main__":
    main()
