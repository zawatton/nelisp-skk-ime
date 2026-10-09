"""Real private-host dictionary/ACL/client-overlapped probes; no HKCU writes."""
import argparse
import ctypes as C
from ctypes import wintypes as W
import importlib.util
import json
import hashlib
from pathlib import Path
import sys
import subprocess
import time
import uuid

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('transport', Path(__file__).with_name('host-contracts.py'))
t = importlib.util.module_from_spec(spec)
spec.loader.exec_module(t)


def adv(name, result, *arguments):
    function = getattr(C.WinDLL('advapi32', use_last_error=True), name)
    function.restype, function.argtypes = result, arguments
    return function


def pipe_checks(host):
    pipe = t.Pipe(host.name)
    try:
        assert pipe.request(b'ENGINE CURRENT') == b'ENGINE ddskk'
        ov = t.Overlapped(event=t.event(None, True, False, None))
        buffer = C.create_string_buffer(8192)
        count = W.DWORD()
        try:
            assert not t.read(pipe.handle, buffer, len(buffer), C.byref(count), C.byref(ov))
            assert C.get_last_error() == 997, 'read was not pending'
            begin = time.perf_counter()
            assert t.cancel(pipe.handle, C.byref(ov)), C.get_last_error()
            assert t.wait(ov.event, 1000) == 0, 'cancel did not signal'
            assert not t.result(pipe.handle, C.byref(ov), C.byref(count), False)
            assert C.get_last_error() == 995, 'cancel did not drain ERROR_OPERATION_ABORTED'
            cancelled_ms = (time.perf_counter()-begin)*1000
            assert pipe.request(b'ENGINE CURRENT') == b'ENGINE ddskk', 'cancel consumed next reply'
        finally:
            t.close(ov.event)
    finally:
        pipe.close()

    # Existing default ACL is observed, not claimed to be least-privilege.
    # Alter only this already-owned private endpoint, and restore in finally.
    handle = t.create(host.name, 0xC0060000, 0, None, 3, 0x40000000, None)
    if handle == t.INVALID:
        raise C.WinError(C.get_last_error())
    original, original_dacl, denied = W.LPVOID(), W.LPVOID(), W.LPVOID()
    changed = False
    free = t.api('LocalFree', W.HANDLE, W.HANDLE)
    get_security = adv('GetSecurityInfo', W.DWORD, W.HANDLE, C.c_int, W.DWORD,
                       W.LPVOID, W.LPVOID, C.POINTER(W.LPVOID), W.LPVOID, C.POINTER(W.LPVOID))
    set_security = adv('SetSecurityInfo', W.DWORD, W.HANDLE, C.c_int, W.DWORD,
                       W.LPVOID, W.LPVOID, W.LPVOID, W.LPVOID)
    def sddl(descriptor):
        text = W.LPWSTR()
        convert = adv('ConvertSecurityDescriptorToStringSecurityDescriptorW', W.BOOL,
                      W.LPVOID, W.DWORD, W.DWORD, C.POINTER(W.LPWSTR), W.LPVOID)
        if not convert(descriptor, 1, 4, C.byref(text), None):
            raise C.WinError(C.get_last_error())
        try:
            return text.value
        finally:
            free(C.cast(text, W.HANDLE))
    try:
        code = get_security(handle, 6, 4, None, None, C.byref(original_dacl), None, C.byref(original))
        if code: raise C.WinError(code)
        original_sddl = sddl(original)
        convert = adv('ConvertStringSecurityDescriptorToSecurityDescriptorW', W.BOOL,
                      W.LPCWSTR, W.DWORD, C.POINTER(W.LPVOID), W.LPVOID)
        assert convert('D:(D;;0x3;;;WD)(A;;GA;;;WD)', 1, C.byref(denied), None)
        present, defaulted, denied_dacl = W.BOOL(), W.BOOL(), W.LPVOID()
        assert adv('GetSecurityDescriptorDacl', W.BOOL, W.LPVOID, C.POINTER(W.BOOL),
                   C.POINTER(W.LPVOID), C.POINTER(W.BOOL))(
                       denied, C.byref(present), C.byref(denied_dacl), C.byref(defaulted))
        code = set_security(handle, 6, 4, None, None, denied_dacl, None)
        if code: raise C.WinError(code)
        changed = True
        rejected = t.create(host.name, 0xC0000000, 0, None, 3, 0x40000000, None)
        error = C.get_last_error()
        if rejected != t.INVALID:
            t.close(rejected)
            raise AssertionError('ACL denial did not reject a new connection')
        assert error == 5, f'expected access denied, got {error}'
    finally:
        if changed:
            code = set_security(handle, 6, 4, None, None, original_dacl, None)
            if code: raise C.WinError(code)
        for descriptor in (original, denied):
            if descriptor: free(descriptor)
        t.close(handle)
    after = t.Pipe(host.name)
    try:
        assert after.request(b'ENGINE CURRENT') == b'ENGINE ddskk', 'restored ACL unusable'
    finally:
        after.close()
    return dict(default_dacl=original_sddl, acl_denied_error=5, acl_restored=True,
                pending_read_error=997, cancelled_read_error=995,
                cancel_ms=cancelled_ms, next_reply_exact=True,
                scope='client overlapped read; default low-IL/server-cancel compatibility unqualified')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--runtime', required=True)
    parser.add_argument('--host', required=True)
    parser.add_argument('--build-dir', default='build/w')
    parser.add_argument('--cold-load-sleep-sec', type=int, default=45)
    parser.add_argument('--engine', default='ddskk')
    parser.add_argument('--mode', choices=['pipe','dictionary','dns'], default='pipe')
    parser.add_argument('--dictionary', type=Path)
    args = parser.parse_args()
    host = t.Host(args)
    host.env.update({f'DDSKK_HOST_POLICY_{name}':'1' for name in
                    ('SOURCES','CACHE','RESTART','PUBLICATION','LEARNING')})
    host.env['DDSKK_HOST_POLICY_SHADOW'] = '0'
    if args.mode == 'dns':
        host.env.update(DDSKK_SKKSERV_ENABLE='1', DDSKK_SKKSERV_HOST=uuid.uuid4().hex+'.s6.invalid',
                        DDSKK_SKKSERV_PORT='9', DDSKK_SKKSERV_START_COMMAND='', NATIVEIME_TEST_OS1_DNS_TRACE='1')
    if args.mode == 'dictionary':
        if not args.dictionary: parser.error('--dictionary required')
        host.env['DDSKK_DICTIONARY_FILES'] = str(args.dictionary.resolve(strict=True))
    started = time.perf_counter()
    report = dict(mode=args.mode, runtime_sha256=hashlib.sha256(Path(args.runtime).read_bytes()).hexdigest(),
                  host_sha256=hashlib.sha256(Path(args.host).read_bytes()).hexdigest(), status='incomplete')
    try:
        host.start()
        if args.mode == 'pipe':
            report.update(pipe_checks(host),status='PASS')
            print('PASS OS1 private pipe '+json.dumps(report), flush=True)
        elif args.mode == 'dns':
            pipe = t.Pipe(host.name)
            try:
                reply = pipe.request(b'LOCAL SERVER 000078000078000078 -')
                deadline = time.monotonic()+5
                log = host.run/'host.log'
                while time.monotonic()<deadline:
                    text = log.read_text('utf-8',errors='replace')
                    if 'os1-dns-enter' in text: break
                    time.sleep(.001)
                assert 'os1-dns-enter' in text, 'network worker did not enter real resolver'
                pending = 'os1-dns-exit' not in text
                before = time.perf_counter()
                assert pipe.request(b'SHUTDOWN') == b'OK'
                ack_ms = (time.perf_counter()-before)*1000
            finally:
                pipe.close()
            bounded = True
            try:
                host.process.wait(timeout=5)  # unchanged existing private-soak shutdown ceiling
            except subprocess.TimeoutExpired:
                bounded = False
            text = log.read_text('utf-8',errors='replace')
            report.update(pending_at_shutdown=pending, shutdown_ack_ms=ack_ms,
                          shutdown_ms=(time.perf_counter()-before)*1000, shutdown_within_5s=bounded,
                          resolver_events=[line for line in text.splitlines() if 'os1-dns-' in line],
                          reply=reply.decode('ascii'), status='INCOMPLETE DNS cancellation',
                          reason='synchronous getaddrinfo has no production cancellation token; completion is not cancellation')
            print('INCOMPLETE OS1 DNS '+json.dumps(report)+' artifacts='+str(host.run),flush=True)
            raise RuntimeError(report['reason'])
        else:
            # Same post-cold-load publication deadline as run-harness.ps1.
            deadline = time.monotonic()+30
            while time.monotonic()<deadline:
                error = (host.run/'stderr.log').read_text('utf-8',errors='replace')
                manifests = list(host.run.rglob('current'))
                if 'invalid UTF8' in error or manifests:
                    break
                time.sleep(.1)
            report.update(dictionary=str(args.dictionary), current_count=len(manifests),
                          invalid_utf8='invalid UTF8' in error,
                          observed_ms=(time.perf_counter()-started)*1000,
                          status='PASS' if manifests and 'invalid UTF8' not in error else 'FAIL')
            print('OS1 dictionary '+json.dumps(report)+' artifacts='+str(host.run),flush=True)
            assert manifests and not report['invalid_utf8'], 'native UTF-8 publication rejected dictionary'
    finally:
        host.stop()
        (host.run/'result.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
        print('CLEANUP OS1 private host reaped; job closed artifacts='+str(host.run),flush=True)


if __name__ == '__main__':
    main()
