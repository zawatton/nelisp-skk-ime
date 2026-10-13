"""Build and exercise actual private hook owners without a host/child/Emacs."""
import importlib.util
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('gate', Path(__file__).with_name('test-hn-e2e-oracle.py'))
gate = importlib.util.module_from_spec(spec); spec.loader.exec_module(gate)

def main():
    out = ROOT / 'build/w/hn-oracle-replay-unit'
    out.mkdir(parents=True, exist_ok=True)
    (out / 'CMakeLists.txt').write_text(f'''cmake_minimum_required(VERSION 3.24)
project(hn_replay_unit LANGUAGES CXX)
add_executable(hn-replay-unit "{(ROOT / 'windows/test-host/hn_oracle_replay_unit.cpp').as_posix()}" "{(ROOT / 'windows/src/local_index.cpp').as_posix()}" "{(ROOT / 'windows/src/engine_protocol.cpp').as_posix()}")
target_compile_features(hn-replay-unit PRIVATE cxx_std_20)
target_compile_definitions(hn-replay-unit PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
target_compile_options(hn-replay-unit PRIVATE /utf-8)
target_link_libraries(hn-replay-unit PRIVATE ws2_32 advapi32 bcrypt)
''', encoding='utf-8', newline='\n')
    subprocess.run(['cmake', '-S', str(out), '-B', str(out / 'build'), '-G', 'Visual Studio 17 2022', '-A', 'x64'], check=True, timeout=30)
    subprocess.run(['cmake', '--build', str(out / 'build'), '--config', 'Release'], check=True, timeout=60)
    exe = str(out / 'build/Release/hn-replay-unit.exe')
    for diagnostics, key, switch, expected in (
            (None, 'Software\\NativeIME-test-unit', '1', '0'),
            ('1', 'Software\\NativeIME-test-unit', None, '0'),
            ('0', 'Software\\NativeIME-test-unit', '1', '0'),
            ('1', 'Software\\NativeIME', '1', '0'),
            ('1', 'Software\\NativeIME-test-unit', '0', '0'),
            ('1', 'Software\\NativeIME-test-unit', '10', '0'),
            ('1', 'Software\\NativeIME-test-unit', '1', '1')):
        env = dict(os.environ, NATIVEIME_REGISTRY_KEY=key)
        for name, value in [('DDSKK_HARNESS_DIAGNOSTICS', diagnostics), ('DDSKK_HOST_POLICY_TEST_HP2_ONLY', switch)]:
            if value is None:
                env.pop(name, None)
            else:
                env[name] = value
        subprocess.run([exe, '--old-only', expected], env=env, check=True, timeout=10)
    rows = gate.frozen(); replay = gate.replay_rows(rows)
    sources = []
    for i, row in enumerate(replay):
        path = out / f'{i:04d}.request'; path.write_bytes(gate.replay_input(row))
        Path(str(path) + '.reply').unlink(missing_ok=True)
        sources.append(path)
    malformed = out / 'malformed.request'; malformed.write_bytes(b'\xff\xff\xff\xff')
    extra = [gate.FIXTURE / 'SKK-JISYO.synthetic', malformed, sources[0]]
    wire = b''.join(str(path).encode('utf-8').hex().encode() + b'\n' for path in sources + extra)
    env = dict(os.environ); env.pop('HN_IME_RUNTIME', None)
    result = subprocess.run([str(out / 'build/Release/hn-replay-unit.exe'), str(out), str(gate.FIXTURE / 'SKK-JISYO.synthetic')],
                            input=wire, capture_output=True, env=env, timeout=20)
    diagnostics = result.stderr.decode('utf-8', 'replace')
    print(diagnostics, end='')
    result.check_returncode()
    gate.require('PASS owner selection operations=5 modes=off/elisp/shadow' in diagnostics,
                 'missing owner selection coverage')
    log = (out / 'owner-selection.log').read_text('utf-8')
    for reason in ('admission-bounds', 'hn3-not-negotiated', 'shadow-mode'):
        gate.require('reason=' + reason in log, 'missing fallback reason ' + reason)
    gate.require('step=caller-fence' in log, 'missing stale reply evidence')
    replies = result.stdout.splitlines(); gate.require(len(replies) == len(replay) + 3, 'reply count')
    gate.require(replies[-3:] == [b'ERR HN ORACLE PATH', b'ERR HN ORACLE INPUT', b'ERR HN ORACLE EXISTS'], 'path/framing/overwrite controls')
    replies = replies[:-3]
    for row, path, reply in zip(replay, sources, replies):
        gate.exact(reply, b'OK HN ORACLE cpp', row['case'] + ' dispatch')
        gate.check_replay(row, Path(str(path) + '.reply').read_bytes(), rows)
    print(f'PASS production C++ hook corpus cases={len(replay)} path_controls=3 stacks=0 emacs=0')

if __name__ == '__main__':
    main()
