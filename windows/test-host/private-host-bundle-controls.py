"""Negative bundle controls, immutable packaging and read-only dry runs."""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import uuid

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('bundle', Path(__file__).with_name('private-host-bundle.py'))
bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle)


def startup_case(args, manifest, original, field, old, incompatible):
    manifest.write_bytes(original.replace((field + '=' + old).encode(), (field + '=' + incompatible).encode()))
    args.key = 'Software\\NativeIME-test-' + uuid.uuid4().hex
    args.pipe = 'EH5-' + uuid.uuid4().hex
    deployment = bundle.Deployment(args)
    try:
        env = dict(bundle.os.environ, DDSKK_PIPE_NAME=deployment.name, NATIVEIME_REGISTRY_KEY=args.key,
            DDSKK_HOST_BUNDLE_MANIFEST=str(manifest), DDSKK_HOST_LOG=str(args.state / 'host.log'),
            LOCALAPPDATA=str(args.state), DDSKK_USER_JISYO=str(args.state / 'user.jisyo'),
            DDSKK_SKKSERV_ENABLE='0', NELISP_IME_ENGINE='ddskk', DDSKK_HOST_POLICY_SHADOW='1')
        for switch in ('SOURCES', 'CACHE', 'RESTART', 'PUBLICATION', 'LEARNING'):
            env['DDSKK_HOST_POLICY_' + switch] = '1'
        deployment.host = deployment.job.spawn([str(args.bundle / 'ddskk-engine-host.exe'),
            str(args.runtime), str(args.bundle / 'repository')], env, args.state / 'stderr.log')
        bundle.time.sleep(args.cold_load_sleep_sec)
        assert deployment.request('ENGINE CURRENT') == b'ENGINE ddskk'
        assert deployment.request('SESSION fallback RESET').startswith(b'STATE ')
        log = (args.state / 'host.log').read_text('utf-8')
        assert 'policy-fallback native reason=incompatible-bundle-image-or-protocol' in log
        assert 'policy-start pid=' not in log
        deployment.stop()
        print(f'PASS real startup incompatible_field={field} native_fallback=1 managed_children=0', flush=True)
    finally:
        deployment.close()


def main():
    parser = argparse.ArgumentParser()
    for name in ('bundle', 'runtime', 'state', 'deploy'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--startup', action='store_true')
    parser.add_argument('--cold-load-sleep-sec', type=int, default=45)
    args = parser.parse_args()
    args.state.mkdir(parents=True, exist_ok=True)
    fields = bundle.manifest(args.bundle, args.runtime)
    manifest = args.bundle / 'bundle.manifest'
    original = manifest.read_bytes()
    cases = [('policy_ipc', 'HP1'), ('contract', 'engine-host-v999'),
             ('policy_sha256', '0' * 64), ('runtime_sha256', '0' * 64),
             ('host_sha256', '0' * 64), ('schema', '999')]
    rejected = 0
    try:
        for key, value in cases:
            manifest.write_bytes(original.replace((key + '=' + fields[key]).encode(), (key + '=' + value).encode()))
            try:
                bundle.manifest(args.bundle, args.runtime)
            except ValueError:
                rejected += 1
            else:
                raise AssertionError('corrupt manifest accepted: ' + key)
        manifest.write_bytes(original)
        before = set(args.state.rglob('*'))
        process = subprocess.run(['pwsh', '-NoProfile', '-File', str(args.deploy), '-Action', 'Deploy',
            '-BundleDirectory', str(args.bundle), '-Runtime', str(args.runtime), '-StateDirectory', str(args.state),
            '-RegistryKey', 'Software\\NativeIME-test-controls', '-PipeName', 'EH5-controls', '-DryRun'],
            capture_output=True, text=True)
        assert process.returncode == 0 and 'no writes/processes' in process.stdout, process.stderr
        assert set(args.state.rglob('*')) == before
        private_rejected = 0
        for key, pipe in [('Software\\NativeIME','EH5-controls'),
                          ('Software\\NativeIME-test-controls','ddskk-ime-v1'),
                          ('Software\\NativeIME-test-controls','EH5-' + 'x' * 300)]:
            result = subprocess.run(['pwsh','-NoProfile','-File',str(args.deploy),'-Action','Deploy',
                '-BundleDirectory',str(args.bundle),'-Runtime',str(args.runtime),'-StateDirectory',str(args.state),
                '-RegistryKey',key,'-PipeName',pipe,'-DryRun'],capture_output=True,text=True)
            assert result.returncode != 0 and 'Explicit bounded' in result.stderr, result.stderr
            private_rejected += 1
        assert set(args.state.rglob('*')) == before
        for phase, expected in [('prepared','old'),('released','old'),('committed','new')]:
            bundle.durable(args.state / 'journal.json', dict(phase=phase, old='old', new='new'))
            recovered = json.loads((args.state / 'journal.json').read_text('utf-8'))
            assert bundle.recovery_bundle(recovered) == Path(expected)
        # Exclusive state and immutable manifest controls have real bad-input
        # checks; no successful broken case can be labelled a valid recovery.
        try:
            bundle.recovery_bundle(dict(phase='unknown', old='old', new='new'))
        except ValueError:
            pass
        else:
            raise AssertionError('invalid journal phase accepted')
        print(f'PASS bundle controls incompatible_rejected={rejected} private_guard_rejections={private_rejected} dryrun_no_writes=1 durable_journal_phases=3 invalid_phase_rejected=1', flush=True)
        if args.startup:
            # Bypass the script-side rejection to test the real startup fallback.
            state = args.state
            for field, incompatible in [('policy_ipc','HP1'),('policy_sha256','0' * 64)]:
                args.state = state / field
                args.state.mkdir()
                startup_case(args, manifest, original, field, fields[field], incompatible)
    finally:
        manifest.write_bytes(original)


if __name__ == '__main__':
    main()
