"""Validate the production inline checker, including the reported leaked reading."""
import importlib.util
from pathlib import Path
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('inline_preedit', Path(__file__).with_name('test-inline-preedit.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
expected = [('RET', 'て愛'), ('OKURI', 'て愛て書く'),
            ('FOLLOW', 'て愛て書くて愛すと'),
            ('OKURI-FOLLOW', 'て愛て書くて愛すとて書くすと'),
            ('EXHAUST', 'て愛て書くて愛すとて書くすとて愛'),
            ('END', 'て愛て書くて愛すとて書くすとて愛')]
text = ''.join(f'AFTER {label} BUF=[{word}] SEL=0 COMP=-\n' for label, word in expected)
module.verify_registration_document(text)
broken = [text.split('AFTER END')[0], text + text.splitlines()[0] + '\n',
          text.replace('て愛て書く', 'て愛ぱぱぷて書く')]
if len(sys.argv) > 1:
    broken.append(Path(sys.argv[1]).read_text(encoding='utf-8'))
for fixture in broken:
    try:
        module.verify_registration_document(fixture)
    except AssertionError:
        continue
    raise AssertionError('Checker accepted missing/duplicate checkpoint or leaked reading')
print(f'PASS inline registration checker: 6 checkpoints, {len(broken)} negative controls')
callback = 'KEYLAT token=s test_us=1000 down_us=500 total_us=1500 claimed=1 direct=0\n'
phases = '\n'.join([
    'PHASE name=key-test-receipt seq=1 path=registration us=0',
    'PHASE name=key-test-return seq=1 path=registration us=1000',
    'PHASE name=key-receipt seq=1 path=key us=1100',
    'PHASE name=key-return seq=1 path=registration-queue us=1500',
    'PHASE name=engine-lookup-request seq=2 path=engine us=2000',
    'PHASE name=engine-lookup-start seq=2 path=engine us=2200',
    'PHASE name=engine-lookup-end seq=2 path=engine us=78000',
    'PHASE name=registration-inline-start seq=2 path=pump us=78010',
    'PHASE name=registration-inline-end seq=2 path=pump us=78020'])
assert module.registration_timing_report(callback, phases) == [1500]
for fixture in ('', phases + '\nPHASE name=key-connect-start seq=1 path=engine us=500'):
    try:
        module.registration_timing_report(callback, fixture)
    except AssertionError:
        continue
    raise AssertionError('Timing reporter accepted missing phases or callback provider probe')
preview = ('\nPHASE name=provider-preview-start seq=3 path=engine-worker us=79000'
           '\nPHASE name=provider-preview-end seq=3 path=engine-worker us=154000'
           '\nPHASE name=provider-preview-ui-start seq=3 path=pump us=154100'
           '\nPHASE name=provider-preview-ui-end seq=3 path=pump us=154200'
           '\nPHASE name=provider-dispatch-start seq=3 path=key us=1500'
           '\nPHASE name=provider-dispatch-end seq=3 path=key us=1800')
assert module.registration_timing_report(callback, phases + preview) == [1500]
try:
    module.registration_timing_report(callback, phases + preview.replace('path=engine-worker', 'path=key'))
except AssertionError:
    pass
else:
    raise AssertionError('Reporter accepted provider preview on the key callback')
print('PASS registration timing reporter: 8 phase pairs, 3 negative controls')

