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

#include "engine_client.h"
#include "candidate_ui.h"
#include "display_attribute.h"
#include "guids.h"
#include "langbar_button.h"
#include "mode_indicator.h"

#include <msctf.h>
#include <ctffunc.h>
#include <windows.h>

class TextService final : public ITfTextInputProcessor, public ITfKeyEventSink,
                          public ITfDisplayAttributeProvider,
                          public ITfFunctionProvider,
                          public ITfFnConfigure,
                          public CandidateUIHandler,
                          public LangBarButtonHandler {
 public:
  TextService();

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** object) override;
  ULONG STDMETHODCALLTYPE AddRef() override;
  ULONG STDMETHODCALLTYPE Release() override;

  HRESULT STDMETHODCALLTYPE Activate(ITfThreadMgr* thread_manager,
                                     TfClientId client_id) override;
  HRESULT STDMETHODCALLTYPE Deactivate() override;

  HRESULT STDMETHODCALLTYPE OnSetFocus(BOOL foreground) override;
  HRESULT STDMETHODCALLTYPE OnTestKeyDown(ITfContext* context, WPARAM wparam,
                                          LPARAM lparam, BOOL* eaten) override;
  HRESULT STDMETHODCALLTYPE OnKeyDown(ITfContext* context, WPARAM wparam,
                                      LPARAM lparam, BOOL* eaten) override;
  HRESULT STDMETHODCALLTYPE OnTestKeyUp(ITfContext* context, WPARAM wparam,
                                        LPARAM lparam, BOOL* eaten) override;
  HRESULT STDMETHODCALLTYPE OnKeyUp(ITfContext* context, WPARAM wparam,
                                    LPARAM lparam, BOOL* eaten) override;
  HRESULT STDMETHODCALLTYPE OnPreservedKey(ITfContext* context, REFGUID guid,
                                           BOOL* eaten) override;
  HRESULT STDMETHODCALLTYPE EnumDisplayAttributeInfo(
      IEnumTfDisplayAttributeInfo** enumerator) override;
  HRESULT STDMETHODCALLTYPE GetDisplayAttributeInfo(
      REFGUID guid, ITfDisplayAttributeInfo** info) override;
  HRESULT STDMETHODCALLTYPE GetType(GUID* guid) override;
  HRESULT STDMETHODCALLTYPE GetDescription(BSTR* description) override;
  HRESULT STDMETHODCALLTYPE GetFunction(REFGUID guid, REFIID iid,
                                         IUnknown** function) override;
  HRESULT STDMETHODCALLTYPE GetDisplayName(BSTR* name) override;
  HRESULT STDMETHODCALLTYPE Show(HWND parent, LANGID language,
                                 REFGUID profile) override;

  HRESULT ApplyEngineState(TfEditCookie edit_cookie, ITfContext* context,
                           const ddskk::EngineState& state);
  void UpdateCandidateUI(ITfContext* context,
                         const ddskk::EngineState& state);
  HRESULT SelectCandidate(UINT index) override;
  HRESULT FinalizeCandidate() override;
  HRESULT AbortCandidate() override;
  void SelectInputEngine(bool ddskk) override;
  void ToggleInputMode() override;
  void ShowSettings() override;

 private:
  ~TextService();
  void UnadviseKeySink();
  static std::optional<char32_t> TranslateKey(WPARAM wparam, LPARAM lparam);
  HRESULT RequestStateEdit(const ddskk::EngineState& state);
  HRESULT ApplyDisplayAttribute(TfEditCookie edit_cookie, ITfContext* context,
                                ITfRange* range, REFGUID guid);
  HRESULT AddLangBarButton();
  void RemoveLangBarButton();
  void LoadSettings();
  void EnsureEngineHost();
  void CaptureCaretRect(TfEditCookie edit_cookie, ITfContext* context,
                        ITfRange* range);
  void MaybeShowModeIndicator(ITfContext* context,
                              const ddskk::EngineState* state);

  LONG ref_count_ = 1;
  ITfThreadMgr* thread_manager_ = nullptr;
  TfClientId client_id_ = TF_CLIENTID_NULL;
  ddskk::EngineClient engine_;
  ITfComposition* composition_ = nullptr;
  size_t committed_length_ = 0;
  CandidateUI* candidate_ui_ = nullptr;
  DWORD candidate_ui_id_ = TF_INVALID_UIELEMENTID;
  ITfContext* candidate_context_ = nullptr;
  int candidate_index_ = -1;
  size_t candidate_count_ = 0;
  bool kana_mode_ = false;
  // True while DDSKK holds an active conversion (▽/▼) or an unfinished
  // romaji prefix.  Backspace / Enter / Escape belong to the IME only in
  // that state; otherwise they must reach the application.
  bool engine_pending_ = false;
  bool ddskk_engine_ = true;
  LangBarSettingsButton* settings_button_ = nullptr;
  ModeIndicator mode_indicator_;
  std::wstring last_mode_label_;
  RECT last_caret_rect_{};
  bool last_caret_valid_ = false;
  bool mode_indicator_enabled_ = true;
};

extern HMODULE g_module;
extern LONG g_object_count;
extern LONG g_lock_count;
