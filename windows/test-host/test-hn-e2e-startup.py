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
# HnStartup waits for the policy child before exposing the host pipe.
POLICY_STARTUP_MS = 60000
PIPE_WAIT_SEC = 65
PREPARATION_SEC = 75
COLD_LOAD_SEC = 45
TSF_HOST_SEC = 220  # Starts after pipe readiness and the cold-load sleep.
EVIDENCE_SEC = PREPARATION_SEC + PIPE_WAIT_SEC + COLD_LOAD_SEC + TSF_HOST_SEC
HARNESS_EXIT_SEC = EVIDENCE_SEC + 15
GATE_SEC = HARNESS_EXIT_SEC + 15
RESTART_WAIT_SEC = POLICY_STARTUP_MS / 1000 + 5  # Retirement/backoff plus native load.


def wait_for(predicate, deadline, step, check_running=lambda: None,
             monotonic=time.monotonic, sleep=time.sleep):
    while monotonic() < deadline:
        value = predicate()
        if value:
            return value
        check_running()
        sleep(min(.05, max(0, deadline - monotonic())))
    raise AssertionError(step + ': coverage evidence deadline')


def replacement_ready(log, retired_pid):
    # READY has no epoch field: require it after a new PID's policy-start.
    starts = list(re.finditer(r'policy-start pid=(\d+) epoch=(\d+)', log))
    if not starts or int(starts[-1][1]) == retired_pid:
        return False
    return bool(re.search(r'policy-ready startup_ms=\d+ native=1\b',
                          log[starts[-1].end():]))


def coverage_script():
    conversion = 'K a n a SPACE ENTER SETTLE30000:'
    # tsf-host rejects WAIT > 60000 without waiting. Preserve both 65 s
    # windows: DOWN needs retirement/backoff plus native READY (26-34 s).
    # SETTLE observes provider idle, not readiness of the replacement child.
    return ('a i SPACE WAIT3000 ENTER SETTLE30000:COLD WAIT60000 WAIT5000 ' +
            conversion + 'WARM WAIT3000 ' + conversion + 'HITS WAIT33000 ' +
            conversion + 'EXPIRY WAIT3000 ' + conversion + 'DOWN WAIT40000 WAIT25000 ' +
            conversion + 'RECOVER WAIT3000 ' + conversion + 'FINAL WAITACK10000:6 WAIT5000')


def check_script_waits(script):
    waits = []
    tokens = script.split()
    for token in tokens:
        if token.startswith('WAIT') and not token.startswith('WAITACK'):
            match = re.fullmatch(r'WAIT([0-9]+)', token)
            if not match or not 0 < int(match[1]) <= 60000:
                raise AssertionError('unsupported TSF wait token: ' + token)
            waits.append(int(match[1]))
    down = tokens.index('SETTLE30000:DOWN')
    recover = tokens.index('SETTLE30000:RECOVER')
    post_down_ms = 0
    for token in tokens[down + 1:recover]:
        if not re.fullmatch(r'WAIT[0-9]+', token):
            break  # Only waits before the RECOVER conversion count.
        post_down_ms += int(token[4:])
    if recover <= down or post_down_ms < 40000:
        raise AssertionError('post-DOWN native restart wait must be at least 40000 ms')
    # FINAL needs the snapshot's 1 s tail plus up to 3 s for a fresh batch.
    final = tokens.index('SETTLE30000:FINAL')
    final_tail_ms = 0
    for token in reversed(tokens[final + 1:]):
        if not re.fullmatch(r'WAIT[0-9]+', token):
            break  # ACK waiting cannot guarantee time for counter sampling.
        final_tail_ms += int(token[4:])
    if final_tail_ms < 5000:
        raise AssertionError('post-FINAL trailing snapshot wait must be at least 5000 ms')
    return waits


def private_key(pipe_name):
    prefix = chr(92) * 2 + '.' + chr(92) + 'pipe' + chr(92) + 'ddskk-test-'
    match = re.fullmatch(re.escape(prefix) + r'([0-9a-f]{12})', pipe_name)
    if not match:
        raise AssertionError('unrecognized private harness pipe')
    return 'Software' + chr(92) + 'NativeIME-test-' + match.group(1)


def counters(text):
    result = {g: [int(n), int(m)] for g, n, m in re.findall(
        r'policy-evaluations group=(\w+) native=(\d+) nelisp-selected=(\d+)', text)}
    if not set(GROUPS).issubset(result):
        raise AssertionError('missing five-group counter samples')
    # STARTUP is separate from the five authoritative phase-delta groups.
    return {g: result[g] for g in (*GROUPS, 'STARTUP') if g in result}


def complete_counter_sample(text):
    """Ignore a partially written batch; STARTUP terminates S4.3 samples."""
    ends = list(re.finditer(r'^.*policy-evaluations group=STARTUP native=\d+ nelisp-selected=\d+\r?\n', text, re.M))
    if not ends:
        return None
    end = ends[-1].end()
    starts = list(re.finditer(r'^.*policy-evaluations group=SOURCES ', text[:end], re.M))
    if not starts:
        raise AssertionError('completed counter batch missing SOURCES')
    return ends[-1].group(0), counters(text[starts[-1].start():end])


def delta(before, after):
    result = {g: [after[g][i] - before[g][i] for i in range(2)] for g in GROUPS}
    if any(n < 0 for values in result.values() for n in values):
        raise AssertionError('counter reset/reordered samples')
    return result


def check_replayed_ack(identity, reply):
    operation, sequence = identity
    # LOCAL persists one (operation, overlay sequence) watermark per client.
    # Replaying an older operation echoes its ID with the latest durable
    # sequence, including after engine reload or policy-child retirement.
    match = re.fullmatch(rb'ACK ' + re.escape(operation.encode()) + rb' ([1-9]\d*)', reply)
    if not match or int(match[1]) < int(sequence):
        raise AssertionError('acknowledged learning ID/watermark lost: ' + operation +
                             ' minimum_sequence=' + str(sequence) + ' reply=' + repr(reply))


def discard_ids(text, marker):
    return set(re.findall(re.escape(marker) + r' request=([1-9]\d*)\b', text))


def suspended_timeout(before, suspended):
    """Require a newly timed-out HP2 request, even when older faults exist."""
    new = discard_ids(suspended, 'policy-timeout-discard') - discard_ids(before, 'policy-timeout-discard')
    for match in re.finditer(r'policy-request request=([1-9]\d*) kind=(\d+) key=(\S+)', suspended):
        request, kind, key = match.groups()
        if request in new:
            timeout = re.search(r'policy-timeout-discard request=' + request + r'\b', suspended[match.end():])
            if timeout:
                return dict(request=request, kind=int(kind), key=key)
    return None


def check_fault(before, suspended, resumed):
    fault = suspended_timeout(before, suspended)
    if not fault:
        raise AssertionError('no HP2 request timeout while suspended')
    request = fault['request']
    if request in discard_ids(suspended, 'policy-late-discard'):
        raise AssertionError('fault response arrived before resume')
    if request not in discard_ids(resumed, 'policy-late-discard') - discard_ids(suspended, 'policy-late-discard'):
        raise AssertionError('missing same-request late discard after resume')
    return fault


def check(tsf, host, samples, fetches, elapsed):
    if elapsed >= GATE_SEC:
        raise AssertionError('runtime exceeded gate budget')
    if 'UnknownToken:' in tsf:
        raise AssertionError('TSF rejected a scripted token')
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
    # Counter native=N counts C++ evaluations, not native policy children.
    ready = re.findall(r'policy-ready startup_ms=\d+ native=([01])\b', host)
    if len(ready) < 2 or any(state != '1' for state in ready):
        raise AssertionError('native child unavailable/refused')
    bundle = helpers.bundle_evidence(host, minimum=2)
    startup_ms = list(map(int, re.findall(r'policy-ready startup_ms=(\d+)', host)))
    if any(ms > POLICY_STARTUP_MS for ms in startup_ms):
        raise AssertionError('60 s native policy startup budget')
    if 'hn3-answer operation=5' not in host or 'hn3-startup-selection runner=ddskk' not in host:
        raise AssertionError('startup did not use HN3')
    if host.index('hn3-answer operation=5') > host.index('child-start pid=') or host.count('hn3-answer operation=5') < 2:
        raise AssertionError('initial/reload startup HN3 missing')
    startup = samples['FINAL'].get('STARTUP')
    if startup is None or startup[0] != 0 or startup[1] < 2:
        raise AssertionError('initial/reload native startup did not select NeLisp child decisions')
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
    restart_callers = {}
    for kind in (3, 7):
        counts = re.findall(r'policy-authoritative kind=' + str(kind) + r' count=([1-9]\d*)\b', host)
        if not counts:
            raise AssertionError('uncovered restart caller kind=' + str(kind))
        restart_callers[str(kind)] = sum(map(int, counts))
    if 'replacement-published engine=' not in host:
        raise AssertionError('missing real engine replacement')
    if fetches[1] <= fetches[0]:
        raise AssertionError('2 second negative cache did not expire/refetch')
    keepalive = re.findall(r'policy-keepalive refreshed=(\d+) skipped=(\d+)', host)
    keepalive_evidence = dict(samples=len(keepalive),
        refreshed=max((int(row[0]) for row in keepalive), default=0),
        skipped=max((int(row[1]) for row in keepalive), default=0))
    return dict(bundle=bundle, policy_ready_startup_ms=startup_ms, startup_counters=startup,
                keepalive=keepalive_evidence, restart_callers=restart_callers,
                phases=phases, callback_probes=len(rows), pipe_io=0, blocking_waits=0,
                callback_max_us=max(times), negative_cache_fetches=fetches, exact_documents=7)


def self_test():
    # Virtual time covers native loading without starting a stack or sleeping.
    assert RESTART_WAIT_SEC == 65
    for load_sec in (26, 34, 60):
        clock = [0.0]
        def advance(seconds):
            clock[0] += seconds
        wait_for(lambda: clock[0] >= load_sec, RESTART_WAIT_SEC,
                 'post-kill server miss', monotonic=lambda: clock[0], sleep=advance)
        assert load_sec <= clock[0] < RESTART_WAIT_SEC
    for deadline, step in ((3, 'post-kill server miss'),
                           (3, 'post-disable server miss'),
                           (RESTART_WAIT_SEC, 'replacement policy-ready'),
                           (EVIDENCE_SEC, 'AFTER RECOVER')):
        clock = [0.0]
        try:
            wait_for(lambda: False, deadline, step,
                     monotonic=lambda: clock[0], sleep=advance)
        except AssertionError as error:
            assert str(error) == step + ': coverage evidence deadline'
            assert clock[0] == deadline
        else:
            raise AssertionError('named wait deadline accepted')
    old_ready = 'policy-start pid=10 epoch=1\npolicy-ready startup_ms=26000 native=1\n'
    loading = old_ready + 'policy-retire pid=10 epoch=1\npolicy-start pid=11 epoch=2\n'
    assert not replacement_ready(old_ready, 10)
    assert not replacement_ready(loading, 10)
    assert not replacement_ready(loading + 'policy-ready startup_ms=34000 native=0\n', 10)
    assert replacement_ready(loading + 'policy-ready startup_ms=34000 native=1\n', 10)
    before_fault = ('policy-request request=1 kind=4 key=4:2:0:100:0\n'
                    'policy-timeout-discard request=1\npolicy-late-discard request=1\n')
    suspended_fault = before_fault + ('policy-request request=2 kind=4 key=4:2:0:200:0\n'
                                    'policy-timeout-discard request=2\n')
    resumed_fault = suspended_fault + 'policy-late-discard request=2\n'
    assert check_fault(before_fault, suspended_fault, resumed_fault) == dict(
        request='2', kind=4, key='4:2:0:200:0')
    fault_controls = (
        (before_fault, before_fault, resumed_fault), # Fresh memo: no new timeout.
        (before_fault, suspended_fault.replace('policy-timeout-discard request=2', ''), resumed_fault),
        (before_fault, suspended_fault.replace('policy-request request=2', 'missing-request request=2'), resumed_fault),
        (before_fault, suspended_fault, resumed_fault.replace('policy-late-discard request=2', 'policy-late-discard request=3')),
        (before_fault, resumed_fault, resumed_fault), # Late response before resume.
        (before_fault, suspended_fault, suspended_fault),
        (before_fault, before_fault + 'policy-timeout-discard request=3\npolicy-request request=3 kind=4 key=x\n',
         resumed_fault + 'policy-late-discard request=3\n'))
    for control in fault_controls:
        try:
            check_fault(*control)
        except AssertionError:
            continue
        raise AssertionError('fault negative control accepted')
    script = coverage_script()
    waits = check_script_waits(script)
    assert sum(waits) == 180000 and script.count('WAIT60000 WAIT5000') == 1
    assert script.count('DOWN WAIT40000 WAIT25000') == 1
    check_script_waits(script.replace('DOWN WAIT40000 WAIT25000', 'DOWN WAIT40000'))
    restart_controls = (
        script.replace('DOWN WAIT40000 WAIT25000', 'DOWN WAIT39999'),
        script.replace('DOWN WAIT40000 WAIT25000', 'DOWN'),
        script.replace('DOWN WAIT40000 WAIT25000 K', 'DOWN K WAIT40000 WAIT25000'))
    for control in restart_controls:
        try:
            check_script_waits(control)
        except AssertionError:
            continue
        raise AssertionError('short post-DOWN native restart wait accepted')
    final_controls = (
        script.removesuffix(' WAIT5000'),
        script.removesuffix(' WAIT5000') + ' WAIT4999',
        script.replace('FINAL WAITACK10000:6 WAIT5000', 'FINAL WAIT5000 WAITACK10000:6'))
    for control in final_controls:
        try:
            check_script_waits(control)
        except AssertionError as error:
            assert str(error) == 'post-FINAL trailing snapshot wait must be at least 5000 ms'
            continue
        raise AssertionError('missing/short post-FINAL trailing snapshot wait accepted')
    for invalid in ('WAIT65000', 'WAIT60001', 'WAITbad', 'WAIT0'):
        try:
            check_script_waits(script + ' ' + invalid)
        except AssertionError:
            continue
        raise AssertionError('unsupported TSF wait accepted')
    identity = ('0123456789abcdef0123456789abcdef.1', '1')
    check_replayed_ack(identity, b'ACK ' + identity[0].encode() + b' 1')
    # Three FIFO learnings for the same client advance the durable watermark;
    # an old replay is still acknowledged without repeating its mutation.
    check_replayed_ack(identity, b'ACK ' + identity[0].encode() + b' 3')
    ack_controls = (b'', b'ERR LOCAL STORAGE',
                    b'ACK different.1 3', b'ACK ' + identity[0].encode() + b' 0',
                    b'ACK ' + identity[0].encode() + b' 3 extra',
                    b'ACK ' + identity[0].encode() + b' 3\n')
    for reply in ack_controls:
        try:
            check_replayed_ack(identity, reply)
        except AssertionError:
            continue
        raise AssertionError('invalid replay ACK accepted')
    try:
        check_replayed_ack((identity[0], '3'), b'ACK ' + identity[0].encode() + b' 2')
    except AssertionError:
        pass
    else:
        raise AssertionError('regressed replay watermark accepted')
    tsf = '\n'.join('AFTER ' + label + ' BUF=[' + 'あい' + '仮名' * i + '] COMP=-'
                    for i, label in enumerate(LABELS))
    tsf += '\n' + '\n'.join(['CALLBACK_IO hooks=5 mask=271 pipe_io=0 blocking_waits=0'] * 20)
    tsf += '\nKEYLAT token=K total_us=1 claimed=1\nLOCAL_ACK_WAIT OK required=6 observed=6\n'
    tsf += ''.join(f'LOCAL_ACK id=fixture.{i} sequence={i}\n' for i in range(1, 7))
    host = ('policy-ready startup_ms=1 native=1 policy-ready startup_ms=1 native=1 hn3-answer operation=5 hn3-startup-selection runner=ddskk child-start pid=1 hn3-answer operation=5 policy-timeout-discard policy-late-discard policy-retire policy-ready policy-ready'
            ' policy-authoritative kind=3 count=1 policy-authoritative kind=7 count=1'
            ' replacement-published engine=ddskk')
    host += '\nHN-BUNDLE native=11 interpreted=1 refused=host-policy-hn3-reply\n' * 2
    host += ''.join(f'policy-evaluations group={group} native={count} nelisp-selected=1\n'
                    for group, count in zip(GROUPS, (0, 1, 0, 1, 0)))
    assert set(counters(host)) == set(GROUPS)
    assert complete_counter_sample(host) is None
    host += 'policy-evaluations group=STARTUP native=0 nelisp-selected=2\n'
    batch = complete_counter_sample(host)
    assert batch[1]['STARTUP'] == [0, 2]
    partial = host + 'policy-evaluations group=SOURCES native=999 nelisp-selected=999\n'
    assert complete_counter_sample(partial) == batch
    assert counters(partial)['SOURCES'] == [999, 999] # Negative control for old parser.
    incomplete = host + 'policy-evaluations group=SOURCES native=999 nelisp-selected=999\n' + 'policy-evaluations group=STARTUP native=0 nelisp-selected=3\n'
    try:
        complete_counter_sample(incomplete)
    except AssertionError:
        pass
    else:
        raise AssertionError('incomplete terminated batch accepted')
    parsed = counters(host)
    assert set(parsed) == set(GROUPS) | {'STARTUP'} and parsed['STARTUP'] == [0, 2]
    samples = {label: {g: [n, m] for g in GROUPS} for label, n, m in (
        ('ZERO', 0, 0), ('COLD', 1, 0), ('WARM', 2, 1), ('HITS', 2, 2),
        ('EXPIRY', 3, 3), ('DOWN', 4, 4), ('RECOVER', 5, 5), ('FINAL', 5, 6))}
    for label in LABELS:
        samples[label]['STARTUP'] = [0, 1 if label == 'COLD' else 2]
    assert PIPE_WAIT_SEC == 65 and PIPE_WAIT_SEC * 1000 > POLICY_STARTUP_MS
    assert EVIDENCE_SEC == 405 and HARNESS_EXIT_SEC == 420 and GATE_SEC == 435
    assert check(tsf, host, samples, [1, 2], 1)['policy_ready_startup_ms'] == [1, 1]
    assert check(tsf, host, samples, [1, 2], 1)['keepalive'] == dict(samples=0, refreshed=0, skipped=0)
    assert check(tsf, host, samples, [1, 2], 1)['restart_callers'] == {'3': 1, '7': 1}
    evidence = host + 'policy-keepalive refreshed=2 skipped=4\npolicy-keepalive refreshed=5 skipped=7\n'
    assert check(tsf, evidence, samples, [1, 2], 1)['keepalive'] == dict(samples=2, refreshed=5, skipped=7)
    measured_host = host.replace('startup_ms=1', 'startup_ms=26000', 1)
    assert check(tsf, measured_host, samples, [1, 2], 1)['policy_ready_startup_ms'] == [26000, 1]
    assert check(tsf, host.replace('startup_ms=1', 'startup_ms=60000'),
                 samples, [1, 2], GATE_SEC - 1)['policy_ready_startup_ms'] == [60000, 60000]
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
                 (tsf + '\nHR UnknownToken:WAIT65000=80070057\n', host, samples, [1, 2], 1),
                 (tsf, host.replace('HN-BUNDLE', 'MISSING'), samples, [1, 2], 1),
                 (tsf, host, bad, [1, 2], 1),
                 (tsf, host.replace('startup_ms=1 native=1', 'startup_ms=1 native=0'), samples, [1, 2], 1),
                 (tsf, host.replace('policy-ready startup_ms=1 native=1', 'missing-ready'), samples, [1, 2], 1),
                 (tsf, host.replace('startup_ms=1 native=1', 'startup_ms=1 native=0', 1), samples, [1, 2], 1),
                 (tsf, host.replace('hn3-answer operation=5', ''), samples, [1, 2], 1),
                 (tsf.replace('sequence=6', 'sequence=0'), host, samples, [1, 2], 1)]
    # Replies (including keep-alive/reseed) cannot stand in for caller use.
    # Keep this gate strict: HN9p fixes future-epoch pruning in the product.
    for kind in (3, 7):
        for reply in (f'policy-compare match request=1 kind={kind}',
                      f'policy-compare match request=1 kind={kind} keepalive=1 reseed=1'):
            mutations.append((tsf, host.replace(f'policy-authoritative kind={kind} count=1', reply),
                              samples, [1, 2], 1))
    for marker in ('policy-authoritative kind=3 count=1',
                   'policy-authoritative kind=7 count=1', 'replacement-published engine='):
        mutations.append((tsf, host.replace(marker, ''), samples, [1, 2], 1))
    bad = copy.deepcopy(samples); bad['FINAL']['RESTART'][1] = 0
    mutations.extend([(tsf.replace('仮名', 'X'), host, samples, [1, 2], 1),
        (tsf.replace('blocking_waits=0', 'blocking_waits=1'), host, samples, [1, 2], 1),
        (tsf, host.replace('policy-late-discard', ''), samples, [1, 2], 1),
        (tsf, host.replace('policy-timeout-discard', ''), samples, [1, 2], 1),
        (tsf, host, bad, [1, 2], 1), (tsf, host, samples, [1, 1], 1),
        (tsf, host, samples, [1, 2], GATE_SEC), ('', host, samples, [1, 2], 1),
        (tsf, host.replace('startup_ms=1', 'startup_ms=60001', 1), samples, [1, 2], 1),
        (tsf.replace('LOCAL_ACK_WAIT OK', 'LOCAL_ACK_WAIT TIMEOUT'), host, samples, [1, 2], 1)])
    for startup in (None, [1, 2], [0, 1]):
        bad = copy.deepcopy(samples)
        if startup is None:
            del bad['FINAL']['STARTUP']
        else:
            bad['FINAL']['STARTUP'] = startup
        mutations.append((tsf, host, bad, [1, 2], 1))
    for args in mutations:
        try:
            check(*args)
        except AssertionError:
            continue
        raise AssertionError('coverage negative control accepted')
    counter_controls = [''] + [re.sub(r'policy-evaluations group=' + group + r' [^\n]*\n', '', host)
                               for group in GROUPS]
    for text in counter_controls:
        try:
            counters(text)
        except AssertionError:
            continue
        raise AssertionError('missing authoritative counters accepted')
    print(f'PASS policy coverage checker negative_controls={len(mutations)+3+len(counter_controls)} fault_negative_controls={len(fault_controls)} replay_ack_negative_controls={len(ack_controls)+1} wait_negative_controls=4 restart_wait_negative_controls={len(restart_controls)} final_wait_negative_controls={len(final_controls)} named_deadline_controls=4 native_restart_waits=3 replacement_ready_controls=4 stacks=0')


def main(args):
    started = time.monotonic()
    bundle = native_bundle()
    if time.monotonic() - started > PREPARATION_SEC:
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
    tokens = coverage_script()
    check_script_waits(tokens)
    bin_dir = ROOT / args.build_dir / 'Release'
    command = [sys.executable, '-B', str(Path(__file__).with_name('host-test-process-guard.py')),
        'run', '--root', str(ROOT), '--cleanup', '--', 'pwsh', '-NoProfile', '-File',
        str(Path(__file__).with_name('run-harness.ps1')), '-Script', tokens,
        '-EngineHostPath', str(bin_dir / 'ddskk-engine-host.exe'), '-EngineExecutablePath', args.runtime,
        '-RepositoryPath', str(ROOT), '-DllPath', str(bin_dir / 'ddskk-ime.dll'),
        '-CoreDllPath', str(bin_dir / 'ddskk-ime-core.dll'), '-TsfHostExe', str(bin_dir / 'tsf-host.exe'),
        '-LocalConversion', '1', '-SkkServEnable', '1', '-SkkServPort', env['DDSKK_SKKSERV_PORT'],
        '-ColdLoadSleepSec', str(args.cold_load_sleep_sec), '-SkipEngineWarmup',
        '-PipeWaitTimeoutSec', str(PIPE_WAIT_SEC), '-TsfHostTimeoutSec', str(TSF_HOST_SEC),
        '-ArtifactDirectory', str(run / 'harness')]
    job = transport.Job(); process = None; held = None; suspended = False
    samples = {'ZERO': {g: [0, 0] for g in GROUPS}}; cache_fetches = []
    phase_markers = {}
    def text(path):
        return path.read_text('utf-8', errors='replace') if path.exists() else ''
    def host():
        return text(Path(str(host_path) + '.1')) + text(host_path)
    def tsf():
        paths = list((run / 'harness').glob('*/tsf.stdout.log'))
        if len(paths) > 1:
            raise AssertionError('more than one private TSF stack')
        return text(paths[0]) if paths else ''
    def until(predicate, seconds=60, step='evidence', deadline=None):
        end = min(started + EVIDENCE_SEC, time.monotonic() + seconds,
                  deadline if deadline is not None else float('inf'))
        def check_running():
            if process.poll() is not None or errors:
                raise AssertionError(step + ': harness ended/fixture failed before evidence: ' + str(errors))
        return wait_for(predicate, end, step, check_running)
    def snapshot(label, seconds=3):
        # SETTLE covers TSF/provider idle, not independent learning/publication.
        # Allow its tail to finish, then require a newly completed counter batch.
        # LogDecisions runs often but PolicyCounters::Log samples only once/s.
        time.sleep(1)
        before = complete_counter_sample(host())
        def fresh():
            sample = complete_counter_sample(host())
            return sample if sample and (not before or sample[0] != before[0]) else None
        marker, samples[label] = until(fresh, seconds, step='snapshot ' + label)
        print('COUNTS ' + label + ' ' + json.dumps(samples[label]), flush=True)
        phase_markers[label] = dict(counter_marker=marker.strip(),
                                    elapsed_sec=time.monotonic() - started)
        print('COUNTER_MARKER ' + label + ' ' + marker.strip(), flush=True)
    def request(data, deadline=None, step='private control request'):
        def timeout():
            if deadline is None:
                return 2000
            remaining = min(deadline, started + EVIDENCE_SEC) - time.monotonic()
            if remaining <= 0:
                raise TimeoutError('request deadline')
            return max(1, int(remaining * 1000))
        pipe = None
        try:
            pipe = transport.Pipe(pipe_name, timeout=timeout())
            pipe.transfer(data, timeout=timeout())
            reply, more = pipe.transfer(timeout=timeout())
            if more:
                raise AssertionError('oversized private control reply')
            return reply
        except TimeoutError as error:
            raise AssertionError(step + ': ' + str(error)) from error
        finally:
            if pipe is not None:
                pipe.close()
    def configure_server(enabled):
        # Derive only this harness's private key from its copied pipe identity.
        # Open an existing key; never create keys or touch the installed IME.
        import winreg
        key = private_key(pipe_name)
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, key, 0, winreg.KEY_SET_VALUE) as handle:
            winreg.SetValueEx(handle, 'SkkServEnable', 0, winreg.REG_DWORD, int(enabled))
        print('PRIVATE_SERVER enabled=' + str(int(enabled)), flush=True)
    def server_miss(key=b'00304b00306a', seconds=3, step='server miss'):
        end = min(started + EVIDENCE_SEC, time.monotonic() + seconds)
        until(lambda: request(b'LOCAL SERVER ' + key + b' -', deadline=end,
                              step=step) == b'SERVER 4', seconds, step=step, deadline=end)
    def suspend(resume=False):
        fn = getattr(C.WinDLL('ntdll'), 'NtResumeProcess' if resume else 'NtSuspendProcess')
        fn.argtypes, fn.restype = [W.HANDLE], W.LONG
        if fn(held) != 0:
            raise AssertionError('policy suspend/resume failed')
    def replay_ack(identity):
        operation, sequence = identity
        wire = f'LOCAL LEARN {operation} 00304b00306a 004eee00540d'.encode()
        check_replayed_ack(identity, request(wire))
    try:
        process = job.spawn(command, env, gate_path)
        pipe_name = until(lambda: (m.group(1) if (m := re.search(r'run-harness: pipe=(\S+)', text(gate_path))) else None), PIPE_WAIT_SEC, step='harness pipe identity')
        # The pipe identity is logged before host startup, not at pipe readiness.
        until(lambda: 'AFTER COLD ' in tsf(), PIPE_WAIT_SEC + COLD_LOAD_SEC + 35, step='AFTER COLD'); snapshot('COLD')
        server_miss(); time.sleep(.5); server_miss()
        # Cache's independent S3 comparison remains eagerly observed. Keep the
        # server disabled for steady local conversions so that observer is not
        # confused with authoritative CacheTtl/Capacity memo-hit evaluations.
        configure_server(False); server_miss()
        if request(b'ENGINE RELOAD') != b'OK RELOADING':
            raise AssertionError('private engine reload failed')
        until(lambda: 'AFTER WARM ' in tsf(), 70, step='AFTER WARM'); snapshot('WARM')
        server_miss() # Exercise a seeded SOURCES hit within the steady window.
        until(lambda: 'AFTER HITS ' in tsf(), 10, step='AFTER HITS'); snapshot('HITS')
        # Leave exact source/cache signatures idle beyond the policy memo's 30 s.
        # Also prove the real 2 s negative cache refetches, without a new override.
        configure_server(True); server_miss(); time.sleep(.3); server_miss()
        time.sleep(30.5); cache_fetches.append(fetches[0]); server_miss()
        until(lambda: fetches[0] > cache_fetches[0], 3, step='negative cache refetch'); cache_fetches.append(fetches[0])
        until(lambda: 'AFTER EXPIRY ' in tsf(), 10, step='AFTER EXPIRY'); snapshot('EXPIRY')
        acknowledged = until(lambda: re.findall(r'LOCAL_ACK id=(\S+) sequence=([1-9]\d*)', tsf()), 3, step='learning ACK identities')
        for identity in acknowledged:
            replay_ack(identity)
        # A novel reading alone still uses seeded SOURCES/Capacity signatures.
        # Populate it first, then poll its completed negative cache entry while
        # suspended: the independent Cache observer includes its changing age
        # and queues a real HP2 exchange even when authoritative memos are fresh.
        fault_key = ''.join(f'{ord(c):06x}' for c in 'はんきゅうじぇい' + uuid.uuid4().hex.translate(
            str.maketrans('0123456789', 'あいうえおかきくけこ'))).encode('ascii')
        before_fetch = fetches[0]
        server_miss(fault_key)
        until(lambda: fetches[0] > before_fetch, 3, step='fault key fetch')
        policy_pid = int(re.findall(r'policy-start pid=(\d+)', host())[-1])
        held = transport.api('OpenProcess', W.HANDLE, W.DWORD, W.BOOL, W.DWORD)(0x1FFFFF, False, policy_pid)
        member = W.BOOL()
        if not held or not transport.api('IsProcessInJob', W.BOOL, W.HANDLE, W.HANDLE, C.POINTER(W.BOOL))(
                held, job.handle, C.byref(member)) or not member.value or transport.wait(held, 0) != 258:
            raise AssertionError('refuse fault against unowned/exited policy child')
        if 'AFTER DOWN ' in tsf():
            raise AssertionError('missed conversion pause window')
        suspend(); suspended = True
        before_fault = host() # Exclude timeouts that preceded the suspend.
        time.sleep(.1) # Give the novel completed entry an unseeded cache age.
        server_miss(fault_key)
        fault = until(lambda: suspended_timeout(before_fault, host()), 2, step='suspended HP2 timeout')
        pressure(pipe_name, transport)
        time.sleep(3) # Emulate GC while DOWN conversion runs.
        if 'AFTER DOWN ' not in tsf():
            raise AssertionError('conversion did not complete during policy GC pause')
        suspended_fault = host()
        suspend(True); suspended = False
        until(lambda: fault['request'] in discard_ids(host(), 'policy-late-discard'), 4, step='resumed HP2 late discard')
        fault = check_fault(before_fault, suspended_fault, host())
        print('FAULT ' + json.dumps(fault), flush=True)
        if not transport.api('TerminateProcess', W.BOOL, W.HANDLE, W.UINT)(held, 17):
            raise AssertionError('owned policy kill failed')
        until(lambda: 'policy-retire pid=' + str(policy_pid) in host(),
              RESTART_WAIT_SEC, step='post-kill policy retire')
        server_miss(seconds=RESTART_WAIT_SEC, step='post-kill server miss')
        until(lambda: 'AFTER DOWN ' in tsf(), RESTART_WAIT_SEC, step='post-kill AFTER DOWN')
        snapshot('DOWN', seconds=RESTART_WAIT_SEC)
        # Registry refresh/LOCAL SERVER may otherwise run while the native child
        # is still loading. Old READY lines must not satisfy this barrier.
        until(lambda: replacement_ready(host(), policy_pid), RESTART_WAIT_SEC,
              step='replacement policy-ready')
        configure_server(False)
        server_miss(seconds=RESTART_WAIT_SEC, step='post-disable server miss')
        until(lambda: 'AFTER RECOVER ' in tsf(), 70, step='AFTER RECOVER'); snapshot('RECOVER')
        for identity in acknowledged:
            replay_ack(identity)
        server_miss()
        until(lambda: 'AFTER FINAL ' in tsf(), 10, step='AFTER FINAL'); snapshot('FINAL')
        process.wait(timeout=min(15, max(1, HARNESS_EXIT_SEC - (time.monotonic() - started))))
        if process.returncode or not re.search(r'GUARD .*"leftovers": \[\]', text(gate_path)):
            raise AssertionError('harness/owned cleanup failed')
        print('NOTE wrong/late HN3 injection skipped: no existing fenced frame-injection hook; HP2 late-discard exercised', flush=True)
        report = check(tsf(), host(), samples, cache_fetches, time.monotonic() - started)
        report['acknowledged_ids_preserved'] = acknowledged
        report['fault'] = fault
        report['pressure'] = dict(clients=4, exact_replies=32)
        (run / 'coverage.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
        print('PASS S4.3 native startup ' + json.dumps(report), flush=True)
    finally:
        (run / 'samples.json').write_text(json.dumps(samples, indent=2) + '\n', encoding='utf-8')
        (run / 'phase-markers.json').write_text(json.dumps(phase_markers, indent=2) + '\n', encoding='utf-8')
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
    parser.add_argument('--cold-load-sleep-sec', type=int, choices=[COLD_LOAD_SEC], default=COLD_LOAD_SEC)
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
