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
#include <textstor.h>
#include "registry_settings.h"

#include <cstdarg>
#include <chrono>
#include <cstdio>
#include <memory>
#include <new>
#include <shellapi.h>
#include <thread>
#include <utility>

namespace {
constexpr DWORD kInteractiveTimeoutMs = 350;
// Dictionary lookup may legitimately take longer than an ordinary kana
// keystroke. This is only an upper bound; fast conversions still return
// immediately, while a slow lookup no longer causes a destructive resync.
constexpr DWORD kConversionTimeoutMs = 1500;
// Mode-key replay stays off the UI thread. The first use of DDSKK's
// region-conversion path can exceed the dictionary transaction budget;
// retain its response and queued keys instead of dropping the mode change.
constexpr DWORD kModeReplayTimeoutMs = 5000;
constexpr UINT kProviderResultMessage = WM_APP + 0x4e1;
constexpr wchar_t kProviderWindowClass[] = L"NeLispImeProviderResultWindow";
constexpr UINT kPublishStateMessage = WM_APP + 91;
constexpr UINT kModeIndicatorMessage = WM_APP + 92;
constexpr UINT kInlineMessage = WM_APP + 93;
constexpr UINT kConfirmationReplayMessage = WM_APP + 94;
constexpr UINT kRegistrationReplayMessage = WM_APP + 95;
size_t InlineCursor(const ddskk::EngineState& state) {
  const auto display = state.text + state.pending_romaji;
  size_t units = display.size();
  if (!state.segments.empty() && state.active_segment >= 0 &&
      static_cast<size_t>(state.active_segment) < state.segments.size()) {
    const auto& segment = state.segments[state.active_segment];
    units = static_cast<size_t>(std::clamp(segment.start + segment.length,
                                         0, static_cast<int>(display.size())));
  }
  size_t points = 0;
  for (size_t i = 0; i < units; ++i, ++points)
    if (IS_HIGH_SURROGATE(display[i]) && i + 1 < units &&
        IS_LOW_SURROGATE(display[i + 1])) ++i;
  return points;
}
void DelayTestProvider() {
#ifdef NATIVEIME_CORE_PROVIDER_DELAY_MS
  Sleep(NATIVEIME_CORE_PROVIDER_DELAY_MS);
#endif
}
void DelayRegistrationProvider(bool registration) {
  if (!registration || !GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", nullptr, 0)) return;
  wchar_t value[16]{};
  if (!GetEnvironmentVariableW(L"NATIVEIME_TEST_REGISTRATION_WORKER_DELAY_MS", value, 16)) return;
  const DWORD delay = std::min<DWORD>(30000, wcstoul(value, nullptr, 10));
  if (!delay) return;
  std::printf("REGISTRATION_WORKER delay_ms=%lu\n", delay);
  Sleep(delay); // Private negative control; runs only on the provider worker.
}
std::atomic<DWORD> process_publication_sequence{0};
std::atomic<unsigned> process_publishers{0};
// Writers serialize outside key callbacks. Queuing never acquires this mutex.
std::mutex process_publication_writer;
DWORD process_flushed_sequence = 0;
struct PublicationLock {
  const NativeImeCallbacks& callbacks;
  explicit PublicationLock(const NativeImeCallbacks& cb) : callbacks(cb) {
    if (callbacks.publication_lock) callbacks.publication_lock(callbacks.owner, TRUE);
  }
  ~PublicationLock() { if (callbacks.publication_lock) callbacks.publication_lock(callbacks.owner, FALSE); }
};

bool ControlDown() {
  // Some TSF hosts update the thread-local keyboard state after dispatching
  // TestKeyDown/KeyDown.  The asynchronous state keeps Ctrl+G/Ctrl+J
  // reliable in those hosts while GetKeyState remains the normal path.
  return (GetKeyState(VK_CONTROL) & 0x8000) != 0 ||
         (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0;
}

bool ShiftDown() {
  // Match ControlDown(): some hosts expose the modifier through async
  // state first.  A VK_Q value alone cannot distinguish q from Shift+Q.
  return (GetKeyState(VK_SHIFT) & 0x8000) != 0 ||
         (GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0;
}

bool SameComIdentity(IUnknown* left, IUnknown* right);

class StateEditSession final : public ITfEditSession {
 public:
  StateEditSession(TextService* service, ITfContext* context,
                   ddskk::EngineState state, const wchar_t* path = L"engine", uint64_t sequence = 0,
                   bool confirmation = false)
      : service_(service), context_(context), state_(std::move(state)),
        confirmation_(confirmation), fresh_key_(service->ReplayingConfirmation()),
        sequence_(sequence ? sequence : service->KeySequence()), generation_(service->EditGeneration()), path_(path) {
    service_->StateSessionCreated();
    service_->AddRef();
    context_->AddRef();
    if (confirmation_) service_->RememberConfirmation(state_);
    if (fresh_key_) insertion_start_ = service_->TakeConfirmationAnchor();
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
    if (!service_->StateEditAllowed(context_, generation_)) {
      service_->TracePhase(L"edit-abandoned", sequence_, path_, S_FALSE);
      return S_FALSE;
    }
    const auto saved_trace = service_->SetEditTraceSequence(sequence_);
    service_->TracePhase(L"edit-start", sequence_, path_);
    ITfRange* end = nullptr;
    const HRESULT result = service_->ApplyEngineState(edit_cookie, context_, state_, &pair_caret_,
        insertion_start_, confirmation_ ? &end : nullptr, fresh_key_);
    if (confirmation_) service_->ConfirmationFinished(context_, generation_, result, end);
    if (end) end->Release();
    service_->FinishStateEdit(context_, state_, result);
    service_->TracePhase(L"edit-end", sequence_, path_, result);
    service_->SetEditTraceSequence(saved_trace);
    return result;
  }

 private:
  ~StateEditSession() {
    // Synchronous callers retain this reference through text-store unlock.
    pair_caret_.Complete();
    if (insertion_start_) insertion_start_->Release();
    service_->StateSessionExecuted();
    context_->Release();
    service_->Release();
  }
  LONG ref_count_ = 1;
  TextService* service_;
  ITfContext* context_;
  ddskk::EngineState state_;
  bool confirmation_ = false, fresh_key_ = false;
  ITfRange* insertion_start_ = nullptr;
  uint64_t sequence_, generation_;
  const wchar_t* path_;
  ddskk::AutoPairCaretUpdate pair_caret_;
};

// Ends one exact composition even after TextService has moved on to another
// ITfContext. A generic StateEditSession consults service_->composition_ at
// execution time, which is necessarily the wrong object once an async edit
// runs after a tab/focus switch.
class TerminateCompositionEditSession final : public ITfEditSession {
 public:
  TerminateCompositionEditSession(ITfComposition* composition, bool settle)
      : composition_(composition), settle_(settle) {
    composition_->AddRef();
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
    ITfRange* range = nullptr;
    HRESULT result = composition_->GetRange(&range);
    if (SUCCEEDED(result)) {
      if (settle_) {
        wchar_t text[4096]{};
        ULONG fetched = 0;
        result = range->GetText(edit_cookie, 0, text,
                                static_cast<ULONG>(_countof(text) - 1),
                                &fetched);
        if (SUCCEEDED(result)) {
          const ULONG marker = fetched > 0 && (text[0] == L'\x25bd' ||
                                               text[0] == L'\x25bc') ? 1 : 0;
          result = range->SetText(edit_cookie, 0, text + marker,
                                  static_cast<LONG>(fetched - marker));
        }
      } else {
        result = range->SetText(edit_cookie, 0, L"", 0);
      }
      range->Release();
    }
    if (FAILED(result)) return result;
    return composition_->EndComposition(edit_cookie);
  }

 private:
  ~TerminateCompositionEditSession() { composition_->Release(); }
  LONG ref_count_ = 1;
  ITfComposition* composition_;
  bool settle_;
};
std::string NarrowUtf8(const wchar_t* text) {
  if (!text || !*text) return {};
  const int size = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0,
                                       nullptr, nullptr);
  if (size <= 1) return {};
  std::string out(static_cast<size_t>(size - 1), '\0');
  WideCharToMultiByte(CP_UTF8, 0, text, -1, out.data(), size, nullptr,
                      nullptr);
  return out;
}

// Read a setting scoped to one engine.  The settings window writes these
// under Software\NativeIME\Engines\<id> so two engines can use
// the same name; FALLBACK is what the shared root key held, which keeps
// profiles written before the split working.
DWORD ReadEngineDword(const wchar_t* engine_id, const wchar_t* name,
                      DWORD fallback) {
  if (!engine_id || !*engine_id) return fallback;
  std::wstring subkey = NativeImeRegistryKey() + L"\\Engines\\";
  subkey += engine_id;
  HKEY key = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, subkey.c_str(), 0, KEY_READ, &key) !=
      ERROR_SUCCESS) {
    return fallback;
  }
  DWORD value = fallback, bytes = sizeof(value), type = 0;
  if (RegQueryValueExW(key, name, nullptr, &type,
                       reinterpret_cast<BYTE*>(&value), &bytes) !=
          ERROR_SUCCESS ||
      type != REG_DWORD) {
    value = fallback;
  }
  RegCloseKey(key);
  return value;
}

constexpr wchar_t kCaretMapName[] = L"Local\\ddskk-ime-caret-v1";
struct SharedImeCaret {
  volatile LONG sequence;
  RECT rect;
  DWORD process_id;
};
HANDLE g_caret_map = nullptr;
SharedImeCaret* g_caret_view = nullptr;

// Publish the TSF-owned text extent for Sumi. This is deliberately a
// separate one-way mapping: candidate placement must never send a request
// through the engine pipe or contend with the keystroke mutex.
void PublishCaretRect(const RECT& rect) {
  if (g_caret_view == nullptr) {
    // Private harnesses must never overwrite Sumi's live caret mapping.
    std::wstring map_name = kCaretMapName;
    wchar_t test_map[256]{};
    if (NativeImeRegistryKey().starts_with(L"Software\\NativeIME-test-") &&
        GetEnvironmentVariableW(L"NATIVEIME_TEST_CARET_MAP", test_map, _countof(test_map)) > 0 &&
        std::wstring(test_map).starts_with(L"Local\\ddskk-test-caret-"))
      map_name = test_map;
    g_caret_map = CreateFileMappingW(INVALID_HANDLE_VALUE, nullptr,
                                     PAGE_READWRITE, 0,
                                     sizeof(SharedImeCaret), map_name.c_str());
    if (g_caret_map == nullptr) return;
    g_caret_view = static_cast<SharedImeCaret*>(MapViewOfFile(
        g_caret_map, FILE_MAP_WRITE, 0, 0, sizeof(SharedImeCaret)));
    if (g_caret_view == nullptr) {
      CloseHandle(g_caret_map);
      g_caret_map = nullptr;
      return;
    }
  }
  InterlockedIncrement(&g_caret_view->sequence);  // odd = writer owns it
  g_caret_view->rect = rect;
  g_caret_view->process_id = GetCurrentProcessId();
  MemoryBarrier();
  InterlockedIncrement(&g_caret_view->sequence);  // even = stable snapshot
}

}  // namespace

LONG g_object_count = 0;
LONG g_lock_count = 0;

struct TextService::ProviderResult {
  TextService* owner = nullptr;
  uint64_t sequence = 0;
  std::optional<ddskk::EngineState> state;
  bool apply_state = true;
  uint64_t key_sequence = 0;
  bool preview_only = false;
  bool settings_pending = false;
  std::optional<ddskk::EngineState> registration_learning;
};

TextService::TextService() {
  InterlockedIncrement(&g_object_count);
  engine_.SetConnectionFailureHandler([this] { EnsureEngineHost(); });
}

TextService::~TextService() {
  fallback_rules_.reset();
  inline_channel_.Stop();
  FlushDebugLog();
  if (candidate_ui_) candidate_ui_->DetachHandler();
  RemovePublishedState();
  settings_watcher_.Stop();
  if (provider_window_ != nullptr) DestroyWindow(provider_window_);
  if (active_context_ != nullptr) active_context_->Release();
  if (registration_range_ != nullptr) registration_range_->Release();
  if (candidate_context_ != nullptr) candidate_context_->Release();
  if (candidate_ui_ != nullptr) candidate_ui_->Release();
  for (ITfComposition* composition : ending_compositions_)
    composition->Release();
  if (composition_ != nullptr) composition_->Release();
  UnadviseOpenCloseCompartment();
  UnadviseKeySink();
  InterlockedDecrement(&g_object_count);
}

LRESULT CALLBACK TextService::ProviderWindowProc(HWND window, UINT message,
                                                  WPARAM wparam,
                                                  LPARAM lparam) {
  if (message == WM_NCCREATE) {
    const auto* create = reinterpret_cast<const CREATESTRUCTW*>(lparam);
    SetWindowLongPtrW(window, GWLP_USERDATA,
                      reinterpret_cast<LONG_PTR>(create->lpCreateParams));
  }
  auto* service = reinterpret_cast<TextService*>(
      GetWindowLongPtrW(window, GWLP_USERDATA));
  if ((message == kRegistrationReplayMessage || (message == WM_TIMER && wparam == 8)) &&
      service != nullptr) {
    KillTimer(window, 8);
    service->ReplayDeferredProviderKeys();
    return 0;
  }
  if (message == kInlineMessage && service != nullptr) {
    service->HandleInlineEvent();
    return 0;
  }
  if (message == kConfirmationReplayMessage && service != nullptr) {
    if (!service->confirmation_resume_posted_ ||
        static_cast<uint64_t>(lparam) != service->confirmation_dispatch_sequence_) return 0;
    if (!wparam) {
      // Cross another message boundary after the commit lock releases. IMM
      // result notifications queued by CUAS at unlock precede this continuation.
      if (!PostMessageW(window, kConfirmationReplayMessage, 1, lparam))
        service->confirmation_resume_posted_ = false;
    } else {
      service->confirmation_resume_posted_ = false;
      service->confirmation_delivery_pending_ = false;
      service->ResumeConfirmedKeys();
    }
    return 0;
  }
  if (message == WM_TIMER && wparam == 7 && service != nullptr) {
    service->RetryConfirmation(); return 0;
  }
  if (message == kPublishStateMessage && service != nullptr) {
    service->FlushPublishedState();
    return 0;
  }
  if (message == kModeIndicatorMessage && service != nullptr) {
    service->FlushModeIndicator();
    return 0;
  }
  if (message == WM_TIMER && wparam == 6 && service != nullptr) {
    if (!service->local_conversion_.active() || !service->active_context_) {
      if (service->local_conversion_retry_ && service->active_context_) return 0;
      service->local_store_.CancelServer();
      service->local_server_next_ = false; KillTimer(window, 6); return 0;
    }
    auto& conversion = service->local_conversion_;
    auto reply = service->local_store_.Server(conversion.reading(), conversion.okuri());
    const auto before_update = conversion;
    if (reply && reply->ready && reply->supported && conversion.UpdateServer(reply->candidates) &&
        FAILED(service->ApplyLocalState(service->active_context_, conversion.State()))) {
      conversion = before_update; return 0; // Retain the authoritative selection and retry on the next tick.
    }
    if (service->local_server_next_ && ((reply && reply->ready) || GetTickCount64() >= service->local_server_deadline_)) {
      service->local_server_next_ = false;
      if (service->local_server_menu_ ? conversion.NextMenu() : conversion.Next()) {
        if (FAILED(service->ApplyLocalState(service->active_context_, conversion.State()))) service->ScheduleLocalRetry();
      }
      else {
        const auto saved = conversion; conversion.Reset(); service->provider_composition_active_ = false;
        if (!service->BeginProviderConversion(service->realtime_frontend_.raw_keys(), false,
            saved.State().candidates.size())) conversion = saved;
      }
    }
    return 0;
  }
  if (message == WM_TIMER && wparam == 9 && service != nullptr) {
    if (!service->provider_conversion_retry_ || !service->active_context_ ||
        !service->realtime_frontend_.preedit()) {
      service->SettleIdleProviderState(); KillTimer(window, 9); return 0;
    }
    if (service->TryLocalConversionFallback()) {
      KillTimer(window, 9); service->ReplayDeferredProviderKeys();
    } else if (!service->provider_pending_.load() && service->engine_.IsConnected() &&
               service->provider_settings_.load() == service->applied_provider_settings_.load()) {
      if (service->BeginProviderConversion(service->realtime_frontend_.raw_keys(),
          service->provider_conversion_registration_, service->provider_conversion_skip_)) {
        service->provider_conversion_retry_ = false;
        if (GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", nullptr, 0)) {
          std::printf("PROVIDER_SETTINGS conversion_resumed=1\n");
          std::fflush(stdout);
        }
        KillTimer(window, 9);
        service->ShowProviderBusy(service->active_context_);
      }
    }
    return 0;
  }
  if (message == WM_TIMER && wparam == 5 && service != nullptr) {
    service->FlushDebugLog();
    return 0;
  }
  if (message == WM_TIMER && wparam == 4 && service != nullptr) {
    if (!service->local_observer_retry_ || !service->local_enabled_ ||
        GetTickCount64() >= service->local_observer_deadline_ ||
        service->local_store_.PublishState(*service->local_observer_retry_, false)) {
      service->local_observer_retry_.reset(); KillTimer(window, 4);
    }
    return 0;
  }
  if (message == WM_TIMER && wparam == 3 && service != nullptr) {
    service->RetryLocalConversion();
    return 0;
  }
  if (message == WM_TIMER && wparam == 2 && service != nullptr) {
    // Failed core replacement has no ABI resume notification. Resume only
    // after the shim stops requesting quiescence; never compete with its swap.
    if (service->local_store_.started() && GetTickCount64() - service->local_handoff_requested_ > 500)
      service->local_store_.Start();
    return 0;
  }
  if (message == WM_TIMER && wparam == 1 && service != nullptr) {
    if (service->local_enabled_ && service->provider_pending_.load() &&
        service->provider_deadline_ && GetTickCount64() >= service->provider_deadline_) {
      if (service->provider_conversion_active_) service->RetainProviderConversion();
      else service->ResolveLocalFallback();
    }
    return 0;
  }
  if (message == kProviderResultMessage) {
    std::unique_ptr<ProviderResult> result(
        reinterpret_cast<ProviderResult*>(lparam));
    if (result && service == result->owner) service->ApplyProviderResult(result.get());
    if (result && result->owner) result->owner->Release();
    return 0;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

bool TextService::CreateProviderWindow() {
  if (provider_window_ != nullptr) return true;
  // Scope the class to this DLL, not the host EXE. A registered live TIP
  // and a side-by-side test DLL may coexist in one process; sharing an
  // EXE-scoped class dispatches ProviderResult through the other DLL's
  // window procedure and its incompatible state layout.
  HMODULE instance = nullptr;
  if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                         GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                         reinterpret_cast<LPCWSTR>(&TextService::ProviderWindowProc),
                         &instance)) return false;
  WNDCLASSW window_class{};
  window_class.lpfnWndProc = &TextService::ProviderWindowProc;
  window_class.hInstance = instance;
  window_class.lpszClassName = kProviderWindowClass;
  if (RegisterClassW(&window_class) == 0 &&
      GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return false;
  provider_window_ = CreateWindowExW(
      0, kProviderWindowClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr,
      instance, this);
  return provider_window_ != nullptr;
}

void TextService::PrepareProviderReading() {
  if (engine_id_ != "ddskk" || local_enabled_ ||
      !realtime_frontend_.preedit() || realtime_frontend_.okuri_started()) return;
  auto keys = realtime_frontend_.raw_keys();
  if (realtime_frontend_.katakana()) keys.insert(keys.begin(), U'q');
  const auto sequence = preparation_sequence_.fetch_add(1) + 1;
  AddRef();
  try {
    std::thread([this, keys = std::move(keys), sequence] {
      {
        std::lock_guard<std::mutex> lock(provider_engine_mutex_);
        // Coalesce typing bursts. Conversion/focus cancellation invalidates
        // queued preparation before it can modify the live context.
        if (preparation_sequence_.load() == sequence && ApplyProviderSettings())
          engine_.PrepareKeys(keys, kConversionTimeoutMs);
      }
      Release();
    }).detach();
  } catch (...) { Release(); }
}

bool TextService::BeginProviderConversion(const std::u32string& keys, bool registration, size_t skip,
                                          std::wstring preview_reading) {
  if (!registration && !skip && !provider_pending_.load() &&
      (provider_settings_.load() != applied_provider_settings_.load() || !engine_.IsConnected()) &&
      TryLocalConversionFallback()) return true;
  preparation_sequence_.fetch_add(1);
  CancelLocalRetry();
  local_observer_retry_.reset();
  local_store_.ReleaseState();
  if (keys.empty() || provider_window_ == nullptr) return false;
  if (okuri_handoff_active_) okuri_handoff_keys_ = realtime_frontend_.raw_keys();
  provider_cleanup_pending_ = false;
  provider_conversion_active_ = true;
  provider_conversion_registration_ = registration;
  provider_conversion_skip_ = skip;
  provider_conversion_started_ = GetTickCount64();
  const auto key_sequence = key_sequence_;
  TracePhase(L"engine-lookup-request", key_sequence, L"engine");
  const uint64_t sequence =
      provider_sequence_.fetch_add(1, std::memory_order_acq_rel) + 1;
  provider_pending_.store(true, std::memory_order_release);
  if (local_enabled_) {
    provider_deadline_ = GetTickCount64() + kModeReplayTimeoutMs * (skip + 2);
    SetTimer(provider_window_, 1, 50, nullptr);
  }
  const HWND destination = provider_window_;
  const bool retry_okuri = okuri_handoff_active_ && okuri_handoff_retry_;
  AddRef();
  try {
    std::thread([this, keys, sequence, key_sequence, destination, retry_okuri, registration, skip,
                 preview_reading = std::move(preview_reading)] {
      if (!preview_reading.empty()) {
        TracePhase(L"provider-preview-start", key_sequence, L"engine-worker");
        std::optional<std::vector<std::wstring>> preview;
        {
          std::lock_guard<std::mutex> lock(provider_engine_mutex_);
          wchar_t delay[16]{};
          if (GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", nullptr, 0) &&
              GetEnvironmentVariableW(L"NATIVEIME_TEST_PROVIDER_PREVIEW_DELAY_MS", delay, 16)) {
            const DWORD ms = std::min<DWORD>(30000, wcstoul(delay, nullptr, 10));
            std::printf("PROVIDER_PREVIEW_WORKER delay_ms=%lu\n", ms);
            Sleep(ms); // Private negative control, never on the TSF key callback.
          }
          if (ApplyProviderSettings(25)) preview = engine_.PreviewCandidates(preview_reading, 8);
        }
        TracePhase(L"provider-preview-end", key_sequence, L"engine-worker");
        if (preview && !preview->empty()) {
          ddskk::EngineState snapshot;
          snapshot.mode = L"provider-preview";
          snapshot.candidate_index = 0;
          snapshot.candidates = std::move(*preview);
          auto* interim = new (std::nothrow) ProviderResult{
              this, sequence, std::move(snapshot), false, key_sequence, true};
          if (interim) {
            AddRef(); // Preview and final result have independent message lifetimes.
            if (!PostMessageW(destination, kProviderResultMessage, 0, reinterpret_cast<LPARAM>(interim))) {
              delete interim;
              Release();
            }
          }
        }
      }
      if (retry_okuri) Sleep(100);
      DelayTestProvider();
      TracePhase(L"engine-lookup-start", key_sequence, L"engine");
      DebugLog(L"Provider convert begin seq=%llu keys=%zu",
               static_cast<unsigned long long>(sequence), keys.size());
      std::optional<ddskk::EngineState> state;
      bool settings_ready = false;
      bool provider_unavailable = false;
      {
        std::lock_guard<std::mutex> lock(provider_engine_mutex_);
        const ULONGLONG deadline = GetTickCount64() +
            (registration || local_enabled_ ? kModeReplayTimeoutMs : kConversionTimeoutMs);
        // An unavailable selector is a transient worker condition, not an
        // empty conversion reply. Retain this request while it reconnects.
        // Selection retries belong to the background worker. A missing host
        // must promptly return ownership to native fallback/retention.
        settings_ready = ApplyProviderSettings(25);
        if (settings_ready) {
          const auto now = GetTickCount64();
          if (now < deadline) {
            const auto remaining = static_cast<DWORD>(deadline - now);
            state = registration ? engine_.RegisterLocal(keys, remaining)
                                 : engine_.ConvertKeys(keys, remaining);
          } else settings_ready = false;
        }
        // A local miss can spend longer entering DDSKK's registration editor
        // than an ordinary lookup. Retry entry once, never retry selection
        // merely because a sent conversion returned no state.
        if (settings_ready && !state && local_enabled_ && !registration)
          state = engine_.RegisterLocal(keys, kModeReplayTimeoutMs);
        for (size_t n = 0; n < skip && state && state->mode == L"candidate"; ++n)
          state = engine_.SendControl(ddskk::EngineControl::kConvert,
              local_enabled_ ? kModeReplayTimeoutMs : kConversionTimeoutMs);
        const auto error = engine_.ConnectionError();
        provider_unavailable = !engine_.IsConnected() &&
            (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND);
      }
      TracePhase(L"engine-lookup-end", key_sequence, L"engine", state ? S_OK : E_FAIL);
      DebugLog(L"Provider convert done seq=%llu state=%d raw=%hs",
               static_cast<unsigned long long>(sequence), state ? 1 : 0,
               engine_.last_response().c_str());
      wchar_t harness_diagnostics[2]{};
      if (GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS",
                                  harness_diagnostics, 2) > 0) {
        std::printf("PROVIDER done seq=%llu state=%d raw=%.160s\n",
                    static_cast<unsigned long long>(sequence), state ? 1 : 0,
                    engine_.last_response().c_str());
        std::fflush(stdout);
      }
      const bool settings_pending = ProviderConversionSettingsPending(settings_ready, provider_unavailable);
      auto* result = new (std::nothrow) ProviderResult{this, sequence,
                                                       std::move(state), true, key_sequence, false, settings_pending};
      if (result == nullptr ||
          !PostMessageW(destination, kProviderResultMessage, 0,
                        reinterpret_cast<LPARAM>(result))) {
        DebugLog(L"Provider convert post failed seq=%llu error=%u",
                 static_cast<unsigned long long>(sequence), GetLastError());
        delete result;
        Release();
      }
    }).detach();
  } catch (...) {
    provider_pending_.store(false, std::memory_order_release);
    Release();
    return false;
  }
  return true;
}

bool TextService::BeginProviderControl(ddskk::EngineControl control,
                                       bool apply_state) {
  if (apply_state) { local_observer_retry_.reset(); local_store_.ReleaseState(); }
  if (provider_window_ == nullptr) return false;
  DWORD test_failure_delay = 0;
  // Copy the authoritative candidate and reading before the worker starts.
  // A failed read may already have changed (or committed) the engine session.
  const auto candidate = apply_state && engine_id_ == "ddskk"
      ? provider_candidate_state_ : std::optional<ddskk::EngineState>{};
  auto reading = realtime_frontend_.raw_keys();
  if (realtime_frontend_.katakana()) reading.insert(reading.begin(), U'q');
  wchar_t test_delay[16]{}, test_registry[128]{};
  if (apply_state && control == ddskk::EngineControl::kCommit &&
      candidate_index_ >= 0 && !candidate_control_test_failure_used_ &&
      GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", nullptr, 0) &&
      GetEnvironmentVariableW(L"NATIVEIME_REGISTRY_KEY", test_registry, 128) &&
      std::wstring(test_registry).starts_with(L"Software\\NativeIME-test-") &&
      GetEnvironmentVariableW(L"NATIVEIME_TEST_CANDIDATE_CONTROL_FAIL_MS", test_delay, 16)) {
    test_failure_delay = std::min<DWORD>(30000, wcstoul(test_delay, nullptr, 10));
    candidate_control_test_failure_used_ = true;
  }
  provider_cleanup_pending_ = !apply_state;
  provider_conversion_active_ = false;
  const uint64_t sequence =
      provider_sequence_.fetch_add(1, std::memory_order_acq_rel) + 1;
  provider_pending_.store(true, std::memory_order_release);
  if (local_enabled_) {
    provider_deadline_ = GetTickCount64() + (registration_mode_ ? 10000 : 5000);
    SetTimer(provider_window_, 1, 50, nullptr);
  }
  const auto key_sequence = key_sequence_;
  TracePhase(L"engine-lookup-request", key_sequence, L"engine");
  const HWND destination = provider_window_;
  const bool bounded_recovery = local_enabled_;
  const bool registration = registration_mode_;
  AddRef();
  try {
    std::thread([this, control, sequence, key_sequence, destination, apply_state, test_failure_delay,
                 candidate, reading, bounded_recovery, registration] {
      const ULONGLONG started = GetTickCount64();
      TracePhase(L"engine-lookup-start", key_sequence, L"engine");
      DelayTestProvider();
      DelayRegistrationProvider(registration);
      std::optional<ddskk::EngineState> state;
      std::optional<ddskk::EngineState> registration_learning;
      {
        std::lock_guard<std::mutex> lock(provider_engine_mutex_);
        // A new conversion resets the engine session itself. If it acquired
        // the mutex first, an old cleanup must not cancel that new episode.
        const bool settings_ready = (apply_state ||
            sequence == provider_sequence_.load(std::memory_order_acquire)) && ApplyProviderSettings();
        if (settings_ready)
          state = engine_.SendControl(control, registration ? kModeReplayTimeoutMs : kConversionTimeoutMs);
        if (test_failure_delay) {
          // Simulate a timed-out read after the engine accepted the control.
          // Recovery must not assume the old session stayed unchanged.
          Sleep(test_failure_delay);
          state.reset();
          engine_.MarkNeedsResync();
          std::printf("CANDIDATE_TEST lost-reply seq=%llu delay_ms=%lu\n",
                      static_cast<unsigned long long>(sequence), test_failure_delay);
          std::fflush(stdout);
        }
        if (settings_ready && candidate && !reading.empty() && candidate->candidate_index >= 0 &&
            static_cast<size_t>(candidate->candidate_index) < candidate->candidates.size() &&
            (control == ddskk::EngineControl::kConvert ||
             control == ddskk::EngineControl::kPrevious ||
             control == ddskk::EngineControl::kCommit)) {
          int target = candidate->candidate_index;
          if (control == ddskk::EngineControl::kConvert) ++target;
          if (control == ddskk::EngineControl::kPrevious) --target;
          const bool select_only = target >= 0 &&
              static_cast<size_t>(target) < candidate->candidates.size() &&
              control != ddskk::EngineControl::kCommit;
          const auto& wanted = candidate->candidates[
              select_only ? target : candidate->candidate_index];
          // Local opt-in may fall back to this provider. Engine loss must
          // resolve that episode rather than park all subsequent keys forever.
          const ULONGLONG recovery_deadline = GetTickCount64() + 3000;
          while (!state && sequence == provider_sequence_.load(std::memory_order_acquire) &&
                 (!bounded_recovery || GetTickCount64() < recovery_deadline)) {
            if (GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", nullptr, 0)) {
              std::printf("PROVIDER retry seq=%llu control=%d raw=%.160s\n",
                          static_cast<unsigned long long>(sequence), static_cast<int>(control),
                          engine_.last_response().c_str());
              std::fflush(stdout);
            }
            Sleep(100);
            // CONVERT-KEYS resets and replays the reading. Never resend the
            // failed control against a session whose outcome is unknown.
            auto restored = engine_.ConvertKeys(reading, kConversionTimeoutMs);
            if (!restored || restored->mode != L"candidate") continue;
            const auto found = std::find(restored->candidates.begin(),
                                         restored->candidates.end(), wanted);
            if (found == restored->candidates.end()) continue;
            const int index = static_cast<int>(found - restored->candidates.begin());
            // Learning from a late commit can reorder candidates. Recover
            // by candidate identity, rather than the old numeric index.
            for (size_t attempts = 0; restored && restored->candidate_index != index &&
                 attempts < candidate->candidates.size(); ++attempts) {
              if (sequence != provider_sequence_.load(std::memory_order_acquire)) break;
              restored = engine_.SendControl(restored->candidate_index < index
                  ? ddskk::EngineControl::kConvert : ddskk::EngineControl::kPrevious,
                  kConversionTimeoutMs);
            }
            if (sequence != provider_sequence_.load(std::memory_order_acquire)) break;
            if (!restored || restored->candidate_index != index) continue;
            state = select_only ? std::move(restored)
                                : engine_.SendControl(control, kConversionTimeoutMs);
            if (state && GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", nullptr, 0)) {
              std::printf("PROVIDER recovered seq=%llu control=%d candidate=%d\n",
                          static_cast<unsigned long long>(sequence), static_cast<int>(control), index);
              std::fflush(stdout);
            }
          }
        }
        if (!apply_state) {
          wchar_t diagnostics[2]{};
          if (GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS",
                                      diagnostics, 2) > 0) {
            std::printf("ENGINE_RELEASE ok=%d candidates=%zu raw=%s\n",
                        state ? 1 : 0, state ? state->candidates.size() : 0,
                        engine_.last_response().c_str());
            std::fflush(stdout);
          }
        }
        if (GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", nullptr, 0)) {
          std::printf("PROVIDER control seq=%llu control=%d state=%d ms=%llu raw=%.160s\n",
                      static_cast<unsigned long long>(sequence), static_cast<int>(control),
                      state ? 1 : 0, GetTickCount64() - started,
                      engine_.last_response().c_str());
          std::fflush(stdout);
        }
        if (registration && bounded_recovery && control == ddskk::EngineControl::kCommit && state)
          registration_learning = engine_.RegistrationLearning();
      }
      TracePhase(L"engine-lookup-end", key_sequence, L"engine", state ? S_OK : E_FAIL);
      auto* result = new (std::nothrow) ProviderResult{this, sequence,
                                                       std::move(state), apply_state, key_sequence};
      if (result) result->registration_learning = std::move(registration_learning);
      if (result == nullptr ||
          !PostMessageW(destination, kProviderResultMessage, 0,
                        reinterpret_cast<LPARAM>(result))) {
        delete result;
        Release();
      }
    }).detach();
  } catch (...) {
    provider_pending_.store(false, std::memory_order_release);
    Release();
    return false;
  }
  return true;
}

bool TextService::BeginProviderKey(char32_t key, bool may_convert) {
  local_observer_retry_.reset(); local_store_.ReleaseState();
  if (provider_window_ == nullptr) return false;
  if (may_convert && realtime_frontend_.okuri_started()) {
    if (!okuri_handoff_active_) okuri_handoff_retry_ = false;
    okuri_handoff_active_ = true;
    okuri_handoff_failed_ = false;
    okuri_handoff_keys_ = realtime_frontend_.raw_keys();
  }
  provider_cleanup_pending_ = false;
  provider_conversion_active_ = false;
  const uint64_t sequence =
      provider_sequence_.fetch_add(1, std::memory_order_acq_rel) + 1;
  provider_pending_.store(true, std::memory_order_release);
  if (local_enabled_) {
    provider_deadline_ = GetTickCount64() + (registration_mode_ ? 10000 : 5000);
    SetTimer(provider_window_, 1, 50, nullptr);
  }
  const auto key_sequence = key_sequence_;
  TracePhase(L"engine-lookup-request", key_sequence, L"engine");
  const HWND destination = provider_window_;
  const bool registration = registration_mode_;
  AddRef();
  try {
    std::thread([this, key, may_convert, sequence, key_sequence, destination, registration] {
      TracePhase(L"engine-lookup-start", key_sequence, L"engine");
      DelayTestProvider();
      DelayRegistrationProvider(registration);
      std::optional<ddskk::EngineState> state;
      {
        std::lock_guard<std::mutex> lock(provider_engine_mutex_);
        if (ApplyProviderSettings()) state = engine_.SendKey(key, registration ? kModeReplayTimeoutMs : may_convert ? kConversionTimeoutMs
                                               : kInteractiveTimeoutMs);
      }
      TracePhase(L"engine-lookup-end", key_sequence, L"engine", state ? S_OK : E_FAIL);
      auto* result = new (std::nothrow) ProviderResult{
          this, sequence, std::move(state), true, key_sequence};
      if (result == nullptr ||
          !PostMessageW(destination, kProviderResultMessage, 0,
                        reinterpret_cast<LPARAM>(result))) {
        delete result;
        Release();
      }
    }).detach();
  } catch (...) {
    provider_pending_.store(false, std::memory_order_release);
    Release();
    return false;
  }
  return true;
}

bool TextService::BeginProviderKeys(const std::u32string& keys, bool sync) {
  local_observer_retry_.reset(); local_store_.ReleaseState();
  if (keys.empty() || provider_window_ == nullptr) return false;
  if (sync && realtime_frontend_.okuri_started() &&
      (okuri_handoff_active_ || !provider_composition_active_)) {
    if (!okuri_handoff_active_) okuri_handoff_retry_ = false;
    okuri_handoff_active_ = true;
    okuri_handoff_failed_ = false;
    okuri_handoff_keys_ = realtime_frontend_.raw_keys();
  }
  DWORD test_failure_delay = 0;
  bool test_drop_reply = false;
  wchar_t test_delay[16]{}, test_registry[128]{};
  if (sync && realtime_frontend_.okuri_started() && !okuri_test_failure_used_ &&
      GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", nullptr, 0) &&
      GetEnvironmentVariableW(L"NATIVEIME_REGISTRY_KEY", test_registry, 128) &&
      std::wstring(test_registry).starts_with(L"Software\\NativeIME-test-")) {
    test_drop_reply = GetEnvironmentVariableW(
        L"NATIVEIME_TEST_OKURI_SYNC_FAIL_MS", test_delay, 16) != 0;
    if (test_drop_reply || GetEnvironmentVariableW(
        L"NATIVEIME_TEST_OKURI_SYNC_DELAY_MS", test_delay, 16)) {
      test_failure_delay = std::min<DWORD>(30000, wcstoul(test_delay, nullptr, 10));
      okuri_test_failure_used_ = true;
    }
  }
  provider_cleanup_pending_ = false;
  provider_conversion_active_ = false;
  const uint64_t sequence =
      provider_sequence_.fetch_add(1, std::memory_order_acq_rel) + 1;
  provider_pending_.store(true, std::memory_order_release);
  if (local_enabled_) {
    provider_deadline_ = GetTickCount64() + 5000;
    SetTimer(provider_window_, 1, 50, nullptr);
  }
  const auto key_sequence = key_sequence_;
  TracePhase(L"engine-lookup-request", key_sequence, L"engine");
  const HWND destination = provider_window_;
  AddRef();
  try {
    std::thread([this, keys, sync, sequence, key_sequence, destination, test_failure_delay,
                 test_drop_reply, retry_okuri = okuri_handoff_retry_] {
      if (retry_okuri) Sleep(100);
      TracePhase(L"engine-lookup-start", key_sequence, L"engine");
      DelayTestProvider();
      std::optional<ddskk::EngineState> state;
      {
        std::lock_guard<std::mutex> lock(provider_engine_mutex_);
        if (test_failure_delay) {
          Sleep(test_failure_delay);
          std::printf("OKURI_TEST %s seq=%llu delay_ms=%lu\n",
                      test_drop_reply ? "timeout" : "late-reply",
                      static_cast<unsigned long long>(sequence), test_failure_delay);
          std::fflush(stdout);
        }
        if (!test_drop_reply && ApplyProviderSettings()) {
          state = sync ? engine_.SyncKeys(keys, kModeReplayTimeoutMs)
                       : engine_.SendKeys(keys, kConversionTimeoutMs);
        }
      }
      TracePhase(L"engine-lookup-end", key_sequence, L"engine", state ? S_OK : E_FAIL);
      auto* result = new (std::nothrow) ProviderResult{
          this, sequence, std::move(state), true, key_sequence};
      if (result == nullptr ||
          !PostMessageW(destination, kProviderResultMessage, 0,
                        reinterpret_cast<LPARAM>(result))) {
        delete result;
        Release();
      }
    }).detach();
  } catch (...) {
    provider_pending_.store(false, std::memory_order_release);
    Release();
    return false;
  }
  return true;
}

void TextService::ResolveLocalFallback() {
  TracePhase(L"provider-fallback", key_sequence_, L"engine");
  // Keep semantic keys, invalidate replies, and return ownership to the native
  // reading. No engine transaction or worker lock belongs to this callback.
  auto queued = std::move(deferred_provider_keys_);
  CancelPendingProvider();
  // A rejected document write did not accept the provider state. Rebuild
  // from the native reading on the next worker transaction, not its live
  // candidate/navigation history. This flag never waits for engine I/O.
  engine_.MarkNeedsResync();
  provider_composition_active_ = false;
  provider_candidate_state_.reset();
  local_conversion_.Reset();
  local_okuri_snapshot_ = {};
  registration_mode_ = false;
  registration_commit_pending_ = false;
  if (registration_range_) { registration_range_->Release(); registration_range_ = nullptr; }
  CloseCandidateUi();
  ApplyLocalState(active_context_, realtime_frontend_.RestorePreedit());
  engine_roundtrip_failed_ = true;
  deferred_provider_keys_ = std::move(queued);
  std::printf("LOCAL_FALLBACK resolved=reading pending=0\n");
  ReplayDeferredProviderKeys();
}

void TextService::CancelPendingProvider() {
  if (provider_window_) KillTimer(provider_window_, 9);
  provider_conversion_retry_ = false;
  confirmation_resume_posted_ = false;
  confirmation_state_.reset();
  if (provider_window_) KillTimer(provider_window_, 7);
  confirmation_pending_ = confirmation_replay_ = false;
  confirmation_delivery_pending_ = false;
  if (confirmation_anchor_) confirmation_anchor_->Release();
  confirmation_anchor_ = nullptr;
  preparation_sequence_.fetch_add(1);
  provider_deadline_ = 0;
  okuri_conversion_started_qpc_ = 0;
  if (provider_window_) KillTimer(provider_window_, 1);
  okuri_handoff_active_ = false;
  okuri_handoff_failed_ = false;
  okuri_mirrored_keys_ = 0;
  provider_cleanup_pending_ = false;
  const uint64_t sequence =
      provider_sequence_.fetch_add(1, std::memory_order_acq_rel) + 1;
  DebugLog(L"Provider cancel seq=%llu",
           static_cast<unsigned long long>(sequence));
  provider_pending_.store(false, std::memory_order_release);
  deferred_provider_keys_.clear();
  provider_conversion_active_ = false;
  engine_.CancelPendingIo();
}

// A local Escape/Ctrl+G restore puts the reading back from
// realtime_frontend_, but the engine session is still in the candidate
// state the provider conversion left it in.  The host publishes that state
// to Sumi and answers its STATUS polls from it, so Sumi's candidate window
// stayed open after the user had cancelled.  The frontend owns the reading
// and the next Space reconverts from raw keys, so the engine side is simply
// cancelled; its reply is not applied to the document. Keep cleanup on the
// provider worker: even an uncontended engine round trip exceeds the local
// cancellation budget. Local input continues while cleanup finishes.
void TextService::ReleaseEngineConversion() {
  BeginProviderControl(ddskk::EngineControl::kCancel, false);
}

void TextService::TraceOkuriCandidate(bool local) {
  if (!okuri_conversion_started_qpc_) return;
  LARGE_INTEGER now{}, frequency{}; QueryPerformanceCounter(&now); QueryPerformanceFrequency(&frequency);
  if (GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", nullptr, 0))
    std::printf("OKURI-CANDIDATE us=%llu seq=%llu path=%s\n",
        static_cast<unsigned long long>((now.QuadPart - okuri_conversion_started_qpc_) * 1000000 / frequency.QuadPart),
        static_cast<unsigned long long>(++okuri_conversion_sequence_), local ? "local" : "engine");
  okuri_conversion_started_qpc_ = 0;
}

void TextService::ApplyProviderResult(ProviderResult* result) {
  DebugLog(L"Provider apply seq=%llu current=%llu state=%d",
           static_cast<unsigned long long>(result ? result->sequence : 0),
           static_cast<unsigned long long>(
               provider_sequence_.load(std::memory_order_acquire)),
           result && result->state ? 1 : 0);
  if (result == nullptr ||
      result->sequence != provider_sequence_.load(std::memory_order_acquire))
    return;
  if (result->preview_only) {
    // A preview is advisory UI, not a provider checkpoint. It cannot end the
    // conversion barrier, consume queued input, or take over registration.
    if (provider_pending_.load(std::memory_order_acquire) && provider_conversion_active_ &&
        active_context_ && result->state) {
      TracePhase(L"provider-preview-ui-start", result->key_sequence, L"pump");
      UpdateCandidateUI(active_context_, *result->state);
      TracePhase(L"provider-preview-ui-end", result->key_sequence, L"pump");
    }
    return;
  }
  provider_pending_.store(false, std::memory_order_release);
  provider_deadline_ = 0;
  if (provider_window_) KillTimer(provider_window_, 1);
  if (okuri_handoff_active_ && result->apply_state) {
    // Leading keys are already in the shadow; controls and following keys
    // remain queued in arrival order until the engine takes ownership.
    while (okuri_mirrored_keys_ && !deferred_provider_keys_.empty()) {
      deferred_provider_keys_.pop_front();
      --okuri_mirrored_keys_;
    }
    auto keys = realtime_frontend_.raw_keys();
    if (realtime_frontend_.katakana()) keys.insert(keys.begin(), U'q');
    if (result->state && okuri_handoff_keys_ != realtime_frontend_.raw_keys()) {
      if (BeginProviderKeys(keys, true)) return;
    } else if (!result->state && !local_enabled_) {
      okuri_handoff_retry_ = true;
      const auto local = realtime_frontend_.RestorePreedit();
      // A complete okuri uses the existing conversion barrier; incomplete
      // n/sokuon prefixes retry sync without synthesizing a Space.
      const bool complete = local.pending_romaji.empty() &&
          !local.text.empty() && local.text.back() != L'*';
      const bool started = complete
          ? BeginProviderConversion(keys) : BeginProviderKeys(keys, true);
      if (started) return;
    } else if (result->state) {
      okuri_handoff_active_ = false;
      okuri_handoff_failed_ = false;
    }
    if (okuri_handoff_active_) {
      if (local_enabled_) { ResolveLocalFallback(); return; }
      // Failure to schedule keeps the reading and every semantic key.
      // Never let Enter commit markers or raw romaji.
      okuri_handoff_active_ = false;
      okuri_handoff_failed_ = true;
      engine_roundtrip_failed_ = true;
      RenderLocalOkuri(active_context_);
      return;
    }
  }
  if (!result->apply_state) {
    provider_cleanup_pending_ = false;
    engine_roundtrip_failed_ = !result->state;
    ReplayDeferredProviderKeys();
    return;
  }
  if (!result->state) {
    engine_roundtrip_failed_ = true;
    CloseCandidateUi();
    if (confirmation_pending_) {
      // No edit session owns this failed commit; do not leave all input
      // behind a confirmation that can never call ConfirmationFinished.
      ReleaseFailedConfirmation();
      ReplayDeferredProviderKeys();
      return;
    }
    if (result->settings_pending) {
      RetainProviderConversion();
      return;
    }
    if (local_enabled_) ResolveLocalFallback();
    return;
  }
  provider_conversion_active_ = false;

  ObserveRegistrationLearning(*result->state, result->registration_learning);
  // Also retain intermediate queued cycling replies: the next control must
  // recover from the latest engine selection even before it is rendered.
  provider_candidate_state_ = result->state->mode == L"candidate"
      ? result->state : std::optional<ddskk::EngineState>{};

  // Resolve queued keys against the provider state in strict arrival order.
  // Candidate controls belong to that candidate; a printable key first
  // accepts it and remains queued so it can start the next native episode.
  if (!deferred_provider_keys_.empty() &&
      ddskk::IsDocumentCandidate(*result->state)) {
    const DeferredProviderKey& key = deferred_provider_keys_.front();
    std::optional<ddskk::EngineControl> control;
    bool consume = true;
    if (ddskk::IsQuitKey(key.virtual_key, key.control))
      control = ddskk::EngineControl::kQuit;
    else if (key.virtual_key == VK_RETURN)
      control = ddskk::EngineControl::kCommit;
    else if (key.virtual_key == VK_SPACE)
      control = ddskk::EngineControl::kConvert;
    else if (key.virtual_key == VK_BACK)
      control = ddskk::EngineControl::kBackspace;
    else if (key.ctrl_j)
      control = ddskk::EngineControl::kCancel;
    else if (key.virtual_key == VK_LEFT)
      control = engine_id_ == "lattice"
          ? (key.shift ? ddskk::EngineControl::kSegmentShrink
                       : ddskk::EngineControl::kSegmentPrev)
          : ddskk::EngineControl::kPrevious;
    else if (key.virtual_key == VK_RIGHT)
      control = engine_id_ == "lattice"
          ? (key.shift ? ddskk::EngineControl::kSegmentExtend
                       : ddskk::EngineControl::kSegmentNext)
          : ddskk::EngineControl::kConvert;
    else if (key.virtual_key >= VK_F6 && key.virtual_key <= VK_F10) {
      constexpr ddskk::EngineControl controls[] = {
          ddskk::EngineControl::kToHiragana,
          ddskk::EngineControl::kToKatakana,
          ddskk::EngineControl::kToHalfKatakana,
          ddskk::EngineControl::kToWideLatin,
          ddskk::EngineControl::kToLatin};
      control = controls[key.virtual_key - VK_F6];
    } else {
      control = ddskk::EngineControl::kCommit;
      consume = false;
    }
    if (consume) deferred_provider_keys_.pop_front();
    if (control && BeginProviderControl(*control)) {
      if (!consume || *control == ddskk::EngineControl::kCommit) confirmation_pending_ = true;
      return;
    }
  }

  // Preserve raw keys across candidate/registration states. They provide
  // the immediate local candidate -> reading cancellation path.
  if (result->state->mode != L"candidate" &&
      result->state->mode != L"registration" &&
      result->state->composition_start < 0) {
    local_okuri_snapshot_ = {};
  realtime_frontend_.Reset();
    realtime_frontend_.AdoptMode(*result->state);
  }
  engine_roundtrip_failed_ = false;
  const bool was_registration = registration_mode_;
  registration_mode_ = result->state->mode == L"registration";
  registration_commit_pending_ =
      was_registration && !registration_mode_ &&
      result->state->composition_start < 0 &&
      result->state->pending_romaji.empty();
  if (was_registration && !registration_mode_ &&
      !registration_commit_pending_ && registration_range_ != nullptr) {
    registration_range_->Release();
    registration_range_ = nullptr;
  }
  provider_composition_active_ = !registration_mode_ &&
      result->state->composition_start >= 0;
  if (local_enabled_ && provider_composition_active_ && result->state->mode == L"preedit" &&
      realtime_frontend_.preedit() && !realtime_frontend_.okuri_started()) {
    const auto index = local_store_.Current();
    if (index && realtime_frontend_.TrySetRulesForReading(index->ParsedRules())) {
      local_rule_snapshot_ = index->Base() ? index->Base() : index;
      local_rule_generation_ = local_rule_snapshot_->header().generation;
      auto_pair_.SetRules(local_rule_snapshot_->ParsedRules());
    }
    const auto native = realtime_frontend_.RestorePreedit();
    if (index && local_rule_snapshot_ && index->Rules() == local_rule_snapshot_->Rules() &&
        result->state->text == native.text && result->state->pending_romaji == native.pending_romaji) {
      // A provider quit/restoration may leave a reading the native frontend
      // already owns exactly. Return typing to it instead of serializing
      // each following letter through the provider transaction queue.
      provider_composition_active_ = false;
      engine_.MarkNeedsResync();
      DebugLog(L"LOCAL_RECLAIM seq=%llu mode=preedit", key_sequence_);
    }
  }
  engine_pending_ = registration_mode_ || result->state->composition_start >= 0 ||
                    !result->state->pending_romaji.empty();
  kana_mode_ = ddskk::DeriveKanaMode(*result->state);
  if (!registration_mode_) last_engine_mode_ = result->state->mode;
  if (registration_mode_) {
    last_engine_mode_ = result->state->mode;
    QueuePublishedState(&*result->state);
    TracePhase(L"registration-inline-start", result->key_sequence, L"pump");
    if (inline_epoch_ && inline_channel_.Publish(inline_epoch_,
          result->state->text + result->state->pending_romaji, InlineCursor(*result->state)))
      inline_state_ = *result->state;
    TracePhase(L"registration-inline-end", result->key_sequence, L"pump");
    CloseCandidateUi();
    if (!was_registration && registration_range_ == nullptr &&
        composition_ != nullptr) {
      composition_->GetRange(&registration_range_);
    }
    // Replay through registration routing, including every semantic control.
    // Never run document candidate confirmation on this editor's candidates.
    ReplayDeferredProviderKeys();
    return;
  }
  if (active_context_ == nullptr) return;
  auto* edit_session =
      new (std::nothrow) StateEditSession(this, active_context_, *result->state, L"engine", result->key_sequence,
          confirmation_pending_ && result->state->composition_start < 0 && result->state->pending_romaji.empty());
  if (edit_session == nullptr) return;
  HRESULT edit_result = E_FAIL;
  const HRESULT request = RequestEdit(active_context_, edit_session, &edit_result, L"engine", result->key_sequence);
  edit_session->Release();
  MaybeShowModeIndicator(active_context_, &*result->state);
  // Preserve the ownership decision above through synchronous or delayed
  // edit execution, including a certified reading reclaimed by the frontend.
  if (SUCCEEDED(request) && SUCCEEDED(edit_result)) {
    if (result->state->mode == L"candidate") TraceOkuriCandidate(false);
    ReplayDeferredProviderKeys();
  } else if (confirmation_pending_) {
    ConfirmationFinished(active_context_, EditGeneration(), FAILED(request) ? request : edit_result, nullptr);
    return;
  } else if (local_enabled_) {
    ResolveLocalFallback();
    return;
  }
  if (result->state->mode == L"candidate" && provider_conversion_started_ &&
      GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", nullptr, 0)) {
    std::printf("SPACE-CANDIDATE ms=%llu seq=%llu\n",
        GetTickCount64() - provider_conversion_started_,
        static_cast<unsigned long long>(result->sequence));
    provider_conversion_started_ = 0;
    std::fflush(stdout);
  }
}

void TextService::ReplayDeferredProviderKeys() {
  if (confirmation_pending_ || confirmation_replay_) { ScheduleConfirmationReplay(); return; }
  while (!deferred_provider_keys_.empty() && active_context_ != nullptr &&
         !provider_pending_.load(std::memory_order_acquire) && !provider_conversion_retry_) {
    const DeferredProviderKey key = deferred_provider_keys_.front();
    deferred_provider_keys_.pop_front();
    if (registration_mode_ ||
        (key.has_codepoint && key.codepoint == U'l' && !key.control && !key.ctrl_j) ||
        (local_enabled_ && kana_mode_ && !provider_composition_active_)) {
      // A late index must use the same local barriers as fresh typing. The
      // old replay loop sent every subsequent SPACE back to the provider,
      // even after the mapped index became available.
      BYTE saved[256]{}, keyboard[256]{};
      GetKeyboardState(saved);
      if (key.shift) keyboard[VK_SHIFT] = 0x80;
      if (key.ctrl_j || key.control) keyboard[VK_CONTROL] = 0x80;
      if (key.caps) keyboard[VK_CAPITAL] = 1;
      SetKeyboardState(keyboard);
      BOOL eaten = FALSE;
      const auto scan = MapVirtualKeyW(static_cast<UINT>(key.virtual_key), MAPVK_VK_TO_VSC);
      tested_key_valid_ = false;
      const auto saved_replay = replay_codepoint_;
      const bool saved_latin_switch = replaying_latin_switch_;
      replay_codepoint_ = key.has_codepoint ? std::optional<char32_t>(key.codepoint) : std::nullopt;
      replaying_latin_switch_ = key.latin_switch;
      const bool saved_registration_dispatch = dispatching_registration_key_;
      dispatching_registration_key_ = registration_mode_;
      OnKeyDown(active_context_, key.virtual_key, (static_cast<LPARAM>(scan) << 16) | 1, &eaten);
      const bool registration_retry = dispatching_registration_key_ &&
          !provider_pending_.load(std::memory_order_acquire);
      dispatching_registration_key_ = saved_registration_dispatch;
      replay_codepoint_ = saved_replay;
      replaying_latin_switch_ = saved_latin_switch;
      SetKeyboardState(saved);
      if (registration_retry) return; // Retry timer, never spin on worker-launch failure.
      if (confirmation_pending_ || confirmation_replay_ || confirmation_delivery_pending_) {
        ScheduleConfirmationReplay(); return;
      }
      continue;
    }
    std::optional<ddskk::EngineState> state;
    if (provider_composition_active_) {
      if (key.has_codepoint) {
        if (engine_id_ == "ddskk" && last_engine_mode_ == L"preedit" &&
            realtime_frontend_.okuri_started()) {
          realtime_frontend_.Feed(key.codepoint);
          RenderLocalOkuri(active_context_);
        }
        // Resolving an okuri prefix can perform a dictionary lookup.
        const bool started = BeginProviderKey(key.codepoint,
            engine_id_ == "ddskk" && last_engine_mode_ == L"preedit");
        if (started) return;
      }
      std::optional<ddskk::EngineControl> control;
      if (key.virtual_key == VK_RETURN) control = ddskk::EngineControl::kCommit;
      else if (key.virtual_key == VK_SPACE) control = ddskk::EngineControl::kConvert;
      else if (key.virtual_key == VK_BACK) {
        if (last_engine_mode_ == L"preedit" && realtime_frontend_.okuri_started())
          realtime_frontend_.BackspaceOkuri();
        control = ddskk::EngineControl::kBackspace;
      }
      else if (key.ctrl_j) control = ddskk::EngineControl::kCancel;
      else if (ddskk::IsQuitKey(key.virtual_key, key.control)) control = ddskk::EngineControl::kQuit;
      if (control && BeginProviderControl(*control)) return;
      continue;
    }
    if (key.virtual_key == VK_SPACE && realtime_frontend_.preedit()) {
      if (BeginProviderConversion(realtime_frontend_.raw_keys())) {
        ShowProviderBusy(active_context_);
        return;
      }
    } else if (key.virtual_key == VK_RETURN) {
      state = realtime_frontend_.Commit();
    } else if (key.virtual_key == VK_BACK) {
      state = realtime_frontend_.Backspace();
    } else if (key.ctrl_j) {
      state = realtime_frontend_.Commit();
      const auto hiragana = realtime_frontend_.ToHiragana();
      if (state) state->mode = L"hiragana";
      else state = hiragana;
    } else if (ddskk::IsQuitKey(key.virtual_key, key.control)) {
      state = realtime_frontend_.Quit();
    } else if (key.virtual_key >= VK_F6 && key.virtual_key <= VK_F10 &&
               realtime_frontend_.preedit()) {
      // Lattice transliteration operates on converted segments.  Put the
      // F-key back behind an atomic conversion barrier; the next provider
      // result will dispatch it as a candidate control above.
      deferred_provider_keys_.push_front(key);
      if (BeginProviderConversion(realtime_frontend_.raw_keys())) {
        ShowProviderBusy(active_context_);
        return;
      }
      deferred_provider_keys_.pop_front();
    } else if (key.has_codepoint) {
      // q is now at the front: the remaining queue contains following keys,
      // not part of its reading. Commit once and preserve those following keys.
      if (engine_id_ == "ddskk" && key.codepoint == U'q' &&
          CommitNativeKatakana(active_context_, true)) continue;
      if (engine_id_ == "ddskk" && realtime_frontend_.preedit() &&
          (key.codepoint == U'q' || key.codepoint == U'Q' ||
           key.codepoint == U'l' || key.codepoint == U'L' ||
           key.codepoint == U'/')) {
        auto keys = realtime_frontend_.raw_keys();
        if (realtime_frontend_.katakana()) keys.insert(keys.begin(), U'q');
        keys.push_back(key.codepoint);
        if (BeginProviderKeys(keys, true)) return;
      }
      state = realtime_frontend_.Feed(key.codepoint);
      if (engine_id_ == "ddskk" && realtime_frontend_.okuri_started()) {
        RenderLocalOkuri(active_context_);
        auto keys = realtime_frontend_.raw_keys();
        if (realtime_frontend_.katakana()) keys.insert(keys.begin(), U'q');
        if (BeginProviderKeys(keys, true)) return;
      }
    }
    if (!state) {
      if (engine_id_ == "ddskk" && !realtime_frontend_.latin() &&
          key.has_codepoint && BeginProviderKeys(realtime_frontend_.raw_keys(), true)) return;
      continue;
    }

    engine_pending_ = state->composition_start >= 0 ||
                      !state->pending_romaji.empty();
    kana_mode_ = ddskk::DeriveKanaMode(*state);
    last_engine_mode_ = state->mode;
    auto* edit_session =
        new (std::nothrow) StateEditSession(this, active_context_, *state);
    if (edit_session == nullptr) return;
    HRESULT edit_result = E_FAIL;
    const HRESULT request = RequestEdit(active_context_, edit_session, &edit_result);
    edit_session->Release();
    if (FAILED(request) || FAILED(edit_result)) return;
  }
}

void TextService::ScheduleConfirmationReplay() {
  SettleIdleProviderState();
  if (!confirmation_pending_ && !confirmation_replay_) FollowSettings();
  if (confirmation_replay_ && !confirmation_pending_ && !pending_state_edits_ &&
      !provider_pending_.load() && provider_window_ && !confirmation_resume_posted_) {
    confirmation_resume_posted_ = true;
    const auto sequence = ++confirmation_dispatch_sequence_;
    if (!PostMessageW(provider_window_, kConfirmationReplayMessage, 0, static_cast<LPARAM>(sequence)))
      confirmation_resume_posted_ = false;
  }
}

void TextService::ConfirmationFinished(ITfContext* context, uint64_t generation,
                                      HRESULT result, ITfRange* end) {
  if (!StateEditAllowed(context, generation)) return;
  if (FAILED(result)) {
    // Retry only refusals that precede document mutation. A failed EndComposition
    // may already have delivered a result and must never be replayed blindly.
    if (provider_window_ && (result == TF_E_LOCKED || result == TF_E_SYNCHRONOUS ||
        result == TS_E_READONLY || result == E_ACCESSDENIED))
      SetTimer(provider_window_, 7, 50, nullptr);
    else ReleaseFailedConfirmation(); // No retry owns a fatal edit refusal.
    return;
  }
  confirmation_state_.reset();
  if (provider_window_) KillTimer(provider_window_, 7);
  confirmation_pending_ = false;
  confirmation_replay_ = true;
  confirmation_delivery_pending_ = true;
  if (confirmation_anchor_) confirmation_anchor_->Release();
  confirmation_anchor_ = end;
  if (end) end->AddRef();
  // The continuation is posted when TSF releases the commit session.
}

void TextService::RetryConfirmation() {
  if (!confirmation_state_ || !active_context_ || pending_state_edits_ || provider_pending_.load()) return;
  const auto state = *confirmation_state_;
  if (provider_window_) KillTimer(provider_window_, 7);
  // A refused synchronous local request restored its selected candidate. An
  // accepted asynchronous commit already queued learning, so retry only its
  // retained document state in that case, never learning or consuming keys twice.
  if (local_conversion_.active()) CommitLocal(active_context_, true);
  else ApplyLocalState(active_context_, state, true);
}

void TextService::ResumeConfirmedKeys() {
  if (!confirmation_replay_ || confirmation_pending_ || pending_state_edits_ ||
      provider_pending_.load() || !active_context_) return;
  if (deferred_provider_keys_.empty()) {
    confirmation_replay_ = false;
    if (confirmation_anchor_) confirmation_anchor_->Release();
    confirmation_anchor_ = nullptr;
    return;
  }
  const auto key = deferred_provider_keys_.front();
  deferred_provider_keys_.pop_front();
  BYTE saved[256]{}, keyboard[256]{};
  GetKeyboardState(saved);
  if (key.shift) keyboard[VK_SHIFT] = 0x80;
  if (key.ctrl_j || key.control) keyboard[VK_CONTROL] = 0x80;
  if (key.caps) keyboard[VK_CAPITAL] = 1;
  if (key.has_codepoint && ((key.codepoint >= U'a' && key.codepoint <= U'z') ||
      (key.codepoint >= U'A' && key.codepoint <= U'Z')))
    keyboard[VK_CAPITAL] = ((key.codepoint >= U'A' && key.codepoint <= U'Z') != key.shift) ? 1 : 0;
  SetKeyboardState(keyboard);
  const auto saved_replay = replay_codepoint_;
  const bool saved_latin_switch = replaying_latin_switch_;
  replay_codepoint_ = key.has_codepoint ? std::optional<char32_t>(key.codepoint) : std::nullopt;
  replaying_latin_switch_ = key.latin_switch;
  replaying_confirmation_ = true;
  BOOL eaten = FALSE;
  const auto scan = MapVirtualKeyW(static_cast<UINT>(key.virtual_key), MAPVK_VK_TO_VSC);
  OnKeyDown(active_context_, key.virtual_key, (static_cast<LPARAM>(scan) << 16) | 1, &eaten);
  if (!eaten && key.has_codepoint) {
    // A queued mode command may have switched to Latin before this key. The
    // original key was already eaten, so deliver its printable text explicitly.
    ddskk::EngineState literal;
    literal.mode = last_engine_mode_;
    if (key.codepoint <= 0xffff) literal.text.assign(1, static_cast<wchar_t>(key.codepoint));
    else {
      literal.text.push_back(static_cast<wchar_t>(0xd800 + ((key.codepoint - 0x10000) >> 10)));
      literal.text.push_back(static_cast<wchar_t>(0xdc00 + ((key.codepoint - 0x10000) & 0x3ff)));
    }
    ApplyLocalState(active_context_, literal);
  }
  replaying_confirmation_ = false;
  replay_codepoint_ = saved_replay;
  replaying_latin_switch_ = saved_latin_switch;
  SetKeyboardState(saved);
  // One key per message; a deferred edit retains the barrier until release.
  ScheduleConfirmationReplay();
}

void TextService::ShowProviderBusy(ITfContext* context) {
  if (context == nullptr || local_conversion_.active()) return;
  ddskk::EngineState busy;
  busy.mode = L"provider-busy";
  busy.candidate_index = 0;
  busy.candidates = {L"変換中…"};
  UpdateCandidateUI(context, busy);
}

void TextService::RenderLocalOkuri(ITfContext* context) {
  if (!context) return;
  const auto state = realtime_frontend_.RestorePreedit();
  engine_pending_ = true;
  last_engine_mode_ = L"preedit";
  auto* edit = new (std::nothrow) StateEditSession(this, context, state);
  if (!edit) return;
  HRESULT result = E_FAIL;
  RequestEdit(context, edit, &result);
  edit->Release();
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
  } else if (iid == IID_ITfCompartmentEventSink) {
    *object = static_cast<ITfCompartmentEventSink*>(this);
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
  if (!CreateProviderWindow()) {
    const DWORD error = GetLastError();
    DebugLog(L"Activate provider-window failed error=%u", error);
    return error ? HRESULT_FROM_WIN32(error) : E_FAIL;
  }
  EnsureEngineHost();
  LoadSettings();
  publication_active_ = true;
  settings_watcher_.Start();
  // Pay the watcher's initial race-covering settings refresh at activation,
  // rather than adding registry and palette work to the first ordinary key.
  FollowSettings();
  // The engine's cold load was measured at 3.4 s. Pay that cost here, on a
  // detached background thread at activation, instead of on the user's
  // first keystroke -- that removes the first-key freeze. This thread
  // constructs its own EngineClient and never touches engine_, which is
  // UI-thread-only.
  // Read-only warm-up: a captured selection could arrive after a registry
  // switch and switch the shared host back to a stale engine.
  // The warm-up owns a module lease, not a service reference. Keeping a
  // service alive here could run its window destructor on this worker.
  InterlockedIncrement(&g_object_count);
  try {
    fallback_rules_ = std::make_shared<std::atomic<std::shared_ptr<const RuleExport>>>();
    // Keep refreshing after ENGINE RELOAD without putting pipe I/O on the
    // key thread. A weak holder ends the module-leased worker on deactivation.
    std::thread([holder = std::weak_ptr(fallback_rules_)] {
      struct WarmupLease {
        ~WarmupLease() { InterlockedDecrement(&g_object_count); }
      } lease;
      try {
        ddskk::EngineClient warm_up_client;
        while (auto rules = holder.lock()) {
          if (warm_up_client.Connect(2000)) {
            warm_up_client.CurrentEngine(1000);
            if (auto exported = warm_up_client.RomajiRules(1000)) {
              const auto previous = rules->load();
              if (!previous || *previous != *exported)
                rules->store(std::make_shared<const RuleExport>(std::move(*exported)));
            }
          }
          rules.reset();
          Sleep(250);
        }
      } catch (...) { /* Warm-up is optional; key requests report failures. */ }
    }).detach();
  } catch (...) { InterlockedDecrement(&g_object_count); }

  if (shim_.query_service) {
    keyboard_open_ = ReadKeyboardOpen(true);
    QueuePublishedState(nullptr);
    engine_.MarkNeedsResync();
    return S_OK;
  }
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
  const HRESULT open_close = AdviseOpenCloseCompartment();
  QueuePublishedState(nullptr);
  DebugLog(L"Activate open-close=%X open=%d",
           static_cast<unsigned>(open_close), keyboard_open_ ? 1 : 0);
  // The langbar settings button is cosmetic. Hosts without a language bar
  // (console TSF hosts, some sandboxed apps) fail AddItem, and returning
  // that failure here made TSF deactivate the whole text service -- no key
  // sink, IME silently dead. Log and carry on instead.
  const HRESULT langbar = AddLangBarButton();
  DebugLog(L"Activate langbar=%X", static_cast<unsigned>(langbar));
  // Every TextService instance shares one out-of-process DDSKK session.
  // Its first actual input must establish ownership instead of inheriting
  // whatever a previously focused application left in that session.
  engine_.MarkNeedsResync();
  return S_OK;
}

HRESULT TextService::Deactivate() {
  confirmation_pending_ = confirmation_replay_ = false;
  confirmation_delivery_pending_ = false;
  if (confirmation_anchor_) confirmation_anchor_->Release();
  confirmation_anchor_ = nullptr;
  fallback_rules_.reset();
  fallback_rule_snapshot_.reset();
  FlushDebugLog();
  CancelLocalRetry();
  local_observer_retry_.reset();
  local_store_.ReleaseState();
  local_store_.Stop();
  local_conversion_.Reset();
  ClearInlineEpisode();
  inline_channel_.Stop();
  RemovePublishedState();
  settings_watcher_.Stop();
  CancelPendingProvider();
  RemoveLangBarButton();
  UnadviseOpenCloseCompartment();
  if (engine_pending_ || registration_mode_ || composition_ != nullptr) {
    ResetAbandonedComposition();
  }
  {
    // A provider worker may still be finishing a cancelled lookup. Do not
    // close its pipe underneath it; this wait is confined to deactivation,
    // never to the keystroke path.
    provider_settings_.store(nullptr);
    std::lock_guard<std::mutex> lock(provider_engine_mutex_);
    engine_.Disconnect();
  }
  if (active_context_ != nullptr) {
    active_context_->Release();
    active_context_ = nullptr;
  }
  CloseCandidateUi();
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
        TF_LBI_STYLE_BTN_MENU | TF_LBI_STYLE_SHOWNINTRAY,
        L"NeLisp IME", LangBarButton::Kind::kSettings);
    settings_result = settings_button_ == nullptr
        ? E_OUTOFMEMORY : manager->AddItem(settings_button_);
    DebugLog(L"LangBar AddItem logo=%X", static_cast<unsigned>(settings_result));
    if (FAILED(settings_result) && settings_button_ != nullptr) {
      settings_button_->Release();
      settings_button_ = nullptr;
    }
  }

  HRESULT input_mode_result = S_OK;
  if (input_mode_button_ == nullptr) {
    // GUID_LBI_INPUTMODE is the well-known item Windows 10/11's taskbar
    // "A/あ" indicator renders. Both this and the separate custom-GUID
    // DDSKK logo item use TF_LBI_STYLE_SHOWNINTRAY, following CorvusSKK's
    // two-item layout, so the logo does not replace the current mode.
    // This style makes an item eligible for the taskbar rather than only
    // the floating language bar
    // (also needs the two GUID_TFCAT_TIPCAP_* categories -- see
    // dllmain.cpp's RegisterCategories() and
    // windows/tools/register-categories.cpp).
    input_mode_button_ = new (std::nothrow) LangBarButton(
        this, GUID_LBI_INPUTMODE,
        TF_LBI_STYLE_BTN_BUTTON | TF_LBI_STYLE_SHOWNINTRAY,
        L"NeLisp IME input mode", LangBarButton::Kind::kInputMode);
    input_mode_result = input_mode_button_ == nullptr
        ? E_OUTOFMEMORY : manager->AddItem(input_mode_button_);
    DebugLog(L"LangBar AddItem mode=%X", static_cast<unsigned>(input_mode_result));
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
      if (!shim_.query_service) keystroke_manager->UnadviseKeyEventSink(client_id_);
      keystroke_manager->Release();
    }
    thread_manager_->Release();
    thread_manager_ = nullptr;
  }
  client_id_ = TF_CLIENTID_NULL;
}

bool TextService::ReadKeyboardOpen(bool fallback) const {
  if (thread_manager_ == nullptr) return fallback;
  ITfCompartmentMgr* manager = nullptr;
  ITfCompartment* compartment = nullptr;
  VARIANT value;
  VariantInit(&value);
  bool open = fallback;
  if (SUCCEEDED(thread_manager_->QueryInterface(
          IID_ITfCompartmentMgr, reinterpret_cast<void**>(&manager))) &&
      SUCCEEDED(manager->GetCompartment(GUID_COMPARTMENT_KEYBOARD_OPENCLOSE,
                                       &compartment)) &&
      SUCCEEDED(compartment->GetValue(&value)) && value.vt == VT_I4) {
    open = value.lVal != 0;
  }
  VariantClear(&value);
  if (compartment != nullptr) compartment->Release();
  if (manager != nullptr) manager->Release();
  return open;
}

HRESULT TextService::AdviseOpenCloseCompartment() {
  if (thread_manager_ == nullptr) return E_UNEXPECTED;
  UnadviseOpenCloseCompartment();
  ITfCompartmentMgr* manager = nullptr;
  ITfCompartment* compartment = nullptr;
  ITfSource* source = nullptr;
  HRESULT result = thread_manager_->QueryInterface(
      IID_ITfCompartmentMgr, reinterpret_cast<void**>(&manager));
  if (SUCCEEDED(result)) {
    result = manager->GetCompartment(GUID_COMPARTMENT_KEYBOARD_OPENCLOSE,
                                     &compartment);
  }
  if (SUCCEEDED(result)) {
    result = compartment->QueryInterface(IID_ITfSource,
                                         reinterpret_cast<void**>(&source));
  }
  if (SUCCEEDED(result)) {
    result = source->AdviseSink(
        IID_ITfCompartmentEventSink,
        static_cast<ITfCompartmentEventSink*>(this), &open_close_cookie_);
  }
  if (source != nullptr) source->Release();
  if (compartment != nullptr) compartment->Release();
  if (manager != nullptr) manager->Release();
  keyboard_open_ = ReadKeyboardOpen(true);
  return result;
}

void TextService::UnadviseOpenCloseCompartment() {
  if (open_close_cookie_ == TF_INVALID_COOKIE || thread_manager_ == nullptr) {
    open_close_cookie_ = TF_INVALID_COOKIE;
    return;
  }
  ITfCompartmentMgr* manager = nullptr;
  ITfCompartment* compartment = nullptr;
  ITfSource* source = nullptr;
  if (SUCCEEDED(thread_manager_->QueryInterface(
          IID_ITfCompartmentMgr, reinterpret_cast<void**>(&manager))) &&
      SUCCEEDED(manager->GetCompartment(GUID_COMPARTMENT_KEYBOARD_OPENCLOSE,
                                       &compartment)) &&
      SUCCEEDED(compartment->QueryInterface(IID_ITfSource,
                                            reinterpret_cast<void**>(&source)))) {
    source->UnadviseSink(open_close_cookie_);
  }
  if (source != nullptr) source->Release();
  if (compartment != nullptr) compartment->Release();
  if (manager != nullptr) manager->Release();
  open_close_cookie_ = TF_INVALID_COOKIE;
}

HRESULT TextService::OnChange(REFGUID guid) {
  if (IsEqualGUID(guid, GUID_COMPARTMENT_KEYBOARD_OPENCLOSE)) {
    ApplyKeyboardOpenChange();
  }
  return S_OK;
}

void TextService::ApplyKeyboardOpenChange() {
  if (publish_state_ || application_open_mode_ != L"restore") FollowSettings();
  const bool open = ReadKeyboardOpen(keyboard_open_);
  if (open == keyboard_open_) return;
  if (!open) {
    mode_before_close_kana_ = kana_mode_;
    engine_mode_before_close_ = last_engine_mode_;
  }
  keyboard_open_ = open;

  // Closing an IME while text is composing must also remove that transient
  // text from the document.  An idle close deliberately does not reset the
  // shared engine session: this compartment is per TSF thread/application.
  if (!open && local_enabled_) {
    ForceCancelComposition(active_context_);
    local_conversion_.Reset();
    local_okuri_snapshot_ = {};
  realtime_frontend_.Reset();
  } else if (!open &&
      (engine_pending_ || registration_mode_ || composition_ != nullptr)) {
    const auto state = engine_.Reset(kInteractiveTimeoutMs);
    CloseCandidateUi();
    if (registration_range_ != nullptr) {
      registration_range_->Release();
      registration_range_ = nullptr;
    }
    registration_commit_pending_ = false;
    registration_mode_ = false;
    engine_pending_ = false;
    provider_composition_active_ = false;
    deferred_provider_keys_.clear();
    if (state && active_context_ != nullptr) {
      auto* edit_session =
          new (std::nothrow) StateEditSession(this, active_context_, *state);
      if (edit_session != nullptr) {
        HRESULT edit_result = E_FAIL;
        active_context_->RequestEditSession(
            client_id_, edit_session, TF_ES_ASYNC | TF_ES_READWRITE,
            &edit_result);
        edit_session->Release();
      }
    } else if (composition_ != nullptr) {
      composition_->Release();
      composition_ = nullptr;
    }
  } else if (open) {
    kana_mode_ = mode_before_close_kana_;
    last_engine_mode_ = engine_mode_before_close_;
    if (application_open_mode_ != L"restore" && ddskk_engine_) {
      // The native frontend is authoritative for ordinary keys. Reset both
      // checkpoints at this explicit application boundary, never in a key callback.
      CancelPendingProvider();
      if (!local_enabled_) {
      std::lock_guard<std::mutex> lock(provider_engine_mutex_);
      engine_.MarkNeedsResync();
      auto state = engine_.SendControl(ddskk::EngineControl::kCancel, 1000);
      realtime_frontend_.SetInputMode(application_open_mode_);
      if (application_open_mode_ == L"latin") {
        state = engine_.SendKey(U'l', 1000);
      } else if (application_open_mode_ == L"katakana") {
        state = engine_.SendKey(U'q', 1000);
      }
      } else {
        realtime_frontend_.SetInputMode(application_open_mode_);
      }
      kana_mode_ = application_open_mode_ != L"latin";
      last_engine_mode_ = application_open_mode_;
    }
  }
  if (!open) published_composing_ = 0;
  if (open) ApplyRequestedInlineMode();
  MaybeShowModeIndicator(nullptr, nullptr);
}

HRESULT TextService::OnSetFocus(BOOL foreground) {
  FollowSettings();
  (void)foreground;
  // Thread-focus notifications are not document-ownership boundaries.
  // Edge/Electron and even TSF UI surfaces can briefly report FALSE while
  // the same editor composition remains active; scheduling RESET here made
  // the very next Enter turn `▼変換' into an empty state.  Real ownership
  // changes are handled by the active ITfContext comparison in OnKeyDown,
  // and actual composition termination by OnCompositionTerminated.
  return S_OK;
}

// The full "would this key be part of the claimed set" predicate,
// factored out of OnTestKeyDown so OnKeyDown's own direct-call fallback
// (its final `else' branch, when TranslateKey() can't resolve a
// character) can ask the identical question instead of assuming every
// such VK was actually claimed -- see that call site's comment for the
// field bug (dead arrow keys) this exists to fix. Assumes the caller has
// already established ddskk_engine_ && kana_mode_ (this does not re-check
// either); `composing' must be `composition_ != nullptr ||
// engine_pending_', computed identically at every call site.
//
// wparam here is a VK code, not an ASCII/character code: the old
// `wparam >= 0x20 && wparam <= 0x7e' range this replaced claimed far more
// than printable keys -- VK_PRIOR/VK_NEXT/VK_END/VK_HOME/arrows/
// VK_INSERT/VK_DELETE (0x21-0x2E), VK_LWIN/VK_RWIN/VK_APPS (0x5B-0x5D),
// the numpad (0x60-0x6F) and F1..F15 (0x70-0x7E) all fall inside it.
// Navigation keys, F-keys, numpad and Win keys must fall through to the
// application; an idle space must insert a plain space (the engine's
// KEY 32 path errors and CorvusSKK passes it through too).
//
// Ctrl+G is checked first and separately from the generic letters range
// below, because 'G' alone (without Ctrl) already falls inside
// `wparam >= 'A' && wparam <= 'Z'' -- without this, Ctrl+G would be
// claimed exactly like a bare "G" keystroke regardless of composing
// state. Ctrl+J is NOT handled here: it has its own always-claimed
// branch in both OnTestKeyDown and OnKeyDown, independent of composing.
bool TextService::WouldClaimKey(WPARAM wparam, bool composing, const BYTE* event_state) const {
  const bool control_down = tested_control_down_ || ControlDown();
  if (registration_mode_) {
    if (wparam == 'G' && control_down) return true;
    // The registration editor only owns Ctrl+G.  All other Ctrl chords
    // remain application/Windows commands (Ctrl+C, Ctrl+W, Ctrl+S, ...).
    if (control_down) return false;
    return (wparam >= 'A' && wparam <= 'Z') ||
           (wparam >= '0' && wparam <= '9') ||
           (wparam >= VK_OEM_1 && wparam <= VK_OEM_8) ||
           wparam == VK_OEM_102 || wparam == VK_SPACE ||
           wparam == VK_BACK || wparam == VK_DELETE ||
           wparam == VK_RETURN || wparam == VK_ESCAPE ||
           wparam == VK_LEFT || wparam == VK_RIGHT ||
           wparam == VK_UP || wparam == VK_DOWN ||
           wparam == VK_HOME || wparam == VK_END ||
           wparam == VK_F6 || wparam == VK_F7;
  }
  if (local_conversion_.active() && ((wparam == 'P' && control_down) ||
      (!control_down && (wparam == VK_UP || wparam == VK_DOWN || wparam == VK_PRIOR || wparam == VK_NEXT ||
                       wparam == VK_HOME || wparam == VK_END)))) return true;
  if (wparam == 'G' && control_down) return composing;
  // Ctrl+J is handled before this predicate by both key callbacks and
  // Ctrl+G was handled immediately above.  Never reinterpret any other
  // Ctrl shortcut as a kana letter.
  if (control_down) return false;
  if (event_state && ((event_state[VK_MENU] & 0x80) ||
      (event_state[VK_LWIN] & 0x80) || (event_state[VK_RWIN] & 0x80))) return false;
  return (wparam >= 'A' && wparam <= 'Z') ||             // letters
         // The engine now inserts 0..9 and Japanese-layout Shift+digit
         // symbols literally, including while a kana composition is open.
         (wparam >= '0' && wparam <= '9') ||
         (wparam >= VK_OEM_1 && wparam <= VK_OEM_3) ||    // 0xBA-0xC0 punctuation
         (wparam >= VK_OEM_4 && wparam <= VK_OEM_8) ||    // 0xDB-0xDF punctuation
         wparam == VK_OEM_102 ||                          // 0xE2 JIS backslash
         (wparam == VK_SPACE &&
          (composing || realtime_frontend_.wide_latin())) ||
         // Lattice owns segment navigation and all five standard
         // transliterations.  DDSKK has one conversion segment: map its
         // unshifted arrows to previous/next candidate and provide its
         // lossless kana-class conversions on F6/F7.  Do not claim keys
         // for an engine that cannot answer them.
         ((engine_id_ == "lattice") &&
          (wparam == VK_LEFT || wparam == VK_RIGHT ||
           (wparam >= VK_F6 && wparam <= VK_F10)) && composing) ||
         ((engine_id_ == "ddskk") &&
          (((wparam == VK_LEFT || wparam == VK_RIGHT) &&
            !(GetKeyState(VK_SHIFT) & 0x8000)) ||
           wparam == VK_F6 || wparam == VK_F7) && composing) ||
         ((wparam == VK_BACK || wparam == VK_RETURN ||
           wparam == VK_ESCAPE) && composing);
}

// Key ownership is native; provider availability is resolved asynchronously.
HRESULT TextService::OnTestKeyDown(ITfContext*, WPARAM wparam, LPARAM lparam,
                                   BOOL* eaten) {
  TracePhase(L"key-test-receipt", key_sequence_ + 1, registration_mode_ ? L"registration" : L"key");
  tested_virtual_key_ = wparam;
  tested_lparam_ = lparam;
  tested_keyboard_layout_ = GetKeyboardLayout(0);
  tested_key_valid_ = GetKeyboardState(tested_keyboard_state_) != FALSE;
  FollowSettings();
  if (eaten == nullptr) return E_POINTER;
  tested_control_down_ = ControlDown();
  // Logs (wparam, handled, connect result, final eaten) with -1 for
  // whichever of handled/connect was never evaluated on this exit path.
  const auto debug_exit = [&](int handled, int connect) {
    TracePhase(L"key-test-return", key_sequence_ + 1, registration_mode_ ? L"registration" : L"key");
    DebugLog(L"OnTestKeyDown vk=%02X handled=%d connect=%d eaten=%d",
             static_cast<unsigned>(wparam), handled, connect, *eaten);
  };
  const bool ctrl_j = wparam == 'J' && tested_control_down_;
  if (!ddskk_engine_ || !keyboard_open_) {
    *eaten = FALSE;
    debug_exit(-1, -1);
    return S_OK;
  }
  const bool realtime_claim = local_conversion_.active() || local_conversion_retry_ || (!provider_composition_active_ &&
      last_engine_mode_ != L"candidate" && !registration_mode_);
  if (ctrl_j && !registration_mode_ && realtime_claim) {
    *eaten = TRUE;
    debug_exit(-1, -1);
    return S_OK;
  }
  if (ctrl_j && !registration_mode_) {
    *eaten = TRUE;
    debug_exit(-1, -1);
    return S_OK;
  }
  if (!kana_mode_) {
    *eaten = FALSE;
    debug_exit(-1, -1);
    return S_OK;
  }
  // Backspace / Enter / Escape / Ctrl+G belong to the IME only while a
  // composition or a pending romaji prefix is actually in flight;
  // otherwise they must fall through to the application (matches
  // CorvusSKK's key ownership). See WouldClaimKey() for the full claim
  // predicate, shared with OnKeyDown's direct-call fallback.
  const bool composing = composition_ != nullptr || engine_pending_;
  if (!WouldClaimKey(wparam, composing, tested_key_valid_ ? tested_keyboard_state_ : nullptr)) {
    *eaten = FALSE;
    debug_exit(0, -1);
    return S_OK;
  }
  // Cancellation belongs to the current document even while its provider
  // owns the transaction mutex or the engine is unavailable. In particular,
  // registration Ctrl+G must not probe Connect on the TSF callback thread.
  // Registration already owns this key. Connect takes the transaction mutex,
  // so even its short timeout can wait behind an in-flight registration worker.
  if (registration_mode_ || realtime_claim || (wparam == 'G' && tested_control_down_) ||
      wparam == VK_ESCAPE) {
    *eaten = TRUE;
    debug_exit(1, -1);
    return S_OK;
  }
  // Claiming is native. The provider worker owns availability/reconnect;
  // probing here could wait behind a settings selection or a stale pipe.
  *eaten = TRUE;
  debug_exit(1, -1);
  return S_OK;
}

void TextService::SelectInputEngine(bool ddskk) {
  // Re-enabling returns to the configured engine, which is not necessarily
  // DDSKK now that the settings offer others.
  const std::string target = ddskk ? engine_id_ : std::string("passthrough");
  if (!engine_.SelectEngine(target, 1000)) return;
  const bool was_ddskk = ddskk_engine_;
  ddskk_engine_ = ddskk && engine_id_ != "passthrough";
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
    provider_composition_active_ = false;
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

void TextService::SelectEngineId(const std::string& id) {
  if (id != "ddskk" && id != "lattice" && id != "dictionary" && id != "passthrough") return;
  const std::wstring wide(id.begin(), id.end());
  HKEY key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, NativeImeRegistryKey().c_str(), 0,
      nullptr, 0, KEY_SET_VALUE, nullptr, &key, nullptr) == ERROR_SUCCESS) {
    if (RegSetValueExW(key, L"Engine", 0, REG_SZ,
        reinterpret_cast<const BYTE*>(wide.c_str()),
        static_cast<DWORD>((wide.size()+1)*sizeof(wchar_t))) == ERROR_SUCCESS)
      settings_watcher_.dirty.store(true);
    RegCloseKey(key);
    FollowSettings();
  }
}

void TextService::ReloadEngine() {
  // A separate connection keeps this immediate host command out of an
  // in-flight provider transaction on this service's session.
  ddskk::EngineClient control;
  control.ReloadEngine(100);
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
  if (!keyboard_open_) return L"--";
  return ModeIndicatorLabel(kana_mode_, last_engine_mode_);
}

ModeIndicatorPalette TextService::CurrentModePalette() const {
  // Reuses ModeIndicator's already-loaded registry overrides (see
  // LoadSettings()) rather than re-reading the registry here.
  return mode_indicator_.PaletteForLabel(CurrentModeLabel());
}

// Title of sumi-ui's settings window, used to find one that is already
// open. It must match `gtk_window_set_title' in
// sumi-ui/indicator/main.c's `open_settings_window' exactly; the two are
// checked against each other by
// sumi-ui/verify/verify-settings-window-title.ps1, because a silent
// mismatch here does not fail anything -- it just quietly goes back to
// spawning a second window every time.
static const wchar_t kSettingsWindowTitle[] = L"NeLisp IME 設定";

// GTK4 gives every toplevel this window class on Windows.  The lookup
// below needs it: FindWindowW with a null class does NOT match this
// window, even though its title is byte-identical to the string above
// (verified with EnumWindows -- 53-00-4B-00-4B-00-20-00-2D-8A-9A-5B on
// both sides).  Passing the class finds it immediately.  Discovered by
// running the lookup against a real settings window before shipping the
// change; a title-only FindWindowW would have compiled, deployed, and
// silently gone on spawning a second window every time.
static const wchar_t kGtkToplevelClass[] = L"gdkSurfaceToplevel";

void TextService::ShowSettings() {
  // A message-only endpoint belongs to the resident GTK main thread.
  // Its title is the registry identity, so private hosts cannot activate
  // the live UI. Only an acknowledged request suppresses the fallback.
  const std::wstring identity = NativeImeRegistryKey();
  const UINT request = RegisterWindowMessageW(L"NativeIME.Sumi.ShowSettings.v1");
  if (request != 0) {
    HWND resident = FindWindowExW(HWND_MESSAGE, nullptr,
                                 L"NeLispSumiSettingsV1", identity.c_str());
    DWORD_PTR acknowledged = 0;
    if (resident && SendMessageTimeoutW(resident, request, 0, 0,
        SMTO_ABORTIFHUNG | SMTO_BLOCK, 500, &acknowledged) && acknowledged == 1)
      return;
  }
  // Focus the settings window if one is already open, rather than
  // starting another process.
  //
  // Every invocation used to ShellExecute unconditionally, and sumi-ui
  // passes G_APPLICATION_NON_UNIQUE for `--settings', so nothing on
  // either side stopped a second one: clicking 設定 twice gave two
  // windows, clicking it ten times gave ten. Reported as 「設定をクリック
  // するたびにウィンドウが新規に立ちあがり量産されます」, together with
  // the delay -- which is the same cause, since each click paid a fresh
  // process start plus GTK4's eleven DLLs (measured at 1.6-1.9s warm, and
  // the user sees up to ~10s cold).
  // Legacy standalone windows have no private identity. Looking them up
  // is safe only for the default production identity.
  if (HWND existing = identity == L"Software\\NativeIME"
          ? FindWindowW(kGtkToplevelClass, kSettingsWindowTitle) : nullptr) {
    // A minimised window has to be restored before it can take focus.
    if (IsIconic(existing)) ShowWindow(existing, SW_RESTORE);
    SetForegroundWindow(existing);
    return;
  }

  // The settings UI stores its own executable path once installed; if
  // present, launch it (with --settings) in preference to the legacy
  // fallback below. Registry read only.
  wchar_t settings_exe[32768]{};
  DWORD settings_exe_bytes = sizeof(settings_exe);
  HKEY key = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, NativeImeRegistryKey().c_str(), 0, KEY_READ,
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

void TextService::LoadApplicationSettings() {
  wchar_t executable[32768]{};
  GetModuleFileNameW(nullptr, executable, _countof(executable));
  std::wstring name(executable);
  name = name.substr(name.find_last_of(L"\\/") + 1);
  CharLowerBuffW(name.data(), static_cast<DWORD>(name.size()));
  const std::wstring path = NativeImeRegistryKey() + L"\\Apps\\" + name;
  auto_pair_caret_ = ddskk::ReadAutoPairCaret(name, nullptr);
  application_open_mode_ = L"restore";
  application_mode_indicator_ = -1;
  application_local_conversion_ = -1;
  inline_enabled_ = false;
  bool enabled = false;
  HKEY key = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, path.c_str(), 0, KEY_QUERY_VALUE,
                    &key) == ERROR_SUCCESS) {
    auto_pair_caret_ = ddskk::ReadAutoPairCaret(name, key);
    wchar_t mode[32]{};
    DWORD bytes = sizeof(mode), type = 0, value = 0;
    if (RegQueryValueExW(key, L"OpenMode", nullptr, &type,
        reinterpret_cast<BYTE*>(mode), &bytes) == ERROR_SUCCESS &&
        type == REG_SZ && bytes >= sizeof(wchar_t) &&
        bytes <= sizeof(mode) && mode[bytes / sizeof(wchar_t) - 1] == 0) {
      if (wcscmp(mode, L"latin") == 0 || wcscmp(mode, L"hiragana") == 0 ||
          wcscmp(mode, L"katakana") == 0) application_open_mode_ = mode;
    }
    bytes = sizeof(value);
    if (RegQueryValueExW(key, L"ModeIndicator", nullptr, &type,
        reinterpret_cast<BYTE*>(&value), &bytes) == ERROR_SUCCESS &&
        type == REG_DWORD && bytes == sizeof(value) && value <= 1) {
      application_mode_indicator_ = static_cast<int>(value);
    }
    bytes = sizeof(value);
    if (RegQueryValueExW(key, L"LocalConversion", nullptr, &type,
        reinterpret_cast<BYTE*>(&value), &bytes) == ERROR_SUCCESS &&
        type == REG_DWORD && bytes == sizeof(value) && value <= 1)
      application_local_conversion_ = static_cast<int>(value);
    bytes = sizeof(value);
    enabled = RegQueryValueExW(key, L"PublishState", nullptr, &type,
        reinterpret_cast<BYTE*>(&value), &bytes) == ERROR_SUCCESS &&
        type == REG_DWORD && bytes == sizeof(value) && value == 1;
    bytes = sizeof(value);
    inline_enabled_ = RegQueryValueExW(key, L"InlinePreedit", nullptr, &type,
        reinterpret_cast<BYTE*>(&value), &bytes) == ERROR_SUCCESS &&
        type == REG_DWORD && bytes == sizeof(value) && value == 1;
    RegCloseKey(key);
  }
  if (publish_state_ && !enabled) RemovePublishedState();
  publish_state_ = enabled;
  if (inline_enabled_ && provider_window_ != nullptr)
    inline_channel_.Start(provider_window_, kInlineMessage);
  if (enabled && thread_manager_ != nullptr && !publication_registered_) {
    if (shim_.publisher_delta) shim_.publisher_delta(shim_.owner, 1);
    else ++process_publishers;
    publication_registered_ = true;
    publication_active_ = true;
  }
}

void TextService::QueuePublishedState(const ddskk::EngineState* state) {
  if (!publish_state_ || !publication_active_) return;
  if (state != nullptr) {
    published_composing_ = !state->candidates.empty() ||
        state->mode == L"candidate" || provider_composition_active_ ? 2 :
        state->composition_start >= 0 || !state->pending_romaji.empty() ? 1 : 0;
  }
  PublishedState next;
  next.mode = last_engine_mode_.empty() ? L"hiragana" : last_engine_mode_;
  next.open = keyboard_open_ ? 1 : 0;
  next.composing = keyboard_open_ ? published_composing_ : 0;
  if (next.mode == last_publication_.mode && next.open == last_publication_.open &&
      next.composing == last_publication_.composing) return;
  next.sequence = shim_.publication_sequence ? shim_.publication_sequence(shim_.owner) : ++process_publication_sequence;
  last_publication_ = next;
  publications_.push_back(std::move(next));
  // This callback only queues snapshots. Registry I/O runs after TSF returns
  // to the message pump; retain every transition, including rapid toggles.
  if (!publication_queued_ && provider_window_ != nullptr)
    publication_queued_ = PostMessageW(provider_window_, kPublishStateMessage, 0, 0) != 0;
}

void TextService::FlushPublishedState() {
  publication_queued_ = false;
  if (!publication_active_ || !publish_state_) return;
  std::lock_guard<std::mutex> writer(process_publication_writer);
  PublicationLock shared_writer(shim_);
  const std::wstring path = NativeImeRegistryKey() + L"\\Clients\\" +
      std::to_wstring(GetCurrentProcessId());
  HKEY key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, path.c_str(), 0, nullptr, 0,
      KEY_SET_VALUE, nullptr, &key, nullptr) != ERROR_SUCCESS) return;
  for (const auto& state : publications_) {
    const DWORD flushed = shim_.publication_flushed ? shim_.publication_flushed(shim_.owner, 0) : process_flushed_sequence;
    if (state.sequence <= flushed) continue;
    const auto write = [key](const wchar_t* name, DWORD value) {
      return RegSetValueExW(key, name, 0, REG_DWORD,
          reinterpret_cast<const BYTE*>(&value), sizeof(value));
    };
    // An odd revision fences a partial multi-value registry write. Readers
    // require the same even revision before and after their snapshot.
    write(L"revision", state.sequence * 2 - 1);
    RegSetValueExW(key, L"mode", 0, REG_SZ,
        reinterpret_cast<const BYTE*>(state.mode.c_str()),
        static_cast<DWORD>((state.mode.size() + 1) * sizeof(wchar_t)));
    write(L"open", state.open);
    write(L"composing", state.composing);
    write(L"sequence", state.sequence);
    write(L"revision", state.sequence * 2);
    if (shim_.publication_flushed) shim_.publication_flushed(shim_.owner, state.sequence);
    else process_flushed_sequence = state.sequence;
  }
  RegCloseKey(key);
  publications_.clear();
}

void TextService::RemovePublishedState() {
  publication_active_ = false;
  publications_.clear();
  publication_queued_ = false;
  if (!publication_registered_) return;
  publication_registered_ = false;
  const unsigned publishers = shim_.publisher_delta ? shim_.publisher_delta(shim_.owner, -1) : --process_publishers;
  last_publication_ = {};
  std::lock_guard<std::mutex> writer(process_publication_writer);
  PublicationLock shared_writer(shim_);
  if (publishers != 0) return;
  const std::wstring path = NativeImeRegistryKey() + L"\\Clients\\" +
      std::to_wstring(GetCurrentProcessId());
  RegDeleteTreeW(HKEY_CURRENT_USER, path.c_str());
}

void TextService::LoadSettings() {
  LoadApplicationSettings();
  for (const wchar_t* label : {L"かな", L"カナ", L"SKK", L"全英", L"Abbrev"})
    mode_indicator_.SetPaletteOverride(label, ModeIndicatorColors(label).background);
  HKEY key = nullptr;
  wchar_t engine[32] = L"ddskk";
  DWORD bytes = sizeof(engine), kana = 1, kana_bytes = sizeof(kana);
  DWORD indicator_ms = 3000, indicator_ms_bytes = sizeof(indicator_ms);
  DWORD indicator_enabled = 1, indicator_enabled_bytes = sizeof(indicator_enabled);
  DWORD indicator_scale = 100, indicator_scale_bytes = sizeof(indicator_scale);
  DWORD debug_log = 0, debug_log_bytes = sizeof(debug_log);
  DWORD local = 0, local_bytes = sizeof(local), local_type = 0;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, NativeImeRegistryKey().c_str(), 0,
                    KEY_READ, &key) == ERROR_SUCCESS) {
    RegQueryValueExW(key, L"Engine", nullptr, nullptr,
                     reinterpret_cast<BYTE*>(engine), &bytes);
    if (RegQueryValueExW(key, L"DebugLog", nullptr, nullptr,
                        reinterpret_cast<BYTE*>(&debug_log), &debug_log_bytes) != ERROR_SUCCESS) {
      debug_log_bytes = sizeof(debug_log);
      RegQueryValueExW(key, L"DllDebug", nullptr, nullptr,
                      reinterpret_cast<BYTE*>(&debug_log), &debug_log_bytes);
    }
    if (RegQueryValueExW(key, L"LocalConversion", nullptr, &local_type,
        reinterpret_cast<BYTE*>(&local), &local_bytes) != ERROR_SUCCESS ||
        local_type != REG_DWORD || local_bytes != sizeof(local)) local = 0;
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
  // Keep private harnesses and side-by-side provider probes isolated from
  // the user's live registry selection.  The engine host already honours
  // this variable; the DLL must select the same provider or the two ends
  // can disagree about key capabilities during a test run.
  wchar_t environment_engine[32]{};
  const DWORD environment_engine_length = GetEnvironmentVariableW(
      L"NELISP_IME_ENGINE", environment_engine,
      static_cast<DWORD>(_countof(environment_engine)));
  if (environment_engine_length > 0 &&
      environment_engine_length < _countof(environment_engine)) {
    wcscpy_s(engine, environment_engine);
  }
  engine_id_ = NarrowUtf8(engine);
  fallback_rule_snapshot_.reset();
  local_enabled_ = engine_id_ == "ddskk" &&
      (application_local_conversion_ >= 0 ? application_local_conversion_ == 1 : local == 1);
  if (local_enabled_) {
    try { local_store_.Start(); SetTimer(provider_window_, 2, 50, nullptr); } catch (...) { local_enabled_ = false; }
  } else {
    CancelLocalRetry(); local_observer_retry_.reset(); local_store_.ReleaseState();
  }
  ddskk_engine_ = engine_id_ != "passthrough";
  realtime_frontend_.SetContinuousPreedit(engine_id_ != "ddskk");
  // Settings that belong to one engine live under its own key, so reread
  // the per-engine copy now that the engine id is known.  The value at the
  // root is the pre-per-engine location and remains the fallback.
  kana_mode_ = ddskk_engine_ &&
               ReadEngineDword(engine, L"InitialKanaMode", kana) != 0;
  engine_pending_ = false;
  provider_composition_active_ = false;
  deferred_provider_keys_.clear();
  debug_log_ = debug_log == 1;
  if (debug_log_ && provider_window_) SetTimer(provider_window_, 5, 100, nullptr);
  // Registry reload also runs inside TSF callbacks. Publish the desired
  // engine; pipe selection/reconnect belongs to the serialized provider worker.
  QueueProviderSettings(engine_id_);

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

void TextService::RefreshDebugSettings() {
  DWORD value = 0, bytes = sizeof(value);
  if (RegGetValueW(HKEY_CURRENT_USER, NativeImeRegistryKey().c_str(), L"DebugLog",
                  RRF_RT_REG_DWORD, nullptr, &value, &bytes) != ERROR_SUCCESS) {
    bytes = sizeof(value);
    if (RegGetValueW(HKEY_CURRENT_USER, NativeImeRegistryKey().c_str(), L"DllDebug",
                    RRF_RT_REG_DWORD, nullptr, &value, &bytes) != ERROR_SUCCESS) return;
  }
  const bool enabled = value == 1;
  if (enabled == debug_log_) return;
  debug_log_ = enabled;
  if (provider_window_) {
    if (enabled) SetTimer(provider_window_, 5, 100, nullptr);
    else KillTimer(provider_window_, 5);
  }
}

void TextService::SettleIdleProviderState() {
  if (provider_pending_.load() || pending_state_edits_) return;
  if (!confirmation_pending_ && !confirmation_delivery_pending_ &&
      confirmation_replay_ && deferred_provider_keys_.empty()) {
    confirmation_replay_ = false;
    confirmation_resume_posted_ = false;
    if (confirmation_anchor_) confirmation_anchor_->Release();
    confirmation_anchor_ = nullptr;
  }
  if (!composition_ && !engine_pending_ && !provider_composition_active_ &&
      !registration_mode_ && !realtime_frontend_.preedit()) {
    provider_conversion_retry_ = false;
    provider_conversion_active_ = false;
    if (provider_window_) KillTimer(provider_window_, 9);
  }
}

void TextService::ReleaseFailedConfirmation() {
  confirmation_pending_ = false;
  confirmation_delivery_pending_ = false;
  confirmation_state_.reset(); // Never blindly repeat a possibly mutated edit.
  if (provider_window_) KillTimer(provider_window_, 7);
  confirmation_replay_ = !deferred_provider_keys_.empty();
  ScheduleConfirmationReplay();
}

bool TextService::CommitNativeKatakana(ITfContext* context, bool replay) {
  if (registration_mode_ || provider_composition_active_ || confirmation_pending_ ||
      confirmation_replay_ || (!replay && !deferred_provider_keys_.empty()) ||
      !realtime_frontend_.CanCommitKatakanaReading()) return false;
  const auto saved = realtime_frontend_;
  // The complete native reading owns q. A pending lookup has no authority
  // to repaint it later, and no queued key is discarded by this cancellation.
  auto following = std::move(deferred_provider_keys_);
  CancelPendingProvider();
  deferred_provider_keys_ = std::move(following);
  engine_.MarkNeedsResync();
  const auto state = realtime_frontend_.CommitKatakana();
  if (!state) return false;
  if (FAILED(ApplyLocalState(context, *state))) realtime_frontend_ = saved;
  return true;
}

void TextService::FollowSettings() {
  SettleIdleProviderState();
  // Diagnostic-only writes do not alter the current engine/document episode.
  // Apply them even while a legitimate reading gates the engine refresh.
  if (settings_watcher_.dirty.load()) RefreshDebugSettings();
  if (composition_ || engine_pending_ || registration_mode_ ||
      provider_pending_.load() || provider_composition_active_ || provider_conversion_retry_ ||
      realtime_frontend_.preedit() || !deferred_provider_keys_.empty() ||
      confirmation_pending_ || confirmation_replay_) return;
  if (!settings_watcher_.dirty.exchange(false)) return;
  LoadSettings();
  MaybeShowModeIndicator(nullptr, nullptr);
}

TextService::ProviderSettings TextService::ReadProviderSettings(const std::string& engine) {
  ProviderSettings settings;
  settings.engine = engine;
  settings.pipe = ddskk::EngineClient::Endpoint();
  HKEY key = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, NativeImeRegistryKey().c_str(), 0,
                    KEY_READ, &key) == ERROR_SUCCESS) {
    auto read = [key](const wchar_t* name) {
      wchar_t value[32768]{}; DWORD bytes = sizeof(value);
      if (RegQueryValueExW(key, name, nullptr, nullptr,
          reinterpret_cast<BYTE*>(value), &bytes) != ERROR_SUCCESS) return std::wstring{};
      value[_countof(value) - 1] = 0;
      return std::wstring(value);
    };
    settings.host = read(L"EngineHost");
    settings.executable = read(L"EngineExecutable");
    if (settings.executable.empty()) settings.executable = read(L"NeLisp");
    settings.repository = read(L"Repository");
    RegCloseKey(key);
  }
  return settings;
}

void TextService::QueueProviderSettings(const std::string& engine) {
  const auto settings = ReadProviderSettings(engine);
  const auto previous = provider_settings_.load();
  // UI/debug/CoreDll registry writes must not invalidate a provider session.
  if (previous && *previous == settings) return;
  provider_settings_.store(std::make_shared<const ProviderSettings>(settings));
  StartProviderSettingsWorker();
}

void TextService::StartProviderSettingsWorker() {
  if (provider_settings_worker_.exchange(true)) return;
  AddRef();
  try {
    std::thread([this] {
      const ULONGLONG deadline = GetTickCount64() + 60000;
      DWORD backoff = 100;
      bool completed = false;
      std::shared_ptr<const ProviderSettings> attempted;
      do {
        bool applied;
        {
          std::lock_guard<std::mutex> lock(provider_engine_mutex_);
          attempted = provider_settings_.load();
          // Cold OPEN/RESET/ENGINE SET cannot reliably fit the conversion
          // worker's 25 ms probe. Allow completion off the TSF thread, while
          // preserving the coalesced worker and backoff on failure.
          applied = ApplyProviderSettings(1000);
          completed = applied;
        }
        if (applied || !provider_settings_.load()) break;
        Sleep(backoff); // Never hold the provider mutex during backoff.
        backoff = std::min<DWORD>(backoff * 2, 2000);
      } while (GetTickCount64() < deadline);
      provider_settings_worker_.store(false);
      // Close the publication/worker-exit race without retrying an expired
      // unchanged target. Queue owns the other side of this race.
      const auto latest = provider_settings_.load();
      if (latest && latest != applied_provider_settings_.load() &&
          (completed || latest != attempted))
        StartProviderSettingsWorker();
      Release();
    }).detach();
  } catch (...) { provider_settings_worker_.store(false); Release(); }
}

bool TextService::ApplyProviderSettings(DWORD timeout_ms) {
  for (;;) {
    const auto desired = provider_settings_.load();
    if (!desired || desired == applied_provider_settings_.load()) return true;
    if (desired != connecting_provider_settings_) {
      // Invalidate once per configuration, never reuse a stale handle.
      engine_.Disconnect();
      engine_.MarkNeedsResync();
      connecting_provider_settings_ = desired;
    }
    EnsureEngineHost();
    const auto started = GetTickCount64();
    const bool selected = engine_.SelectEngine(desired->engine, timeout_ms);
    if (GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", nullptr, 0)) {
      std::printf("PROVIDER_SETTINGS select=%d budget_ms=%lu elapsed_ms=%llu connected=%d connection_error=%lu engine=%s\n",
                  selected ? 1 : 0, timeout_ms, GetTickCount64() - started,
                  engine_.IsConnected() ? 1 : 0, engine_.ConnectionError(), desired->engine.c_str());
      std::fflush(stdout);
    }
    if (!selected) return false;
    engine_.MarkNeedsResync();
    applied_provider_settings_.store(desired);
    if (GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", nullptr, 0)) {
      std::printf("PROVIDER_SETTINGS engine=%s applied=1\n", desired->engine.c_str());
      std::fflush(stdout);
    }
    if (desired == provider_settings_.load()) return true;
  }
}

bool TextService::WaitForProviderSettings(ULONGLONG deadline) {
  for (;;) {
    const auto started = GetTickCount64();
    if (started >= deadline) break;
    const auto remaining = static_cast<DWORD>(deadline - started);
    if (ApplyProviderSettings(std::min<DWORD>(remaining, kInteractiveTimeoutMs)))
      return GetTickCount64() < deadline;
    const auto now = GetTickCount64();
    if (now >= deadline) break;
    Sleep(static_cast<DWORD>(std::min<ULONGLONG>(10, deadline - now)));
  }
  return false;
}

bool TextService::TryLocalConversionFallback() {
  if (!local_enabled_ || !active_context_ || !realtime_frontend_.preedit()) return false;
  if (provider_conversion_active_ && (provider_conversion_registration_ || provider_conversion_skip_)) return false;
  const auto captured = local_store_.Capture();
  if (!captured.available || !captured.index || !local_rule_snapshot_ ||
      captured.index->Rules() != local_rule_snapshot_->Rules()) return false;
  const auto reading = realtime_frontend_.preview_reading();
  std::vector<std::wstring> pending;
  for (const auto& item : captured.pending) if (item.key == reading) {
    pending.erase(std::remove(pending.begin(), pending.end(), item.candidate), pending.end());
    pending.insert(pending.begin(), item.candidate);
  }
  if (!local_conversion_.Begin(captured.index, reading, pending)) return false;
  provider_conversion_active_ = false;
  provider_conversion_retry_ = false;
  provider_composition_active_ = false;
  provider_candidate_state_.reset();
  const HRESULT result = ApplyLocalState(active_context_, local_conversion_.State());
  if (FAILED(result)) ScheduleLocalRetry();
  std::printf("LOCAL_FALLBACK resolved=candidate pending=0\n");
  return true;
}

bool TextService::ProviderConversionSettingsPending(bool settings_ready, bool provider_unavailable) {
  return !settings_ready || provider_unavailable;
}

void TextService::RetainProviderConversion() {
  // Deadline/failure ends this request, not ownership of the reading and keys.
  // Invalidate a late reply before rendering native state or retrying selection.
  provider_sequence_.fetch_add(1);
  provider_pending_.store(false);
  provider_deadline_ = 0;
  if (provider_window_) KillTimer(provider_window_, 1);
  engine_.CancelPendingIo();
  engine_.MarkNeedsResync();
  if (TryLocalConversionFallback()) ReplayDeferredProviderKeys();
  else {
    provider_conversion_retry_ = true;
    applied_provider_settings_.store(nullptr);
    StartProviderSettingsWorker();
    SetTimer(provider_window_, 9, 200, nullptr);
    std::printf("PROVIDER_SETTINGS pending=1 conversion_retained=1\n");
  }
}

void TextService::EnsureEngineHost() {
  if (engine_.Connect(1)) return;
  // Timeout/busy means an existing pipe, not permission to launch another host.
  const DWORD error = engine_.ConnectionError();
  if (error != ERROR_FILE_NOT_FOUND && error != ERROR_PATH_NOT_FOUND) return;
  wchar_t disable_spawn[2]{};
  if (GetEnvironmentVariableW(L"NELISP_IME_DISABLE_HOST_SPAWN", disable_spawn,
                              _countof(disable_spawn)) > 0 && disable_spawn[0] == L'1') return;
  const auto desired = provider_settings_.load();
  const auto settings = desired ? *desired : ReadProviderSettings(engine_id_);
  ddskk::EngineClient::TryStartHost(settings.host, settings.executable,
                                   settings.repository, settings.pipe);
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

  const int utf8_len = WideCharToMultiByte(CP_UTF8, 0, line,
      static_cast<int>(wcslen(line)), nullptr, 0, nullptr, nullptr);
  if (utf8_len <= 0) return;
  std::string utf8(utf8_len, '\0');
  WideCharToMultiByte(CP_UTF8, 0, line, static_cast<int>(wcslen(line)),
                      utf8.data(), utf8_len, nullptr, nullptr);
  std::lock_guard lock(debug_mutex_);
  if (debug_lines_.size() + utf8.size() <= 256 * 1024) debug_lines_ += utf8;
}
void TextService::FlushDebugLog() {
  std::string lines;
  { std::lock_guard lock(debug_mutex_); lines.swap(debug_lines_); }
  if (lines.empty()) return;
  wchar_t directory[MAX_PATH]{};
  const DWORD size = GetEnvironmentVariableW(L"LOCALAPPDATA", directory, MAX_PATH);
  if (!size || size >= MAX_PATH) return;
  const std::wstring folder = std::wstring(directory) + L"\\DDSKK";
  CreateDirectoryW(folder.c_str(), nullptr);
  const HANDLE file = CreateFileW((folder + L"\\dll-debug.log").c_str(),
      FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
      OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  DWORD written = 0;
  WriteFile(file, lines.data(), static_cast<DWORD>(lines.size()), &written, nullptr);
  CloseHandle(file);
}
void TextService::TracePhase(const wchar_t* phase, uint64_t sequence,
                             const wchar_t* path, HRESULT result, DWORD flags) {
  if (!debug_log_) return;
  LARGE_INTEGER counter{}, frequency{};
  QueryPerformanceCounter(&counter); QueryPerformanceFrequency(&frequency);
  DebugLog(L"PHASE name=%ls seq=%llu path=%ls us=%llu hr=%08X flags=%lu async=%d",
      phase, sequence, path,
      static_cast<unsigned long long>((counter.QuadPart / frequency.QuadPart) * 1000000 +
          (counter.QuadPart % frequency.QuadPart) * 1000000 / frequency.QuadPart),
      static_cast<unsigned>(result), flags, result == TF_S_ASYNC);
}
HRESULT TextService::RequestEdit(ITfContext* context, ITfEditSession* edit,
                                  HRESULT* result, const wchar_t* path, uint64_t sequence) {
  if (!sequence) sequence = KeySequence();
  // Let TSF grant the lock now or retain the session. Console hosts no longer
  // need a failed SYNC request followed by the 50 ms local retry timer.
  const DWORD flags = TF_ES_ASYNCDONTCARE | TF_ES_READWRITE;
  TracePhase(L"edit-request", sequence, path, S_OK, flags);
  HRESULT request = context->RequestEditSession(client_id_, edit, flags, result);
  if (SUCCEEDED(request) && (*result == TF_E_SYNCHRONOUS || *result == TF_E_LOCKED)) {
    TracePhase(L"edit-retry-async", sequence, path, *result, TF_ES_ASYNC | TF_ES_READWRITE);
    request = context->RequestEditSession(client_id_, edit, TF_ES_ASYNC | TF_ES_READWRITE, result);
  }
  TracePhase(L"edit-request-return", sequence, path, request, flags);
  TracePhase(L"edit-result", sequence, path, *result, flags);
  return request;
}
void TextService::FinishStateEdit(ITfContext* context,
                                 const ddskk::EngineState& state, HRESULT result) {
  if (FAILED(result) || !thread_manager_) return;
  // Text and candidate UI become visible in the same edit-session execution.
  UpdateCandidateUI(context, state);
  MaybeShowModeIndicator(context, &state);
  ApplyRequestedInlineMode();
}

HRESULT TextService::OnKeyDown(ITfContext* context, WPARAM wparam, LPARAM lparam,
                               BOOL* eaten) {
  const bool tested_event = tested_key_valid_ && tested_virtual_key_ == wparam && tested_lparam_ == lparam;
  BYTE event_state[256]{};
  const bool have_event_state = tested_event || GetKeyboardState(event_state) != FALSE;
  if (tested_event) std::copy_n(tested_keyboard_state_, 256, event_state);
  const HKL event_layout = tested_event ? tested_keyboard_layout_ : GetKeyboardLayout(0);
  const auto replay_codepoint = replay_codepoint_;
  const bool key_shift = tested_event ? (event_state[VK_SHIFT] & 0x80) != 0 : ShiftDown();
  const bool key_caps = (event_state[VK_CAPITAL] & 1) != 0;
  tested_key_valid_ = false;
  bool translated_event = false;
  std::optional<char32_t> translated_codepoint;
  // Translate only when the claim/router needs text, and only once. Merely
  // testing or passing through a dead key must not consume its keyboard state.
  const auto event_codepoint = [&]() {
    if (!translated_event) {
      translated_codepoint = replay_codepoint ? replay_codepoint
          : have_event_state ? TranslateKey(wparam, lparam, event_state, event_layout) : std::nullopt;
      translated_event = true;
      if (GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", nullptr, 0)) {
        std::printf("KEYINPUT vk=%02X scalar=%08X source=%s shift=%d caps=%d\n",
            static_cast<unsigned>(wparam), static_cast<unsigned>(translated_codepoint.value_or(0)),
            replay_codepoint ? "replay" : tested_event ? "test" : "down", key_shift, key_caps);
      }
    }
    return translated_codepoint;
  };
  struct CallbackTailTrace {
    TextService* owner;
    ~CallbackTailTrace() { owner->TracePhase(L"key-locals-released", owner->KeySequence(), L"host"); }
  } callback_tail{this};

  preparation_sequence_.fetch_add(1);
  ++key_sequence_;
  TracePhase(L"key-receipt", key_sequence_, dispatching_registration_key_ ? L"registration-pump" : L"key");
  FollowSettings();
  if (eaten == nullptr) return E_POINTER;
  *eaten = FALSE;
  if (context == nullptr) return E_INVALIDARG;
  bool context_changed = active_context_ != context;
  if (context_changed && active_context_ && inline_epoch_) {
    // A CUAS context can arrive through another interface tear-off. Only
    // IUnknown identifies the COM object; settling that same inline episode
    // would commit an unresolved prefix (n) before the next vowel (u).
    IUnknown* previous_identity = nullptr;
    IUnknown* current_identity = nullptr;
    if (SUCCEEDED(active_context_->QueryInterface(IID_IUnknown,
            reinterpret_cast<void**>(&previous_identity))) &&
        SUCCEEDED(context->QueryInterface(IID_IUnknown,
            reinterpret_cast<void**>(&current_identity))))
      context_changed = previous_identity != current_identity;
    if (previous_identity) previous_identity->Release();
    if (current_identity) current_identity->Release();
  }
  if (context_changed) {
    const bool abandoned = active_context_ != nullptr &&
        (engine_pending_ || registration_mode_ || composition_ != nullptr);
    DebugLog(L"Context switch old=%p new=%p abandoned=%d pending=%d reg=%d comp=%d",
             active_context_, context, abandoned ? 1 : 0,
             engine_pending_ ? 1 : 0, registration_mode_ ? 1 : 0,
             composition_ != nullptr ? 1 : 0);
    // End the composition in the document that actually owns it BEFORE
    // changing active_context_. Merely releasing composition_ after the
    // switch leaves the old TSF context with a live composition/UI element;
    // Edge/Terminal tab changes then strand navigation in that old editor.
    if (abandoned) SettleContextComposition(active_context_);
    if (active_context_ != nullptr) active_context_->Release();
    active_context_ = context;
    active_context_->AddRef();
  }
  std::optional<ddskk::EngineState> state;
  const wchar_t* branch = L"?";
  // Logs the outcome of this call using whatever `state'/`branch' hold at
  // the point it runs; every return path below calls this exactly once,
  // right before returning.
  const auto debug_exit = [&](BOOL final_eaten, HRESULT request_hr = S_OK,
                              HRESULT edit_hr = S_OK) {
    TracePhase(L"key-return", key_sequence_, branch, edit_hr);
    wchar_t harness_diagnostics[2]{};
    if (GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS",
                                harness_diagnostics, 2) > 0) {
      std::printf("KEYBRANCH vk=%02X branch=%ls state=%d provider_active=%d "
                  "provider_pending=%d frontend_preedit=%d\n",
                  static_cast<unsigned>(wparam), branch, state ? 1 : 0,
                  provider_composition_active_ ? 1 : 0,
                  provider_pending_.load(std::memory_order_acquire) ? 1 : 0,
                  realtime_frontend_.preedit() ? 1 : 0);
      // Harness diagnostics flush after callback timing, not on the key thread.
    }
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
  /* Some hosts call KeyDown directly without first asking TestKeyDown.
   * Keep that path identical to the claim decision: navigation, digits and
   * F-keys that are not part of an active conversion must reach the
   * application untouched.  Previously direct KeyDown still translated a
   * digit/punctuation character and sent it to DDSKK, despite TestKeyDown
   * having declined it, so those ordinary editor keys disappeared. */
  const bool force_latin = engine_id_ == "ddskk" && !registration_mode_ &&
      (replaying_latin_switch_ || (ddskk_engine_ && keyboard_open_ && kana_mode_ && have_event_state &&
      !(tested_control_down_ || ControlDown() || (event_state[VK_CONTROL] & 0x80)) &&
      !(event_state[VK_MENU] & 0x80) && !(event_state[VK_LWIN] & 0x80) &&
      !(event_state[VK_RWIN] & 0x80) && event_codepoint() == U'l'));
  const auto latin_command = [&] {
    // Capture the first mode command; following queued l keys are literals
    // after that command, even if its asynchronous delivery is still pending.
    const bool intent = replaying_latin_switch_ || std::none_of(
        deferred_provider_keys_.begin(), deferred_provider_keys_.end(),
        [](const DeferredProviderKey& key) { return key.latin_switch; });
    return DeferredProviderKey{wparam, U'l', true, key_shift, false, false, key_caps, intent};
  };
  // Enter already queued behind a lookup is also a confirmation intent. Never
  // drop it, or a confirmed edit/delivery, merely to change the following mode.
  const bool queued_confirmation = force_latin && !replaying_confirmation_ &&
      std::any_of(deferred_provider_keys_.begin(),
      deferred_provider_keys_.end(), [](const DeferredProviderKey& key) {
        return key.virtual_key == VK_RETURN || key.ctrl_j;
      });
  if (force_latin && !replaying_confirmation_ &&
      (confirmation_pending_ || confirmation_replay_ || confirmation_delivery_pending_ || queued_confirmation)) {
    deferred_provider_keys_.push_back(latin_command());
    ScheduleConfirmationReplay();
    *eaten = TRUE; branch = L"force-latin-after-confirmation";
    debug_exit(*eaten); return S_OK;
  }
  if (force_latin && (provider_pending_.load(std::memory_order_acquire) ||
                     provider_conversion_retry_)) {
    // The pending result owns the selected word. Resolve it first; candidate
    // replay then uses the existing asynchronous confirmation barrier.
    deferred_provider_keys_.push_back(latin_command());
    *eaten = TRUE; branch = L"force-latin-after-provider";
    debug_exit(*eaten); return S_OK;
  }
  if (force_latin && (local_conversion_.active() || provider_composition_active_ ||
                     realtime_frontend_.composing())) {
    // Replayed l precedes keys still in this queue. Requeue the mode command
    // at the front so following letters cannot overtake confirmation.
    deferred_provider_keys_.push_front(latin_command());
    HRESULT confirm = S_OK;
    if (local_conversion_.active()) {
      confirm = CommitLocal(context, true);
    } else if (realtime_frontend_.composing() &&
               (!provider_composition_active_ || realtime_frontend_.okuri_started()) &&
               last_engine_mode_ != L"candidate") {
      // Native-owned incomplete okuri is still a reading, not a candidate.
      // Cancel only its formatting marker, then confirm the pending syllable.
      if (realtime_frontend_.okuri_started()) realtime_frontend_.CancelOkuri();
      const auto confirmed = realtime_frontend_.Commit();
      provider_composition_active_ = false;
      engine_.MarkNeedsResync();
      if (confirmed) confirm = ApplyLocalState(context, *confirmed, true);
    } else if (provider_composition_active_) {
      if (BeginProviderControl(ddskk::EngineControl::kCommit)) confirmation_pending_ = true;
      else { deferred_provider_keys_.pop_front(); confirm = E_FAIL; }
    }
    *eaten = TRUE; branch = L"force-latin-confirm";
    debug_exit(*eaten, confirm, confirm); return S_OK;
  }
  if (force_latin) {
    auto following_keys = replaying_confirmation_ ? std::move(deferred_provider_keys_)
        : std::deque<DeferredProviderKey>{};
    ITfRange* confirmed_anchor = replaying_confirmation_ ? confirmation_anchor_ : nullptr;
    if (replaying_confirmation_) confirmation_anchor_ = nullptr;
    CancelPendingProvider();
    if (replaying_confirmation_) {
      deferred_provider_keys_ = std::move(following_keys);
      confirmation_anchor_ = confirmed_anchor;
      confirmation_replay_ = !deferred_provider_keys_.empty();
    } else {
      // No confirmed transaction is pending on this branch: invalidate only
      // previously queued unconfirmed edits before publishing empty Latin.
      ++edit_generation_;
    }
    CancelLocalRetry();
    local_store_.CancelServer();
    local_conversion_.Reset(); local_okuri_snapshot_ = {};
    local_server_next_ = local_server_menu_ = false;
    provider_composition_active_ = false; provider_candidate_state_.reset();
    engine_.MarkNeedsResync();
    realtime_frontend_.SetInputMode(L"latin");
    state = realtime_frontend_.RestorePreedit();
    // Cleanup stays on the existing worker. Its reply never applies a stale
    // candidate or changes the locally selected Latin mode.
    ReleaseEngineConversion();
    engine_pending_ = false; kana_mode_ = false; last_engine_mode_ = L"latin";
    CloseCandidateUi();
    const HRESULT edit = ApplyLocalState(context, *state);
    *eaten = TRUE; branch = L"force-latin-l";
    debug_exit(*eaten, S_OK, edit); return S_OK;
  }
  if (local_conversion_retry_) {
    RetryLocalConversion(); CancelLocalRetry();
    if (local_conversion_.active() && wparam == VK_SPACE && !key_shift) {
      *eaten = TRUE; branch = L"local-convert-retry"; state = local_conversion_.State();
      debug_exit(*eaten); return S_OK;
    }
  }
  const bool control_down = tested_control_down_ || ControlDown();
  const bool ctrl_j = wparam == 'J' && control_down;
  const bool ctrl_g = wparam == 'G' && control_down;
  const bool composing = composition_ != nullptr || engine_pending_;
  // Refresh even during local preedit: publication can replace an engine
  // before a locally composed reading has entered its session. SetRules
  // rebuilds that reading only when the effective table actually changed.
  if (!realtime_frontend_.okuri_started()) local_okuri_snapshot_ = {};
  TracePhase(L"native-index-start", key_sequence_, L"local");
  const auto local_index = local_enabled_ ? local_store_.Current() : nullptr;
  TracePhase(L"native-index-end", key_sequence_, L"local");
  if (local_index) {
    // The worker parsed and validated this rule export. Pin the table
    // through a reading/candidate episode, including offline input.
    const auto rule_index = local_index->Base() ? local_index->Base() : local_index;
    if ((!local_rule_snapshot_ || local_rule_generation_ != rule_index->header().generation) &&
        !local_conversion_.active() &&
        (!realtime_frontend_.composing() ||
         (wparam == VK_SPACE && realtime_frontend_.preedit() && !provider_composition_active_ &&
          realtime_frontend_.TrySetRulesForReading(rule_index->ParsedRules())))) {
      realtime_frontend_.SetRules(rule_index->ParsedRules());
      auto_pair_.SetRules(rule_index->ParsedRules());
      local_rule_generation_ = rule_index->header().generation;
      // Learning swaps only the overlay. Rules pin the base, so an idle rule
      // cache neither recopies the table nor retains superseded overlays.
      local_rule_snapshot_ = rule_index;
    }
  } else if (!realtime_frontend_.composing() && !provider_composition_active_ &&
             !provider_pending_.load(std::memory_order_acquire) &&
             !local_conversion_.active()) {
    const auto rules = fallback_rules_ ? fallback_rules_->load() : nullptr;
    if (rules && rules != fallback_rule_snapshot_) {
      realtime_frontend_.SetRules(*rules);
      auto_pair_.SetRules(*rules);
      fallback_rule_snapshot_ = rules;
    }
  }
  const auto skk_mode_key = (!control_down && engine_id_ == "ddskk" &&
      realtime_frontend_.preedit() && !provider_composition_active_ && !local_conversion_.active())
      ? event_codepoint() : std::optional<char32_t>{};
  const bool katakana_q = engine_id_ == "ddskk" && composing &&
                           last_engine_mode_ == L"candidate" &&
                           wparam == 'Q' && key_shift;
  const bool claimed = registration_mode_
      ? (ctrl_g || WouldClaimKey(wparam, true, have_event_state ? event_state : nullptr))
      : (ctrl_j || (kana_mode_ && WouldClaimKey(wparam, composing, have_event_state ? event_state : nullptr)));
  tested_control_down_ = false;
  if (!ddskk_engine_ || !keyboard_open_ || !claimed) {
    branch = L"passthrough";
    debug_exit(FALSE);
    return S_OK;
  }
  if (!replaying_confirmation_ && (confirmation_pending_ || confirmation_replay_)) {
    const auto key = !control_down ? event_codepoint() : std::optional<char32_t>{};
    deferred_provider_keys_.push_back({wparam, key.value_or(0), key.has_value(), key_shift, ctrl_j, control_down, key_caps});
    ScheduleConfirmationReplay();
    *eaten = TRUE; branch = L"confirmation-queue"; debug_exit(*eaten); return S_OK;
  }
  if (skk_mode_key == U'q' && CommitNativeKatakana(context)) {
    *eaten = TRUE; branch = L"q-katakana-local";
    debug_exit(*eaten); return S_OK;
  }
  if (local_store_.started()) {
    local_handoff_requested_ = 0;
    local_store_.Start();
  }
  auto record_okuri = [&] {
    if (!GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", nullptr, 0)) return;
    const auto state = realtime_frontend_.RestorePreedit();
    if (!okuri_conversion_started_qpc_ && realtime_frontend_.okuri_started() &&
        state.pending_romaji.empty() && !realtime_frontend_.okuri_text().empty()) {
      LARGE_INTEGER now{}; QueryPerformanceCounter(&now); okuri_conversion_started_qpc_ = now.QuadPart;
    }
  };
  bool cancelled_provider = false;
  if (!registration_mode_ && local_conversion_.active()) {
    local_server_next_ = false;
    const auto reply = local_store_.Server(local_conversion_.reading(), local_conversion_.okuri());
    if (reply && reply->ready && reply->supported) local_conversion_.UpdateServer(reply->candidates);
    const auto saved_conversion = local_conversion_;
    const auto saved_frontend = realtime_frontend_;
    auto apply = [&](const ddskk::EngineState& next) {
      const HRESULT hr = ApplyLocalState(context, next);
      if (FAILED(hr)) { local_conversion_ = saved_conversion; realtime_frontend_ = saved_frontend; }
      return hr;
    };
    *eaten = TRUE;
    branch = L"local-candidate";
    if (katakana_q || wparam == VK_F6 || wparam == VK_F7) {
      if (realtime_frontend_.okuri_started()) realtime_frontend_.CancelOkuri();
      state = katakana_q ? realtime_frontend_.CommitKatakana()
          : wparam == VK_F6 ? std::optional<ddskk::EngineState>(realtime_frontend_.ToHiragana())
                            : realtime_frontend_.ToKatakana();
      if (state) { local_conversion_.Reset(); apply(*state); }
      debug_exit(*eaten); return S_OK;
    }
    if (ctrl_g || wparam == VK_ESCAPE || wparam == VK_BACK) {
      state = realtime_frontend_.okuri_started() ? realtime_frontend_.CancelOkuri() : realtime_frontend_.RestorePreedit();
      local_conversion_.Reset();
      apply(*state);
      debug_exit(*eaten); return S_OK;
    }
    const auto key = !control_down ? event_codepoint() : std::optional<char32_t>{};
    if ((wparam == VK_SPACE && key_shift) || wparam == VK_LEFT || wparam == VK_UP ||
        (control_down && wparam == 'P') || (key && *key == U'x')) {
      if ((wparam == VK_LEFT || wparam == VK_UP) ? local_conversion_.Previous() : local_conversion_.PreviousMenu()) state = local_conversion_.State();
      else { state = realtime_frontend_.okuri_started() ? realtime_frontend_.CancelOkuri() : realtime_frontend_.RestorePreedit(); local_conversion_.Reset(); }
      apply(*state);
      debug_exit(*eaten); return S_OK;
    }
    if (wparam == VK_HOME || wparam == VK_END || wparam == VK_PRIOR || wparam == VK_NEXT) {
      const auto selected = static_cast<size_t>(local_conversion_.State().candidate_index);
      const size_t page = selected < 4 ? 0 : 4 + (selected - 4) / 7 * 7;
      size_t target = wparam == VK_HOME ? 0 : wparam == VK_END ? local_conversion_.State().candidates.size() - 1
          : wparam == VK_PRIOR ? (page >= 11 ? page - 7 : page ? 3 : 0) : page ? page + 7 : 4;
      // Materialize a next source frontier at most once, without an RPC.
      if (wparam == VK_END || target >= local_conversion_.State().candidates.size()) local_conversion_.Materialize();
      target = std::min(target, local_conversion_.State().candidates.size() - 1);
      if (wparam == VK_END) target = local_conversion_.State().candidates.size() - 1;
      local_conversion_.Select(target); apply(local_conversion_.State());
      debug_exit(*eaten); return S_OK;
    }
    if (wparam == VK_SPACE || wparam == VK_RIGHT || wparam == VK_DOWN) {
      if (wparam == VK_SPACE ? local_conversion_.NextMenu() : local_conversion_.Next()) {
        state = local_conversion_.State();
        apply(*state);
      } else {
        if (!reply || !reply->ready) {
          // Keep input responsive while the last file candidate is visible.
          local_server_menu_ = wparam == VK_SPACE;
          local_server_next_ = true; local_server_deadline_ = GetTickCount64() + 250;
          if (provider_window_) SetTimer(provider_window_, 6, 50, nullptr);
          debug_exit(*eaten); return S_OK;
        }
        // Exhaustion is a provider barrier. Replay candidate traversal too,
        // so cancellation retains the previous candidate in its checkpoint.
        // Ordinary local keys never enter an engine shadow stream.
        local_conversion_.Reset();
        provider_composition_active_ = false;
        if (!BeginProviderConversion(realtime_frontend_.raw_keys(), false,
            saved_conversion.State().candidates.size()))
          local_conversion_ = saved_conversion;
      }
      debug_exit(*eaten); return S_OK;
    }
    if (key && local_conversion_.State().candidate_index >= 4) {
      const std::u32string choices = U"asdfjkl";
      const size_t slot = choices.find(*key);
      if (slot != choices.npos) {
        const size_t selected = local_conversion_.State().candidate_index;
        const size_t target = 4 + (selected - 4) / 7 * 7 + slot;
        if (local_conversion_.Select(target)) {
          const HRESULT hr = CommitLocal(context);
          if (FAILED(hr)) local_conversion_ = saved_conversion;
          debug_exit(*eaten, hr, hr); return S_OK;
        }
        debug_exit(*eaten); return S_OK;
      }
    }
    if (wparam == VK_RETURN || ctrl_j) {
      const HRESULT hr = CommitLocal(context);
      debug_exit(*eaten, hr, hr); return S_OK;
    }
    if (key) {
      deferred_provider_keys_.push_back({wparam, *key, true, key_shift, ctrl_j, control_down, key_caps});
      confirmation_pending_ = true;
      const HRESULT hr = CommitLocal(context, true);
      debug_exit(*eaten, hr, hr); return S_OK;
    } else { debug_exit(*eaten); return S_OK; }
  }
  if (!registration_mode_ && local_enabled_ && realtime_frontend_.okuri_started() &&
      !provider_composition_active_ && !provider_pending_.load() &&
      (wparam == VK_RETURN || wparam == VK_SPACE || ctrl_j) &&
      (!realtime_frontend_.RestorePreedit().pending_romaji.empty() ||
       realtime_frontend_.okuri_text().empty())) {
    // No conversion has started. Prefix confirmation/explicit Space uses
    // DDSKK's incomplete-okuri semantics rather than committing a '*' marker.
    local_okuri_snapshot_ = {};
    if (BeginProviderKeys(realtime_frontend_.raw_keys(), true)) {
      deferred_provider_keys_.push_back({wparam, 0, false, key_shift, ctrl_j});
      *eaten = TRUE; branch = L"okuri-prefix-provider";
      debug_exit(*eaten); return S_OK;
    }
    *eaten = TRUE; debug_exit(*eaten); return S_OK;
  }
  const bool cancelled_conversion =
      (ctrl_g || wparam == VK_ESCAPE) && provider_conversion_active_;
  if (!registration_mode_ && (ctrl_g || wparam == VK_ESCAPE)) deferred_provider_keys_.clear();
  // Cleanup has no document state to apply. Local typing and its commit
  // must continue while it finishes; otherwise Enter can pass through
  // ahead of the letters held in the provider queue.
  if ((provider_pending_.load(std::memory_order_acquire) &&
       !provider_cleanup_pending_) || okuri_handoff_failed_ || provider_conversion_retry_) {
    if (!registration_mode_ && (ctrl_g || wparam == VK_ESCAPE)) {
      // Cancellation is local and immediate. The detached lookup may still
      // finish, but its stale sequence can no longer edit the document.
      CancelPendingProvider();
      cancelled_provider = true;
    } else {
      if (provider_conversion_retry_ && wparam == VK_SPACE) {
        auto keys = realtime_frontend_.raw_keys();
        if (realtime_frontend_.katakana()) keys.insert(keys.begin(), U'q');
        if (BeginProviderConversion(keys, provider_conversion_registration_, provider_conversion_skip_))
          provider_conversion_retry_ = false;
        *eaten = TRUE; branch = L"provider-settings-retry";
        debug_exit(*eaten); return S_OK;
      }
      // Preserve every claimed key that arrives behind an asynchronous
      // provider request.  Mutating realtime_frontend_ here used to mix the
      // next word into the raw-key snapshot of the preceding conversion;
      // when its late reply arrived the visible text was then overwritten.
      // Enter/Space/navigation remain semantic controls while queued.  The
      // keyboard translator can also yield CR or a literal space for them;
      // marking that as printable made registration batch Enter into
      // FEED-KEYS and left the modal editor open forever.
      const bool semantic_control = ctrl_j || ctrl_g || wparam == VK_RETURN ||
          wparam == VK_SPACE || wparam == VK_BACK || wparam == VK_DELETE || wparam == VK_ESCAPE ||
          wparam == VK_LEFT || wparam == VK_RIGHT || wparam == VK_UP ||
          wparam == VK_DOWN || wparam == VK_HOME || wparam == VK_END ||
          (wparam >= VK_F6 && wparam <= VK_F10);
      const auto codepoint = semantic_control
          ? std::optional<char32_t>{} : event_codepoint();
      if ((okuri_handoff_active_ || okuri_handoff_failed_) &&
          (codepoint || wparam == VK_BACK) &&
          deferred_provider_keys_.size() == okuri_mirrored_keys_) {
        if (codepoint) { realtime_frontend_.Feed(*codepoint); record_okuri(); }
        else realtime_frontend_.BackspaceOkuri();
        ++okuri_mirrored_keys_;
        RenderLocalOkuri(context);
      }
      deferred_provider_keys_.push_back(DeferredProviderKey{
          wparam, codepoint.value_or(0), codepoint.has_value(), key_shift,
          ctrl_j, control_down, key_caps});
      if (okuri_handoff_failed_) {
        okuri_handoff_active_ = true;
        okuri_handoff_retry_ = true;
        okuri_handoff_failed_ = false;
        auto keys = realtime_frontend_.raw_keys();
        if (realtime_frontend_.katakana()) keys.insert(keys.begin(), U'q');
        const auto local = realtime_frontend_.RestorePreedit();
        if (local.pending_romaji.empty() && !local.text.empty() &&
            local.text.back() != L'*')
          BeginProviderConversion(keys);
        else
          BeginProviderKeys(keys, true);
      }
      TracePhase(L"provider-key-deferred", key_sequence_, L"engine");
      DebugLog(L"QUEUE seq=%llu count=%zu cleanup=%d index=%d", key_sequence_,
          deferred_provider_keys_.size(), provider_cleanup_pending_, local_index ? 1 : 0);
      branch = L"provider-queue";
      *eaten = TRUE;
      debug_exit(*eaten);
      return S_OK;
    }
  }
  const bool local_katakana_q = skk_mode_key == U'q' &&
      realtime_frontend_.CanCommitKatakanaReading();
  if (!local_katakana_q && skk_mode_key && (*skk_mode_key == U'q' || *skk_mode_key == U'Q' ||
                      *skk_mode_key == U'l' || *skk_mode_key == U'L' ||
                      *skk_mode_key == U'/')) {
    auto keys = realtime_frontend_.raw_keys();
    if (realtime_frontend_.katakana()) keys.insert(keys.begin(), U'q');
    keys.push_back(*skk_mode_key);
    if (BeginProviderKeys(keys, true)) {
      branch = L"skk-preedit-key";
      *eaten = TRUE;
      debug_exit(*eaten);
      return S_OK;
    }
  }
  // After the okuri handoff, DDSKK owns both the pending syllable and the
  // reading restored by quit (which merges the okuri into the reading).
  if (provider_composition_active_ && realtime_frontend_.okuri_started() &&
      (ctrl_g || wparam == VK_ESCAPE)) {
    if (BeginProviderControl(ddskk::EngineControl::kQuit)) {
      branch = L"okuri-quit";
      *eaten = TRUE;
      debug_exit(*eaten);
      return S_OK;
    }
  }
  if (provider_composition_active_ && !ctrl_g && wparam != VK_ESCAPE &&
      !katakana_q) {
    if (wparam == VK_SPACE)
      DebugLog(L"LOCAL_PRECONDITION seq=%llu failed=provider-composition preedit=%d provider=1 mode=%ls",
          key_sequence_, realtime_frontend_.preedit(), last_engine_mode_.c_str());
    std::optional<ddskk::EngineControl> control;
    if (wparam == VK_RETURN)
      control = ddskk::EngineControl::kCommit;
    else if (wparam == VK_SPACE)
      control = ddskk::EngineControl::kConvert;
    else if (wparam == VK_BACK) {
      if (last_engine_mode_ == L"preedit" && realtime_frontend_.okuri_started())
        realtime_frontend_.BackspaceOkuri();
      control = ddskk::EngineControl::kBackspace;
    }
    else if (ctrl_j)
      control = ddskk::EngineControl::kCancel;
    else if (wparam == VK_LEFT)
      control = engine_id_ == "lattice"
          ? (key_shift ? ddskk::EngineControl::kSegmentShrink
                         : ddskk::EngineControl::kSegmentPrev)
          : ddskk::EngineControl::kPrevious;
    else if (wparam == VK_RIGHT)
      control = engine_id_ == "lattice"
          ? (key_shift ? ddskk::EngineControl::kSegmentExtend
                         : ddskk::EngineControl::kSegmentNext)
          : ddskk::EngineControl::kConvert;
    else if (wparam >= VK_F6 && wparam <= VK_F10) {
      constexpr ddskk::EngineControl controls[] = {
          ddskk::EngineControl::kToHiragana,
          ddskk::EngineControl::kToKatakana,
          ddskk::EngineControl::kToHalfKatakana,
          ddskk::EngineControl::kToWideLatin,
          ddskk::EngineControl::kToLatin};
      control = controls[wparam - VK_F6];
    }
    if (control && BeginProviderControl(*control)) {
      if (*control == ddskk::EngineControl::kCommit) confirmation_pending_ = true;
      branch = L"provider-control";
      *eaten = TRUE;
      debug_exit(*eaten);
      return S_OK;
    }
    const auto codepoint = event_codepoint();
    if (codepoint) {
      if (engine_id_ == "ddskk" && last_engine_mode_ == L"preedit" &&
          realtime_frontend_.okuri_started()) {
        realtime_frontend_.Feed(*codepoint);
        record_okuri();
        RenderLocalOkuri(context);
      }
      if (engine_id_ == "ddskk" && last_engine_mode_ == L"preedit" &&
          BeginProviderKey(*codepoint, true)) {
        branch = L"provider-preedit-key";
        *eaten = TRUE;
        debug_exit(*eaten);
        return S_OK;
      }
      deferred_provider_keys_.push_back(DeferredProviderKey{
          wparam, *codepoint, true, key_shift, ctrl_j});
      if (BeginProviderControl(ddskk::EngineControl::kCommit)) {
        confirmation_pending_ = true;
        branch = L"provider-accept-and-queue";
        *eaten = TRUE;
        debug_exit(*eaten);
        return S_OK;
      }
      deferred_provider_keys_.pop_back();
    }
  }
  if (registration_mode_) {
    branch = L"registration";
    if (ctrl_j) {
      // CorvusSKK marks Ctrl+J as invalid while the registration editor
      // owns input: swallow it without confirming or leaking it.
      *eaten = TRUE;
      debug_exit(*eaten);
      return S_OK;
    }
    if (!dispatching_registration_key_) {
      const bool semantic_control = ctrl_g || wparam == VK_BACK || wparam == VK_DELETE ||
          wparam == VK_SPACE || wparam == VK_RETURN || wparam == VK_ESCAPE ||
          wparam == VK_LEFT || wparam == VK_RIGHT || wparam == VK_UP || wparam == VK_DOWN ||
          wparam == VK_HOME || wparam == VK_END || wparam == VK_F6 || wparam == VK_F7;
      const auto codepoint = semantic_control ? std::optional<char32_t>{} : event_codepoint();
      deferred_provider_keys_.push_back(DeferredProviderKey{
          wparam, codepoint.value_or(0), codepoint.has_value(), key_shift,
          ctrl_j, control_down, key_caps});
      if (provider_window_ && !PostMessageW(provider_window_, kRegistrationReplayMessage, 0, 0))
        SetTimer(provider_window_, 8, 10, nullptr);
      branch = L"registration-queue";
      *eaten = TRUE;
      debug_exit(*eaten);
      return S_OK;
    }
    {
      std::optional<ddskk::EngineControl> control;
      if (ctrl_g)
        control = ddskk::EngineControl::kQuit;
      else if (wparam == VK_BACK)
        control = ddskk::EngineControl::kBackspace;
      else if (wparam == VK_DELETE)
        control = ddskk::EngineControl::kDelete;
      else if (wparam == VK_SPACE)
        control = ddskk::EngineControl::kConvert;
      else if (wparam == VK_RETURN)
        control = ddskk::EngineControl::kCommit;
      else if (wparam == VK_ESCAPE)
        control = ddskk::EngineControl::kQuit;
      else if (wparam == VK_LEFT)
        control = ddskk::EngineControl::kLeft;
      else if (wparam == VK_RIGHT)
        control = ddskk::EngineControl::kRight;
      else if (wparam == VK_UP || wparam == VK_HOME)
        control = ddskk::EngineControl::kHome;
      else if (wparam == VK_DOWN || wparam == VK_END)
        control = ddskk::EngineControl::kEnd;
      else if (wparam == VK_F6 || wparam == VK_F7)
        control = wparam == VK_F6 ? ddskk::EngineControl::kToHiragana
                                 : ddskk::EngineControl::kToKatakana;
      if (control && BeginProviderControl(*control)) {
        branch = L"registration-async-control";
        *eaten = TRUE;
        debug_exit(*eaten);
        return S_OK;
      }
      const auto codepoint = control ? std::optional<char32_t>{} : event_codepoint();
      if (codepoint && BeginProviderKey(*codepoint)) {
        branch = L"registration-async-key";
        *eaten = TRUE;
        debug_exit(*eaten);
        return S_OK;
      }
    }
    // Failure to launch the worker never falls back to a synchronous pipe
    // transaction on the callback. Retain the exact key and retry from the pump.
    const bool semantic_control = ctrl_g || wparam == VK_BACK || wparam == VK_DELETE ||
        wparam == VK_SPACE || wparam == VK_RETURN || wparam == VK_ESCAPE ||
        wparam == VK_LEFT || wparam == VK_RIGHT || wparam == VK_UP || wparam == VK_DOWN ||
        wparam == VK_HOME || wparam == VK_END || wparam == VK_F6 || wparam == VK_F7;
    const auto codepoint = semantic_control ? std::optional<char32_t>{} : event_codepoint();
    if (semantic_control || codepoint) {
      deferred_provider_keys_.push_front(DeferredProviderKey{
          wparam, codepoint.value_or(0), codepoint.has_value(), key_shift,
          ctrl_j, control_down, key_caps});
      if (provider_window_) SetTimer(provider_window_, 8, 10, nullptr);
    }
    branch = L"registration-retry";
    *eaten = TRUE;
    debug_exit(*eaten);
    return S_OK;
  } else if (ctrl_j) {
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
    // actually reports afterward. This stays kCancel, not the stepwise
    // kQuit that Esc/Ctrl+G now send below: skk-kakutei's unconditional
    // return-to-kana is a different operation from keyboard-quit's
    // stepwise ▼->▽->clear/pending-drop, even though both happen to look
    // like "cancel" from outside.
    if ((realtime_frontend_.composing() || realtime_frontend_.katakana() ||
         realtime_frontend_.latin() || realtime_frontend_.wide_latin()) &&
        !provider_composition_active_ && last_engine_mode_ != L"candidate") {
      state = realtime_frontend_.Commit();
      const auto hiragana = realtime_frontend_.ToHiragana();
      if (state) state->mode = L"hiragana";
      else state = hiragana;
    } else {
      if (BeginProviderControl(ddskk::EngineControl::kCancel)) {
        *eaten = TRUE;
        debug_exit(*eaten);
        return S_OK;
      }
      // Keep an idle Ctrl+J local even if the worker could not be scheduled.
      state = realtime_frontend_.ToHiragana();
    }
    if (!state) {
      // OnTestKeyDown already claimed Ctrl+J; letting it fall through here
      // would leak the raw keystroke into the document instead of just
      // swallowing it for this one failed round-trip. A transaction
      // timeout/resync here is also exactly the class of failure that can
      // leave a candidate UI element stranded open behind a composition
      // no later state will ever again describe -- see CloseCandidateUi().
      CloseCandidateUi();
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
    if (realtime_frontend_.composing() && !provider_composition_active_ &&
        last_engine_mode_ != L"candidate")
      state = local_okuri_snapshot_.index ? realtime_frontend_.BackspaceOkuri() : realtime_frontend_.Backspace();
    else
      state = engine_.SendControl(ddskk::EngineControl::kBackspace,
                                  kInteractiveTimeoutMs);
  } else if (wparam == VK_SPACE) {
    branch = L"space";
    if (engine_id_ == "ddskk" && realtime_frontend_.wide_latin()) {
      state = realtime_frontend_.Feed(U' ');
    } else {
      // Space belongs to the IME only while something is actually being
      // composed; otherwise let the application insert a plain space.
      if (composition_ == nullptr && !engine_pending_) {
        debug_exit(*eaten);
        return S_OK;
      }
      if (realtime_frontend_.preedit() && !provider_composition_active_ &&
          last_engine_mode_ != L"candidate") {
        const auto started = std::chrono::steady_clock::now();
        TracePhase(L"lookup-start", key_sequence_, L"local");
        const auto local_reading = realtime_frontend_.preview_reading();
        const auto captured = local_store_.Capture();
        DebugLog(L"LOCAL_SNAPSHOT seq=%llu mapped=%d available=%d overlay=%llu opens=%llu handoff=%llu",
            key_sequence_, captured.index ? 1 : 0, captured.available,
            captured.index ? captured.index->header().overlay_sequence : 0,
            local_store_.MappingOpensForDiagnostics(), local_handoff_requested_);
        std::vector<std::wstring> pending;
        for (const auto& item : captured.pending) if (item.key == local_reading) {
          pending.erase(std::remove(pending.begin(), pending.end(), item.candidate), pending.end());
          pending.insert(pending.begin(), item.candidate);
        }
        if (local_enabled_ && captured.available && captured.index && local_rule_snapshot_ &&
            captured.index->Rules() == local_rule_snapshot_->Rules() &&
            local_conversion_.Begin(captured.index, local_reading, pending)) {
          // Cleanup replies have no ownership over this new local episode.
          if (provider_cleanup_pending_) CancelPendingProvider();
          provider_candidate_state_.reset();
          local_store_.RequestServer(local_reading);
          local_server_next_ = false;
          if (provider_window_) SetTimer(provider_window_, 6, 50, nullptr);
          branch = L"local-convert";
          TracePhase(L"lookup-end", key_sequence_, L"local");
          state = local_conversion_.State();
          const HRESULT hr = ApplyLocalState(context, *state);
          if (FAILED(hr)) ScheduleLocalRetry();
          *eaten = TRUE;
          if (GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", nullptr, 0)) {
            const auto us = std::chrono::duration_cast<std::chrono::microseconds>(
                std::chrono::steady_clock::now() - started).count();
            std::printf("SPACE-CANDIDATE ms=%lld seq=%llu path=local us=%lld\n",
                static_cast<long long>(us / 1000), ++local_conversion_sequence_,
                static_cast<long long>(us));
          }
          debug_exit(*eaten, hr, hr); return S_OK;
        }
        const wchar_t* local_failure = !local_enabled_ ? L"disabled" :
            !captured.available ? L"snapshot-unavailable" : !captured.index ? L"index-missing" :
            !local_rule_snapshot_ ? L"rules-unpinned" :
            captured.index->Rules() != local_rule_snapshot_->Rules() ? L"rules-mismatch" : L"entry-uncertified-or-empty";
        DebugLog(L"LOCAL_PRECONDITION seq=%llu failed=%ls preedit=%d provider=%d enabled=%d available=%d index=%d rules=%d capabilities=%llu reading=%ls",
            key_sequence_, local_failure, realtime_frontend_.preedit(), provider_composition_active_,
            local_enabled_, captured.available, captured.index ? 1 : 0, local_rule_snapshot_ ? 1 : 0,
            captured.index ? captured.index->header().capabilities : 0, local_reading.c_str());
        TracePhase(L"lookup-miss", key_sequence_, L"local");
        branch = L"provider-convert";
        const auto preview_reading = local_enabled_ ? std::wstring{} : realtime_frontend_.preview_reading();
        TracePhase(L"provider-dispatch-start", key_sequence_, L"key");
        const bool dispatched = BeginProviderConversion(realtime_frontend_.raw_keys(), false, 0, preview_reading);
        TracePhase(L"provider-dispatch-end", key_sequence_, L"key");
        if (dispatched) {
          ShowProviderBusy(context);
          *eaten = TRUE;
          debug_exit(*eaten);
          return S_OK;
        }
        state = engine_.ConvertKeys(realtime_frontend_.raw_keys(),
                                    kConversionTimeoutMs);
        if (state) realtime_frontend_.Reset();
      } else {
        DebugLog(L"LOCAL_PRECONDITION seq=%llu failed=%ls preedit=%d provider=%d mode=%ls",
            key_sequence_, !realtime_frontend_.preedit() ? L"not-preedit" :
                provider_composition_active_ ? L"provider-composition" : L"candidate-mode",
            realtime_frontend_.preedit(), provider_composition_active_, last_engine_mode_.c_str());
        state = engine_.SendControl(ddskk::EngineControl::kConvert,
                                    kConversionTimeoutMs);
      }
    }
  } else if (wparam == VK_LEFT || wparam == VK_RIGHT) {
    if (engine_id_ == "ddskk") {
      branch = L"candidate";
      if ((GetKeyState(VK_SHIFT) & 0x8000) ||
          (composition_ == nullptr && !engine_pending_)) {
        debug_exit(*eaten);
        return S_OK;
      }
      state = engine_.SendControl(wparam == VK_LEFT
          ? ddskk::EngineControl::kPrevious : ddskk::EngineControl::kConvert,
          wparam == VK_RIGHT ? kConversionTimeoutMs : kInteractiveTimeoutMs);
    } else {
      branch = (GetKeyState(VK_SHIFT) & 0x8000) ? L"segment-resize" : L"segment";
      if (engine_id_ != "lattice" ||
          (composition_ == nullptr && !engine_pending_)) {
        debug_exit(*eaten);
        return S_OK;
      }
      if (GetKeyState(VK_SHIFT) & 0x8000) {
        state = engine_.SendControl(wparam == VK_LEFT
            ? ddskk::EngineControl::kSegmentShrink
            : ddskk::EngineControl::kSegmentExtend, kInteractiveTimeoutMs);
      } else {
        state = engine_.SendControl(wparam == VK_LEFT
            ? ddskk::EngineControl::kSegmentPrev
            : ddskk::EngineControl::kSegmentNext, kInteractiveTimeoutMs);
      }
    }
  } else if (wparam >= VK_F6 && wparam <= VK_F10) {
    branch = L"transliterate";
    if ((engine_id_ != "lattice" &&
         !(engine_id_ == "ddskk" && (wparam == VK_F6 || wparam == VK_F7))) ||
        (composition_ == nullptr && !engine_pending_)) {
      debug_exit(*eaten);
      return S_OK;
    }
    const ddskk::EngineControl controls[] = {
        ddskk::EngineControl::kToHiragana, ddskk::EngineControl::kToKatakana,
        ddskk::EngineControl::kToHalfKatakana, ddskk::EngineControl::kToWideLatin,
        ddskk::EngineControl::kToLatin};
    if (engine_id_ == "ddskk" && realtime_frontend_.preedit() &&
        !provider_composition_active_) {
      state = wparam == VK_F6 ? std::optional<ddskk::EngineState>(
                                   realtime_frontend_.ToHiragana())
                              : realtime_frontend_.ToKatakana();
    } else if (engine_id_ == "lattice" && realtime_frontend_.preedit() &&
               !provider_composition_active_ &&
               last_engine_mode_ != L"candidate") {
      deferred_provider_keys_.push_back(DeferredProviderKey{
          wparam, 0, false, key_shift, false});
      if (BeginProviderConversion(realtime_frontend_.raw_keys())) {
        ShowProviderBusy(context);
        *eaten = TRUE;
        debug_exit(*eaten);
        return S_OK;
      }
      deferred_provider_keys_.pop_back();
    } else {
      state = engine_.SendControl(controls[wparam - VK_F6],
                                  kInteractiveTimeoutMs);
    }
  } else if (katakana_q || local_katakana_q) {
    branch = local_katakana_q ? L"q-katakana-local" : L"q-katakana";
    // DDSKK's Shift+Q during ▽/▼ conversion is a kana-class
    // conversion, not a literal uppercase Q.  Dispatch the same lossless
    // operation as F7 so an active candidate is first restored to its
    // reading and then converted without dropping the composition.
    if (realtime_frontend_.preedit())
      state = realtime_frontend_.CommitKatakana();
    else
      state = engine_.SendControl(ddskk::EngineControl::kToKatakana,
                                  kInteractiveTimeoutMs);
  } else if (wparam == VK_RETURN) {
    branch = L"return";
    if (composition_ == nullptr && !engine_pending_) {
      debug_exit(*eaten);
      return S_OK;
    }
    if (realtime_frontend_.composing() && !provider_composition_active_ &&
        last_engine_mode_ != L"candidate")
      state = realtime_frontend_.Commit();
    else
      state = engine_.SendControl(ddskk::EngineControl::kCommit,
                                  kInteractiveTimeoutMs);
  } else if (wparam == VK_ESCAPE) {
    branch = L"escape";
    if (composition_ == nullptr && !engine_pending_) {
      debug_exit(*eaten);
      return S_OK;
    }
    // kQuit, not kCancel: DDSKK's actual keyboard-quit is stepwise (▼->▽
    // with the reading restored, ▽->clear, a pending romaji prefix->drop
    // the last syllable, idle->no-op), not skk-kakutei's unconditional
    // return-to-kana that Ctrl+J above still uses -- see that branch's
    // comment. Research confirmed CorvusSKK dispatches both Esc and
    // Ctrl+G to the identical cancel function code (imcrvtip.h:42, and
    // its README key table lists them as equivalent); DDSKK's C-g-only
    // keyboard-quit binding is an Emacs implementation artifact (Escape
    // was never free there), not a deliberate behavioral difference
    // between the two keys, so both get the same stepwise quit here. If
    // the connected engine predates the QUIT verb it replies with an ERR
    // line, which ParseStateResponse() turns into std::nullopt exactly
    // like any other transaction failure -- the existing `if (!state)'
    // swallow-on-failure path below already handles that with no special
    // casing needed.
    if (((provider_composition_active_ && last_engine_mode_ == L"candidate") ||
         cancelled_conversion) &&
        realtime_frontend_.preedit()) {
      ReleaseEngineConversion();
      state = realtime_frontend_.RestorePreedit();
    } else if (realtime_frontend_.composing()) {
      if (cancelled_provider) ReleaseEngineConversion();
      state = realtime_frontend_.Quit();
    } else {
      if (!BeginProviderControl(ddskk::EngineControl::kQuit))
        ForceCancelComposition(context);
      *eaten = TRUE;
      debug_exit(*eaten);
      return S_OK;
    }
  } else if (ctrl_g) {
    branch = L"ctrlg";
    // DDSKK keyboard-quit is deliberately stepwise: candidate -> original
    // reading -> empty.  RESET here erased the reading on the first press.
    if (composition_ == nullptr && !engine_pending_) {
      debug_exit(*eaten);
      return S_OK;
    }
    if (((provider_composition_active_ && last_engine_mode_ == L"candidate") ||
         cancelled_conversion) &&
        realtime_frontend_.preedit()) {
      branch = L"ctrlg-local-restore";
      ReleaseEngineConversion();
      state = realtime_frontend_.RestorePreedit();
    } else if (realtime_frontend_.composing() &&
               !provider_composition_active_) {
      branch = L"ctrlg-local";
      if (cancelled_provider) ReleaseEngineConversion();
      state = realtime_frontend_.Quit();
    } else if (engine_roundtrip_failed_) {
      // A preceding conversion already proved the pipe unresponsive.
      // Retrying QUIT would merely add another timeout while leaving the
      // TSF composition behind.  End it locally and resync lazily when the
      // engine becomes reachable again.
      branch = L"ctrlg-force";
      ForceCancelComposition(context);
      *eaten = TRUE;
      debug_exit(*eaten);
      return S_OK;
    }
    if (!state) {
      // Provider-owned states without a native reading (for example an
      // abbrev) need DDSKK's stepwise QUIT, but only on the provider worker.
      // A failed schedule uses local abandonment instead of synchronous I/O.
      if (!BeginProviderControl(ddskk::EngineControl::kQuit))
        ForceCancelComposition(context);
      *eaten = TRUE;
      debug_exit(*eaten);
      return S_OK;
    }
  } else {
    branch = L"key";
    const auto codepoint = event_codepoint();
    if (!codepoint) {
      // FIELD BUG this branch used to cause: the harness (and any
      // well-behaved host) only ever reaches OnKeyDown for a VK
      // OnTestKeyDown already claimed, so unconditionally eating a
      // TranslateKey() miss looked safe there. But many real applications
      // call ITfKeyEventSink::KeyDown for EVERY key without ever
      // consulting TestKeyDown first -- on that call order this branch
      // saw arrows, Home/End/PageUp/PageDown/Delete/Insert, F-keys,
      // numpad and Win keys too (none of them resolve through
      // ToUnicodeEx), and unconditionally swallowing them here is exactly
      // what killed caret movement and every other unclaimed key in those
      // apps, even though OnTestKeyDown (when it did run) had always
      // correctly left them unclaimed. Ask the identical claim predicate
      // OnTestKeyDown itself uses instead of assuming: a VK the claim set
      // never wanted passes through untouched (fixes the dead keys),
      // while a VK it DOES want but that still fails to resolve a
      // character is still swallowed, to avoid leaking raw ASCII the
      // engine was never given a chance to process.
      const bool key_composing = composition_ != nullptr || engine_pending_;
      *eaten = WouldClaimKey(wparam, key_composing, have_event_state ? event_state : nullptr) ? TRUE : FALSE;
      debug_exit(*eaten);
      return S_OK;
    }
    const bool realtime_path = !provider_composition_active_ &&
        last_engine_mode_ != L"candidate" && !registration_mode_;
    if (realtime_path) {
      std::optional<ddskk::RealtimeFrontend> frontend_before;
      ddskk::local::Selection okuri_before;
      TracePhase(L"native-snapshot-start", key_sequence_, L"local");
      if (local_enabled_) { frontend_before = realtime_frontend_; okuri_before = local_okuri_snapshot_; }
      TracePhase(L"native-snapshot-end", key_sequence_, L"local");
      TracePhase(L"native-feed-start", key_sequence_, L"local");
      state = realtime_frontend_.Feed(*codepoint);
      record_okuri();
      TracePhase(L"native-feed-end", key_sequence_, L"local");
      // Hand off at the marker, including uppercase vowels that complete
      // okuri immediately. Subsequent keys stay ordered on the provider
      // worker; DDSKK decides when n/sokuon rules start conversion.
      if (engine_id_ == "ddskk" && realtime_frontend_.okuri_started()) {
        const auto reading = realtime_frontend_.okuri_key();
        if (local_enabled_ && !local_okuri_snapshot_.index) {
          auto captured = local_store_.Capture();
          if (captured.available && captured.index && local_rule_snapshot_ &&
              captured.index->Rules() == local_rule_snapshot_->Rules()) {
            const auto entry = captured.index->Lookup(reading, L"あ");
            if (entry.supported && (!entry.user.empty() || !entry.shared.empty()))
              local_okuri_snapshot_ = std::move(captured);
          }
        }
        if (local_okuri_snapshot_.index && state) {
          branch = L"local-okuri-preedit";
          if (state->pending_romaji.empty() && !realtime_frontend_.okuri_text().empty()) {
            std::vector<std::wstring> pending;
            for (const auto& item : local_okuri_snapshot_.pending) if (item.key == reading) {
              pending.erase(std::remove(pending.begin(), pending.end(), item.candidate), pending.end());
              pending.insert(pending.begin(), item.candidate);
            }
            if (local_conversion_.Begin(local_okuri_snapshot_.index, reading, pending, realtime_frontend_.okuri_text())) {
              if (provider_cleanup_pending_) CancelPendingProvider();
              provider_candidate_state_.reset();
              branch = L"local-okuri-convert";
              local_store_.RequestServer(reading, realtime_frontend_.okuri_text());
              local_server_next_ = false;
              if (provider_window_) SetTimer(provider_window_, 6, 50, nullptr);
              state = local_conversion_.State();
            } else local_okuri_snapshot_ = {};
          }
          if (local_okuri_snapshot_.index) {
            TracePhase(L"native-okuri-edit-start", key_sequence_, L"local");
            const HRESULT hr = ApplyLocalState(context, *state);
            TracePhase(L"native-okuri-edit-end", key_sequence_, L"local");
            if (FAILED(hr)) {
              local_conversion_.Reset();
              realtime_frontend_ = *frontend_before;
              local_okuri_snapshot_ = okuri_before;
              okuri_conversion_started_qpc_ = 0;
            } else if (local_conversion_.active()) TraceOkuriCandidate(true);
            *eaten = TRUE; debug_exit(*eaten, hr, hr); return S_OK;
          }
        }

        local_okuri_snapshot_ = {};
        RenderLocalOkuri(context);
        auto keys = realtime_frontend_.raw_keys();
        if (realtime_frontend_.katakana()) keys.insert(keys.begin(), U'q');
        if (BeginProviderKeys(keys, true)) {
          branch = L"okuri-sync";
          *eaten = TRUE;
          debug_exit(*eaten);
          return S_OK;
        }
      }
      if (!state && !realtime_frontend_.latin()) {
        auto keys = realtime_frontend_.raw_keys();
        if (realtime_frontend_.katakana()) keys.insert(keys.begin(), U'q');
        if (BeginProviderKeys(keys, true)) {
          *eaten = TRUE;
          debug_exit(*eaten);
          return S_OK;
        }
      }
      if (state) PrepareProviderReading();
    } else
      state = engine_.SendKey(*codepoint, kInteractiveTimeoutMs);
  }
  if (!state) {
    // OnTestKeyDown already claimed this key, so letting it fall through
    // here would leak the raw keystroke into the document instead of just
    // swallowing it for this one failed round-trip. Also closes any
    // candidate UI element rather than leaving it stranded open behind a
    // composition no later state will ever describe again -- see
    // CloseCandidateUi(). Still correct under the direct-KeyDown-without-
    // TestKeyDown call pattern too (see the `else' branch's comment
    // above): every branch that can set `state' and reach here already
    // matched an explicitly claimed VK on its own terms (Ctrl+J/Ctrl+G's
    // own composing check, BACK/SPACE/RETURN/ESCAPE's composing check, or
    // WouldClaimKey() itself just above), so this key was always meant to
    // be ours regardless of which call order got us here.
    engine_roundtrip_failed_ = true;
    if (ctrl_g) {
      // QUIT itself timed out even though no earlier request had marked
      // the connection bad.  Ctrl+G is the final escape hatch, so do not
      // leave the application inside the stale TSF composition.
      ForceCancelComposition(context);
    } else {
      CloseCandidateUi();
    }
    *eaten = TRUE;
    debug_exit(*eaten);
    return S_OK;
  }
  // The key was claimed in OnTestKeyDown and the engine has already
  // consumed it; even if the edit session fails, letting the raw
  // keystroke through would insert ASCII the engine also processed --
  // this exact path produced the "▽Kana " leak.
  *eaten = TRUE;
  engine_roundtrip_failed_ = false;
  ObserveRegistrationLearning(*state);
  // Single point of truth for engine_pending_ and kana_mode_: every branch
  // above that reaches here (including the Ctrl+J case) has just obtained
  // a fresh state from the engine, so this always reflects the latest
  // reality instead of a locally-tracked guess. Deriving kana_mode_ here
  // is the actual fix for the mode-desync bug: previously it was only
  // ever written by LoadSettings/Ctrl+J/ToggleInputMode, so a plain key
  // like `l' that silently switched the engine's own mode left it stale,
  // and OnTestKeyDown kept claiming keys the engine no longer wanted.
  const bool was_registration = registration_mode_;
  const bool was_candidate = last_engine_mode_ == L"candidate";
  const bool was_provider_composition = provider_composition_active_;
  registration_mode_ = state->mode == L"registration";
  provider_composition_active_ = !registration_mode_ &&
      state->composition_start >= 0 && !state->candidates.empty();
  registration_commit_pending_ =
      was_registration && !registration_mode_ &&
      state->composition_start < 0 && state->pending_romaji.empty();
  if (was_registration && !registration_mode_ &&
      !registration_commit_pending_ && registration_range_ != nullptr) {
    registration_range_->Release();
    registration_range_ = nullptr;
  }
  engine_pending_ = registration_mode_ || state->composition_start >= 0 ||
                    !state->pending_romaji.empty();
  kana_mode_ = ddskk::DeriveKanaMode(*state);
  if (!registration_mode_) last_engine_mode_ = state->mode;
  if ((was_candidate || was_registration || was_provider_composition) &&
      state->mode != L"candidate" && state->composition_start < 0) {
    local_okuri_snapshot_ = {};
  realtime_frontend_.Reset();
  }
  if (registration_mode_) {
    last_engine_mode_ = state->mode;
    QueuePublishedState(&*state);
    if (inline_epoch_ && inline_channel_.Publish(inline_epoch_,
          state->text + state->pending_romaji, InlineCursor(*state)))
      inline_state_ = *state;
    CloseCandidateUi();
    if (!was_registration && registration_range_ == nullptr &&
        composition_ != nullptr) {
      const HRESULT saved = composition_->GetRange(&registration_range_);
      DebugLog(L"Registration save_range hr=%X",
               static_cast<unsigned>(saved));
      if (FAILED(saved)) registration_range_ = nullptr;
    }
    // Keep the reading parked in its TSF composition while Sumi owns the
    // modal registration editor.  The final engine state then replaces the
    // same range exactly once.  If a host terminates the parked composition
    // first, OnCompositionTerminated removes that provisional range instead.
    debug_exit(*eaten);
    return S_OK;
  }
  auto* edit_session = new (std::nothrow) StateEditSession(this, context, *state);
  if (edit_session == nullptr) return E_OUTOFMEMORY;
  HRESULT edit_result = E_FAIL;
  const HRESULT request = RequestEdit(context, edit_session, &edit_result);
  edit_session->Release();
  debug_exit(*eaten, request, edit_result);
  // Covers both the Ctrl+J toggle above and every SendKey-driven mode
  // change (l / L / q / / etc.) below it: by this point `state` always
  // holds the latest engine state, regardless of which branch produced
  // it. This never influences *eaten, which was already decided above.
  MaybeShowModeIndicator(context, &*state);
  if (local_enabled_ && SUCCEEDED(request) && SUCCEEDED(edit_result) &&
      !provider_composition_active_ && !provider_pending_.load()) PublishLocalObserver(*state);
  return S_OK;
}

// HARNESS EVIDENCE this exists to fix: OnTestKeyDown provably claims no
// navigation key (LEFT/RIGHT/UP/DOWN/DEL/HOME/END all eaten=0, idle and
// mid-composition), yet arrow keys still went dead for the user in
// specific host windows. The remaining mechanism was the candidate UI
// element leaking OPEN: UpdateCandidateUI() only ever called
// EndUIElement() when a LATER engine state happened to arrive reporting
// empty candidates -- but every OnKeyDown failure path that returns with
// `*eaten = TRUE` before reaching UpdateCandidateUI() (a transaction
// timeout/resync: the Ctrl+J branch's and the common `if (!state)`
// return) skips it entirely, and OnCompositionTerminated() never touched
// candidate_ui_id_ either. Once the engine session was reset out from
// under the DLL (see EngineClient's own needs_resync_ handling), no
// subsequent state ever carries candidates for that context again, so
// the element stayed open for the life of the app -- and while a TSF UI
// element is open, hosts route navigation keys to the IME's candidate
// handling instead of the caret. This is the single close path: called
// from UpdateCandidateUI()'s own empty-candidates case below, from every
// OnKeyDown failure path that abandons a composition, from
// OnCompositionTerminated(), and from Deactivate().
void TextService::ResetAbandonedComposition() {
  confirmation_pending_ = confirmation_replay_ = false;
  confirmation_delivery_pending_ = false;
  if (confirmation_anchor_) confirmation_anchor_->Release();
  confirmation_anchor_ = nullptr;
  ++edit_generation_;
  CancelLocalRetry();
  local_store_.ReleaseState();
  local_conversion_.Reset();
  ClearInlineEpisode();
  // Do not send RESET here.  This callback can arrive late from an old
  // Edge/Electron/Terminal context after another application has already
  // started using the process-wide engine session; an immediate RESET then
  // erases that other application's live reading/candidate.  Mark this
  // client dirty and let EngineClient reset immediately before THIS client
  // next transacts, when it actually owns input again.
  CancelPendingProvider();
  engine_.MarkNeedsResync();
  local_okuri_snapshot_ = {};
  realtime_frontend_.Reset();
  if (composition_ != nullptr) {
    composition_->Release();
    composition_ = nullptr;
  }
  if (registration_range_ != nullptr) {
    registration_range_->Release();
    registration_range_ = nullptr;
  }
  registration_commit_pending_ = false;
  CloseCandidateUi();
  registration_mode_ = false;
  engine_pending_ = false;
  provider_composition_active_ = false;
  deferred_provider_keys_.clear();
  engine_roundtrip_failed_ = false;
  published_composing_ = 0;
  QueuePublishedState(nullptr);
}

void TextService::ForceCancelComposition(ITfContext* context) {
  local_conversion_.Reset();
  ClearInlineEpisode();
  // Cancel outstanding I/O without acquiring the transaction mutex. RESET
  // is lazy and scoped to this client; neither disconnect nor an engine
  // round trip may block this document's cancellation callback.
  CancelPendingProvider();
  engine_.MarkNeedsResync();
  local_okuri_snapshot_ = {};
  realtime_frontend_.Reset();
  CloseCandidateUi();
  registration_mode_ = false;
  registration_commit_pending_ = false;
  if (registration_range_ != nullptr) {
    registration_range_->Release();
    registration_range_ = nullptr;
  }

  bool cleared = composition_ == nullptr;
  if (composition_ != nullptr && context != nullptr) {
    ITfComposition* abandoned = composition_;
    TrackEndingComposition(abandoned);
    auto* edit_session = new (std::nothrow)
        TerminateCompositionEditSession(abandoned, false);
    if (edit_session != nullptr) {
      HRESULT edit_result = E_FAIL;
      HRESULT request = context->RequestEditSession(
          client_id_, edit_session, TF_ES_SYNC | TF_ES_READWRITE,
          &edit_result);
      if (FAILED(request) || FAILED(edit_result)) {
        edit_result = E_FAIL;
        request = context->RequestEditSession(
            client_id_, edit_session, TF_ES_ASYNC | TF_ES_READWRITE,
            &edit_result);
      }
      DebugLog(L"ForceCancel old-context edit request=%X result=%X",
               static_cast<unsigned>(request),
               static_cast<unsigned>(edit_result));
      edit_session->Release();
      cleared = SUCCEEDED(request) && SUCCEEDED(edit_result);
      if (cleared && composition_ == abandoned) {
        composition_->Release();
        composition_ = nullptr;
      }
    }
    if (!cleared) UntrackEndingComposition(abandoned);
  }
  if (!cleared) {
    // If the application denied the synchronous edit, at least relinquish
    // local ownership so arrows and Windows Ctrl shortcuts are usable.
    ResetAbandonedComposition();
  }
  registration_mode_ = false;
  engine_pending_ = false;
  provider_composition_active_ = false;
  deferred_provider_keys_.clear();
  engine_roundtrip_failed_ = false;
  kana_mode_ = true;
  last_engine_mode_ = L"hiragana";
  published_composing_ = 0;
  QueuePublishedState(nullptr);
}

void TextService::SettleContextComposition(ITfContext* context) {
  CancelLocalRetry();
  local_observer_retry_.reset();
  const bool local_committed = local_conversion_.active() && SUCCEEDED(CommitLocal(context));
  local_conversion_.Reset();
  if (!local_committed && inline_epoch_ && context) {
    // Match the ordinary focus-settle path: confirm the visible reading,
    // excluding only the SKK marker, in its original document.
    auto settled = inline_state_;
    settled.text += settled.pending_romaji;
    if (!settled.text.empty() && (settled.text[0] == L'▽' || settled.text[0] == L'▼'))
      settled.text.erase(0, 1);
    settled.pending_romaji.clear(); settled.composition_start = -1;
    settled.candidates.clear(); settled.segments.clear();
    auto* edit = new (std::nothrow) StateEditSession(this, context, settled);
    if (edit) {
      HRESULT result = E_FAIL;
      RequestEdit(context, edit, &result);
      edit->Release();
    }
  }
  ClearInlineEpisode();
  CancelPendingProvider();
  engine_.MarkNeedsResync();
  local_okuri_snapshot_ = {};
  realtime_frontend_.Reset();
  CloseCandidateUi();

  bool settled = composition_ == nullptr;
  if (composition_ != nullptr && context != nullptr) {
    ITfComposition* abandoned = composition_;
    TrackEndingComposition(abandoned);
    auto* edit_session = new (std::nothrow)
        TerminateCompositionEditSession(abandoned, true);
    if (edit_session != nullptr) {
      HRESULT edit_result = E_FAIL;
      HRESULT request = context->RequestEditSession(
          client_id_, edit_session, TF_ES_SYNC | TF_ES_READWRITE,
          &edit_result);
      if (FAILED(request) || FAILED(edit_result)) {
        edit_result = E_FAIL;
        request = context->RequestEditSession(
            client_id_, edit_session, TF_ES_ASYNC | TF_ES_READWRITE,
            &edit_result);
      }
      edit_session->Release();
      settled = SUCCEEDED(request) && SUCCEEDED(edit_result);
      if (settled && composition_ == abandoned) {
        composition_->Release();
        composition_ = nullptr;
      }
    }
    if (!settled) UntrackEndingComposition(abandoned);
  }
  if (!settled) ResetAbandonedComposition();
  if (registration_range_ != nullptr) {
    registration_range_->Release();
    registration_range_ = nullptr;
  }
  registration_commit_pending_ = false;
  registration_mode_ = false;
  engine_pending_ = false;
  provider_composition_active_ = false;
  deferred_provider_keys_.clear();
  engine_roundtrip_failed_ = false;
  kana_mode_ = true;
  last_engine_mode_ = L"hiragana";
}

namespace {
bool SameComIdentity(IUnknown* left, IUnknown* right) {
  if (left == nullptr || right == nullptr) return left == right;
  IUnknown* left_identity = nullptr;
  IUnknown* right_identity = nullptr;
  left->QueryInterface(IID_IUnknown, reinterpret_cast<void**>(&left_identity));
  right->QueryInterface(IID_IUnknown, reinterpret_cast<void**>(&right_identity));
  const bool same = left_identity != nullptr && left_identity == right_identity;
  if (left_identity != nullptr) left_identity->Release();
  if (right_identity != nullptr) right_identity->Release();
  return same;
}
}  // namespace

bool TextService::StateEditAllowed(ITfContext* context, uint64_t generation) const {
  return thread_manager_ && generation == edit_generation_ &&
         SameComIdentity(context, active_context_);
}

void TextService::TrackEndingComposition(ITfComposition* composition) {
  if (shim_.track_ending_composition) {
    shim_.track_ending_composition(shim_.owner, composition, TRUE); return;
  }
  if (composition == nullptr) return;
  for (ITfComposition* existing : ending_compositions_) {
    if (SameComIdentity(existing, composition)) return;
  }
  composition->AddRef();
  ending_compositions_.push_back(composition);
}

void TextService::UntrackEndingComposition(ITfComposition* composition) {
  if (shim_.track_ending_composition) {
    shim_.track_ending_composition(shim_.owner, composition, FALSE); return;
  }
  for (auto it = ending_compositions_.begin(); it != ending_compositions_.end();
       ++it) {
    if (!SameComIdentity(*it, composition)) continue;
    (*it)->Release();
    ending_compositions_.erase(it);
    return;
  }
}

bool TextService::AcknowledgeEndingComposition(ITfComposition* composition) {
  for (auto it = ending_compositions_.begin(); it != ending_compositions_.end();
       ++it) {
    if (!SameComIdentity(*it, composition)) continue;
    (*it)->Release();
    ending_compositions_.erase(it);
    return true;
  }
  return false;
}

void TextService::CloseCandidateUi() {
  wchar_t harness_diagnostics[2]{};
  if (GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS",
                              harness_diagnostics, 2) > 0) {
    std::printf("CANDIDATEUI close open=%d\n",
                candidate_ui_id_ != TF_INVALID_UIELEMENTID ? 1 : 0);
    std::fflush(stdout);
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
  candidate_index_ = -1;
  candidate_count_ = 0;
}

void TextService::UpdateCandidateUI(ITfContext* context,
                                    const ddskk::EngineState& state) {
  if (state.candidates.empty()) {
    CloseCandidateUi();
    return;
  }
  wchar_t harness_diagnostics[2]{};
  if (GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS",
                              harness_diagnostics, 2) > 0) {
    std::printf("CANDIDATEUI preview=%d count=%zu\n",
                state.mode == L"provider-preview" ? 1 : 0,
                state.candidates.size());
    std::fflush(stdout);
  }
  if (thread_manager_ == nullptr) return;
  ITfUIElementMgr* manager = nullptr;
  if (FAILED(thread_manager_->QueryInterface(
          IID_ITfUIElementMgr, reinterpret_cast<void**>(&manager)))) return;
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
  if (candidate_ui_ != nullptr) candidate_ui_->Update(state, document, local_conversion_.active());
  if (document != nullptr) document->Release();
  TracePhase(L"candidate-show-start", KeySequence(), state.mode.c_str());
  if (candidate_ui_ != nullptr) {
    if (candidate_ui_id_ == TF_INVALID_UIELEMENTID) {
      BOOL show = TRUE;
      const HRESULT begun =
          manager->BeginUIElement(candidate_ui_, &show, &candidate_ui_id_);
      if (harness_diagnostics[0] != L'\0') {
        std::printf("CANDIDATEUI begin hr=%08lx show=%d id=%lu\n",
                    static_cast<unsigned long>(begun), show ? 1 : 0,
                    static_cast<unsigned long>(candidate_ui_id_));
        std::fflush(stdout);
      }
    } else {
      manager->UpdateUIElement(candidate_ui_id_);
    }
  }
  manager->Release();
  TracePhase(L"candidate-show-end", KeySequence(), state.mode.c_str());
}

HRESULT TextService::SelectCandidate(UINT index) {
  if (local_conversion_.active()) {
    const auto saved = local_conversion_;
    if (!local_conversion_.Select(index)) return E_INVALIDARG;
    const HRESULT hr = ApplyLocalState(candidate_context_, local_conversion_.State());
    if (FAILED(hr)) local_conversion_ = saved;
    return hr;
  }
  if (provider_pending_.load(std::memory_order_acquire)) return E_PENDING;
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
  if (local_conversion_.active()) return CommitLocal(candidate_context_);
  if (provider_pending_.load(std::memory_order_acquire)) return E_PENDING;
  if (candidate_context_ == nullptr) return E_UNEXPECTED;
  const auto state = engine_.SendControl(ddskk::EngineControl::kCommit, 1000);
  return state ? RequestStateEdit(*state) : E_FAIL;
}

HRESULT TextService::AbortCandidate() {
  if (local_conversion_.active()) {
    const auto saved = local_conversion_;
    const auto frontend = realtime_frontend_;
    local_conversion_.Reset();
    const auto state = realtime_frontend_.okuri_started() ? realtime_frontend_.CancelOkuri() : realtime_frontend_.RestorePreedit();
    const HRESULT hr = ApplyLocalState(candidate_context_, state);
    if (FAILED(hr)) { local_conversion_ = saved; realtime_frontend_ = frontend; }
    return hr;
  }
  if (provider_pending_.load(std::memory_order_acquire)) return E_PENDING;
  if (candidate_context_ == nullptr) return E_UNEXPECTED;
  const auto state = engine_.SendControl(ddskk::EngineControl::kCancel, 1000);
  return state ? RequestStateEdit(*state) : E_FAIL;
}

HRESULT TextService::ApplyLocalState(ITfContext* context, const ddskk::EngineState& state,
                                   bool confirmation) {
  if (!context) return E_UNEXPECTED;
  if (confirmation) RememberConfirmation(state);
  auto* edit = new (std::nothrow) StateEditSession(this, context, state, L"local", 0, confirmation);
  if (!edit) return E_OUTOFMEMORY;
  HRESULT result = E_FAIL;
  const HRESULT request = RequestEdit(context, edit, &result, L"local");
  edit->Release();
  if (FAILED(request) || FAILED(result)) {
    if (confirmation) ConfirmationFinished(context, EditGeneration(), FAILED(request) ? request : result, nullptr);
    if (GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", nullptr, 0))
      std::printf("LOCAL_EDIT denied=1 retry=reading pending=0 request=%08lx edit=%08lx\n", request, result);
    return FAILED(request) ? request : result;
  }
  engine_pending_ = state.composition_start >= 0 || !state.pending_romaji.empty();
  provider_composition_active_ = false;
  last_engine_mode_ = state.mode;
  kana_mode_ = ddskk::DeriveKanaMode(state);
  MaybeShowModeIndicator(context, &state);
  if (local_enabled_) PublishLocalObserver(state);
  return S_OK;
}

void TextService::PublishLocalObserver(const ddskk::EngineState& state) {
  TracePhase(L"native-observer-start", key_sequence_, L"local");
  if (local_store_.PublishState(state)) {
    local_observer_retry_.reset(); if (provider_window_) KillTimer(provider_window_, 4);
  } else {
    local_observer_retry_ = state;
    local_observer_deadline_ = GetTickCount64() + 5000;
    if (provider_window_) SetTimer(provider_window_, 4, 50, nullptr);
  }
  TracePhase(L"native-observer-end", key_sequence_, L"local");
}
void TextService::CancelLocalRetry() {
  local_conversion_retry_.reset(); local_retry_deadline_ = 0;
  if (provider_window_) KillTimer(provider_window_, 3);
}
void TextService::ScheduleLocalRetry() {
  local_conversion_retry_ = local_conversion_;
  local_conversion_.Reset();
  local_retry_deadline_ = GetTickCount64() + 5000;
  if (provider_window_) SetTimer(provider_window_, 3, 50, nullptr);
}
void TextService::RetryLocalConversion() {
  if (!local_conversion_retry_) return;
  struct RetryTrace {
    LARGE_INTEGER start{};
    RetryTrace() { QueryPerformanceCounter(&start); }
    ~RetryTrace() {
      if (!GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", nullptr, 0)) return;
      LARGE_INTEGER end{}, frequency{}; QueryPerformanceCounter(&end); QueryPerformanceFrequency(&frequency);
      std::printf("LOCAL_RETRY total_us=%llu\n", static_cast<unsigned long long>((end.QuadPart - start.QuadPart) * 1000000 / frequency.QuadPart));
    }
  } trace;
  if (!active_context_ || !keyboard_open_ || !realtime_frontend_.preedit() ||
      GetTickCount64() >= local_retry_deadline_) {
    if (GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", nullptr, 0))
      std::printf("LOCAL_EDIT abandoned=1 pending=0\n");
    CancelLocalRetry(); return;
  }
  local_conversion_ = *local_conversion_retry_;
  const HRESULT hr = ApplyLocalState(active_context_, local_conversion_.State());
  if (SUCCEEDED(hr)) {
    CancelLocalRetry();
    if (GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", nullptr, 0))
      std::printf("LOCAL_EDIT recovered=1 pending=0\n");
  } else local_conversion_.Reset();
}

void TextService::ObserveRegistrationLearning(const ddskk::EngineState& state,
    const std::optional<ddskk::EngineState>& learning) {
  if (learning && local_enabled_) {
    const bool queued = local_store_.Learn(learning->registration_reading, learning->text,
                                          learning->pending_romaji);
    if (GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", nullptr, 0))
      std::printf("REGISTRATION_LEARNING queued=%d pending=%zu\n", queued ? 1 : 0, local_store_.Unsaved());
  }
  if (state.mode == L"registration") {
    registration_reading_ = state.registration_reading;
    if (!registration_mode_) registration_okuri_ = realtime_frontend_.okuri_text();
    return;
  }
  if (!registration_mode_) return;
  if (local_enabled_ && !learning) {
    const bool queued = local_store_.LearnRegistration(state, registration_reading_, registration_okuri_);
    if (GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", nullptr, 0))
      std::printf("REGISTRATION_LEARNING queued=%d pending=%zu\n", queued ? 1 : 0, local_store_.Unsaved());
  }
  registration_reading_.clear();
  registration_okuri_.clear();
}

HRESULT TextService::CommitLocal(ITfContext* context, bool confirmation) {
  if (confirmation) confirmation_pending_ = true;
  const auto saved = local_conversion_;
  const auto key = local_conversion_.reading();
  const auto word = local_conversion_.selected();
  const auto okuri = local_conversion_.okuri();
  const auto state = local_conversion_.Commit();
  const HRESULT result = ApplyLocalState(context, state, confirmation);
  if (FAILED(result)) { local_conversion_ = saved; return result; }
  local_okuri_snapshot_ = {};
  realtime_frontend_.Reset();
  ApplyRequestedInlineMode();
  const bool queued = local_store_.Learn(key, word, okuri);
  if (GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", nullptr, 0))
    std::printf("LOCAL_LEARNING queued=%d pending=%zu\n", queued ? 1 : 0, local_store_.Unsaved());
  return S_OK;
}

HRESULT TextService::RequestStateEdit(const ddskk::EngineState& state) {
  if (candidate_context_ == nullptr) return E_UNEXPECTED;
  // Mirrors the OnKeyDown update: SelectCandidate / FinalizeCandidate /
  // AbortCandidate all apply engine states through this helper, so it must
  // keep engine_pending_ current too (e.g. FinalizeCandidate committing the
  // composition must clear it).
  engine_pending_ = state.composition_start >= 0 || !state.pending_romaji.empty();
  provider_composition_active_ = state.composition_start >= 0 &&
      !state.candidates.empty();
  auto* edit_session =
      new (std::nothrow) StateEditSession(this, candidate_context_, state);
  if (edit_session == nullptr) return E_OUTOFMEMORY;
  HRESULT edit_result = E_FAIL;
  const HRESULT request = candidate_context_->RequestEditSession(
      client_id_, edit_session, TF_ES_ASYNC | TF_ES_READWRITE, &edit_result);
  edit_session->Release();
  return request;
}
HRESULT TextService::OnTestKeyUp(ITfContext*, WPARAM wparam, LPARAM, BOOL* eaten) {
  tested_key_valid_ = false;
  if (eaten == nullptr) return E_POINTER;
  (void)wparam;
  tested_control_down_ = false;
  *eaten = FALSE;
  return S_OK;
}
HRESULT TextService::OnKeyUp(ITfContext*, WPARAM wparam, LPARAM, BOOL* eaten) {
  if (eaten == nullptr) return E_POINTER;
  (void)wparam;
  tested_control_down_ = false;
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
      guid != GUID_DdskkCandidateAttribute &&
      guid != GUID_DdskkConvertedAttribute) return E_INVALIDARG;
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
  *description = SysAllocString(L"NeLisp IME settings");
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
// FinalizeCandidate/AbortCandidate/OnKeyDown. TSF leaves the displayed range
// in the document, so settle it as plain text (without the ▽/▼ UI marker)
// before dropping our state; otherwise tab changes visibly strand "▽かな".
HRESULT TextService::OnCompositionTerminated(TfEditCookie edit_cookie,
                                             ITfComposition* composition) {
  DebugLog(L"OnCompositionTerminated comp=%d", composition_ != nullptr ? 1 : 0);
  // EndComposition below may call this sink synchronously (the harness) or
  // asynchronously after EndComposition returns (Electron/Claude).  Keep
  // the actual COM object alive and match that acknowledgement by identity;
  // resetting it would schedule an empty STATE over the range just committed
  // and erase both the candidate and its reading.
  if (AcknowledgeEndingComposition(composition)) return S_OK;
  if (registration_mode_) {
    // Some hosts terminate the parked document composition while the modal
    // registration editor is active.  If its displayed reading is allowed
    // to commit, the final registered word is inserted after it and appears
    // twice when both strings match.  Remove that provisional range using
    // the write cookie supplied by TSF, but keep the engine registration
    // alive; its final state will insert exactly one registered word at the
    // now-collapsed caret.
    ITfComposition* owned = composition != nullptr ? composition : composition_;
    ITfRange* range = nullptr;
    if (owned != nullptr && SUCCEEDED(owned->GetRange(&range))) {
      range->SetText(edit_cookie, 0, L"", 0);
      range->Release();
    }
    if (composition_ != nullptr) {
      composition_->Release();
      composition_ = nullptr;
    }
    CloseCandidateUi();
    engine_pending_ = true;
    return S_OK;
  }
  ITfComposition* owned = composition != nullptr ? composition : composition_;
  ITfRange* range = nullptr;
  if (owned != nullptr && SUCCEEDED(owned->GetRange(&range))) {
    wchar_t text[4096]{};
    ULONG fetched = 0;
    if (SUCCEEDED(range->GetText(edit_cookie, 0, text,
                                 static_cast<ULONG>(_countof(text) - 1),
                                 &fetched))) {
      const ULONG marker = fetched > 0 && (text[0] == L'\x25bd' ||
                                           text[0] == L'\x25bc') ? 1 : 0;
      range->SetText(edit_cookie, 0, text + marker,
                     static_cast<LONG>(fetched - marker));
    }
    range->Release();
  }
  if (composition_ != nullptr) {
    composition_->Release();
    composition_ = nullptr;
  }
  // Reset this TextService's scoped provider/native state at the same
  // boundary so it cannot reappear when focus returns.
  ResetAbandonedComposition();
  return S_OK;
}

std::optional<char32_t> TextService::TranslateKey(WPARAM wparam,
                                                  LPARAM lparam,
                                                  const BYTE* event_state,
                                                  HKL event_layout) {
  BYTE keyboard_state[256]{};
  if (event_state) std::copy_n(event_state, 256, keyboard_state);
  else if (!GetKeyboardState(keyboard_state)) return std::nullopt;
  WCHAR text[4]{};
  const UINT scan_code = (static_cast<UINT>(lparam) >> 16) & 0xff;
  const int count = ToUnicodeEx(static_cast<UINT>(wparam), scan_code,
                                keyboard_state, text, 4, 0,
                                event_layout ? event_layout : GetKeyboardLayout(0));
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
void TextService::ClearInlineEpisode() {
  inline_channel_.Clear(inline_epoch_);
  inline_epoch_ = 0; preedit_episode_ = false; inline_state_ = {};
}

void TextService::ApplyRequestedInlineMode() {
  if (!requested_inline_mode_.epoch) return;
  if (requested_inline_mode_.epoch != inline_channel_.Epoch()) {
    requested_inline_mode_ = {}; return;
  }
  if (!thread_manager_ || !keyboard_open_ || !ddskk_engine_ ||
      engine_id_ != "ddskk" || pending_state_edits_ || engine_pending_ || registration_mode_ || composition_ ||
      realtime_frontend_.composing() || provider_pending_.load()) return;
  const auto request = std::move(requested_inline_mode_);
  requested_inline_mode_ = {};
  const auto mode = request.mode == L"latin" ? L"latin" : L"hiragana";
  realtime_frontend_.SetInputMode(mode);
  kana_mode_ = request.mode != L"latin";
  last_engine_mode_ = mode;
  mode_before_close_kana_ = kana_mode_; engine_mode_before_close_ = mode;
  engine_.MarkNeedsResync();
  ddskk::EngineState state; state.mode = mode;
  if (local_enabled_) PublishLocalObserver(state);
  MaybeShowModeIndicator(nullptr, &state);
  inline_channel_.ReplyMode(request.epoch, request.mode);
  TracePhase(L"inline-mode-applied", key_sequence_, mode);
  if (GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", nullptr, 0)) {
    std::printf("INLINE_MODE mode=%ls open=%d label=%ls\n", mode, keyboard_open_, CurrentModeLabel().c_str());
    std::fflush(stdout);
  }
}
void TextService::HandleInlineEvent() {
  InlinePreedit::ModeRequest request{};
  if (inline_channel_.TakeModeRequest(&request)) requested_inline_mode_ = std::move(request);
  ApplyRequestedInlineMode();
  if (!inline_epoch_ || !thread_manager_) return;
  RECT caret{};
  if (inline_channel_.Caret(inline_epoch_, &caret)) {
    last_caret_rect_ = caret; last_caret_valid_ = true;
    PublishCaretRect(caret);
  }
  if (inline_channel_.Epoch() == inline_epoch_ || !active_context_) return;
  // Transport loss materializes the latest full preedit immediately, even
  // without another key. The episode remains pinned to ordinary composition.
  auto* edit = new (std::nothrow) StateEditSession(this, active_context_, inline_state_);
  if (!edit) return;
  HRESULT result = E_FAIL;
  RequestEdit(active_context_, edit, &result);
  edit->Release();
}

HRESULT TextService::ApplyEngineState(TfEditCookie edit_cookie,
                                      ITfContext* context,
                                      const ddskk::EngineState& state,
                                      ddskk::AutoPairCaretUpdate* pair_caret,
                                      ITfRange* insertion_start,
                                      ITfRange** committed_end,
                                      bool force_result_composition) {
  if (committed_end) *committed_end = nullptr;
  const auto closer = auto_pair_.Closer(state);
  const auto save_end = [&](ITfRange* range) {
    if (!committed_end) return S_OK;
    HRESULT hr = range->Clone(committed_end);
    if (SUCCEEDED(hr)) hr = (*committed_end)->Collapse(edit_cookie, TF_ANCHOR_END);
    return hr;
  };
  // A TSF edit session may retain this core after its shim deactivated.
  if (thread_manager_ == nullptr) return S_FALSE;
  const bool has_preedit = state.composition_start >= 0 || !state.pending_romaji.empty();
  const bool inline_commit = !has_preedit && !composition_ &&
      (inline_epoch_ || (!preedit_episode_ && inline_enabled_ && inline_channel_.Epoch()));
  const auto commit_epoch = inline_epoch_ ? inline_epoch_ : inline_channel_.Epoch();
  if (!preedit_episode_ && has_preedit) {
    preedit_episode_ = true;
    inline_epoch_ = inline_enabled_ ? inline_channel_.Epoch() : 0;
  }
  if (inline_epoch_) {
    if (has_preedit && inline_channel_.Publish(inline_epoch_,
          state.text + state.pending_romaji,
          InlineCursor(state))) {
      inline_state_ = state;
      RECT caret{};
      if (inline_channel_.Caret(inline_epoch_, &caret)) {
        last_caret_rect_ = caret; last_caret_valid_ = true;
        // The existing Sumi candidate window consumes this rectangle. Do
        // not create a second core popup or alter its styling/selection.
        PublishCaretRect(caret);
        wchar_t diagnostics[2]{};
        if (candidate_count_ && GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", diagnostics, 2)) {
          std::printf("INLINE_CANDIDATE_ANCHOR x=%ld y=%ld height=%ld below_y=%ld candidates=%zu\n",
              caret.left, caret.top, caret.bottom - caret.top, caret.bottom,
              candidate_count_);
          std::fflush(stdout);
        }
      }
      return S_OK; // No document edit and, crucially, no StartComposition.
    }
    if (has_preedit) {
      // Apply this same full engine snapshot through normal composition.
      // No engine replay: replaying the last key would duplicate text.
      inline_channel_.Clear(inline_epoch_);
      inline_epoch_ = 0;
    } else {
      inline_channel_.Clear(inline_epoch_);
      inline_epoch_ = 0;
    }
  }
  if (!has_preedit) preedit_episode_ = false;
  if (inline_commit) {
    if (state.text.empty()) return S_OK;
    ITfInsertAtSelection* insertion = nullptr;
    HRESULT result = context->QueryInterface(IID_ITfInsertAtSelection,
        reinterpret_cast<void**>(&insertion));
    if (FAILED(result)) return result;
    ITfRange* inserted = nullptr;
    // Inline overlays own preedit. Neither their confirmation nor fresh
    // terminal keys may create an explicit or default TSF composition.
    result = insertion->InsertTextAtSelection(edit_cookie,
        TF_IAS_NO_DEFAULT_COMPOSITION, state.text.data(),
        static_cast<LONG>(state.text.size()), &inserted);
    insertion->Release();
    if (SUCCEEDED(result) && inserted) {
      inserted->Collapse(edit_cookie, TF_ANCHOR_END);
      CaptureCaretRect(edit_cookie, context, inserted);
      result = save_end(inserted);
    }
    if (inserted) inserted->Release();
    if (SUCCEEDED(result)) inline_channel_.Pair(commit_epoch, state.text, closer);
    return result;
  }
  wchar_t diagnostics[2]{};
  if (GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", diagnostics, 2) > 0) {
    std::printf("ENGINE_APPLY mode=%ls text_units=%zu segments=%zu active=%d\n",
                state.mode.c_str(), state.text.size(), state.segments.size(),
                state.active_segment);
    // The harness flushes at its feed boundary, outside callback timing.
  }
  const bool registration_target =
      registration_commit_pending_ && registration_range_ != nullptr;
  const bool direct_commit = state.composition_start < 0 &&
                             state.pending_romaji.empty() &&
                             composition_ == nullptr && !registration_target && !inline_commit && !force_result_composition;
  const std::wstring committed = direct_commit ? state.text : std::wstring();
  // The wire protocol carries `text' and `pending_romaji' as separate
  // STATE fields; render both together so a pending-only romaji prefix
  // (e.g. text empty, pending_romaji "k" before it resolves to a kana)
  // is actually visible instead of silently dropped.
  const auto composition_closer = !direct_commit && !registration_target && !inline_commit
      ? closer : std::wstring{};
  const std::wstring display =
      direct_commit ? std::wstring() : state.text + state.pending_romaji + composition_closer;
  DebugLog(L"ApplyEngineState entry comp=%d dlen=%zu",
           composition_ != nullptr ? 1 : 0, display.size());
  ITfRange* range = nullptr;
  if (composition_ != nullptr) {
    const HRESULT get_range = composition_->GetRange(&range);
    TracePhase(L"composition-range", KeySequence(), L"host", get_range);
    DebugLog(L"ApplyEngineState get_range hr=%X",
             static_cast<unsigned>(get_range));
    if (FAILED(get_range)) return get_range;
  } else if (registration_target) {
    // The application ended the TSF composition while Sumi's registration
    // editor was active.  Replace the range captured at registration entry;
    // inserting at the current selection would leave the provisional text
    // behind and produce the registered word twice in real applications.
    range = registration_range_;
    range->AddRef();
    DebugLog(L"ApplyEngineState registration_target=1");
  } else {
    TF_SELECTION selection{};
    ULONG fetched = 0;
    const HRESULT get_selection = insertion_start ? insertion_start->Clone(&selection.range) :
        context->GetSelection(edit_cookie, TF_DEFAULT_SELECTION, 1, &selection,
                              &fetched);
    if (insertion_start && SUCCEEDED(get_selection)) fetched = 1;
    if (FAILED(get_selection) || fetched != 1) return FAILED(get_selection)
                                                        ? get_selection
                                                        : E_FAIL;
    range = selection.range;
    if (!committed.empty()) {
      if (!closer.empty()) {
        const HRESULT pair = auto_pair_.Insert(edit_cookie, context, range, committed, closer,
                                              auto_pair_caret_, pair_caret);
        if (SUCCEEDED(pair) && pair_caret) pair_caret->Arm();
        CaptureCaretRect(edit_cookie, context, range);
        range->Release();
        return pair;
      }
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
      const HRESULT saved = save_end(range);
      range->Release();
      return saved;
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
      ITfCompositionSink* stable_sink = nullptr;
      if (shim_.query_service) shim_.query_service(shim_.owner,
          &IID_ITfCompositionSink, reinterpret_cast<void**>(&stable_sink));
      result = composition_context->StartComposition(
          edit_cookie, range, stable_sink ? stable_sink : static_cast<ITfCompositionSink*>(this),
          &composition_);
      if (stable_sink) stable_sink->Release();
      composition_context->Release();
      TracePhase(L"composition-create", KeySequence(), L"host", result);
      DebugLog(L"ApplyEngineState start_composition hr=%X",
               static_cast<unsigned>(result));
    }
    if (FAILED(result)) {
      range->Release();
      return result;
    }
  }
  TracePhase(L"range-update-start", KeySequence(), L"host");
  const HRESULT set_text = range->SetText(
      edit_cookie, 0, display.data(), static_cast<LONG>(display.size()));
  TracePhase(L"range-update-end", KeySequence(), L"host", set_text);
  DebugLog(L"ApplyEngineState set_text hr=%X", static_cast<unsigned>(set_text));
  if (SUCCEEDED(set_text)) {
    // SetText can shrink the display (ぼく -> 僕). Bind both composition
    // anchors to the updated replacement range before the next provider
    // result arrives; retaining an old end leaves stale text at commit.
    if (composition_ != nullptr) {
      composition_->ShiftStart(edit_cookie, range);
      composition_->ShiftEnd(edit_cookie, range);
    }
    ApplyDisplayAttribute(edit_cookie, context, range,
        !state.segments.empty() ? GUID_DdskkConvertedAttribute :
        state.mode == L"candidate" ? GUID_DdskkCandidateAttribute
                                    : GUID_DdskkPreeditAttribute);
    if (!state.segments.empty() && state.active_segment >= 0) {
      const auto& segment = state.segments[state.active_segment];
      ITfRange* target = nullptr;
      if (SUCCEEDED(range->Clone(&target))) {
        LONG moved = 0;
        target->Collapse(edit_cookie, TF_ANCHOR_START);
        target->ShiftEnd(edit_cookie, segment.start + segment.length, &moved, nullptr);
        target->ShiftStart(edit_cookie, segment.start, &moved, nullptr);
        ApplyDisplayAttribute(edit_cookie, context, target, GUID_DdskkCandidateAttribute);
        target->Release();
      }
    }
    ITfRange* caret = nullptr;
    if (SUCCEEDED(range->Clone(&caret))) {
      // Segment metadata gives the active displayed end in UTF-16. Legacy
      // DDSKK states retain the end-of-display caret: their cursor can
      // instead denote an okurigana boundary inside committed text.
      const LONG relative_cursor = state.segments.empty()
          ? static_cast<LONG>(display.size() - composition_closer.size())
          : state.segments[state.active_segment].start +
            state.segments[state.active_segment].length;
      LONG moved = 0;
      caret->Collapse(edit_cookie, TF_ANCHOR_START);
      caret->ShiftEnd(edit_cookie, relative_cursor, &moved, nullptr);
      caret->Collapse(edit_cookie, TF_ANCHOR_END);
      TF_SELECTION selection{};
      selection.range = caret;
      selection.style.ase = TF_AE_NONE;
      selection.style.fInterimChar = FALSE;
      context->SetSelection(edit_cookie, 1, &selection);
      if (state.candidates.empty() || !last_caret_valid_)
        CaptureCaretRect(edit_cookie, context, caret);
      else
        TracePhase(L"caret-reused", KeySequence(), L"host");
      caret->Release();
    }
  }
  if (SUCCEEDED(set_text) && !composition_closer.empty() && pair_caret)
    pair_caret->Prepare(composition_closer, auto_pair_caret_);
  const HRESULT saved_end = SUCCEEDED(set_text) && !has_preedit ? save_end(range) : S_OK;
  range->Release();
  if (FAILED(set_text)) return set_text;
  if (FAILED(saved_end)) return saved_end;
  // A pending-only state (composition_start < 0 but pending_romaji still
  // non-empty) must keep the composition alive: `display' above already
  // rendered the pending prefix inside it, so ending the composition here
  // too would commit that unresolved romaji straight into the document.
  // The composition only ends once a later state reports the pending
  // prefix has resolved (pending_romaji empty) with no new composition
  // start.
  if (state.composition_start < 0 && state.pending_romaji.empty() &&
      composition_ != nullptr) {
    TrackEndingComposition(composition_);
    const HRESULT end = composition_->EndComposition(edit_cookie);
    TracePhase(L"composition-end", KeySequence(), L"host", end);
    DebugLog(L"ApplyEngineState end_composition hr=%X",
             static_cast<unsigned>(end));
    if (FAILED(end)) UntrackEndingComposition(composition_);
    else if (!composition_closer.empty() && pair_caret) pair_caret->Arm();
    composition_->Release();
    composition_ = nullptr;
    if (registration_commit_pending_) {
      if (registration_range_ != nullptr) registration_range_->Release();
      registration_range_ = nullptr;
      registration_commit_pending_ = false;
    }
    return end;
  }
  if (registration_commit_pending_) {
    if (registration_range_ != nullptr) registration_range_->Release();
    registration_range_ = nullptr;
    registration_commit_pending_ = false;
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
  TracePhase(L"caret-start", KeySequence(), L"host");
  last_caret_valid_ = false;
  if (context == nullptr || range == nullptr) return;
  ITfContextView* view = nullptr;
  if (FAILED(context->GetActiveView(&view)) || view == nullptr) return;
  RECT rect{};
  BOOL clipped = FALSE;
  const HRESULT result = view->GetTextExt(edit_cookie, range, &rect, &clipped);
  view->Release();
  TracePhase(L"caret-end", KeySequence(), L"host", result);
  if (FAILED(result)) return;
  last_caret_rect_ = rect;
  last_caret_valid_ = true;
  PublishCaretRect(rect);
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
  QueuePublishedState(state);
  const std::wstring label = CurrentModeLabel();
  if (label == last_mode_label_) return;
  last_mode_label_ = label;

  ITfContext* caret_context = context != nullptr ? context : active_context_;
  mode_indicator_anchor_valid_ = ResolveModeIndicatorAnchor(
      [this, context = caret_context](RECT* rect) {
        // Inline events also fill last_caret_rect_; query TSF afresh so an
        // old inline snapshot cannot masquerade as the highest-priority caret.
        last_caret_valid_ = false;
        if (context == nullptr) return false;
        class CaretReadSession final : public ITfEditSession {
         public:
          CaretReadSession(TextService* service, ITfContext* context)
              : service_(service), context_(context) {}
          HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override {
            if (out == nullptr) return E_POINTER;
            *out = nullptr;
            if (iid != IID_IUnknown && iid != IID_ITfEditSession) return E_NOINTERFACE;
            *out = static_cast<ITfEditSession*>(this); AddRef(); return S_OK;
          }
          ULONG STDMETHODCALLTYPE AddRef() override { return ++refs_; }
          ULONG STDMETHODCALLTYPE Release() override {
            const ULONG refs = --refs_;
            if (!refs) delete this;
            return refs;
          }
          HRESULT STDMETHODCALLTYPE DoEditSession(TfEditCookie cookie) override {
            TF_SELECTION selection{}; ULONG fetched = 0;
            if (SUCCEEDED(context_->GetSelection(cookie, TF_DEFAULT_SELECTION,
                                                1, &selection, &fetched)) &&
                fetched == 1 && selection.range != nullptr) {
              if (SUCCEEDED(selection.range->Collapse(cookie, TF_ANCHOR_END)))
                service_->CaptureCaretRect(cookie, context_, selection.range);
              selection.range->Release();
            }
            return S_OK;
          }
         private:
          ULONG refs_ = 1;
          TextService* service_;
          ITfContext* context_;
        };
        auto* session = new (std::nothrow) CaretReadSession(this, context);
        if (session == nullptr) return false;
        HRESULT result = E_FAIL;
        const HRESULT request = context->RequestEditSession(
            client_id_, session, TF_ES_SYNC | TF_ES_READ, &result);
        session->Release();
        if (FAILED(request) || FAILED(result) || !last_caret_valid_) return false;
        *rect = last_caret_rect_;
        return true;
      },
      [this](RECT* rect) { return inline_channel_.LastCaret(rect); },
      FocusedSystemCaret, &mode_indicator_anchor_);
  // Taskbar NotifyUpdate and first popup creation can take tens of ms in a
  // fully activated Windows TSF host. Defer both beyond the key callback.
  if (!indicator_update_queued_ && provider_window_ != nullptr)
    indicator_update_queued_ = PostMessageW(provider_window_, kModeIndicatorMessage, 0, 0) != 0;
}

void TextService::FlushModeIndicator() {
  indicator_update_queued_ = false;
  if (thread_manager_ == nullptr) return;
  if (shim_.notify_mode) shim_.notify_mode(shim_.owner);

  // Independent of mode_indicator_enabled_ below: the taskbar icon and the
  // transient popup are two separate UI surfaces, and TSF should still
  // re-query GetIcon() for a real mode change even if the popup is off.
  if (input_mode_button_ != nullptr) {
    input_mode_button_->NotifyUpdate(TF_LBI_ICON | TF_LBI_STATUS);
  }

  const bool enabled = application_mode_indicator_ < 0
      ? mode_indicator_enabled_ : application_mode_indicator_ != 0;
  if (!enabled || !mode_indicator_anchor_valid_) {
    mode_indicator_.Hide();
    return;
  }
  mode_indicator_.Show(last_mode_label_, mode_indicator_anchor_);
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


bool TextService::CoreQuiescent() const {
  const LONG refs = InterlockedCompareExchange(const_cast<LONG*>(&ref_count_), 0, 0);
  const uint64_t flags = (composition_ ? 1 : 0) | (engine_pending_ ? 2 : 0) |
      (registration_mode_ ? 4 : 0) | (provider_pending_.load() ? 8 : 0) |
      (provider_composition_active_ ? 16 : 0) | (provider_cleanup_pending_ ? 32 : 0) |
      ((!deferred_provider_keys_.empty() || confirmation_pending_ || confirmation_replay_) ? 64 : 0) |
      (realtime_frontend_.composing() ? 128 : 0) |
      (candidate_ui_id_ != TF_INVALID_UIELEMENTID ? 256 : 0) |
      (!ending_compositions_.empty() ? 512 : 0) |
      (local_conversion_.active() ? 1024 : 0) |
      (local_conversion_retry_ ? 2048 : 0) |
      (local_observer_retry_ ? 4096 : 0) |
      (static_cast<uint64_t>(refs) << 16);
  wchar_t diagnostics[2]{};
  if (flags != quiescence_trace_ && GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", diagnostics, 2)) {
    std::printf("CORE_QUIESCENCE flags=%llu refs=%ld\n", static_cast<unsigned long long>(flags & 65535), refs);
    std::fflush(stdout); quiescence_trace_ = flags;
  }
  if (flags != (uint64_t{1} << 16)) return false;
  // Core swaps may run on the key thread. Drain durable learning on its
  // worker, and defer the swap until the OS thread is already terminated.
  // A formerly opted-in service may still have learning after opt-out.
  local_handoff_requested_ = GetTickCount64();
  return local_store_.PrepareHandoff();
}
HRESULT TextService::ExportCoreState(NativeImeSnapshot* state) {
  if (!state || state->size != sizeof(*state) || state->version != NATIVEIME_CORE_ABI)
    return E_INVALIDARG;
  if (!CoreQuiescent()) return E_PENDING;
  state->open = keyboard_open_; state->kana = kana_mode_;
  state->closed_kana = mode_before_close_kana_;
  state->needs_resync = engine_.CoreNeedsResync();
  wcscpy_s(state->mode, last_engine_mode_.c_str());
  wcscpy_s(state->closed_mode, engine_mode_before_close_.c_str());
  strcpy_s(state->session, engine_.CoreSession().c_str());
  HANDLE duplicate = INVALID_HANDLE_VALUE;
  const HRESULT result = engine_.ExportCorePipe(&duplicate);
  state->engine_pipe = reinterpret_cast<uintptr_t>(duplicate);
  return result;
}
HRESULT TextService::ImportCoreState(const NativeImeSnapshot* state) {
  if (!state || state->size != sizeof(*state) || state->version != NATIVEIME_CORE_ABI ||
      !memchr(state->session, 0, sizeof(state->session)) ||
      !wmemchr(state->mode, 0, 32) || !wmemchr(state->closed_mode, 0, 32))
    return E_INVALIDARG;
  keyboard_open_ = state->open != 0; kana_mode_ = state->kana != 0;
  mode_before_close_kana_ = state->closed_kana != 0;
  last_engine_mode_ = state->mode; engine_mode_before_close_ = state->closed_mode;
  realtime_frontend_.SetInputMode(last_engine_mode_);
  const HRESULT restored = engine_.RestoreCoreSession(state->session, state->needs_resync != 0, reinterpret_cast<HANDLE>(state->engine_pipe));
  if (FAILED(restored)) return restored;
  last_mode_label_ = CurrentModeLabel();
  publications_.clear(); last_publication_ = {}; published_composing_ = 0;
  QueuePublishedState(nullptr);
  return S_OK;
}
