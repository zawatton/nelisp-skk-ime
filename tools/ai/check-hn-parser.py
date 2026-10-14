#!/usr/bin/env python3
"""HN4 bounded public-only SKK parser parity and 50k-line throughput gate.

One fresh NeLisp replay process handles all batches (native preparation uses a
separate compiler process). No dictionary-sized list/map is constructed in Lisp.
Memory is bounded by builder-side periodic reclamation.
Current OS resident memory is sampled within the same process's replay phase;
the 512 MiB cap applies to its peak above the replay start, not startup peaks.
A held, fully written 64 MiB probe must add at least 48 MiB to prove sensitivity.
Temporary data/cache live under LOCALAPPDATA; no production publication is tested.
"""
import argparse
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "engine/host-native-index.el"
LINE_CAP = 64 * 1024
BATCH_CAP = 256 * 1024
# Bound current resident memory growth during the replay phase to 512 MiB.
PARSE_GROWTH_CAP = 512 * 1024 * 1024
PROBE_HOLD_SECONDS = 1.0
PROBE_MIN_DELTA = 48 * 1024 * 1024


class RejectLine(ValueError):
    pass


def literal(value):
    text = value.decode("utf-8", "strict")
    return '"' + ''.join('\\' + ch if ch in '\\"' else
                         f'\\{ord(ch):03o}' if ord(ch) < 32 or ord(ch) == 127
                         else ch for ch in text) + '"'


def batches(path):
    """Split only at LF (not CR); bound copied bytes including the feed sentinel.

    Byte caps include the original line terminator. Also limit line count to
    bound list overhead. Reject the entire generation on an overlong line.
    """
    with path.open("rb") as stream:
        lines, raw_size, first = [], 0, True
        while line := stream.readline(LINE_CAP + 1):
            if len(line) > LINE_CAP:
                raise RejectLine(f"HN-PARSER-REJECT overlong-line bytes>{LINE_CAP}")
            line.decode("utf-8", "strict")
            if lines and (raw_size + len(line) + 1 > BATCH_CAP or len(lines) >= 512):
                yield first, lines, raw_size
                first, lines, raw_size = False, [], 0
            lines.append(line)
            raw_size += len(line)
        if lines:
            yield first, lines, raw_size


def serialize(records):
    """Native last-key-wins map, sorted by byte key; oracle uint32 LE format."""
    mapping = dict(records)
    result = bytearray()
    for key, tail in sorted(mapping.items()):
        result += struct.pack("<I", len(key)) + key
        result += struct.pack("<I", len(tail)) + tail
    return bytes(result), len(mapping)


def compare(actual, expected):
    return actual == expected


NATIVE_SETUP = r'''(require 'nelisp-native-cache)
(require 'nelisp-bytecode-native-consumer)
(require 'nelisp-native-template-stencils)
(nelisp-native-template-select-target)
(unless (file-exists-p nelisp-native-template--library-path)
  (setq nelisp-native-template--library-path
        (expand-file-name "templates/nelisp-native-template-win64.nelst"
                          (getenv "HN_NELISP_SRC"))))
(setq nelisp-native-cache-backend 'template)
(setq hn-parser-compile-failed nil)
(dolist (name '(host-native-parse-jisyo-line host-native-parse-jisyo-batch))
  (let ((f (cdr (assq name
               (nelisp-bytecode-native-consumer-read-elc-functions
                (getenv "HN_PARSER_ELC"))))))
    (unless f (error "Missing bytecode: %S" name))
    (if (string= (getenv "HN_PARSER_MODE") "compile")
        (condition-case err
            (let ((result (nelisp-native-cache-compile f)))
              (princ (format "HN-PARSER-COMPILE function=%S result=%S cache=%S\n"
                             name result (nelisp-native-cache-file f))))
          (error (setq hn-parser-compile-failed t)
                 (princ (format "HN-PARSER-COMPILE function=%S signal=%S\n"
                                name err))))
      (fset name (or (nelisp-native-cache-load f)
                    (error "Missing native callable: %S" name))))))
(when hn-parser-compile-failed (error "Native compilation failed"))
'''


def run(command, env, deadline, measure=None):
    """Capture output and optionally timestamp phase markers and current RSS."""
    stop = threading.Event()
    samples, markers = [], {}
    with subprocess.Popen(command, cwd=ROOT, env=env, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE) as process:
        def sample():
            try:
                import psutil
                target = psutil.Process(process.pid)
                while not stop.is_set():
                    # psutil RSS is the current working set on Windows too.
                    value = target.memory_info().rss
                    samples.append((time.monotonic(), value))
                    stop.wait(0.025)
            except ImportError:
                # Standard-library Windows fallback when psutil is absent.
                if os.name == "nt":
                    import ctypes
                    from ctypes import wintypes
                    class Counters(ctypes.Structure):
                        _fields_ = [("cb", wintypes.DWORD), ("faults", wintypes.DWORD)] + [
                            (name, ctypes.c_size_t) for name in
                            ("PeakWorkingSetSize", "WorkingSetSize", "peak_paged", "paged",
                             "peak_nonpaged", "nonpaged", "pagefile", "peak_pagefile")]
                    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
                    kernel.OpenProcess.restype = wintypes.HANDLE
                    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
                    kernel.K32GetProcessMemoryInfo.argtypes = [
                        wintypes.HANDLE, ctypes.POINTER(Counters), wintypes.DWORD]
                    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
                    handle = kernel.OpenProcess(0x410, False, process.pid)
                    if handle:
                        try:
                            while not stop.is_set():
                                info = Counters()
                                info.cb = ctypes.sizeof(info)
                                if not kernel.K32GetProcessMemoryInfo(handle, ctypes.byref(info), info.cb):
                                    break
                                samples.append((time.monotonic(), info.WorkingSetSize))
                                stop.wait(0.025)
                        finally:
                            kernel.CloseHandle(handle)
            except OSError:
                pass
            except Exception:
                # Optional telemetry must never determine parity.
                pass
        out_parts, err_parts, readers = [], [], []
        if measure:
            marker_lines = {measure + b" " + name.encode() + b"\n": name for name in
                            ("REPLAY-START", "REPLAY-END", "PROBE-HELD")}

            def read_stdout():
                for line in iter(process.stdout.readline, b""):
                    seen = time.monotonic()
                    out_parts.append(line)
                    if line in marker_lines:
                        markers.setdefault(marker_lines[line], seen)

            def read_stderr():
                for chunk in iter(lambda: process.stderr.read(65536), b""):
                    err_parts.append(chunk)

            readers = [threading.Thread(target=read_stdout, daemon=True),
                       threading.Thread(target=read_stderr, daemon=True)]
            for reader in readers:
                reader.start()
        thread = threading.Thread(target=sample, daemon=True) if measure else None
        if thread:
            thread.start()
        try:
            timeout = max(0.01, deadline-time.monotonic())
            if measure:
                process.wait(timeout=timeout)
                for reader in readers:
                    reader.join()
                out, err = b"".join(out_parts), b"".join(err_parts)
            else:
                out, err = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired as error:
            process.kill()  # Only the owned validation child.
            if measure:
                process.wait()
                for reader in readers:
                    reader.join()
                partial = b"".join(out_parts)
            else:
                partial, _ = process.communicate()
            frames = re.findall(rb" BEGIN (\d+) (\d+) ([0-9.]+)\n", partial)
            completed = partial.count(b" END\n")
            raise RuntimeError(f"deadline exceeded: completed_batches={completed} "
                               f"last_frame={frames[-1] if frames else None}") from error
        finally:
            stop.set()
            if thread:
                thread.join(timeout=1)
        if process.returncode:
            raise RuntimeError(f"exit={process.returncode}: " +
                               (out + err).decode("utf-8", "replace")[-2500:])
    return out, {"samples": samples, "markers": markers} if measure else None


def memory_metrics(telemetry):
    """Measure replay growth and probe sensitivity, failing closed on missing data."""
    samples, markers = telemetry["samples"], telemetry["markers"]
    start, end, held = (markers.get(name) for name in
                        ("REPLAY-START", "REPLAY-END", "PROBE-HELD"))
    replay = [value for stamp, value in samples
              if start is not None and end is not None and start <= stamp <= end]
    probe = [value for stamp, value in samples
             if held is not None and held <= stamp <= held + PROBE_HOLD_SECONDS]
    # REPLAY-END precedes allocation; samples just before PROBE-HELD may
    # already include some or all of the fully written probe.
    before_probe = [value for stamp, value in samples if end is not None and stamp <= end]
    initial = (min(samples, key=lambda item: abs(item[0] - start))[1]
               if samples and start is not None else None)
    peak = max(replay) if replay else None
    growth = peak - initial if peak is not None and initial is not None else None
    delta = max(probe) - before_probe[-1] if probe and before_probe else None
    reason = None
    if (not replay or not probe or not before_probe or growth is None or
            not (start <= end <= held)):
        reason = "missing-telemetry"
    elif delta < PROBE_MIN_DELTA:
        reason = "insensitive"
    elif growth > PARSE_GROWTH_CAP:
        reason = "growth-cap"
    return initial, peak, growth, delta, len(replay), len(probe), reason


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true",
                        help="Compile then fresh-load template native callables")
    args = parser.parse_args(argv)
    try:
        leak_mib = max(0, int(os.environ.get("HN_PARSER_TEST_LEAK_MIB", "0")))
    except ValueError:
        leak_mib = 0
    started = time.monotonic()
    deadline = started + 410
    mode = "native" if args.native else "interpreted"
    runtime = Path(os.environ["HN_NATIVE_RUNTIME"]).resolve(strict=True)
    src = Path(os.environ["HN_NELISP_SRC"]).resolve(strict=True)
    cold = Path(str(runtime) + ".cold").resolve(strict=True)
    Path(str(runtime) + ".native-startup.el").resolve(strict=True)
    local = Path(os.environ["LOCALAPPDATA"]).resolve(strict=True)
    golden = (ROOT / "tests/fixtures/host-native-nelisp/parsed.bin").read_bytes()
    if not golden:
        raise RuntimeError("empty parsed.bin")
    token = ("HN-PARSER-" + uuid.uuid4().hex).encode("ascii")
    with tempfile.TemporaryDirectory(prefix="hn-parser-", dir=local) as tmp:
        work = Path(tmp)
        (work / "emacs").mkdir()
        source = work / SOURCE.name
        source.write_bytes(SOURCE.read_bytes())
        env = dict(os.environ, HN_PARSER_SOURCE=str(source),
                   HN_PARSER_ELC=str(source.with_suffix(".elc")),
                   XDG_CONFIG_HOME=str(work), TEMP=str(work), TMP=str(work),
                   TMPDIR=str(work), NELISP_NATIVE_CACHE=str(work / "cache"))
        command = [str(runtime), "--cold-load-from", str(cold)]
        for directory in ("lisp", "src", "scripts", "packages/nl-ffi/src",
                          "packages/nl-prelude/src"):
            command += ["-L", str(src / directory)]
        setup = '(load (getenv "HN_PARSER_SOURCE") nil t t)\n'
        if args.native:
            expression = ('(progn (require (quote nelisp-bytecode-compiler-input-dialect)) '
                          '(unless (eq (plist-get (nelisp-bytecode-compiler-input-dialect) :status) '
                          '(quote pinned)) (error "Requires pinned GNU bytecode dialect")) '
                          '(require (quote bytecomp)) '
                          '(unless (byte-compile-file (getenv "HN_PARSER_SOURCE")) '
                          '(error "Byte compilation failed")))')
            run(["emacs", "-Q", "--batch", "--init-directory", str(work),
                 "-L", str(src / "lisp"), "--eval", expression], dict(env, HOME=str(work)), deadline)
            setup += NATIVE_SETUP

        # Synthetic extra coverage: first/later BOM, embedded LF stripping is
        # separately checked by direct line calls below, NUL, tabs, boundaries.
        edges = work / "PUBLIC-edges.jisyo"
        edge_lines = [b'\xef\xbb\xbffirst /bom/\r\n', b'\xef\xbb\xbflater /keep/\n',
                      b';single /kept/\n', b';;comment /ignored/\n',
                      b' /empty/\n', b'tab\tonly/skip/\n', b'x\r y /a\rb/\n',
                      b'nul\x00 /tail\x00/\n', b'malformed nope\n',
                      b'cap /' + b'x' * (LINE_CAP - 7) + b'/\n', b'last /unterminated']
        edges.write_bytes(b''.join(edge_lines))
        edge_expected = [(b'first', b'/bom/'), (b'\xef\xbb\xbflater', b'/keep/'),
                         (b';single', b'/kept/'), (b'', b'/empty/'), (b'x', b'/ab/'),
                         (b'nul\x00', b'/tail\x00/'),
                         (b'cap', b'/' + b'x' * (LINE_CAP - 7) + b'/'),
                         (b'last', b'/unterminated')]
        overlong = work / "PUBLIC-overlong.jisyo"
        overlong.write_bytes(b'long /' + b'x' * LINE_CAP + b'/\n')
        try:
            list(batches(overlong))
        except RejectLine as error:
            print(f"{error} control=PASS generation-rejected")
        else:
            raise RuntimeError("overlong-line control silently accepted")
        public = work / "PUBLIC-generated.jisyo"
        with public.open("wb") as stream:
            for i in range(50000):
                key = f"public-{i:05d}".encode()
                tail = f"/candidate-{i};annotation/[a/okuri-{i}/]/".encode()
                stream.write(key + b' prefix ' + tail + (b'\r\n' if i % 2 else b'\n'))

        datasets = [ROOT / "tests/fixtures/host-native-nelisp/SKK-JISYO.synthetic", edges, public]
        batch_meta, files = [], []
        for dataset, path in enumerate(datasets):
            for first, lines, raw_size in batches(path):
                # ASCII sentinel prevents file coding auto-detection from
                # stripping a BOM belonging to the first dictionary line.
                encoded = b"\n" + b"".join(lines)
                if len(encoded) > BATCH_CAP or raw_size > BATCH_CAP:
                    raise RuntimeError("batch bounds violated")
                if token in encoded:
                    raise RuntimeError("framing collision")
                file = work / f"batch-{len(files):04d}.data"
                file.write_bytes(encoded)
                files.append((first, file))
                batch_meta.append((dataset, len(lines)))
        # Read opaque text, never evaluate dictionary strings; one bounded input and
        # result list at a time. Driver contains paths, not dictionary contents.
        paths = ' '.join('(' + ('t' if first else 'nil') + ' ' +
                         literal(str(p).replace('\\', '/').encode()) + ')'
                         for first, p in files)
        replay = r'''(defvar hn-parser-test-leaks nil)
(let ((seq 0))
  ;; The standalone byte writer writes directly to stdout, without buffering.
  (nelisp--write-stdout-bytes "@TOKEN@ REPLAY-START\n")
  (host-native-index-reset-reclaim)
  (dolist (entry '(@PATHS@))
    (let ((input (with-temp-buffer (set-buffer-multibyte nil)
                           (insert-file-contents-literally (cadr entry)) (buffer-string)))
          (start 1) (lines nil) hit input-bytes)
      (while (< start (length input))
        (setq hit (or (string-search "\n" input start) (length input)))
        (push (substring input start hit) lines)
        (setq start (1+ hit)))
      (setq input-bytes (length input))
      (setq input nil lines (nreverse lines))
      (let* ((begin (float-time))
             (records (host-native-parse-jisyo-batch lines (car entry)))
             (elapsed (- (float-time) begin)))
      (princ (format "@TOKEN@ BEGIN %d %d %.9f\n" seq (length records) elapsed))
      (when (< seq @BENCH_START@)
        (dolist (record records)
          (princ (concat (car record) "\n" (cdr record) "\n"))))
      (princ "@TOKEN@ END\n"))
      (host-native-index-note-batch input-bytes))
    ;; Opt-in negative control: retain one fully written string per batch.
    (when (> @LEAK_MIB@ 0)
      (push (make-string (* @LEAK_MIB@ 1024 1024) ?l) hn-parser-test-leaks))
    (setq seq (1+ seq))))
(nelisp--write-stdout-bytes "@TOKEN@ REPLAY-END\n")
(let ((probe (make-string (* 64 1024 1024) ?p)))
  (nelisp--write-stdout-bytes "@TOKEN@ PROBE-HELD\n")
  ;; sleep-for is unavailable in standalone; keep the block live while sampled.
  (let ((until (+ (float-time) @PROBE_HOLD@)))
    (while (< (float-time) until)))
  (unless (= (aref probe (1- (length probe))) ?p)
    (error "Memory probe touch failed"))
  (setq probe nil))
(unless (equal (host-native-parse-jisyo-line "em\nb\red /a\nb\r/") '("embed" . "/ab/"))
  (error "Embedded line break control failed"))
(unless (equal (host-native-parse-jisyo-line
                (concat (unibyte-string 239 187 191) "byte /bom/") t)
               '("byte" . "/bom/"))
  (error "Unibyte BOM control failed"))
(unless (equal (host-native-parse-jisyo-line
                (concat (unibyte-string 230 188 162) " /raw/"))
               (cons (unibyte-string 230 188 162) "/raw/"))
  (error "Unibyte UTF-8 byte-offset control failed"))
(unless (equal (host-native-parse-jisyo-line
                (concat (char-to-string 65279) "漢 /候補/") t)
               '("漢" . "/候補/"))
  (error "Multibyte BOM/index control failed"))
(princ "@TOKEN@ DONE\n")
'''.replace('@PATHS@', paths).replace('@TOKEN@', token.decode()).replace(
            '@LEAK_MIB@', str(leak_mib)).replace('@PROBE_HOLD@', str(PROBE_HOLD_SECONDS)).replace(
            '@BENCH_START@', str(next(i for i, meta in enumerate(batch_meta) if meta[0] == 2)))
        driver = work / "run.el"
        # Same filename in compiler and fresh reader: GNU #$ docstrings are
        # recipe metadata resolved against load-file-name (check-hn-merge flow).
        driver.write_text(';;; -*- lexical-binding: t; -*-\n' + setup +
                          '(cond ((string= (getenv "HN_PARSER_MODE") "compile")\n'
                          '       (princ "HN-PARSER-COMPILE-PASS\\n"))\n'
                          '      (t\n' + replay + '))\n', encoding="utf-8", newline="\n")
        if args.native:
            output, _ = run(command + ["-l", str(driver)], dict(env, HN_PARSER_MODE="compile"), deadline)
            print(output.decode("utf-8", "replace"), end="")
            if b"HN-PARSER-COMPILE-PASS\n" not in output:
                raise RuntimeError("missing native compile marker")
        replay_started = time.monotonic()
        output, telemetry = run(command + ["-l", str(driver)], dict(env, HN_PARSER_MODE="run"), deadline, token)
        wall = time.monotonic() - replay_started
        for name in ("REPLAY-START", "REPLAY-END", "PROBE-HELD"):
            if output.count(token + b" " + name.encode() + b"\n") != 1:
                raise RuntimeError(f"missing or duplicate phase marker {name}")
        start_marker = token + b" REPLAY-START\n"
        cursor = output.index(start_marker) + len(start_marker)
        records, seconds = [[], [], []], [0.0, 0.0, 0.0]
        generated_count = 0
        for seq, (dataset, input_count) in enumerate(batch_meta):
            marker = token + f" BEGIN {seq} ".encode()
            pos = cursor
            if not output.startswith(marker, pos):
                raise RuntimeError(f"missing batch frame {seq}")
            end = output.index(b'\n', pos)
            fields = output[pos + len(marker):end].split()
            count, elapsed = int(fields[0]), float(fields[1])
            seconds[dataset] += elapsed
            cursor = end + 1
            if dataset == 2:
                if count != input_count:
                    raise RuntimeError(f"generated batch {seq} lost records")
                generated_count += count
            for _ in range(count if dataset != 2 else 0):
                end = output.index(b'\n', cursor)
                key, cursor = output[cursor:end], end + 1
                end = output.index(b'\n', cursor)
                tail, cursor = output[cursor:end], end + 1
                records[dataset].append((key, tail))
            end_marker = token + b' END\n'
            if output[cursor:cursor+len(end_marker)] != end_marker:
                raise RuntimeError(f"invalid record count/framing batch {seq}")
            cursor += len(end_marker)
        final_markers = token + b' REPLAY-END\n' + token + b' PROBE-HELD\n' + token + b' DONE\n'
        if output[cursor:] != final_markers:
            raise RuntimeError("missing completion marker or extra output")
        actual, count = serialize(records[0])
        corrupted = bytearray(golden)
        corrupted[len(corrupted) // 2] ^= 1
        negative = not compare(actual, bytes(corrupted))
        oracle = compare(actual, golden)
        initial, peak, growth, delta, replay_count, probe_count, memory_reason = memory_metrics(telemetry)
        memory_ok = memory_reason is None
        passed = oracle and negative and memory_ok
        passed = passed and records[1] == edge_expected and generated_count == 50000
        if records[1] != edge_expected:
            print(f"FAIL edge-count actual={len(records[1])} expected={len(edge_expected)}")
            for i, (got, want) in enumerate(zip(records[1], edge_expected)):
                if got != want:
                    print(f"FAIL edge={i} key={got[0][:64]!r}/{want[0][:64]!r} "
                          f"tail_bytes={len(got[1])}/{len(want[1])} "
                          f"tail_prefix={got[1][:64]!r}/{want[1][:64]!r}")
        rate = 50000 / seconds[2] if seconds[2] > 0 else None
        print(f"HN-PARSER-{'PASS' if passed else 'FAIL'} mode={mode} bytes={len(actual)} "
              f"oracle={'PASS' if oracle else 'FAIL'} records={count} emitted={len(records[0])} batches={len(files)} "
              f"negative-control={'PASS (flipped-byte FAIL)' if negative else 'FAIL'} "
              f"edges={'PASS' if records[1] == edge_expected else 'FAIL'} "
              f"seconds={time.monotonic()-started:.3f} replay_s={wall:.3f} "
              f"replay_start_bytes={initial if initial is not None else 'unavailable'} "
              f"replay_peak_bytes={peak if peak is not None else 'unavailable'} "
              f"growth_bytes={growth if growth is not None else 'unavailable'} "
              f"probe_delta_bytes={delta if delta is not None else 'unavailable'} "
              f"samples_replay={replay_count} samples_probe={probe_count} "
              f"memory={'PASS' if memory_ok else 'FAIL'} " +
              (f"reason={memory_reason} " if memory_reason else "") +
              f"growth_cap_bytes={PARSE_GROWTH_CAP}")
        print(f"HN-PARSER-BENCH mode={mode} public_lines=50000 records={generated_count} "
              f"parse_seconds={seconds[2]:.6f} lines/s={rate:.3f}" if rate is not None else
              f"HN-PARSER-BENCH mode={mode} lines/s=unavailable (timer resolution)")
        return 0 if passed else 1


if __name__ == "__main__":
    invoked = time.monotonic()
    try:
        raise SystemExit(main())
    except (KeyError, OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        import sys
        mode = "native" if "--native" in sys.argv else "interpreted"
        print(f"HN-PARSER-FAIL mode={mode} bytes=unavailable records=unavailable "
              f"seconds={time.monotonic()-invoked:.3f} replay_start_bytes=unavailable "
              f"replay_peak_bytes=unavailable growth_bytes=unavailable probe_delta_bytes=unavailable "
              f"samples_replay=0 samples_probe=0 memory=FAIL reason=missing-telemetry "
              f"growth_cap_bytes={PARSE_GROWTH_CAP} "
              f"error={error}")
        raise SystemExit(1)
