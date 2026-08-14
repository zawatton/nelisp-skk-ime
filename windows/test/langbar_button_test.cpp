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
  bool selected = false;
  bool toggled = false;
  bool settings = false;
};
int main() {
  Handler handler;
  auto* button = new LangBarSettingsButton(&handler);
  TF_LANGBARITEMINFO info{};
  assert(SUCCEEDED(button->GetInfo(&info)));
  assert((info.dwStyle & TF_LBI_STYLE_SHOWNINTRAYONLY) != 0);
  assert((info.dwStyle & TF_LBI_STYLE_BTN_BUTTON) != 0);
  DWORD status = 0;
  assert(SUCCEEDED(button->GetStatus(&status)) && status == 0);
  assert(SUCCEEDED(button->Show(FALSE)));
  assert(SUCCEEDED(button->GetStatus(&status)) &&
         (status & TF_LBI_STATUS_HIDDEN) != 0);
  button->Release();
}
