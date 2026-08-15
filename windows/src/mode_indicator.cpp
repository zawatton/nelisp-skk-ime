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

// Defined in dllmain.cpp. Declared again here (rather than pulling in
// text_service.h) so this file stays self-contained.
extern HMODULE g_module;

namespace {

// CorvusSKK exposes per-mode indicator colors as an "入力モードの色"
// (input mode color) setting. These are the built-in defaults for the
// same idea -- chosen for quick discrimination at a glance -- and are
// overridable from the registry (see ModeIndicator::SetPaletteOverride(),
// wired up in TextService::LoadSettings()) without a rebuild. Border and
// text colors are always derived from the background (see Darken() and
// TextColorFor() below), so only the backgrounds are listed here.
constexpr COLORREF kColorKanaBackground = RGB(0xC0, 0x20, 0x20);      // red
constexpr COLORREF kColorKatakanaBackground = RGB(0x1B, 0x7F, 0x3B);  // green
constexpr COLORREF kColorLatinBackground = RGB(0x1E, 0x5A, 0xA8);     // blue
constexpr COLORREF kColorWideLatinBackground = RGB(0xB0, 0x5A, 0x00); // amber
constexpr COLORREF kColorAbbrevBackground = RGB(0x6A, 0x2C, 0x91);    // purple

// Border colors are this percentage of the background's brightness (i.e.
// one shade darker); see Darken().
constexpr int kBorderDarkenPercent = 70;

// Text is white by default, but flips to near-black once the background
// is pale enough (luminance above this threshold) that white would be
// hard to read -- relevant mainly for a user-chosen light override
// background; see TextColorFor().
constexpr double kLightBackgroundLuminanceThreshold = 0.6;
constexpr COLORREF kColorTextOnDark = RGB(0xFF, 0xFF, 0xFF);
constexpr COLORREF kColorTextOnLight = RGB(0x11, 0x11, 0x11);

constexpr wchar_t kWindowClassName[] = L"DdskkModeIndicatorWindow";
constexpr UINT_PTR kTimerId = 1;

// Anchor offset (below-right of the caret/cursor) and label padding, in
// logical (96 DPI) pixels; both are scaled by the window's DPI, and the
// padding is additionally scaled by ModeIndicator::SetScalePercent().
constexpr int kAnchorGapX = 0;
constexpr int kAnchorGapY = 24;
constexpr int kPaddingX = 6;
constexpr int kPaddingY = 3;

// Scales each RGB channel of `color` to `percent` of its original value.
// Used to derive a border color one shade darker than its background.
COLORREF Darken(COLORREF color, int percent) {
  const auto scale_channel = [percent](BYTE channel) -> BYTE {
    return static_cast<BYTE>((static_cast<int>(channel) * percent) / 100);
  };
  return RGB(scale_channel(GetRValue(color)), scale_channel(GetGValue(color)),
             scale_channel(GetBValue(color)));
}

// Perceptual luma of `color`, normalized to [0, 1]. Not a color-accurate
// linearized-sRGB luminance -- just enough to tell whether a background is
// pale enough that white text would be hard to read on it.
double RelativeLuminance(COLORREF color) {
  return (0.299 * GetRValue(color) + 0.587 * GetGValue(color) +
         0.114 * GetBValue(color)) / 255.0;
}

// White text on a dark/mid background, near-black text on a pale one.
COLORREF TextColorFor(COLORREF background) {
  return RelativeLuminance(background) > kLightBackgroundLuminanceThreshold
             ? kColorTextOnLight
             : kColorTextOnDark;
}

// GetDpiForWindow is only available on Windows 10 1607+. Look it up
// dynamically so the DLL still loads and runs (just unscaled) on older
// systems that TSF itself still supports.
UINT GetWindowDpiOrDefault(HWND hwnd) {
  using GetDpiForWindowFn = UINT(WINAPI*)(HWND);
  const HMODULE user32 = GetModuleHandleW(L"user32.dll");
  const auto get_dpi_for_window =
      user32 == nullptr
          ? nullptr
          : reinterpret_cast<GetDpiForWindowFn>(
                GetProcAddress(user32, "GetDpiForWindow"));
  if (get_dpi_for_window != nullptr) {
    const UINT dpi = get_dpi_for_window(hwnd);
    if (dpi != 0) return dpi;
  }
  return USER_DEFAULT_SCREEN_DPI;
}

}  // namespace

std::wstring ModeIndicatorLabel(bool kana_mode, const std::wstring& engine_mode) {
  if (!kana_mode) return L"SKK";
  if (engine_mode == L"hiragana") return L"かな";
  if (engine_mode == L"katakana") return L"カナ";
  if (engine_mode == L"latin") return L"SKK";
  if (engine_mode == L"wide-latin") return L"全英";
  if (engine_mode == L"abbrev") return L"Abbrev";
  // preedit/candidate: a conversion in progress is still kana input, and
  // an unrecognized/empty mode (e.g. no fresh engine state available)
  // falls back to the same default.
  return L"かな";
}

ModeIndicatorPalette ModeIndicatorColors(const std::wstring& label) {
  COLORREF background = kColorLatinBackground;  // fallback: same as SKK
  if (label == L"かな") {
    background = kColorKanaBackground;
  } else if (label == L"カナ") {
    background = kColorKatakanaBackground;
  } else if (label == L"SKK") {
    background = kColorLatinBackground;
  } else if (label == L"全英") {
    background = kColorWideLatinBackground;
  } else if (label == L"Abbrev") {
    background = kColorAbbrevBackground;
  }
  return ModeIndicatorPalette{background, Darken(background, kBorderDarkenPercent),
                              TextColorFor(background)};
}

ModeIndicator::~ModeIndicator() {
  if (hwnd_ != nullptr) {
    KillTimer(hwnd_, kTimerId);
    DestroyWindow(hwnd_);
  }
  if (font_ != nullptr) DeleteObject(font_);
  if (background_brush_ != nullptr) DeleteObject(background_brush_);
}

void ModeIndicator::SetDurationMs(DWORD duration_ms) {
  duration_ms_ = duration_ms;
}

void ModeIndicator::SetPaletteOverride(const std::wstring& label, COLORREF background) {
  palette_overrides_[label] = background;
}

void ModeIndicator::SetScalePercent(DWORD percent) {
  scale_percent_ = percent;
}

ModeIndicatorPalette ModeIndicator::PaletteForLabel(const std::wstring& label) const {
  const auto override_it = palette_overrides_.find(label);
  if (override_it == palette_overrides_.end()) return ModeIndicatorColors(label);
  const COLORREF background = override_it->second;
  return ModeIndicatorPalette{background, Darken(background, kBorderDarkenPercent),
                              TextColorFor(background)};
}

void ModeIndicator::EnsureBackgroundBrush(const ModeIndicatorPalette& palette) {
  if (background_brush_ != nullptr &&
      background_brush_color_ == palette.background) {
    return;  // Same mode (or same override color): reuse the cached brush.
  }
  if (background_brush_ != nullptr) DeleteObject(background_brush_);
  background_brush_ = CreateSolidBrush(palette.background);
  background_brush_color_ = palette.background;
}

bool ModeIndicator::EnsureWindow() {
  if (hwnd_ != nullptr) return true;
  static bool class_registered = false;
  if (!class_registered) {
    WNDCLASSEXW window_class{};
    window_class.cbSize = sizeof(window_class);
    window_class.lpfnWndProc = &ModeIndicator::WindowProc;
    window_class.hInstance = g_module;
    window_class.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    window_class.hbrBackground = nullptr;  // OnPaint fills the client area.
    window_class.lpszClassName = kWindowClassName;
    if (RegisterClassExW(&window_class) == 0 &&
        GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
      return false;
    }
    class_registered = true;
  }
  // WS_POPUP + the topmost/no-activate/tool-window extended styles keep
  // this window from ever taking focus or appearing in the taskbar/alt-tab
  // list; a TSF text service that steals focus breaks input everywhere.
  hwnd_ = CreateWindowExW(
      WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW, kWindowClassName,
      L"", WS_POPUP, 0, 0, 0, 0, nullptr, nullptr, g_module, this);
  return hwnd_ != nullptr;
}

HFONT ModeIndicator::EnsureFont(UINT dpi) {
  if (font_ != nullptr) return font_;
  NONCLIENTMETRICSW metrics{};
  metrics.cbSize = sizeof(metrics);
  if (!SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof(metrics),
                             &metrics, 0)) {
    return nullptr;
  }
  LOGFONTW font = metrics.lfMessageFont;
  const double dpi_scale =
      static_cast<double>(dpi) / static_cast<double>(USER_DEFAULT_SCREEN_DPI);
  const double user_scale = static_cast<double>(scale_percent_) / 100.0;
  font.lfHeight = static_cast<LONG>(static_cast<double>(font.lfHeight) *
                                    dpi_scale * user_scale);
  font_ = CreateFontIndirectW(&font);
  return font_;
}

void ModeIndicator::Reposition(const POINT& anchor) {
  const UINT dpi = GetWindowDpiOrDefault(hwnd_);
  const double scale =
      static_cast<double>(dpi) / static_cast<double>(USER_DEFAULT_SCREEN_DPI);
  const double user_scale = static_cast<double>(scale_percent_) / 100.0;

  HDC dc = GetDC(hwnd_);
  HFONT font = EnsureFont(dpi);
  HFONT previous_font = nullptr;
  if (font != nullptr) previous_font = static_cast<HFONT>(SelectObject(dc, font));
  SIZE text_size{};
  GetTextExtentPoint32W(dc, label_.c_str(), static_cast<int>(label_.size()),
                        &text_size);
  if (previous_font != nullptr) SelectObject(dc, previous_font);
  ReleaseDC(hwnd_, dc);

  const int padding_x = static_cast<int>(kPaddingX * scale * user_scale);
  const int padding_y = static_cast<int>(kPaddingY * scale * user_scale);
  const int width = static_cast<int>(text_size.cx) + padding_x * 2;
  const int height = static_cast<int>(text_size.cy) + padding_y * 2;

  int x = static_cast<int>(anchor.x) + static_cast<int>(kAnchorGapX * scale);
  int y = static_cast<int>(anchor.y) + static_cast<int>(kAnchorGapY * scale);

  HMONITOR monitor = MonitorFromPoint(anchor, MONITOR_DEFAULTTONEAREST);
  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(monitor_info);
  if (GetMonitorInfoW(monitor, &monitor_info)) {
    const RECT& work_area = monitor_info.rcWork;
    if (x + width > work_area.right) x = static_cast<int>(work_area.right) - width;
    if (y + height > work_area.bottom) y = static_cast<int>(work_area.bottom) - height;
    if (x < work_area.left) x = static_cast<int>(work_area.left);
    if (y < work_area.top) y = static_cast<int>(work_area.top);
  }

  SetWindowPos(hwnd_, HWND_TOPMOST, x, y, width, height,
              SWP_NOACTIVATE | SWP_SHOWWINDOW);
}

void ModeIndicator::Show(const std::wstring& label, const POINT& anchor) {
  if (!EnsureWindow()) return;
  label_ = label;
  current_palette_ = PaletteForLabel(label);
  EnsureBackgroundBrush(current_palette_);
  Reposition(anchor);
  InvalidateRect(hwnd_, nullptr, TRUE);
  ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
  // SetTimer replaces any existing timer sharing this ID on this window,
  // so a second Show() while already visible resets the auto-hide delay
  // instead of stacking a second timer.
  SetTimer(hwnd_, kTimerId, duration_ms_, nullptr);
}

void ModeIndicator::Hide() {
  if (hwnd_ == nullptr) return;
  KillTimer(hwnd_, kTimerId);
  ShowWindow(hwnd_, SW_HIDE);
}

void ModeIndicator::OnPaint() {
  PAINTSTRUCT paint{};
  HDC dc = BeginPaint(hwnd_, &paint);
  RECT client{};
  GetClientRect(hwnd_, &client);

  if (background_brush_ != nullptr) FillRect(dc, &client, background_brush_);

  HBRUSH border_brush = CreateSolidBrush(current_palette_.border);
  FrameRect(dc, &client, border_brush);
  DeleteObject(border_brush);

  if (font_ != nullptr) SelectObject(dc, font_);
  SetTextColor(dc, current_palette_.text);
  SetBkMode(dc, TRANSPARENT);
  RECT text_rect = client;
  DrawTextW(dc, label_.c_str(), static_cast<int>(label_.size()), &text_rect,
           DT_CENTER | DT_VCENTER | DT_SINGLELINE);

  EndPaint(hwnd_, &paint);
}

LRESULT CALLBACK ModeIndicator::WindowProc(HWND hwnd, UINT message,
                                           WPARAM wparam, LPARAM lparam) {
  if (message == WM_NCCREATE) {
    const auto* create = reinterpret_cast<const CREATESTRUCTW*>(lparam);
    SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                      reinterpret_cast<LONG_PTR>(create->lpCreateParams));
    return DefWindowProcW(hwnd, message, wparam, lparam);
  }
  auto* self =
      reinterpret_cast<ModeIndicator*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  switch (message) {
    case WM_PAINT:
      if (self != nullptr) self->OnPaint();
      return 0;
    case WM_TIMER:
      if (self != nullptr && wparam == kTimerId) {
        KillTimer(hwnd, kTimerId);
        ShowWindow(hwnd, SW_HIDE);
      }
      return 0;
    case WM_ERASEBKGND:
      // OnPaint always fills the whole client area; skip the default
      // background erase to avoid flicker.
      return 1;
    case WM_NCDESTROY:
      SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
      return DefWindowProcW(hwnd, message, wparam, lparam);
    default:
      return DefWindowProcW(hwnd, message, wparam, lparam);
  }
}
