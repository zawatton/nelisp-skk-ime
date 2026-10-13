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


def check_registration_gate(out):
    # Load only the evidence validator, never execute the stack harness.
    script = out / 'registration-evidence-unit.ps1'
    script.write_text(r'''param([string]$Source)
$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($Source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Harness parse errors: $errors" }
$functions = @($ast.FindAll({ param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
  $node.Name -eq 'AssertWordProviderEvidence'
}, $true))
if ($functions.Count -ne 1) { throw 'Missing unique evidence validator' }
Invoke-Expression $functions[0].Extent.Text
$applied = "PROVIDER_SETTINGS engine=ddskk applied=1`n"
$learning = "REGISTRATION_LEARNING queued=1 pending=1`n"
$retained = "PROVIDER_SETTINGS pending=1 conversion_retained=1`n"
$resumed = "PROVIDER_SETTINGS conversion_resumed=1`n"
AssertWordProviderEvidence ($applied + $retained + $resumed + $learning * 3) 'valid-depth3' 3 $true
AssertWordProviderEvidence ($applied + $retained + "LOCAL_FALLBACK resolved=candidate pending=0`n" + $learning) 'valid-fallback' 1 $true
AssertWordProviderEvidence $applied 'valid-provider-learning' 1 $false
$broken = @(
  @{name='never-applied'; text=$retained + 'AFTER END BUF=[てすと] SEL=0 COMP=-'; expected=3},
  @{name='missing-learning'; text=$applied + $retained + $resumed; expected=3},
  @{name='wrong-count'; text=$applied + $learning; expected=3},
  @{name='never-resumed'; text=$applied + $learning + $retained; expected=1},
  @{name='retained-again'; text=$applied + $retained + $resumed + $learning + $retained; expected=1},
  @{name='queued-prefix'; text=$applied + "REGISTRATION_LEARNING queued=10`n"; expected=1}
)
foreach ($case in $broken) {
  $rejected = $false
  try { AssertWordProviderEvidence $case.text $case.name $case.expected $true }
  catch { $rejected = $true }
  if (-not $rejected) { throw "Broken evidence accepted: $($case.name)" }
}
Write-Output "PASS registration evidence valid=3 rejected=$($broken.Count) stacks=0"
''', encoding='utf-8')
    subprocess.run(['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                    '-File', str(script), '-Source',
                    str(ROOT / 'windows/test-host/test-registration-nested.ps1')],
                   check=True, timeout=30)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--build-dir', type=Path, default=ROOT / 'build/w/provider-settings-unit')
    parser.add_argument('--source', type=Path, default=ROOT / 'windows/src/text_service.cpp')
    parser.add_argument('--negative-control', choices=('callback-io', 'stale-handle', 'stale-settings', 'pending-conversion', 'irrelevant-write', 'worker-storm', 'registration-entry', 'nested-learning', 'short-worker-budget'))
    args = parser.parse_args()
    out = args.build_dir.resolve()
    assert out.is_relative_to(ROOT / 'build'), 'private build directory required'
    out.mkdir(parents=True, exist_ok=True)
    check_registration_gate(out)
    source = args.source.read_text('utf-8')
    follow = method(source, 'FollowSettings')
    load = method(source, 'LoadSettings')
    for body in (follow, load):
        assert 'engine_.' not in body and 'provider_engine_mutex_' not in body, 'callback does engine work/waits'
    assert 'QueueProviderSettings(engine_id_)' in load
    assert 'engine_.Connect' not in method(source.replace('HRESULT TextService::OnTestKeyDown', 'bool TextService::OnTestKeyDown'), 'OnTestKeyDown')
    bodies = [follow, method(source, 'QueueProviderSettings'), method(source, 'ApplyProviderSettings'), method(source, 'WaitForProviderSettings'), method(source, 'TryLocalConversionFallback'), method(source, 'StartProviderSettingsWorker'), method(source, 'RetainProviderConversion')]
    assert 'engine_.' not in bodies[4], 'native fallback does callback engine work'
    bodies += [method(source, 'ProviderConversionSettingsPending'), method(source, 'ObserveRegistrationLearning')]
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
    elif args.negative_control == 'short-worker-budget':
        assert bodies[5].count('ApplyProviderSettings(1000)') == 1
        bodies[5] = bodies[5].replace('ApplyProviderSettings(1000)', 'ApplyProviderSettings(25)')
    elif args.negative_control == 'registration-entry':
        bodies[7] = bodies[7].replace('return !settings_ready || provider_unavailable;', 'return true; // Old empty-reply classification.')
    elif args.negative_control == 'nested-learning':
        bodies[8] = bodies[8].replace('if (learning && local_enabled_)', 'if (learning && local_enabled_ && state.mode != L"registration")')
    conversion = method(source, 'BeginProviderConversion')
    assert 'settings_ready = ApplyProviderSettings(25)' in conversion and 'engine_.ConvertKeys(keys, remaining)' in conversion
    assert 'ProviderConversionSettingsPending(settings_ready, provider_unavailable)' in conversion
    assert 'registration || local_enabled_ ? kModeReplayTimeoutMs' in conversion
    assert 'engine_.RegisterLocal(keys, kModeReplayTimeoutMs)' in conversion
    assert 'RetainProviderConversion()' in source
    assert conversion.index('TryLocalConversionFallback()') < conversion.index('std::thread(')
    start = conversion.index('      std::optional<ddskk::EngineState> state;')
    end = conversion.index('      TracePhase(L"engine-lookup-end"', start)
    # Execute the production worker transaction block against the fake engine,
    # including selection failure, empty conversion and registration retry.
    bodies.append('std::pair<std::optional<ddskk::EngineState>, bool> TextService::RunConversion(bool registration, size_t skip) {\n'
                  '  const std::string keys = "Kana";\n' + conversion[start:end] +
                  '  return {state, ProviderConversionSettingsPending(settings_ready, provider_unavailable)};\n}')
    # Execute the real retention timer branch, including its readiness gate.
    timer_start = source.index('    if (!service->provider_conversion_retry_')
    timer_end = source.index('\n  }\n  if (message == WM_TIMER && wparam == 5', timer_start)
    bodies.append('int TextService::RunRetentionTimer() {\n'
                  '  auto* service = this; auto* window = provider_window_;\n' +
                  source[timer_start:timer_end] + '\n}')
    client = (ROOT / 'windows/src/engine_client.cpp').read_text('utf-8')
    completion = re.search(r'(?ms)^std::optional<EngineState> EngineClient::RegistrationLearning\([^)]*\) \{.*?^\}', client)
    assert completion, 'missing completion decoder'
    bodies.append('namespace ddskk {\n' + completion[0] + '\n}')
    (out / 'provider_settings.inc').write_text('\n'.join(bodies), encoding='utf-8')
    (out / 'CMakeLists.txt').write_text(
        'cmake_minimum_required(VERSION 3.24)\nproject(provider_settings_unit LANGUAGES CXX)\n'
        f'add_executable(provider-settings-unit "{(ROOT / "windows/test-host/provider_settings_unit.cpp").as_posix()}" "{(ROOT / "windows/src/engine_protocol.cpp").as_posix()}")\n'
        'target_compile_features(provider-settings-unit PRIVATE cxx_std_20)\n'
        'target_compile_options(provider-settings-unit PRIVATE /utf-8)\n'
        f'target_include_directories(provider-settings-unit PRIVATE "{out.as_posix()}" "{(ROOT / "windows/src").as_posix()}")\n'
        f'add_executable(provider-pipe-unit "{(ROOT / "windows/test-host/provider_settings_unit.cpp").as_posix()}" "{(ROOT / "windows/src/engine_client.cpp").as_posix()}" "{(ROOT / "windows/src/engine_protocol.cpp").as_posix()}")\n'
        'target_compile_features(provider-pipe-unit PRIVATE cxx_std_20)\n'
        'target_compile_options(provider-pipe-unit PRIVATE /utf-8)\n'
        'target_compile_definitions(provider-pipe-unit PRIVATE PROVIDER_PIPE_UNIT UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)\n'
        f'target_include_directories(provider-pipe-unit PRIVATE "{(ROOT / "windows/src").as_posix()}")\n', encoding='utf-8')
    subprocess.run(['cmake', '-S', str(out), '-B', str(out / 'build'), '-G', 'Visual Studio 17 2022', '-A', 'x64'], check=True, timeout=60)
    subprocess.run(['cmake', '--build', str(out / 'build'), '--config', 'Release'], check=True, timeout=60)
    executable = out / 'build/Release/provider-settings-unit.exe'
    result = subprocess.run([str(executable)], timeout=10)
    if args.negative_control:
        assert result.returncode != 0, 'broken settings implementation was accepted'
        print(f'PASS settings negative control rejected={args.negative_control} stacks=0')
        return
    result.check_returncode()
    subprocess.run([str(out / 'build/Release/provider-pipe-unit.exe')], check=True, timeout=10)
    print('PASS production settings callback audit methods=9 callback_engine_calls=0 provider_mutex_waits=0 conversion_budget=1500 registration_budget=5000')


if __name__ == '__main__':
    main()
