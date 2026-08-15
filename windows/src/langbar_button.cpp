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

#include "langbar_button.h"

// CONNECT_E_NOCONNECTION/CONNECT_E_ADVISELIMIT/CONNECT_E_CANNOTCONNECT
// (used by AdviseSink()/UnadviseSink() below) are the standard IConnectionPoint
// status codes, declared here rather than pulled in transitively via
// <msctf.h>/<ctfutb.h> under this project's WIN32_LEAN_AND_MEAN build.
#include <olectl.h>
#include <oleauto.h>

#include <utility>

namespace {

// Only one ITfLangBarItemSink is ever realistically advised (TSF's own
// langbar host); a fixed cookie is enough since there is never more than
// one live advise to disambiguate.
constexpr DWORD kSinkCookie = 1;

// GetDpiForSystem is Windows 10 1607+; GetIcon() receives no HWND to
// query a per-monitor DPI from anyway, so this looks it up dynamically
// (mirrors mode_indicator.cpp's GetWindowDpiOrDefault) and falls back to
// the unscaled default on older systems this TIP still supports.
UINT GetSystemDpiOrDefault() {
  using GetDpiForSystemFn = UINT(WINAPI*)();
  const HMODULE user32 = GetModuleHandleW(L"user32.dll");
  const auto get_dpi_for_system =
      user32 == nullptr
          ? nullptr
          : reinterpret_cast<GetDpiForSystemFn>(
                GetProcAddress(user32, "GetDpiForSystem"));
  if (get_dpi_for_system != nullptr) {
    const UINT dpi = get_dpi_for_system();
    if (dpi != 0) return dpi;
  }
  return USER_DEFAULT_SCREEN_DPI;
}

// True if (x, y) falls inside a `size` x `size` square whose corners are
// rounded to `radius`, via the standard "rect body, or within `radius` of
// the nearest corner circle's center" test. Used to hand-rasterize
// CreateModeIcon()'s alpha mask; deliberately not antialiased (sharp
// edges read fine at a 16-24px tray icon size, and it keeps the whole
// routine simple and GDI-independent for the shape itself).
bool InsideRoundedSquare(int x, int y, int size, int radius) {
  const int corner_x = x < radius ? radius
                      : (x >= size - radius ? size - radius - 1 : -1);
  const int corner_y = y < radius ? radius
                      : (y >= size - radius ? size - radius - 1 : -1);
  if (corner_x < 0 || corner_y < 0) return true;  // rect body, no corner
  const int dx = x - corner_x;
  const int dy = y - corner_y;
  return dx * dx + dy * dy <= radius * radius;
}

// Builds a DPI-scaled 32bpp icon: a filled rounded-rect in `fill_color`
// with a single centered white glyph. There are no .ico resources for
// this -- the mode changes at runtime -- so the icon is synthesized via a
// top-down 32bpp DIB section painted through GDI for the color channels,
// then a hand-rasterized alpha mask (see InsideRoundedSquare) rather than
// relying on GDI to produce a usable alpha channel: GDI drawing calls do
// not touch a DIB section's alpha byte at all, so without this second
// pass every painted pixel would come out fully transparent regardless of
// its RGB value. This is the proper 32bpp-alpha CreateIconIndirect path;
// legacy TEXTCOLORICON-style AND/XOR masking cannot express partial
// alpha and is deliberately not used here.
HICON CreateModeIcon(wchar_t glyph, COLORREF fill_color) {
  const UINT dpi = GetSystemDpiOrDefault();
  const int size = MulDiv(16, static_cast<int>(dpi), 96);
  if (size <= 0) return nullptr;

  BITMAPINFO bitmap_info{};
  bitmap_info.bmiHeader.biSize = sizeof(bitmap_info.bmiHeader);
  bitmap_info.bmiHeader.biWidth = size;
  bitmap_info.bmiHeader.biHeight = -size;  // top-down
  bitmap_info.bmiHeader.biPlanes = 1;
  bitmap_info.bmiHeader.biBitCount = 32;
  bitmap_info.bmiHeader.biCompression = BI_RGB;

  void* bits = nullptr;
  HBITMAP color_bitmap = CreateDIBSection(nullptr, &bitmap_info,
      DIB_RGB_COLORS, &bits, nullptr, 0);
  if (color_bitmap == nullptr || bits == nullptr) return nullptr;

  HDC screen_dc = GetDC(nullptr);
  HDC mem_dc = CreateCompatibleDC(screen_dc);
  ReleaseDC(nullptr, screen_dc);
  if (mem_dc == nullptr) {
    DeleteObject(color_bitmap);
    return nullptr;
  }
  HGDIOBJ previous_bitmap = SelectObject(mem_dc, color_bitmap);

  // Paint the color channels only; the hand-rasterized alpha mask below
  // is what actually shapes the icon, so a plain square fill here is
  // enough -- its corners simply end up masked to fully transparent.
  RECT canvas{0, 0, size, size};
  HBRUSH fill_brush = CreateSolidBrush(fill_color);
  FillRect(mem_dc, &canvas, fill_brush);
  DeleteObject(fill_brush);

  SetBkMode(mem_dc, TRANSPARENT);
  SetTextColor(mem_dc, RGB(0xFF, 0xFF, 0xFF));
  LOGFONTW font{};
  font.lfHeight = -(size * 3 / 4);
  font.lfWeight = FW_SEMIBOLD;
  font.lfCharSet = DEFAULT_CHARSET;
  font.lfQuality = CLEARTYPE_QUALITY;
  wcscpy_s(font.lfFaceName, L"Yu Gothic UI");
  HFONT glyph_font = CreateFontIndirectW(&font);
  HGDIOBJ previous_font = nullptr;
  if (glyph_font != nullptr) previous_font = SelectObject(mem_dc, glyph_font);
  const wchar_t text[2] = {glyph, L'\0'};
  DrawTextW(mem_dc, text, 1, &canvas, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  if (previous_font != nullptr) SelectObject(mem_dc, previous_font);
  if (glyph_font != nullptr) DeleteObject(glyph_font);

  GdiFlush();
  SelectObject(mem_dc, previous_bitmap);
  DeleteDC(mem_dc);

  // Hand-rasterized alpha mask: opaque inside the rounded rect, fully
  // transparent outside it. See InsideRoundedSquare() and the function
  // comment above for why this cannot just come from GDI.
  const int radius = size / 4;
  auto* pixels = static_cast<BYTE*>(bits);
  for (int y = 0; y < size; ++y) {
    for (int x = 0; x < size; ++x) {
      BYTE* pixel = pixels + (static_cast<size_t>(y) * size + x) * 4;
      pixel[3] = InsideRoundedSquare(x, y, size, radius) ? 0xFF : 0x00;
    }
  }

  // A 32bpp-alpha color bitmap still requires a mask bitmap; an all-zero
  // (all "not masked") 1bpp AND mask is the conventional choice here,
  // since the real transparency comes entirely from the alpha channel
  // just written above.
  HBITMAP mask_bitmap = CreateBitmap(size, size, 1, 1, nullptr);
  if (mask_bitmap != nullptr) {
    HDC mask_dc = CreateCompatibleDC(nullptr);
    if (mask_dc != nullptr) {
      HGDIOBJ previous_mask = SelectObject(mask_dc, mask_bitmap);
      PatBlt(mask_dc, 0, 0, size, size, BLACKNESS);
      SelectObject(mask_dc, previous_mask);
      DeleteDC(mask_dc);
    }
  }

  ICONINFO icon_info{};
  icon_info.fIcon = TRUE;
  icon_info.hbmMask = mask_bitmap;
  icon_info.hbmColor = color_bitmap;
  HICON icon = CreateIconIndirect(&icon_info);

  // CreateIconIndirect copies both bitmaps internally; the originals must
  // still be freed by the caller regardless of success.
  if (mask_bitmap != nullptr) DeleteObject(mask_bitmap);
  DeleteObject(color_bitmap);
  return icon;
}

// Mirrors ModeIndicatorLabel()'s label set (mode_indicator.h) onto the
// single glyph this tray icon can show. "Abbrev" (reachable mid-
// composition, but never one of this menu's four base modes -- see
// LangBarButton::OnClick()) and anything unrecognized both fall back to a
// plain dash, matching the "disabled/unknown" case.
wchar_t GlyphForModeLabel(const std::wstring& label) {
  if (label == L"かな") return L'あ';
  if (label == L"カナ") return L'ア';
  if (label == L"全英") return L'Ａ';
  if (label == L"SKK") return L'A';
  return L'\x2015';  // "―"
}

}  // namespace

LangBarButton::LangBarButton(LangBarButtonHandler* handler, REFGUID item_guid,
                             DWORD style, std::wstring display_name, Kind kind)
    : handler_(handler), item_guid_(item_guid), style_(style),
      display_name_(std::move(display_name)), kind_(kind) {}

LangBarButton::~LangBarButton() {
  if (sink_ != nullptr) sink_->Release();
}

HRESULT LangBarButton::QueryInterface(REFIID iid, void** object) {
  if (!object) return E_POINTER; *object = nullptr;
  if (iid == IID_IUnknown || iid == IID_ITfLangBarItem ||
      iid == IID_ITfLangBarItemButton) {
    *object = static_cast<ITfLangBarItemButton*>(this);
  } else if (iid == IID_ITfSource) {
    *object = static_cast<ITfSource*>(this);
  } else {
    return E_NOINTERFACE;
  }
  AddRef();
  return S_OK;
}
ULONG LangBarButton::AddRef() { return InterlockedIncrement(&ref_count_); }
ULONG LangBarButton::Release() { const ULONG n=InterlockedDecrement(&ref_count_); if(!n) delete this; return n; }
HRESULT LangBarButton::GetInfo(TF_LANGBARITEMINFO* info) {
  if(!info) return E_POINTER; *info = {};
  info->clsidService=CLSID_DdskkTextService; info->guidItem=item_guid_;
  info->dwStyle=style_;
  // The input-mode item sorts ahead of the settings item, matching where
  // Windows' own taskbar input indicators typically sit relative to a
  // TIP's other langbar buttons.
  info->ulSort = kind_ == Kind::kInputMode ? 0 : 1;
  wcscpy_s(info->szDescription, display_name_.c_str()); return S_OK;
}
HRESULT LangBarButton::GetStatus(DWORD* status) { if(!status)return E_POINTER; *status=shown_?0:TF_LBI_STATUS_HIDDEN; return S_OK; }
HRESULT LangBarButton::Show(BOOL show) { shown_=show!=FALSE; return S_OK; }
HRESULT LangBarButton::GetTooltipString(BSTR* value) { if(!value)return E_POINTER; *value=SysAllocString(display_name_.c_str()); return *value?S_OK:E_OUTOFMEMORY; }
HRESULT LangBarButton::OnClick(TfLBIClick click, POINT, const RECT*) {
  if (!handler_) return E_UNEXPECTED;
  if (click == TF_LBI_CLK_LEFT) {
    // Left click always toggles kana<->latin input, for both items alike.
    handler_->ToggleInputMode();
    return S_OK;
  }
  if (click != TF_LBI_CLK_RIGHT) return S_OK;

  HMENU menu = CreatePopupMenu();
  if (menu == nullptr) return E_OUTOFMEMORY;

  if (kind_ == Kind::kInputMode) {
    // menu_text is what the user sees; label is the canonical
    // ModeIndicatorLabel()/ModeIndicatorColors() key -- these differ for
    // katakana ("カタカナ" vs "カナ"), so both are tracked per entry
    // rather than reusing one string for both roles.
    struct ModeMenuEntry { UINT id; const wchar_t* menu_text; const wchar_t* label; };
    constexpr ModeMenuEntry kModes[] = {
        {1, L"かな", L"かな"},
        {2, L"カタカナ", L"カナ"},
        {3, L"全英", L"全英"},
        {4, L"SKK", L"SKK"},
    };
    const std::wstring current = handler_->CurrentModeLabel();
    for (UINT index = 0; index < 4; ++index) {
      const ModeMenuEntry& entry = kModes[index];
      MENUITEMINFOW item{};
      item.cbSize = sizeof(item);
      item.fMask = MIIM_ID | MIIM_STRING | MIIM_FTYPE | MIIM_STATE;
      item.fType = MFT_STRING | MFT_RADIOCHECK;
      item.fState = current == entry.label ? MFS_CHECKED : MFS_UNCHECKED;
      item.wID = entry.id;
      item.dwTypeData = const_cast<LPWSTR>(entry.menu_text);
      InsertMenuItemW(menu, index, TRUE, &item);
    }
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, 5, L"設定");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, 6, L"キャンセル");
    POINT cursor{}; GetCursorPos(&cursor);
    const UINT command = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON,
        cursor.x, cursor.y, 0, GetForegroundWindow(), nullptr);
    DestroyMenu(menu);
    if (command >= 1 && command <= 4) {
      // Routes through TextService::SelectInputMode(), which sends
      // CONTROL CANCEL (Ctrl+J-equivalent) and, for anything but かな,
      // one follow-up key -- the same engine-driving primitives
      // OnKeyDown/ToggleInputMode already use, and the same place that
      // guards against firing mid-composition. This menu never invents
      // its own path into the engine.
      handler_->SelectInputMode(kModes[command - 1].label);
    } else if (command == 5) {
      handler_->ShowSettings();
    }
    // command == 6 (キャンセル) or 0 (dismissed without a choice): no-op.
    return S_OK;
  }

  // Kind::kSettings: unchanged engine-selection + settings menu.
  AppendMenuW(menu, MF_STRING, 1, L"DDSKK");
  AppendMenuW(menu, MF_STRING, 2, L"パススルー");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, 3, L"設定...");
  POINT cursor{}; GetCursorPos(&cursor);
  const UINT command = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON,
      cursor.x, cursor.y, 0, GetForegroundWindow(), nullptr);
  DestroyMenu(menu);
  if (command == 1) handler_->SelectInputEngine(true);
  if (command == 2) handler_->SelectInputEngine(false);
  if (command == 3) handler_->ShowSettings();
  return S_OK;
}
HRESULT LangBarButton::InitMenu(ITfMenu*) { return E_NOTIMPL; }
HRESULT LangBarButton::OnMenuSelect(UINT) { return E_NOTIMPL; }
HRESULT LangBarButton::GetIcon(HICON* icon) {
  if (!icon) return E_POINTER;
  if (kind_ != Kind::kInputMode || handler_ == nullptr) {
    *icon = LoadIconW(nullptr, IDI_APPLICATION);
    return *icon ? S_OK : E_FAIL;
  }
  // Mode-aware dynamic icon: no .ico resources, since the glyph/color
  // depend on runtime state. Reuses the exact palette
  // MaybeShowModeIndicator() would paint (see TextService::
  // CurrentModePalette(), threaded from ModeIndicator's already-loaded
  // registry overrides -- this never re-reads the registry itself).
  const std::wstring label = handler_->CurrentModeLabel();
  const ModeIndicatorPalette palette = handler_->CurrentModePalette();
  *icon = CreateModeIcon(GlyphForModeLabel(label), palette.background);
  return *icon ? S_OK : E_FAIL;
}
HRESULT LangBarButton::GetText(BSTR* value) { if(!value)return E_POINTER; *value=SysAllocString(display_name_.c_str()); return *value?S_OK:E_OUTOFMEMORY; }

HRESULT LangBarButton::AdviseSink(REFIID riid, IUnknown* unknown, DWORD* cookie) {
  if (unknown == nullptr || cookie == nullptr) return E_INVALIDARG;
  if (riid != IID_ITfLangBarItemSink) return CONNECT_E_CANNOTCONNECT;
  if (sink_ != nullptr) return CONNECT_E_ADVISELIMIT;
  ITfLangBarItemSink* sink = nullptr;
  const HRESULT result = unknown->QueryInterface(
      IID_ITfLangBarItemSink, reinterpret_cast<void**>(&sink));
  if (FAILED(result)) return result;
  sink_ = sink;
  *cookie = kSinkCookie;
  return S_OK;
}
HRESULT LangBarButton::UnadviseSink(DWORD cookie) {
  if (cookie != kSinkCookie || sink_ == nullptr) return CONNECT_E_NOCONNECTION;
  sink_->Release();
  sink_ = nullptr;
  return S_OK;
}
void LangBarButton::NotifyUpdate(DWORD flags) {
  if (sink_ != nullptr) sink_->OnUpdate(flags);
}
