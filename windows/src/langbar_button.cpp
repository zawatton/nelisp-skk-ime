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

#include <oleauto.h>

LangBarSettingsButton::LangBarSettingsButton(LangBarButtonHandler* handler)
    : handler_(handler) {}
HRESULT LangBarSettingsButton::QueryInterface(REFIID iid, void** object) {
  if (!object) return E_POINTER; *object = nullptr;
  if (iid != IID_IUnknown && iid != IID_ITfLangBarItem &&
      iid != IID_ITfLangBarItemButton) return E_NOINTERFACE;
  *object = static_cast<ITfLangBarItemButton*>(this); AddRef(); return S_OK;
}
ULONG LangBarSettingsButton::AddRef() { return InterlockedIncrement(&ref_count_); }
ULONG LangBarSettingsButton::Release() { const ULONG n=InterlockedDecrement(&ref_count_); if(!n) delete this; return n; }
HRESULT LangBarSettingsButton::GetInfo(TF_LANGBARITEMINFO* info) {
  if(!info) return E_POINTER; *info = {};
  info->clsidService=CLSID_DdskkTextService; info->guidItem=GUID_DdskkSettingsButton;
  info->dwStyle=TF_LBI_STYLE_BTN_BUTTON | TF_LBI_STYLE_SHOWNINTRAYONLY;
  info->ulSort=1; wcscpy_s(info->szDescription, L"DDSKK settings"); return S_OK;
}
HRESULT LangBarSettingsButton::GetStatus(DWORD* status) { if(!status)return E_POINTER; *status=shown_?0:TF_LBI_STATUS_HIDDEN; return S_OK; }
HRESULT LangBarSettingsButton::Show(BOOL show) { shown_=show!=FALSE; return S_OK; }
HRESULT LangBarSettingsButton::GetTooltipString(BSTR* value) { if(!value)return E_POINTER; *value=SysAllocString(L"DDSKK settings"); return *value?S_OK:E_OUTOFMEMORY; }
HRESULT LangBarSettingsButton::OnClick(TfLBIClick click, POINT, const RECT*) {
  if (!handler_) return E_UNEXPECTED;
  if (click == TF_LBI_CLK_LEFT) {
    handler_->ToggleInputMode();
    return S_OK;
  }
  if (click == TF_LBI_CLK_RIGHT) {
    HMENU menu = CreatePopupMenu();
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
  }
  return S_OK;
}
HRESULT LangBarSettingsButton::InitMenu(ITfMenu*) { return E_NOTIMPL; }
HRESULT LangBarSettingsButton::OnMenuSelect(UINT) { return E_NOTIMPL; }
HRESULT LangBarSettingsButton::GetIcon(HICON* icon) { if(!icon)return E_POINTER; *icon=LoadIconW(nullptr, IDI_APPLICATION); return *icon?S_OK:E_FAIL; }
HRESULT LangBarSettingsButton::GetText(BSTR* value) { if(!value)return E_POINTER; *value=SysAllocString(L"DDSKK"); return *value?S_OK:E_OUTOFMEMORY; }
