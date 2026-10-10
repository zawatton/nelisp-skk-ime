"""Same TSF client and optional real Emacs listener survive a private cycle.

HKCU is required. The worker must report access denial; no pipe-only result
is substituted for these real input assertions. Run one case at a time.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import time
import uuid
import winreg

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('bundle', Path(__file__).with_name('private-host-bundle.py'))
bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle)
dictionary_spec = importlib.util.spec_from_file_location('large_dictionary', Path(__file__).with_name('large-dictionary.py'))
large_dictionary = importlib.util.module_from_spec(dictionary_spec)
dictionary_spec.loader.exec_module(large_dictionary)


def remove_key(path):
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, path, 0, winreg.KEY_ALL_ACCESS) as key:
        while True:
            try:
                child = winreg.EnumKey(key, 0)
            except OSError:
                break
            remove_key(path + '\\' + child)
    winreg.DeleteKey(winreg.HKEY_CURRENT_USER, path)


def main():
    parser = argparse.ArgumentParser()
    for name in ('bundle', 'previous', 'runtime', 'state', 'dll', 'core', 'tsf-host'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--inline', action='store_true')
    parser.add_argument('--large-dictionary', type=Path)
    parser.add_argument('--clients', type=int, choices=range(1, 9), default=1)
    parser.add_argument('--cold-load-sleep-sec', type=int, default=45)
    parser.add_argument('--concurrent-pressure', action='store_true')
    args = parser.parse_args()
    if args.large_dictionary:
        selected = large_dictionary.select_utf8(args.large_dictionary)
        args.large_dictionary = Path(selected['utf8']['path'])
        print('DICTIONARY '+json.dumps(selected), flush=True)
    for name in ('bundle','previous','runtime','state','dll','core','tsf_host'):
        setattr(args, name, getattr(args, name).resolve())
    dictionary_files = ';'.join(
        [str(bundle.transport.ROOT / 'windows/test-host/data/behavior-jisyo.utf8')] +
        ([str(args.large_dictionary)] if args.large_dictionary else []))
    args.key = 'Software\\NativeIME-test-' + uuid.uuid4().hex
    args.pipe = 'EH5-' + uuid.uuid4().hex
    args.state.mkdir(parents=True, exist_ok=True)
    created = False
    deployment = None
    listener = None
    tsf = None
    peers = []
    pressure = None
    inline = args.state / 'inline'
    inline.mkdir(exist_ok=True)
    for file in (inline / 'pid', inline / 'stop', args.state / 'bundle.request', args.state / 'bundle.done'):
        file.unlink(missing_ok=True)
    try:
        with winreg.CreateKey(winreg.HKEY_CURRENT_USER, args.key) as key:
            created = True
            for name, value in dict(EngineHost=str(args.previous / 'ddskk-engine-host.exe'),
                                    Repository=str(args.previous / 'repository'), EngineExecutable=str(args.runtime),
                                    CoreDll=str(args.core), DictionaryFiles=dictionary_files,
                                    UserJisyoPath=str(args.state / 'user.jisyo'), Engine='ddskk').items():
                winreg.SetValueEx(key, name, 0, winreg.REG_SZ, value)
            for name, value in dict(LocalConversion=1, SkkServEnable=0, InitialKanaMode=1).items():
                winreg.SetValueEx(key, name, 0, winreg.REG_DWORD, value)
        app = args.key + '\\Apps\\tsf-host.exe'
        with winreg.CreateKey(winreg.HKEY_CURRENT_USER, app) as key:
            for name, value in dict(InlinePreedit=int(args.inline), PublishState=1).items():
                winreg.SetValueEx(key, name, 0, winreg.REG_DWORD, value)
            winreg.SetValueEx(key, 'OpenMode', 0, winreg.REG_SZ, 'hiragana')
        deployment = bundle.Deployment(args)
        if args.concurrent_pressure:
            import concurrent_pressure
            concurrent_pressure._transport = bundle.transport
            from concurrent_pressure import Pressure
            assert args.inline and args.clients == 3 and args.large_dictionary
            pressure = Pressure(deployment, args)
            pressure.start()
        old, new = args.previous.resolve(), args.bundle.resolve()
        deployment.start(old)
        if pressure:
            pressure.phase('deploy')
        env = dict(os.environ, NATIVEIME_REGISTRY_KEY=args.key, DDSKK_PIPE_NAME=deployment.name,
                   DDSKK_DICTIONARY_FILES=dictionary_files,
                   DDSKK_HARNESS_DLL_PATH=str(args.dll), DDSKK_HARNESS_DIAGNOSTICS='1',
                   NELISP_IME_DISABLE_HOST_SPAWN='1', NATIVEIME_TEST_BUNDLE_DIRECTORY=str(args.state),
                   NATIVEIME_HARNESS_TSF_OUTPUT=str(args.state / 'tsf.log'),
                   LOCALAPPDATA=str(args.state), NELISP_IME_INLINE_DIR=str(inline),
                   INLINE_TEST_PIDFILE=str(inline / 'pid'), INLINE_TEST_LOG=str(inline / 'emacs.log'),
                   INLINE_TEST_TIMEOUT_SEC='600')
        if pressure:
            env.update(NATIVEIME_TEST_CALLBACK_IO_PROBE='1', NATIVEIME_TEST_CALLBACK_WAIT_CONTROL='0')
        if args.inline:
            # The required HOME prefix is retained for every Emacs process.
            command = "$env:HOME=[Environment]::GetFolderPath('UserProfile'); emacs -Q --batch -L emacs -l windows/test-host/inline-emacs-subscriber.el"
            listener = deployment.job.spawn(['powershell', '-NoProfile', '-Command', command], env, args.state / 'emacs-stderr.log')
        # Same text store, core leases and input owner span both swaps. The
        # DEFER rendezvous happens with a real local composition in progress.
        keys = 'WAIT1500 K a WAIT700 BUNDLE:DEFER n a SPACE WAIT3000 ENTER WAIT700 BUNDLE:NEW K a n a SPACE WAIT3000 ENTER WAIT700 BUNDLE:RESTART K a n a SPACE WAIT3000 ENTER WAIT700 BUNDLE:OLD K a n a SPACE WAIT3000 ENTER WAIT700'
        if pressure:
            keys = keys.replace('WAIT1500 K', 'WAIT1500 a i SPACE WAIT3000 ENTER SETTLE30000:WARM K', 1)
            # Cold restart follows rollback in the concurrent acceptance cycle.
            keys = keys.replace('BUNDLE:RESTART', 'BUNDLE:TEMP').replace('BUNDLE:OLD', 'BUNDLE:RESTART').replace('BUNDLE:TEMP', 'BUNDLE:OLD')
            for number in range(1, args.clients):
                rendezvous = args.state / f'peer-{number}'
                rendezvous.mkdir()
                log = args.state / f'peer-{number}.log'
                peer_env = dict(env, NATIVEIME_HARNESS_TSF_OUTPUT=str(log),
                                NATIVEIME_TEST_BUNDLE_DIRECTORY=str(rendezvous))
                commit = 'K a n a SPACE WAIT3000 ENTER WAIT700 '
                peer_keys = ('WAIT1500 a i SPACE WAIT3000 ENTER SETTLE30000:WARM ' +
                             commit + 'BUNDLE:NEW ' + commit + 'BUNDLE:OLD ' +
                             commit + 'BUNDLE:RESTART ' + commit)
                peer = deployment.job.spawn([str(args.tsf_host), peer_keys], peer_env, log)
                peers.append((peer, log))
        tsf = deployment.job.spawn([str(args.tsf_host), keys], env, args.state / 'tsf.log')
        (inline / 'pid').write_text(str(tsf.pid))
        current = old
        transitions = []
        deadline = time.monotonic() + 600
        request = args.state / 'bundle.request'
        while tsf.poll() is None:
            if time.monotonic() > deadline:
                raise TimeoutError('same-client bundle cycle')
            if not request.exists():
                time.sleep(.02)
                continue
            action = request.read_text('utf-8')
            if not action:
                time.sleep(.01)
                continue
            request.unlink()
            if pressure and action != 'DEFER':
                # Every independent text store reaches a composition-free
                # rendezvous before its shared stack is replaced or restarted.
                for number, (peer, _) in enumerate(peers, 1):
                    marker = args.state / f'peer-{number}' / 'bundle.request'
                    until = time.monotonic() + 120
                    while not marker.exists() or marker.read_text('utf-8') != action:
                        assert peer.poll() is None, 'peer exited before shared lifecycle boundary'
                        if time.monotonic() > until: raise TimeoutError('peer lifecycle rendezvous')
                        time.sleep(.02)
                    marker.unlink()
                pressure.pause()
            if action == 'DEFER':
                assert deployment.request('PRIVATE HANDOVER 1') == b'DEFER COMPOSITION'
            elif action == 'RESTART':
                deployment.restart(current, engine=True)
                deployment.restart(current)
                if pressure:
                    pressure.phase('cold-restart')
                    pressure.report['cold_restart_recovered'] = True
            else:
                target = new if action == 'NEW' else old
                assert action in ('NEW', 'OLD')
                deployment.swap(current, target)
                current = target
                if pressure:
                    pressure.phase('traffic' if action == 'NEW' else 'rollback')
                    assert bundle.recovery_bundle(json.loads(deployment.journal.read_text('utf-8'))) == target
                    if action == 'OLD':
                        pressure.report['rollback_restored'] = True
                with winreg.OpenKey(winreg.HKEY_CURRENT_USER, args.key, 0, winreg.KEY_SET_VALUE) as key:
                    winreg.SetValueEx(key, 'EngineHost', 0, winreg.REG_SZ, str(current / 'ddskk-engine-host.exe'))
                    winreg.SetValueEx(key, 'Repository', 0, winreg.REG_SZ, str(current / 'repository'))
                if action == 'NEW' and not pressure:
                    # Independent TSF text stores share one policy bundle and
                    # engine stack. No second host or runner is launched.
                    for number in range(1, args.clients):
                        log = args.state / f'peer-{number}.log'
                        peer_env = dict(env, NATIVEIME_HARNESS_TSF_OUTPUT=str(log))
                        peer_keys = 'WAIT1500 a i SPACE WAIT3000 ENTER ' + ' '.join(
                            ['K a n a SPACE WAIT3000 ENTER WAIT700'] * 4)
                        peer = deployment.job.spawn([str(args.tsf_host), peer_keys], peer_env, log)
                        peers.append((peer, log))
                    # Keep all text stores alive together before the next
                    # cold restart closes the engine/policy stack.
                    for peer, log in peers:
                        assert peer.wait(timeout=120) == 0
                        peer_text = log.read_text('utf-8')
                        peer_documents = re.findall(r'^AFTER WAIT700 BUF=\[(.*?)\].*COMP=-', peer_text, re.MULTILINE)
                        assert peer_documents and peer_documents[-1].endswith('仮名仮名仮名仮名'), peer_documents
                        peer_times = [int(value) for value in re.findall(
                            r'KEYLAT token=[A-Za-z] .*?total_us=(\d+)', peer_text)]
                        assert peer_times and max(peer_times) < 20000, peer_times
            transitions.append(action)
            if pressure and action != 'DEFER':
                for number in range(1, args.clients):
                    (args.state / f'peer-{number}' / 'bundle.done').write_text('OK')
            (args.state / 'bundle.done').write_text('OK')
        assert tsf.wait(timeout=10) == 0
        if pressure:
            for peer, log in peers:
                assert peer.wait(timeout=120) == 0
                peer_text = log.read_text('utf-8')
                warm = re.search(r'^AFTER WARM BUF=\[(.*?)\]', peer_text, re.MULTILINE)
                peer_documents = re.findall(r'^AFTER WAIT700 BUF=\[(.*?)\].*COMP=-', peer_text, re.MULTILINE)
                assert warm and peer_documents[-1] == warm[1] + '仮名仮名仮名仮名', peer_documents
                assert [value for value in re.findall(r'BUNDLE_RESULT action=(\w+) result=OK', peer_text)] == ['NEW','OLD','RESTART']
                peer_times = [int(value) for value in re.findall(r'KEYLAT token=[A-Za-z] .*?total_us=(\d+)', peer_text)]
                assert peer_times and max(peer_times) < 20000, peer_times
        assert transitions == (['DEFER', 'NEW', 'OLD', 'RESTART'] if pressure else ['DEFER', 'NEW', 'RESTART', 'OLD']), transitions
        text = (args.state / 'tsf.log').read_text('utf-8')
        document = re.findall(r'^AFTER WAIT700 BUF=\[(.*?)\].*COMP=-', text, re.MULTILINE)
        prefix = ''
        if pressure:
            warm = re.search(r'^AFTER WARM BUF=\[(.*?)\]', text, re.MULTILINE)
            assert warm, text
            prefix = warm[1]
        assert document[-1] == prefix + '仮名仮名仮名仮名', document
        ordinary = [int(value) for value in re.findall(r'KEYLAT token=[A-Za-z] .*?total_us=(\d+)', text)]
        assert ordinary and max(ordinary) < 20000, ordinary
        if args.inline:
            (inline / 'stop').write_text('stop')
            assert listener.wait(timeout=15) == 0
            rendered = (inline / 'emacs.log').read_text('utf-8')
            assert rendered.count('▼仮名') >= 4 and 'BUFFER_UNCHANGED=t' in rendered, rendered
            assert 'COMPOSITION START' not in text
        if pressure:
            pressure.pause()
            # Final replay includes IDs generated after the last restart phase.
            for operation, original in pressure.acks.items():
                for _ in range(2):
                    assert deployment.request(f'LOCAL LEARN {operation} 00304b00306a 004eee00540d') == original
        deployment.stop()
        if pressure:
            pressure.finish()
        print(f'PASS same-client bundle cycle inline={int(args.inline)} clients={args.clients} L_dictionary={int(bool(args.large_dictionary))} transitions=4 exact_document=1 real_restarts=2 ordinary_max_us={max(ordinary)}', flush=True)
    finally:
        (inline / 'stop').write_text('stop')
        try:
            if pressure:
                pressure.stop.set()
            if deployment:
                deployment.close()
                if pressure:
                    pressure.report['owned_process_leaks'] = 0
        finally:
            try:
                if pressure:
                    pressure.close()
            finally:
                if created:
                    remove_key(args.key)


if __name__ == '__main__':
    main()
