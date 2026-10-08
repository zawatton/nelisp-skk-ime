"""S3 policy fault isolation; reuses the frozen S2 transport and soak unchanged."""
import argparse
import ctypes as C
from ctypes import wintypes as W
import importlib.util
import json
from pathlib import Path
import re
import sys
import threading
import time

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('s2', Path(__file__).with_name('host-contracts.py'))
s2 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s2)


def log(h):
    path = h.run / 'host.log'
    return path.read_text('utf-8') if path.exists() else ''


def until(predicate, timeout=60):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(.01)
    raise AssertionError('deadline waiting for evidence')


def policy(h):
    until(lambda: 'policy-ready' in log(h))
    return int(re.findall(r'policy-start pid=(\d+)', log(h))[-1])


def owned_handle(h, pid):
    handle = s2.api('OpenProcess', W.HANDLE, W.DWORD, W.BOOL, W.DWORD)(0x1FFFFF, False, pid)
    if not handle:
        raise C.WinError(C.get_last_error())
    member = W.BOOL()
    if not s2.api('IsProcessInJob', W.BOOL, W.HANDLE, W.HANDLE, C.POINTER(W.BOOL))(
            handle, h.job.handle, C.byref(member)) or not member.value:
        s2.close(handle)
        raise AssertionError('refuse to manipulate unowned process')
    return handle


def suspend(handle, resume=False):
    fn = getattr(C.WinDLL('ntdll'), 'NtResumeProcess' if resume else 'NtSuspendProcess')
    fn.argtypes, fn.restype = [W.HANDLE], W.LONG
    if fn(handle) != 0:
        raise AssertionError('policy suspend/resume failed')


def pause(h, handle, ready, errors):
    try:
        suspend(handle)
        ready.set()
        time.sleep(3)
        suspend(handle, True)
    except Exception as error:
        errors.append(str(error))
        ready.set()


def soak_faults(h, handle, ready, errors):
    pause(h, handle, ready, errors)
    if errors:
        return
    try:
        until(lambda: 'policy-late-discard' in log(h), 5)
        assert s2.api('TerminateProcess', W.BOOL, W.HANDLE, W.UINT)(handle, 17)
    except Exception as error:
        errors.append(str(error))


def request(h, data):
    p = s2.Pipe(h.name)
    try:
        return p.request(data)
    finally:
        p.close()


def fault_gate(args, h):
    pid = policy(h)
    handle = owned_handle(h, pid)
    ready, errors = threading.Event(), []
    thread = threading.Thread(target=pause, args=(h, handle, ready, errors))
    timings = []
    baseline = log(h).count('adapter-publication')
    before = s2.resources(h.process)
    timeout_count = log(h).count('policy-timeout-discard')
    thread.start()
    ready.wait(5)
    try:
        # Source observation forces real policy IPC during the suspended heap.
        start = time.perf_counter()
        assert request(h, b'LOCAL SERVER 00304b00306a -') == b'SERVER 4'
        timings.append((time.perf_counter() - start) * 1000)
        until(lambda: log(h).count('policy-timeout-discard') > timeout_count, 2)
        for _ in range(200):
            for query, prefix in ((b'ENGINE CURRENT', b'ENGINE ddskk'),
                    (b'ROMAJI RULES 1', b'RULES 1 '),
                    (b'PREVIEW 00304b00306a', b'PREVIEW '),
                    (b'DIAG CHILD-PID', b'PID ')):
                start = time.perf_counter()
                assert request(h, query).startswith(prefix)
                timings.append((time.perf_counter() - start) * 1000)
        # Real durable local learning drives a native overlay publication while
        # the policy process is still suspended. Not a synthetic intent event.
        start = time.perf_counter()
        reply = request(h, b'LOCAL LEARN 0123456789abcdef0123456789abcdef.1 00304b00306a 004eee00540d')
        assert reply.startswith(b'ACK '), reply
        until(lambda: log(h).count('adapter-publication') > baseline, 1)
        publication_ms = (time.perf_counter() - start) * 1000
        if not thread.is_alive():
            print(f'FAIL pause isolation cached_max_ms={max(timings)} publication_ms={publication_ms}', flush=True)
            raise AssertionError('publication did not occur during the 3 s pause')
    finally:
        thread.join(5)
        s2.close(handle)
    assert not errors and not thread.is_alive(), errors
    until(lambda: 'policy-late-discard' in log(h), 5)
    timings.sort()
    tails = dict(p50=timings[(len(timings)-1)//2], p99=timings[int(len(timings)*.99)-1], max=timings[-1])
    assert tails['p99'] <= 10 and tails['max'] <= 50, tails
    assert publication_ms <= 1000, publication_ms
    # Kill the exact child that this host owns; cached/publication stay native.
    handle = owned_handle(h, pid)
    try:
        assert s2.api('TerminateProcess', W.BOOL, W.HANDLE, W.UINT)(handle, 17)
    finally:
        s2.close(handle)
    start = time.perf_counter()
    assert request(h, b'ENGINE CURRENT') == b'ENGINE ddskk'
    kill_ms = (time.perf_counter() - start) * 1000
    assert kill_ms <= 50, kill_ms
    until(lambda: len(re.findall(r'policy-start pid=', log(h))) >= 2, 5)
    until(lambda: log(h).count('policy-ready') >= 2, 60)
    after = s2.resources(h.process)
    report = dict(cached_requests=len(timings), pause_seconds=3, latency_ms=tails,
                  publication_ms=publication_ms, kill_cached_ms=kill_ms,
                  host_before=before, host_after=after,
                  owned_policy_pids=re.findall(r'policy-start pid=(\d+)', log(h)),
                  startup_ms=re.findall(r'policy-ready startup_ms=(\d+)', log(h)))
    child = owned_handle(h, policy(h))
    try:
        class P:
            _handle = child
        report['policy_resources'] = s2.resources(P())
    finally:
        s2.close(child)
    engine_pid = int(request(h, b'DIAG CHILD-PID').split()[1])
    child = owned_handle(h, engine_pid)
    try:
        class Engine:
            _handle = child
        report['engine_resources'] = s2.resources(Engine())
        report['owned_engine_pid'] = engine_pid
    finally:
        s2.close(child)
    assert 'policy-compare mismatch' not in log(h), 'shadow decision mismatch'
    (h.run / 'policy.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print('PASS S3 isolation ' + json.dumps(report) + ' artifacts=' + str(h.run), flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['isolation', 'soak', 'replay'])
    parser.add_argument('--runtime', required=True)
    parser.add_argument('--host', required=True)
    parser.add_argument('--build-dir', default='build/w')
    parser.add_argument('--cold-load-sleep-sec', type=int, default=45)
    parser.add_argument('--engine', choices=['ddskk', 'lattice'], default='ddskk')
    parser.add_argument('--fixture', default=str(s2.ROOT / 'docs/contracts/native-v1.json'))
    args = parser.parse_args()
    args.mode_s3 = args.mode
    h = s2.Host(args)
    h.env['DDSKK_HOST_POLICY_SHADOW'] = '1'
    try:
        h.start()
        pid = policy(h)
        if args.mode == 'isolation':
            fault_gate(args, h)
        elif args.mode == 'replay':
            s2.corpus(args, h)
            assert 'policy-compare match' in log(h), 'no shadow comparison'
            assert 'policy-compare mismatch' not in log(h), 'shadow mismatch'
        else:
            handle = owned_handle(h, pid)
            ready, errors = threading.Event(), []
            thread = threading.Thread(target=soak_faults, args=(h, handle, ready, errors))
            thread.start(); ready.wait(5)
            try:
                # Force one policy request before the unchanged 100000/32 soak.
                request(h, b'LOCAL SERVER 00304b00306a -')
                s2.soak(args, h)
            finally:
                thread.join(5); s2.close(handle)
            assert not errors and not thread.is_alive(), errors
    finally:
        pids = re.findall(r'(?:policy-start|child-start) pid=(\d+)', log(h))
        h.stop()
        leftovers = []
        for pid in pids:
            handle = s2.api('OpenProcess', W.HANDLE, W.DWORD, W.BOOL, W.DWORD)(0x100000, False, int(pid))
            if handle:
                if s2.wait(handle, 5000) == 258:
                    leftovers.append(pid)
                s2.close(handle)
        print(f'CLEANUP host reaped owned_children={len(pids)} leftovers={leftovers} artifacts={h.run}', flush=True)
        assert not leftovers, leftovers


if __name__ == '__main__':
    main()
