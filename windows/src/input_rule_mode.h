// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "engine_protocol.h"
#include <unordered_map>
namespace ddskk {
inline bool InputRuleAllowsModeCommand(
    const std::unordered_map<std::string, RomajiRule>& rules, char key) {
  if (rules.empty() || (key != 'l' && key != 'L' && key != 'q' && key != 'Q')) return true;
  const auto rule = rules.find(std::string(1, key));
  if (rule != rules.end() && rule->second.command.empty()) return false;
  for (const auto& [candidate, unused] : rules) {
    (void)unused;
    if (candidate.size() > 1 && candidate[0] == key) return false;
  }
  return true;
}
}  // namespace ddskk
