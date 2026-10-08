"""Byte-exact disk fixtures from a completed private native-host run.

Only generation/PID identifiers are normalized, together with size/checksum
fields derived from the normalized BASE basename. Config digest stays exact.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import struct

ROOT = Path(__file__).resolve().parents[2]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def canonical_index(data):
    if len(data) < 144:
        raise ValueError('short index')
    header = list(struct.unpack('<10Q', data[:80]))
    magic, schema, size, count, generation, caps, bad, revision, offset, length = header
    if magic != 0x32495844464C4B53 or schema != 4 or size != len(data) or size > 256 * 1024 * 1024:
        raise ValueError('index header')
    checked = bytearray(data)
    checked[112:144] = bytes(32)
    if hashlib.sha256(checked).digest() != data[112:144]:
        raise ValueError('index checksum')
    if count > (size - 144) // 48 or caps > 7:
        raise ValueError('index bounds')
    following, previous = 144 + 48 * count, b''
    for n in range(count):
        k, kb, u, ub, s, sb = struct.unpack_from('<6Q', data, 144 + n * 48)
        if k != following or u != k + kb or s != u + ub or s + sb > size:
            raise ValueError('record layout')
        key = data[k:k+kb]
        if not key or (n and key <= previous):
            raise ValueError('key order')
        for value in (key, data[u:u+ub], data[s:s+sb]):
            value.decode('utf-8', errors='strict')
        following, previous = s + sb, key
    if offset != following or length != size - offset:
        raise ValueError('metadata bounds')
    metadata = data[offset:]
    if metadata.startswith(b'BASE '):
        if not re.fullmatch(rb'BASE generation-[0-9]+-[0-9]+\.index', metadata):
            raise ValueError('BASE identity')
        metadata = b'BASE generation-0-0.index'
    header[2], header[4], header[9] = offset + len(metadata), 0, len(metadata)
    normalized = bytearray(struct.pack('<10Q', *header) + data[80:112] + bytes(32) + data[144:offset] + metadata)
    normalized[112:144] = hashlib.sha256(normalized).digest()
    return bytes(normalized)


def collect(run):
    manifests = list(run.rglob('current'))
    if len(manifests) != 1:
        raise ValueError('expected one private current manifest')
    manifest = manifests[0]
    name = manifest.read_bytes()
    if not re.fullmatch(rb'overlay-[0-9]+-[0-9]+\.index', name):
        raise ValueError('current format')
    overlay = (manifest.parent / name.decode()).read_bytes()
    offset = struct.unpack_from('<Q', overlay, 64)[0]
    base_name = overlay[offset:]
    if not re.fullmatch(rb'BASE generation-[0-9]+-[0-9]+\.index', base_name):
        raise ValueError('base link')
    files = dict(current=name, overlay=overlay,
                 base=(manifest.parent / base_name[5:].decode()).read_bytes())
    for suffix in ('', '.eg2-provider-watermark', '.eg2-outbox', '.journal'):
        path = run / ('user.jisyo' + suffix)
        if path.exists():
            files[path.name] = path.read_bytes()
    pending = run / 'pending-outbox.bin'
    if pending.exists():
        files[pending.name] = pending.read_bytes()
    return files


def normal(name, data):
    if name in ('base', 'overlay'):
        return canonical_index(data)
    if name == 'current':
        if not re.fullmatch(rb'overlay-[0-9]+-[0-9]+\.index', data):
            raise ValueError('manifest')
        return b'overlay-0-0.index'
    return data


def main():
    p = argparse.ArgumentParser()
    p.add_argument('mode', choices=['capture', 'replay'])
    p.add_argument('--run', type=Path, required=True)
    p.add_argument('--fixture', type=Path, default=ROOT / 'docs/contracts/native-disk-v1.json')
    args = p.parse_args()
    files = collect(args.run)
    # Negative control: malformed bytes really fail the structural/hash validator.
    broken = bytearray(files['overlay'])
    broken[-1] ^= 1
    try:
        canonical_index(broken)
    except ValueError:
        pass
    else:
        raise AssertionError('corrupt index negative control accepted')
    if args.mode == 'capture':
        records = {name: dict(bytes_base64=base64.b64encode(data).decode(), sha256=sha(data))
                   for name, data in files.items()}
        args.fixture.write_text(json.dumps(dict(version=1, files=records), indent=2) + '\n')
        args.fixture.with_suffix('.sha256').write_text(sha(args.fixture.read_bytes()) + '  ' + args.fixture.name + '\n')
    else:
        if sha(args.fixture.read_bytes()) != args.fixture.with_suffix('.sha256').read_text().split()[0]:
            raise AssertionError('disk fixture hash')
        frozen = json.loads(args.fixture.read_text())['files']
        if set(files) != set(frozen):
            raise AssertionError('disk file set')
        for name, item in frozen.items():
            data = base64.b64decode(item['bytes_base64'], validate=True)
            if sha(data) != item['sha256'] or normal(name, data) != normal(name, files[name]):
                raise AssertionError('disk mismatch: ' + name)
    print(f'PASS disk mode={args.mode} files={len(files)} corrupt_index_rejected=1')


if __name__ == '__main__':
    main()
