// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "engine_protocol.h"
#include <msctf.h>
#include <unordered_map>

namespace ddskk {
enum class AutoPairCaret { Selection, LeftKey };
// The absent-value executable defaults live here, not in registry installers.
AutoPairCaret ReadAutoPairCaret(const std::wstring& executable, HKEY application);
constexpr LPARAM AutoPairInputTag = 0x4e494b4d; // nelisp-ime-keymap::Tag

// The synchronous StateEditSession owns this post-commit key transaction.
class AutoPairCaretUpdate {
 public:
  void Prepare(const std::wstring& closer, AutoPairCaret strategy);
  void Arm() { armed_ = true; }
  HRESULT Complete();
 private:
  HWND target_ = nullptr;
  size_t characters_ = 0;
  bool armed_ = false;
};
// Metadata shares the effective rule export and its engine generation.
class AutoPair {
 public:
  void SetRules(const std::vector<RomajiRule>& rules);
  std::wstring Closer(const EngineState& state) const;
  // Caller holds the document edit lock. Caret completion runs after unlock.
  HRESULT Insert(TfEditCookie cookie, ITfContext* context, ITfRange* range,
                 const std::wstring& opener, const std::wstring& closer,
                 AutoPairCaret strategy = AutoPairCaret::Selection,
                 AutoPairCaretUpdate* update = nullptr) const;
 private:
  std::vector<RomajiRule> installed_;
  std::unordered_map<std::wstring, std::wstring> pairs_;
};
}  // namespace ddskk
