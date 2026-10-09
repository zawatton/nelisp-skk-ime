"""Content/encoding routing controls using supplied read-only L variants."""
import argparse
import importlib.util
from pathlib import Path
import sys
import tempfile

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('dictionary', Path(__file__).with_name('large-dictionary.py'))
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--euc', type=Path, required=True)
    parser.add_argument('--utf8', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    selected = d.select_utf8(args.euc, args.utf8)
    assert selected['source']['encoding'] == 'euc-jp'
    assert selected['utf8']['path'] == str(args.utf8.resolve())
    assert d.select_utf8(args.utf8)['utf8']['encoding'] == 'utf-8'
    checks = 2
    with tempfile.TemporaryDirectory(prefix='dictionary-controls-', dir=root/'build/w') as name:
        temporary = Path(name).resolve()
        assert temporary.is_relative_to(root/'build/w')
        copy = temporary/'arbitrary-name.data'
        copy.write_bytes(args.utf8.read_bytes())
        assert d.select_utf8(copy)['utf8']['entries'] == selected['utf8']['entries']
        checks += 1
        small = temporary/'SKK-JISYO.L'
        small.write_bytes((root/'windows/test-host/data/behavior-jisyo.utf8').read_bytes())
        tiny = temporary/'tiny'
        tiny.write_text(';; Large size dictionary for SKK system\n;; okuri-ari entries.\n;; okuri-nasi entries.\nかな /仮名/\n',encoding='utf-8')
        invalid = temporary/'invalid'
        invalid.write_bytes(b'\xff')
        for path in (small,tiny,invalid):
            try: d.inspect(path)
            except ValueError: checks += 1
            else: raise AssertionError('invalid dictionary accepted: '+str(path))
        lines = copy.read_text('utf-8').splitlines()
        for index,line in enumerate(lines):
            if line and not line.startswith(';'):
                lines[index] = 'changed-reading '+line.partition(' ')[2]
                break
        mismatch = temporary/'mismatch.utf8'
        mismatch.write_text('\n'.join(lines)+'\n',encoding='utf-8')
        try: d.select_utf8(args.euc,mismatch)
        except ValueError: checks += 1
        else: raise AssertionError('mismatched UTF-8 copy accepted')
    print(f'PASS L dictionary controls checks={checks} entries={selected["utf8"]["entries"]} negative=4 no_runtime=1')


if __name__ == '__main__':
    main()
