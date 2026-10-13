"""Coordinator-only S1.3: sequential C++ and native private stack phases."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import importlib.util
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
GROUPS = ('SOURCES', 'CACHE', 'RESTART', 'PUBLICATION', 'LEARNING')


def native_bundle():
    # Offline preparation. A prebuilt bundle leaves more of the six-minute
    # coordinator qualification budget for the private stack.
    for name in ('HN_NATIVE_RUNTIME', 'HN_NELISP_SRC'):
        Path(os.environ[name]).resolve(strict=True)
    spec = importlib.util.spec_from_file_location('hn_bundle', ROOT / 'tools/ai/hn-native-bundle.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    if value := os.environ.get('DDSKK_HOST_POLICY_BUNDLE'):
        bundle = Path(value).resolve(strict=True)
        if not bundle.is_relative_to(Path(os.environ['LOCALAPPDATA']).resolve(strict=True)):
            raise AssertionError('bundle must be private under LOCALAPPDATA')
        manifest = json.loads((bundle / 'manifest.json').read_text('utf-8'))
        if manifest['version'] != 1 or manifest['dialect'] != 'pinned' or manifest['backend'] != 'template':
            raise AssertionError('incompatible bundle')
        module.validate_counts(manifest['native_count'], sum(map(len, manifest['functions'].values())), manifest['refused'])
        if manifest['interpreted_count'] != len(manifest['refused']):
            raise AssertionError('bundle interpreted count mismatch')
        if manifest['pins'][0]['path'] != str(Path(os.environ['HN_NATIVE_RUNTIME']).resolve(strict=True)):
            raise AssertionError('bundle runtime mismatch')
        for pin in manifest['pins']:
            if module.digest(pin['path']) != pin['sha256']:
                raise AssertionError('bundle pin mismatch')
        return bundle
    return module.build(Path(os.environ['LOCALAPPDATA']) / ('hn-e2e-' + uuid.uuid4().hex))


def pressure(pipe_name, transport):
    """Small variant of host-contracts' simultaneous client/barrier helper."""
    barrier = threading.Barrier(4)
    def client(index):
        pipe = transport.Pipe(pipe_name, timeout=2000)
        try:
            barrier.wait(timeout=5)
            for _ in range(8):
                pipe.transfer(b'ENGINE CURRENT', timeout=2000)
                reply, more = pipe.transfer(timeout=2000)
                if more or reply != b'ENGINE ddskk':
                    raise AssertionError('concurrent client reply')
            return 8
        finally:
            pipe.close()
    with ThreadPoolExecutor(max_workers=4) as pool:
        completed = sum(pool.map(client, range(4)))
    if completed != 32:
        raise AssertionError('missing concurrent replies')
    print('PRESSURE clients=4 exact_replies=32', flush=True)


def bundle_evidence(host, minimum=1):
    rows = re.findall(r'HN-BUNDLE native=(\d+) interpreted=(\d+) refused=([^\s]+)', host)
    if len(rows) < minimum:
        raise AssertionError('missing bundle counts/refused list')
    reports = []
    for native, interpreted, refused in rows:
        names = [] if refused == '-' else refused.split(',')
        if int(native) < 1 or int(interpreted) != len(names) or len(set(names)) != len(names):
            raise AssertionError('invalid bundle counts/zero native callables')
        reports.append(dict(native=int(native), interpreted=int(interpreted), refused=names))
    return reports


def check_phase(tsf, host, guard, native):
    documents = re.findall(r'AFTER (COLD|WARM|FINAL) BUF=\[([^\r\n]*)\].*COMP=-', tsf)
    if documents != [('COLD', 'あい'), ('WARM', 'あい仮名'), ('FINAL', 'あい仮名仮名')]:
        raise AssertionError('exact committed documents/composition')
    probes = re.findall(r'CALLBACK_IO hooks=(\d+) mask=(\d+) pipe_io=(\d+) blocking_waits=(\d+)', tsf)
    if len(probes) < 10 or any(int(mask) & 271 != 271 or int(io) or int(waits) for _, mask, io, waits in probes):
        raise AssertionError('callback coverage/IO/waits')
    times = list(map(int, re.findall(r'KEYLAT token=\S+ .*?total_us=(\d+) claimed=1', tsf)))
    if not times or max(times) > 20000 or 'SETTLE TIMEOUT' in tsf:
        raise AssertionError('20 ms callback watchdog/settle')
    ack_wait = re.search(r'LOCAL_ACK_WAIT OK required=2 observed=(\d+)', tsf)
    ack_ids = dict(re.findall(r'LOCAL_ACK id=(\S+) sequence=([1-9]\d*)', tsf))
    if not ack_wait or int(ack_wait[1]) < 2 or len(ack_ids) < 2:
        raise AssertionError('acknowledged learning barrier')
    if not re.search(r'GUARD .*"leftovers": \[\]', guard):
        raise AssertionError('owned-PID cleanup missing')
    # Counter native=N counts C++ evaluations, not native policy children.
    ready = re.findall(r'policy-ready startup_ms=\d+ native=([01])\b', host)
    if not ready:
        raise AssertionError('missing policy-ready evidence')
    if native and any(state != '1' for state in ready):
        raise AssertionError('native policy unavailable')
    if not native and (any(state != '0' for state in ready) or 'HN-BUNDLE' in host or
                       re.search(r'HP2 READY HN3=1 native=1\b', host)):
        raise AssertionError('baseline unexpectedly native')
    if any(int(ms) > 60000 for ms in re.findall(r'policy-ready startup_ms=(\d+)', host)):
        raise AssertionError('60 s policy startup budget')
    bundle = bundle_evidence(host) if native else []
    return dict(bundle=bundle, documents=documents, callback_max_us=max(times), callback_waits=0, owned_pid_leftovers=[])


def self_test():
    tsf = '\n'.join(f'AFTER {label} BUF=[{doc}] COMP=-' for label, doc in
                    [('COLD', 'あい'), ('WARM', 'あい仮名'), ('FINAL', 'あい仮名仮名')])
    tsf += '\n' + 'CALLBACK_IO hooks=5 mask=271 pipe_io=0 blocking_waits=0\n' * 10
    tsf += 'KEYLAT token=K total_us=1 claimed=1\nLOCAL_ACK_WAIT OK required=2 observed=2\n'
    tsf += 'LOCAL_ACK id=fixture.1 sequence=1\nLOCAL_ACK id=fixture.2 sequence=2\n'
    host, guard = 'policy-ready startup_ms=1 native=1\nHN-BUNDLE native=11 interpreted=1 refused=host-policy-hn3-reply', 'GUARD {"leftovers": []}'
    check_phase(tsf, host, guard, True)
    baseline = 'policy-ready startup_ms=5 native=0\n'
    baseline += ''.join(f'policy-evaluations group={group} native=1 nelisp-selected=1\n'
                        for group in GROUPS)
    check_phase(tsf, baseline, guard, False)
    baseline_bad = [baseline.replace('startup_ms=5 native=0', 'startup_ms=5 native=1'),
                    baseline + '\nHN-BUNDLE native=11 interpreted=0 refused=-',
                    baseline + '\nHP2 READY HN3=1 native=1',
                    baseline.replace('policy-ready', 'missing-ready')]
    for evidence in baseline_bad:
        try:
            check_phase(tsf, evidence, guard, False)
        except AssertionError:
            continue
        raise AssertionError('native/missing baseline evidence accepted')
    bad = [(tsf, host.replace('HN-BUNDLE native=11', 'HN-BUNDLE native=0'), guard),
           (tsf, host.split('\n')[0], guard),
           (tsf.replace('仮名', 'wrong'), host, guard),
           (tsf.replace('blocking_waits=0', 'blocking_waits=1'), host, guard),
           (tsf.replace('mask=271', 'mask=0'), host, guard),
           (tsf.replace('total_us=1', 'total_us=20001'), host, guard),
           (tsf.replace('LOCAL_ACK_WAIT OK', 'LOCAL_ACK_WAIT TIMEOUT'), host, guard),
           (tsf, host.replace('startup_ms=1 native=1', 'startup_ms=1 native=0'), guard), (tsf, host, ''),
           (tsf.replace('sequence=2', 'sequence=0'), host, guard)]
    for args in bad:
        try:
            check_phase(*args, True)
        except AssertionError:
            continue
        raise AssertionError('bad evidence accepted')
    print(f'PASS S1.3 checker negative_controls={len(bad)+len(baseline_bad)} stacks=0')


def main(args):
    started = time.monotonic()
    bundle = native_bundle()
    if time.monotonic() - started > 75:
        raise AssertionError('offline preparation consumed stack budget; prebuild DDSKK_HOST_POLICY_BUNDLE')
    spec = importlib.util.spec_from_file_location('transport', Path(__file__).with_name('host-contracts.py'))
    transport = importlib.util.module_from_spec(spec); spec.loader.exec_module(transport)
    run = (ROOT / args.build_dir / ('hn-e2e-baseline-' + uuid.uuid4().hex)).resolve()
    if not run.is_relative_to((ROOT / 'build').resolve()):
        raise AssertionError('private build directory required')
    run.mkdir(parents=True)
    # PUBLIC fixture server, bounded to the harness's allowlisted port range.
    listener = socket.socket()
    for port in range(31100, 31200):
        try:
            listener.bind(('127.0.0.1', port)); break
        except OSError:
            continue
    else:
        raise AssertionError('private fixture port unavailable')
    listener.listen(); listener.settimeout(.2)
    stop = threading.Event(); errors = []
    def serve():
        while not stop.is_set():
            try:
                client, _ = listener.accept()
            except socket.timeout:
                continue
            try:
                with client:
                    client.settimeout(2); wire = b''
                    while not wire.endswith(b' '):
                        part = client.recv(4096)
                        if not part:
                            break
                        wire += part
                        if len(wire) > 4096:
                            raise AssertionError('fixture request bound')
                    if wire.startswith(b'1'):
                        client.sendall(b'4\n')
            except Exception as error:
                errors.append(str(error))
    server = threading.Thread(target=serve, daemon=True); server.start()
    reports = {}
    try:
        for phase in ('cpp', 'native'):
            work = run / phase; work.mkdir()
            env = dict(os.environ, DDSKK_HOST_NATIVE_MERGE='0', DDSKK_HOST_NATIVE_STARTUP='0',
                       DDSKK_HOST_POLICY_SHADOW='0', DDSKK_HOST_POLICY_COUNTERS='1',
                       DDSKK_HARNESS_DIAGNOSTICS='1', NATIVEIME_TEST_CALLBACK_IO_PROBE='1',
                       NATIVEIME_TEST_CALLBACK_WAIT_CONTROL='0', NELISP_IME_ENGINE='ddskk',
                       DDSKK_HOST_LOG=str(work / 'host.log'),
                       DDSKK_DICTIONARY_FILES=str(Path(__file__).with_name('data') / 'behavior-jisyo.utf8'),
                       DDSKK_SKKSERV_HOST='127.0.0.1', DDSKK_SKKSERV_PORT=str(port))
            for key in ('DDSKK_HOST_POLICY_RUNTIME', 'DDSKK_HOST_POLICY_BUNDLE', 'DDSKK_SKKSERV_START_COMMAND',
                        'DDSKK_SKKSERV_ENABLE', 'DDSKK_HOST_POLICY_TEST_PAUSE_KIND'):
                env.pop(key, None)
            for group in GROUPS:
                env['DDSKK_HOST_POLICY_' + group] = '1'
            if phase == 'native':
                env.update(DDSKK_HOST_POLICY_RUNTIME=os.environ['HN_NATIVE_RUNTIME'], DDSKK_HOST_POLICY_BUNDLE=str(bundle))
            tokens = ('a i SPACE WAIT3000 ENTER SETTLE30000:COLD '
                      'K a n a SPACE ENTER SETTLE30000:WARM WAIT3000 '
                      'K a n a SPACE ENTER SETTLE30000:FINAL WAITACK10000:2')
            bin_dir = ROOT / args.build_dir / 'Release'
            command = [sys.executable, '-B', str(Path(__file__).with_name('host-test-process-guard.py')),
                       'run', '--root', str(ROOT), '--cleanup', '--', 'pwsh', '-NoProfile', '-File',
                       str(Path(__file__).with_name('run-harness.ps1')), '-Script', tokens,
                       '-EngineHostPath', str(bin_dir / 'ddskk-engine-host.exe'), '-EngineExecutablePath', args.runtime,
                       '-RepositoryPath', str(ROOT), '-DllPath', str(bin_dir / 'ddskk-ime.dll'),
                       '-CoreDllPath', str(bin_dir / 'ddskk-ime-core.dll'), '-TsfHostExe', str(bin_dir / 'tsf-host.exe'),
                       '-LocalConversion', '1', '-SkkServEnable', '1', '-SkkServPort', str(port),
                       '-ColdLoadSleepSec', str(args.cold_load_sleep_sec), '-SkipEngineWarmup',
                       '-PipeWaitTimeoutSec', '65', '-TsfHostTimeoutSec', '110', '-ArtifactDirectory', str(work / 'harness')]
            job = transport.Job(); process = None
            try:
                process = job.spawn(command, env, work / 'guard.log')
                process.wait(timeout=max(1, 350 - (time.monotonic() - started)))
            finally:
                job.close()
                if process:
                    process.wait(timeout=5)
            guard = (work / 'guard.log').read_text('utf-8', errors='replace')
            if process.returncode or errors:
                raise AssertionError('phase failed: ' + phase + ' ' + str(errors))
            logs = list((work / 'harness').rglob('tsf.stdout.log'))
            if len(logs) != 1:
                raise AssertionError('expected exactly one private stack per sequential phase')
            host = ''.join(p.read_text('utf-8', errors='replace') for p in
                           (Path(str(work / 'host.log') + '.1'), work / 'host.log') if p.exists())
            reports[phase] = check_phase(logs[0].read_text('utf-8', errors='replace'), host, guard, phase == 'native')
        if reports['cpp']['documents'] != reports['native']['documents'] or time.monotonic() - started >= 360:
            raise AssertionError('same-run C++ parity/six-minute bound')
        (run / 'receipt.json').write_text(json.dumps(reports, indent=2) + '\n', encoding='utf-8', newline='\n')
        print('PASS S1.3 sequential native/C++ baseline ' + json.dumps(reports), flush=True)
    finally:
        stop.set(); server.join(3); listener.close()
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
            parser.error('--runtime required')
        else:
            main(args)
    except Exception as error:
        print('FAIL S1.3 ' + str(error), flush=True)
        raise SystemExit(1)
