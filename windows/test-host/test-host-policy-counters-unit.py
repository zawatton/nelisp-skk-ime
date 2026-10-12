"""Build a focused production counter test; no host/child/registry is started."""
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
CPP = r'''#define wmain host_program_main
#include "HOST_MAIN"
#undef wmain
namespace { namespace native_adapter {
struct ShadowPolicyTest {
  static int Run(bool expected_on, bool broken) {
    int checks = 0, failures = 0;
    auto check = [&](bool value) { ++checks; if (!value) ++failures; };
    check(PolicyCounters::Enabled() == expected_on);
    shadow.enabled_ = true;
    shadow.switches_.fill(true);
    shadow.healthy_ = true;
    const PolicyKind kinds[] = {PolicyKind::Sources, PolicyKind::CacheTtl,
        PolicyKind::Restart, PolicyKind::Intent, PolicyKind::Learning};
    for (size_t group = 0; group < 5; ++group) {
      const auto kind = kinds[group];
      Observation v{kind, engine_epoch.load(), publication_generation.load(), 1, 1, 1, 0};
      // The native expression is evaluated before passing the eager value,
      // even when an intentionally different seeded NeLisp result is selected.
      auto eager = [&] { if (!broken) NativeEvaluation(kind); return uint64_t{0}; };
      auto decide = [&] { return native_adapter::Decide(kind, 1, 1, 1, eager()); };
      check(decide() == 0); // cold miss
      shadow.Remember(v, 1);
      check(decide() == 1); // authority control: actually selected memo answer
      shadow.decisions_[ShadowPolicy::Key(v)].at = GetTickCount64() - 30001;
      check(decide() == 0); // expiry
      shadow.Remember(v, 1);
      shadow.Invalidate();
      check(decide() == 0); // child retirement
      shadow.healthy_ = true;
      shadow.switches_[group] = false;
      check(decide() == 0); // switch off
      shadow.switches_[group] = true;
      check(PolicyCounters::native[group] == (expected_on ? 5 : 0));
      check(PolicyCounters::nelisp[group] == (expected_on ? 1 : 0));
    }
    // Run an actual production caller, proving native evaluations include
    // learning's eager ready decision on both fallback and memo-hit paths.
    Observation learning{PolicyKind::Learning, engine_epoch.load(), publication_generation.load(), 1, 1, 0, 1};
    shadow.Remember(learning, 0);
    check(!LearningSchedule(true, false));
    check(PolicyCounters::native[4] == (expected_on ? 6 : 0));
    check(PolicyCounters::nelisp[4] == (expected_on ? 2 : 0));
    // Config has no five-group counter; observation/seed work isn't evaluation.
    NativeEvaluation(PolicyKind::Config);
    shadow.Seed(engine_epoch.load());
    check(PolicyCounters::native[0] == (expected_on ? 5 : 0));
    PolicyCounters::Log();
    std::printf("policy counters: enabled=%d checks=%d failures=%d\n", expected_on, checks, failures);
    return failures ? 1 : 0;
  }
};
} }
int main(int argc, char** argv) {
  if (argc < 3) return 2;
  g_log_path = std::filesystem::path(argv[1]).wstring();
  return native_adapter::ShadowPolicyTest::Run(std::string(argv[2]) == "1", argc > 3);
}
'''


def main():
    out = ROOT / "build/w/policy-counters-unit"
    out.mkdir(parents=True, exist_ok=True)
    source = (ROOT / "windows/host/main.cpp").read_text("utf-8")
    # Fail closed if any counted production algorithm site disappears.
    for kind, count in dict(Sources=1, Order=1, Cache=1, CacheTtl=1, Capacity=1,
                            Restart=2, Replacement=1, Intent=1, Payload=1, Learning=1).items():
        marker = f"native_adapter::NativeEvaluation(native_adapter::PolicyKind::{kind});"
        if source.count(marker) != count:
            raise RuntimeError(f"missing/duplicate evaluation site {kind}")
    (out / "unit.cpp").write_text(CPP.replace("HOST_MAIN", (ROOT / "windows/host/main.cpp").as_posix()),
                                  encoding="utf-8", newline="\n")
    (out / "CMakeLists.txt").write_text(
        'cmake_minimum_required(VERSION 3.24)\nproject(policy_counters_unit LANGUAGES CXX)\n'
        'add_executable(policy-counters-unit unit.cpp '
        f'"{(ROOT / "windows/src/local_index.cpp").as_posix()}" '
        f'"{(ROOT / "windows/src/engine_protocol.cpp").as_posix()}")\n'
        'target_compile_features(policy-counters-unit PRIVATE cxx_std_20)\n'
        'target_compile_definitions(policy-counters-unit PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)\n'
        'target_compile_options(policy-counters-unit PRIVATE /utf-8)\n'
        'target_link_libraries(policy-counters-unit PRIVATE ws2_32 advapi32 bcrypt)\n',
        encoding="utf-8", newline="\n")
    subprocess.run(['cmake', '-S', str(out), '-B', str(out / 'build'), '-G',
                    'Visual Studio 17 2022', '-A', 'x64'], check=True, timeout=60)
    subprocess.run(['cmake', '--build', str(out / 'build'), '--config', 'Release'], check=True, timeout=60)
    executable = out / 'build/Release/policy-counters-unit.exe'
    for enabled in ('unset', '0', '1'):
        log = out / f'counters-{enabled}.log'
        log.unlink(missing_ok=True)
        env = dict(os.environ)
        if enabled == 'unset':
            env.pop('DDSKK_HOST_POLICY_COUNTERS', None)
        else:
            env['DDSKK_HOST_POLICY_COUNTERS'] = enabled
        subprocess.run([str(executable), str(log), '1' if enabled == '1' else '0'], env=env, check=True, timeout=10)
        text = log.read_text('utf-8') if log.exists() else ''
        if enabled != '1':
            assert not text, 'default emitted counter diagnostics'
        else:
            for group in ('SOURCES', 'CACHE', 'RESTART', 'PUBLICATION', 'LEARNING'):
                counts = 'native=6 nelisp-selected=2' if group == 'LEARNING' else 'native=5 nelisp-selected=1'
                assert f'policy-evaluations group={group} {counts}' in text
    # Deliberately omit eager evaluation instrumentation; the same checks must fail.
    result = subprocess.run([str(executable), str(out / 'negative.log'), '1', 'broken'],
                            env=dict(os.environ, DDSKK_HOST_POLICY_COUNTERS='1'), timeout=10)
    assert result.returncode == 1, 'counter negative control accepted'
    print('PASS policy counters groups=5 default=quiet eager_hits=counted negative_control=rejected stacks=0')


if __name__ == '__main__':
    main()
