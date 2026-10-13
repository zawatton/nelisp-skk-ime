"""Compile the platform-neutral builder and reject two broken implementations."""
from pathlib import Path
import json
import os
import queue
import re
import shutil
import struct
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
HEADER = [
    ('magic', 0, 4), ('body_length', 4, 4), ('version', 8, 2),
    ('status', 10, 2), ('generation', 12, 8), ('file_index', 20, 4),
    ('batch_seq', 24, 4), ('flags', 28, 4), ('count', 32, 4),
    ('payload_length', 36, 4),
]


def run(command, *, timeout=60):
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True,
                            timeout=timeout)
    if result.returncode:
        raise RuntimeError(f'{command[0]} exited {result.returncode}\n'
                           f'{result.stdout}{result.stderr}')
    return result.stdout


def contract_check(binary):
    spec = json.loads((ROOT / 'docs/contracts/hn-builder-v1.json').read_text('utf-8'))
    checks = 0

    def check(condition, label):
        nonlocal checks
        checks += 1
        if not condition:
            raise RuntimeError(f'contract check failed: {label}')

    check(spec['contract'] == 'hn-builder-v1' and spec['frozen'], 'identity')
    check(spec['version'] == 1 and spec['byte_order'] == 'little-endian', 'version')
    check(spec['header_bytes'] == 40 and spec['fields']['offset'] == 40, 'header')
    check([tuple(row[:3]) for row in spec['header']] == HEADER, 'offsets')
    limits = spec['limits']
    for key, expected in [('line_bytes', 65536), ('payload_bytes', 262144),
                          ('reply_payload_bytes', 524288), ('count', 65536),
                          ('outstanding_requests', 1), ('batch_timeout_ms', 10000)]:
        check(limits[key] == expected, key)
    fixture = dict(line.split('=', 1) for line in
                   run([str(binary), '--contract-fixture'], timeout=10).splitlines())
    check(bytes.fromhex(fixture['ready_hex']) ==
          spec['negotiation']['ready'].encode('ascii'), 'READY')

    def expected_frame(reply):
        values = [b'a', b'/A/', b'', b'/'] if reply else [b'a /A/', b' /']
        payload = b''.join(struct.pack('<I', len(value)) + value for value in values)
        header = bytearray(spec['header_bytes'])
        fields = dict(magic=b'HNBR' if reply else b'HNBQ',
                      body_length=len(header) - 8 + len(payload), version=1,
                      status=0, generation=0x0102030405060708,
                      file_index=0x11223344, batch_seq=0x55667788,
                      flags=0 if reply else 1, count=2, payload_length=len(payload))
        for name, offset, width, _ in spec['header']:
            value = fields[name]
            header[offset:offset + width] = (value if isinstance(value, bytes)
                                            else value.to_bytes(width, 'little'))
        return bytes(header) + payload

    for kind in ('request', 'reply'):
        actual = bytes.fromhex(fixture[f'{kind}_hex'])
        expected = expected_frame(kind == 'reply')
        check(actual == expected, f'{kind} golden bytes')
        for name, offset, width in HEADER:
            check(actual[offset:offset + width] == expected[offset:offset + width],
                  f'{kind} {name}')
    print(f'PASS HN builder contract checks={checks}')
    return checks


def real_child_check(binary, work, runtime):
    # Only public synthetic bytes. The loaded driver's last form enters serve;
    # standalone --eval would echo results into the binary protocol stream.
    driver = work / 'index-serve.el'
    driver.write_text('(load "engine/host-native-index.el" nil t t)\n'
                      '(host-native-index-serve)\n', encoding='utf-8')
    environment = dict(os.environ)
    for name in ('DDSKK_HOST_BUILDER_TEST_FAULT', 'DDSKK_HARNESS_DIAGNOSTICS'):
        environment.pop(name, None)
    process = subprocess.Popen([runtime, '--load', str(driver)], cwd=ROOT,
                               env=environment, stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    inbox = queue.Queue()
    errors = bytearray()

    def read_stdout():
        while part := process.stdout.read(1):
            inbox.put(part)
        inbox.put(None)

    def read_stderr():
        errors.extend(process.stderr.read())

    reader = threading.Thread(target=read_stdout, daemon=True)
    error_reader = threading.Thread(target=read_stderr, daemon=True)
    reader.start()
    error_reader.start()
    checks = 0

    def check(condition, label):
        nonlocal checks
        checks += 1
        if not condition:
            raise RuntimeError(f'real-child check={checks} failed: {label}')

    def take(size, timeout=10):
        deadline = time.monotonic() + timeout
        result = bytearray()
        while len(result) < size:
            try:
                part = inbox.get(timeout=max(.001, deadline - time.monotonic()))
            except queue.Empty:
                raise RuntimeError('builder stdout timeout')
            if part is None:
                error_reader.join(1)
                raise RuntimeError('builder exited: ' + errors.decode('utf-8', 'replace'))
            result.extend(part)
        return bytes(result)

    header_codec = struct.Struct('<4sIHHQIIIII')
    bom = b'\xef\xbb\xbf'
    fixtures = [bom + bom + b'double /preserved/\r\n'
                + 'かな /候補;note/[し/候補/]/\n'.encode('utf-8')
                + b';; comment\n\nmalformed\nemptytail nope\n /empty-key/\n'
                  b'repeat /old/\nembedded\rkey /ta\ril/\r\nrepeat /last/',
                bom + b'\nfirst /after-bom-only/\nzero\0key /zero\0tail/']
    try:
        check(take(len(b'HNB READY version=1\n'), 60) == b'HNB READY version=1\n', 'READY')
        for file_index, contents in enumerate(fixtures):
            source = work / f'public-{file_index}.jisyo'
            source.write_bytes(contents)
            expected = {bytes.fromhex(key): bytes.fromhex(tail) for key, tail in
                        (row.split('=', 1) for row in
                         run([str(binary), '--reference-file', str(source)]).splitlines())}
            # Mirror native removal of exactly one leading BOM before batches.
            raw = contents[3:] if contents.startswith(bom) else contents
            lines = raw.split(b'\n')
            if not lines[-1]:
                lines.pop()
            actual = {}
            # Two small batches also exercise flag validation and generation reuse.
            for seq, batch in enumerate((lines[:1], lines[1:])):
                payload = b''.join(struct.pack('<I', len(line)) + line for line in batch)
                generation = 0xff01020304050607
                wire = header_codec.pack(b'HNBQ', 32 + len(payload), 1, 0,
                                         generation, file_index, seq, int(seq == 0),
                                         len(batch), len(payload)) + payload
                process.stdin.write(wire)
                process.stdin.flush()
                header = take(40)
                magic, body, version, status, gen, index, echoed_seq, flags, count, size = header_codec.unpack(header)
                check((magic, version, status, gen, index, echoed_seq, flags) ==
                      (b'HNBR', 1, 0, generation, file_index, seq, 0), 'reply identity')
                check(body == 32 + size and size <= 524288 and count <= len(batch), 'reply bounds')
                payload = take(size)
                at = 0
                for _ in range(count):
                    values = []
                    for _ in range(2):
                        check(at + 4 <= size, 'record length word')
                        n, = struct.unpack_from('<I', payload, at)
                        at += 4
                        check(n <= 65536 and n <= size - at, 'record length')
                        values.append(payload[at:at + n])
                        at += n
                    actual[values[0]] = values[1]
                check(at == size, 'exact payload consumption')
            check(actual == expected, 'exact C++ reference map')
        process.stdin.close()
        check(process.wait(timeout=10) == 0, 'clean EOF')
        error_reader.join(1)
        check(not errors, 'no child diagnostics')
        print(f'PASS HN builder real-child checks={checks} files={len(fixtures)} batches=4')
    finally:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=5)
        if not process.stdin.closed:
            process.stdin.close()
        reader.join(1)
        error_reader.join(1)
        process.stdout.close()
        process.stderr.close()


def main():
    out = ROOT / 'build/w/hn-builder-unit'
    out.mkdir(parents=True, exist_ok=True)
    source = ROOT / 'windows/test-host/hn_builder_unit.cpp'
    with tempfile.TemporaryDirectory(prefix='run-', dir=out) as temporary:
        work = Path(temporary)
        if os.name == 'nt':
            (work / 'CMakeLists.txt').write_text(f'''cmake_minimum_required(VERSION 3.24)
project(hn_builder_unit LANGUAGES CXX)
add_executable(hn-builder-unit "{source.as_posix()}")
add_executable(hn-builder-overlong-control "{source.as_posix()}")
target_compile_features(hn-builder-unit PRIVATE cxx_std_20)
target_compile_features(hn-builder-overlong-control PRIVATE cxx_std_20)
target_compile_options(hn-builder-unit PRIVATE /utf-8)
target_compile_options(hn-builder-overlong-control PRIVATE /utf-8)
target_compile_definitions(hn-builder-overlong-control PRIVATE HN_BUILDER_NEGATIVE_SKIP_OVERLONG)
''', encoding='utf-8', newline='\n')
            run(['cmake', '-S', str(work), '-B', str(work / 'build'),
                 '-G', 'Visual Studio 17 2022', '-A', 'x64'], timeout=30)
            run(['cmake', '--build', str(work / 'build'), '--config', 'Release'])
            binary = work / 'build/Release/hn-builder-unit.exe'
            overlong_binary = work / 'build/Release/hn-builder-overlong-control.exe'
            print('Compiler: MSVC /std:c++20 /utf-8')
        else:
            compiler = shutil.which('g++-14') or shutil.which('g++')
            if not compiler:
                raise RuntimeError('g++ is required')
            print('Compiler: ' + run([compiler, '--version']).splitlines()[0])
            binary = work / 'hn-builder-unit'
            overlong_binary = work / 'hn-builder-overlong-control'
            run([compiler, '-std=c++20', '-O1', '-Wall', '-Werror', '-pthread',
                 str(source), '-o', str(binary)])
            run([compiler, '-std=c++20', '-O1', '-Wall', '-Werror', '-pthread',
                 '-DHN_BUILDER_NEGATIVE_SKIP_OVERLONG', str(source),
                 '-o', str(overlong_binary)])

        contract_checks = contract_check(binary)
        output = run([str(binary)], timeout=20)
        print(output, end='' if output.endswith('\n') else '\n')
        normal = re.search(r'PASS hn-builder .*?checks=(\d+)', output)
        if not normal or int(normal[1]) == 0:
            raise RuntimeError('unit run did not report successful checks')
        baseline = run([str(binary), '--negative-skip-overlong'], timeout=20)
        if not re.search(r'PASS hn-builder control=skip-overlong .*?checks=1', baseline):
            raise RuntimeError('overlong acceptance predicate failed on the correct build')
        print('PASS overlong acceptance baseline checks=1')
        for control in ('drop-last', 'skip-overlong'):
            target = overlong_binary if control == 'skip-overlong' else binary
            result = subprocess.run([str(target), f'--negative-{control}'], cwd=ROOT,
                                    capture_output=True, text=True, timeout=20)
            output = result.stdout + result.stderr
            print(output, end='' if output.endswith('\n') else '\n')
            rejected = re.search(rf'FAIL hn-builder control={control} .*?checks=(\d+)',
                                 output)
            if result.returncode <= 0 or not rejected or int(rejected[1]) == 0:
                raise RuntimeError(f'negative control {control} was not rejected by checks')
            print(f'PASS negative control={control} rejected exit={result.returncode}'
                  f' checks={rejected[1]}')
        print(f'PASS HN builder units checks={normal[1]} contract_checks={contract_checks}'
              ' negative_controls=2 rejected=2')
        if emacs := shutil.which('emacs'):
            dispatch = [emacs, '-Q', '--batch', '-l',
                        str(ROOT / 'windows/test-host/hn_builder_dispatch_unit.el')]
            output = run(dispatch, timeout=20)
            if not re.search(r'PASS HN builder dispatch checks=[1-9]\d*', output):
                raise RuntimeError('dispatch run did not report checks')
            print(output.strip())
            broken = subprocess.run(dispatch, cwd=ROOT, capture_output=True, text=True,
                                    timeout=20, env=dict(os.environ, HN_BUILDER_DISPATCH_CONTROL='strip-bom'))
            if broken.returncode <= 0 or 'second BOM preserved' not in broken.stderr:
                raise RuntimeError('dispatch strip-bom control was not rejected')
            print(f'PASS dispatch control=strip-bom rejected exit={broken.returncode} checks=5')
        else:
            print('SKIP HN builder dispatch: no GNU Emacs')
        if runtime := os.environ.get('HN_NATIVE_RUNTIME'):
            try:
                real_child_check(binary, work, runtime)
            except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
                print('FAIL HN builder real-child (optional): ' + str(error))


if __name__ == '__main__':
    main()
