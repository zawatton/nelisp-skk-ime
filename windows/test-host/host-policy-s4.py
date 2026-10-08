"""S4 real-host authority, publication, crash/pause and concurrent-ID gates."""
import argparse
import concurrent.futures
import ctypes as C
from ctypes import wintypes as W
import importlib.util
import json
import math
from pathlib import Path
import re
import sys
import threading
import time
import uuid

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('s3', Path(__file__).with_name('host-policy.py'))
s3 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s3)
s2 = s3.s2
SWITCHES = ('SOURCES', 'CACHE', 'RESTART', 'PUBLICATION', 'LEARNING')
POINTS = ('outbox-before', 'outbox-flushed', 'stage-before', 'stage-flushed',
          'checkpoint-replaced', 'cursor-flushed', 'cursor-replaced', 'ack-before', 'ack-written')


def host(args):
    h = s2.Host(args)
    h.env.update({f'DDSKK_HOST_POLICY_{name}': '1' for name in SWITCHES})
    h.env['DDSKK_HOST_POLICY_SHADOW'] = '0'
    return h


def cleanup(h):
    pids = re.findall(r'(?:policy-start|child-start) pid=(\d+)', s3.log(h))
    h.stop()
    leftovers = []
    for pid in pids:
        handle = s2.api('OpenProcess', W.HANDLE, W.DWORD, W.BOOL, W.DWORD)(0x100000, False, int(pid))
        if handle:
            if s2.wait(handle, 5000) == 258:
                leftovers.append(pid)
            s2.close(handle)
    print(f'CLEANUP S4 owned_children={len(pids)} leftovers={leftovers} artifacts={h.run}', flush=True)
    assert not leftovers, leftovers


def tails(values):
    values = sorted(values)
    assert values, 'no timing samples'
    return dict(samples=len(values), p50=values[math.ceil(len(values)*.5)-1],
                p99=values[math.ceil(len(values)*.99)-1], max=values[-1])


def publication_gate(values):
    result = tails(values)
    if result['p99'] > 500 or result['max'] > 1000:
        print('FAIL S4 publication '+json.dumps(result), flush=True)
        raise AssertionError(result)
    return result


def ack_gate(expected, actual):
    assert expected == actual, f'acknowledged-ID loss/order: expected={expected} actual={actual}'


def controls():
    rejected = 0
    for call in (lambda: publication_gate([10]*99 + [1001]),
                 lambda: publication_gate([501]*100),
                 lambda: ack_gate(['a.1', 'b.1'], ['a.1']),
                 lambda: ack_gate(['a.1', 'b.1'], ['b.1', 'a.1'])):
        try:
            call()
        except AssertionError:
            rejected += 1
        else:
            raise AssertionError('negative control accepted')
    print(f'PASS S4 negative controls rejected={rejected} (p99,max,ID-loss,ID-order)', flush=True)


def publication(h, count=20):
    learn = []
    origin = uuid.uuid4().hex
    for i in range(1, count+1):
        baseline = s3.log(h).count('adapter-publication')
        started = time.perf_counter()
        op = f'{origin}.{i}'
        assert s3.request(h, f'LOCAL LEARN {op} 00304b00306a 004eee00540d'.encode()).startswith(f'ACK {op} '.encode())
        s3.until(lambda: s3.log(h).count('adapter-publication') > baseline, 2)
        learn.append((time.perf_counter()-started)*1000)
        time.sleep(.25)
    intents = [int(v) for v in re.findall(r'policy-intent-publication ms=(\d+)', s3.log(h))]
    result = dict(intent_to_publication_ms=publication_gate(intents), learn_to_publication_ms=tails(learn))
    # A source decision must actually be consumed, not just compared in shadow.
    for _ in range(10):
        assert s3.request(h, b'LOCAL SERVER 00304b00306a -') == b'SERVER 4'
        time.sleep(.05)
    s3.until(lambda: 'policy-authoritative kind=2' in s3.log(h), 2)
    assert 'policy-compare mismatch' not in s3.log(h)
    print('PASS S4 publication ' + json.dumps(result), flush=True)
    return result


def active_target(h, target):
    def attempt():
        if target == 'adapter':
            pid = h.process.pid
        elif target == 'engine':
            pid = int(s3.request(h, b'DIAG CHILD-PID').split()[1])
        else:
            pids = re.findall(r'policy-start pid=(\d+)', s3.log(h))
            if not pids:
                return None
            pid = int(pids[-1])
        try:
            handle = s3.owned_handle(h, pid)
        except OSError as error:
            if error.winerror == 87:  # Replaced since the log/DIAG snapshot.
                return None
            raise
        if s2.wait(handle, 0) != 258:
            s2.close(handle)
            return None
        return pid, handle
    return s3.until(attempt, 5)


def matrix_case(args, point, target, action):
    h = host(args)
    marker_root = h.run / 'rendezvous'
    marker = Path(str(marker_root)+'.'+point)
    h.env.update(NATIVEIME_TEST_HOST_POINT=point, NATIVEIME_TEST_HOST_POINT_ROOT=str(marker_root))
    provider = point.startswith(('outbox', 'cursor'))
    op = uuid.uuid4().hex + '.1'
    replies, errors = [], []
    thread = None
    handle = None
    secondary = None
    resumed = False
    captured_ids = []
    try:
        h.start()
        s3.policy(h)
        def transaction():
            p = s2.Pipe(h.name)
            try:
                if provider:
                    for request in (b'SESSION s4 OPEN 2', b'SESSION s4 V2 PREPARE 2 75,97,110,97',
                                    b'SESSION s4 V2 SPACE 2'):
                        response = p.request(request)
                        assert response.startswith((b'OK ', b'STATE ')), response
                    replies.append(p.request(b'SESSION s4 V2 CONTROL COMMIT'))
                else:
                    replies.append(p.request(f'LOCAL LEARN {op} 00304b00306a 004eee00540d'.encode()))
            except Exception as error:
                errors.append(str(error))
            finally:
                p.close()
        thread = threading.Thread(target=transaction)
        thread.start()
        s3.until(marker.exists, 10)
        outbox = h.run / 'user.jisyo.eg2-outbox'
        if provider and outbox.exists():
            captured_ids = [int(v) for v in re.findall(rb'EG2-OUTBOX 1 (\d+) ', outbox.read_bytes())]
        # Policy supervision may replace its child during cold load. Capture
        # the live, job-owned target at the rendezvous, not the setup PID.
        pid, handle = active_target(h, 'policy' if target == 'both' else target)
        if target == 'both':
            _, secondary = active_target(h, 'engine')
        if action == 'pause':
            s3.suspend(handle)
            if secondary:
                s3.suspend(secondary)
            marker.unlink()
            time.sleep(3)
            if secondary:
                s3.suspend(secondary, True)
            s3.suspend(handle, True)
            resumed = True
        else:
            assert s2.api('TerminateProcess', W.BOOL, W.HANDLE, W.UINT)(handle, 17)
            marker.unlink(missing_ok=True)
        thread.join(35)
        assert not thread.is_alive(), 'transaction did not settle after fault'
        # A client-received ACK/STATE is the acceptance boundary. Never retry
        # a provider COMMIT; the sealed native outbox supplies recovery.
        accepted = [r.decode() for r in replies if r.startswith((b'ACK ', b'STATE '))]
        before_restart = s3.log(h)
        cleanup(h)
        stderr = (h.run / 'stderr.log').read_text('utf-8', errors='replace')
        if provider:
            captured_ids += [int(v) for v in re.findall(r'LEARNING_OUTBOX append id=(\d+) [^\n]*ok=1', stderr)]
            captured_ids = sorted(set(captured_ids))
            assert not accepted or captured_ids, 'accepted STATE without captured durable provider identity'
        (h.run / 'before-restart.log').write_text(before_restart, encoding='utf-8')
        (h.run / 'before-restart.stderr.log').write_text(stderr, encoding='utf-8')
        h.job = s2.Job()
        h.env.pop('NATIVEIME_TEST_HOST_POINT')
        h.start()
        s3.policy(h)
        stored = (h.run / 'user.jisyo').read_text('utf-8') if (h.run / 'user.jisyo').exists() else ''
        if provider:
            if accepted or point != 'outbox-before':
                assert 'かな /仮名/' in stored, 'sealed/accepted provider row lost'
                watermark = (h.run / 'user.jisyo.eg2-provider-watermark').read_text('utf-8')
                assert re.fullmatch(r'EG2-PROVIDER 1 [1-9][0-9]*\n', watermark), watermark
                durable = int(watermark.split()[2])
                ack_gate(captured_ids, [value for value in captured_ids if value <= durable])
        else:
            if accepted:
                assert f';; local-ack {op[:-2]} 1 ' in stored, 'acknowledged local ID lost'
                assert 'かな /仮名/' in stored, 'acknowledged candidate lost'
            first = s3.request(h, f'LOCAL LEARN {op} 00304b00306a 004eee00540d'.encode())
            second = s3.request(h, f'LOCAL LEARN {op} 00304b00306a 004eee00540d'.encode())
            assert first == second and first.startswith(f'ACK {op} '.encode()), 'ID replay changed'
            recovered = (h.run / 'user.jisyo').read_text('utf-8')
            assert recovered.count(f';; local-ack {op[:-2]} 1 ') == 1, 'duplicate ID row'
        result = dict(point=point, target=target, action=action, accepted=accepted,
                      provider_IDs=captured_ids,
                      interrupted=errors, acknowledged_ID_loss=0, artifacts=str(h.run))
        (h.run / 's4-case.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
        print('PASS S4 matrix ' + json.dumps(result), flush=True)
        return result
    finally:
        if secondary:
            if action == 'pause' and not resumed:
                s3.suspend(secondary, True)
            s2.close(secondary)
        if handle:
            if action == 'pause' and not resumed:
                s3.suspend(handle, True)
            s2.close(handle)
        marker.unlink(missing_ok=True)
        cleanup(h)
        if thread:
            thread.join(35)
            assert not thread.is_alive(), 'owned client thread remains'


def concurrent_clients(h):
    origins = [uuid.uuid4().hex for _ in range(8)]
    def client(origin):
        p = s2.Pipe(h.name)
        accepted = []
        try:
            session = ('SESSION '+origin).encode()
            assert p.request(session+b' OPEN 2').startswith(b'OK ')
            for i in range(1, 11):
                for request in (b' V2 PREPARE 2 75,97,110,97', b' V2 SPACE 2', b' V2 CONTROL CANCEL'):
                    assert p.request(session+request).startswith(b'STATE ')
                op = f'{origin}.{i}'
                assert p.request(f'LOCAL LEARN {op} 00304b00306a 004eee00540d'.encode()).startswith(f'ACK {op} '.encode())
                accepted.append(op)
            assert p.request(session+b' CLOSE') == b'OK CLOSED'
        finally:
            p.close()
        return accepted
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        accepted = list(pool.map(client, origins))
    snapshot = s3.request(h, b'LOCAL SNAPSHOT')
    for ids in accepted:
        # Engine durable watermarks cover all earlier FIFO IDs from each origin.
        stored = (h.run / 'user.jisyo').read_text('utf-8')
        assert f';; local-ack {ids[0].split(".")[0]} 10 ' in stored, 'acknowledged-ID watermark lost'
    assert snapshot.startswith(b'OVERLAY '), snapshot
    print('PASS S4 multi-client clients=8 conversions=80 acknowledged_IDs=80 lost=0', flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['publication', 'matrix', 'clients', 'controls'])
    parser.add_argument('--runtime', required=True)
    parser.add_argument('--host', required=True)
    parser.add_argument('--build-dir', default='build/w')
    parser.add_argument('--cold-load-sleep-sec', type=int, default=45)
    parser.add_argument('--engine', default='ddskk')
    parser.add_argument('--points', nargs='+', choices=POINTS, default=POINTS)
    parser.add_argument('--targets', nargs='+', choices=['policy', 'engine', 'adapter', 'both'], default=['policy', 'engine', 'adapter', 'both'])
    parser.add_argument('--actions', nargs='+', choices=['crash', 'pause'], default=['crash', 'pause'])
    parser.add_argument('--workers', type=int, default=1)
    args = parser.parse_args()
    controls()
    if args.mode == 'controls':
        return
    if args.mode == 'matrix':
        assert 1 <= args.workers <= 3, 'matrix workers must be 1..3'
        cases = [(point, target, action) for point in args.points
                 for target in args.targets for action in args.actions
                 if not (target == 'both' and action == 'crash')]
        assert cases, 'no matrix cases selected; combined managed injection is a pause'
        def checked_case(case):
            try:
                return matrix_case(args, *case)
            except Exception as error:
                print(f'FAIL S4 matrix point={case[0]} target={case[1]} action={case[2]} error={error}', flush=True)
                raise
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
            futures = [pool.submit(checked_case, case) for case in cases]
            results = []
            try:
                for future in concurrent.futures.as_completed(futures):
                    results.append(future.result())
            except Exception:
                for future in futures:
                    future.cancel()
                raise
        print(f'PASS S4 matrix cases={len(results)} acknowledged_ID_loss=0', flush=True)
    else:
        h = host(args)
        try:
            h.start()
            s3.policy(h)
            publication(h) if args.mode == 'publication' else concurrent_clients(h)
        finally:
            cleanup(h)


if __name__ == '__main__':
    main()
