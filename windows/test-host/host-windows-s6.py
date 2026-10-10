"""Exact Windows policy artifact measurements; never substitutes for OS1 gates."""
import argparse
import ctypes as C
from ctypes import wintypes as W
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time
import host_policy_hp2 as hp2

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('ownership', Path(__file__).with_name('host-test-process-guard.py'))
ownership = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ownership)


def distribution(values):
    values = sorted(values)
    return dict(samples=len(values), p50=values[math.ceil(len(values)*.5)-1],
                p99=values[math.ceil(len(values)*.99)-1], max=values[-1])


def private_bytes(process):
    class Counters(C.Structure):
        _fields_ = [('cb', W.DWORD), ('faults', W.DWORD)] + [
            (name, C.c_size_t) for name in ('peak_working', 'working', 'peak_paged',
                'paged', 'peak_nonpaged', 'nonpaged', 'pagefile', 'peak_pagefile', 'private')]
    counters = Counters()
    counters.cb = C.sizeof(counters)
    query = C.WinDLL('psapi', use_last_error=True).GetProcessMemoryInfo
    query.argtypes, query.restype = [W.HANDLE, W.LPVOID, W.DWORD], W.BOOL
    if not query(int(process._handle), C.byref(counters), counters.cb):
        raise C.WinError(C.get_last_error())
    return counters.private


def sample(runtime, timeout):
    job = ownership.CommandJob()
    process = None
    reader = None
    replies = queue.Queue()
    discovery, latency, memory = [], [], []
    def read():
        for line in process.stdout:
            replies.put(line)
        replies.put(None)
    try:
        env = dict(os.environ)
        env.pop('DDSKK_HOST_POLICY_UNIT_ONLY', None)
        env.pop('DDSKK_HOST_POLICY_TEST_PAUSE_KIND', None)
        begin = time.perf_counter()
        # Suspended launch closes the spawn-before-job-assignment race.
        process = subprocess.Popen([str(runtime), '--load', 'windows/test-host/windows-runtime-s6.el'],
            cwd=ROOT, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, creationflags=0x08000004)
        if not ownership.api('AssignProcessToJobObject', W.BOOL, W.HANDLE, W.HANDLE)(
                job.handle, int(process._handle)):
            raise C.WinError(C.get_last_error())
        resume = C.WinDLL('ntdll').NtResumeProcess
        resume.argtypes, resume.restype = [W.HANDLE], W.LONG
        if resume(int(process._handle)) != 0:
            raise RuntimeError('resume failed')
        reader = threading.Thread(target=read)
        reader.start()
        deadline = time.monotonic() + timeout
        while True:
            line = replies.get(timeout=max(.01, deadline-time.monotonic()))
            if line == b'HP2 READY\n':
                break
            if line is None:
                raise RuntimeError('runtime exited before READY: '+repr(discovery))
            discovery.append(line.decode('utf-8', errors='strict').rstrip())
        startup = (time.perf_counter()-begin)*1000
        assert 'S6 UNICODE かな😀é' in discovery, discovery
        memory.append(private_bytes(process))
        # Byte-for-byte numeric decisions and sequential IPC roundtrip latency.
        for serial in range(1, 101):
            begin = time.perf_counter()
            process.stdin.write(hp2.request(serial, 1, 1, 0, 0))
            process.stdin.flush()
            actual = replies.get(timeout=5)
            assert actual == hp2.reply(serial, 0), actual
            latency.append((time.perf_counter()-begin)*1000)
        memory.append(private_bytes(process))
        process.stdin.close()
        process.wait(timeout=10)
        assert process.returncode == 0, process.returncode
        return dict(startup_ms=startup, private_bytes=max(memory),
                    policy_ipc_ms=distribution(latency), policy_ipc_raw_ms=latency,
                    discovery=discovery)
    finally:
        job.close()
        if process:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=10)
            if process.stdin and not process.stdin.closed:
                process.stdin.close()
            process.stdout.close()
        if reader:
            reader.join(10)
            assert not reader.is_alive(), 'reader leftover'
        print('CLEANUP S6 runtime leftovers=[]', flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--samples', type=int, default=3, choices=range(1, 11))
    parser.add_argument('--cold-load-sleep-sec', type=int, default=45)
    args = parser.parse_args()
    if not args.output.resolve().is_relative_to(ROOT / 'build'):
        parser.error('output must be in this worktree build directory')
    runtime = args.runtime.resolve(strict=True)
    report = dict(runtime_sha256=hashlib.sha256(runtime.read_bytes()).hexdigest(),
                  policy_sha256=hashlib.sha256((ROOT/'engine/host-policy.el').read_bytes()).hexdigest(),
                  artifact='supplied VM; CW1/RW4 alternatives not supplied',
                  scope='policy-only; OS1 native evidence and adapter tail gates required separately',
                  samples=[], status='incomplete')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    try:
        for _ in range(args.samples):
            report['samples'].append(sample(runtime, max(60, args.cold_load_sleep_sec+30)))
        report['startup_ms'] = distribution([s['startup_ms'] for s in report['samples']])
        report['private_bytes'] = distribution([s['private_bytes'] for s in report['samples']])
        # Provisional resource ceilings are explicit, separate from approved
        # callback/durability budgets. IPC is not an adapter host-tail measurement.
        report['budgets'] = dict(startup_ms=60000, private_bytes=512*1024*1024,
                                 policy_ipc_p99_ms=10, policy_ipc_max_ms=50,
                                 resource_ceilings='provisional S6 policy-only')
        assert report['startup_ms']['max'] <= 60000, report['startup_ms']
        assert report['private_bytes']['max'] <= 512*1024*1024, report['private_bytes']
        for value in report['samples']:
            assert value['policy_ipc_ms']['p99'] <= 10 and value['policy_ipc_ms']['max'] <= 50, value
        report['status'] = 'PASS policy-only measurements'
        # Windows redirected consoles may use cp932; keep the receipt portable.
        print('PASS S6 artifact '+json.dumps(report, ensure_ascii=True), flush=True)
    except Exception as error:
        report['status'] = 'FAIL policy-only measurements'
        report['failure'] = repr(error)
        raise
    finally:
        report['runtime_unchanged'] = hashlib.sha256(runtime.read_bytes()).hexdigest() == report['runtime_sha256']
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')


if __name__ == '__main__':
    main()
