// Compiles the production FollowSettings/QueueProviderSettings/ApplyProviderSettings
// bodies against a deterministic engine. No registry, host stack, or runtime.
#ifdef PROVIDER_PIPE_UNIT
// Exercise real timeout/disconnect/resync using only a synthetic private pipe.
#include "engine_client.h"
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>

static void CheckAt(bool ok, int line) {
  if (!ok) { std::printf("FAIL real selector line=%d error=%lu\n", line, GetLastError()); std::exit(1); }
}
#define Check(condition) CheckAt((condition), __LINE__)
int main() {
  const auto name = L"\\\\.\\pipe\\reg3-unit-" + std::to_wstring(GetCurrentProcessId()) +
                    L"-" + std::to_wstring(GetTickCount64());
  Check(SetEnvironmentVariableW(L"DDSKK_PIPE_NAME", name.c_str()) != 0);
  HANDLE ready = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  Check(ready != nullptr);
  std::thread server([&] {
    HANDLE pipe = CreateNamedPipeW(name.c_str(), PIPE_ACCESS_DUPLEX,
        PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT, 1, 8192, 8192, 1000, nullptr);
    Check(pipe != INVALID_HANDLE_VALUE);
    for (int attempt = 0; attempt < 3; ++attempt) {
      SetEvent(ready);
      Check(ConnectNamedPipe(pipe, nullptr) || GetLastError() == ERROR_PIPE_CONNECTED);
      for (const char* command : {"OPEN 2", "RESET", "ENGINE SET ddskk"}) {
        char buffer[512]{}; DWORD read = 0, written = 0;
        Check(ReadFile(pipe, buffer, sizeof(buffer), &read, nullptr) != 0);
        const std::string request(buffer, read);
        Check(request.starts_with("SESSION ") && request.find(command) != std::string::npos);
        const bool reset = std::string(command) == "RESET";
        if (reset) Sleep(80); // Every fresh session exceeds the short budget.
        const std::string response = reset ? "STATE hiragana 0 -1 - - -1 -" :
            std::string(command) == "OPEN 2" ? "OK OPEN 2" : "OK ENGINE ddskk";
        const bool sent = WriteFile(pipe, response.data(), static_cast<DWORD>(response.size()), &written, nullptr) != 0;
        if (reset && attempt < 2) { Check(!sent); break; }
        Check(sent && written == response.size());
      }
      if (attempt == 2) FlushFileBuffers(pipe);
      DisconnectNamedPipe(pipe);
    }
    CloseHandle(pipe);
  });
  ddskk::EngineClient client;
  client.MarkNeedsResync();
  for (int attempt = 0; attempt < 3; ++attempt) {
    Check(WaitForSingleObject(ready, 2000) == WAIT_OBJECT_0);
    const DWORD budget = attempt < 2 ? 25 : 1000;
    const auto start = GetTickCount64();
    const bool selected = client.SelectEngine("ddskk", budget);
    const auto elapsed = GetTickCount64() - start;
    Check(selected == (attempt == 2));
    Check(client.IsConnected() == selected);
    if (selected) Check(elapsed > 25); // Tick rounding need not equal Sleep(80).
    std::printf("PASS real selector attempt=%d budget_ms=%lu selected=%d elapsed_ms=%llu connected=%d\n",
                attempt + 1, budget, selected ? 1 : 0, elapsed, client.IsConnected() ? 1 : 0);
  }
  client.Disconnect();
  server.join();
  CloseHandle(ready);
  SetEnvironmentVariableW(L"DDSKK_PIPE_NAME", nullptr);
  std::puts("PASS real selector timeout_disconnect_resync=1 stacks=0 registry=0");
}
#else
#include <atomic>
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include <optional>
#include <string_view>
#include "engine_protocol.h"

constexpr unsigned kModeReplayTimeoutMs = 5000;
constexpr unsigned kInteractiveTimeoutMs = 350;
constexpr unsigned kConversionTimeoutMs = 1500;
using DWORD = unsigned long;
constexpr DWORD ERROR_FILE_NOT_FOUND = 2, ERROR_PATH_NOT_FOUND = 3;
using ULONGLONG = unsigned long long;
ULONGLONG GetTickCount64() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now().time_since_epoch()).count();
}
unsigned GetEnvironmentVariableW(const wchar_t*, void*, unsigned) { return 0; }
void KillTimer(void*, unsigned) {}
void SetTimer(void*, unsigned, unsigned, void*) {}
void Sleep(unsigned ms) { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); }
thread_local bool in_callback = false;
std::atomic<unsigned> callback_io{0};
void Check(bool ok) { if (!ok) { std::puts("FAIL provider settings assertion"); std::exit(1); } }
using HRESULT = long;
bool FAILED(HRESULT value) { return value < 0; }
namespace ddskk {
class EngineClient {
public:
  std::optional<std::string> response;
  std::string request;
  std::optional<std::string> Transact(const std::string& value, DWORD) { request = value; return response; }
  std::optional<EngineState> RegistrationLearning(DWORD timeout_ms = 1500);
};
}
struct Index { std::string rules = "certified"; const std::string& Rules() { return rules; } };
struct LocalStore {
  struct Snapshot {
    bool available = true;
    std::shared_ptr<Index> index = std::make_shared<Index>();
    struct Entry { std::wstring key, candidate; };
    std::vector<Entry> pending;
  } snapshot;
  Snapshot Capture() { return snapshot; }
  struct Learning { std::wstring reading, word, okuri; };
  std::vector<Learning> learned;
  bool Learn(std::wstring reading, std::wstring word, std::wstring okuri) {
    learned.push_back({reading, word, okuri}); return true;
  }
  bool LearnRegistration(const ddskk::EngineState& state, const std::wstring& reading,
                         const std::wstring& okuri) {
    if (state.text.empty() || state.composition_start >= 0) return false;
    return Learn(reading, state.text, okuri);
  }
  size_t Unsaved() { return learned.size(); }
};
struct LocalConversion {
  bool Begin(std::shared_ptr<Index>, const std::wstring& reading, const std::vector<std::wstring>&) { return reading == L"かな"; }
  std::wstring State() { return L"仮名"; }
};

struct Engine {
  int handle = 1, next_handle = 2;
  unsigned stale_writes = 0, disconnects = 0, failures = 0;
  bool fail_conversion = false;
  bool fail_registration = false;
  DWORD connection_error = 0;
  unsigned registrations = 0, conversion_timeout = 0;
  unsigned select_delay_ms = 0;
  bool absent = false;
  std::vector<unsigned> select_budgets;
  std::vector<std::string> selections;
  std::vector<std::string> conversions;
  std::function<void()> after_select;
  void Io() { if (in_callback) ++callback_io; }
  void Disconnect() { ++disconnects; handle = 0; }
  void MarkNeedsResync() {}
  void CancelPendingIo() {}
  void Connect() { Io(); if (absent) { handle = 0; connection_error = ERROR_FILE_NOT_FOUND; return; } if (!handle) handle = next_handle++; }
  bool IsConnected() { return handle != 0; }
  DWORD ConnectionError() { return connection_error; }
  bool SelectEngine(const std::string& engine, unsigned timeout) {
    Io(); if (handle == 1) ++stale_writes;
    select_budgets.push_back(timeout);
    if (absent) return false;
    if (select_delay_ms) {
      Sleep(std::min(timeout, select_delay_ms));
      if (timeout < select_delay_ms) { Disconnect(); return false; }
    }
    if (failures) { --failures; return false; }
    selections.push_back(engine);
    if (after_select) { auto action = std::move(after_select); after_select = {}; action(); }
    return true;
  }
  std::optional<ddskk::EngineState> ConvertKeys(const std::string& keys, unsigned timeout) {
    Io(); conversions.push_back(keys); conversion_timeout = timeout;
    if (fail_conversion) return std::nullopt;
    ddskk::EngineState state; state.text = L"仮名"; return state;
  }
  std::optional<ddskk::EngineState> RegisterLocal(const std::string&, unsigned timeout) {
    Io(); ++registrations; Check(timeout == kModeReplayTimeoutMs);
    if (fail_registration) return std::nullopt;
    ddskk::EngineState state; state.mode = L"registration"; return state;
  }
  std::optional<ddskk::EngineState> SendControl(ddskk::EngineControl, unsigned) {
    ddskk::EngineState state; state.mode = L"registration"; return state;
  }
};
struct WorkerFlag {
  std::atomic<bool> value{false};
  std::function<void()> before_exit;
  bool exchange(bool next) { return value.exchange(next); }
  void store(bool next) {
    if (!next && before_exit) { auto action = std::move(before_exit); before_exit = {}; action(); }
    value.store(next);
  }
};
class TextService {
public:
  Engine engine_;
  std::mutex provider_engine_mutex_;
  struct ProviderSettings {
    std::string engine;
    std::wstring host, executable, repository, pipe;
    bool operator==(const ProviderSettings&) const = default;
  };
  std::wstring host = L"old";
  ProviderSettings ReadProviderSettings(const std::string& engine) { return {engine, host, L"runtime", L"repo", L"private"}; }
  std::atomic<std::shared_ptr<const ProviderSettings>> provider_settings_;
  std::atomic<std::shared_ptr<const ProviderSettings>> applied_provider_settings_;
  std::shared_ptr<const ProviderSettings> connecting_provider_settings_;
  WorkerFlag provider_settings_worker_;
  std::atomic<unsigned> references{0};
  struct { std::atomic<bool> dirty{false}; } settings_watcher_;
  struct {
    bool composing = false;
    bool preedit() { return composing; }
    std::wstring preview_reading() { return L"かな"; }
    std::wstring okuri_text() { return {}; }
    std::string raw_keys() { return "Kana"; }
  } realtime_frontend_;
  void* composition_ = nullptr;
  bool engine_pending_ = false, registration_mode_ = false;
  bool provider_composition_active_ = false;
  bool provider_conversion_active_ = true, provider_conversion_retry_ = false, local_enabled_ = true;
  bool provider_conversion_registration_ = false;
  size_t provider_conversion_skip_ = 0;
  void* active_context_ = this;
  std::shared_ptr<Index> local_rule_snapshot_ = std::make_shared<Index>();
  LocalStore local_store_;
  LocalConversion local_conversion_;
  std::optional<int> provider_candidate_state_;
  std::wstring document;
  HRESULT ApplyLocalState(void*, const std::wstring& value) { document = value; return 0; }
  void ScheduleLocalRetry() {}
  bool confirmation_pending_ = false, confirmation_replay_ = false;
  std::vector<int> deferred_provider_keys_;
  std::atomic<bool> provider_pending_{false};
  std::atomic<unsigned> provider_sequence_{0};
  ULONGLONG provider_deadline_ = 0;
  void* provider_window_ = this;
  unsigned replays = 0;
  void ReplayDeferredProviderKeys() { ++replays; deferred_provider_keys_.clear(); }
  std::string desired_engine = "ddskk";
  unsigned loads = 0;
  void AddRef() { ++references; }
  void Release() { --references; }
  void EnsureEngineHost() { engine_.Connect(); }
  void LoadSettings() { ++loads; QueueProviderSettings(desired_engine); }
  void MaybeShowModeIndicator(void*, void*) {}
  void FollowSettings();
  void SettleIdleProviderState() {}
  void RefreshDebugSettings() {}
  void QueueProviderSettings(const std::string& engine);
  void StartProviderSettingsWorker();
  bool ApplyProviderSettings(DWORD timeout_ms = 5000);
  bool WaitForProviderSettings(ULONGLONG deadline);
  bool TryLocalConversionFallback();
  void RetainProviderConversion();
  int RunRetentionTimer();
  unsigned resumed_conversions = 0;
  std::optional<ddskk::EngineState> resumed_state;
  bool BeginProviderConversion(const std::string&, bool registration, size_t skip) {
    Check(!provider_pending_.load());
    // Production transaction runs on a worker, not the timer/TSF thread.
    std::thread worker([&] { resumed_state = RunConversion(registration, skip).first; });
    worker.join();
    ++resumed_conversions;
    return true;
  }
  void ShowProviderBusy(void*) {}
  bool ProviderConversionSettingsPending(bool settings_ready, bool provider_unavailable);
  std::pair<std::optional<ddskk::EngineState>, bool> RunConversion(bool registration = false, size_t skip = 0);
  std::wstring registration_reading_, registration_okuri_;
  void ObserveRegistrationLearning(const ddskk::EngineState& state,
      const std::optional<ddskk::EngineState>& learning = std::nullopt);
  void Idle() {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (references.load()) {
      Check(std::chrono::steady_clock::now() < deadline);
      Sleep(1);
    }
  }
};
#include "provider_settings.inc"

int main() {
  {
    TextService cold;
    cold.engine_.select_delay_ms = 80;
    cold.engine_.fail_conversion = true; // MISS resumes into registration.
    cold.provider_settings_.store(std::make_shared<const TextService::ProviderSettings>(cold.ReadProviderSettings("ddskk")));
    for (int attempt = 0; attempt < 2; ++attempt) {
      const auto probe = cold.RunConversion();
      Check(!probe.first && probe.second);
    }
    Check(!cold.applied_provider_settings_.load());
    cold.realtime_frontend_.composing = true;
    cold.local_store_.snapshot.available = false;
    cold.deferred_provider_keys_ = {13};
    in_callback = true;
    const auto retained = GetTickCount64();
    cold.RetainProviderConversion();
    in_callback = false;
    Check(GetTickCount64() - retained < 20 && callback_io == 0);
    cold.Idle();
    Check(cold.applied_provider_settings_.load() == cold.provider_settings_.load());
    Check(cold.engine_.select_budgets == std::vector<unsigned>({25, 25, 1000}));
    Check(cold.provider_conversion_retry_ && cold.deferred_provider_keys_ == std::vector<int>{13});
    in_callback = true;
    cold.RunRetentionTimer();
    in_callback = false;
    Check(cold.resumed_state && cold.resumed_state->mode == L"registration");
    Check(cold.resumed_conversions == 1 && !cold.provider_conversion_retry_ && callback_io == 0);
    Check(cold.deferred_provider_keys_ == std::vector<int>{13});
    cold.RunRetentionTimer();
    Check(cold.resumed_conversions == 1); // No duplicate retry after resume.
    Check(cold.engine_.registrations == 1 && cold.engine_.disconnects == 3);
    std::puts("PASS cold selection short_failures=2 worker_budget=1000 retained_registration=1");
  }
  {
    TextService absent;
    absent.engine_.absent = true;
    absent.provider_settings_.store(std::make_shared<const TextService::ProviderSettings>(absent.ReadProviderSettings("ddskk")));
    const auto start = GetTickCount64();
    const auto probe = absent.RunConversion();
    Check(!probe.first && probe.second && GetTickCount64() - start < 100);
    absent.realtime_frontend_.composing = true;
    absent.deferred_provider_keys_ = {13};
    {
      std::lock_guard lock(absent.provider_engine_mutex_);
      absent.StartProviderSettingsWorker();
      in_callback = true;
      const auto callback_start = GetTickCount64();
      absent.RetainProviderConversion();
      in_callback = false;
      Check(GetTickCount64() - callback_start < 20 && callback_io == 0);
      Check(absent.document == L"仮名" && absent.replays == 1 && !absent.provider_conversion_retry_);
      absent.provider_settings_.store(nullptr); // deactivate the absent fixture
    }
    absent.Idle();
    Check(absent.engine_.disconnects == 1);
    std::puts("PASS absent provider probe_ms<100 callback_ms<20 fallback=1");
  }
  TextService service;
  // An empty/failed registration-entry reply after successful selection is
  // an operation failure, not an unsent settings request that can loop forever.
  Check(!service.ProviderConversionSettingsPending(true, false));
  Check(service.ProviderConversionSettingsPending(false, false));
  Check(service.ProviderConversionSettingsPending(true, true));
  TextService entry;
  entry.QueueProviderSettings("ddskk"); entry.Idle();
  entry.engine_.fail_conversion = true;
  const auto failed_entry = entry.RunConversion();
  Check(failed_entry.first && failed_entry.first->mode == L"registration" && !failed_entry.second);
  Check(entry.engine_.registrations == 1 && entry.engine_.conversion_timeout > kConversionTimeoutMs);
  entry.applied_provider_settings_.store(nullptr);
  entry.engine_.failures = 1;
  const auto unavailable = entry.RunConversion();
  Check(!unavailable.first && unavailable.second && entry.engine_.registrations == 1);
  entry.realtime_frontend_.composing = true;
  entry.local_store_.snapshot.available = false;
  entry.RetainProviderConversion(); entry.Idle();
  entry.engine_.fail_conversion = false;
  const auto resumed = entry.RunConversion();
  Check(resumed.first && !resumed.second && entry.engine_.conversions.size() == 2);
  entry.engine_.fail_conversion = entry.engine_.fail_registration = true;
  const auto empty = entry.RunConversion();
  Check(!empty.first && !empty.second);
  entry.engine_.handle = 0; entry.engine_.connection_error = ERROR_FILE_NOT_FOUND;
  const auto vanished = entry.RunConversion();
  Check(!vanished.first && vanished.second);
  ddskk::EngineClient metadata;
  metadata.response = "REGISTRATION-LEARNED 003068 00304f -1 - 003071";
  const auto decoded = metadata.RegistrationLearning();
  Check(decoded && decoded->text == L"と" && decoded->pending_romaji == L"く" && decoded->registration_reading == L"ぱ");
  Check(metadata.request == "REGISTRATION-LEARNING");
  metadata.response = "OK NONE";
  Check(!metadata.RegistrationLearning());
  metadata.response = "REGISTRATION-LEARNED broken";
  Check(!metadata.RegistrationLearning());
  metadata.response.reset();
  Check(!metadata.RegistrationLearning());
  ddskk::EngineState popup;
  popup.mode = L"registration";
  popup.registration_reading = L"outer";
  service.ObserveRegistrationLearning(popup);
  service.registration_mode_ = true;
  popup.registration_reading = L"inner";
  service.ObserveRegistrationLearning(popup);
  popup.registration_reading = L"deep";
  service.ObserveRegistrationLearning(popup);
  // Child completion stays in registration; its explicit event must reach
  // the local queue before the outer frame finishes or is cancelled.
  ddskk::EngineState event;
  event.text = L"と"; event.registration_reading = L"deep";
  popup.registration_reading = L"inner";
  service.ObserveRegistrationLearning(popup, event);
  event.text = L"すと"; event.registration_reading = L"inner";
  popup.registration_reading = L"outer";
  service.ObserveRegistrationLearning(popup, event);
  event.text = L"てすと"; event.registration_reading = L"outer";
  ddskk::EngineState completed;
  completed.mode = L"hiragana"; completed.text = L"てすと";
  service.ObserveRegistrationLearning(completed, event);
  Check(service.local_store_.learned.size() == 3);
  Check(service.local_store_.learned[0].reading == L"deep");
  Check(service.local_store_.learned[1].word == L"すと");
  Check(service.local_store_.learned[2].reading == L"outer");
  completed.text.clear();
  service.ObserveRegistrationLearning(completed);
  Check(service.local_store_.learned.size() == 3);
  service.registration_mode_ = false;
  {
    // The settings-observing callback must return while a provider owns its
    // mutex. Old FollowSettings blocked here (or synchronously did IPC).
    std::unique_lock<std::mutex> provider(service.provider_engine_mutex_);
    service.settings_watcher_.dirty = true;
    in_callback = true;
    const auto start = std::chrono::steady_clock::now();
    service.FollowSettings();
    in_callback = false;
    Check(std::chrono::steady_clock::now() - start < std::chrono::milliseconds(20));
    Check(service.loads == 1 && callback_io == 0 && service.engine_.selections.empty());
  }
  service.Idle();
  Check(service.engine_.selections == std::vector<std::string>{"ddskk"});
  Check(service.engine_.stale_writes == 0 && service.engine_.handle != 1);
  const unsigned before = service.engine_.disconnects;
  {
    std::unique_lock<std::mutex> provider(service.provider_engine_mutex_);
    in_callback = true;
    // Irrelevant writes preserve identity; endpoint changes invalidate it.
    service.QueueProviderSettings("ddskk");
    Check(service.references == 0);
    service.host = L"new";
    service.QueueProviderSettings("ddskk");
    for (int i = 0; i < 100; ++i) service.QueueProviderSettings("ddskk");
    Check(service.references == 1);
    in_callback = false;
    Check(callback_io == 0 && service.engine_.disconnects == before);
  }
  service.Idle();
  Check(service.engine_.disconnects == before + 1);
  {
    std::unique_lock<std::mutex> provider(service.provider_engine_mutex_);
    in_callback = true;
    service.QueueProviderSettings("ddskk");
    service.QueueProviderSettings("lattice");
    in_callback = false;
    // Force a real provider request to acquire the mutex BEFORE the queued
    // settings jobs: it must apply the latest engine before its operation.
    Check(service.ApplyProviderSettings());
    Check(service.engine_.selections.back() == "lattice");
  }
  service.Idle();
  Check(service.engine_.selections == std::vector<std::string>{"ddskk", "ddskk", "lattice"});
  service.engine_.failures = 1;
  service.QueueProviderSettings("passthrough");
  service.Idle();
  Check(service.engine_.selections.back() == "passthrough");
  service.QueueProviderSettings("ddskk");
  service.Idle();
  Check(service.engine_.selections.back() == "ddskk");
  {
    std::unique_lock<std::mutex> provider(service.provider_engine_mutex_);
    service.engine_.after_select = [&service] {
      service.provider_settings_.store(std::make_shared<const TextService::ProviderSettings>(service.ReadProviderSettings("ddskk")));
    };
    service.provider_settings_.store(std::make_shared<const TextService::ProviderSettings>(service.ReadProviderSettings("lattice")));
    Check(service.ApplyProviderSettings());
    // The provider may consume its key NOW, before another job can run.
    Check(service.engine_.selections.back() == "ddskk");
  }
  Check(service.engine_.selections.back() == "ddskk");
  Check(service.applied_provider_settings_.load()->engine == "ddskk");
  const auto count = service.engine_.selections.size();
  service.settings_watcher_.dirty = true;
  service.deferred_provider_keys_.push_back(1);
  service.FollowSettings();
  Check(service.settings_watcher_.dirty && service.loads == 1);
  service.deferred_provider_keys_.clear();
  service.settings_watcher_.dirty = false;
  {
    std::unique_lock<std::mutex> provider(service.provider_engine_mutex_);
    service.QueueProviderSettings("passthrough");
    service.provider_settings_.store(nullptr); // Deactivate cancels queued settings.
  }
  service.Idle();
  Check(service.engine_.selections.size() == count);
  {
    std::unique_lock<std::mutex> provider(service.provider_engine_mutex_);
    service.provider_settings_.store(std::make_shared<const TextService::ProviderSettings>(service.ReadProviderSettings("ddskk")));
    service.engine_.failures = 1;
    const auto deadline = GetTickCount64() + 1500;
    Check(service.WaitForProviderSettings(deadline));
    Check(service.engine_.ConvertKeys("Kana", static_cast<unsigned>(deadline - GetTickCount64()))->text == L"仮名");
    Check(service.engine_.conversions == std::vector<std::string>{"Kana"});
    service.provider_settings_.store(std::make_shared<const TextService::ProviderSettings>(service.ReadProviderSettings("ddskk")));
    service.engine_.failures = 100;
    const auto exhausted = GetTickCount64() + 40;
    Check(!service.WaitForProviderSettings(exhausted));
    Check(GetTickCount64() < exhausted + 30);
    Check(service.engine_.conversions.size() == 1);
  }
  Check(callback_io == 0 && service.engine_.stale_writes == 0);
  service.realtime_frontend_.composing = true;
  in_callback = true;
  service.provider_conversion_skip_ = 1;
  Check(!service.TryLocalConversionFallback()); // Exhaustion must resume traversal, not candidate zero.
  service.provider_conversion_skip_ = 0;
  Check(service.TryLocalConversionFallback());
  Check(service.document == L"仮名" && !service.provider_conversion_active_);
  service.document.clear();
  service.local_rule_snapshot_->rules = "different";
  Check(!service.TryLocalConversionFallback() && service.document.empty());
  in_callback = false;
  Check(callback_io == 0);
  // An expired/failed conversion retains Enter, then commits a certified
  // candidate once, rather than replaying Enter against the raw reading.
  service.engine_.failures = 0;
  service.local_rule_snapshot_->rules = "certified";
  service.local_store_.snapshot.available = false;
  service.deferred_provider_keys_ = {13};
  service.provider_pending_ = true;
  service.RetainProviderConversion();
  Check(!service.provider_pending_ && service.provider_conversion_retry_);
  Check(service.deferred_provider_keys_ == std::vector<int>{13} && service.replays == 0);
  service.Idle();
  Check(service.applied_provider_settings_.load() == service.provider_settings_.load());
  service.local_store_.snapshot.available = true;
  Check(service.TryLocalConversionFallback());
  service.ReplayDeferredProviderKeys();
  Check(service.document == L"仮名" && service.replays == 1 && service.deferred_provider_keys_.empty());
  // Result delivery may invalidate selection just before an apply worker
  // clears its scheduled flag. The coalesced retry must not be stranded.
  const auto handoff_count = service.engine_.selections.size();
  {
    std::lock_guard lock(service.provider_engine_mutex_);
    service.provider_settings_worker_.before_exit = [&service] {
      service.applied_provider_settings_.store(nullptr);
      service.StartProviderSettingsWorker();
    };
    service.QueueProviderSettings("lattice");
  }
  service.Idle();
  Check(service.applied_provider_settings_.load() == service.provider_settings_.load());
  Check(service.engine_.selections.size() == handoff_count + 2);
  // Six independent services observe the same relevant change. Every one
  // keeps one apply worker and ignores irrelevant repeated publications.
  for (int client = 0; client < 6; ++client) {
    TextService peer;
    {
      std::lock_guard lock(peer.provider_engine_mutex_);
      peer.QueueProviderSettings("ddskk");
      peer.host = L"replacement";
      peer.QueueProviderSettings("ddskk");
      for (int write = 0; write < 100; ++write) peer.QueueProviderSettings("ddskk");
      Check(peer.references == 1);
    }
    peer.Idle();
    Check(peer.engine_.disconnects == 1 && peer.engine_.selections.size() == 1);
    peer.QueueProviderSettings("ddskk");
    Check(peer.references == 0 && peer.engine_.disconnects == 1);
  }
  std::puts("PASS provider settings cases=24 clients=6 irrelevant_reconnects=0 max_apply_workers=1 callback_io=0 stale_writes=0 pending_conversion=1 conversions=1 deadline_exhaustion=1 certified_fallback=1 mismatch_rejected=1 registration_entry=1 nested_learning=3 references=0 stacks=0");
}
#endif
