"""Extract and execute production settings methods; no copied implementation."""
import argparse
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def method(source, name):
    found = re.search(r'(?ms)^(?:void|bool) TextService::' + name + r'\([^)]*\) \{.*?^\}', source)
    assert found, f'missing production method {name}'
    return found[0]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--build-dir', type=Path, default=ROOT / 'build/w/provider-settings-unit')
    parser.add_argument('--source', type=Path, default=ROOT / 'windows/src/text_service.cpp')
    parser.add_argument('--negative-control', choices=('callback-io', 'stale-handle', 'stale-settings', 'pending-conversion', 'irrelevant-write', 'worker-storm'))
    args = parser.parse_args()
    out = args.build_dir.resolve()
    assert out.is_relative_to(ROOT / 'build'), 'private build directory required'
    out.mkdir(parents=True, exist_ok=True)
    source = args.source.read_text('utf-8')
    follow = method(source, 'FollowSettings')
    load = method(source, 'LoadSettings')
    for body in (follow, load):
        assert 'engine_.' not in body and 'provider_engine_mutex_' not in body, 'callback does engine work/waits'
    assert 'QueueProviderSettings(engine_id_)' in load
    assert 'engine_.Connect' not in method(source.replace('HRESULT TextService::OnTestKeyDown', 'bool TextService::OnTestKeyDown'), 'OnTestKeyDown')
    bodies = [follow, method(source, 'QueueProviderSettings'), method(source, 'ApplyProviderSettings'), method(source, 'WaitForProviderSettings'), method(source, 'TryLocalConversionFallback'), method(source, 'StartProviderSettingsWorker'), method(source, 'RetainProviderConversion')]
    assert 'engine_.' not in bodies[4], 'native fallback does callback engine work'
    if args.negative_control == 'callback-io':
        bodies[0] = bodies[0].replace('  LoadSettings();', '  engine_.Connect();\n  LoadSettings();')
    elif args.negative_control == 'stale-handle':
        bodies[2] = bodies[2].replace('engine_.Disconnect();', '// Broken control: retain stale connection.')
    elif args.negative_control == 'stale-settings':
        bodies[2] = bodies[2].replace('if (desired == provider_settings_.load()) return true;', 'return true;')
    elif args.negative_control == 'pending-conversion':
        bodies[3] = 'bool TextService::WaitForProviderSettings(ULONGLONG) { return ApplyProviderSettings(); }'
    elif args.negative_control == 'irrelevant-write':
        bodies[1] = bodies[1].replace('if (previous && *previous == settings) return;', '')
    elif args.negative_control == 'worker-storm':
        bodies[5] = bodies[5].replace('if (provider_settings_worker_.exchange(true)) return;', '')
    conversion = method(source, 'BeginProviderConversion')
    assert 'settings_ready = ApplyProviderSettings(25)' in conversion and 'engine_.ConvertKeys(keys, remaining)' in conversion
    assert '(!state && !registration)' in conversion
    assert 'RetainProviderConversion()' in source
    assert conversion.index('TryLocalConversionFallback()') < conversion.index('std::thread(')
    (out / 'provider_settings.inc').write_text('\n'.join(bodies), encoding='utf-8')
    (out / 'CMakeLists.txt').write_text(
        'cmake_minimum_required(VERSION 3.24)\nproject(provider_settings_unit LANGUAGES CXX)\n'
        f'add_executable(provider-settings-unit "{(ROOT / "windows/test-host/provider_settings_unit.cpp").as_posix()}")\n'
        'target_compile_features(provider-settings-unit PRIVATE cxx_std_20)\n'
        'target_compile_options(provider-settings-unit PRIVATE /utf-8)\n'
        f'target_include_directories(provider-settings-unit PRIVATE "{out.as_posix()}")\n', encoding='utf-8')
    subprocess.run(['cmake', '-S', str(out), '-B', str(out / 'build'), '-G', 'Visual Studio 17 2022', '-A', 'x64'], check=True, timeout=60)
    subprocess.run(['cmake', '--build', str(out / 'build'), '--config', 'Release'], check=True, timeout=60)
    executable = out / 'build/Release/provider-settings-unit.exe'
    result = subprocess.run([str(executable)], timeout=10)
    if args.negative_control:
        assert result.returncode != 0, 'broken settings implementation was accepted'
        print(f'PASS settings negative control rejected={args.negative_control} stacks=0')
        return
    result.check_returncode()
    print('PASS production settings callback audit methods=7 callback_engine_calls=0 provider_mutex_waits=0 conversion_budget=1500')


if __name__ == '__main__':
    main()
