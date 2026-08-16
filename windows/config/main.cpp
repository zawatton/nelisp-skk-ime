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
//
// Settings window for the conversion engines.
//
// The engine list is a table rather than a hardcoded pair, because the
// engine process can host more than DDSKK: nelisp-ime's registry offers a
// dictionary-lattice converter and a plain exact-match one, and more will
// follow.  Each engine owns its own settings page; selecting an engine
// swaps the page, so an engine's options never appear under another one.
//
// Layout of the settings, which the text service reads back:
//
//   HKCU\Software\NativeIME
//     Engine            REG_SZ    selected engine id
//     <common values>             mode indicator, debug flags, ...
//   HKCU\Software\NativeIME\Engines\<id>
//     <that engine's values>
//
// Engine-scoped values live under their own key so two engines can use the
// same setting name without colliding, and so removing an engine does not
// strand its settings among the shared ones.

#include <windows.h>

#include <string>
#include <vector>

namespace {

constexpr wchar_t kSettingsKey[] = L"Software\\NativeIME";
constexpr wchar_t kEnginesKey[] = L"Software\\NativeIME\\Engines";

constexpr int kEngineCombo = 101;
constexpr int kSave = 102;
constexpr int kFirstFieldId = 200;

// One editable setting on an engine's page.
struct Field {
  enum class Kind { Checkbox, Number };

  const wchar_t* value_name;   // registry value under the engine's key
  const wchar_t* label;
  Kind kind;
  DWORD fallback;              // used when the value is absent
  DWORD minimum;               // Number only
  DWORD maximum;               // Number only
};

struct Engine {
  const wchar_t* id;           // wire id, also the registry subkey
  const wchar_t* label;        // shown in the combo box
  const wchar_t* note;         // one line describing the engine
  std::vector<Field> fields;
};

// Adding an engine means adding an entry here.  The id must match what the
// engine process answers to `ENGINE LIST', because that is the string the
// text service sends back with `ENGINE SET'.
const std::vector<Engine>& Engines() {
  static const std::vector<Engine> engines = {
      {L"ddskk", L"DDSKK (NeLisp)",
       L"SKK の変換規則をそのまま使います。",
       {{L"InitialKanaMode", L"起動時からかな入力", Field::Kind::Checkbox, 1, 0, 1},
        {L"OkuriAuto", L"送り仮名を自動処理する", Field::Kind::Checkbox, 1, 0, 1}}},
      {L"lattice", L"かな漢字変換 (nelisp-ime)",
       L"辞書ラティスで文全体の変換候補を選びます。",
       {{L"InitialKanaMode", L"起動時からかな入力", Field::Kind::Checkbox, 1, 0, 1},
        {L"CandidateLimit", L"候補の表示数 (1-30)", Field::Kind::Number, 9, 1, 30},
        {L"Learning", L"確定した候補を学習する", Field::Kind::Checkbox, 1, 0, 1}}},
      {L"dictionary", L"完全一致変換 (nelisp-ime)",
       L"読みが完全に一致する候補だけを出す軽量な変換です。",
       {{L"InitialKanaMode", L"起動時からかな入力", Field::Kind::Checkbox, 1, 0, 1}}},
      {L"passthrough", L"パススルー (実験用)",
       L"変換せずアプリへそのまま渡します。",
       {}},
  };
  return engines;
}

// Controls belonging to one engine's page, so the page can be shown and
// hidden as a unit.
struct Page {
  std::vector<HWND> controls;
  std::vector<int> field_ids;
};

std::vector<Page> g_pages;
int g_visible_page = -1;

// Every control with the position it was authored at, in 96-dpi units.
// Win32 places children in physical pixels, so the layout is stored once at
// its logical size and re-applied whenever the DPI changes; without this the
// window is laid out for 96 dpi and Windows stretches the result, which is
// what makes the text look soft on a high-dpi display.
struct Placed {
  HWND control;
  RECT logical;
};

std::vector<Placed> g_placed;
UINT g_dpi = 96;
HFONT g_font = nullptr;

int Scale(int value) { return MulDiv(value, static_cast<int>(g_dpi), 96); }

// GetDpiForWindow needs Windows 10 1607; fall back to the desktop DC so the
// window is still laid out at the right size on older systems.
UINT GetDpiForWindowOrDefault(HWND window) {
  using GetDpiForWindowFn = UINT(WINAPI*)(HWND);
  if (HMODULE user32 = GetModuleHandleW(L"user32.dll")) {
    if (auto fn = reinterpret_cast<GetDpiForWindowFn>(
            GetProcAddress(user32, "GetDpiForWindow"))) {
      const UINT dpi = fn(window);
      if (dpi != 0) return dpi;
    }
  }
  HDC screen = GetDC(nullptr);
  const UINT dpi = screen ? static_cast<UINT>(GetDeviceCaps(screen, LOGPIXELSX))
                          : 96;
  if (screen) ReleaseDC(nullptr, screen);
  return dpi ? dpi : 96;
}

// The shell's UI font at the current DPI.  Controls left alone use the
// bitmap SYSTEM_FONT, which is why an untouched Win32 dialog looks dated
// next to the rest of the shell.
HFONT MakeUiFont(UINT dpi) {
  NONCLIENTMETRICSW metrics{};
  metrics.cbSize = sizeof(metrics);
  if (!SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof(metrics),
                             &metrics, 0)) {
    return nullptr;
  }
  LOGFONTW font = metrics.lfMessageFont;
  font.lfHeight = MulDiv(font.lfHeight, static_cast<int>(dpi), 96);
  return CreateFontIndirectW(&font);
}

void ApplyFont(HWND control) {
  if (g_font) SendMessageW(control, WM_SETFONT,
                           reinterpret_cast<WPARAM>(g_font), TRUE);
}

void Remember(HWND control, int x, int y, int width, int height) {
  g_placed.push_back({control, {x, y, x + width, y + height}});
}

// Re-apply the stored layout at the current DPI.
void Relayout() {
  for (const Placed& placed : g_placed) {
    SetWindowPos(placed.control, nullptr, Scale(placed.logical.left),
                 Scale(placed.logical.top),
                 Scale(placed.logical.right - placed.logical.left),
                 Scale(placed.logical.bottom - placed.logical.top),
                 SWP_NOZORDER | SWP_NOACTIVATE);
    ApplyFont(placed.control);
  }
}

std::wstring EngineSubkey(const wchar_t* id) {
  return std::wstring(kEnginesKey) + L"\\" + id;
}

DWORD ReadDword(const std::wstring& subkey, const wchar_t* name,
                DWORD fallback) {
  HKEY key = nullptr;
  DWORD value = fallback, bytes = sizeof(value), type = 0;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, subkey.c_str(), 0, KEY_READ, &key) !=
      ERROR_SUCCESS) {
    return fallback;
  }
  if (RegQueryValueExW(key, name, nullptr, &type,
                       reinterpret_cast<BYTE*>(&value), &bytes) !=
          ERROR_SUCCESS ||
      type != REG_DWORD) {
    value = fallback;
  }
  RegCloseKey(key);
  return value;
}

bool WriteDword(const std::wstring& subkey, const wchar_t* name, DWORD value) {
  HKEY key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, subkey.c_str(), 0, nullptr, 0,
                      KEY_WRITE, nullptr, &key, nullptr) != ERROR_SUCCESS) {
    return false;
  }
  const LONG status =
      RegSetValueExW(key, name, 0, REG_DWORD,
                     reinterpret_cast<const BYTE*>(&value), sizeof(value));
  RegCloseKey(key);
  return status == ERROR_SUCCESS;
}

std::wstring ReadSelectedEngine() {
  HKEY key = nullptr;
  wchar_t buffer[64] = L"ddskk";
  DWORD bytes = sizeof(buffer), type = 0;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kSettingsKey, 0, KEY_READ, &key) ==
      ERROR_SUCCESS) {
    if (RegQueryValueExW(key, L"Engine", nullptr, &type,
                         reinterpret_cast<BYTE*>(buffer), &bytes) !=
            ERROR_SUCCESS ||
        type != REG_SZ) {
      wcscpy_s(buffer, L"ddskk");
    }
    RegCloseKey(key);
  }
  // A truncated REG_SZ would leave the buffer unterminated.
  buffer[(sizeof(buffer) / sizeof(buffer[0])) - 1] = L'\0';
  return buffer;
}

bool WriteSelectedEngine(const std::wstring& id) {
  HKEY key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, kSettingsKey, 0, nullptr, 0,
                      KEY_WRITE, nullptr, &key, nullptr) != ERROR_SUCCESS) {
    return false;
  }
  const LONG status = RegSetValueExW(
      key, L"Engine", 0, REG_SZ,
      reinterpret_cast<const BYTE*>(id.c_str()),
      static_cast<DWORD>((id.size() + 1) * sizeof(wchar_t)));
  RegCloseKey(key);
  return status == ERROR_SUCCESS;
}

void ShowPage(int index) {
  for (size_t page = 0; page < g_pages.size(); ++page) {
    const int mode = (static_cast<int>(page) == index) ? SW_SHOW : SW_HIDE;
    for (HWND control : g_pages[page].controls) ShowWindow(control, mode);
  }
  g_visible_page = index;
}

// Load an engine's stored values into its page.  Reading happens per page
// rather than once at startup so that switching engines always shows what
// is actually saved for the engine now selected.
void LoadPage(HWND window, size_t index) {
  const Engine& engine = Engines()[index];
  const std::wstring subkey = EngineSubkey(engine.id);
  const Page& page = g_pages[index];
  for (size_t field = 0; field < engine.fields.size(); ++field) {
    const Field& spec = engine.fields[field];
    const DWORD value = ReadDword(subkey, spec.value_name, spec.fallback);
    const int id = page.field_ids[field];
    if (spec.kind == Field::Kind::Checkbox) {
      CheckDlgButton(window, id, value ? BST_CHECKED : BST_UNCHECKED);
    } else {
      SetDlgItemInt(window, id, value, FALSE);
    }
  }
}

bool SavePage(HWND window, size_t index) {
  const Engine& engine = Engines()[index];
  const std::wstring subkey = EngineSubkey(engine.id);
  const Page& page = g_pages[index];
  for (size_t field = 0; field < engine.fields.size(); ++field) {
    const Field& spec = engine.fields[field];
    const int id = page.field_ids[field];
    DWORD value = 0;
    if (spec.kind == Field::Kind::Checkbox) {
      value = IsDlgButtonChecked(window, id) == BST_CHECKED ? 1 : 0;
    } else {
      BOOL translated = FALSE;
      value = GetDlgItemInt(window, id, &translated, FALSE);
      // An empty or non-numeric field falls back rather than storing 0,
      // which for a count would disable the feature by accident.
      if (!translated) value = spec.fallback;
      if (value < spec.minimum) value = spec.minimum;
      if (value > spec.maximum) value = spec.maximum;
      SetDlgItemInt(window, id, value, FALSE);
    }
    if (!WriteDword(subkey, spec.value_name, value)) return false;
  }
  return true;
}

void Save(HWND window) {
  if (g_visible_page < 0) return;
  const size_t index = static_cast<size_t>(g_visible_page);
  const bool ok = WriteSelectedEngine(Engines()[index].id) &&
                  SavePage(window, index);
  if (!ok) {
    MessageBoxW(window, L"設定を保存できませんでした。",
                L"Native IME 設定", MB_OK | MB_ICONERROR);
    return;
  }
  MessageBoxW(window,
              L"設定を保存しました。IMEを切り替えると反映されます。",
              L"Native IME 設定", MB_OK | MB_ICONINFORMATION);
}

HWND MakeControl(HWND parent, const wchar_t* cls, const wchar_t* text,
                 DWORD style, int x, int y, int width, int height, int id) {
  HWND control = CreateWindowW(
      cls, text, WS_CHILD | style, Scale(x), Scale(y), Scale(width),
      Scale(height), parent,
      reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), nullptr, nullptr);
  if (control) {
    Remember(control, x, y, width, height);
    ApplyFont(control);
  }
  return control;
}

void BuildPages(HWND window) {
  const int page_top = 58;
  int next_id = kFirstFieldId;
  g_pages.clear();
  for (const Engine& engine : Engines()) {
    Page page;
    int y = page_top;
    page.controls.push_back(MakeControl(window, L"STATIC", engine.note, 0,
                                        20, y, 400, 20, 0));
    y += 28;
    for (const Field& field : engine.fields) {
      const int id = next_id++;
      if (field.kind == Field::Kind::Checkbox) {
        page.controls.push_back(MakeControl(window, L"BUTTON", field.label,
                                            BS_AUTOCHECKBOX, 20, y, 320, 24,
                                            id));
      } else {
        page.controls.push_back(MakeControl(window, L"STATIC", field.label, 0,
                                            20, y + 4, 190, 20, 0));
        page.controls.push_back(MakeControl(window, L"EDIT", nullptr,
                                            WS_BORDER | ES_NUMBER, 215, y,
                                            60, 24, id));
      }
      page.field_ids.push_back(id);
      y += 30;
    }
    if (engine.fields.empty()) {
      page.controls.push_back(MakeControl(window, L"STATIC",
                                          L"この変換には設定項目がありません。",
                                          0, 20, y, 400, 20, 0));
    }
    g_pages.push_back(std::move(page));
  }
}

LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                            LPARAM lparam) {
  if (message == WM_CREATE) {
    g_dpi = GetDpiForWindowOrDefault(window);
    g_font = MakeUiFont(g_dpi);
    MakeControl(window, L"STATIC", L"変換方式", WS_VISIBLE, 20, 22, 90, 24, 0);
    HWND combo = MakeControl(window, L"COMBOBOX", nullptr,
                             WS_VISIBLE | CBS_DROPDOWNLIST | WS_VSCROLL, 115,
                             18, 300, 240, kEngineCombo);
    for (const Engine& engine : Engines()) {
      SendMessageW(combo, CB_ADDSTRING, 0,
                   reinterpret_cast<LPARAM>(engine.label));
    }
    MakeControl(window, L"BUTTON", L"保存", WS_VISIBLE | BS_DEFPUSHBUTTON,
                330, 235, 85, 30, kSave);

    BuildPages(window);

    const std::wstring selected = ReadSelectedEngine();
    int index = 0;
    for (size_t i = 0; i < Engines().size(); ++i) {
      if (selected == Engines()[i].id) index = static_cast<int>(i);
    }
    SendMessageW(combo, CB_SETCURSEL, index, 0);
    for (size_t i = 0; i < Engines().size(); ++i) LoadPage(window, i);
    ShowPage(index);
    return 0;
  }
  if (message == WM_COMMAND) {
    if (LOWORD(wparam) == kSave) { Save(window); return 0; }
    if (LOWORD(wparam) == kEngineCombo && HIWORD(wparam) == CBN_SELCHANGE) {
      const LRESULT selected = SendDlgItemMessageW(window, kEngineCombo,
                                                   CB_GETCURSEL, 0, 0);
      if (selected != CB_ERR) ShowPage(static_cast<int>(selected));
      return 0;
    }
  }
  if (message == WM_DPICHANGED) {
    // Moving to a monitor with a different scale: adopt the new DPI, rebuild
    // the font at that size, and re-apply the stored layout.  lparam is the
    // frame Windows suggests, which already accounts for the new scale.
    g_dpi = HIWORD(wparam);
    if (g_font) DeleteObject(g_font);
    g_font = MakeUiFont(g_dpi);
    const RECT* suggested = reinterpret_cast<const RECT*>(lparam);
    SetWindowPos(window, nullptr, suggested->left, suggested->top,
                 suggested->right - suggested->left,
                 suggested->bottom - suggested->top,
                 SWP_NOZORDER | SWP_NOACTIVATE);
    Relayout();
    InvalidateRect(window, nullptr, TRUE);
    return 0;
  }
  if (message == WM_DESTROY) {
    if (g_font) { DeleteObject(g_font); g_font = nullptr; }
    PostQuitMessage(0);
    return 0;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

}  // namespace

// Declare per-monitor DPI awareness before any window exists.  Without it
// Windows renders the window at 96 dpi and bitmap-stretches the result,
// which is exactly the softness a high-dpi display shows.  Done in code
// rather than a manifest so the executable needs no extra build inputs.
void EnablePerMonitorDpi() {
  using SetContextFn = BOOL(WINAPI*)(DPI_AWARENESS_CONTEXT);
  using SetAwarenessFn = BOOL(WINAPI*)(int);
  HMODULE user32 = GetModuleHandleW(L"user32.dll");
  if (user32) {
    if (auto set_context = reinterpret_cast<SetContextFn>(
            GetProcAddress(user32, "SetProcessDpiAwarenessContext"))) {
      if (set_context(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)) return;
      if (set_context(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE)) return;
    }
    // Windows 8.1 and earlier: system-wide awareness is the best available.
    if (auto set_aware = reinterpret_cast<SetAwarenessFn>(
            GetProcAddress(user32, "SetProcessDPIAware"))) {
      set_aware(1);
    }
  }
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int show) {
  EnablePerMonitorDpi();
  constexpr wchar_t name[] = L"NativeImeConfigWindow";
  WNDCLASSW cls{};
  cls.hInstance = instance;
  cls.lpfnWndProc = WindowProc;
  cls.lpszClassName = name;
  cls.hCursor = LoadCursorW(nullptr, IDC_ARROW);
  cls.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
  RegisterClassW(&cls);
  // The window is authored at 96 dpi like its controls; size it for the
  // monitor it will appear on.
  HDC screen = GetDC(nullptr);
  const int dpi = screen ? GetDeviceCaps(screen, LOGPIXELSX) : 96;
  if (screen) ReleaseDC(nullptr, screen);
  HWND window = CreateWindowW(
      name, L"Native IME 設定", WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU,
      CW_USEDEFAULT, CW_USEDEFAULT, MulDiv(455, dpi, 96),
      MulDiv(320, dpi, 96), nullptr, nullptr, instance, nullptr);
  if (!window) return 2;
  ShowWindow(window, show);
  UpdateWindow(window);
  MSG message{};
  while (GetMessageW(&message, nullptr, 0, 0) > 0) {
    TranslateMessage(&message);
    DispatchMessageW(&message);
  }
  return 0;
}
