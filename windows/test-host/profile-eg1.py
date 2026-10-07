"""Summarize private bench-conversion JSON and nested QPC PHASE logs."""
import json
import re
import statistics
import sys
from pathlib import Path

def summary(label, values):
    values = sorted(values)
    if values:
        print(f"{label} n={len(values)} p50={statistics.median(values):.6f} "
              f"p90={values[max(0, (9*len(values)+9)//10-1)]:.6f} max={values[-1]:.6f} ms")

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8-sig"))
groups = {}
for row in data.get("transactions", []):
    request = row["request"]
    if request.startswith("SESSION "):
        request = request.split(" ", 2)[2]
    label = row.get("operation") or (" ".join(request.split()[:2]) if request.startswith("CONTROL ") else request.split()[0])
    for metric in ("writeMs", "readMs", "decodeMs", "totalMs"):
        groups.setdefault(f"client {label} {metric}", []).append(row[metric])
for label, values in sorted(groups.items()):
    summary(label, values)

costs, self_costs, segments = {}, {}, {}
for path in Path(data["traceDir"]).glob("*-host.log"):
    clock, stack, boundaries = 0.0, [], {}
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    # Prefer additive QPC records; support earlier EG1 decimal-only traces.
    qpc = any(line.startswith("engine-phase-qpc ") for line in lines)
    phase_prefix = "engine-phase-qpc" if qpc else "engine-phase"
    relay_prefix = "dictionary-relay-qpc" if qpc else "dictionary-relay"
    for line in lines:
        match = re.search(rf"^{phase_prefix} name=(\S+) ms=([\d.]+) next=(\S+)", line)
        if match:
            clock += float(match[2])
            event = match[3]
            if event.startswith("enter:"):
                stack.append([event[6:], clock, 0.0])
            elif event.startswith("leave:") and stack and stack[-1][0] == event[6:]:
                name, start, children = stack.pop()
                elapsed = clock-start
                costs.setdefault(name, []).append(elapsed)
                self_costs.setdefault(name, []).append(elapsed-children)
                if stack:
                    stack[-1][2] += elapsed
            elif event.endswith("-begin"):
                boundaries[event[:-6]] = clock
            elif event.endswith("-end") and event[:-4] in boundaries:
                segments.setdefault(event[:-4], []).append(clock-boundaries.pop(event[:-4]))
        for pattern, label in ((r"request-lock .* qpc_wait_ms=([\d.]+)" if qpc else r"request-lock .* wait_ms=([\d.]+)", "host mutex-wait"),
                               (rf"^{relay_prefix} ms=([\d.]+)", "host dictionary-relay"),
                               (r"dictionary-source name=builtin-index ms=([\d.]+)", "host builtin-index"),
                               (r"dictionary-source name=skkserv-query ms=([\d.]+)", "host skkserv-query")):
            match = re.search(pattern, line)
            if match:
                segments.setdefault(label, []).append(float(match[1]))
for label, values in sorted(segments.items()):
    summary(label, values)
for label in sorted(costs, key=lambda name: sum(self_costs[name]), reverse=True):
    summary("inclusive "+label, costs[label])
    summary("self "+label, self_costs[label])
