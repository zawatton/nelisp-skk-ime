"""Collect Worker E1's recorded gate commands, tails, counts and hashes.

Usage: python report-inline-preedit.py RUNTIME_PATH
Only reads this checkout's build logs and writes build/validation/inline-e1.
"""
import hashlib
import json
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[2]
runtime = sys.argv[1]
out = root / 'build/validation/inline-e1'
out.mkdir(exist_ok=True)


def read(path):
    data = path.read_bytes()
    return data.decode('utf-16' if data.startswith((b'\xff\xfe', b'\xfe\xff')) else 'utf-8', errors='replace')


common = ('-DllPath "$PWD/build/w/Release/ddskk-ime.dll" -TsfHostExe "$PWD/build/w/Release/tsf-host.exe" '
          '-EngineHostPath "$PWD/build/w/Release/ddskk-engine-host.exe" -EngineExecutablePath ' + runtime +
          ' -RepositoryPath "$PWD" -ColdLoadSleepSec 45')
inline = ('python windows/test-host/test-inline-preedit.py --dll build/w/Release/ddskk-ime.dll '
          '--core build/w/Release/ddskk-ime-core.dll --tsf-host build/w/Release/tsf-host.exe '
          '--engine-host build/w/Release/ddskk-engine-host.exe --runtime ' + runtime)
ps = 'powershell -NoProfile -ExecutionPolicy Bypass -File windows/test-host/'
build = 'cmake --build build/w --config Release'
commands = {
    'baseline-inline-ert.log': ("$env:HOME=[Environment]::GetFolderPath('UserProfile'); emacs -Q --batch -L emacs -l emacs/nelisp-ime-emacs-inline-test.el -f ert-run-tests-batch-and-exit", None, [23, 22, 1]),
    'baseline-core.log': (ps + 'run-harness.ps1 -Script "K a SPACE WAIT3000 ENTER" -CoreDllPath "$PWD/build/w/Release/ddskk-ime-core.dll" ' + common, None, None),
    'baseline-inline-core.log': (inline + ' --artifacts build/baseline --case inline', 1, None),
    'configure-runtime.log': ('cmake -S windows -B build/w -G "Visual Studio 17 2022" -A x64 -DNELISP_EXECUTABLE=' + runtime, 0, None),
    'ctest.log': ("$env:NELISP_EXECUTABLE='" + runtime + "'; ctest --test-dir build/w -C Release --output-on-failure", 0, [8, 8, 0]),
}
for name, code in [('inline-build.log', 0), ('inline-build-final.log', 0), ('inline-build-final2.log', 1), ('inline-build-final3.log', 0)]:
    commands[name] = (build, code, None)
for name in ('ctest-runtime.log', 'ctest-final.log'):
    commands[name] = ('ctest --test-dir build/w -C Release --output-on-failure', 0, [9, 9, 0])
for name, directory, case, code in (
    ('inline-gate.log', 'inline', 'inline', 1), ('inline-gate2.log', 'inline2', 'inline', 1),
    ('inline-emacs.log', 'real-emacs', 'emacs', 1), ('inline-final.log', 'inline-final', 'inline', 1),
    ('emacs-final.log', 'emacs-final', 'emacs', 1), ('drop-final.log', 'drop-final', 'drop', 1),
    ('inline-serial.log', 'inline-serial', 'inline', 1), ('inline-confirm.log', 'inline-confirm', 'inline', 0)):
    commands[name] = (inline + ' --artifacts build/validation/' + directory + ' --case ' + case, code, [1, 1-code, code])
for case in ('missing', 'wrong', 'drop', 'emacs'):
    commands['confirm-' + case + '.log'] = (inline + ' --artifacts build/validation/confirm-' + case + ' --case ' + case, 0, [1, 1, 0])
for suffix in ('', '-final'):
    commands['ddskk-behavior' + suffix + '.log'] = (ps + 'test-ddskk-behavior.ps1 ' + common, 0, [45, 45, 0])
    commands['emacs-integration' + suffix + '.log'] = (ps + 'test-emacs-integration.ps1 ' + common, 0, [33, 33, 0])
    hot = ps + 'test-core-hot-swap.ps1 -BuildDirectory "$PWD/build/w/Release" -EngineExecutablePath ' + runtime + ' -RepositoryPath "$PWD" -ColdLoadSleepSec 45'
    if suffix:
        hot += ' -ArtifactDirectory "$PWD/build/validation/core-final"'
    commands['core-hot-swap' + suffix + '.log'] = (hot, 0, [19, 19, 0])
for name, load, counts in (
    ('stateline-ert.log', '-l framework/test/nelisp-ime-stateline-test.el -l framework/test/nelisp-ime-stateline-conformance-test.el', [31, 31, 0]),
    ('lattice-ert.log', '-l engines/lattice/test/nelisp-ime-lattice-test.el', [14, 14, 0])):
    commands[name] = ("$env:HOME=[Environment]::GetFolderPath('UserProfile'); emacs -Q --batch -L framework/src -L engines/lattice/src " + load + ' -f ert-run-tests-batch-and-exit', 0, counts)

changes = {
    'windows/src/inline_preedit.h:12': 'Core-owned background channel and bounded queue.',
    'windows/src/inline_preedit.cpp:20': 'Rate-limited discovery; nonblocking authentication, UTF-8 escaping, sequence/coalescing, CARET and loss notification (:109).',
    'windows/src/text_service.h:29': 'Channel include and episode/epoch/latest-state ownership (:129).',
    'windows/src/text_service.cpp:41': 'Cursor/message helpers; destructor (:272), dispatch (:300), deactivate (:886), per-app gate (:1498), reset/cancel (:2479/:2509), original-context settle (:2572), popup cleanup (:2687), loss/CARET events (:2969), pinned preedit and no-default-composition commit (:2998).',
    'windows/src/candidate_ui.h:56': 'Inline popup API and HWND ownership.',
    'windows/src/candidate_ui.cpp:20': 'user32 linkage; teardown (:36); nonactivating popup and actual rectangle diagnostics (:75).',
    'windows/CMakeLists.txt:8': 'Adds only inline_preedit.cpp to core sources.',
    'windows/test-host/run-harness.ps1:75': 'Inline parameters; env save (:212), private directory (:244), per-app DWORD (:250), PID coordination (:340).',
    'windows/test-host/test-inline-preedit.py:1': 'Five private integration cases, transcript/buffer/geometry/latency/cleanup assertions.',
    'windows/test-host/inline-drop-subscriber.py:1': 'Separate subscriber killed after its first PREEDIT.',
    'windows/test-host/inline-emacs-subscriber.el:1': 'Real listener/PID override and overlay reports; only CARET pixels stubbed.',
    'windows/test-host/report-inline-preedit.py:1': 'Collect recorded commands/tails/counts/hashes reproducibly.',
    'README.org:75': 'Configuration, commit choice, test command and IMM32 limitation.',
    'tools/ai/emacs-inline-preedit-progress.org:4': 'S1.1-S1.3 and S3.1 evidence/notes only.',
}
report = ['Worker E1 validation report', '',
          'Changes are unstaged. No commit/push, live deployment/registration, foreground input, live registry/pipe/user-data write or edits to other checkouts. Core ABI and shim sources are unchanged.', '',
          'Commit choice: ITfInsertAtSelection::InsertTextAtSelection with TF_IAS_NO_DEFAULT_COMPOSITION in a write edit session. SetText was observed creating temporary default compositions. Microsoft documents suppression at https://learn.microsoft.com/en-us/windows/win32/api/msctf/nf-msctf-itfinsertatselection-inserttextatselection. Private tests prove no COMPOSITION START and exact insertion once. IMM32 GCS_RESULTSTR/character delivery and graphical Windows Emacs were not tested; they remain live validation. No IMM32 window was added. Batch integration uses real TCP/authentication/overlay rendering; only caret pixel sampling is stubbed.', '',
          'Failures retained: unchanged Emacs TCP ERT 22/23 (Windows mode 438 versus 384); unchanged DLL fails no-composition check. Initial SetText commits caused default compositions. A rebuild failed LNK1104 while a harness held the DLL; two subsequent runs used the previous DLL and are not insertion-change evidence. Parallel cold runtimes timed out provider work, and 100 ms candidate waits missed async states. Final cases run serially with one-second provider candidate waits, preserving assertions. One serial run reached 24,524 us against the new test’s unchanged 20 ms bound; rerun passed at 6,343 us. Existing 25 ms ordinary-key and 20 ms Ctrl+G thresholds are unchanged.', '',
          'Initial configure: cmake -S windows -B build/w -G "Visual Studio 17 2022" -A x64; exit 0. Verbatim tool tail: -- Build files have been written to: ' + str(root/'build/w').replace('\\', '/'),
          'Initial build: ' + build + '; exit 0. Verbatim tool tail: Building Custom Rule ' + str(root/'windows/CMakeLists.txt').replace('\\', '/'),
          'Pre-existing engine_protocol.cpp C4244 warnings were not changed. No build counts were emitted.', '',
          'Changed files and locations:', '']
report.extend(f'- {location}: {description}' for location, description in changes.items())
report += ['', 'Commands omit redirection/tail/exit wrappers and expand the final argument array. Counts are [total, passed, failed]; custom counts are cases. Earliest wrappers did not capture subprocess exit (null). Tails are verbatim from recorded logs.', '']
gates = []
for name, (command, exit_code, counts) in commands.items():
    path = root/'build'/name
    body = read(path) if path.exists() else ''
    status = 'pass' if exit_code == 0 else 'fail' if exit_code == 1 else 'observed'
    if not body or (name in ('ddskk-behavior-final.log', 'emacs-integration-final.log', 'core-hot-swap-final.log') and 'PASS' not in body):
        status = 'not-finished'
    tail = '\n'.join(body.splitlines()[-8:])
    digest = hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None
    gates.append(dict(log='build/'+name, command=command, exit=exit_code, counts=counts, status=status, sha256=digest, tail=tail))
    report += [f'{name}: {status}; exit={exit_code}; counts={counts}; sha256={digest}', '', '~~~powershell', command, '~~~', '', 'Verbatim tail:', '', '~~~text', tail, '~~~', '']

observations = {}
for case, directory in [('inline', 'inline-confirm')] + [(c, 'confirm-'+c) for c in ('missing', 'wrong', 'drop', 'emacs')]:
    folder = root/'build/validation'/directory
    host = max(folder.glob('harness-*/tsf.stdout.log'), key=lambda p: p.stat().st_mtime)
    text = read(host)
    channel = folder/('inline-'+case)/'channel.log'
    item = dict(composition_starts=text.count('COMPOSITION START'), final=re.findall(r'^FINAL.*$', text, re.M)[-1], channel_lines=len(read(channel).splitlines()), host_sha256=hashlib.sha256(host.read_bytes()).hexdigest(), channel_sha256=hashlib.sha256(channel.read_bytes()).hexdigest())
    emacs = folder/'inline-emacs/emacs.log'
    if emacs.exists():
        item.update(renders=read(emacs).count('RENDER '), emacs_sha256=hashlib.sha256(emacs.read_bytes()).hexdigest())
    observations[case] = item
sources = {k.split(':')[0]: hashlib.sha256((root/k.split(':')[0]).read_bytes()).hexdigest() for k in changes if not k.startswith('tools/ai/') and (root/k.split(':')[0]).exists()}
# The ledger references this artifact's hash; excluding it avoids a circular
# hash dependency. Record the exact binaries alongside the source snapshot.
binaries = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in (root/'build/w/Release').glob('*') if p.suffix in ('.dll', '.exe')}
cleanup_file = out/'cleanup.json'
cleanup = json.loads(cleanup_file.read_text(encoding='utf-8-sig')) if cleanup_file.exists() else None
payload = dict(gates=gates, observations=observations, sources_at_report_time=sources, binaries=binaries, cleanup=cleanup, imm32_checked=False, graphical_emacs_checked=False, shim_or_abi_changed=False, committed=False)
report += ['Owned-process audit: ' + json.dumps(cleanup), '']
(out/'gate-results.json').write_text(json.dumps(payload, indent=2, ensure_ascii=False)+'\n', encoding='utf-8')
(out/'report.md').write_text('\n'.join(report)+'\n', encoding='utf-8')
print('REPORT gates=%d not_finished=%d' % (len(gates), sum(g['status']=='not-finished' for g in gates)))
