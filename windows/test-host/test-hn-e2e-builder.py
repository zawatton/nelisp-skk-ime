"""HN13: strict builder/merge qualification; no product or ledger mutations.

Publication telemetry must attest per-file counts, source, and pinned native launch.
Fault restart initially falls back to C++, then checks retention on rebuild.
"""
import argparse
import copy
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import socket
import sys
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).parent
PUBLICATION = (r'\bbuilder-publish generation=(\d+) files=(\d+) entries=(\d+(?:,\d+)*)'
               r' source=(builder|cpp) native=([01]) ms=(\d+)\r?$')


def require(ok, reason):
    if not ok:
        raise AssertionError(reason)


def oracle(data):
    """Independent byte oracle for ParseFileReference / ParseSkkJisyo."""
    if data.startswith(b'\xef\xbb\xbf'):
        data = data[3:]
    result = {}
    for raw in data.split(b'\n'):
        line = raw.replace(b'\r', b'').replace(b'\n', b'')
        if not line or line.startswith(b';;'):
            continue
        space = line.find(b' ')
        slash = line.find(b'/', space) if space >= 0 else -1
        if slash >= 0:
            result[line[:space]] = line[slash:]
    return result


def fixtures(run, candidate='BuilderLast'):
    first, second, large = [run / name for name in
                            ('PUBLIC-first.utf8', 'PUBLIC-second.utf8', 'PUBLIC-large.utf8')]
    first.write_bytes(('\ufeff;; PUBLIC generated fixture\r\nかな /Discard/\r\n'
                       'broken\r\ninvalid no-slash\r\nかな /' + candidate +
                       ';last/Other/\r\nかに /BuilderSecond/').encode('utf-8'))
    second.write_bytes(b';; PUBLIC generated fixture\r\nmissing\r\n'
                       + 'かな /BuilderLast;dedup/SecondFile/\r\nかに /Discard/\r\nかに /BuilderSecond/OtherSecond/'.encode('utf-8'))
    if not large.exists():
        large.write_bytes((';; PUBLIC generated GC pressure\r\n' +
                           ''.join(f'pressure{i:05d} /Public{i:05d}/\r\n' for i in range(50000)) +
                           'かぬ /BuilderLarge/').encode('utf-8'))
    paths = [first, second, large]
    return paths, [len(oracle(path.read_bytes())) for path in paths]


def tails(values):
    require(bool(values), 'missing latency samples')
    ordered = sorted(values)
    return dict(samples=len(values), p50=ordered[math.ceil(len(values)*.5)-1],
                p99=ordered[math.ceil(len(values)*.99)-1], max=ordered[-1])


def publications(host, expected, source, native, generations):
    rows = [(int(gen), int(files), [int(v) for v in entries.split(',')], owner,
             int(pinned), int(ms))
            for gen, files, entries, owner, pinned, ms in re.findall(PUBLICATION, host, re.MULTILINE)]
    require(len(rows) == host.count('builder-publish'), 'malformed builder-publish telemetry')
    require(bool(rows), 'missing builder-publish files/entries/source/native telemetry')
    require([row[0] for row in rows] == generations, 'unexpected publication generations')
    require(all(row[1] == len(expected) and row[2] == expected and row[3] == source and row[4] == native
                for row in rows), 'builder publication files/entries/source/native mismatch')
    return rows


def documents(tsf):
    return dict(re.findall(r'AFTER ([A-Z][A-Z0-9_]*) BUF=\[([^\r\n]*)\].*COMP=-', tsf))


def check_phase(label, evidence, expected):
    host, tsf = evidence['host'], evidence['tsf']
    ready = re.findall(r'policy-ready startup_ms=\d+ native=([01])\b', host)
    require(ready and all(x == '1' for x in ready), label + ': missing native=1 policy READY')
    require('builder-shadow mismatch' not in host and 'hn3-shadow mismatch' not in host
            and 'policy-compare mismatch' not in host, label + ': shadow mismatch')
    docs = documents(tsf)
    require(docs.get('BASE') == 'BuilderLastBuilderSecondBuilderLarge', label + ': exact builder-only/last-wins/large commit')
    if label == 'ON':
        publications(host, expected, 'builder', 1, [1, 2])
        prior = docs['BASE']
        for i in range(12):
            current = docs.get(f'PRESSURE{i}')
            require(current in (prior + 'BuilderLast', prior + 'BuilderNew'),
                    f'partial generation answer PRESSURE{i}: {current!r}')
            prior = current
        require(docs.get('NEW') == prior + 'BuilderNew', 'new generation did not commit')
        require(evidence.get('overlap_samples', 0) >= 3, 'fewer than three conversions overlapping rebuild')
    elif label == 'FAULT':
        publications(host, expected, 'cpp', 0, [1])
        require(re.search(r'\bbuilder-fallback reason=transport generation=1 action=cpp fault=midstream\r?$', host, re.MULTILINE),
                'missing initial C++ fallback evidence')
        require(re.search(r'\bbuilder-fallback reason=transport generation=2 action=retain fault=midstream\r?$', host, re.MULTILINE),
                'missing retained-generation (action=retain) evidence')
        require(not re.search(r'builder-publish generation=2\b', host),
                'fault published new generation')
        starts = re.findall(r'builder-start pid=(\d+)', host)
        retires = re.findall(r'builder-retire pid=(\d+)', host)
        require(starts and all(pid in retires for pid in starts), 'fault builder child not retired')
        require(docs.get('RETAINED') == docs['BASE'] + 'BuilderLast', 'old candidate not retained')
    else:
        publications(host, expected, 'cpp', 1, [1])
        rows = re.findall(r'\bbuilder-shadow match files=(\d+) builder-counts=(\d+(?:,\d+)*) cpp-counts=(\d+(?:,\d+)*)\r?$', host, re.MULTILINE)
        require(len(rows) == 1 and int(rows[0][0]) == len(expected)
                and [int(v) for v in rows[0][1].split(',')] == expected
                and rows[0][1] == rows[0][2], 'shadow did not match every file/count')
    merge_prefix = 'hn3-shadow match' if label == 'SHADOW' else 'hn3-answer'
    for op in (1, 2, 3, 5):
        require(f'{merge_prefix} operation={op}' in host, label + f': missing HN3 operation={op}')
    counters = {}
    for group in ('MERGE', 'STARTUP'):
        rows = re.findall(r'policy-evaluations group=' + group + r' native=(\d+) nelisp-selected=(\d+)', host)
        require(rows, label + ': missing HN8 counters ' + group)
        counters[group] = list(map(int, rows[-1]))
        column = 0 if label == 'SHADOW' else 1
        require(counters[group][column] >= (3 if group == 'MERGE' else 1),
                label + ': missing HN8 selected/C++ owner counters ' + group)
    if label != 'SHADOW':
        require('hn3-startup-selection runner=ddskk' in host and 'child-start pid=' in host
                and host.index('hn3-answer operation=5') < host.index('child-start pid='), 'startup HN3 ordering')
    probes = re.findall(r'CALLBACK_IO hooks=(\d+) mask=(\d+) pipe_io=(\d+) blocking_waits=(\d+)', tsf)
    require(len(probes) >= 10 and all(int(mask) & 271 == 271 and not int(io) and not int(waits)
                                     for _, mask, io, waits in probes), label + ': CALLBACK_IO coverage/IO/waits')
    times = list(map(int, re.findall(r'KEYLAT token=\S+ .*?total_us=(\d+) claimed=1', tsf)))
    require(times and max(times) <= 20000 and 'SETTLE TIMEOUT' not in tsf, label + ': unchanged 20 ms watchdog')
    cached = tails(evidence['cached_ms'])
    require(cached['samples'] >= 200 and cached['p99'] <= 10 and cached['max'] <= 50, label + ': cached host p99/max ' + str(cached))
    require(re.search(r'GUARD .*"leftovers": \[\]', evidence['guard']), label + ': owned PID cleanup')
    return dict(documents=len(docs), callback_max_us=max(times), callback_probes=len(probes), cached_host_ms=cached,
                owner_counters=counters)


def check(evidence, expected, elapsed):
    require(elapsed <= 400, '400 s wall bound exceeded')
    report = {label: check_phase(label, evidence[label], expected) for label in ('ON', 'FAULT', 'SHADOW')}
    local = list(map(int, re.findall(r'SPACE-CANDIDATE ms=\d+ seq=\d+ path=local us=(\d+)', evidence['SHADOW']['tsf'])))
    metric = tails([v/1000 for v in local]) if local else None
    require(metric is not None, 'missing local SPACE path=local telemetry (no proxy accepted)')
    require(metric['p50'] <= 30, 'local SPACE p50 >30 ms')
    report.update(local_space_ms=metric, elapsed_s=round(elapsed, 3), files=len(expected),
                  per_file_entries=expected, callback_io=0, blocking_waits=0, fault_seed='cpp initial fallback')
    return report


def self_test():
    expected = [2, 2, 50001]
    require(oracle(b'\xef\xbb\xbf;;c\r\nk /old/\r\nbad\r\nk /last/') == {b'k': b'/last/'}, 'oracle edge cases')
    require(oracle(b'\xef\xbb\xbf\xef\xbb\xbfk /x/') == {b'\xef\xbb\xbfk': b'/x/'}, 'oracle second BOM')
    base = 'AFTER BASE BUF=[BuilderLastBuilderSecondBuilderLarge] COMP=-\n'
    base += 'CALLBACK_IO hooks=5 mask=271 pipe_io=0 blocking_waits=0\n'*10
    base += 'KEYLAT token=K total_us=1 claimed=1\n'
    native = 'policy-ready startup_ms=1 native=1\nhn3-startup-selection runner=ddskk\nhn3-answer operation=5\nchild-start pid=1\n'
    native += ''.join(f'hn3-answer operation={op}\n' for op in (1, 2, 3))
    native += 'policy-evaluations group=MERGE native=3 nelisp-selected=3\npolicy-evaluations group=STARTUP native=1 nelisp-selected=1\n'
    pub = 'builder-publish generation=1 files=3 entries=2,2,50001 source=builder native=1 ms=1\n'
    evidence = {label: dict(host=native, tsf=base, cached_ms=[1]*200,
                           overlap_samples=3, guard='GUARD {"leftovers": []}') for label in ('ON', 'FAULT', 'SHADOW')}
    evidence['ON']['host'] += pub + pub.replace('generation=1', 'generation=2')
    prior = 'BuilderLastBuilderSecondBuilderLarge'
    for i in range(12):
        prior += 'BuilderLast' if i < 6 else 'BuilderNew'
        evidence['ON']['tsf'] += f'AFTER PRESSURE{i} BUF=[{prior}] COMP=-\n'
    evidence['ON']['tsf'] += f'AFTER NEW BUF=[{prior}BuilderNew] COMP=-\n'
    evidence['FAULT']['host'] += ('builder-start pid=9\nbuilder-retire pid=9\n'
                                'builder-fallback reason=transport generation=1 action=cpp fault=midstream\n'
                                + pub.replace('source=builder native=1', 'source=cpp native=0') +
                                'builder-start pid=10\nbuilder-retire pid=10\n'
                                'builder-fallback reason=transport generation=2 action=retain fault=midstream\n')
    evidence['FAULT']['tsf'] += 'AFTER RETAINED BUF=[BuilderLastBuilderSecondBuilderLargeBuilderLast] COMP=-\n'
    evidence['SHADOW']['host'] = native.replace('hn3-answer', 'hn3-shadow match') + pub.replace('source=builder', 'source=cpp')
    evidence['SHADOW']['host'] += 'builder-shadow match files=3 builder-counts=2,2,50001 cpp-counts=2,2,50001\n'
    evidence['SHADOW']['tsf'] += 'SPACE-CANDIDATE ms=1 seq=1 path=local us=1000\n'
    check(evidence, expected, 1)
    cases = []
    for phase, field, old, new in [
        ('ON', 'tsf', 'AFTER PRESSURE0 BUF=[BuilderLastBuilderSecondBuilderLargeBuilderLast]', 'AFTER PRESSURE0 BUF=[]'),
        ('ON', 'host', 'native=1', 'native=0'),
        ('ON', 'host', 'entries=2,2,50001', 'entries=1,3,50001'),
        ('ON', 'host', 'entries=2,2,50001', 'entries=50005'),
        ('ON', 'host', 'source=builder native=1', 'source=builder native=0'),
        ('ON', 'host', 'source=builder', 'source=cpp'),
        ('ON', 'host', 'files=3', 'files=2'),
        ('ON', 'host', 'generation=2', 'generation=3'),
        ('ON', 'host', 'builder-publish', 'hn-builder published'),
        ('ON', 'host', 'ms=1\n', 'ms=1 junk\n'),
        ('FAULT', 'host', 'action=retain', 'action=cpp'),
        ('FAULT', 'host', 'source=cpp native=0', 'source=cpp native=1'),
        ('FAULT', 'host', 'generation=1 action=cpp', 'generation=1 action=retain'),
        ('FAULT', 'host', 'builder-retire pid=10\n', ''),
        ('SHADOW', 'host', 'source=cpp', 'source=builder'),
        ('SHADOW', 'host', 'source=cpp native=1', 'source=cpp native=0'),
        ('SHADOW', 'host', 'builder-shadow match', 'builder-shadow mismatch'),
        ('SHADOW', 'host', 'cpp-counts=2,2,50001', 'cpp-counts=1,3,50001'),
        ('SHADOW', 'tsf', 'path=local', 'path=other'),
        ('ON', 'tsf', 'blocking_waits=0', 'blocking_waits=1'),
        ('ON', 'tsf', 'total_us=1', 'total_us=20001')]:
        bad = copy.deepcopy(evidence)
        bad[phase][field] = bad[phase][field].replace(old, new)
        cases.append(bad)
    bad = copy.deepcopy(evidence); bad['ON']['cached_ms'] = [51]*200; cases.append(bad)
    bad = copy.deepcopy(evidence); bad['ON']['overlap_samples'] = 0; cases.append(bad)
    for bad in cases:
        try:
            check(bad, expected, 1)
        except AssertionError:
            continue
        raise AssertionError('negative control accepted')
    print('PASS HN13 builder-e2e ' + json.dumps(dict(self_test=True, negative_controls=len(cases), stacks=0)), flush=True)


def load_transport():
    spec = importlib.util.spec_from_file_location('hn13_transport', HERE / 'host-contracts.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


def main(args):
    run = (ROOT / args.build_dir / ('hn13-builder-' + uuid.uuid4().hex)).resolve()
    require(run.is_relative_to((ROOT / 'build').resolve()), 'private build directory required')
    run.mkdir(parents=True)
    print('ARTIFACTS ' + str(run), flush=True)
    started = time.monotonic()
    evidence = {}
    try:
        for name in ('runtime', 'policy_runtime', 'bundle'):
            require(Path(getattr(args, name)).exists(), name + ' does not exist')
        paths, expected = fixtures(run)
        (run / 'oracle.json').write_text(json.dumps(dict(files=[str(p) for p in paths], counts=expected), indent=2), 'utf-8')
        transport = load_transport()
        for label, mode, fault in [('ON', '1', ''), ('FAULT', '1', 'midstream'), ('SHADOW', '2', '')]:
            fixtures(run)
            evidence[label] = run_phase(args, run, label, mode, fault, paths, expected, started, transport)
            # Fail immediately on genuine missing product evidence; do not run more stacks.
            check_phase(label, evidence[label], expected)
        report = check(evidence, expected, time.monotonic()-started)
        (run / 'receipt.json').write_text(json.dumps(report, indent=2), 'utf-8')
        print('PASS HN13 builder-e2e ' + json.dumps(report), flush=True)
    except Exception as error:
        (run / 'failure.json').write_text(json.dumps(dict(reason=str(error), elapsed_s=time.monotonic()-started,
                                                        completed_phases=list(evidence)), indent=2), 'utf-8')
        raise


def conversion(reading, label):
    return reading + ' SPACE SETTLE30000:' + label + '_CAND ENTER SETTLE30000:' + label


def run_phase(args, run, label, mode, fault, paths, expected, started, transport):
    phase = run / label; phase.mkdir()
    host_path, gate_path = phase / 'host.log', phase / 'gate.log'
    base = ' '.join([conversion('K a n a', 'FIRST'), conversion('K a n i', 'SECOND'), conversion('K a n u', 'BASE')])
    if label == 'ON':
        tokens = base + ' WAIT1000 ' + ' '.join(conversion('K a n a', f'PRESSURE{i}') + ' WAIT250' for i in range(12))
        tokens += ' WAIT15000 ' + conversion('K a n a', 'NEW') + ' WAIT5000'
    elif label == 'FAULT':
        tokens = base + ' WAIT15000 ' + conversion('K a n a', 'RETAINED') + ' WAIT5000'
    else:
        tokens = base + ' WAIT5000 ' + conversion('K a n a', 'LOCAL1') + ' ' + conversion('K a n i', 'LOCAL2') + ' WAIT5000'
    env = dict(os.environ, DDSKK_HOST_NATIVE_MERGE='2' if label == 'SHADOW' else '1',
               DDSKK_HOST_NATIVE_STARTUP='2' if label == 'SHADOW' else '1', DDSKK_HOST_NATIVE_BUILDER=mode,
               DDSKK_HOST_POLICY_RUNTIME=args.policy_runtime, DDSKK_HOST_POLICY_BUNDLE=args.bundle,
               DDSKK_HOST_POLICY_COUNTERS='1', DDSKK_HOST_POLICY_SHADOW='0', DDSKK_HARNESS_DIAGNOSTICS='1',
               NATIVEIME_TEST_CALLBACK_IO_PROBE='1', NATIVEIME_TEST_CALLBACK_WAIT_CONTROL='0',
               DDSKK_HOST_LOG=str(host_path), DDSKK_DICTIONARY_FILES=';'.join(map(str, paths)),
               NELISP_IME_ENGINE='ddskk', DDSKK_LEARN_DISABLED='1', DDSKK_SKKSERV_HOST='127.0.0.1', DDSKK_SKKSERV_ENABLE='1')
    for key in ('DDSKK_HOST_POLICY_TEST_PAUSE_KIND', 'DDSKK_SKKSERV_START_COMMAND', 'DDSKK_HARNESS_LOCAL_CONVERSION',
                'DDSKK_HOST_NATIVE_ENTRY', 'DDSKK_HOST_BUNDLE_ENTRY', 'DDSKK_HOST_BUILDER_TEST_FAULT'):
        env.pop(key, None)
    if fault:
        env['DDSKK_HOST_BUILDER_TEST_FAULT'] = fault
    for group in ('SOURCES', 'CACHE', 'RESTART', 'PUBLICATION', 'LEARNING'):
        env['DDSKK_HOST_POLICY_' + group] = '1'
    listener = socket.socket(); stop = threading.Event(); server = None
    process = None; job = transport.Job(); pipe_name = None; errors = []; cache = []; overlap = 0
    def read(path):
        return path.read_text('utf-8', errors='replace') if path.exists() else ''
    def host():
        return read(Path(str(host_path) + '.1')) + read(host_path)
    def tsf():
        logs = list((phase / 'harness').rglob('tsf.stdout.log'))
        require(len(logs) <= 1, 'more than one private stack in phase')
        return read(logs[0]) if logs else ''
    def until(predicate, seconds, step):
        deadline = min(started+380, time.monotonic()+seconds)
        while time.monotonic() < deadline:
            result = predicate()
            if result:
                return result
            if process.poll() is not None:
                guard = read(gate_path)
                if 'Access to the registry key' in guard and 'is denied' in guard:
                    raise AssertionError('environment: private HKCU NativeIME-test- registry creation denied; '
                                         'host not started; see ' + str(gate_path))
                raise AssertionError(step + ': harness exit=' + str(process.returncode) + '; see ' + str(gate_path))
            require(not errors, step + ': fixture error ' + str(errors))
            time.sleep(.03)
        raise AssertionError(step + ': evidence deadline (400 s total bound)')
    def request(data):
        class BoundedPipe(transport.Pipe):
            def transfer(self, data=None, size=65536, timeout=30000):
                return super().transfer(data, size, timeout=min(2000, max(1, int((started+385-time.monotonic())*1000))))
        pipe = BoundedPipe(pipe_name, timeout=2000)
        try:
            return pipe.request(data)
        finally:
            pipe.close()
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
                        require(len(wire) <= 4096, 'server fixture bound')
                    if wire.startswith(b'1'):
                        client.sendall(b'1/ServerOnly/\n')
            except Exception as error:
                errors.append(str(error))
    try:
        for port in range(31100, 31200):
            try:
                listener.bind(('127.0.0.1', port)); break
            except OSError:
                continue
        else:
            raise AssertionError('no free loopback fixture port')
        listener.listen(); listener.settimeout(.2)
        env['DDSKK_SKKSERV_PORT'] = str(port)
        server = threading.Thread(target=serve, daemon=True); server.start()
        binaries = ROOT / args.build_dir / 'Release'
        command = [sys.executable, '-B', str(HERE / 'host-test-process-guard.py'), 'run', '--root', str(ROOT), '--cleanup', '--',
                   'pwsh', '-NoProfile', '-File', str(HERE / 'run-harness.ps1'), '-Script', tokens,
                   '-EngineHostPath', str(binaries / 'ddskk-engine-host.exe'), '-EngineExecutablePath', args.runtime,
                   '-RepositoryPath', str(ROOT), '-DllPath', str(binaries / 'ddskk-ime.dll'),
                   '-CoreDllPath', str(binaries / 'ddskk-ime-core.dll'), '-TsfHostExe', str(binaries / 'tsf-host.exe'),
                   '-LocalConversion', '0', '-SkkServEnable', '1', '-SkkServPort', str(port),
                   '-ColdLoadSleepSec', str(args.cold_load_sleep_sec), '-SkipEngineWarmup', '-PipeWaitTimeoutSec', '65',
                   '-TsfHostTimeoutSec', '100', '-ArtifactDirectory', str(phase / 'harness')]
        process = job.spawn(command, env, gate_path)
        pipe_name = until(lambda: m[1] if (m := re.search(r'run-harness: pipe=(\S+)', read(gate_path))) else None, 70, 'private pipe')
        require(re.fullmatch(r'\\\\\.\\pipe\\ddskk-test-[0-9a-f]{12}', pipe_name), 'refuse non-private pipe')
        until(lambda: 'AFTER BASE ' in tsf(), 100, label + ' base TSF conversion')
        if label == 'ON':
            # Stop before pressure if the product cannot attest generation 1.
            publications(host(), expected, 'builder', 1, [1])
        if label in ('ON', 'FAULT'):
            fixtures(run, 'BuilderNew')
            before = host()
            rebuild_start = time.monotonic()
            require(request(b'HN BUILDER REBUILD') == b'OK HN BUILDER REBUILD', 'private rebuild rejected')
            target = 'builder-publish generation=2' if label == 'ON' else 'action=retain'
            until(lambda: target in host()[len(before):], 30, label + ' rebuild')
            rebuild_end = time.monotonic()
            # Real timestamped key events, not the number of scripted intentions.
            ticks = [int(t)/1e6 for t in re.findall(r'SCRIPTKEY token=SPACE .*?utc_us=(\d+)', tsf())]
            end_wall = time.time(); begin_wall = end_wall - (rebuild_end-rebuild_start)
            overlap = sum(begin_wall <= t <= end_wall for t in ticks)
        else:
            # Switch only this private registry after provider-path builder proof.
            import winreg
            key_name = 'Software\\NativeIME-test-' + pipe_name.rsplit('-', 1)[1]
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, key_name, 0, winreg.KEY_SET_VALUE) as key:
                winreg.SetValueEx(key, 'LocalConversion', 0, winreg.REG_DWORD, 1)
        # Same synchronous transport/timer and cached queries as host-policy.py.
        for _ in range(60):
            for query, prefix in [(b'ENGINE CURRENT', b'ENGINE ddskk'), (b'ROMAJI RULES 1', b'RULES 1 '),
                                  (b'PREVIEW 00304b00306a', b'PREVIEW '), (b'DIAG CHILD-PID', b'PID ')]:
                now = time.perf_counter(); reply = request(query); cache.append((time.perf_counter()-now)*1000)
                require(reply.startswith(prefix), 'cached host reply mismatch')
        process.wait(timeout=max(1, min(100, started+380-time.monotonic())))
        require(process.returncode == 0, label + ': private harness exit=' + str(process.returncode))
        result = dict(host=host(), tsf=tsf(), guard=read(gate_path), cached_ms=cache, overlap_samples=overlap)
        (phase / 'evidence.json').write_text(json.dumps(result, indent=2), 'utf-8')
        return result
    finally:
        if process and process.poll() is None and pipe_name:
            try:
                request(b'SHUTDOWN'); process.wait(timeout=3)
            except Exception:
                pass
        job.close()
        if process:
            process.wait(timeout=5)
        stop.set()
        if server:
            server.join(2)
        listener.close()
        (phase / 'captured-host.log').write_text(host(), 'utf-8')
        (phase / 'captured-tsf.log').write_text(tsf(), 'utf-8')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--runtime')
    parser.add_argument('--policy-runtime')
    parser.add_argument('--bundle')
    parser.add_argument('--build-dir', default='build/w')
    parser.add_argument('--cold-load-sleep-sec', type=int, choices=[45], default=45)
    args = parser.parse_args()
    try:
        if args.self_test:
            self_test()
        else:
            require(args.runtime and args.policy_runtime and args.bundle, '--runtime, --policy-runtime and --bundle required')
            main(args)
    except Exception as error:
        print('FAIL HN13 builder-e2e reason=' + str(error), flush=True)
        sys.exit(1)
