#!/usr/bin/env python3
"""Replay every frozen startup snapshot/operation in one NeLisp process.

No host, registry, dictionaries or production process configuration is accessed.
Native preparation and fresh replay share one stable driver filename; private
cache generations stay under LOCALAPPDATA and retain compiler trust checks.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "engine/host-native-startup.el"
FUNCTIONS = ("host-native-select-engine", "host-native-child-env-plan")
BRIDGES = (
    ("UserJisyoPath", "DDSKK_USER_JISYO"),
    ("UserJisyoBatch", "DDSKK_USER_JISYO_SAVE_BATCH_SIZE"),
    ("BehaviorOkuriStrictly", "DDSKK_OKURI_STRICTLY"),
    ("BehaviorDeleteOkuriOnCancel", "DDSKK_DELETE_OKURI_ON_CANCEL"),
    ("BehaviorAddKatakanaCand", "DDSKK_SEARCH_KATAKANA"),
    ("BehaviorLearnDisabled", "DDSKK_LEARN_DISABLED"),
)

def literal(value):
    """Emit a UTF-8 Lisp string, with fixed-width octal ASCII control escapes."""
    text = value.decode("utf-8", "strict")
    return '"' + ''.join('\\' + ch if ch in '\\"' else
                         f'\\{ord(ch):03o}' if ord(ch) < 32 or ord(ch) == 127
                         else ch for ch in text) + '"'


def lisp(value):
    if value is None or value is False:
        return "nil"
    if value is True:
        return "t"
    if isinstance(value, str):
        return literal(value.encode("utf-8"))
    if isinstance(value, int):
        return str(value)
    return "(" + " ".join(lisp(x) for x in value) + ")"


def wide(raw):
    if len(raw) % 2:
        raw += b"\0"
    return raw.decode("utf-16le", "strict").split("\0", 1)[0]


def snapshot(record):
    """Decode the oracle's mixed ASCII/UTF16 framing, preserving raw size/type.

    RegQueryValueEx owners use zero-filled buffers and a null type argument.
    Do not enforce REG_SZ/REG_DWORD: wrong types that fit are accepted by C++.
    """
    inputs = [bytes.fromhex(x) for x in record["inputs_hex"]]
    key, framework, expansion = map(int, inputs[0].decode("ascii").split(","))
    inherited, registry = [], []
    for raw in inputs[2:]:
        if raw.startswith(b"env:"):
            # '=' is ONE ASCII byte between two UTF16 strings in this oracle.
            pos = next(i for i in range(4, len(raw), 2) if raw[i:i+1] == b"=")
            value = raw[pos+1:].decode("utf-16le")
            inherited.append([raw[4:pos].decode("utf-16le"), value,
                              len(raw[pos+1:]) // 2])
        elif raw.startswith(b"reg:"):
            pos = next(i for i in range(4, len(raw), 2) if raw[i:i+1] == b":")
            end = raw.index(b":", pos+1)
            data = raw[end+1:]
            registry.append([raw[4:pos].decode("utf-16le"),
                             ":present", True, ":type", int(raw[pos+1:end]),
                             ":size", len(data), ":text", wide(data),
                             ":dword", int.from_bytes(data[:4].ljust(4, b"\0"), "little")])
        else:
            raise RuntimeError("unknown startup input framing")
    entry = next((v for n, v, _ in inherited if n == "DDSKK_NELISP_ENTRY"), "")
    return dict(inherited=inherited, registry=registry, key=bool(key),
                framework=bool(framework), expansion=bool(expansion),
                expanded=inputs[1].decode("utf-16le"),
                native=0 < len(entry.encode("utf-16le")) // 2 < 16 and entry.lower() == "native")


def snapshot_lisp(item):
    # Registry is an alist whose cdr is a plist. Keywords must remain symbols.
    registry = "(" + " ".join("(" + lisp(v[0]) + " " + " ".join(
        x if i % 2 == 0 else lisp(x) for i, x in enumerate(v[1:])) + ")"
        for v in item["registry"]) + ")"
    return ("(list :inherited '" + lisp(item["inherited"]) +
            " :registry '" + registry + " :registry-present " + lisp(item["key"]) +
            " :framework-available " + lisp(item["framework"]) +
            " :expansion-ok " + lisp(item["expansion"]) +
            " :expanded-path " + lisp(item["expanded"]) +
            " :native-entry " + lisp(item["native"]) +
            " :requested-present nil :prior-imported hn-startup-prior)")


def missing_cases(records, items):
    """Report corpus gaps; do not synthesize C++ evidence or refresh goldens."""
    names = {r["case"] for r in records}
    operations = [bytes.fromhex(r["result_hex"]).decode("utf-16le")
                  for r in records if r["case"].startswith("startup-operation-")]
    categories = {
        "successive reloads": all("startup-" + str(i) in names for i in (1, 2, 3)),
        "imported-variable removal": any(x.startswith("remove:") for x in operations),
        "wrong registry types": any(v[4] not in (1, 2, 4) for s in items for v in s["registry"]),
        "expansion failure": any(not s["expansion"] for s in items),
        "missing framework": any(not s["framework"] for s in items),
        "empty values": any(v == "" for s in items for _, v, _ in s["inherited"]),
        "long values": any(v[6] > 65536 or (v[0] == "Engine" and v[6] > 126)
                           for s in items for v in s["registry"]),
    }
    return [name for name, present in categories.items() if not present]


def mismatches(actual, expected):
    if len(actual) != len(expected):
        raise RuntimeError(f"result count {len(actual)} != {len(expected)}")
    return [i for i, (got, want) in enumerate(zip(actual, expected)) if got != want]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true")
    args = parser.parse_args(argv)
    started = time.monotonic()
    deadline = started + (270 if args.native else 115)
    records = [r for line in (ROOT / "tests/fixtures/host-native-nelisp/oracle.jsonl")
               .read_text(encoding="utf-8").splitlines()
               if (r := json.loads(line))["case"].startswith("startup-")]
    snapshots = [r for r in records if re.fullmatch(r"startup-\d+", r["case"])]
    if not snapshots:
        raise RuntimeError("empty startup corpus")
    items = [snapshot(r) for r in snapshots]
    missing = missing_cases(records, items)
    print("HN-STARTUP-ORACLE missing=" + json.dumps(missing) +
          (" (follow-up oracle extension required)" if missing else ""))
    runtime = Path(os.environ["HN_NATIVE_RUNTIME"]).resolve(strict=True)
    src = Path(os.environ["HN_NELISP_SRC"]).resolve(strict=True)
    cold = Path(str(runtime) + ".cold").resolve(strict=True)
    Path(str(runtime) + ".native-startup.el").resolve(strict=True)
    local = Path(os.environ["LOCALAPPDATA"]).resolve(strict=True)
    token = ("HN-STARTUP-" + uuid.uuid4().hex).encode("ascii")

    def run(command, env):
        result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True,
                                timeout=max(0.01, deadline - time.monotonic()))
        if result.returncode:
            for line in result.stdout.decode("utf-8", "replace").splitlines():
                if line.startswith("HN-STARTUP-COMPILE function="):
                    print(line)
            raise RuntimeError(f"exit={result.returncode}: " +
                               (result.stdout + result.stderr).decode("utf-8", "replace")[-2500:])
        return result.stdout

    with tempfile.TemporaryDirectory(prefix="hn-startup-", dir=local) as tmp:
        work = Path(tmp)
        (work / "emacs").mkdir()
        source = work / SOURCE.name
        source.write_bytes(SOURCE.read_bytes())
        env = dict(os.environ, HN_STARTUP_SOURCE=str(source),
                   HN_STARTUP_ELC=str(source.with_suffix(".elc")),
                   XDG_CONFIG_HOME=str(work), TEMP=str(work), TMP=str(work),
                   TMPDIR=str(work), NELISP_NATIVE_CACHE=str(work / "cache"))
        command = [str(runtime), "--cold-load-from", str(cold)]
        for directory in ("lisp", "src", "scripts", "packages/nl-ffi/src",
                          "packages/nl-prelude/src"):
            command += ["-L", str(src / directory)]
        setup = '(load (getenv "HN_STARTUP_SOURCE") nil t t)\n'
        if args.native:
            expression = ('(progn (require (quote nelisp-bytecode-compiler-input-dialect)) '
                          '(unless (eq (plist-get (nelisp-bytecode-compiler-input-dialect) :status) '
                          '(quote pinned)) (error "Requires pinned GNU bytecode dialect")) '
                          '(require (quote bytecomp)) '
                          '(unless (byte-compile-file (getenv "HN_STARTUP_SOURCE")) '
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
(setq hn-startup-compile-failed nil)
'''
            setup += "(dolist (name '(" + " ".join(FUNCTIONS) + "))\n"
            setup += '''  (let ((f (cdr (assq name
                 (nelisp-bytecode-native-consumer-read-elc-functions
                  (getenv "HN_STARTUP_ELC"))))))
    (unless f (error "Missing bytecode: %S" name))
    (if (string= (getenv "HN_STARTUP_MODE") "compile")
        (condition-case err
            (let ((result (nelisp-native-cache-compile f)))
              (princ (format "HN-STARTUP-COMPILE function=%S result=%S cache=%S\\n"
                             name result (nelisp-native-cache-file f))))
          (error (setq hn-startup-compile-failed t)
                 (princ (format "HN-STARTUP-COMPILE function=%S signal=%S\\n"
                                name err))))
      (let ((file (nelisp-native-cache-file f)))
        (fset name (or (nelisp-native-cache-load f)
                      (error "Missing native callable: %S cache=%S" name file)))))))
(when hn-startup-compile-failed (error "Native compilation failed; see per-function results"))
'''

        replay = '''(setq hn-startup-prior nil)
(defun hn-startup-field (value)
  (princ (format "%d\\n" (string-bytes value))) (princ value))
'''
        for record, item in zip(snapshots, items):
            # The C++ harness resets static imports except in the 1 -> 2 -> 3 lineage.
            number = int(record["case"].removeprefix("startup-"))
            if number not in (2, 3):
                replay += "(setq hn-startup-prior nil)\n"
            replay += "(let* ((snapshot " + snapshot_lisp(item) + ''')
                         (selection (host-native-select-engine snapshot))
                         (plan (host-native-child-env-plan snapshot))
                         (ops (plist-get plan :ops)))
  (hn-startup-field (plist-get selection :child-engine-id))
  (hn-startup-field (symbol-name (plist-get selection :runner)))
  (hn-startup-field (symbol-name (plist-get selection :entry)))
  (princ (format "%d\\n" (length ops)))
  (dolist (op ops)
    (hn-startup-field (symbol-name (car op)))
    (hn-startup-field (cadr op))
    (hn-startup-field (or (nth 2 op) "")))
  (setq hn-startup-prior (plist-get plan :imported)))
'''
        driver = work / "run.el"
        # Stable filename preserves GNU #$ docstring metadata and recipe hashes.
        driver.write_text(";;; -*- lexical-binding: t; -*-\n" + setup +
                          '(if (string= (getenv "HN_STARTUP_MODE") "compile")\n'
                          '    (princ "HN-STARTUP-COMPILE-PASS\\n")\n'
                          '  (progn\n' + f'(princ "{token.decode()}\\n")\n' + replay +
                          f'(princ "{token.decode()}\\n")))\n',
                          encoding="utf-8", newline="\n")
        if args.native:
            compiled = run(command + ["-l", str(driver)], dict(env, HN_STARTUP_MODE="compile"))
            print(compiled.decode("utf-8", "replace"), end="")
            print("HN-STARTUP-CACHE files=" + json.dumps(
                sorted(p.relative_to(work / "cache").as_posix()
                       for p in (work / "cache").rglob("*") if p.is_file())))
            if b"HN-STARTUP-COMPILE-PASS\n" not in compiled:
                raise RuntimeError("missing native compile marker")
        output = run(command + ["-l", str(driver)], dict(env, HN_STARTUP_MODE="run"))
        framed = output.split(token + b"\n")
        if len(framed) != 3 or framed[2].strip():
            raise RuntimeError("invalid replay framing")
        payload, cursor = framed[1], 0

        def integer():
            nonlocal cursor
            end = payload.index(b"\n", cursor)
            value = int(payload[cursor:end])
            cursor = end + 1
            if value < 0:
                raise RuntimeError("negative frame size")
            return value

        def field():
            nonlocal cursor
            size = integer()
            value = payload[cursor:cursor+size]
            if len(value) != size:
                raise RuntimeError("short field")
            cursor += size
            return value.decode("utf-8", "strict")

        by_case, operations = {}, {}
        for record, item in zip(snapshots, items):
            child_id, runner, entry = field(), field(), field()
            if runner not in ("ddskk", "framework") or entry not in ("native", "load"):
                raise RuntimeError("invalid runner/entry enum")
            environment = {n: v for n, v, _ in item["inherited"]}
            ops = []
            for _ in range(integer()):
                op, name, value = field(), field(), field()
                if name not in {n for _, n in BRIDGES} | {"NELISP_IME_ENGINE"}:
                    raise RuntimeError("non-allowlisted environment operation")
                if op == "remove":
                    environment.pop(name, None)
                    text = "remove:" + name
                elif op == "set":
                    environment[name] = value
                    text = "set:" + name + "=" + value
                else:
                    raise RuntimeError("invalid environment operation")
                if name != "NELISP_IME_ENGINE":
                    ops.append(text.encode("utf-16le"))
            if environment.get("NELISP_IME_ENGINE") != child_id:
                raise RuntimeError("child ID/plan mismatch")
            block = "".join(n + "=" + v + "\0" for n, v in
                            sorted(environment.items(), key=lambda pair: pair[0].lower())) + "\0"
            script = "engine/ddskk-engine-stdio.el" if runner == "ddskk" else "framework/nelisp-ime-stdio.el"
            by_case[record["case"]] = (child_id.encode("utf-16le") + b"|" +
                                      script.encode("utf-16le") + b"|" + entry.encode("ascii") +
                                      b"|" + block.encode("utf-16le"))
            operations[record["case"].replace("startup-", "startup-operation-")] = ops
        if cursor != len(payload):
            raise RuntimeError("extra replay output")
        actual = []
        offsets = {}
        for record in records:
            name = record["case"]
            if name in by_case:
                actual.append(by_case[name])
            else:
                index = offsets.get(name, 0)
                actual.append(operations[name][index])
                offsets[name] = index + 1
        if any(len(ops) != offsets.get(name, 0) for name, ops in operations.items()):
            raise RuntimeError("extra startup operations")
        expected = [bytes.fromhex(r["result_hex"]) for r in records]
        wrong = mismatches(actual, expected)
        corrupted = expected.copy()
        corrupted[0] += b"!"
        negative = mismatches(actual, corrupted) == sorted(set(wrong + [0])) and 0 not in wrong
        for index in wrong:
            print(f"FAIL case={records[index]['case']} record={index}")
        passed = not wrong and negative and not missing
        print(f"HN-STARTUP-{'PASS' if passed else 'FAIL'} mode={'native' if args.native else 'interpreted'} "
              f"snapshots={len(snapshots)} records={len(records)} exact={len(records)-len(wrong)} "
              f"negative-control={'PASS (corrupted result FAIL)' if negative else 'FAIL'} "
              f"seconds={time.monotonic()-started:.3f}")
        return 0 if passed else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (KeyError, IndexError, OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"HN-STARTUP-FAIL error={error}")
        raise SystemExit(1)
