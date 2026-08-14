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

#include <windows.h>

#include <map>
#include <string>

// Maps the DLL's kana_mode_ flag and the engine-reported mode string to the
// short label shown by ModeIndicator. This is the single source of truth
// for that mapping, kept as a free function so it is testable without any
// window/GDI dependency.
//
// `engine_mode` is expected to be one of the ddskk::EngineState::mode
// values ("hiragana", "katakana", "latin", "wide-latin", "abbrev",
// "preedit", "candidate") or empty when no fresh engine state is
// available (e.g. a langbar-triggered call). preedit/candidate map to the
// same label as hiragana because a conversion in progress is still kana
// input; callers rely on the label being unchanged in that case to avoid
// popping the indicator for ordinary conversion keystrokes.
std::wstring ModeIndicatorLabel(bool kana_mode, const std::wstring& engine_mode);

// The background/border/text colors used to paint the indicator for one
// mode label.
struct ModeIndicatorPalette {
  COLORREF background;
  COLORREF border;
  COLORREF text;
};

// Returns the built-in default palette for `label` (one of the strings
// ModeIndicatorLabel() can return: "かな", "カナ", "英数", "全英",
// "Abbrev"). This is the same idea as CorvusSKK's "入力モードの色"
// setting -- a distinct color per input mode, chosen for quick
// discrimination at a glance -- with sensible built-in defaults;
// TextService::LoadSettings() can override any of them from the registry
// via ModeIndicator::SetPaletteOverride() without a rebuild. Any other
// (unrecognized) label falls back to the same palette as "英数". Pure and
// testable without any window/GDI dependency, mirroring
// ModeIndicatorLabel().
ModeIndicatorPalette ModeIndicatorColors(const std::wstring& label);

// A small always-on-top, non-activating popup window that shows the
// current input mode near the caret (or the mouse cursor as a fallback)
// for a short time, CorvusSKK-style: CorvusSKK's "入力モードを表示する"
// setting shows "キャレットまたは辞書登録ウィンドウ付近に入力モードを表示
// します" for a configurable duration (default 3000 ms); this class
// implements the same idea for DDSKK.
//
// Must be constructed on (and only ever used from) a thread that pumps a
// Win32 message loop -- a TSF text service thread always does. Window
// class registration is lazy and happens at most once per module.
class ModeIndicator final {
 public:
  ModeIndicator() = default;
  ~ModeIndicator();

  ModeIndicator(const ModeIndicator&) = delete;
  ModeIndicator& operator=(const ModeIndicator&) = delete;

  // Sets how long the indicator stays visible once shown, in
  // milliseconds. The caller (TextService::LoadSettings) is responsible
  // for clamping this to CorvusSKK's documented [1, 60000] range.
  void SetDurationMs(DWORD duration_ms);

  // Overrides the built-in ModeIndicatorColors() background for `label`
  // (e.g. from one of the HKCU\Software\NativeIME\ModeColor* registry
  // values, a 0x00BBGGRR COLORREF each); the border and text colors are
  // re-derived from it the same way the built-in defaults are (see
  // Darken() and the luminance-based text-color flip in
  // mode_indicator.cpp). A label with no override keeps the built-in
  // default from ModeIndicatorColors().
  void SetPaletteOverride(const std::wstring& label, COLORREF background);

  // Sets the ModeIndicatorScale registry percentage applied to the font
  // height and padding (100 = built-in size, unscaled). The caller
  // (TextService::LoadSettings) is responsible for clamping this to
  // [50, 300].
  void SetScalePercent(DWORD percent);

  // Shows (or re-shows) the popup with `label`, positioned just below
  // `anchor` and clamped to stay inside the work area of the monitor
  // containing `anchor`. If already visible, this relabels/repositions
  // and resets the auto-hide timer rather than stacking a new one.
  void Show(const std::wstring& label, const POINT& anchor);

  // Hides the popup immediately, if shown.
  void Hide();

 private:
  bool EnsureWindow();
  void Reposition(const POINT& anchor);
  HFONT EnsureFont(UINT dpi);
  // Resolves `label` to a palette, applying any override registered via
  // SetPaletteOverride().
  ModeIndicatorPalette PaletteForLabel(const std::wstring& label) const;
  // Recreates background_brush_ only when `palette.background` differs
  // from the currently cached brush's color, so repeated Show() calls for
  // the same mode reuse it instead of leaking a fresh GDI object each
  // time, while a real mode (or override) change still frees the old one.
  void EnsureBackgroundBrush(const ModeIndicatorPalette& palette);
  void OnPaint();
  static LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wparam,
                                     LPARAM lparam);

  HWND hwnd_ = nullptr;
  HFONT font_ = nullptr;
  HBRUSH background_brush_ = nullptr;
  COLORREF background_brush_color_ = 0;
  ModeIndicatorPalette current_palette_ = ModeIndicatorColors(std::wstring());
  std::map<std::wstring, COLORREF> palette_overrides_;
  std::wstring label_;
  DWORD duration_ms_ = 3000;
  DWORD scale_percent_ = 100;
};
