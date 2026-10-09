"""Offline integrity check; also exercises a failing checksum control."""
import base64
import hashlib
import json
from pathlib import Path
import runpy

ROOT = Path(__file__).resolve().parents[2]
disk = runpy.run_path(str(Path(__file__).with_name('host-disk-contracts.py')))
canonical = disk['canonical_index']


def sha(data):
    return hashlib.sha256(data).hexdigest()


def checked_response(record):
    data = base64.b64decode(record['response_base64'], validate=True)
    if sha(data) != record['response_sha256']:
        raise ValueError('response integrity')
    if sha(record['request'].encode()) != record['request_sha256']:
        raise ValueError('request integrity')
    if record['normalize'] not in ('', 'pid'):
        raise ValueError('unknown normalization')
    return data


contracts = ROOT / 'docs/contracts'
plan = disk['input_plan'](contracts / 'native-disk-inputs-v1.json')
spec = json.loads((contracts / 'engine-host-v1.json').read_text())
assert spec['contract_version'] == 1 and len(spec['public_requests']) >= 35
count = 0
for name in ('native-v1', 'native-legacy-v1', 'native-disk-v1'):
    path = contracts / (name + '.json')
    assert sha(path.read_bytes()) == path.with_suffix('.sha256').read_text().split()[0], name
    fixture = json.loads(path.read_text())
    assert fixture['version'] == 1
    for item in fixture.get('records', []):
        checked_response(item)
        count += 1
    for name, item in fixture.get('files', {}).items():
        data = base64.b64decode(item['bytes_base64'], validate=True)
        assert sha(data) == item['sha256']
        if name in ('base', 'overlay'):
            canonical(data)
    if 'files' in fixture:
        base = base64.b64decode(fixture['files']['base']['bytes_base64'], validate=True)
        config = disk['index_config'](base, plan, captured=True)
        canonical(base64.b64decode(fixture['files']['overlay']['bytes_base64'], validate=True), config)
policy_fixture = contracts / 'host-policy-inputs-v2.json'
assert sha(policy_fixture.read_bytes()) == policy_fixture.with_suffix('.sha256').read_text().split()[0]
sk1_fixture = contracts / 'host-policy-sk1-extra-v1.json'
assert sha(sk1_fixture.read_bytes()) == sk1_fixture.with_suffix('.sha256').read_text().split()[0]
record = json.loads((contracts / 'native-v1.json').read_text())['records'][0]
record['response_base64'] = base64.b64encode(b'wrong').decode()
try:
    checked_response(record)
except ValueError:
    pass
else:
    raise AssertionError('bad response control passed')
inventory = json.loads((contracts / 'source-inventory-v2.json').read_text())
assert inventory['version'] == 2 and inventory['text_hash'] == 'sha256-crlf-to-lf'
for name, frozen in inventory['source_sha256'].items():
    data = (ROOT / name).read_bytes()
    normalized = data.replace(b'\r\n', b'\n')
    assert sha(normalized) == frozen, 'source changed: ' + name
    assert sha(normalized.replace(b'\n', b'\r\n').replace(b'\r\n', b'\n')) == frozen
    assert sha(normalized + b'changed-source') != frozen, 'source corruption control passed'

print(f'PASS integrity transcripts=2 responses={count} disk_files={len(fixture["files"])} sources={len(inventory["source_sha256"])} bad_response_rejected=1 eol_controls=2 source_corruption_rejected=1')
