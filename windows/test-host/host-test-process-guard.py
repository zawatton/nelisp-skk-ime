"""Own each serial command and its descendants before any child can run.

The anonymous kill-on-close job cannot include live IME/MCP/other sessions.
Gate failures close that same job; no process-name or stale-PID kill is used.
"""
import argparse
import base64
import ctypes as C
from ctypes import wintypes as W
import json
import re
from pathlib import Path
import subprocess
import sys
import time

IME_NAMES = {'nelisp.exe', 'ddskk-engine-host.exe', 'tsf-host.exe', 'input-rules-host.exe',
             'host-policy-sync-control.exe'}


def utf8_command(arguments):
    # CREATE_NO_WINDOW has no inherited console code page. PowerShell then
    # defaults to the system ANSI page (e.g. 932) and misdecodes nested UTF-8
    # harness output. Initialize the test shell before invoking its script.
    if Path(arguments[0]).stem.lower() not in ('pwsh', 'powershell'):
        return arguments
    position = next((i for i, value in enumerate(arguments) if value.lower() == '-file'), None)
    if position is None:
        return arguments
    if position + 1 >= len(arguments):
        raise ValueError('PowerShell -File requires a script')
    def literal(value):
        return "'" + value.replace("'", "''") + "'"
    invocation = literal(arguments[position + 1])
    for value in arguments[position + 2:]:
        invocation += ' ' + (value if re.fullmatch(r'-[A-Za-z][A-Za-z0-9_-]*', value) else literal(value))
    script = ('$global:LASTEXITCODE=0; '
              '[Console]::InputEncoding=[Text.UTF8Encoding]::new($false); '
              '[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); '
              '$OutputEncoding=[Console]::OutputEncoding; & ' + invocation +
              '; if (-not $? -and $global:LASTEXITCODE -eq 0) { exit 1 }; exit $global:LASTEXITCODE')
    encoded = base64.b64encode(script.encode('utf-16le')).decode('ascii')
    return arguments[:position] + ['-EncodedCommand', encoded]


def api(name, result, *arguments):
    function = getattr(C.WinDLL('kernel32', use_last_error=True), name)
    function.restype, function.argtypes = result, arguments
    return function


class CommandJob:
    def __init__(self):
        self.handle = api('CreateJobObjectW', W.HANDLE, W.LPVOID, W.LPCWSTR)(None, None)
        if not self.handle:
            raise C.WinError(C.get_last_error())
        info = C.create_string_buffer(144)  # x64 EXTENDED_LIMIT_INFORMATION
        C.c_uint32.from_buffer(info, 16).value = 0x2000  # KILL_ON_JOB_CLOSE
        if not api('SetInformationJobObject', W.BOOL, W.HANDLE, C.c_int, W.LPVOID, W.DWORD)(
                self.handle, 9, info, len(info)):
            self.close()
            raise C.WinError(C.get_last_error())

    def spawn(self, arguments):
        # No child runs (or can respawn) until ownership has been established.
        process = subprocess.Popen(utf8_command(arguments), stdout=sys.stdout, stderr=sys.stderr,
                                   creationflags=0x08000004)
        try:
            if not api('AssignProcessToJobObject', W.BOOL, W.HANDLE, W.HANDLE)(
                    self.handle, int(process._handle)):
                raise C.WinError(C.get_last_error())
            resume = C.WinDLL('ntdll').NtResumeProcess
            resume.argtypes, resume.restype = [W.HANDLE], W.LONG
            if resume(int(process._handle)) != 0:
                raise RuntimeError('owned command resume failed')
            return process
        except BaseException:
            process.kill()
            process.wait()
            raise

    def members(self):
        capacity = 64
        while True:
            data = C.create_string_buffer(8 + capacity * C.sizeof(C.c_size_t))
            if api('QueryInformationJobObject', W.BOOL, W.HANDLE, C.c_int,
                   W.LPVOID, W.DWORD, W.LPVOID)(self.handle, 3, data, len(data), None):
                count = C.c_uint32.from_buffer(data, 4).value
                alive = []
                for pid in (C.c_size_t * count).from_buffer(data, 8):
                    process = api('OpenProcess', W.HANDLE, W.DWORD, W.BOOL, W.DWORD)(
                        0x101000, False, pid)
                    if not process:
                        if C.get_last_error() != 87:  # exited, no longer in PID table
                            alive.append(pid)
                        continue
                    try:
                        member = W.BOOL()
                        if not api('IsProcessInJob', W.BOOL, W.HANDLE, W.HANDLE,
                                   C.POINTER(W.BOOL))(process, self.handle, C.byref(member)):
                            raise C.WinError(C.get_last_error())
                        # The job list may retain an exited process while a
                        # parent still holds its handle. It is not a leftover.
                        if member.value and api('WaitForSingleObject', W.DWORD, W.HANDLE,
                                                W.DWORD)(process, 0) == 258:
                            alive.append(pid)
                    finally:
                        api('CloseHandle', W.BOOL, W.HANDLE)(process)
                return alive
            if C.get_last_error() != 234:
                raise C.WinError(C.get_last_error())
            capacity *= 2

    def cleanup(self, names=None):
        # Windows can retain this command's conhost briefly after the runner
        # exits. This is teardown only, outside every callback/timing gate.
        settle = time.monotonic() + 1
        while self.members() and time.monotonic() < settle:
            time.sleep(.01)
        remaining = self.members()
        guarded = []
        for pid in remaining:
            try:
                if names is None or Path(command_line(pid)[0]).name.lower() in names:
                    guarded.append(pid)
            except Exception:
                # This PID is positively job-owned, never an unrelated user
                # process. Always close the job even if image inspection fails.
                guarded.append(pid)
        if remaining and not api('TerminateJobObject', W.BOOL, W.HANDLE, W.UINT)(self.handle, 1):
            raise C.WinError(C.get_last_error())
        deadline = time.monotonic() + 5
        while self.members() and time.monotonic() < deadline:
            time.sleep(.01)
        leftovers = self.members()
        print('GUARD owned-command cleanup ' + json.dumps(
            dict(remaining=remaining, guarded=guarded, terminated=remaining, leftovers=leftovers)), flush=True)
        if leftovers:
            raise RuntimeError(f'owned command processes did not exit: {leftovers}')
        return guarded

    def close(self):
        if self.handle:
            api('CloseHandle', W.BOOL, W.HANDLE)(self.handle)
            self.handle = None


def run_command(arguments, cleanup, names=IME_NAMES):
    job = CommandJob()
    process = None
    try:
        process = job.spawn(arguments)
        code = process.wait()
        remaining = job.cleanup(names)
        if remaining and not cleanup:
            print(f'Refuse next stack: command-owned processes remained: {remaining}', flush=True)
            return code or 1
        return code
    finally:
        job.close()
        if process is not None:
            process.wait(timeout=10)


def external_script(arguments, root):
    # All test stacks load engine/host-policy.el, engine/ddskk-engine-stdio.el
    # or framework/nelisp-ime-stdio.el. Other applications can use the same
    # nelisp.exe (for example an absolute bootstrap script outside the tree).
    scripts = [value for value in arguments[1:] if value.lower().endswith('.el')]
    return bool(scripts) and all(Path(value).is_absolute() and
                                not Path(value).resolve().is_relative_to(root)
                                for value in scripts)


def command_line(pid):
    kernel = C.WinDLL('kernel32', use_last_error=True)
    kernel.OpenProcess.argtypes = [W.DWORD, W.BOOL, W.DWORD]
    kernel.OpenProcess.restype = W.HANDLE
    kernel.CloseHandle.argtypes = [W.HANDLE]
    handle = kernel.OpenProcess(0x1000, False, pid)
    if not handle:
        raise C.WinError(C.get_last_error())
    query = C.WinDLL('ntdll').NtQueryInformationProcess
    query.argtypes = [W.HANDLE, W.ULONG, W.LPVOID, W.ULONG, C.POINTER(W.ULONG)]
    class UnicodeString(C.Structure):
        _fields_ = [('length', W.USHORT), ('capacity', W.USHORT), ('buffer', W.LPVOID)]
    try:
        size = W.ULONG()
        query(handle, 60, None, 0, C.byref(size))
        if size.value < C.sizeof(UnicodeString):
            raise RuntimeError('command line size unavailable')
        buffer = C.create_string_buffer(size.value)
        if query(handle, 60, buffer, len(buffer), C.byref(size)) != 0:
            raise RuntimeError('command line unavailable')
        value = UnicodeString.from_buffer(buffer)
        text = C.wstring_at(value.buffer, value.length // 2)
        shell = C.WinDLL('shell32')
        shell.CommandLineToArgvW.argtypes = [W.LPCWSTR, C.POINTER(C.c_int)]
        shell.CommandLineToArgvW.restype = C.POINTER(W.LPWSTR)
        count = C.c_int()
        argv = shell.CommandLineToArgvW(text, C.byref(count))
        if not argv:
            raise RuntimeError('command line parse failed')
        try:
            return [argv[i] for i in range(count.value)]
        finally:
            kernel.LocalFree.argtypes = [W.HANDLE]
            kernel.LocalFree(C.cast(argv, W.HANDLE))
    finally:
        kernel.CloseHandle(handle)


def main():
    if len(sys.argv) > 1 and sys.argv[1] == 'run':
        parser = argparse.ArgumentParser()
        parser.add_argument('--root', type=Path, required=True)
        parser.add_argument('--cleanup', action='store_true')
        parser.add_argument('command', nargs=argparse.REMAINDER)
        args = parser.parse_args(sys.argv[2:])
        command = args.command[1:] if args.command[:1] == ['--'] else args.command
        if not command or not args.root.resolve().is_dir():
            parser.error('existing worktree root and command required')
        sys.exit(run_command(command, args.cleanup))
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('pids', nargs='*', type=int)
    args = parser.parse_args()
    root = args.root.resolve()
    remaining, external = [], []
    for pid in args.pids:
        try:
            argv = command_line(pid)
            executable = Path(argv[0]).resolve()
            # Legacy read-only inspection is positive executable attribution,
            # never "unknown means ours". Serial gates use job ownership above,
            # which also covers orphaned children and excludes other sessions.
            ours = executable.name.lower() in ('ddskk-engine-host.exe', 'tsf-host.exe') and \
                executable.is_relative_to(root / 'build')
            unrelated = not ours
        except Exception:
            unrelated = True
        (external if unrelated else remaining).append(pid)
    print(json.dumps(dict(remaining=remaining, external=external)))


if __name__ == '__main__':
    main()
