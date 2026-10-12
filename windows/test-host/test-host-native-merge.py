"""Coordinator-only HN8 one-stack ON then SHADOW gate. --self-test starts none."""
import argparse
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


def counts(host, group):
    rows = re.findall(r'policy-evaluations group=' + group + r' native=(\d+) nelisp-selected=(\d+)', host)
    if not rows:
        raise AssertionError('missing counters: ' + group)
    return list(map(int, rows[-1]))


def check(tsf, on, shadow, elapsed):
    if elapsed >= 285:
        raise AssertionError('five-minute gate bound exceeded')
    for label, document in [('ON','Alpha'),('SHADOW','AlphaBeta')]:
        if not re.search(r'AFTER ' + label + r' BUF=\[' + document + r'\].*COMP=-', tsf):
            raise AssertionError('exact committed document: ' + label)
    probes = re.findall(r'CALLBACK_IO hooks=(\d+) mask=(\d+) pipe_io=(\d+) blocking_waits=(\d+)', tsf)
    if len(probes) < 10 or any(int(mask) & 271 != 271 or int(io) or int(waits) for _,mask,io,waits in probes):
        raise AssertionError('callback probe missing or IO/wait observed')
    times = list(map(int,re.findall(r'KEYLAT token=\S+ .*?total_us=(\d+) claimed=1',tsf)))
    if not times or max(times) > 20000 or 'SETTLE TIMEOUT' in tsf:
        raise AssertionError('callback/settle deadline')
    for op in (1,2,3):
        if f'hn3-answer operation={op}' not in on or f'hn3-shadow match operation={op}' not in shadow:
            raise AssertionError('unanswered ON or unpaired SHADOW merge operation=' + str(op))
    if 'hn3-answer operation=5' not in on or 'hn3-startup-selection runner=ddskk' not in on:
        raise AssertionError('startup did not select through HN3 before initial child')
    if on.index('hn3-answer operation=5') > on.index('child-start pid='):
        raise AssertionError('startup HN3 happened after spawn')
    if 'hn3-shadow match operation=5' not in shadow:
        raise AssertionError('startup SHADOW missing after reload')
    host = on + shadow
    if 'hn3-shadow mismatch' in host or 'policy-compare mismatch' in host:
        raise AssertionError('shadow mismatch')
    if counts(on,'MERGE')[1] < 3 or counts(on,'STARTUP')[1] < 1:
        raise AssertionError('missing NeLisp selection counters')
    if counts(host,'MERGE')[0] <= counts(on,'MERGE')[0] or counts(host,'STARTUP')[0] <= counts(on,'STARTUP')[0]:
        raise AssertionError('SHADOW did not execute C++ owners')
    return dict(exact_documents=2, merge_operations=3, startup_hn3=True, shadow_mismatches=0,
                callback_probes=len(probes), callback_io=0, callback_waits=0, callback_max_us=max(times),
                merge_counts=counts(host,'MERGE'), startup_counts=counts(host,'STARTUP'))


def self_test():
    tsf = 'AFTER ON BUF=[Alpha] COMP=-\nAFTER SHADOW BUF=[AlphaBeta] COMP=-\n'
    tsf += ('CALLBACK_IO hooks=5 mask=271 pipe_io=0 blocking_waits=0\n'*10)
    tsf += 'KEYLAT token=K total_us=1 claimed=1\n'
    on = ('hn3-answer operation=5\nhn3-startup-selection runner=ddskk\nchild-start pid=1\n' +
          ''.join(f'hn3-answer operation={i}\n' for i in (1,2,3)) +
          'policy-evaluations group=MERGE native=0 nelisp-selected=3\npolicy-evaluations group=STARTUP native=0 nelisp-selected=1\n')
    shadow = ''.join(f'hn3-shadow match operation={i}\n' for i in (1,2,3,5))
    shadow += 'policy-evaluations group=MERGE native=3 nelisp-selected=3\npolicy-evaluations group=STARTUP native=1 nelisp-selected=1\n'
    check(tsf,on,shadow,1)
    cases = [(tsf.replace('AlphaBeta','wrong'),on,shadow,1),
             (tsf.replace('blocking_waits=0','blocking_waits=1'),on,shadow,1),
             (tsf.replace('mask=271','mask=0'),on,shadow,1),
             (tsf.replace('total_us=1','total_us=20001'),on,shadow,1),
             (tsf,on,shadow.replace('match operation=3','mismatch operation=3'),1),
             (tsf,on.replace('hn3-answer operation=5',''),shadow,1),
             (tsf,on,shadow.replace('native=3','native=0'),1),
             (tsf,on,shadow,285)]
    for args in cases:
        try:
            check(*args)
        except (AssertionError,ValueError):
            continue
        raise AssertionError('negative control accepted')
    print(f'PASS HN8 checker negative_controls={len(cases)} stacks=0')


def main(args):
    # Import Win32 capabilities only on the coordinator's explicit stack run.
    spec = importlib.util.spec_from_file_location('transport', Path(__file__).with_name('host-contracts.py'))
    transport = importlib.util.module_from_spec(spec); spec.loader.exec_module(transport)
    run = ROOT / args.build_dir / ('hn8-merge-' + uuid.uuid4().hex)
    if not run.resolve().is_relative_to((ROOT / 'build').resolve()):
        raise AssertionError('private build directory required')
    run.mkdir(parents=True)
    first, second = run / 'public-first.utf8', run / 'public-second.utf8'
    first.write_text('かな /Alpha;first/[し/skipped/]/Zeta/\nかに /Beta;first/Eta/\n',encoding='utf-8')
    second.write_text('かな /Alpha;second/Omega/\nかに /Beta;second/Theta/\n',encoding='utf-8')
    host_path, gate_path = run / 'host.log', run / 'gate.log'
    env = dict(os.environ, DDSKK_HOST_NATIVE_MERGE='1', DDSKK_HOST_NATIVE_STARTUP='1',
               DDSKK_HOST_POLICY_COUNTERS='1', DDSKK_HOST_POLICY_SHADOW='0',
               DDSKK_HARNESS_DIAGNOSTICS='1', NATIVEIME_TEST_CALLBACK_IO_PROBE='1',
               NATIVEIME_TEST_CALLBACK_WAIT_CONTROL='0', DDSKK_HOST_LOG=str(host_path),
               DDSKK_DICTIONARY_FILES=str(first)+';'+str(second), NELISP_IME_ENGINE='ddskk',
               DDSKK_SKKSERV_HOST='127.0.0.1', DDSKK_SKKSERV_ENABLE='1')
    env.pop('DDSKK_SKKSERV_START_COMMAND',None); env.pop('DDSKK_HOST_POLICY_TEST_PAUSE_KIND',None)
    for group in ('SOURCES','CACHE','RESTART','PUBLICATION','LEARNING'):
        env['DDSKK_HOST_POLICY_'+group] = '1'
    listener = socket.socket()
    for port in range(31100,31200):
        try:
            listener.bind(('127.0.0.1',port)); break
        except OSError:
            continue
    else:
        raise AssertionError('no free port in 31100-31199')
    listener.listen(); listener.settimeout(.2)
    env['DDSKK_SKKSERV_PORT'] = str(listener.getsockname()[1])
    stop = threading.Event(); errors = []; keys = []
    def serve():
        while not stop.is_set():
            try:
                client,_ = listener.accept()
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
                        key = wire[1:].strip().decode('utf-8'); keys.append(key)
                        reply = {'かな':'1/Alpha;server/Gamma/\n','かに':'1/Beta;server/Delta/\n'}.get(key,'4\n')
                        client.sendall(reply.encode('utf-8'))
            except Exception as error:
                errors.append(str(error))
    server = threading.Thread(target=serve,daemon=True); server.start()
    tokens = ('K a n a SPACE SETTLE30000:ON_CAND ENTER SETTLE30000:ON WAIT65000 '
              'K a n i SPACE SETTLE30000:SHADOW_CAND ENTER SETTLE30000:SHADOW')
    bin_dir = ROOT / args.build_dir / 'Release'
    command = [sys.executable,'-B',str(Path(__file__).with_name('host-test-process-guard.py')),
        'run','--root',str(ROOT),'--cleanup','--','pwsh','-NoProfile','-File',str(Path(__file__).with_name('run-harness.ps1')),
        '-Script',tokens,'-EngineHostPath',str(bin_dir/'ddskk-engine-host.exe'),'-EngineExecutablePath',args.runtime,
        '-RepositoryPath',str(ROOT),'-DllPath',str(bin_dir/'ddskk-ime.dll'),'-CoreDllPath',str(bin_dir/'ddskk-ime-core.dll'),
        '-TsfHostExe',str(bin_dir/'tsf-host.exe'),'-LocalConversion','0','-SkkServEnable','1',
        '-SkkServPort',env['DDSKK_SKKSERV_PORT'],'-ColdLoadSleepSec',str(args.cold_load_sleep_sec),
        '-SkipEngineWarmup','-PipeWaitTimeoutSec','65','-TsfHostTimeoutSec','180','-ArtifactDirectory',str(run/'harness')]
    job = transport.Job(); process = None; started = time.monotonic(); pipe_name = None
    def text(path):
        return path.read_text('utf-8',errors='replace') if path.exists() else ''
    def host():
        return text(Path(str(host_path)+'.1')) + text(host_path)
    def tsf():
        paths = list((run/'harness').rglob('tsf.stdout.log'))
        if len(paths) > 1:
            raise AssertionError('more than one private stack')
        return text(paths[0]) if paths else ''
    def until(predicate,seconds,step):
        end = min(started+265,time.monotonic()+seconds)
        while time.monotonic() < end:
            value = predicate()
            if value:
                return value
            if process.poll() is not None or errors:
                raise AssertionError(step+': harness ended or fixture failed: '+str(errors))
            time.sleep(.05)
        raise AssertionError(step+': HN8 evidence deadline')
    def request(data, step):
        pipe = None
        try:
            pipe = transport.Pipe(pipe_name,timeout=2000)
            return pipe.request(data)
        except Exception as error:
            raise AssertionError(f'{step}: {error}') from error
        finally:
            if pipe is not None:
                pipe.close()
    try:
        process = job.spawn(command,env,gate_path)
        pipe_name = until(lambda: m.group(1) if (m := re.search(r'run-harness: pipe=(\S+)',text(gate_path))) else None,70,'discover private pipe')
        if not re.fullmatch(r'\\\\\.\\pipe\\ddskk-test-[0-9a-f]{12}',pipe_name):
            raise AssertionError('refuse non-private control pipe')
        until(lambda:'AFTER ON ' in tsf(),100,'ON committed document')
        until(lambda: counts(host(),'MERGE')[1] >= 3 if 'policy-evaluations group=MERGE' in host() else False,
              3,'ON managed merge counters')
        on = host()
        if request(b'HN3 TEST SHADOW', 'enable SHADOW after ON') != b'OK HN3 SHADOW':
            raise AssertionError('fenced SHADOW control rejected')
        if request(b'ENGINE RELOAD', 'reload for SHADOW startup') != b'OK RELOADING':
            raise AssertionError('private reload failed')
        until(lambda:'AFTER SHADOW ' in tsf(),90,'SHADOW committed document')
        process.wait(timeout=min(15,max(1,280-(time.monotonic()-started))))
        all_host = host(); shadow = all_host[len(on):]
        if process.returncode or not re.search(r'GUARD .*"leftovers": \[\]',text(gate_path)):
            raise AssertionError('harness or owned-PID cleanup failed')
        if not {'かな','かに'}.issubset(keys):
            raise AssertionError('both conversions did not query fake server')
        report = check(tsf(),on,shadow,time.monotonic()-started)
        (run/'receipt.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
        print('PASS HN8 one-stack '+json.dumps(report),flush=True)
    finally:
        if process and process.poll() is None and pipe_name:
            try:
                request(b'SHUTDOWN', 'cleanup SHUTDOWN'); process.wait(timeout=5)
            except Exception as error:
                print('CLEANUP HN8 '+str(error),flush=True)
        job.close()
        if process:
            process.wait(timeout=5)
        stop.set(); server.join(3); listener.close()
        print('ARTIFACTS '+str(run),flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-test',action='store_true')
    parser.add_argument('--runtime')
    parser.add_argument('--build-dir',default='build/w')
    parser.add_argument('--cold-load-sleep-sec',type=int,choices=[45],default=45)
    args = parser.parse_args()
    try:
        if args.self_test:
            self_test()
        elif not args.runtime:
            parser.error('--runtime required')
        else:
            main(args)
    except Exception as error:
        print('FAIL HN8 '+str(error),flush=True)
        raise SystemExit(1)
