"""Coordinator-only S4.3 native startup/fault gate; --self-test starts no stacks."""
import argparse
import copy
import ctypes as C
from ctypes import wintypes as W
import importlib.util
import json
import os
from pathlib import Path
import re
import socket
import sys
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
from importlib.machinery import SourceFileLoader
helpers = SourceFileLoader('hn_e2e_baseline', str(Path(__file__).with_name('test-hn-e2e-baseline.py'))).load_module()
native_bundle = helpers.native_bundle
pressure = helpers.pressure
GROUPS = ('SOURCES', 'CACHE', 'RESTART', 'PUBLICATION', 'LEARNING')
LABELS = ('COLD', 'WARM', 'HITS', 'EXPIRY', 'DOWN', 'RECOVER', 'FINAL')


def private_key(pipe_name):
    prefix = chr(92) * 2 + '.' + chr(92) + 'pipe' + chr(92) + 'ddskk-test-'
    match = re.fullmatch(re.escape(prefix) + r'([0-9a-f]{12})', pipe_name)
    if not match:
        raise AssertionError('unrecognized private harness pipe')
    return 'Software' + chr(92) + 'NativeIME-test-' + match.group(1)


def counters(text):
    result = {g: [int(n), int(m)] for g, n, m in re.findall(
        r'policy-evaluations group=(\w+) native=(\d+) nelisp-selected=(\d+)', text)}
    if set(result) != set(GROUPS):
        raise AssertionError('missing five-group counter samples')
    return result


def delta(before, after):
    result = {g: [after[g][i] - before[g][i] for i in range(2)] for g in GROUPS}
    if any(n < 0 for values in result.values() for n in values):
        raise AssertionError('counter reset/reordered samples')
    return result


def check(tsf, host, samples, fetches, elapsed):
    if elapsed >= 360:
        raise AssertionError('runtime exceeded six minutes')
    for i, label in enumerate(LABELS):
        document = 'あい' + '仮名' * i
        if not re.search(r'AFTER ' + label + r' BUF=\[' + document + r'\].*COMP=-', tsf):
            raise AssertionError('exact document/composition failed: ' + label)
    rows = re.findall(r'CALLBACK_IO hooks=(\d+) mask=(\d+) pipe_io=(\d+) blocking_waits=(\d+)', tsf)
    if len(rows) < 20 or any(int(mask) & 271 != 271 or int(io) or int(waits)
                            for _, mask, io, waits in rows):
        raise AssertionError('missing callback coverage or callback IO/wait')
    times = list(map(int, re.findall(r'KEYLAT token=\S+ .*?total_us=(\d+) claimed=1', tsf)))
    if not times or max(times) > 20000 or 'SETTLE TIMEOUT' in tsf or not re.search(
            r'LOCAL_ACK_WAIT OK required=6 observed=\d+', tsf):
        raise AssertionError('callback budget or ACK/settle barrier failed')
    ack_ids = dict(re.findall(r'LOCAL_ACK id=(\S+) sequence=([1-9]\d*)', tsf))
    if len(ack_ids) < 6 or int(re.search(r'LOCAL_ACK_WAIT OK required=6 observed=(\d+)', tsf)[1]) < 6:
        raise AssertionError('missing unique acknowledged learning IDs')
    if len(re.findall(r'policy-ready startup_ms=\d+ native=1', host)) < 2 or re.search(r'policy-ready startup_ms=\d+ native=0', host):
        raise AssertionError('native child unavailable/refused')
    bundle = helpers.bundle_evidence(host, minimum=2)
    if any(int(ms) > 60000 for ms in re.findall(r'policy-ready startup_ms=(\d+)', host)):
        raise AssertionError('60 s native policy startup budget')
    if 'hn3-answer operation=5' not in host or 'hn3-startup-selection runner=ddskk' not in host:
        raise AssertionError('startup did not use HN3')
    if host.index('hn3-answer operation=5') > host.index('child-start pid=') or host.count('hn3-answer operation=5') < 2:
        raise AssertionError('initial/reload startup HN3 missing')
    for marker in ('policy-timeout-discard', 'policy-late-discard', 'policy-retire'):
        if marker not in host:
            raise AssertionError('missing fault evidence: ' + marker)
    if host.count('policy-ready') < 2 or 'policy-compare mismatch' in host:
        raise AssertionError('policy restart/equivalence failed')
    phases = {name: delta(samples[a], samples[b]) for name, a, b in (
        ('cold-miss', 'ZERO', 'COLD'), ('miss-generation', 'COLD', 'WARM'),
        ('steady', 'WARM', 'HITS'), ('expiry', 'HITS', 'EXPIRY'),
        ('child-down', 'EXPIRY', 'DOWN'), ('restart-miss', 'DOWN', 'RECOVER'),
        ('steady-recovered', 'RECOVER', 'FINAL'))}
    for name in ('steady', 'steady-recovered'):
        if any(n for n, _ in phases[name].values()) or not sum(m for _, m in phases[name].values()):
            raise AssertionError('steady hits evaluated native or selected no managed answers: ' + name)
    for name in ('cold-miss', 'miss-generation', 'expiry', 'child-down'):
        if not sum(n for n, _ in phases[name].values()):
            raise AssertionError('no native fallback evidence: ' + name)
    if any(not samples['FINAL'][g][1] for g in GROUPS):
        raise AssertionError('uncovered authoritative policy group')
    # RESTART aggregates two distinct caller policies. Neither seeded replies
    # nor policy-child supervision proves engine backoff/publication authority.
    for kind in (3, 7):
        if not re.search(r'policy-authoritative kind=' + str(kind) + r' count=[1-9]\d*', host):
            raise AssertionError('uncovered restart caller kind=' + str(kind))
    if 'replacement-published engine=' not in host:
        raise AssertionError('missing real engine replacement')
    if fetches[1] <= fetches[0]:
        raise AssertionError('2 second negative cache did not expire/refetch')
    return dict(bundle=bundle, phases=phases, callback_probes=len(rows), pipe_io=0, blocking_waits=0,
                callback_max_us=max(times), negative_cache_fetches=fetches, exact_documents=7)


def self_test():
    tsf = '\n'.join('AFTER ' + label + ' BUF=[' + 'あい' + '仮名' * i + '] COMP=-'
                    for i, label in enumerate(LABELS))
    tsf += '\n' + '\n'.join(['CALLBACK_IO hooks=5 mask=271 pipe_io=0 blocking_waits=0'] * 20)
    tsf += '\nKEYLAT token=K total_us=1 claimed=1\nLOCAL_ACK_WAIT OK required=6 observed=6\n'
    tsf += ''.join(f'LOCAL_ACK id=fixture.{i} sequence={i}\n' for i in range(1, 7))
    host = ('policy-ready startup_ms=1 native=1 policy-ready startup_ms=1 native=1 hn3-answer operation=5 hn3-startup-selection runner=ddskk child-start pid=1 hn3-answer operation=5 policy-timeout-discard policy-late-discard policy-retire policy-ready policy-ready'
            ' policy-authoritative kind=3 count=1 policy-authoritative kind=7 count=1'
            ' replacement-published engine=ddskk')
    host += '\nHN-BUNDLE native=11 interpreted=1 refused=host-policy-hn3-reply\n' * 2
    samples = {label: {g: [n, m] for g in GROUPS} for label, n, m in (
        ('ZERO', 0, 0), ('COLD', 1, 0), ('WARM', 2, 1), ('HITS', 2, 2),
        ('EXPIRY', 3, 3), ('DOWN', 4, 4), ('RECOVER', 5, 5), ('FINAL', 5, 6))}
    check(tsf, host, samples, [1, 2], 1)
    pipe = chr(92) * 2 + '.' + chr(92) + 'pipe' + chr(92) + 'ddskk-test-012345abcdef'
    assert private_key(pipe) == 'Software' + chr(92) + 'NativeIME-test-012345abcdef'
    for invalid in (pipe.replace('ddskk-test-', 'ddskk-live-'), pipe.replace('.', 'X'), pipe + 'x'):
        try:
            private_key(invalid)
        except AssertionError:
            continue
        raise AssertionError('non-private key accepted')
    bad = copy.deepcopy(samples); bad['HITS']['CACHE'][0] += 1
    mutations = [(tsf, host.replace('HN-BUNDLE native=11', 'HN-BUNDLE native=0'), samples, [1, 2], 1),
                 (tsf, host.replace('HN-BUNDLE', 'MISSING'), samples, [1, 2], 1),
                 (tsf, host, bad, [1, 2], 1), (tsf, host.replace('native=1', 'native=0'), samples, [1, 2], 1), (tsf, host.replace('hn3-answer operation=5', ''), samples, [1, 2], 1),
                 (tsf.replace('sequence=6', 'sequence=0'), host, samples, [1, 2], 1)]
    for marker in ('policy-authoritative kind=3 count=1',
                   'policy-authoritative kind=7 count=1', 'replacement-published engine='):
        mutations.append((tsf, host.replace(marker, ''), samples, [1, 2], 1))
    bad = copy.deepcopy(samples); bad['FINAL']['RESTART'][1] = 0
    mutations.extend([(tsf.replace('仮名', 'X'), host, samples, [1, 2], 1),
        (tsf.replace('blocking_waits=0', 'blocking_waits=1'), host, samples, [1, 2], 1),
        (tsf, host.replace('policy-late-discard', ''), samples, [1, 2], 1),
        (tsf, host, bad, [1, 2], 1), (tsf, host, samples, [1, 1], 1),
        (tsf, host, samples, [1, 2], 360), ('', host, samples, [1, 2], 1),
        (tsf.replace('LOCAL_ACK_WAIT OK', 'LOCAL_ACK_WAIT TIMEOUT'), host, samples, [1, 2], 1)])
    for args in mutations:
        try:
            check(*args)
        except AssertionError:
            continue
        raise AssertionError('coverage negative control accepted')
    try:
        counters('')
    except AssertionError:
        pass
    else:
        raise AssertionError('empty counters accepted')
    print(f'PASS policy coverage checker negative_controls={len(mutations)+4} stacks=0')


def main(args):
    started = time.monotonic()
    bundle = native_bundle()
    if time.monotonic() - started > 75:
        raise AssertionError('offline preparation consumed stack budget; prebuild DDSKK_HOST_POLICY_BUNDLE')
    spec = importlib.util.spec_from_file_location('contracts', Path(__file__).with_name('host-contracts.py'))
    transport = importlib.util.module_from_spec(spec); spec.loader.exec_module(transport)
    run = ROOT / args.build_dir / ('policy-coverage-' + uuid.uuid4().hex)
    if not run.resolve().is_relative_to((ROOT / 'build').resolve()):
        raise AssertionError('private build directory required')
    run.mkdir(parents=True)
    host_path, gate_path = run / 'host.log', run / 'gate.log'
    env = dict(os.environ, DDSKK_HOST_POLICY_RUNTIME=os.environ['HN_NATIVE_RUNTIME'],
               DDSKK_HOST_POLICY_BUNDLE=str(bundle), DDSKK_HOST_NATIVE_STARTUP='1', DDSKK_HOST_NATIVE_MERGE='0',
               DDSKK_HOST_POLICY_COUNTERS='1', DDSKK_HOST_POLICY_SHADOW='0',
               DDSKK_HARNESS_DIAGNOSTICS='1', NATIVEIME_TEST_CALLBACK_IO_PROBE='1',
               NATIVEIME_TEST_CALLBACK_WAIT_CONTROL='0', NELISP_IME_ENGINE='ddskk',
               DDSKK_DICTIONARY_FILES=str(Path(__file__).with_name('data') / 'behavior-jisyo.utf8'), DDSKK_HOST_LOG=str(host_path), DDSKK_SKKSERV_HOST='127.0.0.1')
    for group in GROUPS:
        env['DDSKK_HOST_POLICY_' + group] = '1'
    env.pop('DDSKK_SKKSERV_START_COMMAND', None)
    env.pop('DDSKK_HOST_POLICY_TEST_PAUSE_KIND', None)
    env.pop('DDSKK_SKKSERV_ENABLE', None) # Private harness registry is authoritative.
    # PUBLIC private loopback fixture always misses; shortest production TTL=2 s.
    # run-harness.ps1 only accepts SkkServPort 31100-31199; take the first free one.
    listener = socket.socket()
    for port in range(31100, 31200):
        try:
            listener.bind(('127.0.0.1', port)); break
        except OSError:
            continue
    else:
        raise AssertionError('no free private skkserv port in 31100-31199')
    listener.listen(); listener.settimeout(.2)
    env['DDSKK_SKKSERV_PORT'] = str(listener.getsockname()[1])
    stop = threading.Event(); fetches = [0]; errors = []
    def serve():
        while not stop.is_set():
            try:
                client, _ = listener.accept()
            except socket.timeout:
                continue
            try:
                with client:
                    client.settimeout(1); wire = b''
                    while not wire.endswith(b' '):
                        part = client.recv(4096)
                        if not part:
                            break
                        wire += part
                        if len(wire) > 4096:
                            raise AssertionError('oversized fixture query')
                    if not wire.startswith(b'1'):
                        raise AssertionError('unexpected fixture protocol')
                    fetches[0] += 1; client.sendall(b'4\n')
            except Exception as error:
                errors.append(str(error))
    server = threading.Thread(target=serve, daemon=True); server.start()
    conversion = 'K a n a SPACE ENTER SETTLE30000:'
    tokens = ('a i SPACE WAIT3000 ENTER SETTLE30000:COLD WAIT65000 ' +
              conversion + 'WARM WAIT3000 ' + conversion + 'HITS WAIT33000 ' +
              conversion + 'EXPIRY WAIT3000 ' + conversion + 'DOWN WAIT65000 ' +
              conversion + 'RECOVER WAIT3000 ' + conversion + 'FINAL WAITACK10000:6')
    bin_dir = ROOT / args.build_dir / 'Release'
    command = [sys.executable, '-B', str(Path(__file__).with_name('host-test-process-guard.py')),
        'run', '--root', str(ROOT), '--cleanup', '--', 'pwsh', '-NoProfile', '-File',
        str(Path(__file__).with_name('run-harness.ps1')), '-Script', tokens,
        '-EngineHostPath', str(bin_dir / 'ddskk-engine-host.exe'), '-EngineExecutablePath', args.runtime,
        '-RepositoryPath', str(ROOT), '-DllPath', str(bin_dir / 'ddskk-ime.dll'),
        '-CoreDllPath', str(bin_dir / 'ddskk-ime-core.dll'), '-TsfHostExe', str(bin_dir / 'tsf-host.exe'),
        '-LocalConversion', '1', '-SkkServEnable', '1', '-SkkServPort', env['DDSKK_SKKSERV_PORT'],
        '-ColdLoadSleepSec', str(args.cold_load_sleep_sec), '-SkipEngineWarmup',
        '-PipeWaitTimeoutSec', '10', '-TsfHostTimeoutSec', '220', '-ArtifactDirectory', str(run / 'harness')]
    job = transport.Job(); process = None; held = None; suspended = False
    samples = {'ZERO': {g: [0, 0] for g in GROUPS}}; cache_fetches = []
    def text(path):
        return path.read_text('utf-8', errors='replace') if path.exists() else ''
    def host():
        return text(Path(str(host_path) + '.1')) + text(host_path)
    def tsf():
        paths = list((run / 'harness').rglob('tsf.stdout.log'))
        if len(paths) > 1:
            raise AssertionError('more than one private TSF stack')
        return text(paths[0]) if paths else ''
    def until(predicate, seconds=60):
        end = min(started + 255, time.monotonic() + seconds)
        while time.monotonic() < end:
            value = predicate()
            if value:
                return value
            if process.poll() is not None or errors:
                raise AssertionError('harness ended/fixture failed before evidence: ' + str(errors))
            time.sleep(.05)
        raise AssertionError('coverage evidence deadline')
    def snapshot(label):
        # Worker logs at <=100 ms cadence; no callback waits for telemetry.
        time.sleep(.5); samples[label] = counters(host())
        print('COUNTS ' + label + ' ' + json.dumps(samples[label]), flush=True)
    def request(data):
        pipe = transport.Pipe(pipe_name, timeout=2000)
        try:
            pipe.transfer(data, timeout=2000)
            reply, more = pipe.transfer(timeout=2000)
            if more:
                raise AssertionError('oversized private control reply')
            return reply
        finally:
            pipe.close()
    def configure_server(enabled):
        # Derive only this harness's private key from its copied pipe identity.
        # Open an existing key; never create keys or touch the installed IME.
        import winreg
        key = private_key(pipe_name)
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, key, 0, winreg.KEY_SET_VALUE) as handle:
            winreg.SetValueEx(handle, 'SkkServEnable', 0, winreg.REG_DWORD, int(enabled))
        print('PRIVATE_SERVER enabled=' + str(int(enabled)), flush=True)
    def server_miss():
        until(lambda: request(b'LOCAL SERVER 00304b00306a -') == b'SERVER 4', 3)
    def suspend(resume=False):
        fn = getattr(C.WinDLL('ntdll'), 'NtResumeProcess' if resume else 'NtSuspendProcess')
        fn.argtypes, fn.restype = [W.HANDLE], W.LONG
        if fn(held) != 0:
            raise AssertionError('policy suspend/resume failed')
    def replay_ack(identity):
        operation, sequence = identity
        wire = f'LOCAL LEARN {operation} 00304b00306a 004eee00540d'.encode()
        expected = f'ACK {operation} {sequence}'.encode()
        if request(wire) != expected:
            raise AssertionError('acknowledged learning ID/sequence lost: ' + operation)
    try:
        process = job.spawn(command, env, gate_path)
        pipe_name = until(lambda: (m.group(1) if (m := re.search(r'run-harness: pipe=(\S+)', text(gate_path))) else None), 10)
        until(lambda: 'AFTER COLD ' in tsf(), 90); snapshot('COLD')
        server_miss(); time.sleep(.5); server_miss()
        # Cache's independent S3 comparison remains eagerly observed. Keep the
        # server disabled for steady local conversions so that observer is not
        # confused with authoritative CacheTtl/Capacity memo-hit evaluations.
        configure_server(False); server_miss()
        if request(b'ENGINE RELOAD') != b'OK RELOADING':
            raise AssertionError('private engine reload failed')
        until(lambda: 'AFTER WARM ' in tsf(), 70); snapshot('WARM')
        server_miss() # Exercise a seeded SOURCES hit within the steady window.
        until(lambda: 'AFTER HITS ' in tsf(), 10); snapshot('HITS')
        # Leave exact source/cache signatures idle beyond the policy memo's 30 s.
        # Also prove the real 2 s negative cache refetches, without a new override.
        configure_server(True); server_miss(); time.sleep(.3); server_miss()
        time.sleep(30.5); cache_fetches.append(fetches[0]); server_miss()
        until(lambda: fetches[0] > cache_fetches[0], 3); cache_fetches.append(fetches[0])
        until(lambda: 'AFTER EXPIRY ' in tsf(), 10); snapshot('EXPIRY')
        acknowledged = until(lambda: re.findall(r'LOCAL_ACK id=(\S+) sequence=([1-9]\d*)', tsf()), 3)
        for identity in acknowledged:
            replay_ack(identity)
        policy_pid = int(re.findall(r'policy-start pid=(\d+)', host())[-1])
        held = transport.api('OpenProcess', W.HANDLE, W.DWORD, W.BOOL, W.DWORD)(0x1FFFFF, False, policy_pid)
        member = W.BOOL()
        if not held or not transport.api('IsProcessInJob', W.BOOL, W.HANDLE, W.HANDLE, C.POINTER(W.BOOL))(
                held, job.handle, C.byref(member)) or not member.value or transport.wait(held, 0) != 258:
            raise AssertionError('refuse fault against unowned/exited policy child')
        before = host().count('policy-timeout-discard'); late = host().count('policy-late-discard')
        if 'AFTER DOWN ' in tsf():
            raise AssertionError('missed conversion pause window')
        suspend(); suspended = True; server_miss()
        until(lambda: host().count('policy-timeout-discard') > before, 2)
        pressure(pipe_name, transport)
        time.sleep(3) # Emulate GC while DOWN conversion runs.
        if 'AFTER DOWN ' not in tsf():
            raise AssertionError('conversion did not complete during policy GC pause')
        suspend(True); suspended = False
        until(lambda: host().count('policy-late-discard') > late, 4)
        if not transport.api('TerminateProcess', W.BOOL, W.HANDLE, W.UINT)(held, 17):
            raise AssertionError('owned policy kill failed')
        until(lambda: 'policy-retire pid=' + str(policy_pid) in host(), 2); server_miss()
        until(lambda: 'AFTER DOWN ' in tsf(), 15); snapshot('DOWN')
        configure_server(False); server_miss()
        until(lambda: 'AFTER RECOVER ' in tsf(), 70); snapshot('RECOVER')
        for identity in acknowledged:
            replay_ack(identity)
        server_miss()
        until(lambda: 'AFTER FINAL ' in tsf(), 10); snapshot('FINAL')
        process.wait(timeout=min(15, max(1, 265 - (time.monotonic() - started))))
        if process.returncode or not re.search(r'GUARD .*"leftovers": \[\]', text(gate_path)):
            raise AssertionError('harness/owned cleanup failed')
        print('NOTE wrong/late HN3 injection skipped: no existing fenced frame-injection hook; HP2 late-discard exercised', flush=True)
        report = check(tsf(), host(), samples, cache_fetches, time.monotonic() - started)
        report['acknowledged_ids_preserved'] = acknowledged
        report['pressure'] = dict(clients=4, exact_replies=32)
        (run / 'coverage.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
        print('PASS S4.3 native startup ' + json.dumps(report), flush=True)
    finally:
        (run / 'samples.json').write_text(json.dumps(samples, indent=2) + '\n', encoding='utf-8')
        if suspended:
            try:
                suspend(True)
            except Exception as error:
                print('CLEANUP resume: ' + str(error), flush=True)
        if held:
            transport.close(held)
        if process and process.poll() is None:
            try:
                request(b'SHUTDOWN'); process.wait(timeout=8)
            except Exception:
                pass
        job.close()
        try:
            if process:
                process.wait(timeout=5)
        finally:
            stop.set(); server.join(2); listener.close()
            print('ARTIFACTS ' + str(run), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--runtime')
    parser.add_argument('--build-dir', default='build/w')
    parser.add_argument('--cold-load-sleep-sec', type=int, choices=[45], default=45)
    args = parser.parse_args()
    try:
        if args.self_test:
            self_test()
        elif not args.runtime:
            parser.error('--runtime required for stack run')
        else:
            main(args)
    except Exception as error:
        print('FAIL S4.3 native startup ' + str(error), flush=True)
        raise SystemExit(1)
