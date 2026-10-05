// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "engine_protocol.h"
#include <msctf.h>
#include <unordered_map>

namespace ddskk {
// Metadata shares the effective rule export and its engine generation.
class AutoPair {
 public:
  void SetRules(const std::vector<RomajiRule>& rules);
  std::wstring Closer(const EngineState& state) const;
  // Caller holds the document edit lock; no synthetic keyboard input.
  HRESULT Insert(TfEditCookie cookie, ITfContext* context, ITfRange* range,
                 const std::wstring& opener, const std::wstring& closer) const;
 private:
  std::vector<RomajiRule> installed_;
  std::unordered_map<std::wstring, std::wstring> pairs_;
};
}  // namespace ddskk
