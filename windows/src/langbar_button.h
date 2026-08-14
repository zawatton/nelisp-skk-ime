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

#include "guids.h"

#include <ctfutb.h>

class LangBarButtonHandler {
 public:
  virtual void SelectInputEngine(bool ddskk) = 0;
  virtual void ToggleInputMode() = 0;
  virtual void ShowSettings() = 0;
 protected:
  ~LangBarButtonHandler() = default;
};

class LangBarSettingsButton final : public ITfLangBarItemButton {
 public:
  explicit LangBarSettingsButton(LangBarButtonHandler* handler);
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** object) override;
  ULONG STDMETHODCALLTYPE AddRef() override;
  ULONG STDMETHODCALLTYPE Release() override;
  HRESULT STDMETHODCALLTYPE GetInfo(TF_LANGBARITEMINFO* info) override;
  HRESULT STDMETHODCALLTYPE GetStatus(DWORD* status) override;
  HRESULT STDMETHODCALLTYPE Show(BOOL show) override;
  HRESULT STDMETHODCALLTYPE GetTooltipString(BSTR* tooltip) override;
  HRESULT STDMETHODCALLTYPE OnClick(TfLBIClick click, POINT point,
                                    const RECT* area) override;
  HRESULT STDMETHODCALLTYPE InitMenu(ITfMenu* menu) override;
  HRESULT STDMETHODCALLTYPE OnMenuSelect(UINT id) override;
  HRESULT STDMETHODCALLTYPE GetIcon(HICON* icon) override;
  HRESULT STDMETHODCALLTYPE GetText(BSTR* text) override;
 private:
  ~LangBarSettingsButton() = default;
  LONG ref_count_ = 1;
  bool shown_ = true;
  LangBarButtonHandler* handler_;
};
