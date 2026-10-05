#include "shim_service.h"
#include <filesystem>
#include <mutex>
#include <vector>
#include <cstdio>
LONG g_object_count = 0, g_lock_count = 0;
struct NativeImeModule {
  HMODULE handle = nullptr;
  NativeImeCoreApi api{};
  std::wstring path;
};
namespace {
std::atomic<uint32_t> publication_sequence{0}, publishers{0};
std::mutex publication_writer;
uint32_t publication_flushed = 0;
constexpr wchar_t kShimWindow[] = L"NativeImeStableShim";
// Reference-counted leases belong to each service and each dispatch. Retain one
// process-lifetime lease per validated module: TSF may retain candidate COM
// callbacks, and core windows/worker epilogues can escape the shim's call stack.
// The OS reclaims the cache on process exit; no loader-lock destructor runs.
std::vector<std::shared_ptr<NativeImeModule>>& Modules() {
  static auto* modules = new std::vector<std::shared_ptr<NativeImeModule>>;
  return *modules;
}
std::mutex& ModuleMutex() { static auto* m = new std::mutex; return *m; }
void Log(const char* event, const std::wstring& path, HRESULT hr, const char* version = "-") {
  wchar_t diagnostics[2]{};
  if (GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", diagnostics, 2)) {
    std::printf("CORE %s version=%s hr=%08lX pid=%lu\n", event, version,
        static_cast<unsigned long>(hr), GetCurrentProcessId()); std::fflush(stdout);
  }
  wchar_t local[32768]{};
  if (!GetEnvironmentVariableW(L"LOCALAPPDATA", local, 32768)) return;
  const auto directory = std::filesystem::path(local) / L"DDSKK";
  CreateDirectoryW(directory.c_str(), nullptr);
  const auto file_path = directory / L"dll-debug.log";
  HANDLE file = CreateFileW(file_path.c_str(), FILE_APPEND_DATA,
      FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, 0, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  wchar_t line[32768]{};
  _snwprintf_s(line, _TRUNCATE, L"%lu CORE %hs version=%hs hr=%08lX path=%ls\r\n",
      GetCurrentProcessId(), event, version, static_cast<unsigned long>(hr), path.c_str());
  int n = WideCharToMultiByte(CP_UTF8, 0, line, -1, nullptr, 0, nullptr, nullptr);
  std::vector<char> bytes(n);
  WideCharToMultiByte(CP_UTF8, 0, line, -1, bytes.data(), n, nullptr, nullptr);
  DWORD written = 0; WriteFile(file, bytes.data(), n - 1, &written, nullptr); CloseHandle(file);
}
HRESULT LoadCore(const std::wstring& path, std::shared_ptr<NativeImeModule>& result) {
  if (!std::filesystem::path(path).is_absolute()) return E_INVALIDARG;
  std::lock_guard<std::mutex> lock(ModuleMutex());
  for (const auto& m : Modules()) if (_wcsicmp(m->path.c_str(), path.c_str()) == 0) {
    result = m; return S_OK;
  }
  HMODULE handle = LoadLibraryExW(path.c_str(), nullptr,
      LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
  if (!handle) { auto hr = HRESULT_FROM_WIN32(GetLastError()); Log("reject-load", path, hr); return hr; }
  auto entry = reinterpret_cast<NativeImeGetCoreApiFn>(GetProcAddress(handle, "NativeImeGetCoreApi"));
  NativeImeCoreApi api{};
  HRESULT hr = entry ? entry(NATIVEIME_CORE_ABI, sizeof(api), &api) : E_NOINTERFACE;
  if (FAILED(hr) || api.size != sizeof(api) || api.version != NATIVEIME_CORE_ABI ||
      !api.diagnostic_version || !api.create || !api.destroy || !api.activate ||
      !api.deactivate || !api.invoke || !api.quiescent || !api.export_state ||
      !api.import_state || !api.can_unload || !api.prepare_unload) {
    Log("reject-abi", path, FAILED(hr) ? hr : E_NOINTERFACE);
    FreeLibrary(handle); return E_NOINTERFACE;
  }
  result = std::make_shared<NativeImeModule>();
  result->handle = handle; result->api = api; result->path = path;
  Modules().push_back(result); return S_OK;
}
}
ShimService::ShimService() { InterlockedIncrement(&g_object_count); }
ShimService::~ShimService() { Deactivate(); InterlockedDecrement(&g_object_count); }
ULONG ShimService::AddRef() { return InterlockedIncrement(&refs_); }
ULONG ShimService::Release() { auto n = InterlockedDecrement(&refs_); if (!n) delete this; return n; }
HRESULT ShimService::QueryInterface(REFIID iid, void** out) {
  if (!out) return E_POINTER; *out = nullptr;
  if (iid == IID_IUnknown || iid == IID_ITfTextInputProcessor || iid == IID_ITfTextInputProcessorEx)
    *out = static_cast<ITfTextInputProcessorEx*>(this);
  else if (iid == IID_ITfKeyEventSink) *out = static_cast<ITfKeyEventSink*>(this);
  else if (iid == IID_ITfCompositionSink) *out = static_cast<ITfCompositionSink*>(this);
  else if (iid == IID_ITfCompartmentEventSink) *out = static_cast<ITfCompartmentEventSink*>(this);
  else if (iid == IID_ITfDisplayAttributeProvider) *out = static_cast<ITfDisplayAttributeProvider*>(this);
  else if (iid == IID_ITfFunctionProvider) *out = static_cast<ITfFunctionProvider*>(this);
  else if (iid == IID_ITfFnConfigure || iid == IID_ITfFunction) *out = static_cast<ITfFnConfigure*>(this);
  else return E_NOINTERFACE;
  AddRef(); return S_OK;
}
uint32_t WINAPI ShimService::PublicationSequence(void*) { return ++publication_sequence; }
uint32_t WINAPI ShimService::PublisherDelta(void*, int32_t delta) { return delta > 0 ? ++publishers : --publishers; }
void WINAPI ShimService::PublicationLock(void*, BOOL lock) { if (lock) publication_writer.lock(); else publication_writer.unlock(); }
uint32_t WINAPI ShimService::PublicationFlushed(void*, uint32_t value) { if (value) publication_flushed = value; return publication_flushed; }
void WINAPI ShimService::TrackEnding(void* owner, void* composition, BOOL track) {
  auto* s = static_cast<ShimService*>(owner);
  IUnknown* identity = nullptr;
  if (!composition || FAILED(static_cast<ITfComposition*>(composition)->QueryInterface(
      IID_IUnknown, reinterpret_cast<void**>(&identity)))) return;
  auto it = std::find(s->ending_compositions_.begin(), s->ending_compositions_.end(), identity);
  if (track && it == s->ending_compositions_.end()) s->ending_compositions_.push_back(identity);
  else { identity->Release(); if (!track && it != s->ending_compositions_.end()) {
    (*it)->Release(); s->ending_compositions_.erase(it);
  } }
}
void WINAPI ShimService::NotifyMode(void* owner) {
  auto* s = static_cast<ShimService*>(owner);
  if (s->input_mode_button_) s->input_mode_button_->NotifyUpdate(TF_LBI_ICON | TF_LBI_TEXT);
}
HRESULT WINAPI ShimService::QueryService(void* owner, const GUID* iid, void** out) {
  return static_cast<ShimService*>(owner)->QueryInterface(*iid, out);
}
std::wstring ShimService::RequestedPath() const {
  wchar_t path[32768]{}; DWORD bytes = sizeof(path);
  if (RegGetValueW(HKEY_CURRENT_USER, NativeImeRegistryKey().c_str(), L"CoreDll",
      RRF_RT_REG_SZ, nullptr, path, &bytes) == ERROR_SUCCESS && path[0]) return path;
  GetModuleFileNameW(g_module, path, 32768);
  return (std::filesystem::path(path).parent_path() / L"ddskk-ime-core.dll").wstring();
}
HRESULT ShimService::CreateCore(const std::wstring& path, std::shared_ptr<NativeImeModule>& m, void** state) {
  HRESULT hr = LoadCore(path, m);
  if (FAILED(hr)) return hr;
  NativeImeCallbacks cb{sizeof(cb), NATIVEIME_CORE_ABI, this, QueryService, NotifyMode, TrackEnding,
      PublicationSequence, PublisherDelta, PublicationLock, PublicationFlushed};
  hr = m->api.create(&cb, state);
  if (FAILED(hr) || !*state) { Log("reject-init", path, FAILED(hr) ? hr : E_FAIL); return FAILED(hr) ? hr : E_FAIL; }
  return S_OK;
}
HRESULT ShimService::Activate(ITfThreadMgr* tm, TfClientId id) {
  if (!tm || tm_) return E_INVALIDARG;
  tm_ = tm; tm_->AddRef(); id_ = id;
  switching_ = true;
  requested_ = RequestedPath();
  HRESULT hr = CreateCore(requested_, module_, &state_);
  if (SUCCEEDED(hr)) hr = module_->api.activate(state_, tm_, id_);
  switching_ = false;
  if (FAILED(hr)) { Log("reject-activate", requested_, hr); Deactivate(); return hr; }
  ITfKeystrokeMgr* keys = nullptr;
  hr = tm_->QueryInterface(IID_ITfKeystrokeMgr, reinterpret_cast<void**>(&keys));
  if (SUCCEEDED(hr)) { hr = keys->AdviseKeyEventSink(id_, this, TRUE); keys->Release(); }
  if (FAILED(hr)) { Deactivate(); return hr; }
  ITfCompartmentMgr* compartments = nullptr; ITfCompartment* compartment = nullptr;
  if (SUCCEEDED(tm_->QueryInterface(IID_ITfCompartmentMgr, reinterpret_cast<void**>(&compartments)))) {
    if (SUCCEEDED(compartments->GetCompartment(GUID_COMPARTMENT_KEYBOARD_OPENCLOSE, &compartment))) {
      if (SUCCEEDED(compartment->QueryInterface(IID_ITfSource, reinterpret_cast<void**>(&compartment_source_))))
        compartment_source_->AdviseSink(IID_ITfCompartmentEventSink, static_cast<ITfCompartmentEventSink*>(this), &compartment_cookie_);
      compartment->Release();
    }
    compartments->Release();
  }
  AddButtons();
  WNDCLASSW wc{}; wc.hInstance = g_module; wc.lpfnWndProc = WindowProc; wc.lpszClassName = kShimWindow;
  RegisterClassW(&wc);
  window_ = CreateWindowExW(0, kShimWindow, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, g_module, this);
  if (!window_ || !SetTimer(window_, 1, 50, nullptr)) { Deactivate(); return E_FAIL; }
  watcher_.Start();
  Log("active", requested_, S_OK, module_->api.diagnostic_version);
  return S_OK;
}
HRESULT ShimService::Deactivate() {
  switching_ = true;
  watcher_.Stop();
  if (window_) { DestroyWindow(window_); window_ = nullptr; }
  RemoveButtons();
  for (auto* composition : ending_compositions_) composition->Release();
  ending_compositions_.clear();
  if (compartment_source_) {
    if (compartment_cookie_ != TF_INVALID_COOKIE) compartment_source_->UnadviseSink(compartment_cookie_);
    compartment_source_->Release(); compartment_source_ = nullptr; compartment_cookie_ = TF_INVALID_COOKIE;
  }
  if (state_) { module_->api.deactivate(state_); module_->api.destroy(state_); state_ = nullptr; }
  if (tm_) {
    ITfKeystrokeMgr* keys = nullptr;
    if (SUCCEEDED(tm_->QueryInterface(IID_ITfKeystrokeMgr, reinterpret_cast<void**>(&keys)))) {
      keys->UnadviseKeyEventSink(id_); keys->Release();
    }
    tm_->Release(); tm_ = nullptr;
  }
  module_.reset(); key_pair_ = false; pending_ = false; switching_ = false; return S_OK;
}
LRESULT CALLBACK ShimService::WindowProc(HWND window, UINT msg, WPARAM wp, LPARAM lp) {
  if (msg == WM_NCCREATE) SetWindowLongPtrW(window, GWLP_USERDATA,
      reinterpret_cast<LONG_PTR>(reinterpret_cast<CREATESTRUCTW*>(lp)->lpCreateParams));
  auto* s = reinterpret_cast<ShimService*>(GetWindowLongPtrW(window, GWLP_USERDATA));
  if (msg == WM_TIMER && s) { s->AddRef(); s->TrySwap(); s->Release(); return 0; }
  return DefWindowProcW(window, msg, wp, lp);
}
void ShimService::TrySwap() {
  if (!state_ || switching_ || calls_ || key_pair_) return;
  if (watcher_.dirty.exchange(false)) {
    auto next = RequestedPath();
    if (next != requested_) { requested_ = next; pending_ = true; }
  }
  if (!pending_ || !module_->api.quiescent(state_)) return;
  switching_ = true;
  NativeImeSnapshot snapshot{sizeof(snapshot), NATIVEIME_CORE_ABI};
  HRESULT hr = module_->api.export_state(state_, &snapshot);
  std::shared_ptr<NativeImeModule> replacement; void* next = nullptr;
  if (SUCCEEDED(hr)) hr = CreateCore(requested_, replacement, &next);
  if (SUCCEEDED(hr)) hr = replacement->api.activate(next, tm_, id_);
  if (SUCCEEDED(hr)) hr = replacement->api.import_state(next, &snapshot);
  if (SUCCEEDED(hr)) {
    module_->api.deactivate(state_); module_->api.destroy(state_);
    state_ = next; module_ = replacement;
    Log("swapped", requested_, S_OK, module_->api.diagnostic_version);
  } else {
    if (next) { replacement->api.deactivate(next); replacement->api.destroy(next); }
    Log("reject-swap", requested_, hr, module_->api.diagnostic_version);
  }
  if (snapshot.engine_pipe && snapshot.engine_pipe != reinterpret_cast<uintptr_t>(INVALID_HANDLE_VALUE))
    CloseHandle(reinterpret_cast<HANDLE>(snapshot.engine_pipe));
  pending_ = false; switching_ = false;
  if (SUCCEEDED(hr) && input_mode_button_) input_mode_button_->NotifyUpdate(TF_LBI_ICON | TF_LBI_TEXT);
}
HRESULT ShimService::Invoke(uint32_t op, NativeImeCall& a) const {
  if (!state_ || switching_) return E_UNEXPECTED;
  auto lease = module_; ++calls_;
  HRESULT hr = lease->api.invoke(state_, op, &a);
  --calls_; return hr;
}
HRESULT ShimService::Key(uint32_t op, ITfContext* c, WPARAM w, LPARAM l, BOOL* eaten) {
  if (op == NI_TEST_DOWN || op == NI_DOWN) key_pair_ = true;
  NativeImeCall a{}; a.context = c; a.wparam = w; a.lparam = l; a.eaten = eaten;
  auto hr = Invoke(op, a);
  if (op == NI_UP || ((op == NI_TEST_UP || op == NI_TEST_DOWN) && (!eaten || !*eaten))) key_pair_ = false;
  return hr;
}
#define KEY_METHOD(name, op) HRESULT ShimService::name(ITfContext* c, WPARAM w, LPARAM l, BOOL* e) { return Key(op, c, w, l, e); }
KEY_METHOD(OnTestKeyDown, NI_TEST_DOWN)
KEY_METHOD(OnKeyDown, NI_DOWN)
KEY_METHOD(OnTestKeyUp, NI_TEST_UP)
KEY_METHOD(OnKeyUp, NI_UP)
HRESULT ShimService::OnSetFocus(BOOL focus) { NativeImeCall a{}; a.wparam = focus; return Invoke(NI_FOCUS, a); }
HRESULT ShimService::OnPreservedKey(ITfContext* c, REFGUID g, BOOL* e) { NativeImeCall a{}; a.context = c; a.guid = &g; a.eaten = e; return Invoke(NI_PRESERVED, a); }
HRESULT ShimService::OnCompositionTerminated(TfEditCookie ec, ITfComposition* c) {
  IUnknown* identity = nullptr;
  if (c && SUCCEEDED(c->QueryInterface(IID_IUnknown, reinterpret_cast<void**>(&identity)))) {
    auto it = std::find(ending_compositions_.begin(), ending_compositions_.end(), identity);
    identity->Release();
    if (it != ending_compositions_.end()) {
      (*it)->Release(); ending_compositions_.erase(it); return S_OK;
    }
  }
  NativeImeCall a{}; a.context = c; a.wparam = ec; return Invoke(NI_COMPOSITION_END, a);
}
HRESULT ShimService::OnChange(REFGUID g) { NativeImeCall a{}; a.guid = &g; return Invoke(NI_COMPARTMENT, a); }
HRESULT ShimService::EnumDisplayAttributeInfo(IEnumTfDisplayAttributeInfo** out) { if (!out) return E_POINTER; *out = nullptr; return E_NOTIMPL; }
HRESULT ShimService::GetDisplayAttributeInfo(REFGUID g, ITfDisplayAttributeInfo** out) {
  if (!out) return E_POINTER; *out = nullptr;
  if (g != GUID_DdskkPreeditAttribute && g != GUID_DdskkCandidateAttribute && g != GUID_DdskkConvertedAttribute) return E_INVALIDARG;
  *out = CreateDisplayAttributeInfo(g); return *out ? S_OK : E_OUTOFMEMORY;
}
HRESULT ShimService::GetType(GUID* g) { if (!g) return E_POINTER; *g = CLSID_DdskkTextService; return S_OK; }
HRESULT ShimService::GetDescription(BSTR* out) { if (!out) return E_POINTER; *out = SysAllocString(L"NeLisp IME settings"); return *out ? S_OK : E_OUTOFMEMORY; }
HRESULT ShimService::GetDisplayName(BSTR* out) { return GetDescription(out); }
HRESULT ShimService::GetFunction(REFGUID, REFIID iid, IUnknown** out) { return QueryInterface(iid, reinterpret_cast<void**>(out)); }
HRESULT ShimService::Show(HWND, LANGID, REFGUID) { ShowSettings(); return S_OK; }
void ShimService::SelectInputEngine(bool ddskk) { NativeImeCall a{}; a.wparam = ddskk; Invoke(NI_ENGINE, a); }
void ShimService::SelectEngineId(const std::string& id) { NativeImeCall a{}; a.narrow = id.c_str(); Invoke(NI_ENGINE_ID, a); }
void ShimService::SelectInputMode(const std::wstring& mode) { NativeImeCall a{}; a.text = mode.c_str(); Invoke(NI_MODE, a); }
void ShimService::ReloadEngine() { NativeImeCall a{}; Invoke(NI_RELOAD, a); }
void ShimService::ToggleInputMode() { NativeImeCall a{}; Invoke(NI_TOGGLE, a); }
void ShimService::ShowSettings() { NativeImeCall a{}; Invoke(NI_SETTINGS, a); }
std::wstring ShimService::CurrentModeLabel() const { NativeImeCall a{}; Invoke(NI_LABEL, a); return a.label; }
ModeIndicatorPalette ShimService::CurrentModePalette() const { NativeImeCall a{}; Invoke(NI_PALETTE, a); return {a.palette[0], a.palette[1], a.palette[2]}; }
void ShimService::AddButtons() {
  ITfLangBarItemMgr* mgr = nullptr;
  if (FAILED(tm_->QueryInterface(IID_ITfLangBarItemMgr, reinterpret_cast<void**>(&mgr)))) return;
  settings_button_ = new LangBarButton(this, GUID_DdskkSettingsButton,
      TF_LBI_STYLE_BTN_MENU | TF_LBI_STYLE_SHOWNINTRAY, L"NeLisp IME", LangBarButton::Kind::kSettings);
  input_mode_button_ = new LangBarButton(this, GUID_LBI_INPUTMODE,
      TF_LBI_STYLE_BTN_BUTTON | TF_LBI_STYLE_SHOWNINTRAY, L"NeLisp IME input mode", LangBarButton::Kind::kInputMode);
  if (FAILED(mgr->AddItem(settings_button_))) { settings_button_->Release(); settings_button_ = nullptr; }
  if (FAILED(mgr->AddItem(input_mode_button_))) { input_mode_button_->Release(); input_mode_button_ = nullptr; }
  mgr->Release();
}
void ShimService::RemoveButtons() {
  ITfLangBarItemMgr* mgr = nullptr;
  if (tm_ && SUCCEEDED(tm_->QueryInterface(IID_ITfLangBarItemMgr, reinterpret_cast<void**>(&mgr)))) {
    if (settings_button_) mgr->RemoveItem(settings_button_);
    if (input_mode_button_) mgr->RemoveItem(input_mode_button_);
    mgr->Release();
  }
  if (settings_button_) { settings_button_->DetachHandler(); settings_button_->Release(); settings_button_ = nullptr; }
  if (input_mode_button_) { input_mode_button_->DetachHandler(); input_mode_button_->Release(); input_mode_button_ = nullptr; }
}
