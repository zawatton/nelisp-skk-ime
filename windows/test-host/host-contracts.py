"""Native reference capture/replay and adversarial private-pipe qualification.

Requires Windows and Python 3. No registry writes or live defaults. All spawned
processes are assigned, suspended, to a kill-on-close job before execution.
"""
import argparse
import base64
import concurrent.futures
import ctypes as C
from ctypes import wintypes as W
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
K = C.WinDLL('kernel32', use_last_error=True)
INVALID = C.c_void_p(-1).value


def api(name, result, *args):
    fn = getattr(K, name)
    fn.restype, fn.argtypes = result, args
    return fn


close = api('CloseHandle', W.BOOL, W.HANDLE)
create = api('CreateFileW', W.HANDLE, W.LPCWSTR, W.DWORD, W.DWORD,
             W.LPVOID, W.DWORD, W.DWORD, W.HANDLE)
wait_pipe = api('WaitNamedPipeW', W.BOOL, W.LPCWSTR, W.DWORD)
event = api('CreateEventW', W.HANDLE, W.LPVOID, W.BOOL, W.BOOL, W.LPCWSTR)
wait = api('WaitForSingleObject', W.DWORD, W.HANDLE, W.DWORD)
cancel = api('CancelIoEx', W.BOOL, W.HANDLE, W.LPVOID)
result = api('GetOverlappedResult', W.BOOL, W.HANDLE, W.LPVOID,
             C.POINTER(W.DWORD), W.BOOL)
read = api('ReadFile', W.BOOL, W.HANDLE, W.LPVOID, W.DWORD,
           C.POINTER(W.DWORD), W.LPVOID)
write = api('WriteFile', W.BOOL, W.HANDLE, W.LPCVOID, W.DWORD,
            C.POINTER(W.DWORD), W.LPVOID)
set_mode = api('SetNamedPipeHandleState', W.BOOL, W.HANDLE,
               C.POINTER(W.DWORD), W.LPVOID, W.LPVOID)


class Overlapped(C.Structure):
    _fields_ = [('internal', C.c_size_t), ('high', C.c_size_t),
                ('offset', W.DWORD), ('offset_high', W.DWORD), ('event', W.HANDLE)]


class Pipe:
    def __init__(self, name, timeout=30000):
        self.handle = None
        end = time.monotonic() + timeout / 1000
        while time.monotonic() < end:
            h = create(name, 0xC0000000, 0, None, 3, 0x40000000, None)
            if h != INVALID:
                self.handle = h
                break
            wait_pipe(name, 100)
            time.sleep(.01)
        if self.handle is None:
            raise TimeoutError('private pipe connect')
        mode = W.DWORD(2)
        if not set_mode(self.handle, C.byref(mode), None, None):
            self.close()
            raise C.WinError(C.get_last_error())

    def close(self):
        if self.handle:
            cancel(self.handle, None)
            close(self.handle)
            self.handle = None

    def transfer(self, data=None, size=65536, timeout=30000):
        buffer = C.create_string_buffer(data, len(data)) if data is not None else C.create_string_buffer(size)
        ov = Overlapped(event=event(None, True, False, None))
        count = W.DWORD()
        try:
            ok = (write if data is not None else read)(self.handle, buffer,
                len(data) if data is not None else size, C.byref(count), C.byref(ov))
            error = C.get_last_error() if not ok else 0
            if error == 234:
                result(self.handle, C.byref(ov), C.byref(count), False)
            if error == 997:
                if wait(ov.event, timeout) != 0:
                    cancel(self.handle, C.byref(ov))
                    result(self.handle, C.byref(ov), C.byref(count), True)
                    raise TimeoutError('pipe IO cancelled and drained')
                ok = result(self.handle, C.byref(ov), C.byref(count), False)
                error = C.get_last_error() if not ok else 0
            if error not in (0, 234):
                raise C.WinError(error)
            return buffer.raw[:count.value], error == 234
        finally:
            close(ov.event)

    def request(self, data, chunk=65536):
        self.transfer(data)
        parts = []
        while True:
            part, more = self.transfer(size=chunk)
            if not part:
                raise EOFError('host closed response')
            parts.append(part)
            if not more:
                return b''.join(parts)


class Job:
    def __init__(self):
        self.handle = api('CreateJobObjectW', W.HANDLE, W.LPVOID, W.LPCWSTR)(None, None)
        # JOBOBJECT_EXTENDED_LIMIT_INFORMATION: native x64 layout, LimitFlags offset 16.
        info = C.create_string_buffer(144)
        C.c_uint32.from_buffer(info, 16).value = 0x2000
        if not api('SetInformationJobObject', W.BOOL, W.HANDLE, C.c_int,
                   W.LPVOID, W.DWORD)(self.handle, 9, info, len(info)):
            raise C.WinError(C.get_last_error())

    def spawn(self, args, env, log):
        with open(log, 'wb') as output:
            p = subprocess.Popen(args, env=env, stdout=output, stderr=output,
                                 creationflags=0x08000004)
        if not api('AssignProcessToJobObject', W.BOOL, W.HANDLE, W.HANDLE)(self.handle, int(p._handle)):
            p.kill()
            p.wait()
            raise C.WinError(C.get_last_error())
        resume = C.WinDLL('ntdll').NtResumeProcess
        resume.argtypes, resume.restype = [W.HANDLE], W.LONG
        if resume(int(p._handle)) != 0:
            p.kill()
            p.wait()
            raise RuntimeError('resume failed')
        return p

    def close(self):
        close(self.handle)


class Host:
    def __init__(self, args):
        self.args = args
        self.run = ROOT / args.build_dir / ('eh2-' + uuid.uuid4().hex)
        self.run.mkdir(parents=True)
        self.name = r'\\.\pipe\EH2-' + uuid.uuid4().hex
        self.env = dict(os.environ, DDSKK_PIPE_NAME=self.name,
            NATIVEIME_REGISTRY_KEY='Software\\NativeIME-test-EH2-' + uuid.uuid4().hex,
            LOCALAPPDATA=str(self.run), DDSKK_USER_JISYO=str(self.run / 'user.jisyo'),
            DDSKK_DICTIONARY_FILES=str(ROOT / 'windows/test-host/data/behavior-jisyo.utf8'),
            DDSKK_SKKSERV_ENABLE='0', NELISP_IME_ENGINE=args.engine,
            DDSKK_HARNESS_DIAGNOSTICS='1', NATIVEIME_TEST_LOCAL_CONVERSION='1',
            DDSKK_HOST_LOG=str(self.run / 'host.log'))
        self.job = Job()
        self.process = None

    def start(self):
        self.process = self.job.spawn([str(Path(self.args.host).resolve()),
            str(Path(self.args.runtime).resolve()), str(ROOT)], self.env, self.run / 'stderr.log')
        time.sleep(self.args.cold_load_sleep_sec)
        if self.process.poll() is not None:
            raise RuntimeError('host exited: ' + str(self.run))
        return self

    def stop(self):
        self.job.close()
        if self.process:
            self.process.wait(timeout=10)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def normal(data, rule):
    if rule == 'pid':
        if not re.fullmatch(rb'PID [0-9]+', data):
            raise ValueError('invalid PID response')
        return b'PID <pid>'
    if rule:
        raise ValueError('unknown normalizer ' + rule)
    return data


def corpus(args, h):
    path = Path(args.fixture)
    plan = json.loads((ROOT / 'docs/contracts' / ('requests-v1.json' if args.engine == 'ddskk' else 'requests-legacy-v1.json')).read_text('utf-8'))
    expected = None if args.mode == 'capture' else json.loads(path.read_text('utf-8'))
    if expected is None:
        plan = [dict(item, request=item['request'].replace('{i}', str(i)))
                for item in plan for i in range(item.get('repeat', 1))]
    if expected is not None:
        if expected.get('engine', 'ddskk') != args.engine or expected['version'] != 1:
            raise AssertionError('fixture engine/version mismatch')
        raw = path.read_bytes()
        if digest(raw) != path.with_suffix('.sha256').read_text().split()[0]:
            raise AssertionError('fixture hash mismatch')
        plan = expected['records']
    records = []
    p = Pipe(h.name)
    try:
        if args.engine == 'lattice':
            for request in (b'RESET', b'KEY 97', b'KEY 105', b'CONTROL CONVERT'):
                p.request(request)
            time.sleep(3)
            p.request(b'CONTROL COMMIT')
            p.request(b'RESET')
        for i, item in enumerate(plan):
            request = item['request'].encode('utf-8')
            if expected is not None and digest(request) != item['request_sha256']:
                raise AssertionError('request hash mismatch')
            try:
                response = p.request(request, chunk=17)
            except Exception as error:
                raise RuntimeError(f'fixture {i} request={request!r}') from error
            rule = item.get('normalize', '')
            if expected is not None:
                frozen = base64.b64decode(item['response_base64'], validate=True)
                if digest(frozen) != item['response_sha256']:
                    raise AssertionError('response hash mismatch')
                if normal(response, rule) != normal(frozen, rule):
                    raise AssertionError(f'fixture {i} {request!r}: expected {frozen!r}, actual {response!r}')
            records.append(dict(request=item['request'], normalize=rule,
                request_sha256=digest(request), response_base64=base64.b64encode(response).decode(),
                response_sha256=digest(response)))
    finally:
        p.close()
    if args.mode == 'capture':
        path.parent.mkdir(parents=True, exist_ok=True)
        data = (json.dumps(dict(version=1, baseline='bff41b7',
            engine=args.engine,
            host_sha256=digest(Path(args.host).read_bytes()),
            runtime_sha256=digest(Path(args.runtime).read_bytes()), records=records), indent=2) + '\n').encode()
        path.write_bytes(data)
        path.with_suffix('.sha256').write_text(digest(data) + '  ' + path.name + '\n')
    if args.engine == 'ddskk':
        # Capture a real sealed producer while the worker checkpoint is denied.
        # This is ordinary file sharing refusal, not a special engine input.
        checkpoint = h.run / 'user.jisyo.eg2-checkpoint'
        time.sleep(1)
        blocker = create(str(checkpoint), 0xC0000000, 0, None, 4, 0x80000000, None)
        if blocker == INVALID:
            raise C.WinError(C.get_last_error())
        pending = Pipe(h.name)
        try:
            for request in (b'SESSION pending OPEN 2', b'SESSION pending V2 PREPARE 2 75,97,110,97',
                            b'SESSION pending V2 SPACE 2'):
                pending.request(request)
            response = pending.request(b'SESSION pending V2 CONTROL COMMIT')
            if not response.startswith(b'STATE hiragana '):
                raise AssertionError('pending producer commit failed')
            outbox = (h.run / 'user.jisyo.eg2-outbox').read_bytes()
            if not outbox.startswith(b'EG2-OUTBOX 1 '):
                raise AssertionError('sealed outbox absent')
            (h.run / 'pending-outbox.bin').write_bytes(outbox)
            pending.request(b'SESSION pending CLOSE')
        finally:
            pending.close()
            close(blocker)
        # LOCAL ACK is durable; allow the separate 200ms publication coalescer.
        deadline = time.monotonic() + 10
        while (h.run / 'user.jisyo.eg2-outbox').stat().st_size:
            if time.monotonic() > deadline:
                raise TimeoutError('producer retirement')
            time.sleep(.05)
        time.sleep(1)
        subprocess.run([os.sys.executable, str(ROOT / 'windows/test-host/host-disk-contracts.py'),
                        args.mode, '--run', str(h.run)], check=True)
    print(f'PASS contracts mode={args.mode} records={len(records)} artifacts={h.run}', flush=True)


def resources(p):
    class Counters(C.Structure):
        _fields_ = [('cb', W.DWORD), ('faults', W.DWORD)] + [(n, C.c_size_t) for n in
            ('peak_ws', 'ws', 'peak_paged', 'paged', 'peak_nonpaged', 'nonpaged', 'pagefile', 'peak_pagefile', 'private')]
    c = Counters(cb=C.sizeof(Counters))
    fn = C.WinDLL('psapi').GetProcessMemoryInfo
    fn.argtypes = [W.HANDLE, W.LPVOID, W.DWORD]
    if not fn(int(p._handle), C.byref(c), c.cb):
        raise C.WinError(C.get_last_error())
    handles = W.DWORD()
    if not api('GetProcessHandleCount', W.BOOL, W.HANDLE, C.POINTER(W.DWORD))(int(p._handle), C.byref(handles)):
        raise C.WinError(C.get_last_error())
    return dict(private_bytes=c.private, handles=handles.value)


def soak(args, h):
    samples, controls = [], []
    before = resources(h.process)
    def check(label, value):
        if not value:
            raise AssertionError(label)
        controls.append(label)
    squats = [Pipe(h.name) for _ in range(8)]
    sampling_stop = threading.Event()
    sampling_errors = []
    def sample():
        while not sampling_stop.wait(.1):
            try:
                samples.append(resources(h.process))
            except Exception as error:
                sampling_errors.append(str(error))
                return
    sampler = threading.Thread(target=sample)
    sampler.start()
    try:
        collision = h.job.spawn([str(Path(args.host).resolve()), str(Path(args.runtime).resolve()), str(ROOT)],
                                h.env, h.run / 'collision.log')
        check('name collision loser exits success', collision.wait(timeout=10) == 0)
        p = Pipe(h.name)
        try:
            check('CRLF', p.request(b'ENGINE CURRENT\r\n') == b'ENGINE ddskk')
            check('malformed LOCAL frame', p.request(b'LOCAL SERVER garbage -') == b'SERVER 4')
            check('invalid UTF8 local frame', p.request(b'LOCAL SERVER \xff -') == b'SERVER 4')
            check('embedded NUL preview', p.request(b'PREVIEW \0') == b'PREVIEW -')
            check('fragmented response', p.request(b'ROMAJI RULES 1', chunk=7).startswith(b'RULES 1 '))
            # Each WriteFile is a message: splitting a request is two requests, not a stream frame.
            check('fragmented request first message', p.request(b'ENGINE ') == b'ERR REQUEST')
            check('fragmented request second message', p.request(b'CURRENT') == b'ERR REQUEST')
        finally:
            p.close()
        p = Pipe(h.name)
        try:
            try:
                p.transfer(timeout=20)
            except TimeoutError:
                controls.append('idle read deadline cancels and drains')
            else:
                raise AssertionError('idle read unexpectedly completed')
            check('cancel cannot steal next reply', p.request(b'ENGINE CURRENT') == b'ENGINE ddskk')
        finally:
            p.close()
        p = Pipe(h.name)
        try:
            try:
                p.request(b'x' * 8193)
            except (OSError, EOFError):
                controls.append('oversized frame disconnect')
            else:
                raise AssertionError('oversized frame accepted')
        finally:
            p.close()
        barrier = threading.Barrier(32)
        lock = threading.Lock()
        def client(index):
            values = []
            pipe = Pipe(h.name)
            try:
                barrier.wait(timeout=30)
                for j in range(3125):
                    start = time.perf_counter_ns()
                    response = pipe.request(b'ENGINE CURRENT')
                    if response != b'ENGINE ddskk':
                        raise AssertionError(response)
                    values.append((time.perf_counter_ns() - start) / 1e6)
                    if j and j % 500 == 0:
                        pipe.close()
                        pipe = Pipe(h.name)
                with lock:
                    samples.append(resources(h.process))
                return values
            finally:
                pipe.close()
        with concurrent.futures.ThreadPoolExecutor(max_workers=32) as pool:
            values = [v for batch in pool.map(client, range(32)) for v in batch]
        check('completed exactly 100000', len(values) == 100000)
    finally:
        sampling_stop.set()
        sampler.join(timeout=5)
        for p in squats:
            p.close()
    time.sleep(2)
    after = resources(h.process)
    check('resource sampler completed', not sampler.is_alive() and not sampling_errors and len(samples) > 1)
    # Fixed qualification ceilings; failures remain failures, not baseline adjustments.
    check('private bytes growth <=64 MiB', after['private_bytes'] - before['private_bytes'] <= 64 * 1024 * 1024)
    check('handle growth <=64', after['handles'] - before['handles'] <= 64)
    check('peak private bytes <=512 MiB', max([before, after] + samples, key=lambda x: x['private_bytes'])['private_bytes'] <= 512 * 1024 * 1024)
    check('peak handles <=2048', max([before, after] + samples, key=lambda x: x['handles'])['handles'] <= 2048)
    # Host shutdown must finish even with clients connected and not sending data.
    idle = [Pipe(h.name) for _ in range(8)]
    p = Pipe(h.name)
    try:
        check('shutdown acknowledgement', p.request(b'SHUTDOWN') == b'OK')
        p.close()
        check('shutdown with squatting clients <=5s', h.process.wait(timeout=5) == 0)
    finally:
        p.close()
        for pipe in idle:
            pipe.close()
    check('private endpoint released', not wait_pipe(h.name, 100))
    values.sort()
    report = dict(version=1, clients=32, completed=len(values), controls=controls,
        before=before, after=after, samples=samples,
        latency_ms=dict(p50=values[math.ceil(len(values)*.5)-1],
                        p99=values[math.ceil(len(values)*.99)-1], max=values[-1]))
    (h.run / 'soak.json').write_text(json.dumps(report, indent=2) + '\n')
    print('PASS soak ' + json.dumps(report['latency_ms']) + f' clients=32 completed={len(values)} controls={len(controls)} artifacts={h.run}', flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['capture', 'replay', 'soak'])
    parser.add_argument('--host', required=True)
    parser.add_argument('--runtime', required=True)
    parser.add_argument('--build-dir', default='build/w')
    parser.add_argument('--cold-load-sleep-sec', type=int, default=45)
    parser.add_argument('--fixture', default=str(ROOT / 'docs/contracts/native-v1.json'))
    parser.add_argument('--engine', choices=['ddskk', 'lattice'], default='ddskk')
    args = parser.parse_args()
    h = Host(args)
    try:
        h.start()
        soak(args, h) if args.mode == 'soak' else corpus(args, h)
    finally:
        h.stop()
        print('CLEANUP owned job closed; host reaped; private pipe=' + h.name, flush=True)


if __name__ == '__main__':
    main()
