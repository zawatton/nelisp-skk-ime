// SPDX-License-Identifier: GPL-3.0-or-later
#include "auto_pair.h"
#include "registry_settings.h"
#include "../keymap/core.h"
#include <cstdio>
#include <string>
int wmain() {
  unsigned checks = 0, failures = 0;
  auto check = [&](bool ok) { ++checks; if (!ok) ++failures; };
  using ddskk::AutoPairCaret;
  static_assert(ddskk::AutoPairInputTag == keymap::Tag);
  for (auto name : {L"WindowsTerminal.exe", L"OpenConsole.exe", L"conhost.exe", L"WINDOWSTERMINAL.EXE", L"msedge.exe", L"chrome.exe"})
    check(ddskk::ReadAutoPairCaret(name, nullptr) == AutoPairCaret::LeftKey);
  for (auto name : {L"notepad.exe", L"my-conhost.exe", L""})
    check(ddskk::ReadAutoPairCaret(name, nullptr) == AutoPairCaret::Selection);
  // The isolation runner supplies a private key. Refuse the live default.
  wchar_t root[256]{};
  if (!GetEnvironmentVariableW(L"NATIVEIME_REGISTRY_KEY", root, 256) ||
      std::wstring(root).find(L"NativeIME-test-") == std::wstring::npos) return 2;
  HKEY key = nullptr;
  std::wstring path = std::wstring(root) + L"\\Apps\\WindowsTerminal.exe";
  if (RegCreateKeyExW(HKEY_CURRENT_USER, path.c_str(), 0, nullptr, 0, KEY_ALL_ACCESS, nullptr, &key, nullptr)) return 3;
  check(ddskk::ReadAutoPairCaret(L"WindowsTerminal.exe", key) == AutoPairCaret::LeftKey);
  for (auto value : {L"selection", L"left-key", L"invalid", L""}) {
    RegSetValueExW(key, L"AutoPairCaret", 0, REG_SZ, reinterpret_cast<const BYTE*>(value),
        static_cast<DWORD>((wcslen(value) + 1) * sizeof(wchar_t)));
    check(ddskk::ReadAutoPairCaret(L"WindowsTerminal.exe", key) ==
          (wcscmp(value, L"left-key") == 0 ? AutoPairCaret::LeftKey : AutoPairCaret::Selection));
    check(ddskk::ReadAutoPairCaret(L"notepad.exe", key) ==
          (wcscmp(value, L"left-key") == 0 ? AutoPairCaret::LeftKey : AutoPairCaret::Selection));
  }
  DWORD wrong = 1;
  RegSetValueExW(key, L"AutoPairCaret", 0, REG_DWORD, reinterpret_cast<const BYTE*>(&wrong), sizeof(wrong));
  check(ddskk::ReadAutoPairCaret(L"conhost.exe", key) == AutoPairCaret::Selection);
  const wchar_t unterminated[] = {L'l', L'e', L'f', L't', L'-', L'k', L'e', L'y'};
  RegSetValueExW(key, L"AutoPairCaret", 0, REG_SZ, reinterpret_cast<const BYTE*>(unterminated), sizeof(unterminated));
  check(ddskk::ReadAutoPairCaret(L"conhost.exe", key) == AutoPairCaret::Selection);
  RegSetValueExW(key, L"AutoPairCaret", 0, REG_SZ, reinterpret_cast<const BYTE*>(unterminated), 1);
  check(ddskk::ReadAutoPairCaret(L"conhost.exe", key) == AutoPairCaret::Selection);
  std::wstring oversized(100, L'x');
  RegSetValueExW(key, L"AutoPairCaret", 0, REG_SZ, reinterpret_cast<const BYTE*>(oversized.c_str()),
      static_cast<DWORD>((oversized.size() + 1) * sizeof(wchar_t)));
  check(ddskk::ReadAutoPairCaret(L"conhost.exe", key) == AutoPairCaret::Selection);
  RegCloseKey(key);
  // Even with injected-input remapping enabled, the shared tag bypasses it.
  keymap::Snapshot rules; rules.enabled = true; rules.passInjected = false;
  keymap::Rule rule; rule.from.count = rule.to.count = 1;
  rule.from.keys[0] = {VK_LEFT, 0, true}; rule.to.keys[0] = {'A', 0, false}; rules.keys.push_back(rule);
  keymap::State state;
  for (bool up : {false, true}) {
    auto result = keymap::decide({{VK_LEFT, 0, true}, up, true, keymap::Tag, 0}, state, rules, {});
    check(!result.swallow && result.count == 0);
  }
  keymap::State control_state;
  auto control = keymap::decide({{VK_LEFT, 0, true}, false, true, 0, 0}, control_state, rules, {});
  check(control.swallow && control.count > 0); // untagged control really remaps
  std::printf("PASS auto-pair strategy checks=%u failures=%u hooks=0 SendInput=0\n", checks, failures);
  return failures ? 1 : 0;
}
