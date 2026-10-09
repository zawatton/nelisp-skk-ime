// Private TSF harness probe: import hooks in the two IME modules, never core edits.
#pragma once
#include <windows.h>
#include <cstdio>
#include <cstring>
#include <string>

namespace callback_io_probe {
inline thread_local bool active = false;
inline thread_local unsigned pipe_io = 0, blocking_waits = 0;
inline unsigned hooks = 0, mask = 0;
inline bool Enabled() {
  wchar_t enabled[8]{}, diagnostics[8]{}, key[1024]{};
  return GetEnvironmentVariableW(L"NATIVEIME_TEST_CALLBACK_IO_PROBE", enabled, 8) == 1 && enabled[0] == L'1' &&
      GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", diagnostics, 8) == 1 && diagnostics[0] == L'1' &&
      GetEnvironmentVariableW(L"NATIVEIME_REGISTRY_KEY", key, 1024) &&
      std::wstring(key).starts_with(L"Software\\NativeIME-test-");
}
inline HANDLE WINAPI Create(LPCWSTR path, DWORD access, DWORD share, LPSECURITY_ATTRIBUTES security,
    DWORD disposition, DWORD flags, HANDLE template_file) {
  if (active && path && std::wstring(path).starts_with(L"\\\\.\\pipe\\")) ++pipe_io;
  return ::CreateFileW(path, access, share, security, disposition, flags, template_file);
}
inline BOOL WINAPI Read(HANDLE file, LPVOID bytes, DWORD size, LPDWORD read, LPOVERLAPPED ov) {
  if (active && GetFileType(file) == FILE_TYPE_PIPE) ++pipe_io;
  return ::ReadFile(file, bytes, size, read, ov);
}
inline BOOL WINAPI Write(HANDLE file, LPCVOID bytes, DWORD size, LPDWORD written, LPOVERLAPPED ov) {
  if (active && GetFileType(file) == FILE_TYPE_PIPE) ++pipe_io;
  return ::WriteFile(file, bytes, size, written, ov);
}
inline DWORD WINAPI Wait(HANDLE handle, DWORD timeout) {
  if (active && timeout) ++blocking_waits;
  return ::WaitForSingleObject(handle, timeout);
}
inline DWORD WINAPI WaitEx(HANDLE handle, DWORD timeout, BOOL alertable) {
  if (active && timeout) ++blocking_waits;
  return ::WaitForSingleObjectEx(handle, timeout, alertable);
}
inline DWORD WINAPI WaitMany(DWORD count, const HANDLE* handles, BOOL all, DWORD timeout) {
  if (active && timeout) ++blocking_waits;
  return ::WaitForMultipleObjects(count, handles, all, timeout);
}
inline BOOL WINAPI WaitPipe(LPCWSTR name, DWORD timeout) {
  if (active) ++pipe_io;
  return ::WaitNamedPipeW(name, timeout);
}
inline BOOL WINAPI CallPipe(LPCWSTR name, LPVOID input, DWORD input_size,
    LPVOID output, DWORD output_size, LPDWORD read, DWORD timeout) {
  if (active) ++pipe_io;
  return ::CallNamedPipeW(name, input, input_size, output, output_size, read, timeout);
}
inline BOOL WINAPI Overlapped(HANDLE file, LPOVERLAPPED ov, LPDWORD transferred, BOOL wait) {
  if (active && wait && GetFileType(file) == FILE_TYPE_PIPE) ++blocking_waits;
  return ::GetOverlappedResult(file, ov, transferred, wait);
}
inline void Install(HMODULE module) {
  if (!module) return;
  auto base = reinterpret_cast<unsigned char*>(module);
  const auto dos = reinterpret_cast<IMAGE_DOS_HEADER*>(base);
  if (dos->e_magic != IMAGE_DOS_SIGNATURE) return;
  const auto nt = reinterpret_cast<IMAGE_NT_HEADERS*>(base + dos->e_lfanew);
  if (nt->Signature != IMAGE_NT_SIGNATURE) return;
  const auto rva = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress;
  if (!rva) return;
  struct Hook { const char* name; ULONG_PTR replacement; };
  const Hook replacements[] = {
    {"CreateFileW", reinterpret_cast<ULONG_PTR>(&Create)},
    {"ReadFile", reinterpret_cast<ULONG_PTR>(&Read)},
    {"WriteFile", reinterpret_cast<ULONG_PTR>(&Write)},
    {"WaitForSingleObject", reinterpret_cast<ULONG_PTR>(&Wait)},
    {"WaitForSingleObjectEx", reinterpret_cast<ULONG_PTR>(&WaitEx)},
    {"WaitForMultipleObjects", reinterpret_cast<ULONG_PTR>(&WaitMany)},
    {"WaitNamedPipeW", reinterpret_cast<ULONG_PTR>(&WaitPipe)},
    {"CallNamedPipeW", reinterpret_cast<ULONG_PTR>(&CallPipe)},
    {"GetOverlappedResult", reinterpret_cast<ULONG_PTR>(&Overlapped)}};
  for (auto descriptor = reinterpret_cast<IMAGE_IMPORT_DESCRIPTOR*>(base+rva); descriptor->Name; ++descriptor) {
    if (!descriptor->OriginalFirstThunk) continue;
    auto names = reinterpret_cast<IMAGE_THUNK_DATA*>(base+descriptor->OriginalFirstThunk);
    auto slots = reinterpret_cast<IMAGE_THUNK_DATA*>(base+descriptor->FirstThunk);
    for (; names->u1.AddressOfData; ++names, ++slots) {
      if (IMAGE_SNAP_BY_ORDINAL(names->u1.Ordinal)) continue;
      const auto name = reinterpret_cast<IMAGE_IMPORT_BY_NAME*>(base+names->u1.AddressOfData)->Name;
      unsigned index = 0;
      for (const auto& hook : replacements) {
        const unsigned bit = 1u << index++;
        if (std::strcmp(name, hook.name) || slots->u1.Function == hook.replacement) continue;
        DWORD previous = 0;
        if (!VirtualProtect(&slots->u1.Function, sizeof(ULONG_PTR), PAGE_READWRITE, &previous)) continue;
        slots->u1.Function = hook.replacement;
        DWORD ignored = 0;
        VirtualProtect(&slots->u1.Function, sizeof(ULONG_PTR), previous, &ignored);
        ++hooks; mask |= bit;
      }
    }
  }
}
struct Record {
  bool enabled = Enabled();
  explicit Record() {
    if (!enabled) return;
    Install(GetModuleHandleW(L"ddskk-ime.dll"));
    Install(GetModuleHandleW(L"ddskk-ime-core.dll"));
    pipe_io = blocking_waits = 0;
  }
  ~Record() {
    if (enabled) std::printf("CALLBACK_IO hooks=%u mask=%u pipe_io=%u blocking_waits=%u\n", hooks, mask, pipe_io, blocking_waits);
  }
};
struct Scope {
  bool prior = active;
  Scope() {
    active = Enabled();
    wchar_t control[8]{};
    if (active && GetEnvironmentVariableW(L"NATIVEIME_TEST_CALLBACK_WAIT_CONTROL", control, 8) == 1 && control[0] == L'1') {
      HANDLE event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
      Wait(event, 1); // Actual wait, through the identical probe wrapper.
      CloseHandle(event);
    }
  }
  ~Scope() { active = prior; }
};
}
