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

#include <windows.h>

namespace {
constexpr int kEngine = 101, kKana = 102, kSave = 103;

void Load(HWND window) {
  HKEY key = nullptr;
  wchar_t engine[32] = L"ddskk";
  DWORD bytes = sizeof(engine), kana = 1, kana_bytes = sizeof(kana);
  if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\NativeIME", 0,
                    KEY_READ, &key) == ERROR_SUCCESS) {
    RegQueryValueExW(key, L"Engine", nullptr, nullptr,
                     reinterpret_cast<BYTE*>(engine), &bytes);
    RegQueryValueExW(key, L"InitialKanaMode", nullptr, nullptr,
                     reinterpret_cast<BYTE*>(&kana), &kana_bytes);
    RegCloseKey(key);
  }
  SendDlgItemMessageW(window, kEngine, CB_SETCURSEL,
                      wcscmp(engine, L"passthrough") == 0 ? 1 : 0, 0);
  CheckDlgButton(window, kKana, kana ? BST_CHECKED : BST_UNCHECKED);
}

void Save(HWND window) {
  const LRESULT selected = SendDlgItemMessageW(window, kEngine, CB_GETCURSEL, 0, 0);
  const wchar_t* engine = selected == 1 ? L"passthrough" : L"ddskk";
  DWORD kana = IsDlgButtonChecked(window, kKana) == BST_CHECKED;
  HKEY key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\NativeIME", 0, nullptr,
      0, KEY_WRITE, nullptr, &key, nullptr) != ERROR_SUCCESS) return;
  RegSetValueExW(key, L"Engine", 0, REG_SZ,
      reinterpret_cast<const BYTE*>(engine),
      static_cast<DWORD>((wcslen(engine) + 1) * sizeof(wchar_t)));
  RegSetValueExW(key, L"InitialKanaMode", 0, REG_DWORD,
      reinterpret_cast<const BYTE*>(&kana), sizeof(kana));
  RegCloseKey(key);
  MessageBoxW(window, L"設定を保存しました。IMEを切り替えると反映されます。",
              L"Native IME settings", MB_OK | MB_ICONINFORMATION);
}

LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                            LPARAM lparam) {
  if (message == WM_CREATE) {
    CreateWindowW(L"STATIC", L"入力エンジン", WS_CHILD | WS_VISIBLE,
                  20, 22, 110, 24, window, nullptr, nullptr, nullptr);
    HWND combo = CreateWindowW(L"COMBOBOX", nullptr,
        WS_CHILD | WS_VISIBLE | CBS_DROPDOWNLIST, 135, 18, 220, 100,
        window, reinterpret_cast<HMENU>(static_cast<INT_PTR>(kEngine)), nullptr, nullptr);
    SendMessageW(combo, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(L"DDSKK (NeLisp)"));
    SendMessageW(combo, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(L"パススルー (実験用)"));
    CreateWindowW(L"BUTTON", L"起動時からかな入力",
        WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX, 20, 65, 250, 24,
        window, reinterpret_cast<HMENU>(static_cast<INT_PTR>(kKana)), nullptr, nullptr);
    CreateWindowW(L"BUTTON", L"保存", WS_CHILD | WS_VISIBLE | BS_DEFPUSHBUTTON,
        270, 110, 85, 30, window,
        reinterpret_cast<HMENU>(static_cast<INT_PTR>(kSave)), nullptr, nullptr);
    Load(window); return 0;
  }
  if (message == WM_COMMAND && LOWORD(wparam) == kSave) { Save(window); return 0; }
  if (message == WM_DESTROY) { PostQuitMessage(0); return 0; }
  return DefWindowProcW(window, message, wparam, lparam);
}
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int show) {
  constexpr wchar_t name[] = L"NativeImeConfigWindow";
  WNDCLASSW cls{}; cls.hInstance = instance; cls.lpfnWndProc = WindowProc;
  cls.lpszClassName = name; cls.hCursor = LoadCursorW(nullptr, IDC_ARROW);
  cls.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
  RegisterClassW(&cls);
  HWND window = CreateWindowW(name, L"Native IME 設定",
      WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU, CW_USEDEFAULT, CW_USEDEFAULT,
      395, 200, nullptr, nullptr, instance, nullptr);
  if (!window) return 2;
  ShowWindow(window, show); UpdateWindow(window);
  MSG message{}; while (GetMessageW(&message, nullptr, 0, 0) > 0) {
    TranslateMessage(&message); DispatchMessageW(&message);
  }
  return 0;
}
