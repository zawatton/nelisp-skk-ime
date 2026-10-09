"""Read-only attribution for new IME-named processes after a serial gate.

Uninspectable processes remain failures. Only a verified executable or loaded
Elisp script outside this worktree is excluded; no process is terminated.
"""
import argparse
import ctypes as C
from ctypes import wintypes as W
import json
from pathlib import Path


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
            unrelated = (executable.name.lower() in ('ddskk-engine-host.exe', 'tsf-host.exe') and
                         not executable.is_relative_to(root)) or external_script(argv, root)
        except Exception:
            unrelated = False
        (external if unrelated else remaining).append(pid)
    print(json.dumps(dict(remaining=remaining, external=external)))


if __name__ == '__main__':
    main()
