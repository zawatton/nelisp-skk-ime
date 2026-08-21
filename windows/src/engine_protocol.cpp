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
  if (fields.size() == 9 && fields[1] != "registration") return std::nullopt;
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
  if (fields.size() == 9) {
    auto reading = DecodeScalarHex(fields[8]);
    if (!reading) return std::nullopt;
    state.registration_reading = std::move(*reading);
  }
  return state;
}

bool DeriveKanaMode(const EngineState& state) { return state.mode != L"latin"; }
}  // namespace ddskk
