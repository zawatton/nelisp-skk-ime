"""Six process launch race + real host accept burst; private, one stack, <30s."""
import argparse
import os
from pathlib import Path
import subprocess
import uuid
ROOT = Path(__file__).resolve().parents[2]
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--build-dir', type=Path, default=ROOT / 'build/w')
    args = parser.parse_args()
    build = args.build_dir.resolve()
    assert build.is_relative_to(ROOT / 'build')
    out = build / 'host-startup-regression'
    out.mkdir(parents=True, exist_ok=True)
    (out / 'CMakeLists.txt').write_text(
        'cmake_minimum_required(VERSION 3.24)\nproject(host_startup_regression LANGUAGES CXX)\n'
        f'add_executable(host-startup-regression "{ROOT.as_posix()}/windows/test-host/host_startup_regression.cpp" '
        f'"{ROOT.as_posix()}/windows/src/engine_client.cpp" "{ROOT.as_posix()}/windows/src/engine_protocol.cpp")\n'
        f'target_include_directories(host-startup-regression PRIVATE "{ROOT.as_posix()}/windows/src")\n'
        'target_compile_features(host-startup-regression PRIVATE cxx_std_20)\n'
        'target_compile_definitions(host-startup-regression PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN)\n'
        'target_compile_options(host-startup-regression PRIVATE /utf-8)\n', encoding='utf-8')
    subprocess.run(['cmake', '-S', str(out), '-B', str(out / 'build'), '-G', 'Visual Studio 17 2022', '-A', 'x64'], check=True, timeout=60)
    subprocess.run(['cmake', '--build', str(out / 'build'), '--config', 'Release'], check=True, timeout=60)
    fixture = out / 'build/Release/host-startup-regression.exe'
    host = build / 'Release/ddskk-engine-host.exe'
    assert host.is_file()
    env = os.environ.copy()
    env.update(NATIVEIME_REGISTRY_KEY='Software\\NativeIME-test-' + uuid.uuid4().hex,
               LOCALAPPDATA=str(out), DDSKK_USER_JISYO=str(out / 'user-jisyo'),
               DDSKK_HOST_LOG=str(out / 'host.log'), DDSKK_SKKSERV_ENABLE='0',
               DDSKK_DICTIONARY_FILES='', NELISP_IME_ENGINE='ddskk')
    for option in ('SOURCES', 'CACHE', 'RESTART', 'PUBLICATION', 'LEARNING'):
        env['DDSKK_HOST_POLICY_' + option] = '0'
    guard = ROOT / 'windows/test-host/host-test-process-guard.py'
    for mode in ('--busy', '--run'):
        env['DDSKK_PIPE_NAME'] = r'\\.\pipe\eh8-startup-' + uuid.uuid4().hex
        command = ['python', '-B', str(guard), 'run', '--root', str(ROOT), '--cleanup', '--',
                   str(fixture), mode, str(host), str(ROOT)]
        subprocess.run(command, env=env, check=True, timeout=40)
    text = (out / 'host.log').read_text('utf-8')
    assert 'pipe-accept-failed' not in text and 'singleton-already-owned' not in text, text[-2000:]
    print('PASS host startup/accept log fatal_accepts=0 duplicate_hosts=0')
if __name__ == '__main__':
    main()
