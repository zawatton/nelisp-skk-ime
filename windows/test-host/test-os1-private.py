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
import socket
import struct
import threading
import re


class DnsFixture:
    """Real per-query DNS blackhole on an exclusively owned loopback socket.

    Unsupported custom-server APIs, busy UDP/53, or early NXDOMAIN fail the
    probe rather than silently substituting a sleep or a completed lookup.
    """
    def __init__(self):
        self.sockets = []
        self.threads = []
        self.stop = threading.Event()
        self.answer = threading.Event()
        self.packets = 0
        self.errors = []

    def start(self):
        try:
            dns = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self.sockets.append(dns)
            dns.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
            dns.bind(('127.0.0.2', 53))
            tcp = socket.socket()
            self.sockets.append(tcp)
            tcp.bind(('127.0.0.1', 0))
            tcp.listen(4)
            self.port = tcp.getsockname()[1]
            for sock, task in ((dns, self.dns), (tcp, self.server)):
                sock.settimeout(.05)
                thread = threading.Thread(target=task, args=(sock,))
                self.threads.append(thread)
                thread.start()
            return self
        except BaseException:
            self.close()
            raise

    def dns(self, sock):
        try:
            while not self.stop.is_set():
                try: data, peer = sock.recvfrom(4096)
                except socket.timeout: continue
                self.packets += 1
                if not self.answer.is_set(): continue  # no response at all
                assert len(data) >= 17 and data[4:6] == b'\0\1', 'unexpected DNS query'
                end = 12
                while data[end]: end += 1+data[end]
                end += 1
                kind, cls = struct.unpack('!HH', data[end:end+4])
                question = data[12:end+4]
                # Preserve question/transaction; answer A with TTL=0, AAAA with
                # authoritative NODATA. No DNS cache entry survives this probe.
                answer = (b'\xc0\x0c'+struct.pack('!HHIH', 1, 1, 0, 4)+socket.inet_aton('127.0.0.1')) if kind == 1 and cls == 1 else b''
                response = data[:2]+struct.pack('!HHHHH', 0x8580, 1, bool(answer), 0, 0)+question+answer
                sock.sendto(response, peer)
        except BaseException as error:
            if not self.stop.is_set(): self.errors.append(repr(error))

    def server(self, sock):
        try:
            while not self.stop.is_set():
                try: client, _ = sock.accept()
                except socket.timeout: continue
                with client:
                    client.settimeout(.5)
                    data = b''
                    while b' ' not in data and len(data) < 4096:
                        part = client.recv(4096)
                        if not part: break
                        data += part
                    assert data.startswith(b'1') and data.endswith(b' '), data
                    client.sendall(b'1/S6-DNS/\n')
        except BaseException as error:
            if not self.stop.is_set(): self.errors.append(repr(error))

    def close(self):
        self.stop.set()
        for sock in self.sockets: sock.close()
        for thread in self.threads:
            thread.join(timeout=1)
            assert not thread.is_alive(), 'fixture thread left behind'


def dns_checks(host, fixture):
    log = host.run/'host.log'
    def text(): return log.read_text('utf-8', errors='replace')
    def until(predicate, seconds=2):
        deadline = time.monotonic()+seconds
        while time.monotonic() < deadline:
            value = text()
            assert not fixture.errors, fixture.errors
            if predicate(value): return value
            time.sleep(.001)
        raise AssertionError('DNS evidence timeout: '+text())
    pipe = t.Pipe(host.name)
    try:
        assert pipe.request(b'LOCAL SERVER 000078000078000078 -') == b'SERVER PENDING'
        first = until(lambda value: 'os1-dns-exit' in value)
        assert fixture.packets > 0, 'no real DNS packet reached blackhole'
        assert 'os1-dns-pending' in first
        assert 'os1-dns-cancel reason=deadline status=0' in first, first
        assert 'os1-dns-exit status=10111' in first, first  # WSA_E_CANCELLED
        drains = re.findall(r'os1-dns-drained ms=([0-9.]+)', first)
        assert len(drains) == 1 and float(drains[0]) <= 1000, drains
        exits = re.findall(r'os1-dns-exit status=10111 ms=([0-9.]+)', first)
        assert len(exits) == 1 and float(exits[0]) <= 1000, exits

        fixture.answer.set()
        assert pipe.request(b'LOCAL SERVER 000079000079000079 -') == b'SERVER PENDING'
        deadline = time.monotonic()+5
        reply = b''
        while time.monotonic() < deadline:
            reply = pipe.request(b'LOCAL SERVER 000079000079000079 -')
            if reply != b'SERVER PENDING': break
            time.sleep(.005)
        assert reply == b'SERVER 1/S6-DNS/', reply
        assert 'os1-dns-exit status=0' in text(), 'next resolver request failed'

        fixture.answer.clear()
        packets = fixture.packets
        pending_count = text().count('os1-dns-pending')
        assert pipe.request(b'LOCAL SERVER 00007a00007a00007a -') == b'SERVER PENDING'
        until(lambda value: value.count('os1-dns-pending') > pending_count and fixture.packets > packets)
        before = time.perf_counter()
        assert pipe.request(b'SHUTDOWN') == b'OK'
        ack_ms = (time.perf_counter()-before)*1000
    finally:
        pipe.close()
    host.process.wait(timeout=5)  # existing private-soak ceiling, unchanged
    elapsed = (time.perf_counter()-before)*1000
    assert elapsed <= 5000, f'shutdown exceeded existing ceiling: {elapsed} ms'
    final = text()
    assert 'os1-dns-cancel reason=shutdown status=0' in final, final
    assert final.count('os1-dns-exit status=10111') == 2, final
    drains = list(map(float, re.findall(r'os1-dns-drained ms=([0-9.]+)', final)))
    assert len(drains) == 2 and max(drains) <= 1000, drains
    assert not fixture.errors, fixture.errors
    return dict(real_dns_packets=fixture.packets, cancelled_status=10111,
                deadline_cancelled=True, shutdown_cancelled=True, next_reply_exact=True,
                cancel_drain_ms=drains, shutdown_ack_ms=ack_ms, shutdown_ms=elapsed,
                shutdown_within_5s=elapsed <= 5000,
                resolver_events=[line for line in final.splitlines() if 'os1-dns-' in line])

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
    fixture = None
    if args.mode == 'dictionary':
        if not args.dictionary: parser.error('--dictionary required')
        host.env['DDSKK_DICTIONARY_FILES'] = str(args.dictionary.resolve(strict=True))
    started = time.perf_counter()
    report = dict(mode=args.mode, runtime_sha256=hashlib.sha256(Path(args.runtime).read_bytes()).hexdigest(),
                  host_sha256=hashlib.sha256(Path(args.host).read_bytes()).hexdigest(), status='incomplete')
    try:
        if args.mode == 'dns':
            fixture = DnsFixture().start()
            host.env.update(DDSKK_SKKSERV_ENABLE='1', DDSKK_SKKSERV_HOST=uuid.uuid4().hex+'.s6.test.',
                            DDSKK_SKKSERV_PORT=str(fixture.port), DDSKK_SKKSERV_START_COMMAND='',
                            NATIVEIME_TEST_OS1_DNS_TRACE='1', NATIVEIME_TEST_OS1_DNS_SERVER='127.0.0.2')
        host.start()
        if args.mode == 'pipe':
            report.update(pipe_checks(host),status='PASS')
            print('PASS OS1 private pipe '+json.dumps(report), flush=True)
        elif args.mode == 'dns':
            report.update(dns_checks(host, fixture), status='PASS')
            print('PASS OS1 DNS cancellation '+json.dumps(report)+' artifacts='+str(host.run), flush=True)
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
    except BaseException as error:
        report.update(status='FAIL', failure=repr(error))
        raise
    finally:
        try:
            host.stop()
        finally:
            if fixture: fixture.close()
        (host.run/'result.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
        print('CLEANUP OS1 private host reaped; job closed artifacts='+str(host.run),flush=True)


if __name__ == '__main__':
    main()
