"""Private foreground bundle deployment. Never attach to an unowned host.

The exclusive state-file lease serializes coordinators. A flushed journal
selects old before commit and new after commit. Every host runs in our job;
one stack at a time, with a disconnected interval and fresh client sessions.
"""
import argparse
import hashlib
import importlib.util
import json
import mmap
import os
import re
from pathlib import Path
import sys
import time
import uuid

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('transport', Path(__file__).with_name('host-contracts.py'))
transport = importlib.util.module_from_spec(spec)
spec.loader.exec_module(transport)
spec = importlib.util.spec_from_file_location('ownership', Path(__file__).with_name('host-test-process-guard.py'))
ownership = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ownership)


def durable(path, value):
    temporary = path.with_suffix('.pending')
    with temporary.open('w', encoding='utf-8') as stream:
        json.dump(value, stream, indent=2)
        stream.flush()
        os.fsync(stream.fileno())
    # Windows write-through rename; pending journal never replaces authority.
    move = transport.api('MoveFileExW', transport.W.BOOL, transport.W.LPCWSTR,
                         transport.W.LPCWSTR, transport.W.DWORD)
    if not move(str(temporary), str(path), 0x1 | 0x8):
        raise transport.C.WinError(transport.C.get_last_error())


def manifest(bundle, runtime):
    if not bundle.resolve().is_relative_to(transport.ROOT / 'build'):
        raise ValueError('bundle must be under this checkout build directory')
    pairs = [line.split('=', 1) for line in (bundle / 'bundle.manifest').read_text('utf-8').splitlines()]
    fields = dict(pairs)
    if len(fields) != 7 or len(pairs) != 7 or fields.get('schema') != '1' or fields.get('contract') != 'engine-host-v1' or fields.get('policy_ipc') != 'HP2' or fields.get('mode') not in ('native', 'policy'):
        raise ValueError('incompatible bundle manifest')
    for name, file in [('host', bundle / 'ddskk-engine-host.exe'), ('runtime', runtime),
                       ('policy', bundle / 'repository/engine/host-policy.el')]:
        if hashlib.sha256(file.read_bytes()).hexdigest() != fields[name + '_sha256']:
            raise ValueError('incompatible bundle ' + name)
    return fields


def recovery_bundle(record):
    if record.get('phase') not in ('prepared', 'released', 'committed'):
        raise ValueError('unknown deployment journal phase')
    return Path(record['new'] if record['phase'] == 'committed' else record['old'])


class Deployment:
    def __init__(self, args):
        self.args = args
        self.root = args.state.resolve()
        if not self.root.is_relative_to(transport.ROOT / 'build'):
            raise ValueError('state must be under this checkout build directory')
        self.root.mkdir(parents=True, exist_ok=True)
        # A real exclusive Windows handle, not a stale PID/file existence lock.
        self.lease = transport.create(str(self.root / 'deployment.lease'), 0xC0000000,
                                      0, None, 4, 0x80, None)
        if self.lease == transport.INVALID:
            raise RuntimeError('deployment already leased')
        self.job = transport.Job()
        self.host = None
        self.clients = []
        self.mappings = []
        self.name = '\\\\.\\pipe\\' + args.pipe
        self.journal = self.root / 'deployment.json'
        self.count = 0

    def request(self, request):
        pipe = transport.Pipe(self.name)
        try:
            if request == 'PRIVATE HANDOVER 1':
                pipe.transfer(request.encode(), timeout=35000)
                reply, more = pipe.transfer(timeout=35000)
                assert not more
                return reply
            return pipe.request(request.encode())
        finally:
            pipe.close()

    def start(self, bundle, prewarm=False):
        fields = manifest(bundle, self.args.runtime)
        if self.host is not None:
            raise AssertionError('one owned stack at a time')
        self.wait_stack_exit()
        name = self.name + '-warm-' + uuid.uuid4().hex if prewarm else self.name
        log = self.root / ('warm.log' if prewarm else 'host.log')
        env = dict(os.environ, DDSKK_PIPE_NAME=name, NATIVEIME_REGISTRY_KEY=self.args.key,
                   LOCALAPPDATA=str(self.root), DDSKK_USER_JISYO=str(self.root / 'user.jisyo'),
                   DDSKK_HOST_BUNDLE_MANIFEST=str(bundle / 'bundle.manifest'),
                   DDSKK_HOST_LOG=str(log), DDSKK_HOST_POLICY_SHADOW='0',
                   DDSKK_SKKSERV_ENABLE='0', NELISP_IME_ENGINE='ddskk',
                   NATIVEIME_TEST_LOCAL_CONVERSION='1',
                   DDSKK_HARNESS_DIAGNOSTICS='1',
                   DDSKK_DICTIONARY_FILES=';'.join(
                       [str(transport.ROOT / 'windows/test-host/data/behavior-jisyo.utf8')] +
                       ([str(self.args.large_dictionary)] if getattr(self.args, 'large_dictionary', None) else [])))
        print('BUNDLE_DICTIONARY_FILES '+env['DDSKK_DICTIONARY_FILES'], flush=True)
        for switch in ('SOURCES', 'CACHE', 'RESTART', 'PUBLICATION', 'LEARNING'):
            env['DDSKK_HOST_POLICY_' + switch] = '1' if fields['mode'] == 'policy' else '0'
        self.host = self.job.spawn([str(bundle / 'ddskk-engine-host.exe'), str(self.args.runtime),
                                   str(bundle / 'repository')], env, self.root / 'stderr.log')
        if prewarm:
            self.fault('during-prewarm')
        time.sleep(self.args.cold_load_sleep_sec)
        pipe = transport.Pipe(name)
        try:
            assert pipe.request(b'PRIVATE OWNER 1') == f'OWNER {self.host.pid}'.encode(), 'endpoint is not our host'
            assert pipe.request(b'SESSION warm OPEN 2') == b'OK OPEN 2'
            assert pipe.request(b'SESSION warm RESET').startswith(b'STATE ')
            assert pipe.request(b'SESSION warm CLOSE').startswith(b'OK')
        finally:
            pipe.close()
        if fields['mode'] == 'policy':
            deadline = time.monotonic() + 65
            while f'host={self.host.pid} policy-ready' not in log.read_text('utf-8'):
                if self.host.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError('policy prewarm failed')
                time.sleep(.1)
        self.count += 1
        if prewarm:
            pipe = transport.Pipe(name)
            try:
                assert pipe.request(b'PRIVATE HANDOVER 1') == b'OK HANDOVER RECONNECT'
            finally:
                pipe.close()
            self.host.wait(timeout=60)
            self.host = None
            self.wait_stack_exit()

    def stop(self):
        if self.host is None:
            return
        response = self.request('PRIVATE HANDOVER 1')
        if response != b'OK HANDOVER RECONNECT':
            raise RuntimeError('handover deferred: ' + repr(response))
        self.host.wait(timeout=60)
        self.host = None
        self.wait_stack_exit()

    def wait_stack_exit(self):
        deadline = time.monotonic() + 10
        while True:
            members = ownership.CommandJob.members(self.job)
            remaining = []
            for pid in members:
                try:
                    handle = bundle_transport_handle(self, pid)
                except OSError as error:
                    if error.winerror == 87:
                        continue
                    raise
                try:
                    if transport.wait(handle, 0) == 0:
                        continue
                    path = transport.C.create_unicode_buffer(32768)
                    length = transport.W.DWORD(len(path))
                    query = transport.api('QueryFullProcessImageNameW', transport.W.BOOL,
                        transport.W.HANDLE, transport.W.DWORD, transport.W.LPWSTR,
                        transport.C.POINTER(transport.W.DWORD))
                    if not query(handle, 0, path, transport.C.byref(length)):
                        if transport.wait(handle, 0) != 0:
                            remaining.append(pid)  # still owned/alive: do not advance
                        continue
                    if Path(path.value).name.lower() in ('ddskk-engine-host.exe', 'nelisp.exe'):
                        remaining.append(pid)
                finally:
                    transport.close(handle)
            if not remaining:
                return
            if time.monotonic() >= deadline:
                raise RuntimeError('refuse next owned stack; remaining=' + str(remaining))
            time.sleep(.01)

    def swap(self, old, new, during=None):
        manifest(new, self.args.runtime)
        durable(self.journal, dict(phase='prepared', old=str(old), new=str(new)))
        self.fault('before-handover')
        if during:
            during()
        # PREPARED remains old authority on any crash/cancellation. Closing the
        # old host drains its durable writers before the private prewarm loads.
        self.stop()
        durable(self.journal, dict(phase='released', old=str(old), new=str(new)))
        self.fault('after-release')
        self.start(new, prewarm=True)
        self.fault('after-prewarm')
        self.start(new)
        durable(self.journal, dict(phase='committed', old=str(old), new=str(new)))
        self.fault('after-commit')
        print('COMMIT clients=reconnect bundle=' + str(new), flush=True)

    def fault(self, point):
        if getattr(self.args, 'fault_at', None) == point:
            raise InterruptedError('private test cancellation/crash boundary=' + point)

    def restart(self, bundle, engine=False):
        if engine:
            assert self.request('SESSION incarnation OPEN 2') == b'OK OPEN 2'
            pid = int(self.request('DIAG CHILD-PID').split()[1])
            process = bundle_transport_handle(self, pid)
            try:
                assert transport.api('TerminateProcess', transport.W.BOOL, transport.W.HANDLE,
                                     transport.W.UINT)(process, 23)
            finally:
                transport.close(process)
            time.sleep(self.args.cold_load_sleep_sec + 5)
            assert int(self.request('DIAG CHILD-PID').split()[1]) != pid
            assert self.request('SESSION incarnation V2 RESET') == b'ERR SESSION LOST'
            assert self.request('SESSION incarnation OPEN 2') == b'OK OPEN 2'
            assert self.request('SESSION incarnation RESET').startswith(b'STATE ')
            assert self.request('SESSION incarnation CLOSE').startswith(b'OK')
        else:
            self.host.kill()
            self.host.wait(timeout=10)
            self.host = None
            self.wait_stack_exit()
            self.start(bundle)


    def close(self):
        members = ownership.CommandJob.members(self.job)
        handles = []
        for pid in members:
            try:
                handles.append((pid, bundle_transport_handle(self, pid)))
            except OSError as error:
                if error.winerror != 87:
                    raise
        self.job.close()
        if self.host is not None:
            self.host.wait(timeout=10)
        for file, mapping, original in self.mappings:
            assert mapping[:] == original, 'retained mapping changed'
            mapping.close()
            file.close()
        transport.close(self.lease)
        leftovers = []
        for pid, handle in handles:
            if transport.wait(handle, 10000) != 0:
                leftovers.append(pid)
            transport.close(handle)
        print('CLEANUP owned_pids=' + str(members) + ' leftovers=' + str(leftovers), flush=True)
        if leftovers:
            raise RuntimeError('owned processes did not exit')


def bundle_transport_handle(deployment, pid):
    process = transport.api('OpenProcess', transport.W.HANDLE, transport.W.DWORD,
                            transport.W.BOOL, transport.W.DWORD)(0x101001, False, pid)
    if not process:
        raise transport.C.WinError(transport.C.get_last_error())
    member = transport.W.BOOL()
    if not transport.api('IsProcessInJob', transport.W.BOOL, transport.W.HANDLE,
                         transport.W.HANDLE, transport.C.POINTER(transport.W.BOOL))(
            process, deployment.job.handle, transport.C.byref(member)) or not member.value:
        transport.close(process)
        raise RuntimeError('refuse unowned process')
    return process


def run(args):
    if (len(args.key) >= 200 or len(args.pipe) >= 190 or
            not re.fullmatch(r'Software\\NativeIME-test-[A-Za-z0-9-]+', args.key) or
            not re.fullmatch(r'EH5-[A-Za-z0-9-]+', args.pipe)):
        raise ValueError('private endpoints required')
    deployment = Deployment(args)
    try:
        bundle = args.bundle.resolve()
        if args.action in ('recover', 'rollback'):
            record = json.loads(deployment.journal.read_text('utf-8'))
            bundle = recovery_bundle(record) if args.action == 'recover' else Path(record['old'])
        if args.action == 'storage':
            deployment.start(bundle)
            operation = uuid.uuid4().hex + '.1'
            assert deployment.request(f'LOCAL LEARN {operation} 00304b00306a 004eee00540d').startswith(f'ACK {operation} '.encode())
            target = deployment.root / 'user.jisyo'
            blocker = transport.create(str(target), 0x80000000, 1, None, 3, 0x80, None)
            if blocker == transport.INVALID:
                raise transport.C.WinError(transport.C.get_last_error())
            pending = transport.Pipe(deployment.name)
            operation = uuid.uuid4().hex + '.1'
            try:
                pending.transfer(f'LOCAL LEARN {operation} 00304b00306a 0052a0005948'.encode())
                deadline = time.monotonic() + 10
                while 'LEARNING_IO retry' not in (deployment.root / 'stderr.log').read_text('utf-8'):
                    if time.monotonic() > deadline:
                        raise TimeoutError('real blocked checkpoint')
                    time.sleep(.01)
                owner = deployment.host.pid
                assert deployment.request('PRIVATE HANDOVER 1') == b'DEFER STORAGE'
                assert deployment.request('PRIVATE OWNER 1') == f'OWNER {owner}'.encode()
            finally:
                transport.close(blocker)
            try:
                reply, more = pending.transfer(timeout=35000)
                assert not more and reply.startswith(f'ACK {operation} '.encode())
                assert deployment.request(f'LOCAL LEARN {operation} 00304b00306a 0052a0005948') == reply
            finally:
                pending.close()
            deployment.stop()
            print('PASS blocked storage real_checkpoint_refusal=1 old_owner_preserved=1 exact_ack_replay=1', flush=True)
        elif args.action == 'cycle':
            if not args.previous:
                raise ValueError('Cycle requires previous native bundle')
            old = args.previous.resolve()
            assert manifest(old, args.runtime)['mode'] == 'native'
            assert manifest(bundle, args.runtime)['mode'] == 'policy'
            deployment.start(old)
            collision = deployment.job.spawn([str(old / 'ddskk-engine-host.exe'), str(args.runtime),
                str(old / 'repository')], dict(os.environ, DDSKK_PIPE_NAME=deployment.name,
                NATIVEIME_REGISTRY_KEY=args.key, LOCALAPPDATA=str(deployment.root),
                DDSKK_USER_JISYO=str(deployment.root / 'user.jisyo')),
                deployment.root / 'collision.log')
            assert collision.wait(timeout=10) == 0
            assert deployment.request('PRIVATE OWNER 1') == f'OWNER {deployment.host.pid}'.encode()
            # Keep a real session open: handover must refuse to lose composition.
            client = transport.Pipe(deployment.name)
            try:
                assert client.request(b'SESSION composing OPEN 2') == b'OK OPEN 2'
                assert client.request(b'SESSION composing KEY 75').startswith(b'STATE ')
                assert deployment.request('PRIVATE HANDOVER 1') == b'DEFER COMPOSITION'
                assert client.request(b'SESSION composing RESET').startswith(b'STATE ')
                assert client.request(b'SESSION composing CLOSE').startswith(b'OK')
            finally:
                client.close()
            origin = uuid.uuid4().hex
            acknowledged = []
            def burst(first):
                for index in range(first, first + 10):
                    # Independent producer cursors keep every original revision
                    # available for exact replay; each producer starts at 1.
                    operation = f'{origin[:28]}{index:04x}.1'
                    candidate = '004eee00540d' if index % 2 else '0052a0005948'
                    reply = deployment.request(f'LOCAL LEARN {operation} 00304b00306a {candidate}')
                    assert reply.startswith(f'ACK {operation} '.encode()), reply
                    acknowledged.append((operation, candidate, reply))
            burst(1)
            # Retain real immutable generation mappings across both host exits.
            deadline = time.monotonic() + 15
            generations = []
            while not generations and time.monotonic() < deadline:
                generations = list(deployment.root.rglob('generation-*.index'))
                time.sleep(.1)
            assert generations, 'no published immutable generation to retain'
            for generation in generations:
                file = generation.open('rb')
                mapping = mmap.mmap(file.fileno(), 0, access=mmap.ACCESS_READ)
                deployment.mappings.append((file, mapping, mapping[:]))
            deployment.swap(old, bundle, lambda: burst(11))
            deployment.restart(bundle, engine=True)
            deployment.restart(bundle)
            deployment.swap(bundle, old, lambda: burst(21))
            for operation, candidate, original in acknowledged:
                reply = deployment.request(f'LOCAL LEARN {operation} 00304b00306a {candidate}')
                assert reply == original, (operation, original, reply)
            deployment.stop()
            rows = (deployment.root / 'user.jisyo').read_text('utf-8').splitlines()
            row = next(line for line in rows if line.startswith('かな '))
            assert row == 'かな /加奈/仮名/', row
            print(f'PASS private cycle acknowledged_ids={len(acknowledged)} exact_replays={len(acknowledged)} starts={deployment.count} composition_deferrals=1 retained_mappings={len(deployment.mappings)} exact_order=1 endpoint_collision_losers=1', flush=True)
        else:
            # Foreground scoped deployment, deliberately no background daemon.
            deployment.start(bundle, prewarm=True)
            deployment.start(bundle)
            if args.action in ('deploy', 'rollback'):
                old = (Path(record['new']) if args.action == 'rollback' else
                       args.previous.resolve() if args.previous else bundle)
                durable(deployment.journal, dict(phase='committed', old=str(old), new=str(bundle)))
            print('READY private foreground deployment clients=reconnect', flush=True)
            time.sleep(args.lifetime_sec)
            deployment.stop()
    finally:
        deployment.close()
        print('CLEANUP owned job closed', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--action', choices=['deploy', 'rollback', 'recover', 'cycle', 'storage'], required=True)
    for name in ('bundle', 'runtime', 'state'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--previous', type=Path)
    parser.add_argument('--key', required=True)
    parser.add_argument('--pipe', required=True)
    parser.add_argument('--cold-load-sleep-sec', type=int, default=45)
    parser.add_argument('--lifetime-sec', type=int, default=60)
    parser.add_argument('--fault-at', choices=['before-handover','after-release','during-prewarm','after-prewarm','after-commit'])
    run(parser.parse_args())
