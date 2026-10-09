"""Exact-runtime Unicode byte gate, independent of policy IPC budgets."""
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
spec = importlib.util.spec_from_file_location('ownership', Path(__file__).with_name('host-test-process-guard.py'))
ownership = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ownership)
EXPECTED = b'S6 UNICODE '+"かな\U0001f600e\u0301".encode('utf-8')+b'\n'


def check_output(output, exit_code):
    assert exit_code == 0, ('Unicode runtime exit', exit_code, output)
    assert output == EXPECTED, ('Unicode bytes differ', output, EXPECTED)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--cold-load-sleep-sec', type=int, default=45)
    args = parser.parse_args()
    assert args.output.resolve().is_relative_to(ROOT/'build')
    runtime = args.runtime.resolve(strict=True)
    before = hashlib.sha256(runtime.read_bytes()).hexdigest()
    report = dict(runtime_sha256=before, status='incomplete')
    job = ownership.CommandJob()
    process = None
    started = time.perf_counter()
    try:
        # Two CLI actions suppress automatic printing of the load's value.
        command = [str(runtime), '--load', 'windows/test-host/windows-runtime-unicode-s6.el', '--eval', 'nil']
        report['command'] = command
        process = subprocess.Popen(command, cwd=ROOT, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, creationflags=0x08000004)
        assert ownership.api('AssignProcessToJobObject', W.BOOL, W.HANDLE, W.HANDLE)(job.handle, int(process._handle))
        resume = C.WinDLL('ntdll').NtResumeProcess
        resume.argtypes, resume.restype = [W.HANDLE], W.LONG
        assert resume(int(process._handle)) == 0
        output, _ = process.communicate(b'', timeout=max(60, args.cold_load_sleep_sec+30))
        report.update(exit=process.returncode, stdout_hex=output.hex(), expected_hex=EXPECTED.hex(),
                      observed_ms=(time.perf_counter()-started)*1000)
        check_output(output, process.returncode)
        report['status'] = 'PASS'
        print('PASS OS1 Unicode exact UTF-8 bytes='+EXPECTED.hex(), flush=True)
    except BaseException as error:
        report.update(status='FAIL', failure=repr(error))
        raise
    finally:
        job.close()
        if process:
            if process.poll() is None: process.kill()
            process.wait(timeout=10)
            for stream in (process.stdin, process.stdout):
                if not stream.closed: stream.close()
        report['runtime_unchanged'] = hashlib.sha256(runtime.read_bytes()).hexdigest() == before
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
        assert report['runtime_unchanged'], 'runtime changed during Unicode probe'
        print('CLEANUP OS1 Unicode leftovers=[]', flush=True)


if __name__ == '__main__':
    main()
