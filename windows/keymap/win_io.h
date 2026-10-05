// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <windows.h>
#include <shlobj.h>

#include <filesystem>
#include <string>
#include <vector>

#include "config.h"
namespace keymap {
inline constexpr wchar_t kCaptureProperty[] = L"NelispImeKeymapCapture";
inline constexpr UINT kCaptureReleaseMessage = WM_APP + 4;

inline std::wstring env(const wchar_t* name) {
  DWORD n = GetEnvironmentVariableW(name, nullptr, 0);
  if (!n) return {};
  std::wstring s(n, L'\0');
  GetEnvironmentVariableW(name, s.data(), n);
  s.resize(n - 1);
  return s;
}
inline std::wstring settingsKey() {
  auto s = env(L"NATIVEIME_REGISTRY_KEY");
  return (s.empty() ? L"Software\\NativeIME" : s) + L"\\Keymap";
}
inline DWORD runtimePid() {
  DWORD value = 0, bytes = sizeof(value);
  RegGetValueW(HKEY_CURRENT_USER, settingsKey().c_str(), L"Pid",
               RRF_RT_REG_DWORD, nullptr, &value, &bytes);
  return value;
}
inline std::wstring readString(const wchar_t* name) {
  HKEY k;
  std::wstring out;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, settingsKey().c_str(), 0,
                    KEY_QUERY_VALUE, &k) == ERROR_SUCCESS) {
    DWORD type = 0, bytes = 0;
    if (RegQueryValueExW(k, name, nullptr, &type, nullptr, &bytes) ==
            ERROR_SUCCESS &&
        (type == REG_SZ || type == REG_MULTI_SZ) && bytes < 1024 * 1024) {
      out.resize(bytes / sizeof(wchar_t) + 1);
      RegQueryValueExW(k, name, nullptr, &type,
                       reinterpret_cast<BYTE*>(out.data()), &bytes);
      while (!out.empty() && out.back() == 0) out.pop_back();
    }
    RegCloseKey(k);
  }
  return out;
}
inline std::wstring configPath() {
  auto p = env(L"NELISP_IME_KEYMAP_FILE");
  if (p.empty()) p = readString(L"File");
  if (!p.empty()) return std::filesystem::absolute(p).wstring();
  PWSTR folder = nullptr;
  std::wstring out;
  if (SUCCEEDED(
          SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr, &folder))) {
    out = std::wstring(folder) + L"\\NativeIME\\keymap.conf";
    CoTaskMemFree(folder);
  }
  return out;
}
inline std::wstring utf16(const std::string& s) {
  if (s.empty()) return {};
  int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(),
                              static_cast<int>(s.size()), nullptr, 0);
  if (!n) throw std::runtime_error("file is not valid UTF-8");
  std::wstring out(n, 0);
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()),
                      out.data(), n);
  return out;
}
inline std::string utf8(const std::wstring& s) {
  int n = WideCharToMultiByte(CP_UTF8, 0, s.data(), static_cast<int>(s.size()),
                              nullptr, 0, nullptr, nullptr);
  std::string out(n, 0);
  WideCharToMultiByte(CP_UTF8, 0, s.data(), static_cast<int>(s.size()),
                      out.data(), n, nullptr, nullptr);
  return out;
}
// No waits in this function. The timer/watch owner retries sharing violations.
inline bool readFile(const std::wstring& path, std::wstring& text,
                     DWORD& error) {
  HANDLE h =
      CreateFileW(path.c_str(), GENERIC_READ,
                  FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                  nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (h == INVALID_HANDLE_VALUE) {
    error = GetLastError();
    if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND) {
      text.clear();
      return true;
    }
    return false;
  }
  LARGE_INTEGER size{};
  if (!GetFileSizeEx(h, &size) || size.QuadPart > 1024 * 1024) {
    CloseHandle(h);
    error = ERROR_FILE_TOO_LARGE;
    return false;
  }
  std::string bytes(static_cast<size_t>(size.QuadPart), 0);
  DWORD got = 0;
  bool ok = ReadFile(h, bytes.data(), static_cast<DWORD>(bytes.size()), &got,
                     nullptr) &&
            got == bytes.size();
  error = ok ? 0 : GetLastError();
  CloseHandle(h);
  if (ok) try {
      text = utf16(bytes);
    } catch (...) {
      error = ERROR_NO_UNICODE_TRANSLATION;
      return false;
    }
  return ok;
}
inline bool writeFileAtomic(const std::wstring& path,
                            const std::wstring& text) {
  std::error_code ec;
  std::filesystem::create_directories(std::filesystem::path(path).parent_path(),
                                      ec);
  auto temp = path + L".tmp." + std::to_wstring(GetCurrentProcessId());
  auto bytes = utf8(text);
  HANDLE h = CreateFileW(temp.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                         FILE_ATTRIBUTE_NORMAL, nullptr);
  if (h == INVALID_HANDLE_VALUE) return false;
  DWORD written = 0;
  bool ok = WriteFile(h, bytes.data(), static_cast<DWORD>(bytes.size()),
                      &written, nullptr) &&
            written == bytes.size() && FlushFileBuffers(h);
  CloseHandle(h);
  if (ok) {
    if (GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES)
      ok = ReplaceFileW(path.c_str(), temp.c_str(), nullptr, 0, nullptr,
                        nullptr) != 0;
    else
      ok = MoveFileExW(temp.c_str(), path.c_str(), MOVEFILE_WRITE_THROUGH) != 0;
  }
  if (!ok) DeleteFileW(temp.c_str());
  return ok;
}
inline void publish(const Snapshot& s, const std::wstring& path,
                    bool error = false) {
  HKEY k;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, settingsKey().c_str(), 0, nullptr, 0,
                      KEY_SET_VALUE, nullptr, &k, nullptr) != ERROR_SUCCESS)
    return;
  auto str = [&](const wchar_t* name, const std::wstring& v) {
    RegSetValueExW(k, name, 0, REG_SZ, reinterpret_cast<const BYTE*>(v.c_str()),
                   static_cast<DWORD>((v.size() + 1) * sizeof(wchar_t)));
  };
  auto num = [&](const wchar_t* name, DWORD v) {
    RegSetValueExW(k, name, 0, REG_DWORD, reinterpret_cast<const BYTE*>(&v),
                   sizeof(v));
  };
  str(L"Status", error || !s.errors.empty() ? L"error" : L"ok");
  str(L"ConfigPath", path);
  str(L"Version", L"1.0.0");
  num(L"Pid", GetCurrentProcessId());
  num(L"RuleCount", static_cast<DWORD>(s.keys.size() + s.shortcuts.size()));
  std::wstring errors;
  for (auto& e : s.errors) {
    errors += e;
    errors.push_back(0);
  }
  errors.push_back(0);
  if (errors.size() == 1) errors.push_back(0);
  RegSetValueExW(k, L"Errors", 0, REG_MULTI_SZ,
                 reinterpret_cast<const BYTE*>(errors.data()),
                 static_cast<DWORD>(errors.size() * sizeof(wchar_t)));
  RegCloseKey(k);
}
inline Layout activeLayout(HWND foreground) {
  DWORD thread = GetWindowThreadProcessId(foreground, nullptr);
  HKL hkl = GetKeyboardLayout(thread);
  return MapVirtualKeyExW(0x1a, MAPVK_VSC_TO_VK_EX, hkl) == 0xc0 ? Layout::JIS
                                                                 : Layout::US;
}
inline bool supportedLayout(HWND foreground) {
  HKL hkl = GetKeyboardLayout(GetWindowThreadProcessId(foreground, nullptr));
  auto lang = LOWORD(reinterpret_cast<ULONG_PTR>(hkl));
  return lang == 0x0411 ||
         (lang == 0x0409 && HIWORD(reinterpret_cast<ULONG_PTR>(hkl)) == 0x0409);
}
inline Key normalize(Key k) {
  if (k.vk == VK_CONTROL) k.vk = k.extended ? VK_RCONTROL : VK_LCONTROL;
  if (k.vk == VK_MENU) k.vk = k.extended ? VK_RMENU : VK_LMENU;
  if (k.vk == VK_SHIFT) k.vk = k.scan == 0x36 ? VK_RSHIFT : VK_LSHIFT;
  return k;
}
}  // namespace keymap
