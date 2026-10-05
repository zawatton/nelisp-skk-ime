"""Check stored round-2 behavior measurements by their explicit values."""
import argparse
import json
import re
from pathlib import Path


def read(path):
    return Path(path).read_text(encoding="utf-8-sig", errors="replace")


def check_learning(baseline, candidate):
    a, b = [json.loads(read(p)) for p in (baseline, candidate)]
    for field in ("runtimeHash", "dictionaryHash", "corpusHash"):
        assert a[field] == b[field], f"input fingerprint differs: {field}"
    assert len(a["learning"]) == len(b["learning"]) >= 6, "learning corpus size differs"
    for i, (x, y) in enumerate(zip(a["learning"], b["learning"])):
        for field in ("name", "first", "selected", "learned"):
            assert x[field] == y[field], f"learning differs: {i}/{field}"
    print(f"PASS learning equality: {len(b['learning'])}/{len(a['learning'])}")


def check_states(baseline, candidate):
    a, b = [json.loads(read(p)) for p in (baseline, candidate)]
    for field in ("runtimeHash", "dictionaryHash", "corpusHash"):
        assert a[field] == b[field], f"input fingerprint differs: {field}"
    assert len(a["samples"]) == len(b["samples"]) >= 122, "state corpus size differs"
    for i, (x, y) in enumerate(zip(a["samples"], b["samples"])):
        for field in ("name", "kind", "response"):
            assert x[field] == y[field], f"state differs: {i}/{field}"
    print(f"PASS state equality: {len(b['samples'])}/{len(a['samples'])}")


def check_behavior(directory):
    root = Path(directory)
    files = {
        "ctest": ("round2-ctest-final.log", r"100% tests passed, (\d+) tests failed out of (\d+)", (0, 10)),
        "ERT": ("round2-ert-final.log", r"Ran (\d+) tests, (\d+) results as expected, (\d+) unexpected", (45, 45, 0)),
        "live-input": ("round2-live-input-final.log", r"Ran (\d+) tests, (\d+) results as expected, (\d+) unexpected", (3, 3, 0)),
        "protocol": ("round2-host-protocol.log", r"host UTF8 protocol: (\d+) checks, (\d+) failures", (43, 0)),
        "replay": ("round2-replay-equivalence.log", r"Replay full checkpoint/snapshot: (\d+)/(\d+) sequences PASS", (38, 38)),
    }
    for label, (name, pattern, expected) in files.items():
        matches = re.findall(pattern, read(root / name))
        assert matches and tuple(map(int, matches[-1])) == expected, f"{label} counts fail: {matches}"
        print(f"PASS {label} counts={expected}")
    matches = re.findall(r"\bPASS\s+([0-9.]+)\s+(\d+)\b", read(root / "round2-behavior-final.log"))
    assert matches and float(matches[-1][0]) <= 20 and int(matches[-1][1]) == 45, f"DDSKK suite counts fail: {matches}"
    print(f"PASS DDSKK assertions={matches[-1][1]} CtrlGMaxMs={matches[-1][0]}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    learning = sub.add_parser("learning")
    learning.add_argument("baseline")
    learning.add_argument("candidate")
    states = sub.add_parser("states")
    states.add_argument("baseline")
    states.add_argument("candidate")
    behavior = sub.add_parser("behavior")
    behavior.add_argument("directory")
    args = parser.parse_args()
    if args.command == "learning":
        check_learning(args.baseline, args.candidate)
    elif args.command == "states":
        check_states(args.baseline, args.candidate)
    else:
        check_behavior(args.directory)


if __name__ == "__main__":
    main()
