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
  assert(ddskk::EncodeConvertKeysRequest(U"Kana") ==
         "CONTROL CONVERT-KEYS 75,97,110,97\n");
  assert(ddskk::EncodeConvertKeysRequest(U"").empty());
  assert(ddskk::EncodeFeedKeysRequest(U"test") ==
         "CONTROL FEED-KEYS 116,101,115,116\n");
  assert(ddskk::EncodeFeedKeysRequest(U"").empty());
  assert(ddskk::EncodeControlRequest(ddskk::EngineControl::kBackspace) ==
         "CONTROL BACKSPACE\n");
  assert(ddskk::EncodeControlRequest(ddskk::EngineControl::kConvert) ==
         "CONTROL CONVERT\n");
  assert(ddskk::EncodeControlRequest(ddskk::EngineControl::kPrevious) ==
         "CONTROL PREVIOUS\n");
  assert(ddskk::EncodeControlRequest(ddskk::EngineControl::kSegmentPrev) ==
         "CONTROL SEGMENT-PREV\n");
  assert(ddskk::EncodeControlRequest(ddskk::EngineControl::kSegmentExtend) ==
         "CONTROL SEGMENT-EXTEND\n");
  assert(ddskk::EncodeControlRequest(ddskk::EngineControl::kToKatakana) ==
         "CONTROL TO-KATAKANA\n");
  assert(ddskk::EncodeControlRequest(ddskk::EngineControl::kDelete) ==
         "CONTROL DELETE\n");

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

  auto registration = ddskk::ParseStateResponse(
      "STATE registration 2 -1 00304b00306a - -1 - 00308800307f");
  assert(registration && registration->mode == L"registration");
  assert(registration->text == L"かな");
  assert(registration->registration_reading == L"よみ");

  auto empty = ddskk::ParseStateResponse("STATE hiragana 0 -1 - - -1 -");
  assert(empty && empty->text.empty() && empty->pending_romaji.empty());
  assert(!ddskk::ParseStateResponse("ERR REQUEST"));

  // Regression coverage for the DLL-side mode-desync bug: TextService's
  // kana_mode_ must be derived from the engine's own EngineState::mode on
  // every keystroke, never tracked as an independently-updated local
  // flag. Feed a sequence of parsed states -- exactly what OnKeyDown sees
  // across a run of keystrokes, including a real transition into "latin"
  // -- and confirm the derived flag follows the engine every time instead
  // of sticking at whatever it last was.
  auto hiragana = ddskk::ParseStateResponse("STATE hiragana 0 -1 - - -1 -");
  assert(hiragana && ddskk::DeriveKanaMode(*hiragana));

  auto latin = ddskk::ParseStateResponse("STATE latin 0 -1 - - -1 -");
  assert(latin && !ddskk::DeriveKanaMode(*latin));

  // A subsequent preedit state (e.g. the user pressed Ctrl+J, or typed an
  // uppercase letter after returning to kana) must flip the derived flag
  // back to kana, not leave it stuck at the "latin" reading above.
  auto preedit = ddskk::ParseStateResponse(
      "STATE preedit 3 1 0025bd00304b00306a 00006e -1 -");
  assert(preedit && ddskk::DeriveKanaMode(*preedit));

  auto katakana = ddskk::ParseStateResponse("STATE katakana 0 -1 - - -1 -");
  assert(katakana && ddskk::DeriveKanaMode(*katakana));

  auto wide_latin = ddskk::ParseStateResponse("STATE wide-latin 0 -1 - - -1 -");
  assert(wide_latin && ddskk::DeriveKanaMode(*wide_latin));

  auto abbrev = ddskk::ParseStateResponse("STATE abbrev 0 -1 - - -1 -");
  assert(abbrev && ddskk::DeriveKanaMode(*abbrev));

  auto candidate = ddskk::ParseStateResponse(
      "STATE candidate 2 1 0025bc004eee00540d - 0 004eee00540d,00304b00306a");
  assert(candidate && ddskk::DeriveKanaMode(*candidate));

  // And back to latin again, to confirm this isn't a one-shot transition.
  auto latin_again = ddskk::ParseStateResponse("STATE latin 0 -1 - - -1 -");
  assert(latin_again && !ddskk::DeriveKanaMode(*latin_again));
}
