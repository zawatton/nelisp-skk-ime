"""Execute extracted production transitions with the real native frontend."""
from pathlib import Path
import subprocess
import re
ROOT=Path(__file__).resolve().parents[2]
def method(source,name):
    m=re.search(r'(?ms)^(?:void|bool) TextService::'+name+r'\([^)]*\) \{.*?^\}',source)
    assert m,name
    return m[0]
def main():
    source=(ROOT/'windows/src/text_service.cpp').read_text('utf-8')
    start=source.index('  if (!result->state) {', source.index('  if (!result->apply_state) {',source.index('void TextService::ApplyProviderResult')))
    stop=source.index('  provider_conversion_active_ = false;',start)
    guard_start=source.index('  if (result == nullptr ||',source.index('void TextService::ApplyProviderResult'))
    guard_stop=source.index('  if (result->preview_only)',guard_start)
    empty='void TextService::ApplyEmpty(ProviderResult* result) {\n'+source[guard_start:guard_stop]+'  provider_pending_.store(false);\n'+source[start:stop]+'\n}'
    queue_start=source.index('  if ((provider_pending_.load(std::memory_order_acquire) &&')
    queue_stop=source.index(' {',queue_start)
    queue='bool TextService::WouldQueueProviderKey() { return '+source[queue_start:queue_stop].strip()[3:]+'; }'
    names=['FollowSettings','ScheduleConfirmationReplay']
    fixed='void TextService::ReleaseFailedConfirmation()' in source
    if fixed: names+=['ReleaseFailedConfirmation','SettleIdleProviderState','CommitNativeKatakana','ConfirmationFinished']
    if fixed:
        for name in ['SettleIdleProviderState','ReleaseFailedConfirmation','CommitNativeKatakana','RefreshDebugSettings']:
            body=method(source,name)
            assert not any(call in body for call in ['WriteFile(', 'ReadFile(', 'WaitNamedPipeW(', 'CreateFileW(', 'GetOverlappedResult(', 'EnsureEngineHost(']), name
    # Keep synchronous diagnostic log storage outside the timed key callback.
    exit_body=source[source.index('  const auto debug_exit = [&](BOOL'):source.index('  /* Some hosts')]
    assert 'fflush(' not in exit_body
    apply_body=source[source.index('    std::printf("ENGINE_APPLY'):source.index('  const bool registration_target',source.index('    std::printf("ENGINE_APPLY'))]
    assert 'fflush(' not in apply_body
    fixture=(ROOT/'windows/test-host/test-post-swap-callbacks.ps1').read_text('utf-8')
    assert 'SETTLE30000:BEFORE WAITACK30000:1 KILLCHILD' in fixture
    assert 'SETTLE30000:SWAP WAITACK30000:2 ENGINE:lattice' in fixture
    assert '.Maximum -gt 20000' in fixture
    out=ROOT/'build/w/idle-input-unit';out.mkdir(parents=True,exist_ok=True)
    (out/'idle_input.inc').write_text('\n'.join([method(source,n) for n in names]+[empty,queue]),encoding='utf-8',newline='\n')
    (out/'CMakeLists.txt').write_text('cmake_minimum_required(VERSION 3.24)\nproject(idle_input LANGUAGES CXX)\n'
        f'add_executable(idle-input-unit "{ROOT.as_posix()}/windows/test-host/idle_input_unit.cpp" "{ROOT.as_posix()}/windows/src/realtime_frontend.cpp")\n'
        f'target_include_directories(idle-input-unit PRIVATE "{ROOT.as_posix()}/windows/src" "{out.as_posix()}")\n'
        'target_compile_features(idle-input-unit PRIVATE cxx_std_20)\ntarget_compile_options(idle-input-unit PRIVATE /utf-8)\n'
        + ('target_compile_definitions(idle-input-unit PRIVATE FIXED_IDLE_INPUT)\n' if fixed else ''),encoding='utf-8',newline='\n')
    subprocess.run(['cmake','-S',str(out),'-B',str(out/'build'),'-G','Visual Studio 17 2022','-A','x64'],check=True,timeout=60)
    subprocess.run(['cmake','--build',str(out/'build'),'--config','Release'],check=True,timeout=60)
    subprocess.run([str(out/'build/Release/idle-input-unit.exe')],check=True,timeout=10)
if __name__=='__main__': main()
