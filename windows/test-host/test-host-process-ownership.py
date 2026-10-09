"""Real job ownership/cleanup controls; no IME runtime or registry required."""
import argparse
import importlib.util
from pathlib import Path
import subprocess
import sys
import time
import uuid

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('guard', Path(__file__).with_name('host-test-process-guard.py'))
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--build-dir', default='build/w')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    artifacts = root / args.build_dir / ('ownership-' + uuid.uuid4().hex)
    artifacts.mkdir(parents=True)
    pidfile = artifacts / 'child.pid'
    child_code = 'import time; time.sleep(60)'
    parent_code = ('import subprocess,sys,time; from pathlib import Path; '
                   'p=subprocess.Popen([sys.executable,"-c",sys.argv[2]]); '
                   'Path(sys.argv[1]).write_text(str(p.pid)); time.sleep(.5)')
    command = [sys.executable, '-c', parent_code, str(pidfile), child_code]
    outside = subprocess.Popen([sys.executable, '-c', child_code])
    job = guard.CommandJob()
    checks = 0

    def check(condition, label):
        nonlocal checks
        assert condition, label
        checks += 1
        print('PASS ' + label, flush=True)

    try:
        parent = job.spawn(command)
        deadline = time.monotonic() + 10
        while not pidfile.exists() and time.monotonic() < deadline:
            time.sleep(.01)
        child = int(pidfile.read_text())
        members = job.members()
        check(parent.pid in members and child in members, 'parent and descendants positively owned')
        check(outside.pid not in members, 'other session excluded even while command runs')
        parent.wait(timeout=10)
        check(parent.pid not in job.members(), 'exited parent handle is not a leftover')
        check(child in job.members(), 'orphan remains owned after parent exit')
        removed = job.cleanup()
        check(child in removed and not job.members(), 'owned orphan cleaned and reaped')
        check(outside.poll() is None, 'unrelated process remains untouched')
        job.close()
        names = {Path(sys.executable).name.lower()}
        check(guard.run_command(command, False, names) == 1, 'CONTROL strict guard rejects leaked child')
        check(guard.run_command(command, True, names) == 0, 'per-case cleanup closes leaked child job')
        check(guard.run_command([sys.executable, '-c', 'pass'], False) == 0,
              'clean command passes strict guard')
        check(guard.run_command([sys.executable, '-c', 'raise SystemExit(7)'], False) == 7,
              'command failure exit code preserved')
        check(outside.poll() is None, 'unrelated process survives strict and cleanup controls')
        output = subprocess.run([sys.executable, str(Path(__file__).with_name('host-test-process-guard.py')),
            'run', '--root', str(root), '--', sys.executable, '-c',
            'import sys; print("OWNED_STDOUT"); print("OWNED_STDERR",file=sys.stderr)'],
            capture_output=True, text=True)
        check(output.returncode == 0 and 'OWNED_STDOUT' in output.stdout and 'OWNED_STDERR' in output.stderr,
              'child stdout/stderr evidence preserved by launcher')
        print(f'PASS ownership checks={checks} failures=0 artifacts={artifacts}', flush=True)
    finally:
        job.close()
        outside.kill()
        outside.wait(timeout=10)


if __name__ == '__main__':
    main()
