"""Exercise the interpreted policy's actual stdio; starts no host or stack."""
import argparse
import os
from pathlib import Path
import queue
import struct
import subprocess
import threading
import time
ROOT = Path(__file__).resolve().parents[2]
HEADER = struct.Struct('<4sIHHQQQQII')
FENCES = (0x80ff81e3, 0xffe38281, 0x01020304, 0x7fffffffffffffff)


def frame(op, fields):
    raw = [s.encode('utf-8') for s in fields]
    body = b''.join(struct.pack('<I', len(s)) + s for s in raw)
    return HEADER.pack(b'HN3Q', 44 + len(body), op, 0, *FENCES,
                       len(raw), sum(map(len, raw))) + body


class Child:
    def __init__(self, runtime):
        self.process = subprocess.Popen([runtime, '--load', 'engine/host-policy.el'], cwd=ROOT,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.inbox = queue.Queue()
        self.pending = bytearray()
        self.errors = bytearray()
        def read():
            while part := self.process.stdout.read(1):
                self.inbox.put(part)
            self.inbox.put(None)
        def stderr():
            self.errors.extend(self.process.stderr.read())
        self.reader = threading.Thread(target=read, daemon=True)
        self.error_reader = threading.Thread(target=stderr, daemon=True)
        self.reader.start(); self.error_reader.start()
        assert self.take(16, 60) == b'HP2 READY HN3=1\n', 'capability negotiation'

    def take(self, size, timeout=15):
        end = time.monotonic() + timeout
        while len(self.pending) < size:
            try:
                part = self.inbox.get(timeout=max(.001, end-time.monotonic()))
            except queue.Empty:
                raise AssertionError('policy stdout deadline')
            if part is None:
                self.error_reader.join(1)
                raise AssertionError('policy exited: ' + self.errors.decode('utf-8', errors='replace'))
            self.pending.extend(part)
        result = bytes(self.pending[:size]); del self.pending[:size]
        return result

    def request(self, op, fields, fragmented=False):
        wire = frame(op, fields)
        start = time.monotonic()
        if fragmented:
            for byte in wire:
                self.process.stdin.write(bytes([byte])); self.process.stdin.flush()
        else:
            self.process.stdin.write(wire); self.process.stdin.flush()
        header = self.take(52)
        magic, length, actual, status, *rest = HEADER.unpack(header)
        assert (magic, actual, status, tuple(rest[:4])) == (b'HN3R', op, 0, FENCES)
        body = self.take(length-44)
        at = 0; raw = []
        for _ in range(rest[4]):
            n, = struct.unpack_from('<I', body, at); at += 4
            raw.append(body[at:at+n]); at += n
        assert at == len(body) and sum(map(len, raw)) == rest[5], 'byte lengths'
        return [s.decode('utf-8') for s in raw], (time.monotonic()-start)*1000

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.kill(); self.process.wait(timeout=3)
        self.reader.join(1); self.error_reader.join(1)
        self.process.stdout.close(); self.process.stderr.close()


def main(runtime):
    child = Child(runtime)
    times = []
    try:
        # Non-ASCII paths and high binary length/count/fence bytes reproduce the
        # coordinator's startup snapshot, without registry or engine access.
        snapshot = ['0','','1','0','0','0','','0','2',
                    'NELISP_IME_ENGINE','ddskk','5',
                    'DDSKK_DICTIONARY_FILES','/仮名/' + 'x'*180,'184','7']
        for name in ('Engine','DictionaryFiles','SkkServEnable','SkkServPort',
                     'LocalConversion','Learning','NativeEntry'):
            snapshot += [name,'0','0','0','','0']
        result, ms = child.request(5, snapshot)
        assert result[:5] == ['ddskk','load','ddskk','0','1']
        times.append(ms)
        for op, fields, expected in (
            (1, ['/仮名;one/[し/skip/]/','/仮名;two/次/'], ['/仮名;one/次/']),
            (2, ['/仮名/','/仮名;note/次/'], ['1/仮名/仮名;note/次/']),
            (3, ['1/仮名/次/'], ['LIST ("仮名" "次" )']),
            (4, ['a"\\\n'], ['"a\\"\\\\\\012"'])):
            result, ms = child.request(op, fields)
            assert result == expected, (op, result, expected)
            times.append(ms)
        hp2 = b'HP2Q           ! !!   \n'
        child.process.stdin.write(hp2); child.process.stdin.flush()
        legacy = child.take(19)
        assert legacy.startswith(b'HP2R') and legacy.endswith(b'\n')
        result, ms = child.request(1, ['/仮名/'], fragmented=True)
        assert result == ['/仮名/']; times.append(ms)
        # Saturate binary length words above 127 and include NUL/control data.
        result, _ = child.request(4, ['仮名'*100 + '\x00\n'])
        assert result[0].endswith('\\000\\012"')
        assert max(times[:4]) < 200, ('merge/startup service deadline', times)
        # A field-local invalid UTF-8 octet must still fail after normalization.
        bad = bytearray(frame(1, ['x'])); bad[-1] = 128
        child.process.stdin.write(bad); child.process.stdin.flush()
        child.process.wait(timeout=2); child.error_reader.join(1)
        assert child.process.returncode != 0 and b'HN3 UTF-8' in child.errors
        print(f'PASS HN3 interpreted child operations=5 HP2=unchanged fragmentation=bytewise '
              f'invalid_utf8=rejected max_service_ms={max(times[:4]):.1f} stacks=0')
    finally:
        child.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--runtime', default=os.environ.get('HN_IME_RUNTIME'))
    args = parser.parse_args()
    if not args.runtime:
        parser.error('--runtime or HN_IME_RUNTIME required')
    main(args.runtime)
