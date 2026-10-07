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
import struct
import subprocess
import threading
import time
import uuid


def verify_custom_symbol_rules(artifacts):
    # Verify the configured export actually reached the immutable base. A
    # default table could otherwise make the custom-rules reproduction green.
    bases = list(artifacts.rglob('generation-*.index'))
    assert bases, 'No published rule base for custom-symbol fixture'
    for base in bases:
        data = base.read_bytes()
        offset, length = struct.unpack_from('<QQ', data, 64)
        rules = data[offset:offset + length].decode('utf-8')
        symbols = {}
        for record in rules.split()[2:]:
            fields = record.split(':')
            if fields[0] in ('00002e', '00002c'):
                symbols[fields[0]] = fields[2]
        assert symbols == {'00002e': '003002', '00002c': '003001'}, symbols


def main():
    p = argparse.ArgumentParser()
    for name in ('dll', 'core', 'tsf-host', 'engine-host', 'runtime', 'artifacts'):
        p.add_argument('--' + name, required=True)
    p.add_argument('--case', choices=('inline', 'missing', 'wrong', 'drop', 'emacs', 'pair', 'pair-legacy', 'pair-down', 'emacs-pair', 'emacs-accept-queue', 'emacs-nested-pair', 'emacs-okuri', 'emacs-navigation', 'emacs-fast-typeahead', 'emacs-open-mode', 'emacs-provider-restored'), default='inline')
    p.add_argument('--custom-symbol-rules', action='store_true')
    p.add_argument('--map-during-reading', action='store_true')
    p.add_argument('--key-gap', type=int, choices=(0, 10, 20), default=0)
    p.add_argument('--context-alias', action='store_true',
                   help='Deliver the vowel through a context tear-off with the same COM identity')
    p.add_argument('--selection-unavailable', action='store_true',
                   help='Model an IMM32 host that rejects explicit caret selection')
    p.add_argument('--cold-load', type=int, default=45)
    p.add_argument('--local-conversion', action='store_true')
    p.add_argument('--repository', default=None)
    p.add_argument('--cycle-regression', action='store_true',
                   help='Cycle to candidate five, lose its commit reply, then settle')
    p.add_argument('--q-regression', action='store_true',
                   help='Check immediate local q commit and the following reading')
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
            if done.is_set() or args.case in ('missing', 'emacs', 'pair-down', 'emacs-pair', 'emacs-accept-queue', 'emacs-nested-pair', 'emacs-okuri', 'emacs-navigation', 'emacs-fast-typeahead', 'emacs-open-mode', 'emacs-provider-restored'):
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

    thread = threading.Thread(target=serve, daemon=True)
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
    pairing = args.case in ('pair', 'pair-legacy', 'pair-down', 'emacs-pair', 'emacs-nested-pair')
    if args.case == 'emacs-accept-queue':
        script = ('WAIT2500 a i SPACE SETTLE30000 ENTER SETTLE30000 '
                  'K a SPACE SETTLE8000 n '
                  + ('SETTLE8000 CONTEXTALIAS ' if args.context_alias else '')
                  + 'u SETTLE8000 WAIT500')
    if args.case == 'emacs-navigation':
        assert args.local_conversion, 'Navigation case requires local ownership'
        script = ('WAIT2500 K a n a REFUSEWRITE SPACE WAIT200 SETTLE8000:FIRST MIRROR '
                  'SPACE WAIT100 x WAIT100 SPACE SSPACE WAIT100 SPACE CTRLP WAIT100 '
                  'PGDN WAIT100 PGDN WAIT100 PGUP WAIT100 UP WAIT100 DOWN WAIT100 '
                  'HOME x WAIT100 SPACE ENTER WAIT100 '
                  'K a n j i REFUSEWRITE SPACE WAIT200 SETTLE8000:NEW ENTER WAIT6500 '
                  'T e i k o u c h i REFUSEWRITE SPACE WAIT200 SETTLE8000:PUBLISHED ENTER '
                  'T e i k o u t i SPACE ENTER SETTLE8000:END WAIT500')
    if args.case == 'emacs-okuri':
        assert args.local_conversion, 'Okuri inline case requires local ownership'
        script = ('WAIT2500 K WAIT100 a WAIT100 K WAIT100 u WAIT300 '
                  'SPACE WAIT100 x WAIT100 SPACE WAIT100 ENTER WAIT100 '
                  'K a T WAIT100 t WAIT100 a WAIT300 ENTER WAIT100 '
                  'S i N WAIT100 d WAIT100 a WAIT300 ENTER WAIT100 '
                  'K a K WAIT100 BS WAIT100 K u WAIT300 ENTER WAIT100 '
                  'K a U WAIT300 CTRLG WAIT100 CTRLG WAIT100 '
                  'K a U WAIT300 n u ENTER SETTLE8000:END WAIT500')
    if args.cycle_regression:
        assert args.case == 'emacs', 'Cycle regression requires the real Emacs listener'
        script = ('WAIT2500 K a n a SPACE SETTLE30000:first '
                  'SPACE SETTLE30000:second SPACE SETTLE30000:third '
                  'SPACE SETTLE30000:fourth SPACE SETTLE30000:fifth '
                  'ENTER SETTLE30000:commit WAIT500')
    if args.case == 'emacs-fast-typeahead':
        assert args.local_conversion
        script = (f'KEYGAP{args.key_gap} WAIT2500 N a i ASYNCWRITE SPACE ASYNCFLUSH WAIT100 '
                  'ASYNCWRITE ENTER N a i SPACE ENTER ASYNCFLUSH WAITREMAP5000 '
                  'N a i SPACE WAIT100 ENTER SETTLE8000:END WAIT500')
    if args.case == 'emacs-open-mode':
        script = 'IMEOFF WAIT2500 CLIENT IMEON WAIT100 CLIENT n a i WAIT100 CLIENT CTRLJ WAIT100 CLIENT n a i WAIT100 CLIENT ENTER SETTLE8000:END WAIT500'
    if args.q_regression:
        assert args.case == 'emacs' and not args.cycle_regression
        script = ('WAIT2500 K a n a q SETTLE30000:q '
                  'K a ENTER SETTLE30000:next')
    if pairing:
        script = 'WAIT2500 a i SPACE WAIT3000 ENTER WAIT500 APPCLEAR BRACKET WAIT100 WAIT500'
        if args.case == 'emacs-nested-pair':
            script += ' BRACKET WAIT100 WAIT500'
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
    command += ['-DebugLog']
    if args.case == 'emacs-provider-restored':
        command[command.index('-Script') + 1] = 'KEYGAP0 WAIT2500 N a i SPACE WAIT4000 LEFT WAIT100 a ASYNCWRITE SPACE ASYNCFLUSH ENTER SETTLE8000:END'
    if args.case == 'emacs-open-mode':
        command += ['-PublishState']
    if args.local_conversion:
        command += ['-LocalConversion', '1']
    env = os.environ.copy()
    env['DDSKK_HARNESS_DIAGNOSTICS'] = '1'
    if args.custom_symbol_rules:
        private_appdata = directory / 'appdata'
        rules = private_appdata / 'NativeIME' / 'input-rules.conf'
        rules.parent.mkdir(parents=True, exist_ok=True)
        rules.write_text('[symbols-hankaku]\n, = "、"\n. = "。"\n', encoding='utf-8')
        command += ['-InputRulesFile', str(rules)]
    if args.map_during_reading:
        env['NATIVEIME_TEST_LOCAL_MAP_DELAY_MS'] = '3000'
        script = script.replace('N a i ASYNCWRITE', 'N a i WAIT1000 ASYNCWRITE', 1)
        command[command.index('-Script') + 1] = script
    if args.selection_unavailable:
        env['NATIVEIME_TEST_SELECTION_UNAVAILABLE'] = '1'
    if args.cycle_regression:
        env['NATIVEIME_TEST_CANDIDATE_CONTROL_FAIL_MS'] = '1600'
    env['INLINE_TEST_OPEN_MODE'] = 'latin' if args.case == 'emacs-open-mode' else ''
    env['INLINE_TEST_PIDFILE'] = str(pidfile)
    env['NELISP_IME_INLINE_DIR'] = str(directory)
    env['INLINE_TEST_PAIR'] = ('2' if args.case == 'emacs-nested-pair'
                               else '1' if args.case == 'emacs-pair' else '')
    env['INLINE_TEST_ARTIFACTS'] = str(artifacts)
    env['INLINE_TEST_LOG'] = str(directory / 'emacs.log')
    if args.case in ('emacs-pair', 'emacs-nested-pair'):
        # Only the engine sees this configuration. The real Emacs library
        # must learn both strings from PAIR, with no local pair table.
        rules = directory / 'input-rules.conf'
        pair = '"(" ")"' if args.case == 'emacs-nested-pair' else '"<<" ">>"'
        rules.write_text('width = hankaku\nauto-pair = yes\n[pairs-hankaku]\n[ = ' + pair + '\n',
                         encoding='utf-8')
        env['NELISP_IME_INPUT_RULES'] = str(rules)
    if args.case == 'emacs-navigation':
        source = directory / 'shared.utf8'
        source.write_text('かな /仮名/佳奈/加奈/可奈/哉/金/香奈/花菜/奏/叶/華奈/河南/\n'
                          'かんじ /漢字/幹事/感じ/\nていこうち /抵抗値/\n', encoding='utf-8')
        personal = directory / 'personal.utf8'
        personal.write_text('ていこうち /抵抗値/\nおーむ /Ω/\nていこうち /抵抗値/\n', encoding='utf-8')
        env['DDSKK_DICTIONARY_FILES'] = str(personal) + ';' + str(source)
        env['NATIVEIME_TEST_LOCAL_WORKER_STALL_MS'] = '5000'
    if args.case in ('emacs-fast-typeahead', 'emacs-provider-restored'):
        first, second = directory / 'first.utf8', directory / 'second.utf8'
        first.write_text('ない /無い/内/\nかな /仮名/佳奈/\n', encoding='utf-8')
        second.write_text('ない /無い/亡い/\nかな /仮名/加奈/\n', encoding='utf-8')
        env['DDSKK_DICTIONARY_FILES'] = str(first) + ';' + str(second)
        env['NATIVEIME_TEST_LOCAL_REMAP_DELAY_MS'] = '400'
        if args.case == 'emacs-provider-restored':
            first.write_text('ない /無い/内/\nないあ /無い亜/\n', encoding='utf-8')
            env['NATIVEIME_TEST_LOCAL_MAP_DELAY_MS'] = '6000'
    if args.case == 'emacs-okuri':
        env['DDSKK_DICTIONARY_FILES'] = str(root / 'windows/test-host/data/okuri-jisyo.utf8')
    try:
        (directory / 'stop').unlink(missing_ok=True)
        if args.case in ('inline', 'emacs'):
            (directory / 'windows.log').unlink(missing_ok=True)
            observer = subprocess.Popen([os.sys.executable,
                str(root / 'windows/test-host/candidate-window-observer.py'),
                str(directory), str(artifacts), caret_map])
        if args.case in ('emacs', 'emacs-pair', 'emacs-accept-queue', 'emacs-nested-pair', 'emacs-okuri', 'emacs-navigation', 'emacs-fast-typeahead', 'emacs-open-mode', 'emacs-provider-restored'):
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
    (directory / 'harness.log').write_text(output, encoding='utf-8')
    (directory / 'channel.log').write_text('\n'.join(lines), encoding='utf-8')
    assert result.returncode == 0, (result.returncode, output[-4000:])
    # Read the host's UTF-8 bytes directly; Windows PowerShell's outer stdout
    # encoding depends on its launcher, and is not a protocol observation.
    tsf_log = max(artifacts.glob('harness-*/tsf.stdout.log'), key=lambda path: path.stat().st_mtime)
    host_text = tsf_log.read_text(encoding='utf-8')
    print(host_text[-1000:].encode('ascii', 'backslashreplace').decode('ascii'))
    assert not errors, errors
    assert 'UnknownToken' not in host_text, 'Invalid test script'
    if args.custom_symbol_rules:
        verify_custom_symbol_rules(artifacts)
    assert 'exited=True' in output, 'Harness did not confirm owned process cleanup'
    if args.case == 'emacs-open-mode':
        states = re.findall(r'^CLIENT mode=(\S+) open=(\d+) composing=(\d+) sequence=(\d+)', host_text, re.MULTILINE)
        assert len(states) == 5, states
        assert states[0][1] == '0' and states[1][:3] == ('latin', '1', '0'), states
        assert states[2][:3] == ('latin', '1', '0') and states[2][3] == states[1][3], states
        assert states[3][:3] == ('hiragana', '1', '0') and states[4][0:2] == ('hiragana', '1'), states
        assert 'INLINE_MODE mode=latin open=1 label=SKK' in host_text
        assert host_text.count('INLINE_MODE mode=latin') == 1
        assert 'AFTER END BUF=[ない] SEL=2,2 COMP=-' in host_text, host_text[-3000:]
        assert 'COMPOSITION START' not in host_text
        rendered = (directory / 'emacs.log').read_text(encoding='utf-8')
        assert 'MODEACK MODE-APPLIED latin' in rendered and 'BUFFER_UNCHANGED=t' in rendered, rendered
        assert emacs.returncode == 0
        print('PASS real Emacs open-mode latin open=1 label=SKK C-j=hiragana unchanged_typing=1 checkpoints=5 cleanup=confirmed')
        return
    if args.case == 'emacs-provider-restored':
        debug = '\n'.join(f.read_text(encoding='utf-8') for f in artifacts.rglob('dll-debug.log'))
        assert 'LOCAL_RECLAIM ' in debug, debug
        assert 'AFTER END BUF=[無い亜] SEL=3,3 COMP=-' in host_text, host_text[-4000:]
        assert 'branch=provider-preedit-key' not in host_text and 'branch=local-convert' in host_text
        assert emacs.returncode == 0
        print('PASS real Emacs provider-restored reading reclaimed=1 following_letters=local following_SPACE=local cleanup=confirmed')
        return
    if args.case == 'emacs-fast-typeahead':
        assert 'AFTER ASYNCFLUSH BUF=[無い無い] SEL=4,4 COMP=-' in host_text, host_text[-4000:]
        assert 'AFTER END BUF=[無い無い無い] SEL=6,6 COMP=-' in host_text, host_text[-4000:]
        assert 'EDIT_ASYNC queued=1' in host_text and 'EDIT_ASYNC executed=1' in host_text
        assert 'LOCAL_MAPPING delay_ms=400 retained=1' in host_text
        assert not re.search(r'branch=provider-(queue|convert)|LOCAL_EDIT recovered', host_text)
        assert 'COMPOSITION START' not in host_text
        rendered = (directory / 'emacs.log').read_text(encoding='utf-8')
        assert '▼無い' in rendered and 'BUFFER_UNCHANGED=t' in rendered, rendered
        assert emacs.returncode == 0, emacs.returncode
        times = [int(value) for value in re.findall(r'^KEYLAT token=\S+ .*total_us=(\d+) claimed=1', host_text, re.MULTILINE)]
        assert times and max(times) <= 25000, times
        # Correlate SPACE receipt and the first candidate render using UTC.
        spaces = [int(v) / 1000000 for v in re.findall(r'^SCRIPTKEY token=SPACE .*utc_us=(\d+)', host_text, re.MULTILINE)]
        candidates = [float(v) for v in re.findall(r'RENDER_AT ([0-9.]+)\nRENDER \d+ ▼無い', rendered)]
        assert spaces and candidates, (host_text, rendered)
        latency = (candidates[0] - spaces[0]) * 1000
        assert 0 <= latency <= 100, latency
        print(f'PASS real Emacs async typeahead gap_ms={args.key_gap} callbacks={len(times)} max_us={max(times)} first_visible_ms={latency:.3f} cleanup=confirmed')
        return
    if args.case == 'emacs-navigation':
        assert 'AFTER END BUF=[仮名漢字抵抗値抵抗値] SEL=10,10 COMP=-' in host_text, host_text[-4000:]
        assert 'LOCAL_EDIT recovered=1' in host_text and 'branch=local-convert' in host_text
        assert 'branch=provider-queue' not in host_text and 'branch=provider-convert' not in host_text
        rendered = (directory / 'emacs.log').read_text(encoding='utf-8')
        for text in ('▽かな', '▼仮名', '▼佳奈', '▼哉', '▼河南', '▼可奈', '▼漢字', '▼抵抗値'):
            assert text in rendered, (text, rendered)
        assert 'BUFFER_UNCHANGED=t' in rendered and emacs.returncode == 0
        assert 'COMPOSITION START' not in host_text
        times = [int(value) for value in re.findall(r'^KEYLAT token=\S+ .*total_us=(\d+) claimed=1', host_text, re.MULTILINE)]
        assert times and max(times) <= 25000, times
        print(f'PASS real Emacs local navigation checkpoints=8 final_units=10 callbacks={len(times)} max_us={max(times)} cleanup=confirmed')
        return
    if args.case == 'emacs-okuri':
        assert 'AFTER END BUF=[掛く買った死んだ掛く買うぬ] SEL=13,13 COMP=-' in host_text, host_text[-4000:]
        assert 'branch=local-okuri-convert' in host_text
        assert 'branch=provider-queue' not in host_text and 'branch=okuri-sync' not in host_text
        rendered = (directory / 'emacs.log').read_text(encoding='utf-8')
        for text in ('▽か*k', '▼書く', '▼掛く', '▽か*っt', '▼買った', '▽し*んd', '▼死んだ', '▽か*', '▽かう', '▼買う'):
            assert text in rendered, (text, rendered)
        assert 'BUFFER_UNCHANGED=t' in rendered and emacs.returncode == 0
        assert 'COMPOSITION START' not in host_text
        times = [int(value) for value in re.findall(r'^KEYLAT token=\S+ .*total_us=(\d+) claimed=1', host_text, re.MULTILINE)]
        assert times and max(times) <= 25000, times
        print(f'PASS real Emacs local okuri checkpoints=10 final_units=13 callbacks={len(times)} max_us={max(times)} cleanup=confirmed')
        return
    if args.case == 'emacs-accept-queue':
        if args.local_conversion:
            assert 'branch=local-convert' in host_text, host_text[-4000:]
            assert 'branch=provider-accept-and-queue' not in host_text
            assert 'branch=provider-queue' not in host_text
        else:
            assert 'branch=provider-accept-and-queue' in host_text, host_text[-4000:]
            if not args.context_alias:
                assert 'branch=provider-queue' in host_text, host_text[-4000:]
        if args.context_alias:
            assert 'CONTEXT_ALIAS distinct=1 same_identity=1' in host_text, host_text[-4000:]
        assert 'AFTER WAIT500 BUF=[あい蚊ぬ] SEL=4,4 COMP=-' in host_text, host_text[-4000:]
        rendered = (directory / 'emacs.log').read_text(encoding='utf-8')
        assert '▼蚊' in rendered and emacs.returncode == 0, rendered
        assert 'COMPOSITION START' not in host_text, 'Inline created a TSF composition'
        print('PASS inline accept-and-queue final=あい蚊ぬ selection_unavailable=' + str(args.selection_unavailable))
        return
    if args.q_regression:
        assert 'branch=q-katakana-local state=1' in host_text
        assert 'AFTER q BUF=[カナ] SEL=2,2 COMP=-' in host_text
        assert 'AFTER next BUF=[カナか] SEL=3,3 COMP=-' in host_text
        assert 'COMPOSITION START' not in host_text
        settle = re.search(r'SETTLE OK token=SETTLE30000:q elapsed_ms=(\d+)', host_text)
        assert settle and int(settle[1]) <= 200, 'q exceeded local settle budget'
        rendered = (directory / 'emacs.log').read_text(encoding='utf-8')
        assert '▽かな' in rendered and 'BUFFER_UNCHANGED=t' in rendered
        assert emacs.returncode == 0
        print(f'PASS local-q inline assertions=8 settle_ms={settle[1]} cleanup=confirmed')
        return
    if args.cycle_regression:
        assert 'CANDIDATE_TEST lost-reply' in host_text, 'Fault injection did not run'
        assert 'AFTER commit BUF=[佳奈] SEL=2,2 COMP=-' in host_text, host_text[-2000:]
        rendered = (directory / 'emacs.log').read_text(encoding='utf-8')
        assert '▼佳奈' in rendered and emacs.returncode == 0, rendered
        assert 'COMPOSITION START' not in host_text, 'Inline created a TSF composition'
        print('PASS candidate-cycle fifth=佳奈 lost_commit_reply=recovered settle=idle cleanup=confirmed')
        return
    if args.case == 'emacs-nested-pair':
        assert 'AFTER WAIT500 BUF=[((] SEL=2,2 COMP=-' in host_text, host_text[-2000:]
        rendered = (directory / 'emacs.log').read_text(encoding='utf-8')
        assert len(re.findall(r'^PAIR [0-9]+ \( \)$', rendered, re.MULTILINE)) == 2, rendered
        assert 'PAIR_BUFFER=(()) POINT=3' in rendered, rendered
        assert emacs.returncode == 0, emacs.returncode
        assert 'COMPOSITION START' not in host_text, 'Inline created a TSF composition'
        print('PASS inline nested pair buffer=(()) point=3 pair_lines=2 cleanup=confirmed')
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
