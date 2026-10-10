"""Stack-free negative controls; synthetic receipts are never acceptance evidence."""
import ast
import copy
from pathlib import Path
import tempfile
import unittest
import subprocess
from types import SimpleNamespace
from unittest.mock import patch
import concurrent_pressure as pressure


def receipt():
    phases = ['deploy','traffic','rollback','cold-restart']
    report = dict(cycle=dict(start=1,end=45), phases=phases,
        sources={name: dict(start=0,end=50) for name in ('gc','network','storage')},
        phase_windows={}, operations=[], collections={'engine':[], 'policy':[]},
        dns_packets=4,dns_cancellations=4,skkserv_failures=4,storage_refusals=4,sealed_outbox_ids=[1,2,3],
        provider_watermark=3,acknowledged_ids=4,exact_ack_replays=4,duplicate_ack_rows=0,
        callback_probes=20,callback_waits=0,callback_io=0,callback_max_us=100,
        rollback_restored=True,cold_restart_recovered=True)
    for number, phase in enumerate(phases):
        start = 2+number*10
        report['phase_windows'][phase] = [start,start+9]
        for source in ('network','storage'):
            report['operations'].append(dict(source=source,phase=phase,start=start,end=start+5))
        for process in ('engine','policy'):
            report['collections'][process].append(dict(start=start+1,end=start+2))
    return report


class Controls(unittest.TestCase):
    def test_provider_session_connection(self):
        pipes, calls = [], []
        class Pipe:
            def __init__(self, name):
                self.sessions, self.closed, self.ack = set(), False, None
                pipes.append(self)
            def request(self, data):
                text = data.decode()
                calls.append((self, text))
                if text.startswith('LOCAL SERVER '): return b'SERVER PENDING'
                _, session, command = text.split(' ', 2)
                if command == 'OPEN 2':
                    self.sessions.add(session)
                    return b'OK OPEN 2'
                if session not in self.sessions: return b'ERR SESSION LOST'
                if command == 'CLOSE':
                    self.sessions.remove(session)
                    return b'OK CLOSED'
                return b'STATE hiragana fixture'
            def transfer(self, data=None, **kwargs):
                if data is not None:
                    self.ack = b'ACK '+data.split()[2]+b' 1'
                    return b'', False
                return self.ack, False
            def close(self):
                # Match main.cpp's connection-owner session cleanup, not GC.
                self.sessions.clear()
                self.closed = True
        class Deployment:
            name = 'private-unit-pipe'
            def request(self, request):
                pipe = Pipe(self.name)
                try: return pipe.request(request.encode())
                finally: pipe.close()
        fixture = pressure.Pressure(Deployment(), SimpleNamespace())
        fixture.fixture = SimpleNamespace(answer=SimpleNamespace(clear=lambda: None,set=lambda: None))
        with patch.object(pressure, '_transport', SimpleNamespace(Pipe=Pipe)), patch.object(fixture.stop,'wait',return_value=False):
            fixture.exercise()
        provider_calls = [(pipe,text) for pipe,text in calls if text.startswith('SESSION ')]
        self.assertEqual(len(provider_calls),5)
        self.assertTrue(all(pipe is provider_calls[0][0] for pipe,_ in provider_calls))
        self.assertTrue(all(pipe.closed for pipe in pipes))
        self.assertEqual(len(fixture.acks),1)
        print('PASS EH8 provider session connection requests=5 persistent_pipes=1 all_closed=1 stacks=0')

    def test_storage_does_not_create_checkpoint(self):
        calls = []
        fixture = pressure.Pressure(None, SimpleNamespace(state=Path('unused-unit-state')))
        def create(*args):
            calls.append(args)
            return -1  # missing target: startup must not fabricate one
        def wait(seconds):
            fixture.stop.set()
            return True
        transport = SimpleNamespace(create=create, INVALID=-1,
            C=SimpleNamespace(get_last_error=lambda: 2, WinError=lambda code: OSError(code,'missing')))
        with patch.object(pressure,'_transport',transport), patch.object(fixture.stop,'wait',side_effect=wait):
            fixture.storage()
        self.assertEqual([call[4] for call in calls],[3,3])  # OPEN_EXISTING
        self.assertFalse(fixture.errors)
        self.assertFalse(fixture.report['operations'])
        print('PASS EH8 storage missing targets=2 fabricated_checkpoints=0 stacks=0')

    def test_good(self):
        pressure.check_overlap(receipt())

    def test_reject_false_green(self):
        changes = [
            lambda r: r['sources']['storage'].update(start=3),
            lambda r: r['sources']['network'].update(end=40),
            lambda r: r['cycle'].update(end=1900),
            lambda r: r['phases'].pop(),
            lambda r: r['collections']['policy'].clear(),
            lambda r: r['collections']['engine'].pop(),
            lambda r: r['operations'].clear(),
            lambda r: r['operations'][1].update(start=8,end=9),
            lambda r: r.update(dns_packets=0),
            lambda r: r.update(dns_cancellations=0),
            lambda r: r.update(skkserv_failures=0),
            lambda r: r.update(storage_refusals=0),
            lambda r: r.update(sealed_outbox_ids=[]),
            lambda r: r.update(provider_watermark=1),
            lambda r: r.update(acknowledged_ids=0),
            lambda r: r.update(exact_ack_replays=3),
            lambda r: r.update(duplicate_ack_rows=1),
            lambda r: r.update(callback_probes=0),
            lambda r: r.update(callback_waits=1),
            lambda r: r.update(callback_io=1),
            lambda r: r.update(callback_max_us=20001),
            lambda r: r.update(rollback_restored=False),
            lambda r: r.update(cold_restart_recovered=False),
        ]
        for number, change in enumerate(changes):
            with self.subTest(control=number):
                report = copy.deepcopy(receipt())
                change(report)
                with self.assertRaises((AssertionError,KeyError)):
                    pressure.check_overlap(report)
        print(f'PASS EH8 overlap negative controls={len(changes)} synthetic_receipts_only=1 stacks=0')

    def test_instrumentation(self):
        root = Path(__file__).resolve().parents[2]
        (root/'build').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=root/'build') as directory:
            for process, filename in (('engine','ddskk-engine.el'),('policy','host-policy.el')):
                original = (root/'engine'/filename).read_text('utf-8')
                target = Path(directory)/filename
                target.write_text(original,encoding='utf-8')
                digest = pressure.instrument(target,process)
                text = target.read_text('utf-8')
                self.assertEqual(len(digest),64)
                self.assertEqual(text.count(f'(eh8-collect "{process}")'),1)
                self.assertIn('(garbage-collect)',text)
                self.assertEqual((root/'engine'/filename).read_text('utf-8'),original)
                with self.assertRaises(AssertionError): pressure.instrument(target,process)
        print('PASS EH8 copied-source instrumentation processes=2 source_edits=0 runtime_launches=0')

    def test_python_syntax(self):
        for filename in ('concurrent_pressure.py','prepare-concurrent-pressure.py',
                         'private-host-bundle.py','private-host-bundle-e2e.py'):
            ast.parse(Path(__file__).with_name(filename).read_text('utf-8'))

    def test_callback_log_only(self):
        root = Path(__file__).resolve().parents[2]
        (root/'build').mkdir(exist_ok=True)
        good = ('AFTER WARM BUF=[] SEL=0,0 COMP=-\nbranch=local-convert\nLOCAL_ACK fixture\n' +
                'CALLBACK_IO hooks=5 mask=271 pipe_io=0 blocking_waits=0\n' * 10 +
                'KEYLAT token=a total_us=100 claimed=1\n')
        with tempfile.TemporaryDirectory(dir=root/'build') as directory:
            log = Path(directory)/'synthetic.log'
            for number, text in enumerate((good, good.replace('blocking_waits=0','blocking_waits=1'),
                good.replace('total_us=100','total_us=20001'), good.replace('mask=271','mask=0'))):
                log.write_text(text,encoding='utf-8')
                command = ['pwsh','-NoProfile','-NonInteractive','-File',
                           str(root/'windows/test-host/test-host-policy-callbacks.ps1'),
                           '-Runtime','not-executed.exe','-CheckLogOnly',str(log)]
                result = subprocess.run(command,capture_output=True,text=True)
                self.assertEqual(result.returncode == 0,number == 0,result.stdout+result.stderr)
        print('PASS EH8 reused callback log checker negative_controls=3 synthetic_logs_only=1 stacks=0')


if __name__ == '__main__': unittest.main(verbosity=2)
