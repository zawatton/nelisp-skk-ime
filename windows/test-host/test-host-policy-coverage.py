"""Coordinator-only one-stack S4.2 gate; --self-test never imports Win32 tools."""
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
GROUPS = ('SOURCES', 'CACHE', 'RESTART', 'PUBLICATION', 'LEARNING')
LABELS = ('COLD', 'WARM', 'HITS', 'EXPIRY', 'DOWN', 'RECOVER', 'FINAL')


def wait_for(predicate, deadline, step, check_running=lambda: None,
             monotonic=time.monotonic, sleep=time.sleep):
    while monotonic() < deadline:
        value = predicate()
        if value:
            return value
        check_running()
        sleep(min(.05, max(0, deadline - monotonic())))
    raise AssertionError(step + ': coverage evidence deadline')


def coverage_script():
    conversion = 'K a n a SPACE ENTER SETTLE30000:'
    # TSF accepts waits up to 60000 ms; preserve both existing 65 s windows.
    return ('a i SPACE WAIT3000 ENTER SETTLE30000:COLD WAIT60000 WAIT5000 ' +
            conversion + 'WARM WAIT3000 ' + conversion + 'HITS WAIT33000 ' +
            conversion + 'EXPIRY WAIT10000 ' + conversion + 'DOWN WAIT60000 WAIT5000 ' +
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
    # ACK can finish immediately; only trailing waits protect FINAL sampling.
    final = tokens.index('SETTLE30000:FINAL')
    final_tail_ms = 0
    for token in reversed(tokens[final + 1:]):
        if not re.fullmatch(r'WAIT[0-9]+', token):
            break
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
    if set(result) != set(GROUPS):
        raise AssertionError('missing five-group counter samples')
    return result


def complete_counter_sample(text):
    """Ignore a partially written batch; LEARNING ends S4.2's five groups."""
    ends = list(re.finditer(r'^.*policy-evaluations group=LEARNING native=\d+ nelisp-selected=\d+\r?\n', text, re.M))
    if not ends:
        return None
    end = ends[-1].end()
    # A missing SOURCES row must not borrow groups from the prior batch.
    start = ends[-2].end() if len(ends) > 1 else 0
    starts = list(re.finditer(r'^.*policy-evaluations group=SOURCES ', text[start:end], re.M))
    if not starts:
        raise AssertionError('completed counter batch missing SOURCES')
    return ends[-1].group(0), counters(text[start + starts[-1].start():end])


def settled_counter_sample(host, until, label, seconds=3, sleep=time.sleep):
    # SETTLE covers TSF/provider idle, not independent learning/publication.
    # Finish its tail, then require a new complete batch (logged once/s).
    sleep(1)
    before = complete_counter_sample(host())
    def fresh():
        sample = complete_counter_sample(host())
        return sample if sample and (not before or sample[0] != before[0]) else None
    return until(fresh, seconds, step='snapshot ' + label)


def delta(before, after):
    result = {g: [after[g][i] - before[g][i] for i in range(2)] for g in GROUPS}
    if any(n < 0 for values in result.values() for n in values):
        raise AssertionError('counter reset/reordered samples')
    return result


NOVEL_PHASES = ('cold', 'generation', 'restart')


def novel_fixture():
    return ''.join(
        f'policy-request request={i} kind=8 key=8:1:{256+i}:1:0\n'
        f'policy-compare match request={i} kind=8\n'
        f'policy-novel phase={phase} key=8:1:{256+i}:1:0 native=1 first=1 answer=1 later=1\n'
        for i, phase in enumerate(NOVEL_PHASES, 1))


def check_novel_fallback(host):
    evidence = {}
    keys = set()
    for phase in NOVEL_PHASES:
        rows = re.findall(r'policy-novel phase=' + phase +
            r' key=(8:\d+:\d+:1:0) native=(\d+) first=(\d+) answer=(\d+) later=(\d+)\b', host)
        if len(rows) != 1 or rows[0][1:] != ('1', '1', '1', '1'):
            raise AssertionError('missing deterministic novel-key fallback/answer/memo: ' + phase)
        key = rows[0][0]
        if key in keys or not 257 <= int(key.split(':')[2]) <= 262143:
            raise AssertionError('novel key reused/seeded/out of range: ' + phase)
        requests = re.findall(r'policy-request request=(\d+) kind=8 key=' + re.escape(key) + r'\b', host)
        if not requests or not re.search(r'policy-compare match request=' + requests[0] + r' kind=8(?: elapsed_ms=\d+)?(?:\n|$)', host):
            raise AssertionError('novel key missing matching child answer: ' + phase)
        if host.index('policy-request request=' + requests[0] + ' kind=8 key=' + key) > host.index('policy-novel phase=' + phase):
            raise AssertionError('novel evidence precedes child request: ' + phase)
        keys.add(key)
        evidence[phase] = dict(key=key, native=1, answer=1, memo=1)
    return evidence


def request_novel_fallback(request, phase):
    reply = request(b'POLICY TEST NOVEL ' + phase.encode('ascii')).decode('ascii')
    if not re.fullmatch(r'policy-novel phase=' + phase +
                       r' key=8:\d+:\d+:1:0 native=1 first=1 answer=1 later=1', reply):
        raise AssertionError('deterministic novel-key probe failed: ' + phase + ': ' + reply)


def check(tsf, host, samples, fetches, elapsed):
    if elapsed >= 285:
        raise AssertionError('runtime exceeded 285 seconds')
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
    # Cold/reload/prefetch may answer before any caller; their deltas are observational.
    novel = check_novel_fallback(host)
    for name in ('expiry', 'child-down'):
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
    return dict(novel_fallback=novel, phases=phases, restart_callers=restart_callers, callback_probes=len(rows), pipe_io=0, blocking_waits=0,
                callback_max_us=max(times), negative_cache_fetches=fetches, exact_documents=7)


def self_test():
    script = coverage_script()
    assert sum(check_script_waits(script)) == 187000
    assert script.count('WAIT60000 WAIT5000') == 2
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
    def batch(stamp, n):
        return ''.join(f'{stamp} policy-evaluations group={g} native={n} nelisp-selected=1\n'
                       for g in GROUPS)
    old, tail, fresh = batch('old', 1), batch('tail', 2), batch('fresh', 2)
    parsed = complete_counter_sample(old)
    assert parsed[1] == {g: [1, 1] for g in GROUPS}
    assert complete_counter_sample('') is None
    partial = old + tail.rsplit('\n', 2)[0] + '\n'
    assert complete_counter_sample(partial) == parsed
    assert counters(partial)['SOURCES'] == [2, 1] # Old parser mixes batches.
    assert complete_counter_sample(old + tail[:-1]) == parsed # Unterminated LEARNING.
    counter_controls = [old + tail.replace(
        f'tail policy-evaluations group={g} native=2 nelisp-selected=1\n', '')
        for g in GROUPS[:-1]]
    counter_controls.append('x policy-evaluations group=LEARNING native=2 nelisp-selected=1\n')
    for control in counter_controls:
        try:
            complete_counter_sample(control)
        except AssertionError:
            continue
        raise AssertionError('incomplete terminated batch accepted')
    # Tail settles at 1 s; partial/frozen batches cannot satisfy freshness.
    # Same counter values with a new timestamp must satisfy it.
    for label in LABELS:
        clock = [0.0]
        def advance(seconds):
            clock[0] += seconds
        def log():
            if clock[0] < 1:
                return old
            if clock[0] < 1.5:
                return old + tail
            if clock[0] < 2:
                return old + tail + fresh.rsplit('\n', 2)[0] + '\n'
            return old + tail + fresh
        def until(predicate, seconds, step):
            assert step == 'snapshot ' + label
            return wait_for(predicate, clock[0] + seconds, step,
                            monotonic=lambda: clock[0], sleep=advance)
        marker, sample = settled_counter_sample(log, until, label, sleep=advance)
        assert marker.startswith('fresh ') and sample == {g: [2, 1] for g in GROUPS}
        assert 2 <= clock[0] < 2.1
    deadline_steps = ['AFTER ' + label for label in LABELS] + ['snapshot ' + label for label in LABELS]
    for step in deadline_steps:
        clock = [0.0]
        try:
            wait_for(lambda: False, 3, step, monotonic=lambda: clock[0], sleep=advance)
        except AssertionError as error:
            assert str(error) == step + ': coverage evidence deadline' and clock[0] == 3
            continue
        raise AssertionError('named wait deadline accepted')
    clock = [0.0]
    def until_frozen(predicate, seconds, step):
        return wait_for(predicate, clock[0] + seconds, step,
                        monotonic=lambda: clock[0], sleep=advance)
    try:
        settled_counter_sample(lambda: old, until_frozen, 'WARM', sleep=advance)
    except AssertionError as error:
        assert str(error) == 'snapshot WARM: coverage evidence deadline' and clock[0] == 4
    else:
        raise AssertionError('stale counter batch accepted')
    tsf = '\n'.join('AFTER ' + label + ' BUF=[' + 'あい' + '仮名' * i + '] COMP=-'
                    for i, label in enumerate(LABELS))
    tsf += '\n' + '\n'.join(['CALLBACK_IO hooks=5 mask=271 pipe_io=0 blocking_waits=0'] * 20)
    tsf += '\nKEYLAT token=K total_us=1 claimed=1\nLOCAL_ACK_WAIT OK required=6 observed=6\n'
    host = ('policy-timeout-discard policy-late-discard policy-retire policy-ready policy-ready'
            ' policy-authoritative kind=3 count=1 policy-authoritative kind=7 count=1'
            ' replacement-published engine=ddskk')
    samples = {label: {g: [n, m] for g in GROUPS} for label, n, m in (
        ('ZERO', 0, 0), ('COLD', 1, 0), ('WARM', 2, 1), ('HITS', 2, 2),
        ('EXPIRY', 3, 3), ('DOWN', 4, 4), ('RECOVER', 5, 5), ('FINAL', 5, 6))}
    host += '\n' + novel_fixture()
    assert check(tsf, host, samples, [1, 2], 1)['restart_callers'] == {'3': 1, '7': 1}
    pipe = chr(92) * 2 + '.' + chr(92) + 'pipe' + chr(92) + 'ddskk-test-012345abcdef'
    assert private_key(pipe) == 'Software' + chr(92) + 'NativeIME-test-012345abcdef'
    for invalid in (pipe.replace('ddskk-test-', 'ddskk-live-'), pipe.replace('.', 'X'), pipe + 'x'):
        try:
            private_key(invalid)
        except AssertionError:
            continue
        raise AssertionError('non-private key accepted')
    bad = copy.deepcopy(samples); bad['HITS']['CACHE'][0] += 1
    mutations = [(tsf, host, bad, [1, 2], 1)]
    # A background reply does not prove either restart caller used authority.
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
        (tsf, host, bad, [1, 2], 1), (tsf, host, samples, [1, 1], 1),
        (tsf, host, samples, [1, 2], 285), ('', host, samples, [1, 2], 1),
        (tsf.replace('LOCAL_ACK_WAIT OK', 'LOCAL_ACK_WAIT TIMEOUT'), host, samples, [1, 2], 1)])
    # Seeds/prefetch winning all three ordinary miss phases is valid.
    raced = copy.deepcopy(samples)
    for label, n in (('COLD', 0), ('WARM', 0), ('HITS', 0),
                     ('EXPIRY', 1), ('DOWN', 2), ('RECOVER', 2), ('FINAL', 2)):
        for g in GROUPS:
            raced[label][g][0] = n
    check(tsf, host, raced, [1, 2], 1)
    for phase in NOVEL_PHASES:
        mutations.append((tsf, re.sub(r'policy-novel phase=' + phase + r'[^\n]*\n', '', host), raced, [1, 2], 1))
    for old, new in (('native=1 first=1', 'native=0 first=1'),
                     ('native=1 first=1', 'native=2 first=1'),
                     ('answer=1 later=1', 'answer=0 later=1'),
                     ('answer=1 later=1', 'answer=1 later=0'),
                     ('policy-compare match request=1 kind=8', 'policy-compare match request=1 kind=8 keepalive=1'),
                     ('8:1:257:1:0', '8:1:256:1:0')):
        mutations.append((tsf, host.replace(old, new), raced, [1, 2], 1))
    mutations.append((tsf, host.replace(novel_fixture(), ''), raced, [1, 2], 1))
    for label, previous in (('EXPIRY', 'HITS'), ('DOWN', 'EXPIRY')):
        missing = copy.deepcopy(samples)
        for g in GROUPS:
            missing[label][g][0] = missing[previous][g][0]
        mutations.append((tsf, host, missing, [1, 2], 1))
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
    print(f'PASS policy coverage checker negative_controls={len(mutations)+4} counter_batch_controls={len(counter_controls)} snapshot_controls={len(LABELS)+1} final_wait_negative_controls={len(final_controls)} wait_negative_controls=4 named_deadline_controls={len(deadline_steps)} stacks=0')


def hook_self_test():
    """Compile the production hook/dispatch; fake replies only, no host stack."""
    import subprocess
    out = ROOT / 'build/w/policy-novel-unit'
    out.mkdir(parents=True, exist_ok=True)
    main_source = (ROOT / 'windows/host/main.cpp').read_text('utf-8')
    start = main_source.index('    } else if (engine_request.starts_with("POLICY TEST NOVEL ")) {')
    end = main_source.index('    } else if (engine_request == "HN3 TEST SHADOW") {', start)
    dispatch = main_source[start:end].replace('    } else if', '    if', 1) + '    }\n'
    cpp = r'''#define wmain host_program_main
#include "HOST_MAIN"
#undef wmain
namespace { namespace native_adapter {
struct ShadowPolicyTest {
  static int Run(bool enabled, bool preseed, bool counters) {
    auto& policy = shadow;
    policy.enabled_ = true; policy.switches_[1] = true; policy.healthy_ = true;
    engine_epoch = 1; publication_generation = 0;
    if (preseed) policy.Remember({PolicyKind::Capacity, 1, 0, 257, 1, 0, 1}, 1);
    std::atomic<bool> done{false};
    std::thread child;
    if (enabled) child = std::thread([&] {
      while (!done) {
        Observation value{}; bool have = false;
        {
          std::unique_lock lock(policy.mutex_);
          policy.changed_.wait_for(lock, std::chrono::milliseconds(10), [&] {
            return done || !policy.queue_.empty();
          });
          if (!policy.queue_.empty()) {
            value = policy.queue_.front(); policy.queue_.pop_front(); have = true;
          }
        }
        if (have) {
          // HP2 round-trip inputs, independently decoded scalar/boolean fields.
          const auto frame = policy.Frame(1, value);
          const auto a = (frame[19]-32)*4096 + (frame[20]-32)*64 + frame[21]-32;
          const auto answer = uint64_t{a < 256 || frame[17] != 32};
          policy.Remember(value, answer); policy.changed_.notify_all();
        }
      }
    });
    int failures = 0;
    unsigned i = 0;
    for (const auto phase : {"cold", "generation", "restart"}) {
      const std::string engine_request = std::string("POLICY TEST NOVEL ") + phase;
      std::string response;
      DISPATCH
      const auto expected = std::string("policy-novel phase=") + phase + " key=8:1:" +
          std::to_string(257 + i++) + ":1:0 native=1 first=1 answer=1 later=1";
      if (response != (enabled ? expected : "ERR POLICY NOVEL DISABLED")) ++failures;
    }
    done = true; policy.changed_.notify_all();
    if (child.joinable()) child.join();
    if (PolicyCounters::native[1] != (enabled && counters ? 3 : 0) ||
        PolicyCounters::nelisp[1] != (enabled && counters ? 3 : 0)) ++failures;
    if (!enabled && (!policy.queue_.empty() || !policy.decisions_.empty() || !policy.recent_.empty())) ++failures;
    std::printf("policy novel unit: enabled=%d counters=%d failures=%d stacks=0\n", enabled, counters, failures);
    return failures ? 1 : 0;
  }
};
} }
int main(int argc, char** argv) {
  if (argc != 5) return 2;
  g_pipe_name = std::string(argv[1]) == "private" ? L"\\\\.\\pipe\\ddskk-test-unit" : L"\\\\.\\pipe\\ddskk-live";
  return native_adapter::ShadowPolicyTest::Run(std::string(argv[2]) == "1",
      std::string(argv[3]) == "preseed", std::string(argv[4]) == "1");
}
'''
    (out / 'unit.cpp').write_text(cpp.replace('HOST_MAIN', (ROOT / 'windows/host/main.cpp').as_posix())
                                 .replace('DISPATCH', dispatch), encoding='utf-8', newline='\n')
    (out / 'CMakeLists.txt').write_text(
        'cmake_minimum_required(VERSION 3.24)\nproject(policy_novel_unit LANGUAGES CXX)\n'
        'add_executable(policy-novel-unit unit.cpp '
        f'"{(ROOT / "windows/src/local_index.cpp").as_posix()}" '
        f'"{(ROOT / "windows/src/engine_protocol.cpp").as_posix()}")\n'
        'target_compile_features(policy-novel-unit PRIVATE cxx_std_20)\n'
        'target_compile_definitions(policy-novel-unit PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)\n'
        'target_compile_options(policy-novel-unit PRIVATE /utf-8)\n'
        'target_link_libraries(policy-novel-unit PRIVATE ws2_32 advapi32 bcrypt)\n',
        encoding='utf-8', newline='\n')
    for command in (['cmake', '-S', str(out), '-B', str(out / 'build'), '-G',
                     'Visual Studio 17 2022', '-A', 'x64'],
                    ['cmake', '--build', str(out / 'build'), '--config', 'Release']):
        result = subprocess.run(command, capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=120)
        if result.returncode:
            raise AssertionError('novel unit build failed:\n' + result.stdout + result.stderr)
    executable = out / 'build/Release/policy-novel-unit.exe'
    cases = [('private', None, True, False), ('private', '0', True, False),
             ('private', '1', False, False), ('public', '1', True, False),
             ('private', '1', True, True)]
    for pipe, diagnostics, private_registry, enabled in cases:
        for counters_on in ('0', '1'):
            env = dict(os.environ, DDSKK_HOST_POLICY_COUNTERS=counters_on,
                       NATIVEIME_REGISTRY_KEY='Software\\NativeIME-test-unit' if private_registry else 'Software\\NativeIME')
            env.pop('DDSKK_HARNESS_DIAGNOSTICS', None)
            if diagnostics is not None:
                env['DDSKK_HARNESS_DIAGNOSTICS'] = diagnostics
            result = subprocess.run([str(executable), pipe, str(int(enabled)), 'normal', counters_on],
                                    env=env, capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=10)
            if result.returncode:
                raise AssertionError('novel hook unit failed: ' + result.stdout + result.stderr)
    result = subprocess.run([str(executable), 'private', '1', 'preseed', '1'],
                            env=dict(os.environ, DDSKK_HOST_POLICY_COUNTERS='1', DDSKK_HARNESS_DIAGNOSTICS='1',
                                     NATIVEIME_REGISTRY_KEY='Software\\NativeIME-test-unit'),
                            capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=10)
    if result.returncode != 1:
        raise AssertionError('preseeded/no-first-fallback unit control accepted')
    print('PASS policy novel hook cases=10 negative_controls=1 production_inert=8 harness_on=2 counters=unchanged stacks=0')


def main(args):
    spec = importlib.util.spec_from_file_location('contracts', Path(__file__).with_name('host-contracts.py'))
    transport = importlib.util.module_from_spec(spec); spec.loader.exec_module(transport)
    run = ROOT / args.build_dir / ('policy-coverage-' + uuid.uuid4().hex)
    if not run.resolve().is_relative_to((ROOT / 'build').resolve()):
        raise AssertionError('private build directory required')
    run.mkdir(parents=True)
    host_path, gate_path = run / 'host.log', run / 'gate.log'
    env = dict(os.environ, DDSKK_HOST_LOG=str(host_path), DDSKK_SKKSERV_HOST='127.0.0.1')
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
        '-PipeWaitTimeoutSec', '10', '-TsfHostTimeoutSec', '220', '-ArtifactDirectory', str(run / 'harness')]
    job = transport.Job(); process = None; held = None; suspended = False
    started = time.monotonic(); samples = {'ZERO': {g: [0, 0] for g in GROUPS}}; cache_fetches = []
    phase_markers = {}
    def text(path):
        return path.read_text('utf-8', errors='replace') if path.exists() else ''
    def host():
        return text(Path(str(host_path) + '.1')) + text(host_path)
    def tsf():
        paths = list((run / 'harness').rglob('tsf.stdout.log'))
        if len(paths) > 1:
            raise AssertionError('more than one private TSF stack')
        return text(paths[0]) if paths else ''
    def until(predicate, seconds=60, step='evidence', deadline=None):
        end = min(started + 255, time.monotonic() + seconds,
                  deadline if deadline is not None else float('inf'))
        def check_running():
            if process.poll() is not None or errors:
                raise AssertionError(step + ': harness ended/fixture failed before evidence: ' + str(errors))
        return wait_for(predicate, end, step, check_running)
    def snapshot(label):
        marker, samples[label] = settled_counter_sample(host, until, label)
        print('COUNTS ' + label + ' ' + json.dumps(samples[label]), flush=True)
        phase_markers[label] = dict(counter_marker=marker.strip(),
                                    elapsed_sec=time.monotonic() - started)
        print('COUNTER_MARKER ' + label + ' ' + marker.strip(), flush=True)
    def request(data, deadline=None, step='private control request'):
        def timeout():
            if deadline is None:
                return 2000
            remaining = min(deadline, started + 255) - time.monotonic()
            if remaining <= 0:
                raise TimeoutError('request deadline')
            return max(1, min(2000, int(remaining * 1000)))
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
        end = min(started + 255, time.monotonic() + seconds)
        until(lambda: request(b'LOCAL SERVER ' + key + b' -', deadline=end,
                              step=step) == b'SERVER 4', seconds, step=step, deadline=end)
    def suspend(resume=False):
        fn = getattr(C.WinDLL('ntdll'), 'NtResumeProcess' if resume else 'NtSuspendProcess')
        fn.argtypes, fn.restype = [W.HANDLE], W.LONG
        if fn(held) != 0:
            raise AssertionError('policy suspend/resume failed')
    try:
        process = job.spawn(command, env, gate_path)
        pipe_name = until(lambda: (m.group(1) if (m := re.search(r'run-harness: pipe=(\S+)', text(gate_path))) else None), 10, step='harness pipe identity')
        until(lambda: 'AFTER COLD ' in tsf(), 90, step='AFTER COLD'); snapshot('COLD')
        until(lambda: 'policy-ready' in host(), 60, step='novel cold policy-ready')
        request_novel_fallback(request, 'cold')
        server_miss(step='cold server miss'); time.sleep(.5); server_miss(step='cold cached miss')
        # Cache's independent S3 comparison remains eagerly observed. Keep the
        # server disabled for steady local conversions so that observer is not
        # confused with authoritative CacheTtl/Capacity memo-hit evaluations.
        configure_server(False); server_miss(step='disabled server miss')
        published = host().count('replacement-published engine=')
        if request(b'ENGINE RELOAD') != b'OK RELOADING':
            raise AssertionError('private engine reload failed')
        until(lambda: host().count('replacement-published engine=') > published, 65,
              step='novel generation replacement-published')
        request_novel_fallback(request, 'generation')
        until(lambda: 'AFTER WARM ' in tsf(), 70, step='AFTER WARM')
        snapshot('WARM')
        server_miss(step='steady seeded SOURCES hit') # Exercise a seeded SOURCES hit within the steady window.
        until(lambda: 'AFTER HITS ' in tsf(), 10, step='AFTER HITS'); snapshot('HITS')
        # Leave exact source/cache signatures idle beyond the policy memo's 30 s.
        # Also prove the real 2 s negative cache refetches, without a new override.
        configure_server(True); server_miss(step='expiry server prime'); time.sleep(.3); server_miss(step='expiry cached miss')
        time.sleep(30.5); cache_fetches.append(fetches[0]); server_miss(step='negative cache expiry')
        until(lambda: fetches[0] > cache_fetches[0], 3, step='negative cache refetch'); cache_fetches.append(fetches[0])
        until(lambda: 'AFTER EXPIRY ' in tsf(), 10, step='AFTER EXPIRY'); snapshot('EXPIRY')
        # A fresh memo may skip HP2 work for the old reading. Prime a novel
        # completed negative entry; its changing Cache observer age queues work
        # while suspended, independently of authoritative memo keep-alive.
        fault_key = ''.join(f'{ord(c):06x}' for c in 'はんきゅうじぇい' + uuid.uuid4().hex.translate(
            str.maketrans('0123456789', 'あいうえおかきくけこ'))).encode('ascii')
        before_fetch = fetches[0]
        server_miss(fault_key, step='fault key prime')
        until(lambda: fetches[0] > before_fetch, 3, step='fault key fetch')
        policy_pid = int(re.findall(r'policy-start pid=(\d+)', host())[-1])
        held = transport.api('OpenProcess', W.HANDLE, W.DWORD, W.BOOL, W.DWORD)(0x1FFFFF, False, policy_pid)
        member = W.BOOL()
        if not held or not transport.api('IsProcessInJob', W.BOOL, W.HANDLE, W.HANDLE, C.POINTER(W.BOOL))(
                held, job.handle, C.byref(member)) or not member.value or transport.wait(held, 0) != 258:
            raise AssertionError('refuse fault against unowned/exited policy child')
        suspend(); suspended = True
        before = host().count('policy-timeout-discard'); late = host().count('policy-late-discard')
        time.sleep(.1) # Give the completed entry an unseeded Cache age.
        server_miss(fault_key, step='suspended fault key')
        until(lambda: host().count('policy-timeout-discard') > before, 2, step='suspended HP2 timeout')
        suspend(True); suspended = False
        until(lambda: host().count('policy-late-discard') > late, 4, step='resumed HP2 late discard')
        if not transport.api('TerminateProcess', W.BOOL, W.HANDLE, W.UINT)(held, 17):
            raise AssertionError('owned policy kill failed')
        until(lambda: 'policy-retire pid=' + str(policy_pid) in host(), 2, step='post-kill policy retire'); server_miss(step='post-kill server miss')
        until(lambda: 'AFTER DOWN ' in tsf(), 15, step='AFTER DOWN'); snapshot('DOWN')
        configure_server(False); server_miss(step='post-disable server miss')
        request_novel_fallback(request, 'restart')
        until(lambda: 'AFTER RECOVER ' in tsf(), 70, step='AFTER RECOVER'); snapshot('RECOVER')
        server_miss(step='recovered seeded SOURCES hit')
        until(lambda: 'AFTER FINAL ' in tsf(), 10, step='AFTER FINAL'); snapshot('FINAL')
        process.wait(timeout=min(15, max(1, 265 - (time.monotonic() - started))))
        if process.returncode or not re.search(r'GUARD .*"leftovers": \[\]', text(gate_path)):
            raise AssertionError('harness/owned cleanup failed')
        report = check(tsf(), host(), samples, cache_fetches, time.monotonic() - started)
        (run / 'coverage.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
        print('PASS S4.2 policy coverage ' + json.dumps(report), flush=True)
    finally:
        (run / 'samples.json').write_text(json.dumps(samples, indent=2) + '\n', encoding='utf-8')
        (run / 'phase-markers.json').write_text(json.dumps(phase_markers, indent=2) + '\n', encoding='utf-8')
        if suspended:
            suspend(True)
        if held:
            transport.close(held)
        if process and process.poll() is None:
            try:
                request(b'SHUTDOWN'); process.wait(timeout=8)
            except Exception:
                pass
        job.close()
        if process:
            process.wait(timeout=5)
        stop.set(); server.join(2); listener.close()
        print('ARTIFACTS ' + str(run), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--self-test-hook', action='store_true')
    parser.add_argument('--runtime')
    parser.add_argument('--build-dir', default='build/w')
    parser.add_argument('--cold-load-sleep-sec', type=int, choices=[45], default=45)
    args = parser.parse_args()
    try:
        if args.self_test_hook:
            hook_self_test()
        elif args.self_test:
            self_test()
        elif not args.runtime:
            parser.error('--runtime required for stack run')
        else:
            main(args)
    except Exception as error:
        print('FAIL S4.2 policy coverage ' + str(error), flush=True)
        raise SystemExit(1)
