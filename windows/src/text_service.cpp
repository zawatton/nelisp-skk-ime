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

#include "text_service.h"

#include <cstdarg>
#include <cstdio>
#include <new>
#include <shellapi.h>
#include <thread>
#include <utility>

namespace {
class StateEditSession final : public ITfEditSession {
 public:
  StateEditSession(TextService* service, ITfContext* context,
                   ddskk::EngineState state)
      : service_(service), context_(context), state_(std::move(state)) {
    service_->AddRef();
    context_->AddRef();
  }
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** object) override {
    if (object == nullptr) return E_POINTER;
    *object = nullptr;
    if (iid != IID_IUnknown && iid != IID_ITfEditSession) return E_NOINTERFACE;
    *object = static_cast<ITfEditSession*>(this);
    AddRef();
    return S_OK;
  }
  ULONG STDMETHODCALLTYPE AddRef() override {
    return InterlockedIncrement(&ref_count_);
  }
  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG count = InterlockedDecrement(&ref_count_);
    if (count == 0) delete this;
    return count;
  }
  HRESULT STDMETHODCALLTYPE DoEditSession(TfEditCookie edit_cookie) override {
    return service_->ApplyEngineState(edit_cookie, context_, state_);
  }

 private:
  ~StateEditSession() {
    context_->Release();
    service_->Release();
  }
  LONG ref_count_ = 1;
  TextService* service_;
  ITfContext* context_;
  ddskk::EngineState state_;
};
}  // namespace

LONG g_object_count = 0;
LONG g_lock_count = 0;

TextService::TextService() { InterlockedIncrement(&g_object_count); }

TextService::~TextService() {
  if (candidate_context_ != nullptr) candidate_context_->Release();
  if (candidate_ui_ != nullptr) candidate_ui_->Release();
  if (composition_ != nullptr) composition_->Release();
  UnadviseKeySink();
  InterlockedDecrement(&g_object_count);
}

HRESULT TextService::QueryInterface(REFIID iid, void** object) {
  if (object == nullptr) return E_POINTER;
  *object = nullptr;
  if (iid == IID_IUnknown || iid == IID_ITfTextInputProcessor) {
    *object = static_cast<ITfTextInputProcessor*>(this);
  } else if (iid == IID_ITfKeyEventSink) {
    *object = static_cast<ITfKeyEventSink*>(this);
  } else if (iid == IID_ITfDisplayAttributeProvider) {
    *object = static_cast<ITfDisplayAttributeProvider*>(this);
  } else if (iid == IID_ITfFunctionProvider) {
    *object = static_cast<ITfFunctionProvider*>(this);
  } else if (iid == IID_ITfFunction || iid == IID_ITfFnConfigure) {
    *object = static_cast<ITfFnConfigure*>(this);
  } else if (iid == IID_ITfCompositionSink) {
    *object = static_cast<ITfCompositionSink*>(this);
  } else {
    return E_NOINTERFACE;
  }
  AddRef();
  return S_OK;
}

ULONG TextService::AddRef() { return InterlockedIncrement(&ref_count_); }

ULONG TextService::Release() {
  const ULONG count = InterlockedDecrement(&ref_count_);
  if (count == 0) delete this;
  return count;
}

HRESULT TextService::Activate(ITfThreadMgr* thread_manager,
                              TfClientId client_id) {
  if (thread_manager == nullptr) return E_INVALIDARG;
  thread_manager_ = thread_manager;
  thread_manager_->AddRef();
  client_id_ = client_id;
  EnsureEngineHost();
  // The engine's cold load was measured at 3.4 s. Pay that cost here, on a
  // detached background thread at activation, instead of on the user's
  // first keystroke -- that removes the first-key freeze. This thread
  // constructs its own EngineClient and never touches engine_, which is
  // UI-thread-only.
  std::thread([] {
    ddskk::EngineClient warm_up_client;
    const ULONGLONG deadline = GetTickCount64() + 20000;
    while (GetTickCount64() < deadline) {
      if (warm_up_client.Connect(2000)) {
        warm_up_client.Ping(15000);
        return;
      }
      Sleep(250);
    }
  }).detach();
  LoadSettings();

  ITfKeystrokeMgr* keystroke_manager = nullptr;
  const HRESULT query = thread_manager_->QueryInterface(
      IID_ITfKeystrokeMgr, reinterpret_cast<void**>(&keystroke_manager));
  if (FAILED(query)) {
    UnadviseKeySink();
    return query;
  }
  const HRESULT advise = keystroke_manager->AdviseKeyEventSink(client_id_, this, TRUE);
  keystroke_manager->Release();
  DebugLog(L"Activate advise=%X", static_cast<unsigned>(advise));
  if (FAILED(advise)) {
    UnadviseKeySink();
    return advise;
  }
  // The langbar settings button is cosmetic. Hosts without a language bar
  // (console TSF hosts, some sandboxed apps) fail AddItem, and returning
  // that failure here made TSF deactivate the whole text service -- no key
  // sink, IME silently dead. Log and carry on instead.
  const HRESULT langbar = AddLangBarButton();
  DebugLog(L"Activate langbar=%X", static_cast<unsigned>(langbar));
  return S_OK;
}

HRESULT TextService::Deactivate() {
  RemoveLangBarButton();
  engine_.Disconnect();
  if (composition_ != nullptr) {
    composition_->Release();
    composition_ = nullptr;
  }
  if (candidate_ui_id_ != TF_INVALID_UIELEMENTID && thread_manager_ != nullptr) {
    ITfUIElementMgr* manager = nullptr;
    if (SUCCEEDED(thread_manager_->QueryInterface(
            IID_ITfUIElementMgr, reinterpret_cast<void**>(&manager)))) {
      manager->EndUIElement(candidate_ui_id_);
      manager->Release();
    }
    candidate_ui_id_ = TF_INVALID_UIELEMENTID;
  }
  if (candidate_context_ != nullptr) {
    candidate_context_->Release();
    candidate_context_ = nullptr;
  }
  UnadviseKeySink();
  return S_OK;
}

// The langbar button had never actually registered anywhere in any
// process: AddItem returned E_FAIL every time, because both this function
// and RemoveLangBarButton() acquired their ITfLangBarItemMgr via
// CoCreateInstance(CLSID_TF_LangBarItemMgr, ...) -- a freestanding manager
// instance with no linkage to the live taskbar/langbar session, so AddItem
// had nothing to attach to. The correct pattern (CorvusSKK
// LanguageBar.cpp:606) is QueryInterface on the ITfThreadMgr TSF itself
// handed to Activate(): that manager instance IS the one wired to this
// session's langbar.
HRESULT TextService::AddLangBarButton() {
  if (thread_manager_ == nullptr) return E_UNEXPECTED;
  ITfLangBarItemMgr* manager = nullptr;
  HRESULT result = thread_manager_->QueryInterface(
      IID_ITfLangBarItemMgr, reinterpret_cast<void**>(&manager));
  if (FAILED(result)) return result;

  HRESULT settings_result = S_OK;
  if (settings_button_ == nullptr) {
    settings_button_ = new (std::nothrow) LangBarButton(
        this, GUID_DdskkSettingsButton,
        TF_LBI_STYLE_BTN_BUTTON | TF_LBI_STYLE_SHOWNINTRAYONLY,
        L"DDSKK settings", LangBarButton::Kind::kSettings);
    settings_result = settings_button_ == nullptr
        ? E_OUTOFMEMORY : manager->AddItem(settings_button_);
    if (FAILED(settings_result) && settings_button_ != nullptr) {
      settings_button_->Release();
      settings_button_ = nullptr;
    }
  }

  HRESULT input_mode_result = S_OK;
  if (input_mode_button_ == nullptr) {
    // GUID_LBI_INPUTMODE is the well-known item Windows 10/11's taskbar
    // "A/あ" indicator renders; TF_LBI_STYLE_SHOWNINTRAY (not the
    // ...ONLY variant the settings item uses) is what makes it eligible
    // for the taskbar itself rather than only the floating language bar
    // (also needs the two GUID_TFCAT_TIPCAP_* categories -- see
    // dllmain.cpp's RegisterCategories() and
    // windows/tools/register-categories.cpp).
    input_mode_button_ = new (std::nothrow) LangBarButton(
        this, GUID_LBI_INPUTMODE,
        TF_LBI_STYLE_BTN_BUTTON | TF_LBI_STYLE_SHOWNINTRAY,
        L"DDSKK input mode", LangBarButton::Kind::kInputMode);
    input_mode_result = input_mode_button_ == nullptr
        ? E_OUTOFMEMORY : manager->AddItem(input_mode_button_);
    if (FAILED(input_mode_result) && input_mode_button_ != nullptr) {
      input_mode_button_->Release();
      input_mode_button_ = nullptr;
    }
  }
  manager->Release();
  return FAILED(settings_result) ? settings_result : input_mode_result;
}

void TextService::RemoveLangBarButton() {
  if (settings_button_ == nullptr && input_mode_button_ == nullptr) return;
  // See AddLangBarButton(): the manager must be the one TSF handed us via
  // thread_manager_, not a freestanding CoCreateInstance() instance.
  ITfLangBarItemMgr* manager = nullptr;
  if (thread_manager_ != nullptr &&
      SUCCEEDED(thread_manager_->QueryInterface(
          IID_ITfLangBarItemMgr, reinterpret_cast<void**>(&manager)))) {
    if (settings_button_ != nullptr) manager->RemoveItem(settings_button_);
    if (input_mode_button_ != nullptr) manager->RemoveItem(input_mode_button_);
    manager->Release();
  }
  if (settings_button_ != nullptr) {
    settings_button_->Release();
    settings_button_ = nullptr;
  }
  if (input_mode_button_ != nullptr) {
    input_mode_button_->Release();
    input_mode_button_ = nullptr;
  }
}

void TextService::UnadviseKeySink() {
  if (thread_manager_ != nullptr) {
    ITfKeystrokeMgr* keystroke_manager = nullptr;
    if (SUCCEEDED(thread_manager_->QueryInterface(
            IID_ITfKeystrokeMgr,
            reinterpret_cast<void**>(&keystroke_manager)))) {
      keystroke_manager->UnadviseKeyEventSink(client_id_);
      keystroke_manager->Release();
    }
    thread_manager_->Release();
    thread_manager_ = nullptr;
  }
  client_id_ = TF_CLIENTID_NULL;
}

HRESULT TextService::OnSetFocus(BOOL) { return S_OK; }

// Only claim printable keys while the out-of-process engine is reachable.
HRESULT TextService::OnTestKeyDown(ITfContext*, WPARAM wparam, LPARAM,
                                   BOOL* eaten) {
  if (eaten == nullptr) return E_POINTER;
  // Logs (wparam, handled, connect result, final eaten) with -1 for
  // whichever of handled/connect was never evaluated on this exit path.
  const auto debug_exit = [&](int handled, int connect) {
    DebugLog(L"OnTestKeyDown vk=%02X handled=%d connect=%d eaten=%d",
             static_cast<unsigned>(wparam), handled, connect, *eaten);
  };
  const bool ctrl_j = wparam == 'J' && (GetKeyState(VK_CONTROL) & 0x8000);
  if (!ddskk_engine_) {
    *eaten = FALSE;
    debug_exit(-1, -1);
    return S_OK;
  }
  if (ctrl_j) {
    *eaten = engine_.Connect(1500);
    debug_exit(-1, *eaten);
    return S_OK;
  }
  if (!kana_mode_) {
    *eaten = FALSE;
    debug_exit(-1, -1);
    return S_OK;
  }
  // Backspace / Enter / Escape belong to the IME only while a composition
  // or a pending romaji prefix is actually in flight; otherwise they must
  // fall through to the application (matches CorvusSKK's key ownership).
  const bool composing = composition_ != nullptr || engine_pending_;
  // wparam here is a VK code, not an ASCII/character code: the old
  // `wparam >= 0x20 && wparam <= 0x7e' range claimed far more than
  // printable keys -- VK_PRIOR/VK_NEXT/VK_END/VK_HOME/arrows/VK_INSERT/
  // VK_DELETE (0x21-0x2E), VK_LWIN/VK_RWIN/VK_APPS (0x5B-0x5D), the
  // numpad (0x60-0x6F) and F1..F15 (0x70-0x7E) all fall inside it.
  // Navigation keys, F-keys, numpad and Win keys must fall through to the
  // application; an idle space must insert a plain space (the engine's
  // KEY 32 path errors and CorvusSKK passes it through too).
  const bool handled =
      (wparam >= 'A' && wparam <= 'Z') ||             // letters
      (wparam >= '0' && wparam <= '9') ||              // top-row digits
      (wparam >= VK_OEM_1 && wparam <= VK_OEM_3) ||    // 0xBA-0xC0 punctuation
      (wparam >= VK_OEM_4 && wparam <= VK_OEM_8) ||    // 0xDB-0xDF punctuation
      wparam == VK_OEM_102 ||                          // 0xE2 JIS backslash
      (wparam == VK_SPACE && composing) ||             // space converts only mid-composition
      ((wparam == VK_BACK || wparam == VK_RETURN ||
        wparam == VK_ESCAPE) && composing);
  if (!handled) {
    *eaten = FALSE;
    debug_exit(0, -1);
    return S_OK;
  }
  const bool connected = engine_.Connect(1500);
  if (!connected) {
    // Leaking romaji into the document is strictly worse than swallowing a
    // key for one round-trip while the host respawns: OnKeyDown swallows
    // any key this function claimed but can't complete (see its "never
    // leak a claimed key" failure paths), and the respawned host is
    // reachable by the next keystroke.
    EnsureEngineHost();
  }
  *eaten = TRUE;
  debug_exit(1, connected ? 1 : 0);
  return S_OK;
}

void TextService::SelectInputEngine(bool ddskk) {
  if (!engine_.SelectEngine(ddskk ? "ddskk" : "passthrough", 1000)) return;
  const bool was_ddskk = ddskk_engine_;
  ddskk_engine_ = ddskk;
  if (!ddskk) {
    // Passthrough makes OnTestKeyDown/OnKeyDown bail out unconditionally
    // (their `!ddskk_engine_' early-outs), so kana_mode_ no longer
    // affects key-claiming at all once this branch runs; it only feeds
    // MaybeShowModeIndicator's label, which should read as
    // latin/direct-input while the IME is disengaged. Forcing it false
    // here is therefore setting a known-correct value, not a stale guess.
    kana_mode_ = false;
    last_engine_mode_ = L"latin";
    engine_pending_ = false;
  } else if (!was_ddskk) {
    // Resuming DDSKK from passthrough. Passthrough never sends the engine
    // anything (see above), so the out-of-process session's own mode is
    // exactly what it was when we left -- but the wire protocol has no
    // passive "what's your current mode" query, only mutating verbs, so
    // trusting whatever stale value kana_mode_ was left at (forced false
    // above, the last time we switched away) would just reintroduce the
    // same kind of guess this whole fix removes. Force a known state
    // instead: the same unconditional-kana CONTROL CANCEL Ctrl+J uses
    // above. It is a safe no-op on the document here, because passthrough
    // guarantees no composition was ever started while it was active.
    const auto state = engine_.SendControl(ddskk::EngineControl::kCancel, 1000);
    if (state) {
      kana_mode_ = ddskk::DeriveKanaMode(*state);
      last_engine_mode_ = state->mode;
    }
  }
  // No ITfContext is available from this langbar-triggered path; the
  // indicator falls back to the mouse cursor position.
  MaybeShowModeIndicator(nullptr, nullptr);
}

void TextService::ToggleInputMode() {
  // A langbar click has no ITfContext to flush a document edit through,
  // unlike OnKeyDown/SelectCandidate/FinalizeCandidate/AbortCandidate.
  // Refuse to touch the engine while a composition (or a pending romaji
  // prefix) is in flight: doing so could change what the engine thinks
  // the document holds with no way to reconcile that here.
  if (!ddskk_engine_ || engine_pending_) return;
  // kana_mode_ is kept in sync with the engine's own mode on every other
  // path now (see OnKeyDown), so it is trustworthy here as "what the
  // engine is currently doing." Drive the actual transition through the
  // engine instead of just flipping a local flag the way this used to:
  // `l' is the real DDSKK key for leaving kana (matches the ordinary
  // OnKeyDown SendKey path for a typed `l'), and CONTROL CANCEL is the
  // same unconditional-kana command Ctrl+J uses above. Neither produces
  // visible text while nothing is composing (guaranteed by the
  // engine_pending_ check above), so no document edit is needed either.
  const auto state = kana_mode_
      ? engine_.SendKey(U'l', 1000)
      : engine_.SendControl(ddskk::EngineControl::kCancel, 1000);
  if (!state) return;
  kana_mode_ = ddskk::DeriveKanaMode(*state);
  last_engine_mode_ = state->mode;
  MaybeShowModeIndicator(nullptr, nullptr);
}

// Right-click mode selection on the input-mode langbar item's menu (see
// LangBarButton::OnClick()). Mirrors ToggleInputMode()'s guard exactly --
// a langbar click has no ITfContext to flush a document edit through
// either, so the engine must not be touched mid-composition -- and routes
// through the same primitives OnKeyDown/ToggleInputMode already use,
// never a new engine-driving path: CONTROL CANCEL is the Ctrl+J-
// equivalent that always lands in hiragana submode (see the long comment
// on OnKeyDown's Ctrl+J branch), so かな needs nothing further; カナ/全英/
// SKK each send the one additional DDSKK key that moves off that
// baseline -- `q' toggles hiragana<->katakana, `L' enters the wide-latin
// (全英) submode, and `l' is the same ascii/latin key ToggleInputMode
// itself sends.
void TextService::SelectInputMode(const std::wstring& label) {
  if (!ddskk_engine_ || engine_pending_) return;
  auto state = engine_.SendControl(ddskk::EngineControl::kCancel, 1000);
  if (!state) return;
  if (label == L"カナ") {
    state = engine_.SendKey(U'q', 1000);
  } else if (label == L"全英") {
    state = engine_.SendKey(U'L', 1000);
  } else if (label == L"SKK") {
    state = engine_.SendKey(U'l', 1000);
  }
  // かな (or anything unrecognized): CANCEL alone already reached it.
  if (!state) return;
  kana_mode_ = ddskk::DeriveKanaMode(*state);
  last_engine_mode_ = state->mode;
  MaybeShowModeIndicator(nullptr, &*state);
}

std::wstring TextService::CurrentModeLabel() const {
  return ModeIndicatorLabel(kana_mode_, last_engine_mode_);
}

ModeIndicatorPalette TextService::CurrentModePalette() const {
  // Reuses ModeIndicator's already-loaded registry overrides (see
  // LoadSettings()) rather than re-reading the registry here.
  return mode_indicator_.PaletteForLabel(CurrentModeLabel());
}

void TextService::ShowSettings() {
  // The settings UI stores its own executable path once installed; if
  // present, launch it (with --settings) in preference to the legacy
  // fallback below. Registry read only.
  wchar_t settings_exe[32768]{};
  DWORD settings_exe_bytes = sizeof(settings_exe);
  HKEY key = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\NativeIME", 0, KEY_READ,
                    &key) == ERROR_SUCCESS) {
    const LONG status = RegQueryValueExW(
        key, L"SettingsExe", nullptr, nullptr,
        reinterpret_cast<BYTE*>(settings_exe), &settings_exe_bytes);
    RegCloseKey(key);
    if (status == ERROR_SUCCESS && settings_exe[0] != L'\0') {
      ShellExecuteW(nullptr, L"open", settings_exe, L"--settings", nullptr,
                   SW_SHOWNORMAL);
      return;
    }
  }
  wchar_t module_path[MAX_PATH]{};
  GetModuleFileNameW(g_module, module_path, MAX_PATH);
  std::wstring path(module_path);
  path.replace(path.find_last_of(L"\\/") + 1, std::wstring::npos,
               L"ddskk-ime-config.exe");
  ShellExecuteW(nullptr, L"open", path.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
}

void TextService::LoadSettings() {
  HKEY key = nullptr;
  wchar_t engine[32] = L"ddskk";
  DWORD bytes = sizeof(engine), kana = 1, kana_bytes = sizeof(kana);
  DWORD indicator_ms = 3000, indicator_ms_bytes = sizeof(indicator_ms);
  DWORD indicator_enabled = 1, indicator_enabled_bytes = sizeof(indicator_enabled);
  DWORD indicator_scale = 100, indicator_scale_bytes = sizeof(indicator_scale);
  DWORD debug_log = 0, debug_log_bytes = sizeof(debug_log);
  if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\NativeIME", 0,
                    KEY_READ, &key) == ERROR_SUCCESS) {
    RegQueryValueExW(key, L"Engine", nullptr, nullptr,
                     reinterpret_cast<BYTE*>(engine), &bytes);
    RegQueryValueExW(key, L"DllDebug", nullptr, nullptr,
                     reinterpret_cast<BYTE*>(&debug_log), &debug_log_bytes);
    RegQueryValueExW(key, L"InitialKanaMode", nullptr, nullptr,
                     reinterpret_cast<BYTE*>(&kana), &kana_bytes);
    RegQueryValueExW(key, L"ModeIndicatorMs", nullptr, nullptr,
                     reinterpret_cast<BYTE*>(&indicator_ms), &indicator_ms_bytes);
    RegQueryValueExW(key, L"ModeIndicator", nullptr, nullptr,
                     reinterpret_cast<BYTE*>(&indicator_enabled),
                     &indicator_enabled_bytes);
    RegQueryValueExW(key, L"ModeIndicatorScale", nullptr, nullptr,
                     reinterpret_cast<BYTE*>(&indicator_scale),
                     &indicator_scale_bytes);

    // Per-mode indicator colors, CorvusSKK's "入力モードの色" equivalent.
    // Each is an optional 0x00BBGGRR COLORREF; a value that is absent
    // leaves ModeIndicatorColors()'s built-in default for that mode in
    // place (see ModeIndicator::SetPaletteOverride()).
    auto read_color_override = [key, this](const wchar_t* name, const wchar_t* label) {
      DWORD value = 0, value_bytes = sizeof(value);
      if (RegQueryValueExW(key, name, nullptr, nullptr,
                           reinterpret_cast<BYTE*>(&value), &value_bytes) ==
          ERROR_SUCCESS) {
        mode_indicator_.SetPaletteOverride(label, static_cast<COLORREF>(value));
      }
    };
    read_color_override(L"ModeColorKana", L"かな");
    read_color_override(L"ModeColorKatakana", L"カナ");
    read_color_override(L"ModeColorLatin", L"SKK");
    read_color_override(L"ModeColorWideLatin", L"全英");
    read_color_override(L"ModeColorAbbrev", L"Abbrev");

    RegCloseKey(key);
  }
  ddskk_engine_ = wcscmp(engine, L"passthrough") != 0;
  kana_mode_ = ddskk_engine_ && kana != 0;
  engine_pending_ = false;
  debug_log_ = debug_log == 1;
  engine_.SelectEngine(ddskk_engine_ ? "ddskk" : "passthrough", 1000);

  // CorvusSKK documents a [1, 60000] ms range for its equivalent setting.
  if (indicator_ms < 1) indicator_ms = 1;
  if (indicator_ms > 60000) indicator_ms = 60000;
  mode_indicator_.SetDurationMs(indicator_ms);
  mode_indicator_enabled_ = indicator_enabled != 0;

  // ModeIndicatorScale is a percentage of the built-in font/padding size.
  if (indicator_scale < 50) indicator_scale = 50;
  if (indicator_scale > 300) indicator_scale = 300;
  mode_indicator_.SetScalePercent(indicator_scale);

  // Seed the baseline label without popping the indicator, so only a
  // real subsequent transition (not this initial load) shows the popup.
  last_engine_mode_ = L"hiragana";
  last_mode_label_ = ModeIndicatorLabel(kana_mode_, last_engine_mode_);
}

void TextService::EnsureEngineHost() {
  if (engine_.Connect(1)) return;
  HKEY key = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\NativeIME", 0,
                    KEY_READ, &key) != ERROR_SUCCESS) return;
  auto read = [key](const wchar_t* name) {
    wchar_t value[32768]{}; DWORD bytes = sizeof(value);
    if (RegQueryValueExW(key, name, nullptr, nullptr,
        reinterpret_cast<BYTE*>(value), &bytes) != ERROR_SUCCESS) return std::wstring{};
    return std::wstring(value);
  };
  const std::wstring host = read(L"EngineHost");
  std::wstring executable = read(L"EngineExecutable");
  if (executable.empty()) executable = read(L"NeLisp");
  const std::wstring repository = read(L"Repository");
  RegCloseKey(key);
  if (host.empty() || executable.empty()) return;
  std::wstring command = L"\"" + host + L"\" \"" + executable + L"\"";
  if (!repository.empty()) command += L" \"" + repository + L"\"";
  STARTUPINFOW startup{}; startup.cb = sizeof(startup);
  startup.dwFlags = STARTF_USESHOWWINDOW; startup.wShowWindow = SW_HIDE;
  PROCESS_INFORMATION process{};
  if (CreateProcessW(nullptr, command.data(), nullptr, nullptr, FALSE,
      0, nullptr, repository.empty() ? nullptr : repository.c_str(),
      &startup, &process)) {
    CloseHandle(process.hThread); CloseHandle(process.hProcess);
  }
}

// Appends one line to %LOCALAPPDATA%\DDSKK\dll-debug.log: "<pid> <tick> "
// followed by the caller's formatted message. Uses the truncating _s CRT
// variants throughout so an over-long message or path never crashes the
// host application -- this is diagnostic-only and must never be able to
// bring down whatever process the DLL is loaded into. Opens, writes, and
// closes the file on every call rather than keeping a handle open, so a
// user can read/rotate/delete the log while the IME keeps running.
void TextService::DebugLog(const wchar_t* format, ...) {
  if (!debug_log_) return;

  wchar_t message[512]{};
  va_list args;
  va_start(args, format);
  _vsnwprintf_s(message, 512, _TRUNCATE, format, args);
  va_end(args);

  wchar_t line[640]{};
  _snwprintf_s(line, 640, _TRUNCATE, L"%lu %llu %ls\r\n",
              static_cast<unsigned long>(GetCurrentProcessId()),
              static_cast<unsigned long long>(GetTickCount64()), message);

  wchar_t local_app_data[MAX_PATH]{};
  const DWORD local_app_data_len =
      GetEnvironmentVariableW(L"LOCALAPPDATA", local_app_data, MAX_PATH);
  if (local_app_data_len == 0 || local_app_data_len >= MAX_PATH) return;
  const std::wstring log_dir = std::wstring(local_app_data) + L"\\DDSKK";
  CreateDirectoryW(log_dir.c_str(), nullptr);
  const std::wstring log_path = log_dir + L"\\dll-debug.log";

  const int utf8_len = WideCharToMultiByte(CP_UTF8, 0, line, -1, nullptr, 0,
                                           nullptr, nullptr);
  if (utf8_len <= 0) return;
  std::string utf8(static_cast<size_t>(utf8_len) - 1, '\0');
  WideCharToMultiByte(CP_UTF8, 0, line, -1, utf8.data(), utf8_len, nullptr,
                      nullptr);

  const HANDLE file = CreateFileW(
      log_path.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
      nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  DWORD written = 0;
  WriteFile(file, utf8.data(), static_cast<DWORD>(utf8.size()), &written,
           nullptr);
  CloseHandle(file);
}

HRESULT TextService::OnKeyDown(ITfContext* context, WPARAM wparam, LPARAM lparam,
                               BOOL* eaten) {
  if (eaten == nullptr) return E_POINTER;
  *eaten = FALSE;
  if (context == nullptr) return E_INVALIDARG;
  if (engine_needs_cancel_) {
    // OnCompositionTerminated saw the application end the previous
    // composition on its own (focus change, app-driven edit, etc.); the
    // out-of-process engine still thinks it owns half of that state, so it
    // must be cancelled before this key is sent, or its stale text would
    // re-render into a brand-new composition. The result is ignored: a
    // failure here gets resynced by EngineClient's own needs_resync_
    // handling on the next transaction.
    engine_needs_cancel_ = false;
    engine_.SendControl(ddskk::EngineControl::kCancel, 1500);
  }
  std::optional<ddskk::EngineState> state;
  const wchar_t* branch = L"?";
  // Logs the outcome of this call using whatever `state'/`branch' hold at
  // the point it runs; every return path below calls this exactly once,
  // right before returning.
  const auto debug_exit = [&](BOOL final_eaten, HRESULT request_hr = S_OK,
                              HRESULT edit_hr = S_OK) {
    if (state) {
      DebugLog(L"OnKeyDown vk=%02X branch=%ls state=1 mode=%ls tlen=%zu "
               L"plen=%zu req=%X edit=%X eaten=%d",
               static_cast<unsigned>(wparam), branch, state->mode.c_str(),
               state->text.size(), state->pending_romaji.size(),
               static_cast<unsigned>(request_hr),
               static_cast<unsigned>(edit_hr), final_eaten);
    } else {
      DebugLog(L"OnKeyDown vk=%02X branch=%ls state=0 mode=- tlen=0 plen=0 "
               L"req=- edit=- eaten=%d",
               static_cast<unsigned>(wparam), branch, final_eaten);
    }
  };
  if (wparam == 'J' && (GetKeyState(VK_CONTROL) & 0x8000)) {
    branch = L"ctrlj";
    // C-j is not a toggle in DDSKK. `skk-kakutei' (bound to C-j via
    // `skk-kakutei-key' in every mode map -- skk.el:942-948, :456-457,
    // :508-509, :521-522) always ends up in kana submode: its docstring
    // says so directly ("`\C-j' returns to hiragana submode from either
    // ASCII submode", skk.el:120-123), and its own tail `cond'
    // (skk.el:2787-2806) ends with `((not (or skk-j-mode
    // skk-jisx0201-mode)) (skk-j-mode-on skk-katakana))', which fires
    // unconditionally whenever the current submode is not already kana
    // -- and is simply a no-op when it is. CONTROL CANCEL already
    // reproduces exactly this: its `cancel' branch in
    // engine/skk-ime-session.el ends with an unconditional
    // `(skk-j-mode-on (and skk-katakana))' regardless of what came
    // before, and that file even documents the intent: "The native host
    // sends `cancel' for Ctrl+J when returning to kana input." So there
    // is nothing to toggle here -- always send CANCEL, and let the
    // common tail below derive kana_mode_ from whatever the engine
    // actually reports afterward.
    state = engine_.SendControl(ddskk::EngineControl::kCancel, 1500);
    if (!state) {
      // OnTestKeyDown already claimed Ctrl+J; letting it fall through here
      // would leak the raw keystroke into the document instead of just
      // swallowing it for this one failed round-trip.
      *eaten = TRUE;
      debug_exit(*eaten);
      return S_OK;
    }
  } else if (!kana_mode_) {
    branch = L"nokana";
    debug_exit(*eaten);
    return S_OK;
  } else if (wparam == VK_BACK) {
    branch = L"back";
    // Backspace belongs to the IME only while something is actually being
    // composed; otherwise let the application handle it (e.g. delete the
    // previous character in the document).
    if (composition_ == nullptr && !engine_pending_) {
      debug_exit(*eaten);
      return S_OK;
    }
    state = engine_.SendControl(ddskk::EngineControl::kBackspace, 1500);
  } else if (wparam == VK_SPACE) {
    branch = L"space";
    // Space belongs to the IME only while something is actually being
    // composed; otherwise let the application insert a plain space
    // (OnTestKeyDown now only claims VK_SPACE mid-composition too).
    if (composition_ == nullptr && !engine_pending_) {
      debug_exit(*eaten);
      return S_OK;
    }
    state = engine_.SendControl(ddskk::EngineControl::kConvert, 1500);
  } else if (wparam == VK_RETURN) {
    branch = L"return";
    if (composition_ == nullptr && !engine_pending_) {
      debug_exit(*eaten);
      return S_OK;
    }
    state = engine_.SendControl(ddskk::EngineControl::kCommit, 1500);
  } else if (wparam == VK_ESCAPE) {
    branch = L"escape";
    if (composition_ == nullptr && !engine_pending_) {
      debug_exit(*eaten);
      return S_OK;
    }
    state = engine_.SendControl(ddskk::EngineControl::kCancel, 1500);
  } else {
    branch = L"key";
    const auto codepoint = TranslateKey(wparam, lparam);
    if (!codepoint) {
      // OnTestKeyDown's claim set only claims VK codes TranslateKey should
      // be able to resolve; if it still can't, swallow rather than leak a
      // key the application never got a chance to see coming.
      *eaten = TRUE;
      debug_exit(*eaten);
      return S_OK;
    }
    state = engine_.SendKey(*codepoint, 1500);
  }
  if (!state) {
    // OnTestKeyDown already claimed this key, so letting it fall through
    // here would leak the raw keystroke into the document instead of just
    // swallowing it for this one failed round-trip.
    *eaten = TRUE;
    debug_exit(*eaten);
    return S_OK;
  }
  // The key was claimed in OnTestKeyDown and the engine has already
  // consumed it; even if the edit session fails, letting the raw
  // keystroke through would insert ASCII the engine also processed --
  // this exact path produced the "▽Kana " leak.
  *eaten = TRUE;
  // Single point of truth for engine_pending_ and kana_mode_: every branch
  // above that reaches here (including the Ctrl+J case) has just obtained
  // a fresh state from the engine, so this always reflects the latest
  // reality instead of a locally-tracked guess. Deriving kana_mode_ here
  // is the actual fix for the mode-desync bug: previously it was only
  // ever written by LoadSettings/Ctrl+J/ToggleInputMode, so a plain key
  // like `l' that silently switched the engine's own mode left it stale,
  // and OnTestKeyDown kept claiming keys the engine no longer wanted.
  engine_pending_ = state->composition_start >= 0 || !state->pending_romaji.empty();
  kana_mode_ = ddskk::DeriveKanaMode(*state);
  last_engine_mode_ = state->mode;
  UpdateCandidateUI(context, *state);
  auto* edit_session = new (std::nothrow) StateEditSession(this, context, *state);
  if (edit_session == nullptr) return E_OUTOFMEMORY;
  HRESULT edit_result = E_FAIL;
  const HRESULT request = context->RequestEditSession(
      client_id_, edit_session, TF_ES_SYNC | TF_ES_READWRITE, &edit_result);
  edit_session->Release();
  debug_exit(*eaten, request, edit_result);
  // Covers both the Ctrl+J toggle above and every SendKey-driven mode
  // change (l / L / q / / etc.) below it: by this point `state` always
  // holds the latest engine state, regardless of which branch produced
  // it. This never influences *eaten, which was already decided above.
  MaybeShowModeIndicator(context, &*state);
  return S_OK;
}

void TextService::UpdateCandidateUI(ITfContext* context,
                                    const ddskk::EngineState& state) {
  if (thread_manager_ == nullptr) return;
  ITfUIElementMgr* manager = nullptr;
  if (FAILED(thread_manager_->QueryInterface(
          IID_ITfUIElementMgr, reinterpret_cast<void**>(&manager)))) return;
  if (state.candidates.empty()) {
    if (candidate_ui_id_ != TF_INVALID_UIELEMENTID) {
      manager->EndUIElement(candidate_ui_id_);
      candidate_ui_id_ = TF_INVALID_UIELEMENTID;
    }
  } else {
    if (candidate_ui_ == nullptr) candidate_ui_ = new (std::nothrow) CandidateUI(this);
    if (candidate_context_ != context) {
      if (candidate_context_ != nullptr) candidate_context_->Release();
      candidate_context_ = context;
      candidate_context_->AddRef();
    }
    candidate_index_ = state.candidate_index;
    candidate_count_ = state.candidates.size();
    ITfDocumentMgr* document = nullptr;
    context->GetDocumentMgr(&document);
    if (candidate_ui_ != nullptr) candidate_ui_->Update(state, document);
    if (document != nullptr) document->Release();
    if (candidate_ui_ != nullptr) {
      if (candidate_ui_id_ == TF_INVALID_UIELEMENTID) {
        BOOL show = TRUE;
        manager->BeginUIElement(candidate_ui_, &show, &candidate_ui_id_);
      } else {
        manager->UpdateUIElement(candidate_ui_id_);
      }
    }
  }
  manager->Release();
}

HRESULT TextService::SelectCandidate(UINT index) {
  if (candidate_context_ == nullptr || candidate_index_ < 0 ||
      index >= candidate_count_) return E_INVALIDARG;
  std::optional<ddskk::EngineState> state;
  size_t attempts = 0;
  while (candidate_index_ < static_cast<int>(index) && attempts++ < candidate_count_) {
    const int previous = candidate_index_;
    state = engine_.SendControl(ddskk::EngineControl::kConvert, 1000);
    if (!state || state->candidate_index == previous) return E_FAIL;
    candidate_index_ = state->candidate_index;
  }
  attempts = 0;
  while (candidate_index_ > static_cast<int>(index) && attempts++ < candidate_count_) {
    const int previous = candidate_index_;
    state = engine_.SendControl(ddskk::EngineControl::kPrevious, 1000);
    if (!state || state->candidate_index == previous) return E_FAIL;
    candidate_index_ = state->candidate_index;
  }
  if (candidate_index_ != static_cast<int>(index)) return E_FAIL;
  return state ? RequestStateEdit(*state) : S_OK;
}

HRESULT TextService::FinalizeCandidate() {
  if (candidate_context_ == nullptr) return E_UNEXPECTED;
  const auto state = engine_.SendControl(ddskk::EngineControl::kCommit, 1000);
  return state ? RequestStateEdit(*state) : E_FAIL;
}

HRESULT TextService::AbortCandidate() {
  if (candidate_context_ == nullptr) return E_UNEXPECTED;
  const auto state = engine_.SendControl(ddskk::EngineControl::kCancel, 1000);
  return state ? RequestStateEdit(*state) : E_FAIL;
}

HRESULT TextService::RequestStateEdit(const ddskk::EngineState& state) {
  if (candidate_context_ == nullptr) return E_UNEXPECTED;
  // Mirrors the OnKeyDown update: SelectCandidate / FinalizeCandidate /
  // AbortCandidate all apply engine states through this helper, so it must
  // keep engine_pending_ current too (e.g. FinalizeCandidate committing the
  // composition must clear it).
  engine_pending_ = state.composition_start >= 0 || !state.pending_romaji.empty();
  UpdateCandidateUI(candidate_context_, state);
  auto* edit_session =
      new (std::nothrow) StateEditSession(this, candidate_context_, state);
  if (edit_session == nullptr) return E_OUTOFMEMORY;
  HRESULT edit_result = E_FAIL;
  const HRESULT request = candidate_context_->RequestEditSession(
      client_id_, edit_session, TF_ES_ASYNC | TF_ES_READWRITE, &edit_result);
  edit_session->Release();
  return request;
}
HRESULT TextService::OnTestKeyUp(ITfContext*, WPARAM, LPARAM, BOOL* eaten) {
  if (eaten == nullptr) return E_POINTER;
  *eaten = FALSE;
  return S_OK;
}
HRESULT TextService::OnKeyUp(ITfContext*, WPARAM, LPARAM, BOOL* eaten) {
  if (eaten == nullptr) return E_POINTER;
  *eaten = FALSE;
  return S_OK;
}
HRESULT TextService::OnPreservedKey(ITfContext*, REFGUID, BOOL* eaten) {
  if (eaten == nullptr) return E_POINTER;
  *eaten = FALSE;
  return S_OK;
}

HRESULT TextService::EnumDisplayAttributeInfo(
    IEnumTfDisplayAttributeInfo** enumerator) {
  if (enumerator == nullptr) return E_POINTER;
  *enumerator = nullptr;
  return E_NOTIMPL;
}

HRESULT TextService::GetDisplayAttributeInfo(
    REFGUID guid, ITfDisplayAttributeInfo** info) {
  if (info == nullptr) return E_POINTER;
  *info = nullptr;
  if (guid != GUID_DdskkPreeditAttribute &&
      guid != GUID_DdskkCandidateAttribute) return E_INVALIDARG;
  *info = CreateDisplayAttributeInfo(guid);
  return *info ? S_OK : E_OUTOFMEMORY;
}

HRESULT TextService::GetType(GUID* guid) {
  if (guid == nullptr) return E_POINTER;
  *guid = CLSID_DdskkTextService;
  return S_OK;
}

HRESULT TextService::GetDescription(BSTR* description) {
  if (description == nullptr) return E_POINTER;
  *description = SysAllocString(L"DDSKK (NeLisp) settings");
  return *description ? S_OK : E_OUTOFMEMORY;
}

HRESULT TextService::GetFunction(REFGUID, REFIID iid, IUnknown** function) {
  if (function == nullptr) return E_POINTER;
  return QueryInterface(iid, reinterpret_cast<void**>(function));
}

HRESULT TextService::GetDisplayName(BSTR* name) {
  return GetDescription(name);
}

HRESULT TextService::Show(HWND, LANGID, REFGUID) {
  ShowSettings();
  return S_OK;
}

// TSF calls this when the application ends a composition on its own
// (focus change, an app-driven edit, etc.) rather than through
// FinalizeCandidate/AbortCandidate/OnKeyDown. Whatever was displayed is
// now committed document text this DLL no longer owns, but the
// out-of-process engine still thinks it owns its half of that state --
// see engine_needs_cancel_'s declaration for how the next key resyncs it.
HRESULT TextService::OnCompositionTerminated(TfEditCookie, ITfComposition*) {
  DebugLog(L"OnCompositionTerminated comp=%d", composition_ != nullptr ? 1 : 0);
  if (composition_ != nullptr) {
    composition_->Release();
    composition_ = nullptr;
  }
  engine_pending_ = false;
  engine_needs_cancel_ = true;
  return S_OK;
}

std::optional<char32_t> TextService::TranslateKey(WPARAM wparam,
                                                  LPARAM lparam) {
  BYTE keyboard_state[256]{};
  if (!GetKeyboardState(keyboard_state)) return std::nullopt;
  WCHAR text[4]{};
  const UINT scan_code = (static_cast<UINT>(lparam) >> 16) & 0xff;
  const int count = ToUnicodeEx(static_cast<UINT>(wparam), scan_code,
                                keyboard_state, text, 4, 0,
                                GetKeyboardLayout(0));
  if (count == 1) return static_cast<char32_t>(text[0]);
  if (count == 2 && IS_HIGH_SURROGATE(text[0]) && IS_LOW_SURROGATE(text[1]))
    return static_cast<char32_t>(0x10000 +
        ((text[0] - 0xd800) << 10) + (text[1] - 0xdc00));
  return std::nullopt;
}

// Episode model (confirmed against the engine): it truncates its session
// buffer at every commit boundary, so state.text always holds exactly the
// current episode -- either a leading marker (state.text[0,
// state.composition_start) is "▽"/"▼") plus the active segment, or, once
// state.composition_start is -1, the episode's final committed result.
// Nothing from an earlier episode ever carries over. So there is no
// running commit offset to track across calls: `committed' is only ever
// the whole state.text (direct_commit) or nothing, and `display' is the
// whole episode text -- marker included, the way CorvusSKK renders it too
// -- plus any still-unresolved romaji prefix. The composition itself only
// closes once an episode ends with no pending romaji left (see the tail
// below).
HRESULT TextService::ApplyEngineState(TfEditCookie edit_cookie,
                                      ITfContext* context,
                                      const ddskk::EngineState& state) {
  const bool direct_commit = state.composition_start < 0 &&
                             state.pending_romaji.empty() &&
                             composition_ == nullptr;
  const std::wstring committed = direct_commit ? state.text : std::wstring();
  // The wire protocol carries `text' and `pending_romaji' as separate
  // STATE fields; render both together so a pending-only romaji prefix
  // (e.g. text empty, pending_romaji "k" before it resolves to a kana)
  // is actually visible instead of silently dropped.
  const std::wstring display =
      direct_commit ? std::wstring() : state.text + state.pending_romaji;
  DebugLog(L"ApplyEngineState entry comp=%d dlen=%zu",
           composition_ != nullptr ? 1 : 0, display.size());
  ITfRange* range = nullptr;
  if (composition_ != nullptr) {
    const HRESULT get_range = composition_->GetRange(&range);
    DebugLog(L"ApplyEngineState get_range hr=%X",
             static_cast<unsigned>(get_range));
    if (FAILED(get_range)) return get_range;
  } else {
    TF_SELECTION selection{};
    ULONG fetched = 0;
    const HRESULT get_selection =
        context->GetSelection(edit_cookie, TF_DEFAULT_SELECTION, 1, &selection,
                              &fetched);
    if (FAILED(get_selection) || fetched != 1) return FAILED(get_selection)
                                                        ? get_selection
                                                        : E_FAIL;
    range = selection.range;
    if (!committed.empty()) {
      const HRESULT commit = range->SetText(
          edit_cookie, 0, committed.data(), static_cast<LONG>(committed.size()));
      if (FAILED(commit)) {
        range->Release();
        return commit;
      }
      range->Collapse(edit_cookie, TF_ANCHOR_END);
      TF_SELECTION caret{};
      caret.range = range;
      caret.style.ase = TF_AE_NONE;
      caret.style.fInterimChar = FALSE;
      const HRESULT select = context->SetSelection(edit_cookie, 1, &caret);
      if (FAILED(select)) {
        range->Release();
        return select;
      }
    }
    if (display.empty()) {
      CaptureCaretRect(edit_cookie, context, range);
      range->Release();
      return S_OK;
    }
    ITfContextComposition* composition_context = nullptr;
    HRESULT result = context->QueryInterface(
        IID_ITfContextComposition,
        reinterpret_cast<void**>(&composition_context));
    if (SUCCEEDED(result)) {
      // `this' as the sink (instead of the previous nullptr) is what lets
      // OnCompositionTerminated fire when the application ends this
      // composition on its own; without it composition_ silently went
      // stale and its rendered text stayed committed in the document,
      // consistent with the "kかnな" leak.
      result = composition_context->StartComposition(
          edit_cookie, range, static_cast<ITfCompositionSink*>(this),
          &composition_);
      composition_context->Release();
      DebugLog(L"ApplyEngineState start_composition hr=%X",
               static_cast<unsigned>(result));
    }
    if (FAILED(result)) {
      range->Release();
      return result;
    }
  }
  const HRESULT set_text = range->SetText(
      edit_cookie, 0, display.data(), static_cast<LONG>(display.size()));
  DebugLog(L"ApplyEngineState set_text hr=%X", static_cast<unsigned>(set_text));
  if (SUCCEEDED(set_text)) {
    ApplyDisplayAttribute(edit_cookie, context, range,
        state.mode == L"candidate" ? GUID_DdskkCandidateAttribute
                                    : GUID_DdskkPreeditAttribute);
    ITfRange* caret = nullptr;
    if (SUCCEEDED(range->Clone(&caret))) {
      // The caret always goes to the END of the display. This IME never
      // moves the caret inside a composition (arrow keys are deliberately
      // unclaimed and fall through to the application), and DDSKK's own
      // point is at the insertion end throughout ▽/▼/pending states and
      // after every kakutei. The engine's state.cursor field is NOT a
      // reliable display position across all flows: on the okuri-ari
      // commit ("KanaSimi" -> 悲し + み) it points inside the committed
      // text at the okurigana boundary, which parked the caret between
      // 悲 and し so the trailing み landed in the middle ("悲みし").
      // Deriving the caret from display.size() alone removes that whole
      // bug class.
      const LONG relative_cursor = static_cast<LONG>(display.size());
      LONG moved = 0;
      caret->Collapse(edit_cookie, TF_ANCHOR_START);
      caret->ShiftEnd(edit_cookie, relative_cursor, &moved, nullptr);
      caret->Collapse(edit_cookie, TF_ANCHOR_END);
      TF_SELECTION selection{};
      selection.range = caret;
      selection.style.ase = TF_AE_NONE;
      selection.style.fInterimChar = FALSE;
      context->SetSelection(edit_cookie, 1, &selection);
      CaptureCaretRect(edit_cookie, context, caret);
      caret->Release();
    }
  }
  range->Release();
  if (FAILED(set_text)) return set_text;
  // A pending-only state (composition_start < 0 but pending_romaji still
  // non-empty) must keep the composition alive: `display' above already
  // rendered the pending prefix inside it, so ending the composition here
  // too would commit that unresolved romaji straight into the document.
  // The composition only ends once a later state reports the pending
  // prefix has resolved (pending_romaji empty) with no new composition
  // start.
  if (state.composition_start < 0 && state.pending_romaji.empty() &&
      composition_ != nullptr) {
    const HRESULT end = composition_->EndComposition(edit_cookie);
    DebugLog(L"ApplyEngineState end_composition hr=%X",
             static_cast<unsigned>(end));
    composition_->Release();
    composition_ = nullptr;
    return end;
  }
  return S_OK;
}

// Reads the on-screen extent of `range` (typically the current caret
// position) while a document lock is already held, and caches it for
// MaybeShowModeIndicator to consume afterward. Never fails loudly: any
// failure just leaves last_caret_valid_ false so the caller falls back to
// the mouse cursor position.
void TextService::CaptureCaretRect(TfEditCookie edit_cookie, ITfContext* context,
                                   ITfRange* range) {
  last_caret_valid_ = false;
  if (context == nullptr || range == nullptr) return;
  ITfContextView* view = nullptr;
  if (FAILED(context->GetActiveView(&view)) || view == nullptr) return;
  RECT rect{};
  BOOL clipped = FALSE;
  const HRESULT result = view->GetTextExt(edit_cookie, range, &rect, &clipped);
  view->Release();
  if (FAILED(result)) return;
  last_caret_rect_ = rect;
  last_caret_valid_ = true;
}

// The single choke point after every mode change: pops the transient
// popup indicator and pushes an update to the input-mode langbar icon,
// whenever the computed label actually changes. `context` may be null
// (langbar-triggered calls have no associated context); `state` may be
// null when no fresh engine state is available (the label then falls
// back to kana_mode_ alone). This never touches *eaten, the composition,
// or any edit session result -- it is purely a side effect observed
// after the fact.
void TextService::MaybeShowModeIndicator(ITfContext* context,
                                         const ddskk::EngineState* state) {
  // Kept fresh regardless of mode_indicator_enabled_ below: CurrentModeLabel()
  // (used by the input-mode item's GetIcon()/OnClick()) must reflect the
  // engine's last-reported mode even when the transient popup is disabled.
  if (state != nullptr) last_engine_mode_ = state->mode;
  const std::wstring engine_mode = state != nullptr ? state->mode : std::wstring();
  const std::wstring label = ModeIndicatorLabel(kana_mode_, engine_mode);
  if (label == last_mode_label_) return;
  last_mode_label_ = label;

  // Independent of mode_indicator_enabled_ below: the taskbar icon and the
  // transient popup are two separate UI surfaces, and TSF should still
  // re-query GetIcon() for a real mode change even if the popup is off.
  if (input_mode_button_ != nullptr) {
    input_mode_button_->NotifyUpdate(TF_LBI_ICON | TF_LBI_STATUS);
  }

  if (!mode_indicator_enabled_) return;
  POINT anchor{};
  if (context != nullptr && last_caret_valid_) {
    anchor.x = last_caret_rect_.left;
    anchor.y = last_caret_rect_.bottom;
  } else {
    GetCursorPos(&anchor);
  }
  mode_indicator_.Show(label, anchor);
}

HRESULT TextService::ApplyDisplayAttribute(TfEditCookie edit_cookie,
                                           ITfContext* context, ITfRange* range,
                                           REFGUID guid) {
  ITfCategoryMgr* categories = nullptr;
  HRESULT result = CoCreateInstance(CLSID_TF_CategoryMgr, nullptr,
      CLSCTX_INPROC_SERVER, IID_ITfCategoryMgr,
      reinterpret_cast<void**>(&categories));
  TfGuidAtom atom = TF_INVALID_GUIDATOM;
  if (SUCCEEDED(result)) result = categories->RegisterGUID(guid, &atom);
  if (categories != nullptr) categories->Release();
  ITfProperty* property = nullptr;
  if (SUCCEEDED(result)) result = context->GetProperty(GUID_PROP_ATTRIBUTE, &property);
  if (SUCCEEDED(result)) {
    VARIANT value; VariantInit(&value); value.vt = VT_I4; value.lVal = atom;
    result = property->SetValue(edit_cookie, range, &value);
    property->Release();
  }
  return result;
}
