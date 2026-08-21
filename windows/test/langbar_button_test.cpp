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

#include <cassert>
#include <cstdlib>

#ifdef NDEBUG
#undef assert
#define assert(condition) ((condition) ? static_cast<void>(0) : std::abort())
#endif

class Handler final : public LangBarButtonHandler {
 public: void SelectInputEngine(bool ddskk) override { selected = ddskk; }
  void ToggleInputMode() override { toggled = true; }
  void ShowSettings() override { settings = true; }
  void SelectInputMode(const std::wstring& label) override { selected_mode = label; }
  std::wstring CurrentModeLabel() const override { return L"かな"; }
  ModeIndicatorPalette CurrentModePalette() const override {
    return ModeIndicatorPalette{RGB(0xC0, 0x20, 0x20), RGB(0x88, 0x16, 0x16),
                                RGB(0xFF, 0xFF, 0xFF)};
  }
  bool selected = false;
  bool toggled = false;
  bool settings = false;
  std::wstring selected_mode;
};
int main() {
  Handler handler;
  auto* settings_button = new LangBarButton(
      &handler, GUID_DdskkSettingsButton,
      TF_LBI_STYLE_BTN_MENU | TF_LBI_STYLE_SHOWNINTRAY,
      L"NeLisp IME", LangBarButton::Kind::kSettings);
  TF_LANGBARITEMINFO info{};
  assert(SUCCEEDED(settings_button->GetInfo(&info)));
  assert((info.dwStyle & TF_LBI_STYLE_SHOWNINTRAY) != 0);
  assert((info.dwStyle & TF_LBI_STYLE_BTN_MENU) != 0);
  assert(info.ulSort == 1);
  DWORD status = 0;
  assert(SUCCEEDED(settings_button->GetStatus(&status)) && status == 0);
  HICON logo_icon = nullptr;
  assert(SUCCEEDED(settings_button->GetIcon(&logo_icon)) &&
         logo_icon != nullptr);
  DestroyIcon(logo_icon);
  assert(SUCCEEDED(settings_button->Show(FALSE)));
  assert(SUCCEEDED(settings_button->GetStatus(&status)) && status == 0);
  settings_button->Release();

  // The input-mode item: GUID_LBI_INPUTMODE/TF_LBI_STYLE_SHOWNINTRAY,
  // independently from the logo item, with a mode-aware GetIcon() and a
  // real ITfSource (AdviseSink/UnadviseSink/NotifyUpdate).
  auto* input_mode_button = new LangBarButton(
      &handler, GUID_LBI_INPUTMODE,
      TF_LBI_STYLE_BTN_BUTTON | TF_LBI_STYLE_SHOWNINTRAY,
      L"NeLisp IME input mode", LangBarButton::Kind::kInputMode);
  assert(SUCCEEDED(input_mode_button->GetInfo(&info)));
  assert((info.dwStyle & TF_LBI_STYLE_SHOWNINTRAY) != 0);
  HICON icon = nullptr;
  assert(SUCCEEDED(input_mode_button->GetIcon(&icon)) && icon != nullptr);
  DestroyIcon(icon);

  ITfSource* source = nullptr;
  assert(SUCCEEDED(input_mode_button->QueryInterface(
      IID_ITfSource, reinterpret_cast<void**>(&source))));
  assert(source != nullptr);
  source->Release();

  input_mode_button->Release();
}
