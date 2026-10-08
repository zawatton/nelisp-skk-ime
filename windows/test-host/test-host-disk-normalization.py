"""Portable config normalization must still reject changes to stable bytes."""
import base64
import hashlib
import json
from pathlib import Path
import runpy
import struct
import tempfile
import unittest

disk = runpy.run_path(str(Path(__file__).with_name('host-disk-contracts.py')))
ROOT = disk['ROOT']
fixture = json.loads((ROOT / 'docs/contracts/native-disk-v1.json').read_bytes())['files']
base = base64.b64decode(fixture['base']['bytes_base64'])
overlay = base64.b64decode(fixture['overlay']['bytes_base64'])
plan = disk['input_plan'](ROOT / 'docs/contracts/native-disk-inputs-v1.json')
frozen = disk['index_config'](base, plan, captured=True)


def sealed(data):
    data = bytearray(data)
    data[112:144] = bytes(32)
    data[112:144] = hashlib.sha256(data).digest()
    return bytes(data)


def native_config(root, sources, data=base):
    header = struct.unpack('<10Q', data[:80])
    material = str(header[5]).encode() + data[header[8]:]
    for source in sources:
        path = root / source['relative_path']
        material += str(path).encode() + hashlib.sha256(path.read_bytes()).digest()
    return hashlib.sha256(material).digest()


def relocated(data, digest):
    result = bytearray(data); result[80:112] = digest
    return sealed(result)


class Normalization(unittest.TestCase):
    def test_two_checkout_roots_preserve_all_stable_bytes(self):
        with tempfile.TemporaryDirectory(dir=ROOT / 'build/w') as directory:
            for name in ('checkout-a', 'checkout-b'):
                root = Path(directory) / name
                path = root / plan['sources'][0]['relative_path']; path.parent.mkdir(parents=True)
                path.write_bytes((ROOT / plan['sources'][0]['relative_path']).read_bytes())
                digest = native_config(root, plan['sources'])
                actual_base = relocated(base, digest)
                config = disk['index_config'](actual_base, plan, root=root)
                self.assertEqual(disk['normal']('base', base, frozen), disk['normal']('base', actual_base, config))
                self.assertEqual(disk['normal']('overlay', overlay, frozen),
                                 disk['normal']('overlay', relocated(overlay, digest), config))

    def test_forged_config_with_valid_checksum_is_rejected(self):
        for data in (base, overlay):
            forged = bytearray(data); forged[80] ^= 1
            with self.assertRaisesRegex(ValueError, 'config digest'):
                disk['canonical_index'](sealed(forged), frozen)
            if data == base:
                with self.assertRaisesRegex(ValueError, 'config digest'):
                    disk['index_config'](sealed(forged), plan)

    def test_candidate_revision_capabilities_and_rules_are_not_erased(self):
        for offset in (56, 40, 199):  # revision, capabilities, UTF-8 candidate payload
            changed = bytearray(overlay); changed[offset] ^= 1
            self.assertNotEqual(disk['canonical_index'](overlay, frozen),
                                disk['canonical_index'](sealed(changed), frozen))
        changed = bytearray(base); changed[struct.unpack_from('<Q', base, 64)[0] + 14] ^= 1
        self.assertNotEqual(disk['canonical_index'](base, frozen),
                            disk['canonical_index'](sealed(changed), frozen))

    def test_source_comments_cannot_change_unnoticed(self):
        with tempfile.TemporaryDirectory(dir=ROOT / 'build/w') as directory:
            root = Path(directory)
            path = root / plan['sources'][0]['relative_path']; path.parent.mkdir(parents=True)
            path.write_bytes((ROOT / plan['sources'][0]['relative_path']).read_bytes() + b';; changed\n')
            with self.assertRaisesRegex(ValueError, 'pinned input plan'):
                disk['index_config'](relocated(base, native_config(root, plan['sources'])), plan, root=root)

    def test_source_order_and_logical_names_remain_significant(self):
        with tempfile.TemporaryDirectory(dir=ROOT / 'build/w') as directory:
            root = Path(directory)
            sources = []
            for name in ('one.utf8', 'two.utf8'):
                content = (ROOT / plan['sources'][0]['relative_path']).read_bytes()
                (root / name).write_bytes(content)
                sources.append(dict(relative_path=name, sha256=hashlib.sha256(content).hexdigest()))
            configs = []
            for ordered in (sources, sources[::-1]):
                digest = native_config(root, ordered)
                configs.append(disk['index_config'](relocated(base, digest), dict(plan, sources=ordered), root=root)[1])
            self.assertNotEqual(*configs)
            self.assertNotEqual(configs[0], frozen[1])

    def test_learning_metadata_is_byte_exact(self):
        for name in ('user.jisyo', 'user.jisyo.eg2-provider-watermark', 'pending-outbox.bin'):
            data = base64.b64decode(fixture[name]['bytes_base64'])
            self.assertEqual(disk['normal'](name, data), data)
            self.assertNotEqual(disk['normal'](name, data), disk['normal'](name, data + b'changed'))

    def test_explicit_capture_preserves_lf_and_crlf(self):
        with tempfile.TemporaryDirectory(dir=ROOT / 'build/w') as directory:
            for eol in (b'\n', b'\r\n'):
                path = Path(directory) / 'capture.json'; path.write_bytes(b'old' + eol)
                disk['write_exact'](path, 'new\nnext\n')
                self.assertEqual(path.read_bytes(), b'new' + eol + b'next' + eol)


if __name__ == '__main__':
    unittest.main(verbosity=2)
