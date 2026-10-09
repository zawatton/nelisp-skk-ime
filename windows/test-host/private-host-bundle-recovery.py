"""Serial real process recovery at bundle journal boundaries."""
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


def main():
    parser = argparse.ArgumentParser()
    for name in ('bundle', 'previous', 'runtime', 'state'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--cold-load-sleep-sec', type=int, default=45)
    parser.add_argument('--points', nargs='+', default=['before-handover','after-release','during-prewarm','after-prewarm','after-commit'])
    args = parser.parse_args()
    count = 0
    for point in args.points:
        state = args.state / point
        state.mkdir(parents=True)
        key = 'Software\\NativeIME-test-' + uuid.uuid4().hex
        pipe = 'EH5-' + uuid.uuid4().hex
        base = [sys.executable, str(Path(__file__).with_name('private-host-bundle.py')),
                '--bundle', str(args.bundle), '--previous', str(args.previous), '--runtime', str(args.runtime),
                '--state', str(state), '--key', key, '--pipe', pipe,
                '--cold-load-sleep-sec', str(args.cold_load_sleep_sec), '--lifetime-sec', '0']
        guard = [sys.executable, str(Path(__file__).with_name('host-test-process-guard.py')),
                 'run', '--root', str(bundle.transport.ROOT), '--']
        with (state / 'interrupted.log').open('w') as log:
            interrupted = subprocess.run(guard + base + ['--action', 'cycle', '--fault-at', point], stdout=log, stderr=log)
        text = (state / 'interrupted.log').read_text('utf-8')
        assert interrupted.returncode != 0 and 'private test cancellation/crash boundary=' + point in text, text[-3000:]
        assert '"leftovers": []' in text, text[-3000:]
        record = json.loads((state / 'deployment.json').read_text('utf-8'))
        expected = args.bundle if point == 'after-commit' else args.previous
        assert bundle.recovery_bundle(record).resolve() == expected.resolve()
        before = (state / 'user.jisyo').read_text('utf-8')
        learned = [line for line in before.splitlines() if line.startswith('かな ') or line.startswith(';; local-ack ')]
        assert len(learned) >= 11
        with (state / 'recovered.log').open('w') as log:
            recovered = subprocess.run(guard + base + ['--action', 'recover'], stdout=log, stderr=log)
        text = (state / 'recovered.log').read_text('utf-8')
        assert recovered.returncode == 0 and '"leftovers": []' in text, text[-3000:]
        after = (state / 'user.jisyo').read_text('utf-8')
        for line in learned:
            assert after.splitlines().count(line) == 1, (point, line)
        count += 1
        print(f'PASS bundle recovery point={point} phase={record["phase"]} retained_learning_rows={len(learned)} duplicate_rows=0', flush=True)
    print(f'PASS S5 recovery cases={count} acknowledged_ID_loss=0', flush=True)


if __name__ == '__main__':
    main()
