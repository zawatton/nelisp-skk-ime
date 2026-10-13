"""Coordinator-only S2.3 qualification; self-test is entirely offline.

Frozen bytes are replayed through diagnostics-only production owners.
Never refresh goldens; missing owner/wire evidence remains a failure.
"""
import argparse
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
FIXTURE = ROOT / 'tests/fixtures/host-native-nelisp'
GATE_SECONDS = 360
MODES = ('cpp', 'elisp')


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def exact(actual, expected, label):
    require(actual == expected,
            f'{label}: byte mismatch actual={len(actual)} expected={len(expected)} '
            f'actual_hex={actual.hex()} expected_hex={expected.hex()} '
            f'sha256={hashlib.sha256(actual).hexdigest()} expected_sha256={hashlib.sha256(expected).hexdigest()}')


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def frozen():
    manifest = json.loads((FIXTURE / 'manifest.json').read_text('utf-8'))
    require(manifest['schema'] == 1, 'fixture schema')
    for name in ('SKK-JISYO.synthetic', 'oracle.jsonl', 'parsed.bin'):
        require(hashlib.sha256((FIXTURE / name).read_bytes()).hexdigest() == manifest['sha256'][name],
                'corrupt frozen fixture: ' + name)
    rows = [json.loads(line) for line in (FIXTURE / 'oracle.jsonl').read_text('utf-8').splitlines()]
    require(len(rows) >= 1700, 'incomplete oracle corpus')
    return rows


def packed(entries):
    result = bytearray()
    for key, tail in sorted(entries.items()):
        result += struct.pack('<I', len(key)) + key + struct.pack('<I', len(tail)) + tail
    return bytes(result)


def index_records(data):
    """Extract exact raw shared map bytes, not candidates parsed in Python.

    Published schema-4 records are compiled local-conversion candidates,
    not ParseSkkJisyo raw tails. Validate the envelope/checksum and compare
    these exact records across owner modes. Raw parsed.bin is checked by
    the separate parsed-entry hook; never equate the two schemas.
    """
    data = bytes(data)
    require(len(data) >= 144, 'short published index')
    magic, schema, size, count = struct.unpack_from('<4Q', data)
    require((magic, schema, size) == (0x32495844464c4b53, 4, len(data)), 'index envelope')
    require(0 < count <= (len(data) - 144) // 48, 'index record count')
    checked = bytearray(data); checked[112:144] = b'\0' * 32
    exact(hashlib.sha256(checked).digest(), data[112:144], 'index checksum')
    floor = 144 + count * 48
    def view(offset, length):
        require(floor <= offset <= len(data) and length <= len(data) - offset, 'index offset')
        return data[offset:offset + length]
    entries = {}
    for n in range(count):
        ko, kl, uo, ul, so, sl = struct.unpack_from('<6Q', data, 144 + n * 48)
        key, user, tail = view(ko, kl), view(uo, ul), view(so, sl)
        require(not user, 'published index contains personal dictionary bytes')
        require(len(key) >= 2 and key[-2] == 31 and key[-1:] in (b'A', b'N', b'U'), 'index section tag')
        key = key[:-2]
        require(key not in entries, 'ambiguous duplicate section in published map')
        entries[key] = tail
    return packed(entries)


def check_receipt(receipt, golden):
    require(receipt['real_host'] and receipt['real_engine'] and receipt['oracle_exact'], 'synthetic-only run')
    require(receipt['leftovers'] == [], 'leftover owned PID')
    require(set(receipt['modes']) == set(MODES), 'missing owner mode')
    for name in MODES:
        phase = receipt['modes'][name]
        require(phase['merge'] == phase['startup'] == MODES.index(name), 'incorrect owner mode')
        require(phase['replay_cases'] == [r['case'] for r in replay_rows(frozen())], 'incomplete production replay')
        require(phase['wire_checks'] > 0 and phase['server_requests'] > 0, 'no public wire/server evidence')
        exact(bytes.fromhex(phase['parsed_hex']), golden, name + ' raw parsed map')
        require(phase['index_hex'], 'missing published index bytes')
        require(phase['tsf_exact'] and phase['emacs_exact'], 'missing TSF/Emacs exact evidence')
        require(phase['owner_evidence'], 'missing C++/NeLisp owner evidence')
    exact(bytes.fromhex(receipt['modes']['cpp']['index_hex']),
          bytes.fromhex(receipt['modes']['elisp']['index_hex']), 'compiled index owner parity')
    require(receipt['hp2_exact'], 'missing exact old-only HP2 evidence')
    require(not receipt['missing'], 'MISSING PUBLIC REPLAY: ' + '; '.join(receipt['missing']))
    require(receipt['elapsed'] < GATE_SECONDS, 'six-minute gate deadline')


def check_guard_cleanup(log):
    # PowerShell CLIXML can end immediately before the receipt on the same line.
    records = list(re.finditer(r'GUARD owned-command cleanup ', log))
    require(len(records) == 1, 'expected exactly one owned-PID cleanup receipt')
    payload = log[records[0].end():].partition('\n')[0]
    def reject_constant(value):
        raise ValueError('invalid JSON constant: ' + value)
    guard = json.loads(payload, parse_constant=reject_constant)
    require(isinstance(guard, dict), 'owned-PID cleanup receipt must be an object')
    require(guard['leftovers'] == [], 'leftover owned PID')
    return guard['leftovers']


def check_documents(tsf, emacs, cases):
    require('SETTLE TIMEOUT' not in tsf, 'TSF settle timeout')
    committed = ''
    for label, _, reading, word in cases:
        committed += word
        rows = re.findall(r'^AFTER ' + label + r' BUF=\[(.*?)\] SEL=.* COMP=-\r?$', tsf, re.M)
        require(len(rows) == 1, 'one settled TSF document required: ' + label)
        exact(rows[0].encode('utf-8'), committed.encode('utf-8'), 'TSF exact document ' + label)
        require(re.search(r'^RENDER \d+ ▽' + re.escape(reading) + r' cursor=', emacs, re.M), 'Emacs exact reading ' + label)
        require(re.search(r'^RENDER \d+ ▼' + re.escape(word) + r' cursor=', emacs, re.M), 'Emacs exact candidate ' + label)
    require(emacs.count('\nCLEAR\n') >= len(cases) and 'BUFFER_UNCHANGED=t' in emacs,
            'Emacs commit/clear evidence')


def replay_rows(rows):
    return [r for r in rows if r['case'].startswith(('builtin-', 'server-', 'engine-', 'quote-'))
            or r['case'] == 'parsed-entry' or re.fullmatch(r'startup-\d+', r['case'])]


def replay_input(row):
    fields = [row['case'].encode()] + [bytes.fromhex(v) for v in row['inputs_hex']]
    return b''.join(struct.pack('<I', len(v)) + v for v in fields)


def replay_output(data):
    at = 0
    def field():
        nonlocal at
        require(at + 4 <= len(data), 'replay short length')
        n, = struct.unpack_from('<I', data, at); at += 4
        require(n <= len(data) - at, 'replay short field')
        value = data[at:at+n]; at += n
        return value
    value = field()
    require(at + 4 <= len(data), 'replay short operations')
    count, = struct.unpack_from('<I', data, at); at += 4
    require(count <= 13, 'replay operation bound')
    operations = [field() for _ in range(count)]
    require(at == len(data), 'replay extra bytes')
    return value, operations


def check_replay(row, data, rows):
    value, operations = replay_output(data)
    exact(value, bytes.fromhex(row['result_hex']), row['case'])
    expected = [bytes.fromhex(r['result_hex']) for r in rows
                if row['case'].startswith('startup-') and
                r['case'] == row['case'].replace('startup-', 'startup-operation-')]
    require(operations == expected, row['case'] + ': exact ordered startup operations ' +
            repr(([v.hex() for v in operations], [v.hex() for v in expected])))


def replay_attempt(request, wire):
    value = request(wire)
    return None if value == b'ERR HN ORACLE UNAVAILABLE' else value


def expected_owner(row, mode):
    if mode == 'cpp' or row['case'] == 'parsed-entry':
        return b'cpp'
    # HN3 admission limits retain the production C++ oversized fallback.
    inputs = [bytes.fromhex(x) for x in row['inputs_hex']]
    if row['case'].startswith('builtin-missing-'):
        inputs = []
    if row['case'].startswith(('builtin-', 'server-', 'engine-', 'quote-')):
        size = 52 + sum(4 + len(x) for x in inputs)
        if size > 131072 or sum(4 + len(x) for x in inputs) > 262144:
            return b'cpp'
    return b'elisp'


def check_hp2(host, rows):
    require(re.search(r'policy-ready-wire hex=485032205245414459\r?$', host, re.M) is not None, 'old-only READY missing')
    require('hn3-answer operation=' not in host and 'hn3-wire-request' not in host and
            'hn3-startup-selection' not in host, 'HN3 used with old-only peer')
    policies = load('hn10_policy', ROOT / 'tools/ai/check-hn-policy.py')
    codec = load('hn10_hp2', HERE / 'host_policy_hp2.py')
    # Pin exact production wire replies to frozen numeric decisions after
    # the documented call-site projection and HP2 scalar saturation.
    goldens = {}
    for row in rows:
        if '/' not in row['case']:
            continue
        kind, a, b, c = policies.policy_inputs(row)
        q = codec.request(0, kind, a, b, c)
        signature = q[15:22]
        decision = int(bytes.fromhex(row['result_hex']))
        require(signature not in goldens or goldens[signature] == decision, 'ambiguous HP2 golden')
        goldens[signature] = decision
    checks = 0
    for qhex, rhex in re.findall(r'policy-hp2-wire q=([0-9a-f]+) r=([0-9a-f]+)', host):
        q, reply = bytes.fromhex(qhex), bytes.fromhex(rhex)
        require(len(q) == 23 and q.startswith(b'HP2Q') and q[-1:] == b'\n', 'HP2 query shape')
        require(len(reply) == 19 and reply.startswith(b'HP2R') and reply[4:15] == q[4:15] and
                reply[-1:] == b'\n' and all(32 <= c <= 95 for c in reply[4:-1]), 'HP2 reply envelope')
        signature = q[15:22]
        if signature not in goldens:
            continue  # Live ages/backoffs outside the frozen snapshot lattice.
        serial = 0
        for ch in q[4:15]:
            serial = serial * 64 + ch - 32
        exact(reply, codec.reply(serial, goldens[signature]), 'HP2 frozen reply')
        checks += 1
    require(checks > 0, 'no exact frozen HP2 replies')
    return checks


def self_test():
    require(replay_attempt(lambda _: b'ERR HN ORACLE UNAVAILABLE', b'replay') is None,
            'unavailable replay must retry')
    require(replay_attempt(lambda _: b'OK HN ORACLE cpp', b'replay') == b'OK HN ORACLE cpp',
            'owner mismatch must reach exact assertion')
    guard = 'GUARD owned-command cleanup {"remaining": [], "guarded": [], "terminated": [], "leftovers": []}'
    for log in (guard + '\n', '</Objs>' + guard, '</Objs>' + guard + '\r\n'):
        require(check_guard_cleanup(log) == [], 'valid guard cleanup receipt rejected')
    guard_controls = [
        ('two guard receipts', guard + '\n' + guard),
        ('two guard receipts on one line', guard + guard),
        ('no guard receipt', '</Objs>'),
        ('malformed guard JSON', guard[:-1]),
        ('trailing guard JSON data', guard + ' junk'),
        ('nonstandard guard JSON constant', guard.replace('"remaining": []', '"remaining": NaN')),
        ('guard leftover PID', guard.replace('"leftovers": []', '"leftovers": [123]')),
        ('guard false leftovers', guard.replace('"leftovers": []', '"leftovers": false')),
    ]
    for label, log in guard_controls:
        try:
            check_guard_cleanup(log)
        except (AssertionError, ValueError):
            print('REJECT ' + label)
        else:
            raise AssertionError('negative control accepted: ' + label)
    print(f'PASS guard cleanup self-test accepted=3 rejected={len(guard_controls)}')
    rows = frozen()
    golden = (FIXTURE / 'parsed.bin').read_bytes()
    entries = {bytes.fromhex(r['inputs_hex'][0]): bytes.fromhex(r['result_hex'])
               for r in rows if r['case'] == 'parsed-entry'}
    exact(packed(entries), golden, 'oracle parsed-entry serialization')
    # Construct a valid index envelope to exercise the actual index reader.
    payload = bytearray(); records = bytearray(); floor = 144 + len(entries) * 48
    for key, tail in sorted(entries.items()):
        tagged = key + b'\x1fN'; ko = floor + len(payload); payload += tagged
        so = floor + len(payload); payload += tail
        records += struct.pack('<6Q', ko, len(tagged), so, 0, so, len(tail))
    envelope = bytearray(struct.pack('<10Q', 0x32495844464c4b53, 4, floor + len(payload),
                                    len(entries), 1, 0, 0, 0, floor + len(payload), 0) + b'\0' * 64 + records + payload)
    envelope[112:144] = hashlib.sha256(envelope).digest()
    exact(index_records(envelope), golden, 'index reader roundtrip')
    phase = dict(merge=0, startup=0, wire_checks=9, server_requests=3,
                 index_hex=golden.hex(), parsed_hex=golden.hex(), replay_cases=[r['case'] for r in replay_rows(rows)], tsf_exact=True, emacs_exact=True, owner_evidence=True)
    receipt = dict(real_host=True, real_engine=True, oracle_exact=True, leftovers=[],
                   modes={'cpp': phase, 'elisp': dict(phase, merge=1, startup=1)},
                   hp2_exact=True, missing=[], elapsed=1)
    check_receipt(receipt, golden)
    controls = []
    bad = copy.deepcopy(receipt); bad['modes']['cpp']['index_hex'] = (bytes([golden[0] ^ 1]) + golden[1:]).hex()
    controls.append(('corrupted golden byte', bad))
    bad = copy.deepcopy(receipt); bad['modes']['cpp']['parsed_hex'] = '00'; controls.append(('raw parser mismatch', bad))
    bad = copy.deepcopy(receipt); bad['modes']['cpp']['replay_cases'] = []; controls.append(('missing replay', bad))
    bad = copy.deepcopy(receipt); del bad['modes']['elisp']; controls.append(('missing mode', bad))
    bad = copy.deepcopy(receipt); bad['leftovers'] = [123]; controls.append(('leftover PID', bad))
    bad = copy.deepcopy(receipt); bad['real_host'] = False; controls.append(('synthetic-only run', bad))
    bad = copy.deepcopy(receipt); bad['hp2_exact'] = False; controls.append(('missing HP2 hook', bad))
    bad = copy.deepcopy(receipt); bad['modes']['elisp']['emacs_exact'] = False; controls.append(('missing Emacs', bad))
    bad = copy.deepcopy(receipt); bad['missing'] = ['engine wire']; controls.append(('partial corpus', bad))
    for label, bad in controls:
        try:
            check_receipt(bad, golden)
        except AssertionError:
            print('REJECT ' + label)
        else:
            raise AssertionError('negative control accepted: ' + label)
    cases = [('A', '', 'alpha', 'new'), ('E', '', 'emoji', '😀'), ('T', '', 'trailing', 'no-final-newline')]
    document = ''; tsf = ''; emacs = '\n'
    for label, _, reading, word in cases:
        document += word
        tsf += f'AFTER {label} BUF=[{document}] SEL=0,0 COMP=-\n'
        emacs += f'RENDER 0 ▽{reading} cursor=t\nRENDER 0 ▼{word} cursor=t\nCLEAR\n'
    emacs += 'BUFFER_UNCHANGED=t\n'
    check_documents(tsf, emacs, cases)
    for bad_tsf, bad_emacs in ((tsf.replace('new', 'bad'), emacs),
                               (tsf, emacs.replace('▽alpha', '▽wrong')),
                               (tsf, emacs.replace('▼😀', '▼wrong')),
                               (tsf, emacs.replace('CLEAR', 'missing'))):
        try:
            check_documents(bad_tsf, bad_emacs, cases)
        except AssertionError:
            continue
        raise AssertionError('bad TSF/inline evidence accepted')
    corrupt_index = bytearray(envelope); corrupt_index[-1] ^= 1
    try:
        index_records(corrupt_index)
    except AssertionError:
        pass
    else:
        raise AssertionError('bad published checksum accepted')
    for row in replay_rows(rows):
        expected = bytes.fromhex(row['result_hex'])
        ops = [bytes.fromhex(r['result_hex']) for r in rows if
               row['case'].startswith('startup-') and r['case'] == row['case'].replace('startup-', 'startup-operation-')]
        payload = struct.pack('<I', len(expected)) + expected + struct.pack('<I', len(ops))
        payload += b''.join(struct.pack('<I', len(v)) + v for v in ops)
        check_replay(row, payload, rows)
        for corrupt in (payload[:-1], payload + b'x'):
            try:
                check_replay(row, corrupt, rows)
            except AssertionError:
                pass
            else:
                raise AssertionError('corrupt replay accepted')
        require(replay_input(row).startswith(struct.pack('<I', len(row['case']))), 'input framing')
    policy = load('hn10_self_policy', ROOT / 'tools/ai/check-hn-policy.py')
    codec = load('hn10_self_hp2', HERE / 'host_policy_hp2.py')
    hp2 = 'policy-ready-wire hex=485032205245414459\n'
    hp2_cases = 0
    for number, row in enumerate(rows, 1):
        if '/' not in row['case']:
            continue
        q = codec.request(number, *policy.policy_inputs(row))
        reply = codec.reply(number, int(bytes.fromhex(row['result_hex'])))
        hp2 += f'policy-hp2-wire q={q.hex()} r={reply.hex()}\n'
        hp2_cases += 1
    require(check_hp2(hp2, rows) == hp2_cases, 'HP2 complete byte checks')
    for corrupt in (hp2.replace('485032205245414459', '48503220524541445920484e333d31'),
                    hp2 + 'hn3-wire-request operation=1',
                    re.sub(r' r=([0-9a-f])', r' r=f', hp2, count=1)):
        try:
            check_hp2(corrupt, rows)
        except AssertionError:
            pass
        else:
            raise AssertionError('bad HP2 evidence accepted')
    print(f'PASS replay self-test cases={len(replay_rows(rows))} HP2={hp2_cases} corrupt_replays={2*len(replay_rows(rows))} HP2_controls=3')
    print(f'PASS S2.3 self-test checked={len(rows)} negative_controls={len(controls)+5+len(guard_controls)} stacks=0 emacs=0')


def text(path):
    return path.read_text('utf-8', errors='replace') if path.exists() else ''


def main(args):
    started = time.monotonic(); rows = frozen()
    build = (ROOT / args.build_dir).resolve()
    require(build.is_relative_to((ROOT / 'build').resolve()), 'private build directory required')
    binary = build / 'Release'
    oracle_binary = build / 'test-host/hn-oracle/Release/hn-oracle.exe'
    require(oracle_binary.is_file(), 'prebuilt CMake hn-oracle target required: ' + str(oracle_binary))
    for name in ('ddskk-engine-host.exe', 'ddskk-ime.dll', 'ddskk-ime-core.dll', 'tsf-host.exe'):
        require((binary / name).is_file(), 'prebuilt Release binary required: ' + name)
    runtime = Path(args.runtime).resolve(strict=True)
    emacs = shutil.which(args.emacs)
    require(emacs is not None, 'Emacs unavailable: S2.3 requires real inline evidence')
    run = build / ('hn10-oracle-' + uuid.uuid4().hex); run.mkdir()
    receipt = dict(real_host=False, real_engine=False, oracle_exact=False, leftovers=[], modes={},
                   hp2_exact=False, missing=[], elapsed=0)
    failures = []
    # The private C++ executable must reproduce every frozen byte first.
    result = subprocess.run([str(oracle_binary), str(FIXTURE / 'SKK-JISYO.synthetic'),
                             str(run / 'oracle')], capture_output=True, timeout=20)
    (run / 'oracle.stdout.log').write_bytes(result.stdout)
    (run / 'oracle.stderr.log').write_bytes(result.stderr)
    require(result.returncode == 0, 'private C++ oracle failed')
    oracle = load('hn10_oracle', ROOT / 'tools/ai/check-hn-oracle.py')
    oracle.compare(FIXTURE, run / 'oracle'); receipt['oracle_exact'] = True
    transport = load('hn10_transport', HERE / 'host-contracts.py')
    entries = [r for r in rows if r['case'] == 'parsed-entry']
    cases = [('ALPHA', 'SLASH a l p h a', 'alpha', 'new'),
             ('EMOJI', 'SLASH e m o j i', 'emoji', '😀'),
             ('TAIL', 'SLASH t r a i l i n g', 'trailing', 'no-final-newline')]
    # Documents are derived from frozen raw entries; annotations do not commit.
    tails = {bytes.fromhex(r['inputs_hex'][0]).decode('utf-8'): bytes.fromhex(r['result_hex']).decode('utf-8') for r in entries}
    for _, _, reading, word in cases:
        require(tails[reading].split('/')[1].split(';')[0] == word, 'TSF reading not in frozen corpus')
    listener = socket.socket()
    for port in range(31100, 31200):
        try:
            listener.bind(('127.0.0.1', port)); break
        except OSError:
            continue
    else:
        listener.close(); raise AssertionError('no private skkserv port')
    listener.listen(); listener.settimeout(.2)
    stop = threading.Event(); server_errors = []; fetched = []
    server_rows = [r for r in rows if r['case'] in ('server-0', 'server-1', 'server-2')]
    # First three server cases have an empty builtin tier and empty server tail.
    replies = {'おらくる' + suffix: bytes.fromhex(row['result_hex'])
               for suffix, row in zip(('あ', 'い', 'う'), server_rows)}
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
                        wire += part; require(len(wire) <= 4096, 'skkserv request limit')
                    if wire.startswith(b'1'):
                        key = wire[1:-1].decode('utf-8'); fetched.append(key)
                        client.sendall(replies.get(key, b'4') + b'\n')
            except Exception as error:
                server_errors.append(str(error))
    thread = threading.Thread(target=serve, daemon=True); thread.start()
    try:
        for mode in MODES:
            work = run / mode; work.mkdir(); replay_dir = work / 'replay'; replay_dir.mkdir(); inline = work / 'inline'; inline.mkdir()
            env = dict(os.environ)
            # Clear inherited dictionary/policy/test overrides, including flags
            # that could stop the engine, delay it or select alternate sources.
            for key in list(env):
                if key.startswith(('DDSKK_', 'NELISP_IME_', 'NATIVEIME_TEST_', 'INLINE_TEST_')):
                    env.pop(key)
            env.update(DDSKK_DICTIONARY_FILES=str(FIXTURE / 'SKK-JISYO.synthetic'),
                       DDSKK_LEARN_DISABLED='1', DDSKK_HOST_NATIVE_MERGE=str(MODES.index(mode)),
                       DDSKK_HOST_NATIVE_STARTUP=str(MODES.index(mode)), DDSKK_HOST_POLICY_COUNTERS='1',
                       DDSKK_HOST_POLICY_SHADOW='1' if mode == 'cpp' else '0',
                       DDSKK_HOST_POLICY_TEST_HP2_ONLY='1' if mode == 'cpp' else '0',
                       DDSKK_HOST_ORACLE_DIR=str(replay_dir), DDSKK_HARNESS_DIAGNOSTICS='1', NELISP_IME_ENGINE='ddskk',
                       DDSKK_HOST_LOG=str(work / 'host.log'), DDSKK_SKKSERV_ENABLE='1',
                       DDSKK_SKKSERV_HOST='127.0.0.1', DDSKK_SKKSERV_PORT=str(port),
                       INLINE_TEST_PIDFILE=str(inline / 'pid'), NELISP_IME_INLINE_DIR=str(inline),
                       INLINE_TEST_LOG=str(inline / 'emacs.log'), INLINE_TEST_TIMEOUT_SEC='150',
                       HOME=str(inline), APPDATA=str(inline / 'appdata'), LOCALAPPDATA=str(inline / 'local'))
            tokens = 'WAIT3000 ' + ' '.join(keys + ' WAIT300 SPACE SETTLE10000:' + label +
                                           '_CAND WAIT300 ENTER SETTLE10000:' + label + ' WAIT300'
                                           for label, keys, _, _ in cases) + ' WAIT15000'
            command = [sys.executable, '-B', str(HERE / 'host-test-process-guard.py'), 'run',
                       '--root', str(ROOT), '--cleanup', '--', 'pwsh', '-NoProfile', '-File',
                       str(HERE / 'run-harness.ps1'), '-Script', tokens, '-EngineHostPath', str(binary / 'ddskk-engine-host.exe'),
                       '-EngineExecutablePath', str(runtime), '-RepositoryPath', str(ROOT),
                       '-DllPath', str(binary / 'ddskk-ime.dll'), '-CoreDllPath', str(binary / 'ddskk-ime-core.dll'),
                       '-TsfHostExe', str(binary / 'tsf-host.exe'), '-LocalConversion', '1', '-SkkServEnable', '1',
                       '-SkkServPort', str(port), '-ColdLoadSleepSec', '45', '-PipeWaitTimeoutSec', '65',
                       '-TsfHostTimeoutSec', '100', '-ArtifactDirectory', str(work / 'harness'), '-SkipEngineWarmup',
                       '-InlinePreedit', '-PublishState', '-InlineDirectory', str(inline), '-InlinePidFile', str(inline / 'pid')]
            job = transport.Job(); process = subscriber = None; pipe_name = None; fetched_start = len(fetched)
            phase = dict(merge=MODES.index(mode), startup=MODES.index(mode), wire_checks=0,
                         server_requests=0, index_hex='', parsed_hex='', replay_cases=[], tsf_exact=False, emacs_exact=False, owner_evidence=False)
            receipt['modes'][mode] = phase
            def until(predicate, seconds, label):
                end = min(started + 345, time.monotonic() + seconds)
                while time.monotonic() < end:
                    value = predicate()
                    if value:
                        return value
                    require(process.poll() is None, label + ': harness exited')
                    require(not server_errors, 'skkserv: ' + repr(server_errors))
                    time.sleep(.05)
                raise AssertionError(label + ': deadline')
            def request(wire):
                pipe = transport.Pipe(pipe_name, timeout=2000)
                try:
                    pipe.transfer(wire, timeout=2000); reply, more = pipe.transfer(timeout=2000)
                    require(not more, 'public reply too large'); return reply
                finally:
                    pipe.close()
            try:
                subscriber = job.spawn([emacs, '-Q', '--batch', '-L', str(ROOT / 'emacs'), '-l',
                                        str(HERE / 'inline-emacs-subscriber.el')], env, work / 'emacs-process.log')
                process = job.spawn(command, env, work / 'guard.log')
                pipe_name = until(lambda: m[1] if (m := re.search(r'run-harness: pipe=(\S+)', text(work / 'guard.log'))) else None, 10, 'private pipe identity')
                require(re.fullmatch(r'\\\\\.\\pipe\\ddskk-test-[0-9a-f]{12}', pipe_name), 'refuse non-private pipe')
                until(lambda: list((work / 'harness').rglob('generation-*.index')), 110, 'host published index')
                receipt['real_host'] = True
                if mode == 'elisp':
                    until(lambda: request(b'HN ORACLE READY') == b'OK HN ORACLE READY',
                          15, 'HN3 replay readiness')
                parsed = {}
                for number, row in enumerate(replay_rows(rows)):
                    source = replay_dir / f'{number:04d}.request'
                    source.write_bytes(replay_input(row))
                    try:
                        wire = b'HN ORACLE ' + str(source).encode('utf-8').hex().encode()
                        # Publication can race the first replay. Retry only the
                        # explicit unavailable response; owner mismatches fail.
                        actual = until(lambda: replay_attempt(request, wire),
                                       15, row['case'] + ' HN3 owner')
                        (replay_dir / f'{number:04d}.owner').write_bytes(actual)
                        exact(actual, b'OK HN ORACLE ' + expected_owner(row, mode), row['case'] + ' owner')
                        replay = Path(str(source) + '.reply').read_bytes()
                        check_replay(row, replay, rows)
                        if row['case'] == 'parsed-entry':
                            parsed[bytes.fromhex(row['inputs_hex'][0])] = replay_output(replay)[0]
                        phase['wire_checks'] += 1
                        phase['replay_cases'].append(row['case'])
                    except (AssertionError, OSError) as error:
                        failures.append(mode + ': replay ' + str(number) + ' ' + row['case'] + ': ' + str(error))
                phase['parsed_hex'] = packed(parsed).hex()
                try:
                    exact(packed(parsed), (FIXTURE / 'parsed.bin').read_bytes(), mode + ' raw parsed map')
                except AssertionError as error:
                    failures.append(str(error))
                for reading, expected in replies.items():
                    wire = b'LOCAL SERVER ' + ''.join(f'{ord(c):06x}' for c in reading).encode() + b' -'
                    actual = until(lambda: value if (value := request(wire)) != b'SERVER PENDING' else None, 5, 'server corpus')
                    exact(actual, b'SERVER ' + expected, 'server golden ' + reading); phase['wire_checks'] += 1
                exact(request(b'ENGINE CURRENT'), b'ENGINE ddskk', 'public startup selection')
                paths = list((work / 'harness').rglob('generation-*.index'))
                projected = [index_records(path.read_bytes()) for path in paths]
                require(projected, 'no host index')
                phase['index_hex'] = projected[-1].hex()
                (work / 'published-records.bin').write_bytes(projected[-1])
                for data in projected:
                    exact(data, projected[0], mode + ' stable compiled index records')
                process.wait(timeout=max(1, min(120, started + 345 - time.monotonic())))
                require(process.returncode == 0, 'harness failed')
                (inline / 'stop').write_text('stop', encoding='utf-8'); subscriber.wait(timeout=8)
                require(subscriber.returncode == 0, 'real Emacs subscriber failed')
                logs = list((work / 'harness').rglob('tsf.stdout.log'))
                require(len(logs) == 1, 'one private stack per sequential owner phase required')
                try:
                    check_documents(text(logs[0]), text(inline / 'emacs.log'), cases)
                    phase['tsf_exact'] = phase['emacs_exact'] = True
                except AssertionError as error:
                    failures.append(mode + ': ' + str(error))
                host = text(Path(str(work / 'host.log') + '.1')) + text(work / 'host.log')
                receipt['real_engine'] = receipt['real_engine'] or bool(re.search(r'child-start pid=\d+', host))
                if mode == 'cpp':
                    phase['hp2_checks'] = check_hp2(host, rows)
                    receipt['hp2_exact'] = True
                if mode == 'elisp':
                    phase['owner_evidence'] = all(f'hn3-answer operation={op}' in host for op in (1, 2, 3, 4, 5))
                    require('hn3-startup-selection runner=ddskk' in host, 'Elisp startup selection missing')
                else:
                    phase['owner_evidence'] = ('hn3-answer operation=' not in host and
                        'hn-oracle-owner case=builtin-3 owner=cpp' in host and
                        bool(re.search(r'child-start pid=\d+', host)))
                phase['server_requests'] = len(fetched) - fetched_start
                leftovers = check_guard_cleanup(text(work / 'guard.log'))
                receipt['leftovers'].extend(leftovers)
            except Exception as error:
                failures.append(mode + ': ' + str(error))
            finally:
                (inline / 'stop').write_text('stop', encoding='utf-8')
                if process and process.poll() is None and pipe_name:
                    try:
                        request(b'SHUTDOWN'); process.wait(timeout=5)
                    except Exception:
                        pass
                job.close()
                for owned in (process, subscriber):
                    if owned:
                        owned.wait(timeout=5)
        receipt['elapsed'] = time.monotonic() - started
        receipt['failures'] = failures
        (run / 'receipt.json').write_text(json.dumps(receipt, indent=2, ensure_ascii=False) + '\n', encoding='utf-8', newline='\n')
        require(not failures, '; '.join(failures))
        check_receipt(receipt, (FIXTURE / 'parsed.bin').read_bytes())
        print('PASS S2.3 real host/engine oracle parity', flush=True)
    finally:
        stop.set(); thread.join(3); listener.close()
        print('ARTIFACTS ' + str(run), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--runtime', default=os.environ.get('HN_IME_RUNTIME'))
    parser.add_argument('--build-dir', default='build/w')
    parser.add_argument('--emacs', default='emacs')
    args = parser.parse_args()
    try:
        if args.self_test:
            self_test()
        else:
            require(args.runtime, '--runtime or HN_IME_RUNTIME required')
            main(args)
    except Exception as error:
        print('FAIL S2.3 ' + str(error), flush=True)
        raise SystemExit(1)
