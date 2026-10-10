"""Bounded, serial CLI execution discovery on a supplied read-only image."""
import argparse
import ctypes as C
from ctypes import wintypes as W
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import time

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('resources', Path(__file__).with_name('host-windows-s6.py'))
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', required=True, type=Path)
    parser.add_argument('--fixture-directory', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    runtime = args.runtime.resolve(strict=True)
    fixtures = args.fixture_directory.resolve(strict=True)
    assert fixtures.is_relative_to(ROOT/'build') and args.output.resolve().is_relative_to(ROOT/'build')
    before = hashlib.sha256(runtime.read_bytes()).hexdigest()
    rows = []
    cases = [
        ['eval-elisp-artifact', str(fixtures/'compiled-smoke.nelc'),
         '(progn (nelisp--write-stdout-bytes "S6-BCL-CALLED\\n") (s6-compiled-smoke 41))'],
        ['native-exec-elisp-artifact', str(fixtures/'compiled-smoke.neln'), 's6-compiled-smoke', '41'],
        ['--neln-selftest'],
        ['--ddskk-ime-server', str(fixtures/'compiled-smoke.el')],
    ]
    try:
        for command in cases:
            job = r.ownership.CommandJob()
            process = None
            started = time.perf_counter()
            try:
                process = subprocess.Popen([str(runtime)]+command, cwd=ROOT,
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                    creationflags=0x08000004)
                assert r.ownership.api('AssignProcessToJobObject', W.BOOL, W.HANDLE, W.HANDLE)(
                    job.handle, int(process._handle))
                resume = C.WinDLL('ntdll').NtResumeProcess
                resume.argtypes, resume.restype = [W.HANDLE], W.LONG
                assert resume(int(process._handle)) == 0
                output, _ = process.communicate(b'', timeout=30)
                rows.append(dict(command=command, exit=process.returncode,
                                 elapsed_ms=(time.perf_counter()-started)*1000,
                                 output=output.decode('utf-8', errors='replace')))
            finally:
                job.close()
                if process:
                    if process.poll() is None: process.kill()
                    process.wait(timeout=10)
                    for stream in (process.stdin, process.stdout):
                        if not stream.closed: stream.close()
                print('CLEANUP execution CLI leftovers=[]', flush=True)
    finally:
        unchanged = hashlib.sha256(runtime.read_bytes()).hexdigest() == before
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(dict(runtime_sha256=before, runtime_unchanged=unchanged,
                                               rows=rows), indent=2)+'\n', encoding='utf-8')
        assert unchanged, 'runtime changed during discovery'
    print(json.dumps(rows, indent=2))


if __name__ == '__main__':
    main()
