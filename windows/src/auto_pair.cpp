// SPDX-License-Identifier: GPL-3.0-or-later
#include "auto_pair.h"

namespace ddskk {
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
                         const std::wstring& opener, const std::wstring& closer) const {
  const auto text = opener + closer;
  HRESULT result = range->SetText(cookie, 0, text.data(), static_cast<LONG>(text.size()));
  if (FAILED(result)) return result;
  result = range->Collapse(cookie, TF_ANCHOR_END);
  if (FAILED(result)) return result;
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
