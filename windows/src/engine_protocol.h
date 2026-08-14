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

#pragma once

#include <optional>
#include <string>
#include <vector>

namespace ddskk {

struct EngineState {
  std::wstring mode;
  int cursor = 0;
  int composition_start = -1;
  std::wstring text;
  std::wstring pending_romaji;
  int candidate_index = -1;
  std::vector<std::wstring> candidates;
};

std::string EncodeKeyRequest(char32_t codepoint);
enum class EngineControl { kBackspace, kConvert, kPrevious, kCommit, kCancel };
std::string EncodeControlRequest(EngineControl control);
std::optional<EngineState> ParseStateResponse(const std::string& line);

}  // namespace ddskk
