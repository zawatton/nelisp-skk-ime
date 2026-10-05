"""Private Win32 observer of the unchanged Sumi shared-caret contract.

This fixture supplies one nonactivating observer window. It is not GTK/Sumi;
it verifies the published anchor and counts actual HWNDs owned by the fixture
and tsf-host, including any unwanted core STATIC candidate window.
"""
import ctypes as c
from ctypes import wintypes as w
from pathlib import Path
import sys
import time

directory, artifacts, map_name = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
kernel = c.WinDLL('kernel32', use_last_error=True)
user = c.WinDLL('user32', use_last_error=True)
kernel.OpenFileMappingW.argtypes = [w.DWORD, w.BOOL, w.LPCWSTR]
kernel.OpenFileMappingW.restype = w.HANDLE
kernel.MapViewOfFile.argtypes = [w.HANDLE, w.DWORD, w.DWORD, w.DWORD, c.c_size_t]
kernel.MapViewOfFile.restype = c.c_void_p
kernel.UnmapViewOfFile.argtypes = [c.c_void_p]
kernel.CloseHandle.argtypes = [w.HANDLE]
user.CreateWindowExW.argtypes = [w.DWORD, w.LPCWSTR, w.LPCWSTR, w.DWORD,
                               c.c_int, c.c_int, c.c_int, c.c_int,
                               w.HWND, w.HMENU, w.HINSTANCE, c.c_void_p]
user.CreateWindowExW.restype = w.HWND
user.SetWindowPos.argtypes = [w.HWND, w.HWND, c.c_int, c.c_int, c.c_int, c.c_int, w.UINT]
user.GetWindowRect.argtypes = [w.HWND, c.POINTER(w.RECT)]
user.DestroyWindow.argtypes = [w.HWND]
user.GetWindowThreadProcessId.argtypes = [w.HWND, c.POINTER(w.DWORD)]
user.GetWindowTextW.argtypes = [w.HWND, w.LPWSTR, c.c_int]
user.GetClassNameW.argtypes = [w.HWND, w.LPWSTR, c.c_int]
user.IsWindowVisible.argtypes = [w.HWND]
callback_type = c.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)
user.EnumWindows.argtypes = [callback_type, w.LPARAM]


class Caret(c.Structure):
    _fields_ = [('sequence', w.LONG), ('rect', w.RECT), ('pid', w.DWORD)]


mapping = view = hwnd = None
pid = None
deadline = time.monotonic() + 180
seen = 0
title = 'DDSKK private candidate observer'
log = directory / 'windows.log'
try:
    while not (directory / 'stop').exists() and time.monotonic() < deadline:
        if pid is None and (directory / 'pid').exists():
            pid = int((directory / 'pid').read_text())
        if not mapping:
            mapping = kernel.OpenFileMappingW(4, False, map_name) # FILE_MAP_READ
            if mapping:
                view = kernel.MapViewOfFile(mapping, 4, 0, 0, c.sizeof(Caret))
                if not view:
                    raise c.WinError(c.get_last_error())
        logs = list(artifacts.glob('harness-*/tsf.stdout.log'))
        if not view or not logs:
            time.sleep(.02)
            continue
        host = max(logs, key=lambda p: p.stat().st_mtime)
        body = host.read_text(encoding='utf-8')
        events = body.count('INLINE_CANDIDATE_ANCHOR ')
        if events <= seen:
            time.sleep(.02)
            continue
        seen = events
        before = Caret.from_address(view).sequence
        snapshot = Caret.from_buffer_copy(c.string_at(view, c.sizeof(Caret)))
        after = Caret.from_address(view).sequence
        if not before or before & 1 or before != after or snapshot.pid != pid:
            continue
        if not hwnd:
            hwnd = user.CreateWindowExW(0x08000080, 'STATIC', title,
                0x80800000, 0, 0, 160, 28, None, None, None, None)
            if not hwnd:
                raise c.WinError(c.get_last_error())
        # Existing Sumi adds its unchanged four-pixel gap below rect.bottom.
        x, y = snapshot.rect.left, snapshot.rect.bottom + 4
        if not user.SetWindowPos(hwnd, w.HWND(-1), x, y, 160, 28, 0x0050):
            raise c.WinError(c.get_last_error())
        visible = []

        @callback_type
        def count(window, _):
            owner = w.DWORD()
            user.GetWindowThreadProcessId(window, c.byref(owner))
            if owner.value not in (pid, kernel.GetCurrentProcessId()) or not user.IsWindowVisible(window):
                return True
            name, klass = c.create_unicode_buffer(256), c.create_unicode_buffer(64)
            user.GetWindowTextW(window, name, 256)
            user.GetClassNameW(window, klass, 64)
            if name.value == title or (klass.value == 'Static' and name.value.startswith('▶ ')):
                visible.append(window)
            return True

        user.EnumWindows(count, 0)
        actual = w.RECT()
        user.GetWindowRect(hwnd, c.byref(actual))
        with log.open('a', encoding='utf-8') as stream:
            stream.write(f'CANDIDATE_WINDOWS visible={len(visible)} core_extra={len(visible)-1} '
                         f'x={actual.left} y={actual.top} anchor_x={snapshot.rect.left} '
                         f'anchor_y={snapshot.rect.top} height={snapshot.rect.bottom-snapshot.rect.top}\n')
        assert len(visible) == 1, visible
        assert (actual.left, actual.top) == (321, 483), (actual.left, actual.top)
        time.sleep(.02)
finally:
    if hwnd:
        user.DestroyWindow(hwnd)
    if view:
        kernel.UnmapViewOfFile(view)
    if mapping:
        kernel.CloseHandle(mapping)
