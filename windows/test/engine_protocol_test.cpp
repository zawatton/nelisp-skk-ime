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

#include <cassert>
#include <cstdlib>

#ifdef NDEBUG
#undef assert
#define assert(condition) ((condition) ? static_cast<void>(0) : std::abort())
#endif

int main() {
  assert(ddskk::EncodeKeyRequest(U'あ') == "KEY 12354\n");
  assert(ddskk::EncodeKeyRequest(0x110000).empty());
  assert(ddskk::EncodeControlRequest(ddskk::EngineControl::kBackspace) ==
         "CONTROL BACKSPACE\n");
  assert(ddskk::EncodeControlRequest(ddskk::EngineControl::kConvert) ==
         "CONTROL CONVERT\n");
  assert(ddskk::EncodeControlRequest(ddskk::EngineControl::kPrevious) ==
         "CONTROL PREVIOUS\n");

  auto state = ddskk::ParseStateResponse(
      "STATE preedit 3 1 0025bd00304b00306a 00006e -1 -");
  assert(state);
  assert(state->mode == L"preedit");
  assert(state->cursor == 3);
  assert(state->composition_start == 1);
  assert(state->text == L"▽かな");
  assert(state->pending_romaji == L"n");

  auto candidates = ddskk::ParseStateResponse(
      "STATE candidate 2 1 0025bc004eee00540d - 0 004eee00540d,00304b00306a");
  assert(candidates && candidates->candidate_index == 0);
  assert(candidates->candidates.size() == 2);
  assert(candidates->candidates[0] == L"仮名");

  auto empty = ddskk::ParseStateResponse("STATE hiragana 0 -1 - - -1 -");
  assert(empty && empty->text.empty() && empty->pending_romaji.empty());
  assert(!ddskk::ParseStateResponse("ERR REQUEST"));
}
