"""Check stored round-2 behavior measurements by their explicit values."""
import argparse
import json
import math
import re
from pathlib import Path


def read(path):
    data = Path(path).read_bytes()
    # Windows PowerShell harness redirection emits UTF-16; JSON and the
    # Python/PowerShell 7 reports use UTF-8. Decode the actual BOM.
    encoding = "utf-16" if data.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig"
    return data.decode(encoding, errors="replace")


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


def check_cpu(baseline, candidate):
    a, b = [json.loads(read(p)) for p in (baseline, candidate)]
    for field in ("runtimeHash", "dictionaryHash", "corpusHash", "server"):
        assert a[field] == b[field], f"input fingerprint differs: {field}"
    tiers = []
    for log in (a, b):
        assert isinstance(log["server"], bool), "invalid server flag"
        # Old non-server logs predate this field. ServerOnly requires a
        # private server, so a missing field with server=False is necessarily
        # False. Never infer the dictionary tier of a server-enabled run.
        assert "serverOnly" in log or log["server"] is False, "unknown server dictionary tier"
        tiers.append(log.get("serverOnly", False))
    assert tiers[0] == tiers[1], "server dictionary tier differs"
    passed = True
    for kind in ("plain", "okuri"):
        values = []
        for log in (a, b):
            samples = [s["cpuMs"] for s in log["samples"] if s["kind"] == kind and s["cold"] is False]
            assert all(isinstance(x, (int, float)) and math.isfinite(x) and x >= 0 for x in samples), "invalid CPU measurement"
            values.append(sorted(samples))
        x, y = values
        assert len(x) == len(y) >= 20, f"invalid sample counts: {kind}"
        p = math.ceil(len(x) * .5) - 1
        assert x[p] > 0, "zero baseline CPU p50"
        ratio = y[p] / x[p]
        print(f"{kind} n={len(x)} baseline={x[p]:.3f} candidate={y[p]:.3f} ratio={ratio:.3f} limit=0.5")
        passed = passed and ratio <= .5
    assert passed, "FAIL S2.1: engine CPU p50 ratio exceeds 0.5"
    print("PASS S2.1: 2/2 kinds")


def check_behavior(directory):
    root = Path(directory)
    files = {
        "ctest": ("round2-ctest-final.log", r"100% tests passed, (\d+) tests failed out of (\d+)", (0, 10)),
        "ERT": ("round2-ert-final.log", r"Ran (\d+) tests, (\d+) results as expected, (\d+) unexpected", (45, 45, 0)),
        "live-input": ("round2-live-input-final.log", r"Ran (\d+) tests, (\d+) results as expected, (\d+) unexpected", (3, 3, 0)),
        "protocol": ("round2-host-protocol.log", r"host UTF8 protocol: (\d+) checks, (\d+) failures", (43, 0)),
        "replay": ("round2-reader-replay.log", r"Replay full checkpoint/snapshot: (\d+)/(\d+) sequences PASS", (38, 38)),
        "capture": ("round2-reader-replay.log", r"Checkpoint unbound/marker parity: (\d+) checks PASS", (2,)),
        "reader": ("round2-reader-replay.log", r"Host LIST reader: (\d+) checks PASS", (6,)),
    }
    for label, (name, pattern, expected) in files.items():
        matches = re.findall(pattern, read(root / name))
        assert matches and tuple(map(int, matches[-1])) == expected, f"{label} counts fail: {matches}"
        print(f"PASS {label} counts={expected}")
    matches = re.findall(r"\bPASS\s+([0-9.]+)\s+(\d+)\b", read(root / "round2-behavior-final.log"))
    assert matches and float(matches[-1][0]) <= 20 and int(matches[-1][1]) == 45, f"DDSKK suite counts fail: {matches}"
    print(f"PASS DDSKK assertions={matches[-1][1]} CtrlGMaxMs={matches[-1][0]}")


def check_cold(path):
    log = json.loads(read(path))
    assert log["quietRequired"] is True, "quiet measurement required"
    rows = [s for s in log["samples"] if s["kind"] == "okuri" and s["cold"] is True]
    assert len(rows) == 1, "one cold okuri measurement required"
    for stage in ("before", "after"):
        loads = [x["load"] for x in log["coldLoads"] if x["kind"] == "okuri" and x["stage"] == stage]
        assert loads, f"missing {stage} load"
        load = loads[-1]  # The harness retries the before check until quiet.
        assert load["intervalMs"] > 0 and load["top"], "invalid load measurement"
        assert max(x["cpuMs"] / load["intervalMs"] for x in load["top"]) <= .3, "busy machine"
    wall = rows[0]["wallMs"]
    assert isinstance(wall, (int, float)) and math.isfinite(wall) and 0 <= wall < 500, "cold okuri limit"
    print(f"PASS S2.2: first okuri wall={wall:.3f} ms <500; quiet before/after")


def check_tsf(directory):
    root = Path(directory)
    for name in ("load-before.json", "load-after.json"):
        loads = json.loads(read(root / name))
        load = loads[-1] if isinstance(loads, list) else loads
        assert load["intervalMs"] > 0 and load["top"], "invalid load measurement"
        assert max(x["cpuMs"] / load["intervalMs"] for x in load["top"]) <= .3, "busy TSF run"
    values = sorted(int(ms) for ms, seq in re.findall(r"^SPACE-CANDIDATE ms=(\d+) seq=(\d+)", read(root / "tsf.log"), re.M)
                    if int(seq) > 2)
    assert len(values) >= 20, "missing TSF conversions"
    p50, p90 = [values[math.ceil(len(values) * p) - 1] for p in (.5, .9)]
    print(f"TSF n={len(values)} p50={p50} p90={p90} max={values[-1]}; quiet before/after")
    assert p50 <= 100 and p90 <= 150, "FAIL S3.1: p50 >100 ms or p90 >150 ms"
    print("PASS S3.1")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    learning = sub.add_parser("learning")
    learning.add_argument("baseline")
    learning.add_argument("candidate")
    states = sub.add_parser("states")
    states.add_argument("baseline")
    states.add_argument("candidate")
    cpu = sub.add_parser("cpu")
    cpu.add_argument("baseline")
    cpu.add_argument("candidate")
    behavior = sub.add_parser("behavior")
    behavior.add_argument("directory")
    cold = sub.add_parser("cold")
    cold.add_argument("path")
    tsf = sub.add_parser("tsf")
    tsf.add_argument("directory")
    args = parser.parse_args()
    if args.command == "learning":
        check_learning(args.baseline, args.candidate)
    elif args.command == "states":
        check_states(args.baseline, args.candidate)
    elif args.command == "cpu":
        check_cpu(args.baseline, args.candidate)
    elif args.command == "cold":
        check_cold(args.path)
    elif args.command == "tsf":
        check_tsf(args.directory)
    else:
        check_behavior(args.directory)


if __name__ == "__main__":
    main()
