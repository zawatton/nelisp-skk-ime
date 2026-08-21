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
#include "realtime_frontend.h"
#include "candidate_ui.h"
#include "display_attribute.h"
#include "guids.h"
#include "langbar_button.h"
#include "mode_indicator.h"

#include <atomic>
#include <deque>
#include <mutex>
#include <string>
#include <vector>

#include <msctf.h>
#include <ctffunc.h>
#include <windows.h>

class TextService final : public ITfTextInputProcessor, public ITfKeyEventSink,
                          public ITfDisplayAttributeProvider,
                          public ITfFunctionProvider,
                          public ITfFnConfigure,
                          public ITfCompositionSink,
                          public ITfCompartmentEventSink,
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
  HRESULT STDMETHODCALLTYPE OnCompositionTerminated(
      TfEditCookie ecWrite, ITfComposition* composition) override;
  HRESULT STDMETHODCALLTYPE OnChange(REFGUID guid) override;

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
  void SelectInputMode(const std::wstring& label) override;
  std::wstring CurrentModeLabel() const override;
  ModeIndicatorPalette CurrentModePalette() const override;

 private:
  ~TextService();
  void UnadviseKeySink();
  HRESULT AdviseOpenCloseCompartment();
  void UnadviseOpenCloseCompartment();
  bool ReadKeyboardOpen(bool fallback) const;
  void ApplyKeyboardOpenChange();
  static std::optional<char32_t> TranslateKey(WPARAM wparam, LPARAM lparam);
  // Whether this VK would be part of OnTestKeyDown's claimed set, given
  // `composing' (= composition_ != nullptr || engine_pending_, computed
  // identically at every call site). Assumes ddskk_engine_ && kana_mode_
  // are already established by the caller (matches where OnTestKeyDown's
  // own claim logic runs); does not re-check either. Shared by
  // OnTestKeyDown and OnKeyDown's direct-call fallback -- see both for
  // why the two must ask the identical question.
  bool WouldClaimKey(WPARAM wparam, bool composing) const;
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
  // Closes the candidate-selection UI element (if open) and clears the
  // per-candidate state tracked alongside it (candidate_context_/
  // candidate_count_/candidate_index_). Safe to call whether or not a
  // candidate UI is currently open. See its definition for the harness
  // evidence behind why every path that can abandon a composition must
  // call this, not just UpdateCandidateUI()'s normal empty-candidates case.
  void CloseCandidateUi();
  // Emergency fallback used only after the engine stopped answering
  // Ctrl+G.  Removes the document composition locally and makes the next
  // engine transaction start with RESET, so a wedged conversion cannot
  // leave the application trapped in IME-owned input.
  void ForceCancelComposition(ITfContext* context);
  // Finalize the old document's visible preedit as plain text (stripping
  // the ▽/▼ UI marker) before accepting input in a newly focused context.
  void SettleContextComposition(ITfContext* context);
  void TrackEndingComposition(ITfComposition* composition);
  void UntrackEndingComposition(ITfComposition* composition);
  bool AcknowledgeEndingComposition(ITfComposition* composition);
  // Drop local TSF composition state and mark this client's engine checkpoint
  // for reset when focus/context loss abandons unconfirmed input.
  void ResetAbandonedComposition();
  // Appends one line to %LOCALAPPDATA%\DDSKK\dll-debug.log when
  // debug_log_ is set (HKCU\Software\NativeIME\DllDebug == 1). No-op
  // otherwise, so this is safe to call unconditionally from hot paths.
  void DebugLog(const wchar_t* format, ...);
  struct ProviderResult;
  static LRESULT CALLBACK ProviderWindowProc(HWND window, UINT message,
                                              WPARAM wparam, LPARAM lparam);
  bool CreateProviderWindow();
  bool BeginProviderConversion(const std::u32string& keys);
  bool BeginProviderControl(ddskk::EngineControl control);
  bool BeginProviderKey(char32_t key);
  bool BeginProviderKeys(const std::u32string& keys);
  void CancelPendingProvider();
  void ApplyProviderResult(ProviderResult* result);
  void ReplayDeferredProviderKeys();
  void ShowProviderBusy(ITfContext* context);

  struct DeferredProviderKey {
    WPARAM virtual_key = 0;
    char32_t codepoint = 0;
    bool has_codepoint = false;
    bool shift = false;
    bool ctrl_j = false;
  };

  LONG ref_count_ = 1;
  ITfThreadMgr* thread_manager_ = nullptr;
  TfClientId client_id_ = TF_CLIENTID_NULL;
  ddskk::EngineClient engine_;
  ddskk::RealtimeFrontend realtime_frontend_;
  HWND provider_window_ = nullptr;
  std::mutex provider_engine_mutex_;
  std::atomic<uint64_t> provider_sequence_{0};
  std::atomic<bool> provider_pending_{false};
  std::deque<DeferredProviderKey> deferred_provider_keys_;
  ITfComposition* composition_ = nullptr;
  // AddRef'd identities of compositions ended by this TIP. Some hosts delay
  // OnCompositionTerminated; a vector preserves every outstanding identity
  // when a fast typist completes another episode before the earlier callback.
  std::vector<ITfComposition*> ending_compositions_;
  // Stable document range parked when Corvus-style registration begins.
  // Some real TSF hosts terminate composition_ before the registration
  // result arrives; this range still lets the result replace the original
  // reading instead of inserting again at the caret.
  ITfRange* registration_range_ = nullptr;
  bool registration_commit_pending_ = false;
  // Set when a claimed key could not obtain an engine STATE.  The next
  // Ctrl+G must not wait on the same unresponsive pipe again; it takes the
  // local emergency-cancel path instead.
  bool engine_roundtrip_failed_ = false;
  ITfContext* active_context_ = nullptr;
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
  // True when a provider owns the converted composition. Lattice can have
  // one candidate and still report "preedit", so mode alone is insufficient.
  bool provider_composition_active_ = false;
  // True while the engine's modal CorvusSKK-style dictionary registration
  // editor owns input. The document composition remains parked on the
  // reading while its checkpointed engine session edits registration text.
  bool registration_mode_ = false;
  // TSF may release/update Ctrl between OnTestKeyDown and OnKeyDown.
  // Remember the modifier decision made for G so a claimed Ctrl+G cannot
  // turn into an ordinary "g" by the time the real key callback arrives.
  // Modifier snapshot captured in OnTestKeyDown.  Edge/Terminal can update
  // the thread keyboard state before the paired OnKeyDown arrives; keeping
  // it makes every Ctrl chord (not only Ctrl+G) reliably pass through.
  bool tested_control_down_ = false;
  // Mirrors TSF's standard keyboard-open compartment.  External clients
  // such as Emacs' `w32-set-ime-open-status' change this value; false is
  // CorvusSKK's direct/"--" state and must claim no keys.
  bool keyboard_open_ = true;
  bool mode_before_close_kana_ = true;
  std::wstring engine_mode_before_close_ = L"hiragana";
  DWORD open_close_cookie_ = TF_INVALID_COOKIE;
  // True while an engine that composes owns the keyboard; false under
  // passthrough, where OnTestKeyDown/OnKeyDown bail out immediately.
  bool ddskk_engine_ = true;
  // The engine the settings chose.  Kept as its wire id rather than a
  // boolean because the engine process hosts more than DDSKK, and because
  // toggling the language bar off and back on must return to the engine the
  // user configured rather than to DDSKK.
  std::string engine_id_ = "ddskk";
  LangBarButton* settings_button_ = nullptr;
  // GUID_LBI_INPUTMODE: the item Windows 10/11's taskbar "A/あ" input
  // indicator renders. See AddLangBarButton()/RemoveLangBarButton().
  LangBarButton* input_mode_button_ = nullptr;
  ModeIndicator mode_indicator_;
  std::wstring last_mode_label_;
  // The most recent ddskk::EngineState::mode string MaybeShowModeIndicator
  // observed (or empty if none yet). Paired with kana_mode_ everywhere the
  // latter is written from a fresh state, so CurrentModeLabel() can derive
  // the same label MaybeShowModeIndicator would without needing its own
  // ITfContext/EngineState -- used by the input-mode langbar item's
  // GetIcon()/OnClick().
  std::wstring last_engine_mode_;
  RECT last_caret_rect_{};
  bool last_caret_valid_ = false;
  bool mode_indicator_enabled_ = true;
  // HKCU\Software\NativeIME\DllDebug == 1; gates DebugLog().
  bool debug_log_ = false;
};

extern HMODULE g_module;
extern LONG g_object_count;
extern LONG g_lock_count;
