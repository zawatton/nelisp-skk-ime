// SPDX-License-Identifier: GPL-3.0-or-later
#include "auto_pair.h"
#include <cstring>
#include <cwchar>

namespace ddskk {
AutoPairCaret ReadAutoPairCaret(const std::wstring& executable, HKEY application) {
  wchar_t value[32]{};
  DWORD bytes = sizeof(value), type = 0;
  const LSTATUS status = application ? RegQueryValueExW(application, L"AutoPairCaret", nullptr, &type,
      reinterpret_cast<BYTE*>(value), &bytes) : ERROR_FILE_NOT_FOUND;
  if (status != ERROR_FILE_NOT_FOUND) {
    if (status == ERROR_SUCCESS && type == REG_SZ && bytes >= sizeof(wchar_t) && bytes <= sizeof(value) &&
        bytes % sizeof(wchar_t) == 0 && value[bytes / sizeof(wchar_t) - 1] == 0) {
      if (wcscmp(value, L"left-key") == 0) return AutoPairCaret::LeftKey;
      if (wcscmp(value, L"selection") == 0) return AutoPairCaret::Selection;
    }
    return AutoPairCaret::Selection; // malformed overrides fail closed
  }
  static constexpr const wchar_t* left_key_apps[] = {
      L"WindowsTerminal.exe", L"OpenConsole.exe", L"conhost.exe",
      L"msedge.exe", L"chrome.exe"};
  for (const auto* application_name : left_key_apps)
    if (_wcsicmp(executable.c_str(), application_name) == 0) return AutoPairCaret::LeftKey;
  return AutoPairCaret::Selection;
}
void AutoPairCaretUpdate::Prepare(const std::wstring& closer, AutoPairCaret strategy) {
  if (strategy != AutoPairCaret::LeftKey || closer.empty()) return;
  for (size_t i = 0; i < closer.size(); ++i, ++characters_)
    if (IS_HIGH_SURROGATE(closer[i]) && i + 1 < closer.size() && IS_LOW_SURROGATE(closer[i + 1])) ++i;
  target_ = GetFocus();
}
HRESULT AutoPairCaretUpdate::Complete() {
  if (!armed_ || !characters_) return S_FALSE;
  armed_ = false;
  // SendInput appends behind already queued physical keys. Sent key messages
  // instead execute here, after text-store unlock and before the next queued
  // key. They bypass TSF message-pump preprocessing and the LL remapper.
  // Never send to another thread or to a window that gained focus meanwhile.
  if (!target_ || GetFocus() != target_ ||
      GetWindowThreadProcessId(target_, nullptr) != GetCurrentThreadId()) return E_ABORT;
  BYTE saved[256]{}, neutral[256]{};
  if (!GetKeyboardState(saved)) return HRESULT_FROM_WIN32(GetLastError());
  memcpy(neutral, saved, sizeof(saved));
  for (int vk : {VK_SHIFT, VK_LSHIFT, VK_RSHIFT, VK_CONTROL, VK_LCONTROL,
                 VK_RCONTROL, VK_MENU, VK_LMENU, VK_RMENU}) neutral[vk] &= 0x7f;
  if (!SetKeyboardState(neutral)) return HRESULT_FROM_WIN32(GetLastError());
  const LPARAM previous = SetMessageExtraInfo(AutoPairInputTag);
  const LPARAM down = 1 | (static_cast<LPARAM>(MapVirtualKeyW(VK_LEFT, MAPVK_VK_TO_VSC)) << 16) |
                      (static_cast<LPARAM>(1) << 24);
  for (size_t i = 0; i < characters_; ++i) {
    SendMessageW(target_, WM_KEYDOWN, VK_LEFT, down);
    SendMessageW(target_, WM_KEYUP, VK_LEFT,
                 down | (static_cast<LPARAM>(1) << 30) | (static_cast<LPARAM>(1) << 31));
  }
  SetMessageExtraInfo(previous);
  SetKeyboardState(saved);
  return S_OK;
}

void AutoPair::SetRules(const std::vector<RomajiRule>& rules) {
  if (rules == installed_) return;
  installed_ = rules;
  pairs_.clear();
  for (const auto& rule : rules)
    if (rule.command == L"input-pair" && !rule.hiragana.empty() &&
        !rule.closer.empty())
      pairs_[rule.hiragana] = rule.closer;
}
std::wstring AutoPair::Closer(const EngineState& state) const {
  if (state.composition_start >= 0 || !state.pending_romaji.empty() ||
      (state.mode != L"hiragana" && state.mode != L"katakana")) return {};
  const auto found = pairs_.find(state.text);
  return found == pairs_.end() ? std::wstring{} : found->second;
}
HRESULT AutoPair::Insert(TfEditCookie cookie, ITfContext* context, ITfRange* range,
                         const std::wstring& opener, const std::wstring& closer, AutoPairCaret strategy, AutoPairCaretUpdate* update) const {
  const auto text = opener + closer;
  HRESULT result = range->SetText(cookie, 0, text.data(), static_cast<LONG>(text.size()));
  if (FAILED(result)) return result;
  if (update) update->Prepare(closer, strategy);
  result = range->Collapse(cookie, TF_ANCHOR_END);
  if (FAILED(result)) return result;
  if (strategy == AutoPairCaret::LeftKey) return S_OK;
  LONG moved = 0;
  result = range->ShiftStart(cookie, -static_cast<LONG>(closer.size()), &moved, nullptr);
  if (FAILED(result)) return result;
  if (moved != -static_cast<LONG>(closer.size())) return E_FAIL;
  result = range->Collapse(cookie, TF_ANCHOR_START);
  if (FAILED(result)) return result;
  TF_SELECTION selection{range, {TF_AE_NONE, FALSE}};
  return context->SetSelection(cookie, 1, &selection);
}
}  // namespace ddskk
