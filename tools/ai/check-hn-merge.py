#!/usr/bin/env python3
"""Compare all frozen merge bytes in one cold-loaded NeLisp process."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "engine/host-native-skk.el"
FUNCTIONS = ("host-native-merge-builtins", "host-native-merge-server-reply",
             "host-native-engine-dictionary-reply", "host-native-quote-engine-string")


def literal(value):
    """Emit a UTF-8 Lisp string, with fixed-width octal ASCII control escapes."""
    text = value.decode("utf-8", "strict")
    return '"' + ''.join('\\' + ch if ch in '\\"' else
                         f'\\{ord(ch):03o}' if ord(ch) < 32 or ord(ch) == 127
                         else ch for ch in text) + '"'


def mismatches(actual, expected):
    if len(actual) != len(expected):
        raise RuntimeError(f"result count {len(actual)} != {len(expected)}")
    return [i for i, (got, want) in enumerate(zip(actual, expected)) if got != want]


def main(argv=None, benchmark=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true",
                        help="Compile and fresh-load all four template native callables")
    args = parser.parse_args(argv)
    started = time.monotonic()
    # Native cache compilation/authentication dominates the cold-process gate.
    # The per-call benchmark separates that preparation from merge throughput.
    deadline = started + (300 if benchmark is not None else 180 if args.native else 115)
    records = [r for line in (ROOT / "tests/fixtures/host-native-nelisp/oracle.jsonl")
               .read_text(encoding="utf-8").splitlines()
               if (r := json.loads(line))["case"].startswith(
                   ("builtin-", "server-", "engine-", "quote-"))]
    if not records:
        raise RuntimeError("empty merge corpus")
    expected = [bytes.fromhex(r["result_hex"]) for r in records]
    runtime = Path(os.environ["HN_NATIVE_RUNTIME"]).resolve(strict=True)
    src = Path(os.environ["HN_NELISP_SRC"]).resolve(strict=True)
    cold = Path(str(runtime) + ".cold").resolve(strict=True)
    Path(str(runtime) + ".native-startup.el").resolve(strict=True)
    local = Path(os.environ["LOCALAPPDATA"]).resolve(strict=True)
    token = ("HN-MERGE-" + uuid.uuid4().hex).encode("ascii")
    if any(token in x for x in expected):
        raise RuntimeError("framing token collision")

    def run(command, env):
        try:
            result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True,
                                    timeout=max(0.01, deadline - time.monotonic()))
        except subprocess.TimeoutExpired as error:
            if benchmark is None:
                raise
            benchmark["timeout"] = True
            return error.stdout or b""
        if result.returncode:
            for line in result.stdout.decode("utf-8", "replace").splitlines():
                if line.startswith("HN-MERGE-COMPILE function="):
                    print(line)
            raise RuntimeError(f"exit={result.returncode}: " +
                               (result.stdout + result.stderr).decode("utf-8", "replace")[-2500:])
        return result.stdout

    # A new generation outside the checkout; remove all scratch files on exit.
    with tempfile.TemporaryDirectory(prefix="hn-merge-", dir=local) as tmp:
        work = Path(tmp)
        (work / "emacs").mkdir()
        source = work / SOURCE.name
        source.write_bytes(SOURCE.read_bytes())
        env = dict(os.environ, HN_MERGE_SOURCE=str(source),
                   HN_MERGE_ELC=str(source.with_suffix(".elc")),
                   XDG_CONFIG_HOME=str(work), TEMP=str(work), TMP=str(work),
                   TMPDIR=str(work), NELISP_NATIVE_CACHE=str(work / "cache"))
        command = [str(runtime), "--cold-load-from", str(cold)]
        for directory in ("lisp", "src", "scripts", "packages/nl-ffi/src",
                          "packages/nl-prelude/src"):
            command += ["-L", str(src / directory)]
        setup = '(load (getenv "HN_MERGE_SOURCE") nil t t)\n'
        if args.native:
            expression = ('(progn (require (quote nelisp-bytecode-compiler-input-dialect)) '
                          '(unless (eq (plist-get (nelisp-bytecode-compiler-input-dialect) :status) '
                          '(quote pinned)) (error "Requires pinned GNU bytecode dialect")) '
                          '(require (quote bytecomp)) '
                          '(unless (byte-compile-file (getenv "HN_MERGE_SOURCE")) '
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
(setq hn-merge-compile-failed nil)
'''
            setup += "(dolist (name '(" + " ".join(FUNCTIONS) + "))\n"
            setup += '''  (let ((f (cdr (assq name
                 (nelisp-bytecode-native-consumer-read-elc-functions
                  (getenv "HN_MERGE_ELC"))))))
    (unless f (error "Missing bytecode: %S" name))
    (if (string= (getenv "HN_MERGE_MODE") "compile")
        (condition-case err
            (let ((result (nelisp-native-cache-compile f)))
              (princ (format "HN-MERGE-COMPILE function=%S result=%S cache=%S\\n"
                             name result (nelisp-native-cache-file f))))
          (error (setq hn-merge-compile-failed t)
                 (princ (format "HN-MERGE-COMPILE function=%S signal=%S\\n"
                                name err))))
      (let ((file (nelisp-native-cache-file f))
            (_compiled (when (string= (getenv "HN_MERGE_MODE") "bench")
                         (nelisp-native-cache-compile f))))
        (fset name (or (nelisp-native-cache-load f)
                      (error "Missing native callable: %S cache=%S" name file)))))))
(when hn-merge-compile-failed (error "Native compilation failed; see per-function results"))
'''

        calls = []
        for index, record in enumerate(records):
            name = record["case"]
            inputs = [literal(bytes.fromhex(x)) for x in record["inputs_hex"]]
            if name.startswith("builtin-"):
                # The oracle's maps have only "key". Missing lookup supplies nil.
                argument = "nil" if name.startswith("builtin-missing-") else "'( " + " ".join(inputs) + ")"
                call = f"({FUNCTIONS[0]} {argument})"
            else:
                owner = 1 if name.startswith("server-") else 2 if name.startswith("engine-") else 3
                call = "(" + FUNCTIONS[owner] + " " + " ".join(inputs) + ")"
            if benchmark is None:
                calls.append(f'(princ "{token.decode()}\\n")\n(princ {call})\n')
            else:
                calls.append(f'(let* ((begin (float-time)) (value {call}) '
                             f'(seconds (- (float-time) begin))) '
                             f'(princ (format "{token.decode()} {index} %.9f %d\\n" '
                             f'seconds (if (equal value {literal(expected[index])}) 1 0))))\n')
        driver = work / "run.el"
        # GNU bytecode docstring references (#$) resolve against load-file-name.
        # The template recipe hashes that metadata: both processes must read
        # the .elc under the same driver filename, as the probe already does.
        driver.write_text(";;; -*- lexical-binding: t; -*-\n" + setup +
                          '(if (string= (getenv "HN_MERGE_MODE") "compile")\n'
                          '    (princ "HN-MERGE-COMPILE-PASS\\n")\n'
                          '  (progn\n' + "".join(calls) +
                          f'(princ "{token.decode()}\\n")))\n',
                          encoding="utf-8", newline="\n")
        if args.native and benchmark is None:
            compile_output = run(
                command + ["-l", str(driver)], dict(env, HN_MERGE_MODE="compile"))
            print(compile_output.decode("utf-8", "replace"), end="")
            print("HN-MERGE-CACHE files=" + json.dumps(
                sorted(p.relative_to(work / "cache").as_posix()
                       for p in (work / "cache").rglob("*") if p.is_file())))
            if b"HN-MERGE-COMPILE-PASS\n" not in compile_output:
                raise RuntimeError("missing native compile marker")
        replay_started = time.monotonic()
        output = run(command + ["-l", str(driver)], dict(
            env, HN_MERGE_MODE="bench" if benchmark is not None else "run"))
        if benchmark is not None:
            import re
            benchmark["rows"] = {
                int(i): (float(seconds) * 1000, matched == b"1")
                for i, seconds, matched in re.findall(
                    re.escape(token) + rb" (\d+) ([0-9.]+) ([01])\r?\n", output)}
            benchmark["wall"] = time.monotonic() - started
            return 1 if benchmark.get("timeout") else 0
        print(f"HN-MERGE-TIMING preparation_s={replay_started-started:.3f} "
              f"fresh_replay_s={time.monotonic()-replay_started:.3f}")
        framed = output.split(token + b"\n")
        if len(framed) != len(records) + 2:
            raise RuntimeError(f"missing result frames: expected {len(records)}")
        actual = framed[1:-1]
        # Use the very same byte comparator, with one corrupted golden output.
        corrupted = expected.copy()
        corrupted[0] += b"!"
        negative = mismatches(actual, corrupted)
        wrong = mismatches(actual, expected)
        control = negative == [0]
        mode = "native" if args.native else "interpreted"
        passed = not wrong and control
        print(f"HN-MERGE-{'PASS' if passed else 'FAIL'} mode={mode} "
              f"checked={len(records)} matched={len(records)-len(wrong)} "
              f"negative-control={'PASS (mutated output FAIL: 1)' if control else 'FAIL'} "
              f"seconds={time.monotonic()-started:.3f}")
        for i in wrong[:10]:
            print(f"FAIL case={records[i]['case']} expected-bytes={len(expected[i])} "
                  f"actual-bytes={len(actual[i])}")
        return 0 if passed else 1


if __name__ == "__main__":
    invoked = time.monotonic()
    try:
        raise SystemExit(main())
    except (KeyError, OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        import sys
        mode = "native" if "--native" in sys.argv else "interpreted"
        print(f"HN-MERGE-FAIL mode={mode} checked=0 negative-control=NOT-RUN "
              f"seconds={time.monotonic()-invoked:.3f} error={error}")
        raise SystemExit(1)
