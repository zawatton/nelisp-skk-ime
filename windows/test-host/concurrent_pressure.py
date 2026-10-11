"""Private EH8 drivers and receipt checker. Importing starts no processes.

Sources stay armed across disconnected lifecycle intervals; actual operations
are recorded separately. No process can perform IO while it does not exist.
"""
import hashlib
import json
from pathlib import Path
import re
import threading
import time
import uuid


def check_overlap(report):
    cycle = report['cycle']
    assert 0 < cycle['end'] - cycle['start'] <= 1800, 'cycle exceeds 30 minutes'
    assert report['phases'] == ['deploy', 'traffic', 'rollback', 'cold-restart']
    for name in ('gc', 'network', 'storage'):
        source = report['sources'][name]
        assert source['start'] <= cycle['start'] < cycle['end'] <= source['end'], name
    for phase in report['phases']:
        begin, end = report['phase_windows'][phase]
        rows = [row for row in report['operations'] if row['end'] >= begin and row['start'] <= end]
        assert all(any(row['source'] == source and row['end'] >= row['start']
                       for row in rows) for source in ('network', 'storage')), phase
        for process in ('engine', 'policy'):
            collections = [row for row in report['collections'][process]
                           if begin <= row['start'] <= row['end'] <= end]
            assert collections, (phase, process)
            assert any(max(gc['start'], disk['start'], net['start']) <=
                       min(gc['end'], disk['end'], net['end'])
                       for gc in collections for disk in rows if disk['source'] == 'storage'
                       for net in rows if net['source'] == 'network'), ('no three-source overlap', phase, process)
    assert report['dns_packets'] > 0 and report['dns_cancellations'] > 0
    assert report['skkserv_failures'] > 0
    assert report['storage_refusals'] > 0 and report['sealed_outbox_ids']
    assert report['provider_watermark'] >= max(report['sealed_outbox_ids'])
    assert report['acknowledged_ids'] > 0
    assert report['exact_ack_replays'] == report['acknowledged_ids']
    assert report['duplicate_ack_rows'] == 0
    assert report['callback_probes'] >= 10 and report['callback_waits'] == 0
    assert report['callback_io'] == 0 and report['callback_max_us'] <= 20000
    assert report['rollback_restored'] and report['cold_restart_recovered']


def instrument(path, process):
    """Modify only a disposable bundle copy, preserving protocol replies.

    The real collector runs after 32 KiB transient allocation on every engine
    dispatch / HP2 decision. A completed collection writes a wall-clock interval.
    A missing log (including unsupported runtime file IO) fails acceptance.
    """
    text = path.read_text('utf-8')
    assert '(defun eh8-collect ' not in text, 'bundle already instrumented'
    marker = ('  (ddskk-engine-start)\n  (cond' if process == 'engine' else
              '  "Validate the fixed envelope and return its copied ID and numeric decision."\n')
    assert text.count(marker) == 1, 'pressure injection point changed'
    call = f'  (eh8-collect "{process}")\n'
    replacement = ('  (ddskk-engine-start)\n' + call + '  (cond' if process == 'engine'
                   else marker + call)
    definition = '''
(defun eh8-collect (process)
  (let ((before (float-time)) (scratch (make-string 32768 97)) after)
    (garbage-collect)
    (setq after (float-time))
    (condition-case nil
        (write-region (format "%.9f %.9f\\n" before after) nil
                      (concat (getenv "EH8_GC_DIRECTORY") "/" process ".gc") t)
      (error nil))))
'''
    # Keep the lexical-binding cookie first.
    first, rest = text.replace(marker, replacement, 1).split('\n', 1)
    path.write_text(first + '\n' + definition + rest, encoding='utf-8')
    return hashlib.sha256(path.read_bytes()).hexdigest()


class Pressure:
    def __init__(self, deployment, args):
        self.d, self.args = deployment, args
        self.stop = threading.Event()
        self.active = threading.Event()
        self.threads = []
        self.lock = threading.RLock()
        self.errors = []
        self.acks = {}
        self.current = 'startup'
        self.network_serial = 0
        self.report = dict(status='incomplete', phases=[], phase_windows={}, operations=[],
                           sources={}, collections={})
        self.fixture = None
        self.finished = False

    def start(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location('eh8_dns', Path(__file__).with_name('test-os1-private.py'))
        dns = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(dns)
        # The fixture receives real GetAddrInfoExW requests. Alternate a DNS
        # blackhole with loopback skkserv connections that delay then fail.
        owner = self
        class Fixture(dns.DnsFixture):
            failures = 0
            def server(self, sock):
                import socket
                try:
                    while not self.stop.is_set():
                        try:
                            client, _ = sock.accept()
                        except socket.timeout:
                            continue
                        with client:
                            owner.stop.wait(.3)
                            # Close without a reply: real slow/failing skkserv.
                            self.failures += 1
                except BaseException as error:
                    if not self.stop.is_set(): self.errors.append(repr(error))
        self.fixture = Fixture().start()
        self.args.pressure_env = dict(DDSKK_SKKSERV_ENABLE='1',
            DDSKK_SKKSERV_HOST=uuid.uuid4().hex+'.s6.test.',
            DDSKK_SKKSERV_PORT=str(self.fixture.port), DDSKK_SKKSERV_START_COMMAND='',
            NATIVEIME_TEST_OS1_DNS_TRACE='1', NATIVEIME_TEST_OS1_DNS_SERVER='127.0.0.2',
            EH8_GC_DIRECTORY=str(self.args.state), DDSKK_ENGINE_IDLE_GC_MS='100',
            SKKSERV_GOOGLE_BACKEND='0', SKKSERV_AUTOSTART='0')
        now = time.time()
        self.report['sources'] = {name: dict(start=now) for name in ('gc','network','storage')}
        self.report['cycle'] = dict(start=time.time())
        # A single driver uses fresh pipes and never survives an owned-host exit.
        for target in (self.storage, self.drive):
            thread = threading.Thread(target=target, name='EH8-pressure')
            self.threads.append(thread)
            thread.start()
        return self

    def exercise(self):
        from concurrent_pressure import _transport
        transport = _transport
        phase = self.current
        begin = time.time()
        self.fixture.answer.clear() if self.network_serial % 2 == 0 else self.fixture.answer.set()
        self.network_serial += 1
        reading = ''.join(f'{ord(c):06x}' for c in uuid.uuid4().hex[:8])
        reply = self.d.request(f'LOCAL SERVER {reading} -')
        assert reply.startswith(b'SERVER'), reply
        network_begin = begin
        # The storage thread independently refuses replacement while both
        # LOCAL LEARN and the real provider producer perform durable work.
        pending = transport.Pipe(self.d.name)
        provider = None
        operation = uuid.uuid4().hex+'.1'
        try:
            pending.transfer(f'LOCAL LEARN {operation} 00304b00306a 004eee00540d'.encode())
            # A provider STATE seals an outbox while checkpoint replacement is
            # refused, reusing the real host-contracts producer sequence.
            session = 'eh8-'+uuid.uuid4().hex
            # SESSION state belongs to a connection. Deployment.request() is
            # intentionally one-shot: its disconnect closes any session opened
            # there. Keep OPEN -> V2 -> CLOSE on one independently owned pipe.
            provider = transport.Pipe(self.d.name)
            for request in (f'SESSION {session} OPEN 2',
                            f'SESSION {session} V2 PREPARE 2 75,97,110,97',
                            f'SESSION {session} V2 SPACE 2',
                            f'SESSION {session} V2 CONTROL COMMIT',
                            f'SESSION {session} CLOSE'):
                response = provider.request(request.encode())
                if request.endswith('OPEN 2'): assert response == b'OK OPEN 2', response
                elif request.endswith('CLOSE'): assert response.startswith(b'OK'), response
                elif request.endswith('COMMIT'): assert response.startswith(b'STATE hiragana '), response
                # PREPARE/SPACE answer with preedit/conversion state, as in
                # host-contracts.py; only the commit returns to hiragana.
                else: assert response.startswith(b'STATE '), response
            ack, more = pending.transfer(timeout=35000)
            assert not more and ack.startswith(f'ACK {operation} '.encode()), ack
            self.acks[operation] = ack
        finally:
            if provider is not None:
                provider.close()
            pending.close()
            # Keep an observation window through the real cancellable DNS /
            # failing skkserv deadline, overlapping provider GC and disk refusal.
            self.stop.wait(.3)
            self.report['operations'].append(dict(source='network', phase=phase,
                start=network_begin, end=time.time()))

    def storage(self):
        from concurrent_pressure import _transport as transport
        while not self.stop.is_set():
            phase, blockers, begin = self.current, [], None
            try:
                for suffix in ('', '.eg2-checkpoint'):
                    # Allow cold-load readers; deny writers and rename/delete.
                    # Never fabricate an empty pending recovery checkpoint.
                    handle = transport.create(str(self.args.state / ('user.jisyo'+suffix)),
                        0x80000000, 1, None, 3, 0x80, None)
                    if handle == transport.INVALID:
                        error = transport.C.get_last_error()
                        if error in (2, 32): continue  # absent target / writer currently owns it
                        raise transport.C.WinError(error)
                    blockers.append(handle)
                begin = time.time()  # all recorded handles now actually held
                self.stop.wait(.3)
            except BaseException as error:
                self.errors.append(repr(error))
                return
            finally:
                end = time.time()  # conservative interval ends before first close
                for handle in blockers: transport.close(handle)
                if blockers and begin is not None:
                    self.report['operations'].append(dict(source='storage', phase=phase,
                        start=begin, end=end, handles=len(blockers)))
            self.stop.wait(.2)

    def drive(self):
        while not self.stop.wait(.2):
            if not self.active.is_set(): continue
            try:
                with self.lock:
                    if self.active.is_set(): self.exercise()
            except BaseException as error:
                self.errors.append(repr(error))
                self.active.clear()

    def phase(self, name, release=None):
        self.active.clear()
        with self.lock:
            assert not self.errors, self.errors
            now = time.time()
            if self.report['phases']:
                self.report['phase_windows'][self.current][1] = now
            self.current = name
            self.report['phases'].append(name)
            self.report['phase_windows'][name] = [now, None]
            if release is not None:
                release()  # Lifecycle ready; verification still runs below and must pass.
            self.exercise()
            # Every acknowledged identity is replayed twice across each boundary.
            for operation, original in self.acks.items():
                for _ in range(2):
                    assert self.d.request(f'LOCAL LEARN {operation} 00304b00306a 004eee00540d') == original
        self.active.set()

    def pause(self):
        """Drain one in-flight fault before closing its endpoint; sources stay armed."""
        self.active.clear()
        with self.lock: assert not self.errors, self.errors

    def finish(self):
        self.pause()
        self.stop.set()
        for thread in self.threads:
            thread.join(40)
            assert not thread.is_alive(), 'pressure driver leak'
        now = time.time()
        self.report['phase_windows'][self.current][1] = now
        self.report['cycle']['end'] = now
        for source in self.report['sources'].values(): source['end'] = time.time()
        assert not self.errors and not self.fixture.errors, (self.errors, self.fixture.errors)
        self.report['dns_packets'] = self.fixture.packets
        self.report['skkserv_failures'] = self.fixture.failures
        logs = '\n'.join(path.read_text('utf-8', errors='replace')
                         for path in self.args.state.glob('*.log'))
        self.report['dns_cancellations'] = logs.count('os1-dns-exit status=10111')
        drains = [float(x) for x in re.findall(r'os1-dns-drained ms=([0-9.]+)', logs)]
        assert drains and max(drains) <= 1000
        self.report['dns_drain_ms'] = drains
        self.report['storage_refusals'] = logs.count('LEARNING_IO retry')
        ids = [int(x) for x in re.findall(r'LEARNING_OUTBOX append id=(\d+) [^\n]*ok=1', logs)]
        assert len(ids) == len(set(ids)), 'duplicate provider outbox ID'
        self.report['sealed_outbox_ids'] = ids
        watermark = (self.args.state/'user.jisyo.eg2-provider-watermark').read_text('utf-8')
        assert re.fullmatch(r'EG2-PROVIDER 1 [1-9][0-9]*\n', watermark)
        self.report['provider_watermark'] = int(watermark.split()[2])
        import importlib.util
        spec = importlib.util.spec_from_file_location('eh8_s4', Path(__file__).with_name('host-policy-s4.py'))
        s4 = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(s4)
        s4.ack_gate(ids, [value for value in ids if value <= self.report['provider_watermark']])
        intents = [int(value) for value in re.findall(r'policy-intent-publication ms=(\d+)', logs)]
        self.report['publication_ms'] = s4.publication_gate(intents)
        stored = (self.args.state/'user.jisyo').read_text('utf-8')
        for operation in self.acks:
            assert stored.count(f';; local-ack {operation[:-2]} 1 ') == 1, operation
        self.report.update(acknowledged_ids=len(self.acks), exact_ack_replays=len(self.acks), duplicate_ack_rows=0)
        warmed = []
        for path in [self.args.state/'tsf.log', *self.args.state.glob('peer-*.log')]:
            text = path.read_text('utf-8')
            start = text.find('AFTER WARM ')
            assert start >= 0 and 'SETTLE TIMEOUT' not in text, path
            warmed.append(text[start:])
            # Reuse the unchanged S4 callback import coverage / zero waits /
            # 20 ms watchdog / local branch / LOCAL_ACK checker on each log.
            import subprocess
            subprocess.run(['pwsh','-NoProfile','-NonInteractive','-File',
                str(Path(__file__).with_name('test-host-policy-callbacks.ps1')),
                '-Runtime',str(self.args.runtime),'-CheckLogOnly',str(path)], check=True)
        callback_logs = '\n'.join(warmed)
        rows = re.findall(r'CALLBACK_IO hooks=(\d+) mask=(\d+) pipe_io=(\d+) blocking_waits=(\d+)', callback_logs)
        assert rows and all(int(mask) & 271 == 271 for _, mask, _, _ in rows)
        times = [int(x) for x in re.findall(r'KEYLAT token=\S+ .*?total_us=(\d+) claimed=1', callback_logs)]
        assert times
        self.report.update(callback_probes=len(rows), callback_io=sum(int(row[2]) for row in rows),
            callback_waits=sum(int(row[3]) for row in rows), callback_max_us=max(times))
        for process in ('engine','policy'):
            values = (self.args.state/(process+'.gc')).read_text('utf-8').splitlines()
            self.report['collections'][process] = [dict(zip(('start','end'), map(float, value.split()))) for value in values]
        check_overlap(self.report)
        self.report['status'] = 'PASS'
        self.finished = True
        print(f'PASS simultaneous pressure phases=4 acknowledged_ids={len(self.acks)} callback_probes={len(rows)} callback_waits=0 duplicate_ids=0', flush=True)

    def close(self):
        self.stop.set()
        try:
            for thread in self.threads:
                thread.join(40)
                assert not thread.is_alive(), 'pressure driver leak'
            if self.fixture: self.fixture.close()
        except BaseException as error:
            self.report.update(status='FAIL/cleanup', cleanup_error=repr(error))
            raise
        finally:
            if not self.finished: self.report['status'] = 'FAIL/incomplete'
            elif self.report.get('owned_process_leaks') != 0: self.report['status'] = 'FAIL/owned cleanup'
            self.report['driver_errors'] = self.errors
            (self.args.state/'concurrent-pressure.json').write_text(json.dumps(self.report, indent=2)+'\n', encoding='utf-8')


# Set explicitly by the E2E caller; there is no standalone host in this module.
_transport = None
