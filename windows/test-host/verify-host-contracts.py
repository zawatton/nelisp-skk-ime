"""Offline integrity check; also exercises a failing checksum control."""
import base64
import hashlib
import json
from pathlib import Path
import runpy

ROOT = Path(__file__).resolve().parents[2]
canonical = runpy.run_path(str(Path(__file__).with_name('host-disk-contracts.py')))['canonical_index']


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
record = json.loads((contracts / 'native-v1.json').read_text())['records'][0]
record['response_base64'] = base64.b64encode(b'wrong').decode()
try:
    checked_response(record)
except ValueError:
    pass
else:
    raise AssertionError('bad response control passed')
inventory = json.loads((contracts / 'source-inventory-v1.json').read_text())
for name, frozen in inventory['source_sha256'].items():
    assert sha((ROOT / name).read_bytes()) == frozen, 'source changed: ' + name
print(f'PASS integrity transcripts=2 responses={count} disk_files={len(fixture["files"])} sources={len(inventory["source_sha256"])} bad_response_rejected=1')
