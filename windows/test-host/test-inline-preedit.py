"""Private real-core TCP/Emacs integration. No foreground input or live settings.

Pass all build/runtime paths explicitly. Logs and PID coordination stay under
--artifacts. Each case uses run-harness.ps1's private registry/pipe/LOCALAPPDATA.
"""
import argparse
import json
import os
import re
from pathlib import Path
import socket
import subprocess
import threading
import time
import uuid


def main():
    p = argparse.ArgumentParser()
    for name in ('dll', 'core', 'tsf-host', 'engine-host', 'runtime', 'artifacts'):
        p.add_argument('--' + name, required=True)
    p.add_argument('--case', choices=('inline', 'missing', 'wrong', 'drop', 'emacs', 'pair', 'pair-legacy', 'pair-down', 'emacs-pair'), default='inline')
    p.add_argument('--cold-load', type=int, default=45)
    p.add_argument('--repository', default=None)
    p.add_argument('--cycle-regression', action='store_true',
                   help='Cycle to candidate five, lose its commit reply, then settle')
    args = p.parse_args()
    root = Path(args.repository).resolve() if args.repository else Path(__file__).resolve().parents[2]
    artifacts = Path(args.artifacts).resolve()
    artifacts.mkdir(parents=True, exist_ok=True)
    directory = artifacts / ('inline-' + args.case)
    directory.mkdir(exist_ok=True)
    pidfile = directory / 'pid'
    pidfile.unlink(missing_ok=True)
    done = threading.Event()
    lines = []
    errors = []
    emacs = None
    observer = None
    caret_map = 'Local\\ddskk-test-caret-' + uuid.uuid4().hex
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen()
    listener.settimeout(.2)
    token = '0123456789abcdef0123456789abcdef'

    def serve():
        try:
            if args.case == 'drop':
                channel = directory / 'drop-channel.log'
                channel.unlink(missing_ok=True)
                subscriber = subprocess.Popen([
                    os.sys.executable, str(root / 'windows/test-host/inline-drop-subscriber.py'), str(directory)])
                try:
                    while not done.is_set():
                        if channel.exists() and 'PREEDIT ' in channel.read_text(encoding='utf-8'):
                            subscriber.kill() # the test owns this exact process
                            subscriber.wait(5)
                            lines.extend(channel.read_text(encoding='utf-8').splitlines())
                            return
                        if subscriber.poll() is not None:
                            raise RuntimeError('Drop subscriber exited before PREEDIT')
                        time.sleep(.02)
                finally:
                    if subscriber.poll() is None:
                        subscriber.kill()
                        subscriber.wait(5)
                return
            while not done.is_set() and not pidfile.exists():
                time.sleep(.02)
            if done.is_set() or args.case in ('missing', 'emacs', 'pair-down', 'emacs-pair'):
                return
            pid = int(pidfile.read_text())
            published_token = 'f' * 32 if args.case == 'wrong' else token
            (directory / f'{pid}.json').write_text(json.dumps({
                'token': published_token, 'version': 1, 'port': listener.getsockname()[1]}), encoding='utf-8')
            while not done.is_set():
                try:
                    conn, _ = listener.accept()
                except socket.timeout:
                    continue
                with conn:
                    conn.settimeout(.2)
                    data = b''
                    while not done.is_set():
                        try:
                            chunk = conn.recv(4096)
                        except socket.timeout:
                            continue
                        if not chunk:
                            break
                        data += chunk
                        while b'\n' in data:
                            raw, data = data.split(b'\n', 1)
                            line = raw.decode('utf-8')
                            lines.append(line)
                            if line.startswith('HELLO'):
                                if args.case == 'wrong':
                                    assert line == f'HELLO 1 {published_token} {pid}', line
                                    break
                                assert line == f'HELLO 1 {token} {pid}', line
                                conn.sendall(b'OK 1 pair\nCARET 321 456 23\n' if args.case == 'pair'
                                             else b'OK 1\nCARET 321 456 23\n')
                        if args.case == 'wrong':
                            break
        except Exception as error:
            errors.append(repr(error))

    thread = threading.Thread(target=serve)
    thread.start()
    # The private harness warms the engine separately; direct DDSKK Space
    # would insert a literal space into the measured document.
    script = ('WAIT2500 a i ENTER WAIT500 '
              'K WAIT100 a WAIT100 SPACE WAIT3000 ENTER WAIT500 '
              # DDSKK starts okuri conversion at u; SPACE advances it.
              'K WAIT100 i WAIT100 e WAIT100 R WAIT100 u WAIT100 WAIT3000 ENTER WAIT500 '
              'K WAIT100 a WAIT100 n WAIT100 a WAIT100 SPACE WAIT3000 CTRLG WAIT100 CTRLG WAIT100 '
              'K WAIT100 a WAIT100 n WAIT100 a WAIT100 q WAIT3000 '
              'K WAIT100 a WAIT100 n WAIT100 a WAIT100 SPACE WAIT3000 '
              'SPACE WAIT1000 SPACE WAIT1000 SPACE WAIT1000 SPACE WAIT1000 ENTER WAIT1000 WAIT500')
    pairing = args.case in ('pair', 'pair-legacy', 'pair-down', 'emacs-pair')
    if args.cycle_regression:
        assert args.case == 'emacs', 'Cycle regression requires the real Emacs listener'
        script = ('WAIT2500 K a n a SPACE SETTLE30000:first '
                  'SPACE SETTLE30000:second SPACE SETTLE30000:third '
                  'SPACE SETTLE30000:fourth SPACE SETTLE30000:fifth '
                  'ENTER SETTLE30000:commit WAIT500')
    if pairing:
        script = 'WAIT2500 a i SPACE WAIT3000 ENTER WAIT500 APPCLEAR BRACKET WAIT100 WAIT500'
    # The fake server's CARET is deterministic. The real Emacs runner reports
    # its rendered overlays and uses batch-safe pixel stubs for CARET only.
    command = ['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
               str(root / 'windows/test-host/run-harness.ps1'), '-Script', script,
               '-DllPath', str(Path(args.dll).resolve()), '-CoreDllPath', str(Path(args.core).resolve()),
               '-TsfHostExe', str(Path(args.tsf_host).resolve()), '-EngineHostPath', str(Path(args.engine_host).resolve()),
               '-EngineExecutablePath', str(Path(args.runtime).resolve()), '-RepositoryPath', str(root),
               '-ColdLoadSleepSec', str(args.cold_load), '-InlinePreedit', '-InlineDirectory', str(directory),
               '-InlinePidFile', str(pidfile), '-CaretMapName', caret_map,
               '-ArtifactDirectory', str(artifacts), '-TsfHostTimeoutSec', '90']
    env = os.environ.copy()
    env['DDSKK_HARNESS_DIAGNOSTICS'] = '1'
    if args.cycle_regression:
        env['NATIVEIME_TEST_CANDIDATE_CONTROL_FAIL_MS'] = '1600'
    env['INLINE_TEST_PIDFILE'] = str(pidfile)
    env['NELISP_IME_INLINE_DIR'] = str(directory)
    env['INLINE_TEST_PAIR'] = '1' if args.case == 'emacs-pair' else ''
    env['INLINE_TEST_ARTIFACTS'] = str(artifacts)
    env['INLINE_TEST_LOG'] = str(directory / 'emacs.log')
    if args.case == 'emacs-pair':
        # Only the engine sees this configuration. The real Emacs library
        # must learn both strings from PAIR, with no local pair table.
        rules = directory / 'input-rules.conf'
        rules.write_text('width = hankaku\nauto-pair = yes\n[pairs-hankaku]\n[ = "<<" ">>"\n',
                         encoding='utf-8')
        env['NELISP_IME_INPUT_RULES'] = str(rules)
    try:
        (directory / 'stop').unlink(missing_ok=True)
        if args.case in ('inline', 'emacs'):
            (directory / 'windows.log').unlink(missing_ok=True)
            observer = subprocess.Popen([os.sys.executable,
                str(root / 'windows/test-host/candidate-window-observer.py'),
                str(directory), str(artifacts), caret_map])
        if args.case in ('emacs', 'emacs-pair'):
            # Same prefix required for every PowerShell launch of Emacs.
            emacs_command = "$env:HOME=[Environment]::GetFolderPath('UserProfile'); emacs -Q --batch -L emacs -l windows/test-host/inline-emacs-subscriber.el"
            emacs = subprocess.Popen(['powershell', '-NoProfile', '-Command', emacs_command], cwd=root, env=env)
        harness = subprocess.Popen(command, cwd=root, env=env, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, encoding='utf-8', errors='replace')
        try:
            stdout, stderr = harness.communicate(timeout=240)
        except subprocess.TimeoutExpired:
            # The root is still alive, so its PID cannot be reused. Kill only
            # this test's owned process tree, including host/runtime children.
            subprocess.run(['taskkill', '/PID', str(harness.pid), '/T', '/F'], capture_output=True)
            harness.communicate()
            raise
        result = subprocess.CompletedProcess(command, harness.returncode, stdout, stderr)
    finally:
        done.set()
        thread.join(3)
        listener.close()
        # Runner exits upon its private stop file, never kill unrelated Emacs.
        (directory / 'stop').write_text('stop')
        if emacs:
            try:
                emacs.wait(10)
            except subprocess.TimeoutExpired:
                subprocess.run(['taskkill', '/PID', str(emacs.pid), '/T', '/F'], capture_output=True)
                emacs.wait()
        if observer:
            try:
                observer.wait(10)
            except subprocess.TimeoutExpired:
                observer.kill()
                observer.wait()
    output = result.stdout + result.stderr
    # Read the host's UTF-8 bytes directly; Windows PowerShell's outer stdout
    # encoding depends on its launcher, and is not a protocol observation.
    tsf_log = max(artifacts.glob('harness-*/tsf.stdout.log'), key=lambda path: path.stat().st_mtime)
    host_text = tsf_log.read_text(encoding='utf-8')
    (directory / 'harness.log').write_text(output, encoding='utf-8')
    (directory / 'channel.log').write_text('\n'.join(lines), encoding='utf-8')
    print(host_text[-1000:].encode('ascii', 'backslashreplace').decode('ascii'))
    assert result.returncode == 0, result.returncode
    assert not errors, errors
    assert 'UnknownToken' not in host_text, 'Invalid test script'
    assert 'exited=True' in output, 'Harness did not confirm owned process cleanup'
    if args.cycle_regression:
        assert 'CANDIDATE_TEST lost-reply' in host_text, 'Fault injection did not run'
        assert 'AFTER commit BUF=[佳奈] SEL=2,2 COMP=-' in host_text, host_text[-2000:]
        rendered = (directory / 'emacs.log').read_text(encoding='utf-8')
        assert '▼佳奈' in rendered and emacs.returncode == 0, rendered
        assert 'COMPOSITION START' not in host_text, 'Inline created a TSF composition'
        print('PASS candidate-cycle fifth=佳奈 lost_commit_reply=recovered settle=idle cleanup=confirmed')
        return
    if pairing:
        pairs = [line for line in lines if line.startswith('PAIR ')]
        if args.case == 'pair-down':
            assert not pairs and 'AFTER WAIT500 BUF=[「」] SEL=1,1 COMP=-' in host_text, host_text[-2000:]
        else:
            opener = '<<' if args.case == 'emacs-pair' else '「'
            position = len(opener)
            assert f'AFTER WAIT500 BUF=[{opener}] SEL={position},{position} COMP=-' in host_text, host_text[-2000:]
            assert 'COMPOSITION START' not in host_text, 'Inline pairing created a TSF composition'
            if args.case == 'pair':
                assert len(pairs) == 1 and re.fullmatch(r'PAIR [0-9]+ 「 」', pairs[0]), pairs
            elif args.case == 'pair-legacy':
                assert not pairs, pairs
            else:
                rendered = (directory / 'emacs.log').read_text(encoding='utf-8')
                pairs = re.findall(r'^PAIR [0-9]+ << >>$', rendered, re.MULTILINE)
                assert len(pairs) == 1, rendered
                assert 'PAIR_BUFFER=<<>> POINT=3' in rendered, rendered
                assert emacs.returncode == 0, emacs.returncode
        print(f'PASS inline-preedit case={args.case} pair_lines={len(pairs)} opener_only={args.case != "pair-down"} cleanup=confirmed')
        return
    expected = 'あい蚊消えるカナ佳奈'
    final = re.findall(r'AFTER WAIT500 BUF=\[([^\n]*)\] SEL=10,10 COMP=-', host_text)
    assert final and final[-1] == expected, (final, expected)
    ordinary = [int(value) for value in re.findall(r'KEYLAT token=[A-Za-z] .*?total_us=(\d+)', host_text)]
    assert ordinary and max(ordinary) < 20000, ordinary
    if args.case in ('inline', 'emacs'):
        assert 'COMPOSITION START' not in host_text, 'Inline created a TSF composition'
        if args.case == 'inline':
            snapshots = []
            sequence = 0
            for line in lines[1:]:
                fields = line.split(' ', 3)
                assert int(fields[1]) > sequence, line
                sequence = int(fields[1])
                if fields[0] == 'PREEDIT':
                    text = fields[3]
                    for escape, char in (('%0A', '\n'), ('%0D', '\r'), ('%20', ' '), ('%25', '%')):
                        text = text.replace(escape, char)
                    assert int(fields[2]) == len(text), line
                    snapshots.append(text)
            for text in ('▽k', '▽か', '▼蚊', '▽きえ*r', '▽きえ*る', '▼消える', '▽かな', '▼仮名', '▼佳奈'):
                assert text in snapshots, (text, snapshots)
            assert sum(line.startswith('CLEAR ') for line in lines) == 5, lines
        else:
            rendered = (directory / 'emacs.log').read_text(encoding='utf-8')
            for text in ('▽か', '▼蚊', '▼消える', '▽かな', '▼佳奈'):
                assert text in rendered, rendered
            assert 'cursor=1' in rendered and 'BUFFER_UNCHANGED=t' in rendered, rendered
            assert emacs.returncode == 0, emacs.returncode
        assert 'INLINE_CANDIDATE_ANCHOR x=321 y=456 height=23 below_y=479' in host_text
        windows = (directory / 'windows.log').read_text(encoding='utf-8').splitlines()
        assert windows and observer.returncode == 0, (windows, observer.returncode)
        assert all(line == 'CANDIDATE_WINDOWS visible=1 core_extra=0 x=321 y=483 anchor_x=321 anchor_y=456 height=23'
                   for line in windows), windows
        print(f'PASS candidate windows observations={len(windows)} visible=1 core_extra=0 x=321 y=483')
    else:
        assert 'COMPOSITION START' in host_text, 'Fallback failed to compose'
        if args.case == 'drop':
            assert any(line.startswith('PREEDIT') for line in lines), lines
        if args.case == 'wrong':
            assert lines and all(line.startswith('HELLO') for line in lines), lines
    print(f'PASS inline-preedit case={args.case} channel_lines={len(lines)} ordinary_max_us={max(ordinary)} final_units=10')


if __name__ == '__main__':
    main()
