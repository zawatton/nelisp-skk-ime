"""Serial exact-image GC/debt observation; remote memory is read, never written."""
import argparse
import ctypes as C
from ctypes import wintypes as W
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import queue
import struct
import subprocess
import sys
import threading
import time

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('resources', Path(__file__).with_name('host-windows-s6.py'))
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)
# Read-only native telemetry layout of the supplied image, validated by hash,
# PE section bounds and runtime invariants before any measurement is accepted.
IMAGE = '3fb43697a8bf01e10bc993c468365489ef98a30d5acbe05206f9e9faefdde3db'
GC = 57616+4194304+96+176+64+56+40+1040+8
LOOP = 80+4194304
ALLOC = 57616+4194304+96+176+64


class Telemetry:
    def __init__(self, runtime, process):
        data = runtime.read_bytes()
        assert hashlib.sha256(data).hexdigest() == IMAGE, 'unqualified telemetry layout for changed image'
        pe = struct.unpack_from('<I', data, 60)[0]
        count = struct.unpack_from('<H', data, pe+6)[0]
        optional = struct.unpack_from('<H', data, pe+20)[0]
        sections = pe+24+optional
        found = []
        for i in range(count):
            offset = sections+40*i
            if data[offset:offset+8].rstrip(b'\0') == b'.data':
                size, address = struct.unpack_from('<II', data, offset+8)
                assert GC+64 <= size
                found.append(address)
        assert len(found) == 1
        psapi = C.WinDLL('psapi', use_last_error=True)
        enum = psapi.EnumProcessModulesEx
        enum.argtypes, enum.restype = [W.HANDLE, C.POINTER(W.HMODULE), W.DWORD, C.POINTER(W.DWORD), W.DWORD], W.BOOL
        modules = (W.HMODULE*1024)()
        needed = W.DWORD()
        assert enum(int(process._handle), modules, C.sizeof(modules), C.byref(needed), 3)
        self.base = int(modules[0])+found[0]
        self.process = process
        self.read = r.ownership.api('ReadProcessMemory', W.BOOL, W.HANDLE, W.LPCVOID,
                                    W.LPVOID, C.c_size_t, C.POINTER(C.c_size_t))

    def words(self, address, count):
        buffer = (C.c_uint64*count)()
        size = C.c_size_t()
        if not self.read(int(self.process._handle), address, buffer, C.sizeof(buffer), C.byref(size)):
            raise C.WinError(C.get_last_error())
        assert size.value == C.sizeof(buffer)
        return list(buffer)

    def snapshot(self):
        deadline = time.monotonic()+2
        while True:
            loop = self.words(self.base+LOOP, 6)
            gc = self.words(self.base+GC, 7)
            check = self.words(self.base+LOOP, 6)
            # Sweep clears LIVE before recounting it. Remote reads are not an
            # atomic snapshot: never validate or report this transient state.
            if not loop[3] and not check[3] and gc[2] > 0: break
            assert time.monotonic() < deadline, 'collector failed to complete'
            time.sleep(.001)
        alloc = self.words(self.base+ALLOC, 7)
        arena_base = self.words(self.base, 1)[0]
        arena = self.words(arena_base, 100)
        assert gc[5:7] == [0, 0], 'GC floor/percentage overridden'
        assert loop[1] == 1 and arena[20] == 0, 'GC disabled'
        assert gc[1] >= 16*1024*1024 and gc[2] > 0, ('unexpected GC statistics', gc)
        assert gc[1] == max(16*1024*1024, gc[2]*3), ('debt limit/live mismatch', gc)
        return dict(stamp=time.perf_counter(), debt=gc[0], limit=gc[1], live=gc[2],
                    collections=gc[3], allocated=gc[4]+gc[0], midform=loop[4],
                    collecting=loop[3], growth_limit=loop[5], reserved=arena[91],
                    bucket=alloc[1], linear=alloc[2], bump=alloc[3])

    def settled(self):
        deadline = time.monotonic()+2
        previous = self.snapshot()
        while time.monotonic() < deadline:
            time.sleep(.001)
            now = self.snapshot()
            if not now['collecting'] and now['allocated'] == previous['allocated']:
                return now
            previous = now
        raise AssertionError('runtime did not settle between requests')


def source(args):
    text = (args.policy_source or ROOT/'engine/host-policy.el').read_text('utf-8')
    prefix = '(nelisp--debug-switch 24)\n'
    prefix += '(dolist (name (quote (garbage-collect read-stdin-bytes read-stdin-bytes-into read-stdin-into-buffer nelisp--read-stdin-bytes-into))) (nelisp--write-stdout-bytes (format "S6CAP %s %s\\n" name (fboundp name))))\n'
    if args.discover:
        prefix += '(if (fboundp (quote mapatoms)) (mapatoms (lambda (name) (when (and (fboundp name) (string-match "stdin\\\\|read.*bytes" (symbol-name name))) (nelisp--write-stdout-bytes (format "S6INPUT %s\\n" name))))) (nelisp--write-stdout-bytes "S6INPUT enumeration-unavailable\\n"))\n'
    if args.heap_mib:
        prefix += f'(defvar s6-retained (make-string {args.heap_mib*1024*1024} 97))\n'
    if args.precollect and "(when (fboundp 'garbage-collect) (garbage-collect))" not in text:
        text = text.replace('(nelisp--write-stdout-bytes "HP1 READY\\n")',
                            '(garbage-collect)\n  (nelisp--write-stdout-bytes "HP1 READY\\n")')
    if args.mode == 'policy': return prefix+text
    if args.mode == 'collect':
        return prefix+'''(nelisp--write-stdout-bytes "HP1 READY\\n")
(let (bytes before after)
 (while (setq bytes (read-stdin-bytes 4096))
  (setq before (float-time)) (garbage-collect) (setq after (float-time))
  (nelisp--write-stdout-bytes (format "GC %.9f %.9f\\n" before after))))
'''
    work = {'empty': '', 'number': '(number-to-string 12345)',
            'slice': '(substring "HP1 R 12345 7 11 13 1 0\\n" 0 24)',
            'write': '(nelisp--write-stdout-bytes "ACK\\n")',
            'parse': '(host-policy-frame-into line (length line) numbers numeric)',
            'decision': '(host-policy-decision 1 1 0 0)',
            'reply': '(host-policy-write-reply line numbers 0 reply)'}[args.operation]
    definitions = text.replace('(unless (getenv "DDSKK_HOST_POLICY_UNIT_ONLY") (host-policy-serve))', '')
    startup_gc = '(garbage-collect)\n' if args.precollect else ''
    return prefix+definitions+f'''
(defvar line "HP1 Q 1 7 11 13 1 1 0 0 -")
(defvar numbers (make-vector 11 0))
(defvar numeric (make-vector 4097 nil))
(defvar reply (make-string 4160 32))
(aset reply 0 72) (aset reply 1 80) (aset reply 2 49)
(aset reply 3 32) (aset reply 4 82) (aset reply 5 32)
(host-policy-frame-into line (length line) numbers numeric)
{startup_gc}(nelisp--write-stdout-bytes "HP1 READY\\n")
(let (bytes) (while (setq bytes (read-stdin-bytes {args.read_limit}))
 {work} (nelisp--write-stdout-bytes "ACK\\n")))
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--count', type=int, default=1000)
    parser.add_argument('--mode', choices=['policy','component','collect'], default='policy')
    parser.add_argument('--operation', choices=['empty','number','slice','write','parse','decision','reply'], default='empty')
    parser.add_argument('--read-limit', type=int, default=4096)
    parser.add_argument('--payload-bytes', type=int, default=2)
    parser.add_argument('--precollect', action='store_true')
    parser.add_argument('--heap-mib', type=int, default=0)
    parser.add_argument('--idle-ms', type=int, default=0)
    parser.add_argument('--policy-source', type=Path)
    parser.add_argument('--discover', action='store_true')
    parser.add_argument('--continuous', action='store_true', help='no per-request telemetry reads or settling; measure uninterrupted IPC')
    args = parser.parse_args()
    assert args.output.resolve().is_relative_to(ROOT/'build')
    assert 1 <= args.count <= 1000 and 32 <= args.read_limit <= 4096 and 0 <= args.heap_mib <= 32
    assert 1 <= args.payload_bytes <= args.read_limit
    assert not args.continuous or (args.mode == 'policy' and not args.idle_ms)
    runtime = args.runtime.resolve(strict=True)
    assert hashlib.sha256(runtime.read_bytes()).hexdigest() == IMAGE
    args.output.parent.mkdir(parents=True, exist_ok=True)
    script = args.output.with_suffix('.el')
    script.write_text(';;; -*- lexical-binding: t; -*-\n'+source(args),encoding='utf-8')
    job = r.ownership.CommandJob()
    process = reader = None
    replies = queue.Queue()
    rows, discovery = [], []
    report = dict(runtime_sha256=IMAGE, mode=args.mode, operation=args.operation,
                  precollect=args.precollect, heap_mib=args.heap_mib, idle_ms=args.idle_ms,
                  read_limit=args.read_limit, payload_bytes=args.payload_bytes, rows=rows, status='incomplete',
                  continuous=args.continuous,
                  script_sha256=hashlib.sha256(script.read_bytes()).hexdigest(),
                  policy_sha256=hashlib.sha256((args.policy_source or ROOT/'engine/host-policy.el').read_bytes()).hexdigest())
    def read():
        for line in process.stdout: replies.put(line)
        replies.put(None)
    try:
        env = dict(os.environ)
        for name in ('DDSKK_HOST_POLICY_UNIT_ONLY','DDSKK_HOST_POLICY_TEST_PAUSE_KIND'): env.pop(name,None)
        started = time.perf_counter()
        process = subprocess.Popen([str(runtime),'--load',str(script.resolve())],cwd=ROOT,env=env,
            stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,creationflags=0x08000004)
        assert r.ownership.api('AssignProcessToJobObject',W.BOOL,W.HANDLE,W.HANDLE)(job.handle,int(process._handle))
        resume = C.WinDLL('ntdll').NtResumeProcess
        resume.argtypes,resume.restype=[W.HANDLE],W.LONG
        assert resume(int(process._handle)) == 0
        reader=threading.Thread(target=read); reader.start()
        while True:
            line=replies.get(timeout=60)
            if line == b'HP1 READY\n': break
            assert line is not None, discovery
            discovery.append(line.decode('utf-8',errors='replace').strip())
        report.update(startup_ms=(time.perf_counter()-started)*1000, discovery=discovery,
                      private_before=r.private_bytes(process))
        telemetry=Telemetry(runtime,process)
        initial=previous=telemetry.settled()
        report['initial']=initial
        for serial in range(1,args.count+1):
            if args.idle_ms: time.sleep(args.idle_ms/1000)
            before=previous if args.continuous else telemetry.snapshot()
            assert before['collections'] == previous['collections'], 'idle alone collected'
            wire=f'HP1 Q {serial} 7 11 13 1 1 0 0 -\n'.encode() if args.mode=='policy' else b'x'*args.payload_bytes
            begin=time.perf_counter()
            process.stdin.write(wire); process.stdin.flush()
            actual=replies.get(timeout=5)
            end=time.perf_counter()
            if args.mode=='policy': assert actual == f'HP1 R {serial} 7 11 13 1 0\n'.encode(), actual
            elif args.mode=='component':
                if args.operation=='reply': assert actual == b'HP1 R 1 7 11 13 1 0\n', actual
                else: assert actual == b'ACK\n', actual
                if args.operation in ('write','reply'): assert replies.get(timeout=5) == b'ACK\n'
            else: assert actual.startswith(b'GC '), actual
            if args.continuous:
                rows.append(dict(serial=serial,roundtrip_ms=(end-begin)*1000))
                continue
            after=telemetry.settled()
            row=dict(serial=serial,roundtrip_ms=(end-begin)*1000,
                cycle_ms=(after['stamp']-begin)*1000,
                allocated_bytes=after['allocated']-previous['allocated'],
                allocations=sum(after[k]-previous[k] for k in ('bucket','linear','bump')),
                collections=after['collections']-previous['collections'],
                midform=after['midform']-previous['midform'],before=before,after=after)
            if args.mode=='collect':
                a,b=map(float,actual.decode().split()[1:]); row['explicit_gc_ms']=(b-a)*1000
            rows.append(row); previous=after
        if args.continuous: previous=telemetry.settled()
        report.update(final=previous,private_after=r.private_bytes(process),
            collections=previous['collections']-initial['collections'],
            midform_collections=previous['midform']-initial['midform'],
            total_allocated_bytes=previous['allocated']-initial['allocated'],
            total_allocations=sum(previous[k]-initial[k] for k in ('bucket','linear','bump')),
            distributions={key:r.distribution([row[key] for row in rows])
                           for key in ('roundtrip_ms','cycle_ms','allocated_bytes','allocations') if key in rows[0]},
            explicit_gc_ms=r.distribution([row['explicit_gc_ms'] for row in rows]) if args.mode=='collect' else None,
            status='PASS measurement (budgets not asserted)')
        process.stdin.close(); process.wait(timeout=10)
        assert process.returncode == 0, process.returncode
        print(json.dumps({k:v for k,v in report.items() if k not in ('rows','initial','final')},sort_keys=True),flush=True)
    except BaseException as error:
        report.update(status='FAIL',failure=repr(error)); raise
    finally:
        job.close()
        if process:
            if process.poll() is None: process.kill()
            process.wait(timeout=10)
            if not process.stdin.closed: process.stdin.close()
            process.stdout.close()
        if reader: reader.join(10); assert not reader.is_alive()
        report['runtime_unchanged']=hashlib.sha256(runtime.read_bytes()).hexdigest()==IMAGE
        args.output.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
        print('CLEANUP GC diagnostic leftovers=[]',flush=True)


if __name__ == '__main__': main()
