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
  // Non-empty only for the CorvusSKK-style nine-field registration STATE.
  // `text'/`pending_romaji'/`candidates' then describe the nested
  // registration session, while this preserves the parked main reading.
  std::wstring registration_reading;
};

std::string EncodeKeyRequest(char32_t codepoint);
// Atomic conversion barrier used by the native real-time frontend: reset the
// provider session, replay the exact SKK key sequence, and convert in one
// provider transaction. Ordinary typing never uses this slow path.
std::string EncodeConvertKeysRequest(const std::u32string& keys);
std::string EncodeFeedKeysRequest(const std::u32string& keys);
// kQuit is DDSKK's stepwise keyboard-quit ("CONTROL QUIT"): ▼->▽ with the
// reading restored, ▽->clear, a pending romaji prefix->drop the last
// syllable, idle->no-op. Distinct from kCancel, which is skk-kakutei's
// unconditional return-to-kana semantics (see the Ctrl+J comment in
// TextService::OnKeyDown) -- Esc and Ctrl+G both send kQuit, not kCancel;
// see that same comment for why.
enum class EngineControl { kBackspace, kConvert, kPrevious, kCommit, kCancel,
                           kQuit, kSegmentPrev, kSegmentNext, kSegmentShrink,
                           kSegmentExtend, kToHiragana, kToKatakana,
                           kToHalfKatakana, kToWideLatin, kToLatin,
                           kLeft, kRight, kHome, kEnd, kDelete };
std::string EncodeControlRequest(EngineControl control);
std::optional<EngineState> ParseStateResponse(const std::string& line);

// Whether the DLL should currently treat input as kana (composing) rather
// than plain latin/direct-input passthrough, given the engine's own
// self-reported EngineState::mode. Every mode string except "latin" is a
// kana state: "hiragana"/"katakana" are direct kana input, "wide-latin"/
// "abbrev" are DDSKK submodes only reachable and only leavable via
// kana-mode key handling, and "preedit"/"candidate" mean a conversion is
// already in progress (also kana input).
//
// This is the single source of truth TextService::OnKeyDown uses to keep
// its own kana_mode_ flag from drifting out of sync with the
// out-of-process engine: previously kana_mode_ was a locally-tracked
// boolean that nothing updated when a plain keystroke (e.g. `l') silently
// changed the engine's own mode, so it could disagree with both the
// engine and with ModeIndicatorLabel() (which reads the engine's mode
// directly). Deriving it fresh from every EngineState closes that gap.
bool DeriveKanaMode(const EngineState& state);

}  // namespace ddskk
