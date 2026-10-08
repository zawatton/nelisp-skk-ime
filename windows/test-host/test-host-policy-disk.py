"""Compare off/on private disk bytes using the unchanged S2 normalizers.

This extra equivalence diagnostic never replaces frozen-fixture integrity/replay.
"""
import argparse
import importlib.util
from pathlib import Path
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('disk', Path(__file__).with_name('host-disk-contracts.py'))
disk = importlib.util.module_from_spec(spec); spec.loader.exec_module(disk)
parser = argparse.ArgumentParser()
parser.add_argument('--off-run', type=Path, required=True)
parser.add_argument('--on-run', type=Path, required=True)
args = parser.parse_args()
off, on = disk.collect(args.off_run), disk.collect(args.on_run)
assert off.keys() == on.keys(), 'disk file sets differ'
for name in off:
    assert disk.normal(name, off[name]) == disk.normal(name, on[name]), name
print(f'PASS off/on disk comparison files={len(off)} S2 normalizers unchanged; frozen-hash replay remains separate')
