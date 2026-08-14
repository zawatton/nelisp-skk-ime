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

#include "mode_indicator.h"

#include <cassert>
#include <cstdlib>

#ifdef NDEBUG
#undef assert
#define assert(condition) ((condition) ? static_cast<void>(0) : std::abort())
#endif

// mode_indicator.cpp references this (normally defined in dllmain.cpp) for
// the window class/window hInstance. This test never creates an actual
// window -- it only exercises the pure ModeIndicatorLabel() mapping -- but
// the symbol must still resolve at link time since mode_indicator.cpp is
// linked in as a directly-specified object file, not a library member.
HMODULE g_module = nullptr;

int main() {
  // kana_mode_ false always means the DLL is passing keys through,
  // regardless of what the engine last reported.
  assert(ModeIndicatorLabel(false, L"hiragana") == L"英数");
  assert(ModeIndicatorLabel(false, L"") == L"英数");

  assert(ModeIndicatorLabel(true, L"hiragana") == L"かな");
  assert(ModeIndicatorLabel(true, L"katakana") == L"カナ");
  assert(ModeIndicatorLabel(true, L"latin") == L"英数");
  assert(ModeIndicatorLabel(true, L"wide-latin") == L"全英");
  assert(ModeIndicatorLabel(true, L"abbrev") == L"Abbrev");

  // A conversion in progress is still kana input.
  assert(ModeIndicatorLabel(true, L"preedit") == L"かな");
  assert(ModeIndicatorLabel(true, L"candidate") == L"かな");

  // No fresh engine state (e.g. a langbar-triggered call) falls back to
  // the same default as an ordinary kana transition.
  assert(ModeIndicatorLabel(true, L"") == L"かな");

  // Each of the five recognized labels gets a distinguishable background
  // color (CorvusSKK's "入力モードの色" equivalent), so the mode reads at
  // a glance without needing to read the label text itself.
  const ModeIndicatorPalette kana = ModeIndicatorColors(L"かな");
  const ModeIndicatorPalette katakana = ModeIndicatorColors(L"カナ");
  const ModeIndicatorPalette latin = ModeIndicatorColors(L"英数");
  const ModeIndicatorPalette wide_latin = ModeIndicatorColors(L"全英");
  const ModeIndicatorPalette abbrev = ModeIndicatorColors(L"Abbrev");

  assert(kana.background != katakana.background);
  assert(kana.background != latin.background);
  assert(kana.background != wide_latin.background);
  assert(kana.background != abbrev.background);
  assert(katakana.background != latin.background);
  assert(katakana.background != wide_latin.background);
  assert(katakana.background != abbrev.background);
  assert(latin.background != wide_latin.background);
  assert(latin.background != abbrev.background);
  assert(wide_latin.background != abbrev.background);

  // An unrecognized label falls back to the same (grey) palette as 英数.
  const ModeIndicatorPalette unknown = ModeIndicatorColors(L"???");
  assert(unknown.background == latin.background);
  assert(unknown.border == latin.border);
  assert(unknown.text == latin.text);
}
