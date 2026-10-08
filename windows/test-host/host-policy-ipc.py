"""Qualify HP1 framing/decisions/pause on the supplied Windows NeLisp image."""
import argparse
import hashlib
import ctypes as C
from ctypes import wintypes as W
import importlib.util
import os
import json
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('s2', Path(__file__).with_name('host-contracts.py'))
s2 = importlib.util.module_from_spec(spec); spec.loader.exec_module(s2)


def probe(runtime, malformed=None, records=None):
    job = s2.Job()
    env = dict(os.environ, NATIVEIME_REGISTRY_KEY='Software\\NativeIME-test-EH3-ipc',
               DDSKK_HARNESS_DIAGNOSTICS='1', DDSKK_HOST_POLICY_TEST_PAUSE_KIND='5')
    env.pop('DDSKK_HOST_POLICY_UNIT_ONLY', None)
    p = None
    output = queue.Queue()
    def reader():
        for line in p.stdout:
            output.put(line)
        output.put(None)
    def line(timeout=60):
        return output.get(timeout=timeout)
    def send(data):
        p.stdin.write(data); p.stdin.flush()
    started = time.perf_counter()
    try:
        p = subprocess.Popen([runtime, '--load', 'engine/host-policy.el'], cwd=s2.ROOT,
            env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            creationflags=0x08000004)
        if not s2.api('AssignProcessToJobObject', W.BOOL, W.HANDLE, W.HANDLE)(job.handle, int(p._handle)):
            raise C.WinError(C.get_last_error())
        fn = C.WinDLL('ntdll').NtResumeProcess; fn.argtypes, fn.restype = [W.HANDLE], W.LONG
        assert fn(int(p._handle)) == 0
        thread = threading.Thread(target=reader); thread.start()
        assert line() == b'HP1 READY\n'
        startup_ms = (time.perf_counter() - started) * 1000
        if malformed is not None:
            try:
                send(malformed)
            except BrokenPipeError:
                pass
            # Bad input must terminate without emitting a valid decision.
            p.wait(timeout=5)
            thread.join(5)
            values = []
            while not output.empty():
                values.append(output.get_nowait())
            assert not any(v and v.startswith(b'HP1 R ') for v in values), values
            return dict(malformed_rejected=1, exit=p.returncode)
        frames = records or [(1, 1, 0, 0, 0), (2, 1, 1, 0, 1), (3, 16000, 0, 0, 30000),
                  (4, 1, 60000, 0, 1), (4, 0, 1999, 0, 0)]
        # Split one frame across writes, then batch the remainder in one write.
        wire = ''.join(f'HP1 Q {i+1} 7 11 13 {k} {a} {b} {c} 6162\n'
                       for i, (k, a, b, c, d) in enumerate(frames)).encode()
        send(wire[:9]); time.sleep(.02); send(wire[9:])
        for i, (k, a, b, c, d) in enumerate(frames):
            assert line(5) == f'HP1 R {i+1} 7 11 13 {k} {d}\n'.encode()
        begin = time.perf_counter()
        last = len(frames) + 1
        send(f'HP1 Q {last} 7 11 13 5 1 1 1 -\n'.encode())
        paused_reply = line(5)
        assert paused_reply == f'HP1 R {last} 7 11 13 5 1\n'.encode(), paused_reply
        pause_ms = (time.perf_counter() - begin) * 1000
        assert 3000 <= pause_ms <= 4000, pause_ms
        p.stdin.close(); p.wait(timeout=5); thread.join(5)
        assert p.returncode == 0
        return dict(decisions=len(frames)+1, split_frame=1, batched_frames=len(frames),
                    startup_ms=startup_ms, lisp_pause_ms=pause_ms)
    finally:
        job.close()
        if p:
            if p.poll() is None:
                p.kill()
            p.wait(timeout=10)
            if p.stdin and not p.stdin.closed:
                p.stdin.close()
            p.stdout.close()
        if 'thread' in locals():
            thread.join(5)
            assert not thread.is_alive()


def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--runtime', required=True)
    parser.add_argument('--records', type=Path)
    args = parser.parse_args()
    records = None
    if args.records:
        assert hashlib.sha256(args.records.read_bytes()).hexdigest() == args.records.with_suffix('.sha256').read_text().split()[0], 'recorded fixture bytes changed'
        records = json.loads(args.records.read_text('utf-8'))['records']
    report = probe(args.runtime, records=records)
    if records:
        damaged = [list(r) for r in records]
        damaged[0][-1] = (damaged[0][-1] + 1) % 3
        try:
            probe(args.runtime, records=damaged)
        except AssertionError:
            print('PASS S4 equivalence negative control wrong-native-decision rejected=1')
        else:
            raise AssertionError('equivalence gate accepted a wrong decision')
    invalid = [b'HP2 Q 1 7 11 13 1 1 1 0 -\n',
               b'HP1 Q x 7 11 13 1 1 1 0 -\n',
               b'HP1 Q 1 7 11 13 0 1 1 0 -\n',
               b'HP1 Q 1 7 11 13 1 1 1 0 6g\n', b'x' * 4097 + b'\n']
    for value in invalid:
        probe(args.runtime, value)
    print(f'PASS Windows HP1 IPC {report} malformed_rejected={len(invalid)} owned_children={7 if records else 6} leftovers=0')


if __name__ == '__main__':
    main()
