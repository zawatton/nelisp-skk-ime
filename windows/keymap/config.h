// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "core.h"
namespace keymap {
struct Line {
  std::wstring text, section, source, target;
  unsigned number = 0;
  bool rule = false;
  std::wstring ending = L"\n";
};
struct Document {
  std::vector<Line> lines;
  Snapshot snapshot;
  std::wstring newline = L"\n";
  bool bom = false;
  static Document parse(const std::wstring& text);
  std::wstring text() const;
  void setOption(const std::wstring& name, const std::wstring& value);
  void setRule(const std::wstring& section, const std::wstring& source,
               const std::wstring& target);
  void removeRule(const std::wstring& section, const std::wstring& source);
  void setExclusions(const std::vector<std::wstring>& apps);
};
std::wstring keyName(Key);
std::wstring chordName(const Chord&);
struct Inspection {
  std::wstring name, scan, vk, plain, shifted, registration, conversion;
};
const Rule* matchingRule(const Event&, const Chord&, const Snapshot&);
Inspection inspect(const Event&, const Chord&, const Snapshot&, Layout active);
std::wstring templateText();
}  // namespace keymap
