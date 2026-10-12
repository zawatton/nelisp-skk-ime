#!/usr/bin/env python3
"""HN1 isolated native merge smoke; temporary files only, no IME or dictionary IO."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = r''';;; -*- lexical-binding: t; -*-
(defun hn-probe-merge (n)
  (let ((i 0) (count 0))
    (while (< i n)
      ;; Synthetic candidate IDs repeat in pairs: 0,0,1,1,2,2,...
      (when (= (% i 2) 0) (setq count (1+ count)))
      (setq i (1+ i)))
    count))
'''
DRIVER = r''';;; -*- lexical-binding: t; -*-
(require 'nelisp-native-cache)
(require 'nelisp-bytecode-native-consumer)
(let* ((nelisp-native-cache-backend 'in-house)
       (f (cdr (assq 'hn-probe-merge
                    (nelisp-bytecode-native-consumer-read-elc-functions
                     (getenv "HN_PROBE_ELC"))))))
  (unless f (error "Missing GNU bytecode function"))
  (if (equal (getenv "HN_PROBE_MODE") "compile")
      (progn (nelisp-native-cache-compile f) (princ "HN-COMPILE-PASS\n"))
    (let* ((mode (getenv "HN_PROBE_MODE"))
           (fn (if (equal mode "native")
                   (or (nelisp-native-cache-load f) (error "No native mapping"))
                 (load (getenv "HN_PROBE_SOURCE") nil t t)
                 (symbol-function 'hn-probe-merge)))
           (n 2000))
      (garbage-collect)
      (let* ((start (float-time)) (value (funcall fn n))
             (elapsed (- (float-time) start)))
        (unless (= value 1000)
          (error "Wrong merge result %S" value))
        (princ (format "HN-TIME mode=%s seconds=%.6f value=%S\n"
                       mode elapsed value))))))
'''


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--strings", action="store_true",
                        help="Known-red string equality dedup decision (no proof bypass)")
    args = parser.parse_args()
    started = time.monotonic()
    deadline = started + 270  # Entire compiler E2E smoke stays below five minutes.
    runtime = Path(os.environ["HN_NATIVE_RUNTIME"]).resolve(strict=True)
    src = Path(os.environ["HN_NELISP_SRC"]).resolve(strict=True)
    cold = Path(str(runtime) + ".cold").resolve(strict=True)
    startup = Path(str(runtime) + ".native-startup.el").resolve(strict=True)
    report = {"runtime_sha256": digest(runtime), "cold_sha256": digest(cold),
              "startup_sha256": digest(startup), "iterations": 2000,
              "kernel": "string-equality" if args.strings else "numeric-id-dedup"}

    def run(command, env):
        result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True,
                                timeout=max(0.01, deadline - time.monotonic()))
        output = result.stdout.decode("utf-8", "replace")
        if result.returncode:
            raise RuntimeError(f"exit={result.returncode}: {output[-1500:]} "
                               + result.stderr.decode("utf-8", "replace")[-1500:])
        return output

    # Keep all scratch writes inside the authorized tree; cleanup even on failure.
    with tempfile.TemporaryDirectory(prefix="hn-probe-", dir=ROOT / "tools/ai") as tmp:
        work = Path(tmp)
        source, driver = work / "fixture.el", work / "driver.el"
        (work / "emacs").mkdir()
        fixture, driver_text = FIXTURE, DRIVER
        if args.strings:
            fixture = (";;; -*- lexical-binding: t; -*-\n"
                       "(defun hn-probe-merge (left right) (if (equal left right) 1 2))\n")
            driver_text = DRIVER.replace("(value (funcall fn n))",
                                         '(value (+ (funcall fn "alpha" "alpha") '
                                         '(funcall fn "alpha" "beta")))').replace(
                                             "(= value 1000)", "(= value 3)")
        source.write_text(fixture, encoding="utf-8", newline="\n")
        driver.write_text(driver_text, encoding="utf-8", newline="\n")
        env = dict(os.environ, HN_PROBE_SOURCE=str(source),
                   HN_PROBE_ELC=str(source.with_suffix(".elc")),
                   XDG_CONFIG_HOME=str(work),
                   TEMP=str(work), TMP=str(work), TMPDIR=str(work),
                   NELISP_NATIVE_CACHE=str(work / "cache"))
        expression = ('(progn (require (quote nelisp-bytecode-compiler-input-dialect)) '
                      '(unless (eq (plist-get (nelisp-bytecode-compiler-input-dialect) :status) '
                      '(quote pinned)) (error "Requires pinned GNU bytecode dialect")) '
                      '(require (quote bytecomp)) '
                      '(unless (byte-compile-file (getenv "HN_PROBE_SOURCE")) '
                      '(error "Byte compilation failed")))')
        # Give only GNU Emacs an isolated home for startup's directory checks.
        # The parent environment and NeLisp runtime environment are unchanged.
        gnu_env = dict(env, HOME=str(work))
        run(["emacs", "-Q", "--batch", "--init-directory", str(work),
             "-L", str(src / "lisp"), "--eval", expression], gnu_env)
        command = [str(runtime), "--cold-load-from", str(cold)]
        for directory in ("lisp", "src", "scripts", "packages/nl-ffi/src", "packages/nl-prelude/src"):
            command += ["-L", str(src / directory)]
        command += ["-l", str(driver)]
        compile_start = time.monotonic()
        if "HN-COMPILE-PASS" not in run(command, dict(env, HN_PROBE_MODE="compile")):
            raise RuntimeError("Missing compile marker")
        report["compile_seconds"] = round(time.monotonic() - compile_start, 6)
        for mode in ("native", "interpreted"):
            output = run(command, dict(env, HN_PROBE_MODE=mode))
            match = re.search(r"HN-TIME mode=" + mode + r" seconds=([0-9.]+) value=(.+)", output)
            if not match:
                raise RuntimeError("Missing timing/value marker: " + output[-1500:])
            report[mode + "_seconds"] = float(match[1])
            report[mode + "_value"] = match[2]
        if report["native_value"] != report["interpreted_value"]:
            raise RuntimeError("Cross-mode parity failure")
    report["ratio"] = (report["native_seconds"] / report["interpreted_seconds"]
                       if report["interpreted_seconds"] else None)
    report["wall_seconds"] = round(time.monotonic() - started, 6)
    report["passed"] = True  # Capability + exact value; no invented speed threshold.
    print("HN-NATIVE-PROBE-PASS " + json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (KeyError, OSError, RuntimeError, subprocess.TimeoutExpired) as exc:
        print("HN-NATIVE-PROBE-FAIL " + str(exc))
        raise SystemExit(1)
