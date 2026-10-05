"""Summarize stored host phase CPU deltas; no engine or live IME access."""
import argparse
import math
import re
from pathlib import Path


def percentile(values, p):
    return sorted(values)[math.ceil(len(values) * p) - 1]


def summarize(path, warm):
    data = Path(path).read_bytes()
    text = data.decode("utf-16" if data.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig", errors="replace")
    blocks = re.findall(r"^dispatch tick=[^\n]*request=[^\n]*CONTROL CONVERT-KEYS [^\n]*\n.*?^dispatch done [^\n]*$", text, re.M | re.S)
    assert blocks, "no conversion requests"
    if warm is not None:
        assert len(blocks) >= warm + 1, "missing measured conversions"
        blocks = blocks[:warm + 1]  # Learning checks follow the timed corpus.
    rows = []
    for block in blocks:
        phases = {}
        for name, ms in re.findall(r"^engine-phase-cpu name=(\S+) ms=(\d+) next=", block, re.M):
            phases[name] = phases.get(name, 0) + int(ms)
        match = re.search(r"^dispatch done [^\n]*ms=(\d+) cpu_ms=(\d+)", block, re.M)
        total = int(match[2])
        # Includes response formatting/write and the uninstrumented tail.
        phases["response-tail"] = total - sum(phases.values())
        rows.append((phases, total, int(match[1])))
    print(f"{path}: conversions={len(rows)}; process CPU clock quantum about 16 ms")
    for cohort, selected in (("cold", rows[:1]), ("warm", rows[1:])):
        if not selected:
            continue
        for name in sorted(set().union(*(x[0] for x in selected))):
            values = [x[0].get(name, 0) for x in selected]
            print(f"{cohort} {name} n={len(values)} CPU p50={percentile(values, .5)} p90={percentile(values, .9)} max={max(values)} ms")
        for label, index in (("total-CPU", 1), ("total-wall", 2)):
            values = [x[index] for x in selected]
            print(f"{cohort} {label} n={len(values)} p50={percentile(values, .5)} p90={percentile(values, .9)} max={max(values)} ms")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", nargs="+")
    parser.add_argument("--warm", type=int)
    args = parser.parse_args()
    for trace in args.trace:
        summarize(trace, args.warm)
