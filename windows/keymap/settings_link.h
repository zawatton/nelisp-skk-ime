// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <windows.h>

#include <string>
namespace keymap_settings {
inline std::wstring base() {
  DWORD n = GetEnvironmentVariableW(L"NATIVEIME_REGISTRY_KEY", nullptr, 0);
  if (!n) return L"Software\\NativeIME";
  std::wstring value(n, 0);
  GetEnvironmentVariableW(L"NATIVEIME_REGISTRY_KEY", value.data(), n);
  value.resize(n - 1);
  return value;
}
inline std::wstring value(const wchar_t* name) {
  HKEY key;
  std::wstring out;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, (base() + L"\\Keymap").c_str(), 0,
                    KEY_READ, &key) == ERROR_SUCCESS) {
    DWORD bytes = 0, type = 0;
    if (RegQueryValueExW(key, name, nullptr, &type, nullptr, &bytes) ==
            ERROR_SUCCESS &&
        type == REG_SZ && bytes < 65536) {
      out.resize(bytes / sizeof(wchar_t) + 1);
      RegQueryValueExW(key, name, nullptr, &type,
                       reinterpret_cast<BYTE*>(out.data()), &bytes);
      out.resize(wcsnlen(out.c_str(), out.size()));
    }
    RegCloseKey(key);
  }
  return out;
}
inline void open(HWND owner) {
  auto exe = value(L"Executable");
  if (exe.empty() ||
      GetFileAttributesW(exe.c_str()) == INVALID_FILE_ATTRIBUTES) {
    MessageBoxW(owner,
                L"キー置き換えエディターが見つかりません。nelisp-ime-keymap "
                L"をインストールしてください。",
                L"Native IME 設定", MB_OK | MB_ICONINFORMATION);
    return;
  }
  std::wstring command = L"\"" + exe + L"\" --editor";
  STARTUPINFOW si{sizeof(si)};
  PROCESS_INFORMATION pi{};
  if (CreateProcessW(exe.c_str(), command.data(), nullptr, nullptr, FALSE,
                     CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi)) {
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
  } else
    MessageBoxW(owner, L"キー置き換えエディターを起動できませんでした。",
                L"Native IME 設定", MB_OK | MB_ICONERROR);
}
}  // namespace keymap_settings
