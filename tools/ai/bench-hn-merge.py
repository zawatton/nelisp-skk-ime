#!/usr/bin/env python3
"""Time each frozen merge in one NeLisp process per mode, bounded to 5 min.

Native mode prepares GNU bytecode separately, then compiles, loads and replays
inside one NeLisp process. Call times exclude preparation, startup, comparison
and printing. Completed rows survive a timeout; totals include only those rows.
"""
import importlib.util
import json
from pathlib import Path


def main():
    spec = importlib.util.spec_from_file_location(
        "check_hn_merge", Path(__file__).with_name("check-hn-merge.py"))
    checker = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(checker)
    records = [r for line in (checker.ROOT / "tests/fixtures/host-native-nelisp/oracle.jsonl")
               .read_text(encoding="utf-8").splitlines()
               if (r := json.loads(line))["case"].startswith(
                   ("builtin-", "server-", "engine-", "quote-"))]
    modes = []
    for argv in ([], ["--native"]):
        result = {}
        try:
            checker.main(argv, benchmark=result)
        except (OSError, ValueError, RuntimeError, KeyError) as error:
            result["error"] = str(error)
        modes.append(result)
    print(f"{'record':24} {'bytes in':>9} {'interp ms':>12} {'native ms':>12}")
    for i, record in enumerate(records):
        cells = [f"{m['rows'][i][0]:.3f}" if i in m.get("rows", {}) else "--"
                 for m in modes]
        size = sum(len(bytes.fromhex(x)) for x in record["inputs_hex"])
        print(f"{record['case']:24} {size:9} {cells[0]:>12} {cells[1]:>12}")
    for name, mode in zip(("interpreted", "native"), modes):
        rows = mode.get("rows", {})
        print(f"TOTAL {name}: finished={len(rows)}/{len(records)} "
              f"matched={sum(ok for _, ok in rows.values())} "
              f"call_ms={sum(ms for ms, _ in rows.values()):.3f} "
              f"wall_s={mode.get('wall', 0):.3f} "
              f"timeout={mode.get('timeout', False)}")
        if "error" in mode:
            print(f"ERROR {name}: {mode['error']}")
    return int(any(len(m.get("rows", {})) != len(records) or
                   not all(ok for _, ok in m.get("rows", {}).values()) or
                   m.get("timeout") or "error" in m for m in modes))


if __name__ == "__main__":
    raise SystemExit(main())
