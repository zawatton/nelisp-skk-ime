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
#include "mode_indicator.h"

#include <ctffunc.h>  // GUID_LBI_INPUTMODE
#include <ctfutb.h>
#include <msctf.h>
#include <windows.h>

#include <string>

class LangBarButtonHandler {
 public:
  virtual void SelectInputEngine(bool ddskk) = 0;
  virtual void ToggleInputMode() = 0;
  virtual void ShowSettings() = 0;
  // Routes a right-click mode selection from the input-mode item's menu
  // (one of "かな"/"カナ"/"全英"/"SKK" -- the same label strings
  // ModeIndicatorLabel()/ModeIndicatorColors() use as keys) through the
  // engine. See TextService::SelectInputMode() for the actual CONTROL
  // CANCEL + optional follow-up key path and its composing guard.
  virtual void SelectInputMode(const std::wstring& label) = 0;
  // The current mode label and its resolved (override-aware) palette,
  // exactly what MaybeShowModeIndicator() derives and renders -- exposed
  // so the input-mode item's GetIcon()/OnClick() never have to duplicate
  // or re-derive that state (or re-read the registry) themselves.
  virtual std::wstring CurrentModeLabel() const = 0;
  virtual ModeIndicatorPalette CurrentModePalette() const = 0;
 protected:
  ~LangBarButtonHandler() = default;
};

// A single langbar/taskbar item, parameterized by GUID/style/display name/
// role rather than forked into a second class per item: this DLL adds two
// of these (see TextService::AddLangBarButton()) -- the original settings
// button (Kind::kSettings) and the taskbar "A/あ" input-mode indicator
// Windows 10/11 render for GUID_LBI_INPUTMODE (Kind::kInputMode). Only
// GetIcon() and the right-click menu built in OnClick() actually differ
// between the two roles; everything else (GetInfo/GetStatus/GetText/...,
// and OnClick()'s left-click handling) is shared.
//
// Also implements ITfSource so TSF's langbar host can advise an
// ITfLangBarItemSink and be notified (via NotifyUpdate(), called from
// MaybeShowModeIndicator()) when the input-mode item's icon/status need a
// repaint -- without this, GetIcon() would only ever be re-queried on
// TSF's own schedule, not right after a mode change.
class LangBarButton final : public ITfLangBarItemButton, public ITfSource {
 public:
  enum class Kind { kSettings, kInputMode };

  LangBarButton(LangBarButtonHandler* handler, REFGUID item_guid,
               DWORD style, std::wstring display_name, Kind kind);

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

  // ITfSource. Only one simultaneous ITfLangBarItemSink advise is
  // supported -- TSF's own langbar host is the only realistic caller, and
  // a second concurrent advise fails with CONNECT_E_ADVISELIMIT rather
  // than silently replacing or leaking the first sink.
  HRESULT STDMETHODCALLTYPE AdviseSink(REFIID riid, IUnknown* unknown,
                                       DWORD* cookie) override;
  HRESULT STDMETHODCALLTYPE UnadviseSink(DWORD cookie) override;

  // Calls the advised sink's OnUpdate(flags), if any (e.g.
  // TF_LBI_ICON | TF_LBI_STATUS after a mode change). Safe to call
  // whether or not a sink is currently advised.
  void NotifyUpdate(DWORD flags);

 private:
  ~LangBarButton();
  LONG ref_count_ = 1;
  bool shown_ = true;
  LangBarButtonHandler* handler_;
  GUID item_guid_;
  DWORD style_;
  std::wstring display_name_;
  Kind kind_;
  ITfLangBarItemSink* sink_ = nullptr;
};
