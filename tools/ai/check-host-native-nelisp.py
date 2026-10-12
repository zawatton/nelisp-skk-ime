#!/usr/bin/env python3
"""Read-only HN1 specification/ledger structure check, not runtime acceptance."""
import argparse
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
HEADINGS = (
    "Decision and ownership boundary",
    "Migration 1: candidate merge and reply conversion",
    "Migration 2: built-in SKK-JISYO parser",
    "Migration 3: startup selection and environment policy",
    "Migration 4: retire five duplicate native policy paths",
    "IPC and latency budgets",
    "Windows native compilation and cache",
    "HN1 probe receipt",
    "Qualification, rollback and open questions",
)


def check(document, ledger):
    errors = []
    if "\r" in document or "\r" in ledger:
        errors.append("LF line endings required")
    if not 0 < len(document.splitlines()) < 250:
        errors.append("Design must be nonempty and below 250 lines")
    sections = dict(re.findall(r"^\* ([^\n]+)\n(.*?)(?=^\* |\Z)", document, re.M | re.S))
    for heading in HEADINGS:
        if not sections.get(heading, "").strip():
            errors.append("Missing section: " + heading)
    for heading in HEADINGS[1:5]:
        body = sections.get(heading, "")
        for token in ("Current", "Target", "engine/", "windows/host/", "Latency:",
                      "Fallback", "Parity:", "Rollback", "compil"):
            if token not in body:
                errors.append(heading + ": missing " + token)
    for token in ("HN_NATIVE_RUNTIME", "HN_NELISP_SRC", "nelisp-native-cache-compile",
                  "nelisp-native-cache-load", "HP2", "p99 <=10 ms", "max <=50 ms",
                  "zero host/engine/policy waits", "outside the Lisp heap"):
        if token not in document:
            errors.append("Missing shared contract: " + token)
    if re.search(r"[A-Za-z]:[\\/]", document + ledger):
        errors.append("Machine absolute path found")
    stages = re.findall(r"^\* (S\d+) ([^\n]+)\n(.*?)(?=^\* |\Z)", ledger, re.M | re.S)
    if [stage[0] for stage in stages] != ["S1", "S2", "S3", "S4", "S5"]:
        errors.append("Expected stages S1..S5")
    count = 0
    for stage, _, body in stages:
        criteria = re.findall(r"^\*\* (S\d+\.\d+) ([^\n]+)\n(.*?)(?=^\*\* |\Z)",
                              body, re.M | re.S)
        count += len(criteria)
        if len(criteria) < 3 or "End to end:" not in criteria[-1][1]:
            errors.append(stage + ": at least three criteria, last end-to-end required")
        for index, (identifier, _, checks) in enumerate(criteria, 1):
            if identifier != f"{stage}.{index}":
                errors.append("Invalid criterion ID " + identifier)
            lines = re.findall(r"^(cmd: .+|evidence: .+|pending)$", checks, re.M)
            if not lines or ("pending" in lines and len(lines) != 1):
                errors.append(identifier + ": invalid check lines")
    return errors, count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--negative-control", action="store_true")
    args = parser.parse_args()
    document = (ROOT / "docs/design/host-native-nelisp.org").read_bytes().decode("utf-8")
    ledger = (ROOT / "tools/ai/host-native-nelisp-progress.org").read_bytes().decode("utf-8")
    if args.negative_control:
        anchor = "* Windows native compilation and cache\n"
        assert document.count(anchor) == 1
        document = document.replace(anchor, "* Missing contract\n", 1)
    errors, count = check(document, ledger)
    for error in errors:
        print("FAIL " + error)
    print(f"HN1-DESIGN-{'FAIL' if errors else 'PASS'} sections={len(HEADINGS)} "
          f"criteria={count} lines={len(document.splitlines())}")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
