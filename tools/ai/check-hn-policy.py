#!/usr/bin/env python3
"""Replay frozen numeric policies and HP2 bytes in one NeLisp process.

Native preparation runs separately; fresh replay shares the stable run.el
filename. Private cache generations stay under LOCALAPPDATA. No host is run.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "engine/host-policy.el"
FUNCTIONS = ("host-policy-decision", "host-policy-hp2-number", "host-policy-hp2-reply")
KINDS = dict(Config=1, Sources=2, failure=3, success=3, Cache=4,
             Publication=5, Learning=6, Replacement=7, Capacity=8,
             Intent=9, Order=10, Payload=11, CacheTtl=12)
GROUPS = {"SOURCES", "CACHE", "RESTART", "PUBLICATION", "LEARNING", "STARTUP"}


def literal(value):
    return '"' + ''.join('\\' + chr(ch) if ch in (34, 92) else
                         f'\\{ch:03o}' if ch < 32 or ch == 127 else chr(ch)
                         for ch in value) + '"'


def policy_inputs(record):
    """Reproduce snapshot locals in hn-oracle/extract.py, not algorithms.

    Goldens contain raw snapshot a/b/c, before native bool conversion and
    caller-specific input construction. Passing them directly is incorrect.
    """
    name = record["case"].split("/")[1]
    a, b, c = (int(bytes.fromhex(x)) for x in record["inputs_hex"])
    flag = lambda x: int(x != 0)
    if name == "Config":
        values = flag(a), flag(b), c
    elif name == "Sources":
        values = flag(a), flag(b), c
    elif name == "Order":
        values = flag(a), 1, 0
    elif name == "CacheTtl":
        values = flag(a), 0, 0
    elif name == "Cache":
        values = flag(a), b, c
    elif name == "Capacity":
        values = 256 if a >= 256 else 0, int(a > 0 and b != 0), c
    elif name in ("failure", "success"):
        values = a, int(name == "success"), c
    elif name == "Replacement":
        values = 1, flag(b), flag(c)
    elif name == "Intent":
        values = flag(a), flag(b), c
    elif name == "Payload":
        values = flag(a), flag(b), flag(c)
    elif name == "Learning":
        values = flag(a), 1, c
    else:
        raise ValueError(f"unknown policy case {record['case']}")
    return KINDS[name], *values


def digits(value, width):
    if not 0 <= value < 64 ** width:
        raise ValueError("HP2 field overflow")
    return bytes(32 + ((value >> (6 * i)) & 63) for i in reversed(range(width)))


def query(index, inputs):
    kind, a, b, c = inputs
    scalar = b if kind == 4 else a if kind in (3, 8) else 0
    return (b"HP2Q" + digits(index, 11) + bytes((32 + kind, 32 + min(a, 2),
            32 + min(b, 2), 32 + min(c, 2))) + digits(scalar, 3) + b"\n")


def mismatches(actual, expected):
    if len(actual) != len(expected):
        raise RuntimeError(f"result count {len(actual)} != {len(expected)}")
    return [i for i, (got, want) in enumerate(zip(actual, expected)) if got != want]


def missing_cases(records):
    raw = {name: [tuple(int(bytes.fromhex(x)) for x in r["inputs_hex"])
                  for r in records if r["case"].endswith("/" + name)]
           for name in KINDS}
    present = {
        "hit TTL 60 s": any(a and b == 60000 for a, b, _ in raw["Cache"]),
        "miss TTL 2 s": any(not a and b == 2000 for a, b, _ in raw["Cache"]),
        "capacity 256": any(a == 256 for a, _, _ in raw["Capacity"]),
        "backoff 1-30 s": all(any(a == v for a, _, _ in raw["failure"])
                                 for v in (1000, 15000, 30000)),
        "publication immediate and 200 ms boundary": all(any(c == v for _, _, c in raw["Intent"])
                                                           for v in (0, 1, 2)),
        "durable learning ACK ordering": False,
        "legacy Publication kind 5 (no production caller)": bool(raw["Publication"]),
        "frozen HP2 Q/R byte records": any(bytes.fromhex(x).startswith(b"HP2Q")
                                           for r in records for x in r["inputs_hex"]),
        "host cold/memo miss, expiry, generation change and child retirement": False,
    }
    return [name for name, found in present.items() if not found]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true")
    args = parser.parse_args(argv)
    started = time.monotonic()
    deadline = started + (180 if args.native else 115)
    records = [r for line in (ROOT / "tests/fixtures/host-native-nelisp/oracle.jsonl")
               .read_text(encoding="utf-8").splitlines()
               if (r := json.loads(line))["case"].split("/")[0] in GROUPS]
    if not records or not GROUPS <= {r["case"].split("/")[0] for r in records}:
        raise RuntimeError("missing numeric policy group")
    print("HN-POLICY-ORACLE missing=" + json.dumps(missing_cases(records)))
    runtime = Path(os.environ["HN_NATIVE_RUNTIME"]).resolve(strict=True)
    src = Path(os.environ["HN_NELISP_SRC"]).resolve(strict=True)
    cold = Path(str(runtime) + ".cold").resolve(strict=True)
    Path(str(runtime) + ".native-startup.el").resolve(strict=True)
    local = Path(os.environ["LOCALAPPDATA"]).resolve(strict=True)
    token = ("HN-POLICY-" + uuid.uuid4().hex).encode("ascii")

    def run(command, env):
        result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True,
                                timeout=max(0.01, deadline - time.monotonic()))
        if result.returncode:
            for line in result.stdout.decode("utf-8", "replace").splitlines():
                if line.startswith("HN-POLICY-COMPILE function="):
                    print(line)
            raise RuntimeError(f"exit={result.returncode}: " +
                               (result.stdout + result.stderr).decode("utf-8", "replace")[-2500:])
        return result.stdout

    with tempfile.TemporaryDirectory(prefix="hn-policy-", dir=local) as tmp:
        work = Path(tmp)
        (work / "emacs").mkdir()
        source = work / SOURCE.name
        source.write_bytes(SOURCE.read_bytes())
        env = dict(os.environ, HN_POLICY_SOURCE=str(source),
                   HN_POLICY_ELC=str(source.with_suffix(".elc")),
                   DDSKK_HOST_POLICY_UNIT_ONLY="1",
                   XDG_CONFIG_HOME=str(work), TEMP=str(work), TMP=str(work),
                   TMPDIR=str(work), NELISP_NATIVE_CACHE=str(work / "cache"))
        command = [str(runtime), "--cold-load-from", str(cold)]
        for directory in ("lisp", "src", "scripts", "packages/nl-ffi/src",
                          "packages/nl-prelude/src"):
            command += ["-L", str(src / directory)]
        setup = '(load (getenv "HN_POLICY_SOURCE") nil t t)\n'
        if args.native:
            expression = ('(progn (require (quote nelisp-bytecode-compiler-input-dialect)) '
                          '(unless (eq (plist-get (nelisp-bytecode-compiler-input-dialect) :status) '
                          '(quote pinned)) (error "Requires pinned GNU bytecode dialect")) '
                          '(require (quote bytecomp)) '
                          '(unless (byte-compile-file (getenv "HN_POLICY_SOURCE")) '
                          '(error "Byte compilation failed")))')
            run(["emacs", "-Q", "--batch", "--init-directory", str(work),
                 "-L", str(src / "lisp"), "--eval", expression], dict(env, HOME=str(work)))
            setup += '''(require 'nelisp-native-cache)
(require 'nelisp-bytecode-native-consumer)
(require 'nelisp-native-template-stencils)
(nelisp-native-template-select-target)
(unless (file-exists-p nelisp-native-template--library-path)
  (setq nelisp-native-template--library-path
        (expand-file-name "templates/nelisp-native-template-win64.nelst"
                          (getenv "HN_NELISP_SRC"))))
(setq nelisp-native-cache-backend 'template)
(setq hn-policy-compile-failed nil)
'''
            setup += "(dolist (name '(" + " ".join(FUNCTIONS) + "))\n"
            setup += '''  (let ((f (cdr (assq name
                 (nelisp-bytecode-native-consumer-read-elc-functions
                  (getenv "HN_POLICY_ELC"))))))
    (unless f (error "Missing bytecode: %S" name))
    (if (string= (getenv "HN_POLICY_MODE") "compile")
        (condition-case err
            (let ((result (nelisp-native-cache-compile f)))
              (princ (format "HN-POLICY-COMPILE function=%S result=%S cache=%S\\n"
                             name result (nelisp-native-cache-file f))))
          (error (setq hn-policy-compile-failed t)
                 (princ (format "HN-POLICY-COMPILE function=%S signal=%S\\n"
                                name err))))
      (let ((file (nelisp-native-cache-file f)))
        (fset name (or (nelisp-native-cache-load f)
                      (error "Missing native callable: %S cache=%S" name file)))))))
(when hn-policy-compile-failed (error "Native compilation failed; see per-function results"))
'''


        expected, calls = [], []
        for index, record in enumerate(records, 1):
            inputs = policy_inputs(record)
            want = bytes.fromhex(record["result_hex"])
            frame = query(index, inputs)
            reply = b"HP2R" + frame[4:15] + digits(int(want), 3) + b"\n"
            if len(frame) != 23 or len(reply) != 19:
                raise RuntimeError("wrong HP2 envelope size")
            expected.extend((want + b"\n", reply))
            calls.append('(princ (number-to-string (host-policy-decision ' +
                         ' '.join(map(str, inputs)) + '))) (princ "\\n")\n' +
                         '(princ (host-policy-hp2-reply ' + literal(frame) + ' nil))\n')
        # One stable driver preserves GNU #$ metadata across native preparation
        # and fresh loading. All numeric/codec calls run in ONE replay process.
        driver = work / "run.el"
        driver.write_text(";;; -*- lexical-binding: t; -*-\n" + setup +
                          '(if (string= (getenv "HN_POLICY_MODE") "compile")\n'
                          '    (princ "HN-POLICY-COMPILE-PASS\\n")\n'
                          '  (progn\n' + f'(princ "{token.decode()}\\n")\n' +
                          ''.join(calls) + f'(princ "{token.decode()}\\n")))\n',
                          encoding="utf-8", newline="\n")
        if args.native:
            compiled = run(command + ["-l", str(driver)], dict(env, HN_POLICY_MODE="compile"))
            print(compiled.decode("utf-8", "replace"), end="")
            print("HN-POLICY-CACHE files=" + json.dumps(
                sorted(p.relative_to(work / "cache").as_posix()
                       for p in (work / "cache").rglob("*") if p.is_file())))
            if b"HN-POLICY-COMPILE-PASS\n" not in compiled:
                raise RuntimeError("missing native compile marker")
        output = run(command + ["-l", str(driver)], dict(env, HN_POLICY_MODE="run"))
        framed = output.split(token + b"\n")
        if len(framed) != 3 or framed[2].strip():
            raise RuntimeError("invalid replay framing")
        payload, cursor, actual = framed[1], 0, []
        for _ in records:
            end = payload.index(b"\n", cursor) + 1
            actual.append(payload[cursor:end])
            actual.append(payload[end:end+19])
            cursor = end + 19
        if cursor != len(payload):
            raise RuntimeError("extra or truncated replay output")
        wrong = mismatches(actual, expected)
        # Same exact comparator rejects corrupt numeric AND 19-byte frame data.
        negative = True
        for offset in (0, 1):
            corrupt = expected.copy()
            changed = bytearray(corrupt[offset])
            changed[0] ^= 1
            corrupt[offset] = bytes(changed)
            negative &= offset not in wrong and mismatches(actual, corrupt) == sorted(wrong + [offset])
        for index in wrong[:20]:
            print(f"FAIL case={records[index//2]['case']} record={index//2} "
                  f"output={'decision' if index%2 == 0 else 'HP2R'} "
                  f"got={actual[index].hex()} want={expected[index].hex()}")
        passed = not wrong and negative
        print(f"HN-POLICY-{'PASS' if passed else 'FAIL'} mode={'native' if args.native else 'interpreted'} "
              f"records={len(records)} groups=5 config=1 exact={len(expected)-len(wrong)}/{len(expected)} "
              f"derived_hp2_frames={len(records)} frozen_hp2_frames=0 replay_processes=1 "
              f"negative_controls={'PASS (numeric/frame corruption rejected)' if negative else 'FAIL'} "
              f"seconds={time.monotonic()-started:.3f}")
        return 0 if passed else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (KeyError, IndexError, OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"HN-POLICY-FAIL error={error}")
        raise SystemExit(1)
