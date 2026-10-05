// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <string>
#include <vector>
#include <windows.h>

namespace keymap {
struct InputRow {
  std::wstring section, key;
  std::vector<std::wstring> values;
};
struct InputDocument {
  std::wstring source, width = L"hankaku";
  bool autoPair = true;
  std::vector<InputRow> rows;
  std::vector<std::wstring> errors;
  static InputDocument Parse(const std::wstring& text);
  void Set(const std::wstring& section, const std::wstring& key,
           const std::vector<std::wstring>& values);
};
std::wstring inputRulesPath();
std::wstring inputRulesTemplate();
bool reloadInputEngine();
// Polling is outside the hook. Debounces content changes and retries a busy
// pipe; missing-file transitions restore the same engine defaults.
class InputRulesWatch {
 public:
  void Tick();
 private:
  std::wstring path_, content_;
  bool initialized_ = false;
  ULONGLONG due_ = 0;
};
int rulesEditor(bool selfTest, HWND parent = nullptr);
}  // namespace keymap
