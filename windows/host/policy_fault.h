// Private S4 durability boundary rendezvous. Never enabled by live settings.
#pragma once
#include <windows.h>
#include <string>
#include <cstdio>
namespace ddskk::host_fault {
inline void Point(const wchar_t* point) {
  wchar_t registry[1024]{}, selected[64]{}, root[32768]{}, diagnostics[8]{};
  if (GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", diagnostics, 8) != 1 || diagnostics[0] != L'1' ||
      !GetEnvironmentVariableW(L"NATIVEIME_REGISTRY_KEY", registry, 1024) ||
      !std::wstring(registry).starts_with(L"Software\\NativeIME-test-") ||
      !GetEnvironmentVariableW(L"NATIVEIME_TEST_HOST_POINT", selected, 64) || selected != std::wstring(point) ||
      !GetEnvironmentVariableW(L"NATIVEIME_TEST_HOST_POINT_ROOT", root, 32768)) return;
  const auto marker = std::wstring(root) + L"." + point;
  HANDLE file = CreateFileW(marker.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr,
      CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  CloseHandle(file);
  std::fwprintf(stderr, L"S4_POINT %ls\n", point); std::fflush(stderr);
  const auto deadline = GetTickCount64() + 10000;
  while (GetTickCount64() < deadline && GetFileAttributesW(marker.c_str()) != INVALID_FILE_ATTRIBUTES) Sleep(10);
}
}
