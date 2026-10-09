"""Serial exact-image HP1/echo timing and buffering reproducer (no host)."""
import argparse
import ctypes as C
from ctypes import wintypes as W
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('s6', Path(__file__).with_name('host-windows-s6.py'))
s6 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s6)

TRACE = '(nelisp--write-stdout-bytes (format "S6TIME %.9f %.9f %.9f %.9f\\n" s6-read-begin s6-read-end s6-write-begin s6-write-end))'


def source(mode, policy_source=None):
    if mode == 'stream':
        return (policy_source or ROOT/'engine/host-policy.el').read_text('utf-8')
    if mode == 'framing':
        text = (ROOT/'engine/host-policy.el').read_text('utf-8').replace(
            '(unless (getenv "DDSKK_HOST_POLICY_UNIT_ONLY") (host-policy-serve))', '')
        return text + '''
(let* ((frame (host-policy-frame "HP1 Q 0001 7 11 13 01 1 0 0 -"))
       (values (car frame)))
 (unless (and (equal (cdr frame) "0001 7 11 13 01")
              (= (aref values 4) 1) (= (aref values 5) 1)
              (equal (aref values 8) "01")) (error "HP1 copied fields")))
(host-policy-frame "HP1 Q 1 7 11 13 12 1 0 0 00af")
(host-policy-frame (concat "HP1 Q 1 7 11 13 1 1 0 0 " (make-string 2048 97)))
(dolist (bad (list "HP1 R 1 7 11 13 1 1 0 0 -"
                  "HP1 Q 1 7 11 13 0 1 0 0 -"
                  "HP1 Q 1 7 11 13 13 1 0 0 -"
                  "HP1 Q 1 7 11 13 1 -1 0 0 -"
                  "HP1 Q 1 7 11 13 1  0 0 -"
                  "HP1 Q 1 7 11 13 1 1 0 0 "
                  "HP1 Q 1 7 11 13 1 1 0 0 abc"
                  "HP1 Q 1 7 11 13 1 1 0 0 AF"
                  "HP1 Q 1 7 11 13 1 1 0 0 - extra"
                  (concat "HP1 Q 1 7 11 13 1 1 0 0 " (make-string 2050 97))
                  (make-string 4097 97)))
 (let ((rejected nil))
  (condition-case nil (host-policy-frame bad) (error (setq rejected t)))
  (unless rejected (error "HP1 invalid accepted"))))
''' + source('echo')
    if mode == 'policy':
        text = (policy_source or ROOT/'engine/host-policy.el').read_text('utf-8')
        text = '(defvar s6-read-begin 0)\n(defvar s6-read-end 0)\n(defvar s6-write-begin 0)\n(defvar s6-write-end 0)\n(defvar s6-gc-before 0)\n(defvar s6-gc-after 0)\n' + text
        text = text.replace('(let ((bytes (read-stdin-bytes 4096)))',
            '(setq s6-gc-before (nth 7 (nelisp--debug-switch 0)))\n      (setq s6-read-begin (float-time))\n      (let ((bytes (read-stdin-bytes 4096)))\n        (setq s6-read-end (float-time))')
        begin = text.index('(nelisp--write-stdout-bytes\n                   (concat')
        end = text.index('\n              (setq pending', begin)
        original = text[begin:end]
        assert original.endswith('))))'), original
        call = original[:-2]  # retain the decision/fields let closures outside
        policy_trace = TRACE.replace('%.9f\\n', '%.9f %d %d\\n').replace('s6-write-end))', 's6-write-end s6-gc-before s6-gc-after))')
        wrapped = '(progn (setq s6-write-begin (float-time)) '+call+'\n (setq s6-write-end (float-time)) (setq s6-gc-after (nth 7 (nelisp--debug-switch 0))) '+policy_trace+')))'
        return text[:begin]+wrapped+text[end:]
    if mode in ('echo', 'parse', 'match', 'split', 'validate', 'cond', 'format'):
        work = {'echo':'', 'parse':'(string-match "\\n" bytes) (split-string bytes " " t)',
                'match':'(string-match "\\n" bytes)', 'split':'(split-string bytes " " t)',
                'validate':'(let ((i 0)) (while (< i 8) (string-match "\\\\`[0-9]+\\\\\'" "123") (setq i (1+ i))))',
                'cond':'(cond ((= 1 1) (if (or (= 1 0) (= 0 1)) 1 0)) (t -1))',
                'format':'(concat "HP1 R " (mapconcat (quote identity) (list "1" "7" "11" "13" "1") " ") " " (number-to-string 0) "\\n")'}[mode]
        return '(nelisp--write-stdout-bytes "READY\\n")\n(let (bytes) (while (setq bytes (read-stdin-bytes 4096)) '+work+' (nelisp--write-stdout-bytes bytes)))\n'
    if mode == 'timed-echo':
        return '''(nelisp--write-stdout-bytes "READY\\n")
(let ((running t) s6-read-begin s6-read-end s6-write-begin s6-write-end)
 (while running
  (setq s6-read-begin (float-time))
  (let ((bytes (read-stdin-bytes 4096)))
   (setq s6-read-end (float-time))
   (if (not bytes) (setq running nil)
    (setq s6-write-begin (float-time))
    (nelisp--write-stdout-bytes bytes)
    (setq s6-write-end (float-time))
    '''+TRACE+'))))\n'
    raise ValueError(mode)


def probe(runtime, directory, mode, count, size, gc_disabled=False, policy_source=None):
    script = directory / (mode+('-gc-disabled' if gc_disabled else '')+'.el')
    # Switch 7 covers boundary GC only in this image; 6 also disarms mid-form
    # GC. This finite causal control is never used by the production policy.
    prefix = '(nelisp--debug-switch 7)\n(nelisp--debug-switch 6)\n' if gc_disabled else ''
    script.write_text(';;; -*- lexical-binding: t; -*-\n'+prefix+source(mode,policy_source), encoding='utf-8')
    job = s6.ownership.CommandJob()
    process = None
    reader = None
    chunks = queue.Queue()
    pending = bytearray()
    def read():
        while True:
            data = os.read(process.stdout.fileno(), 4096)
            chunks.put((data, time.time(), time.perf_counter()))
            if not data:
                break
    def take(length=None):
        wall = perf = 0
        while (len(pending) < length if length is not None else b'\n' not in pending):
            data, wall, perf = chunks.get(timeout=60)
            if not data:
                raise RuntimeError('EOF: '+repr(bytes(pending)))
            pending.extend(data)
        limit = length if length is not None else pending.index(10)+1
        value = bytes(pending[:limit]); del pending[:limit]
        # A response and trace may arrive in the same os.read; preserve its stamp.
        if not wall:
            wall, perf = last_stamp[0]
        else:
            last_stamp[0] = (wall, perf)
        return value, wall, perf
    last_stamp = [(0, 0)]
    rows = []
    try:
        env = dict(os.environ)
        env.pop('DDSKK_HOST_POLICY_UNIT_ONLY', None)
        env.pop('DDSKK_HOST_POLICY_TEST_PAUSE_KIND', None)
        process = subprocess.Popen([str(runtime), '--load', str(script)], cwd=ROOT,
            env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            creationflags=0x08000004)
        if not s6.ownership.api('AssignProcessToJobObject', W.BOOL, W.HANDLE, W.HANDLE)(job.handle, int(process._handle)):
            raise C.WinError(C.get_last_error())
        resume = C.WinDLL('ntdll').NtResumeProcess
        resume.argtypes, resume.restype = [W.HANDLE], W.LONG
        if resume(int(process._handle)) != 0:
            raise RuntimeError('resume failed')
        reader = threading.Thread(target=read); reader.start()
        ready = take()[0]
        assert ready == (b'HP1 READY\n' if mode in ('policy','stream') else b'READY\n'), ready
        for serial in range(1, count+1):
            if mode in ('policy','stream'):
                wire = f'HP1 Q {serial} 7 11 13 1 1 0 0 -\n'.encode()
                expected = f'HP1 R {serial} 7 11 13 1 0\n'.encode()
                if mode == 'stream' and serial > 1:
                    wire += f'HP1 Q {count+serial} 7 11 13 1 1 0 0 -\n'.encode()
                    expected += f'HP1 R {count+serial} 7 11 13 1 0\n'.encode()
            elif mode in ('parse','match','split','validate','cond','format'):
                wire = b'HP1 Q 1 7 11 13 1 1 0 0 -\n'; expected = wire
            else:
                wire = b'x'*size; expected = wire  # no newline, no EOF
            start_wall, start_perf = time.time(), time.perf_counter()
            if mode == 'stream' and serial == 1:
                process.stdin.write(wire[:9]); process.stdin.flush()
                time.sleep(.01)
                assert chunks.empty() and not pending, 'partial frame emitted reply'
                wire = wire[9:]
            process.stdin.write(wire); process.stdin.flush()
            sent_perf = time.perf_counter()
            actual, received_wall, received_perf = take(len(expected))
            assert actual == expected, actual
            row = dict(roundtrip_ms=(received_perf-start_perf)*1000,
                       python_send_ms=(sent_perf-start_perf)*1000)
            if mode in ('policy', 'timed-echo'):
                trace = take()[0].decode('ascii').split()
                assert trace[0] == 'S6TIME', trace
                a,b,c,d = map(float, trace[1:5])
                row.update(read_wakeup_ms=(b-start_wall)*1000, lisp_work_ms=(c-b)*1000,
                           write_call_ms=(d-c)*1000, delivery_from_write_ms=(received_wall-c)*1000,
                           read_call_ms=(b-a)*1000,
                           lisp_timestamps=[a,b,c,d], python_timestamps=[start_wall,received_wall])
                if len(trace) == 7:
                    row['midform_gc_before'], row['midform_gc_after'] = map(int,trace[5:])
            rows.append(row)
        process.stdin.close(); process.wait(timeout=10)
        assert process.returncode == 0, process.returncode
        result = dict(mode=mode, size=size, gc_disabled_diagnostic_only=gc_disabled,
                      script_sha256=hashlib.sha256(script.read_bytes()).hexdigest(),
                      rows=rows, distributions={
            key:s6.distribution([row[key] for row in rows]) for key in rows[0] if key.endswith('_ms')})
        if mode == 'framing':
            result.update(valid_frames=3, rejected_frames=11)
        if mode == 'stream':
            result.update(fragmented_frames=1, batched_frames=2*(count-1),
                          verified_replies=2*count-1)
        print(json.dumps({k:v for k,v in result.items() if k!='rows'}), flush=True)
        return result
    finally:
        job.close()
        if process:
            if process.poll() is None: process.kill()
            process.wait(timeout=10)
            if not process.stdin.closed: process.stdin.close()
            process.stdout.close()
        if reader:
            reader.join(10)
            assert not reader.is_alive()
        print('CLEANUP IPC diagnostic leftovers=[]', flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--runtime', required=True, type=Path)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--count', type=int, default=30)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--components', action='store_true')
    modes.add_argument('--gc-control', action='store_true')
    modes.add_argument('--framing-controls', action='store_true')
    modes.add_argument('--stream-controls', action='store_true')
    parser.add_argument('--policy-source', type=Path)
    args = parser.parse_args()
    directory = args.output_dir.resolve()
    if not directory.is_relative_to(ROOT/'build') or not 1 <= args.count <= 100:
        parser.error('worktree build output and count 1..100 required')
    directory.mkdir(parents=True, exist_ok=True)
    runtime = args.runtime.resolve(strict=True)
    identity = hashlib.sha256(runtime.read_bytes()).hexdigest()
    results = []
    try:
        if args.stream_controls:
            matrix = [('stream',32)]
        elif args.framing_controls:
            matrix = [('framing',1)]
        elif args.gc_control:
            matrix = [('policy',32),('policy',32)]
        elif args.components:
            matrix = [(mode,32) for mode in ('match','split','validate','cond','format')]
        else:
            matrix = [('echo',1),('echo',32),('echo',4096),('parse',32),
                      ('timed-echo',1),('policy',32)]
        for index,(mode,size) in enumerate(matrix):
            results.append(probe(runtime,directory,mode,args.count,size,args.gc_control and index==1,args.policy_source))
    finally:
        (directory/'results.json').write_text(json.dumps(dict(runtime_sha256=identity,
            runtime_unchanged=hashlib.sha256(runtime.read_bytes()).hexdigest()==identity,
            policy_sha256=hashlib.sha256((args.policy_source or ROOT/'engine/host-policy.el').read_bytes()).hexdigest(),
            probes=results),indent=2)+'\n',encoding='utf-8')


if __name__ == '__main__':
    main()
