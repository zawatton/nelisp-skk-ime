#pragma once

#include <windows.h>
#include <string>

// Shared by the in-process service and host. Private tests must set this
// before starting either process; never fall back to the live key in tests.
inline std::wstring NativeImeRegistryKey() {
  wchar_t path[1024]{};
  const DWORD length = GetEnvironmentVariableW(
      L"NATIVEIME_REGISTRY_KEY", path, static_cast<DWORD>(_countof(path)));
  return length > 0 && length < _countof(path)
      ? std::wstring(path) : std::wstring(L"Software\\NativeIME");
}
