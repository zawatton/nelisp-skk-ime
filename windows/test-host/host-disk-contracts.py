"""Byte-exact disk fixtures from a completed private native-host run.

Generation/PID identifiers and verified checkout-dependent config digests are
normalized. Logical source paths/order, pinned source bytes, rules, capabilities
and all remaining stable bytes stay exact; native checksums are checked first.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import struct

ROOT = Path(__file__).resolve().parents[2]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def canonical_index(data, config=None):
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
    digest = data[80:112]
    if config is not None:
        expected, portable = config
        if digest != expected:
            raise ValueError('index config digest does not match verified inputs')
        digest = portable
    normalized = bytearray(struct.pack('<10Q', *header) + digest + bytes(32) + data[144:offset] + metadata)
    normalized[112:144] = hashlib.sha256(normalized).digest()
    return bytes(normalized)


def input_plan(path):
    if sha(path.read_bytes()) != path.with_suffix('.sha256').read_text().split()[0]:
        raise ValueError('disk input plan hash')
    plan = json.loads(path.read_bytes())
    if plan['version'] != 1 or not 1 <= len(plan['sources']) <= 64:
        raise ValueError('disk input plan')
    if not re.fullmatch('[0-9a-f]{64}', plan['captured_config_sha256']):
        raise ValueError('captured config digest')
    return plan


def index_config(base, plan, root=ROOT, captured=False):
    """Verify the native SourceStamp-independent digest; remove only root identity.

    Native Publish hashes decimal capabilities + raw RULES + ordered absolute
    source paths + binary source SHA256s. The portable form uses the pinned
    repository-relative source names instead. Captured digest provenance is
    pinned alongside the input plan; the original raw fixture remains intact.
    """
    canonical_index(base)  # Never use unvalidated offsets/config/rules.
    header = struct.unpack('<10Q', base[:80])
    rules = base[header[8]:]
    if not rules.startswith(b'RULES 1 '):
        raise ValueError('base rules')
    physical = portable = str(header[5]).encode() + rules
    for source in plan['sources']:
        relative = PurePosixPath(source['relative_path'])
        if (relative.is_absolute() or '..' in relative.parts or
                relative.as_posix() != source['relative_path'] or
                ':' in str(relative) or '\\' in str(relative)):
            raise ValueError('source logical path')
        path = root.joinpath(*relative.parts)
        digest = hashlib.sha256(path.read_bytes()).digest()
        if digest.hex() != source['sha256']:
            raise ValueError('source content differs from pinned input plan')
        physical += str(path).encode('utf-8') + digest
        portable += relative.as_posix().encode('utf-8') + digest
    expected = (bytes.fromhex(plan['captured_config_sha256']) if captured
                else hashlib.sha256(physical).digest())
    if base[80:112] != expected:
        raise ValueError('base config digest does not match verified inputs')
    return expected, hashlib.sha256(portable).digest()


def write_exact(path, text):
    """Preserve a byte-exact contract's existing EOL style on explicit capture."""
    previous = path.read_bytes() if path.exists() else b''
    eol = b'\r\n' if b'\r\n' in previous else b'\n'
    path.write_bytes(text.encode('utf-8').replace(b'\n', eol))


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


def normal(name, data, config=None):
    if name in ('base', 'overlay'):
        return canonical_index(data, config)
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
    p.add_argument('--inputs', type=Path, default=ROOT / 'docs/contracts/native-disk-inputs-v1.json')
    args = p.parse_args()
    files = collect(args.run)
    plan = input_plan(args.inputs)
    actual_config = index_config(files['base'], plan)
    canonical_index(files['overlay'], actual_config)  # Same verified base identity.
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
        write_exact(args.fixture, json.dumps(dict(version=1, files=records), indent=2) + '\n')
        write_exact(args.fixture.with_suffix('.sha256'), sha(args.fixture.read_bytes()) + '  ' + args.fixture.name + '\n')
        plan['captured_config_sha256'] = actual_config[0].hex()
        write_exact(args.inputs, json.dumps(plan, indent=2) + '\n')
        write_exact(args.inputs.with_suffix('.sha256'), sha(args.inputs.read_bytes()) + '  ' + args.inputs.name + '\n')
    else:
        if sha(args.fixture.read_bytes()) != args.fixture.with_suffix('.sha256').read_text().split()[0]:
            raise AssertionError('disk fixture hash')
        frozen = json.loads(args.fixture.read_text())['files']
        frozen_base = base64.b64decode(frozen['base']['bytes_base64'], validate=True)
        frozen_config = index_config(frozen_base, plan, captured=True)
        if set(files) != set(frozen):
            raise AssertionError('disk file set')
        for name, item in frozen.items():
            data = base64.b64decode(item['bytes_base64'], validate=True)
            if sha(data) != item['sha256'] or normal(name, data, frozen_config) != normal(name, files[name], actual_config):
                raise AssertionError('disk mismatch: ' + name)
    print(f'PASS disk mode={args.mode} files={len(files)} corrupt_index_rejected=1')


if __name__ == '__main__':
    main()
