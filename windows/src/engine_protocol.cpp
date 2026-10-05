// Copyright (C) 2026 nelisp-skk-ime contributors
//
// This program is free software: you can redistribute it and/or
// modify it under the terms of the GNU General Public License as
// published by the Free Software Foundation, either version 3 of
// the License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be
// useful, but WITHOUT ANY WARRANTY; without even the implied
// warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
// PURPOSE.  See the GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

#include "engine_protocol.h"

#include <charconv>
#include <sstream>
#include <vector>
#include <windows.h>

namespace ddskk {
namespace {
std::optional<std::wstring> DecodeScalarHex(const std::string& hex) {
  if (hex == "-") return std::wstring{};
  if ((hex.size() % 6) != 0) return std::nullopt;
  std::wstring text;
  for (size_t i = 0; i < hex.size(); i += 6) {
    unsigned value = 0;
    const auto result = std::from_chars(hex.data() + i, hex.data() + i + 6,
                                        value, 16);
    if (result.ec != std::errc{} || result.ptr != hex.data() + i + 6 ||
        value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff))
      return std::nullopt;
    if (value <= 0xffff) {
      text.push_back(static_cast<wchar_t>(value));
    } else {
      value -= 0x10000;
      text.push_back(static_cast<wchar_t>(0xd800 + (value >> 10)));
      text.push_back(static_cast<wchar_t>(0xdc00 + (value & 0x3ff)));
    }
  }
  return text;
}

bool ParseInt(const std::string& text, int* value) {
  const auto result = std::from_chars(text.data(), text.data() + text.size(), *value);
  return result.ec == std::errc{} && result.ptr == text.data() + text.size();
}
}  // namespace

std::string EncodeKeyRequest(char32_t codepoint) {
  if (codepoint > 0x10ffff) return {};
  return "KEY " + std::to_string(static_cast<uint32_t>(codepoint)) + "\n";
}

std::optional<std::vector<RomajiRule>> ParseRomajiRules(const std::string& line) {
  if (!line.starts_with("RULES 1 ")) return std::nullopt;
  std::istringstream input(line.substr(8));
  std::vector<RomajiRule> rules;
  for (std::string record; input >> record;) {
    std::vector<std::wstring> fields;
    size_t start = 0;
    for (;;) {
      const auto end = record.find(':', start);
      auto field = DecodeScalarHex(record.substr(start, end - start));
      if (!field) return std::nullopt;
      fields.push_back(std::move(*field));
      if (end == std::string::npos) break;
      start = end + 1;
    }
    if ((fields.size() != 5 && fields.size() != 6) || fields[0].empty()) return std::nullopt;
    if (fields.size() == 6 &&
        (fields[0][0] != 1 || fields[4] != L"input-pair" || fields[5].empty()))
      return std::nullopt;
    for (size_t i = 0; i < 2; ++i)
      for (const auto ch : fields[i]) if (ch > 127) return std::nullopt;
    rules.push_back({std::string(fields[0].begin(), fields[0].end()),
                     std::string(fields[1].begin(), fields[1].end()),
                     fields[2], fields[3], fields[4],
                     fields.size() == 6 ? fields[5] : std::wstring{}});
  }
  return rules.empty() ? std::nullopt : std::optional{std::move(rules)};
}

static std::string EncodeKeysRequest(const char* prefix,
                                     const std::u32string& keys) {
  if (keys.empty()) return {};
  std::ostringstream request;
  request << prefix;
  bool first = true;
  for (const char32_t codepoint : keys) {
    if (codepoint > 0x10ffff ||
        (codepoint >= 0xd800 && codepoint <= 0xdfff)) return {};
    if (!first) request << ',';
    first = false;
    request << static_cast<uint32_t>(codepoint);
  }
  request << '\n';
  return request.str();
}

std::string EncodeConvertKeysRequest(const std::u32string& keys) {
  return EncodeKeysRequest("CONTROL CONVERT-KEYS ", keys);
}

std::string EncodeFeedKeysRequest(const std::u32string& keys) {
  return EncodeKeysRequest("CONTROL FEED-KEYS ", keys);
}

std::string EncodeControlRequest(EngineControl control) {
  switch (control) {
    case EngineControl::kBackspace: return "CONTROL BACKSPACE\n";
    case EngineControl::kConvert: return "CONTROL CONVERT\n";
    case EngineControl::kPrevious: return "CONTROL PREVIOUS\n";
    case EngineControl::kCommit: return "CONTROL COMMIT\n";
    case EngineControl::kCancel: return "CONTROL CANCEL\n";
    case EngineControl::kQuit: return "CONTROL QUIT\n";
    case EngineControl::kSegmentPrev: return "CONTROL SEGMENT-PREV\n";
    case EngineControl::kSegmentNext: return "CONTROL SEGMENT-NEXT\n";
    case EngineControl::kSegmentShrink: return "CONTROL SEGMENT-SHRINK\n";
    case EngineControl::kSegmentExtend: return "CONTROL SEGMENT-EXTEND\n";
    case EngineControl::kToHiragana: return "CONTROL TO-HIRAGANA\n";
    case EngineControl::kToKatakana: return "CONTROL TO-KATAKANA\n";
    case EngineControl::kToHalfKatakana: return "CONTROL TO-HALF-KATAKANA\n";
    case EngineControl::kToWideLatin: return "CONTROL TO-WIDE-LATIN\n";
    case EngineControl::kToLatin: return "CONTROL TO-LATIN\n";
    case EngineControl::kLeft: return "CONTROL LEFT\n";
    case EngineControl::kRight: return "CONTROL RIGHT\n";
    case EngineControl::kHome: return "CONTROL HOME\n";
    case EngineControl::kEnd: return "CONTROL END\n";
    case EngineControl::kDelete: return "CONTROL DELETE\n";
  }
  return {};
}

std::optional<EngineState> ParseStateResponse(const std::string& line) {
  std::istringstream input(line);
  std::vector<std::string> fields;
  for (std::string field; input >> field;) fields.push_back(std::move(field));
  if ((fields.size() != 8 && fields.size() != 9) || fields[0] != "STATE")
    return std::nullopt;
  EngineState state;
  if (!ParseInt(fields[2], &state.cursor) ||
      !ParseInt(fields[3], &state.composition_start) ||
      !ParseInt(fields[6], &state.candidate_index)) return std::nullopt;
  auto text = DecodeScalarHex(fields[4]);
  auto pending = DecodeScalarHex(fields[5]);
  if (!text || !pending) return std::nullopt;
  state.mode.assign(fields[1].begin(), fields[1].end());
  state.text = std::move(*text);
  state.pending_romaji = std::move(*pending);
  if (fields[7] != "-") {
    size_t start = 0;
    while (start <= fields[7].size()) {
      const size_t end = fields[7].find(',', start);
      const auto candidate = DecodeScalarHex(fields[7].substr(
          start, end == std::string::npos ? end : end - start));
      if (!candidate) return std::nullopt;
      state.candidates.push_back(*candidate);
      if (end == std::string::npos) break;
      start = end + 1;
    }
  }
  if (fields.size() == 9 && fields[1] == "registration") {
    auto reading = DecodeScalarHex(fields[8]);
    if (!reading) return std::nullopt;
    state.registration_reading = std::move(*reading);
  } else if (fields.size() == 9) {
    // Translate scalar offsets once; TSF ranges count UTF-16 code units.
    std::vector<int> offsets{0};
    for (size_t i = 0; i < state.text.size(); ++i) {
      if (state.text[i] >= 0xd800 && state.text[i] <= 0xdbff) ++i;
      offsets.push_back(static_cast<int>(i + 1));
    }
    const auto separator = fields[8].find(';');
    if (separator == std::string::npos ||
        !ParseInt(fields[8].substr(separator + 1), &state.active_segment))
      return std::nullopt;
    size_t begin = 0;
    int previous_end = 0;
    while (begin < separator) {
      const auto comma = fields[8].find(',', begin);
      const size_t end = comma == std::string::npos ? separator : comma;
      const auto colon = fields[8].find(':', begin);
      int start = 0, length = 0;
      if (end > separator || colon == std::string::npos || colon >= end ||
          !ParseInt(fields[8].substr(begin, colon - begin), &start) ||
          !ParseInt(fields[8].substr(colon + 1, end - colon - 1), &length) ||
          start < previous_end || length <= 0 || start < 0 ||
          static_cast<size_t>(start) >= offsets.size() ||
          static_cast<size_t>(length) >= offsets.size() - start)
        return std::nullopt;
      previous_end = start + length;
      state.segments.push_back({offsets[start], offsets[previous_end] - offsets[start]});
      begin = end + 1;
      if (end != separator && begin == separator) return std::nullopt;
    }
    if (state.active_segment < 0 ||
        static_cast<size_t>(state.active_segment) >= state.segments.size())
      return std::nullopt;
  }
  return state;
}

bool DeriveKanaMode(const EngineState& state) { return state.mode != L"latin"; }
}  // namespace ddskk
