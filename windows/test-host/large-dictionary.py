"""Identify an SKK L dictionary by decoded content; select qualified UTF-8 bytes."""
import argparse
import hashlib
import json
from pathlib import Path


def inspect(path):
    path = Path(path).resolve(strict=True)
    raw = path.read_bytes()
    try:
        text = raw.decode('utf-8-sig', errors='strict')
        encoding = 'utf-8'
    except UnicodeDecodeError:
        text = raw.decode('euc_jp', errors='strict')
        encoding = 'euc-jp'
    lines = text.splitlines()
    # Converted copies may retain a stale euc-jp coding cookie. Detect bytes,
    # not the cookie or filename. Both section markers and L header are required.
    if not any(line.startswith(';; Large size dictionary for SKK system') for line in lines[:100]):
        raise ValueError('missing SKK L header')
    if not all(marker in lines for marker in (';; okuri-ari entries.', ';; okuri-nasi entries.')):
        raise ValueError('missing SKK dictionary sections')
    keys = []
    for line in lines:
        if not line or line.startswith(';'):
            continue
        key, separator, value = line.partition(' ')
        if not separator or not key or not value.startswith('/') or not value.endswith('/'):
            raise ValueError('invalid SKK entry format')
        keys.append(key)
    if len(keys) < 100000:
        raise ValueError(f'not an L-sized dictionary: entries={len(keys)} minimum=100000')
    return dict(path=str(path), encoding=encoding, entries=len(keys),
                sha256=hashlib.sha256(raw).hexdigest(),
                keys_sha256=hashlib.sha256('\n'.join(keys).encode('utf-8')).hexdigest())


def select_utf8(path, utf8_copy=None):
    original = inspect(path)
    if original['encoding'] == 'utf-8':
        selected = original
    else:
        # Prefer the existing, already-qualified copy; never transcode a fixture
        # silently or rewrite the user's dictionaries.
        selected = inspect(utf8_copy or (str(Path(path)) + '.utf8'))
        if selected['encoding'] != 'utf-8':
            raise ValueError('local-index gates require a strict UTF-8 L dictionary')
        if (selected['entries'], selected['keys_sha256']) != (original['entries'], original['keys_sha256']):
            raise ValueError('UTF-8 copy has different ordered readings from the EUC L dictionary')
    return dict(source=original, utf8=selected,
                routes=dict(bundle=selected['path'], local_index=selected['path']))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--dictionary', type=Path, required=True)
    parser.add_argument('--utf8-copy', type=Path)
    args = parser.parse_args()
    print(json.dumps(select_utf8(args.dictionary, args.utf8_copy)))
