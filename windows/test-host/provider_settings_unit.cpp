// Compiles the production FollowSettings/QueueProviderSettings/ApplyProviderSettings
// bodies against a deterministic engine. No registry, host stack, or runtime.
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

constexpr unsigned kModeReplayTimeoutMs = 5000;
constexpr unsigned kInteractiveTimeoutMs = 350;
using DWORD = unsigned long;
using ULONGLONG = unsigned long long;
ULONGLONG GetTickCount64() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now().time_since_epoch()).count();
}
unsigned GetEnvironmentVariableW(const wchar_t*, void*, unsigned) { return 0; }
void Sleep(unsigned ms) { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); }
thread_local bool in_callback = false;
std::atomic<unsigned> callback_io{0};
void Check(bool ok) { if (!ok) { std::puts("FAIL provider settings assertion"); std::exit(1); } }
using HRESULT = long;
bool FAILED(HRESULT value) { return value < 0; }
struct Index { std::string rules = "certified"; const std::string& Rules() { return rules; } };
struct LocalStore {
  struct Snapshot {
    bool available = true;
    std::shared_ptr<Index> index = std::make_shared<Index>();
    struct Entry { std::wstring key, candidate; };
    std::vector<Entry> pending;
  } snapshot;
  Snapshot Capture() { return snapshot; }
};
struct LocalConversion {
  bool Begin(std::shared_ptr<Index>, const std::wstring& reading, const std::vector<std::wstring>&) { return reading == L"かな"; }
  std::wstring State() { return L"仮名"; }
};

struct Engine {
  int handle = 1, next_handle = 2;
  unsigned stale_writes = 0, disconnects = 0, failures = 0;
  std::vector<std::string> selections;
  std::vector<std::string> conversions;
  std::function<void()> after_select;
  void Io() { if (in_callback) ++callback_io; }
  void Disconnect() { ++disconnects; handle = 0; }
  void MarkNeedsResync() {}
  void Connect() { Io(); if (!handle) handle = next_handle++; }
  bool SelectEngine(const std::string& engine, unsigned) {
    Io(); if (handle == 1) ++stale_writes;
    if (failures) { --failures; return false; }
    selections.push_back(engine);
    if (after_select) { auto action = std::move(after_select); after_select = {}; action(); }
    return true;
  }
  std::string ConvertKeys(const std::string& keys, unsigned) {
    Io(); conversions.push_back(keys); return "仮名";
  }
};
class TextService {
public:
  Engine engine_;
  std::mutex provider_engine_mutex_;
  std::atomic<std::shared_ptr<const std::string>> provider_settings_;
  std::shared_ptr<const std::string> applied_provider_settings_;
  std::atomic<unsigned> references{0};
  struct { std::atomic<bool> dirty{false}; } settings_watcher_;
  struct {
    bool composing = false;
    bool preedit() { return composing; }
    std::wstring preview_reading() { return L"かな"; }
  } realtime_frontend_;
  void* composition_ = nullptr;
  bool engine_pending_ = false, registration_mode_ = false;
  bool provider_composition_active_ = false;
  bool provider_conversion_active_ = true, provider_conversion_retry_ = false, local_enabled_ = true;
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
  std::string desired_engine = "ddskk";
  unsigned loads = 0;
  void AddRef() { ++references; }
  void Release() { --references; }
  void EnsureEngineHost() { engine_.Connect(); }
  void LoadSettings() { ++loads; QueueProviderSettings(desired_engine); }
  void MaybeShowModeIndicator(void*, void*) {}
  void FollowSettings();
  void QueueProviderSettings(const std::string& engine);
  bool ApplyProviderSettings(DWORD timeout_ms = 5000);
  bool WaitForProviderSettings(ULONGLONG deadline);
  bool TryLocalConversionFallback();
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
  TextService service;
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
    // Host swap with the SAME engine still requires a fresh connection.
    service.QueueProviderSettings("ddskk");
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
      service.provider_settings_.store(std::make_shared<const std::string>("ddskk"));
    };
    service.provider_settings_.store(std::make_shared<const std::string>("lattice"));
    Check(service.ApplyProviderSettings());
    // The provider may consume its key NOW, before another job can run.
    Check(service.engine_.selections.back() == "ddskk");
  }
  Check(service.engine_.selections.back() == "ddskk");
  Check(*service.applied_provider_settings_ == "ddskk");
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
    service.provider_settings_.store(std::make_shared<const std::string>("ddskk"));
    service.engine_.failures = 1;
    const auto deadline = GetTickCount64() + 1500;
    Check(service.WaitForProviderSettings(deadline));
    Check(service.engine_.ConvertKeys("Kana", static_cast<unsigned>(deadline - GetTickCount64())) == "仮名");
    Check(service.engine_.conversions == std::vector<std::string>{"Kana"});
    service.provider_settings_.store(std::make_shared<const std::string>("ddskk"));
    service.engine_.failures = 100;
    const auto exhausted = GetTickCount64() + 40;
    Check(!service.WaitForProviderSettings(exhausted));
    Check(GetTickCount64() < exhausted + 30);
    Check(service.engine_.conversions.size() == 1);
  }
  Check(callback_io == 0 && service.engine_.stale_writes == 0);
  service.realtime_frontend_.composing = true;
  in_callback = true;
  Check(service.TryLocalConversionFallback());
  Check(service.document == L"仮名" && !service.provider_conversion_active_);
  service.document.clear();
  service.local_rule_snapshot_->rules = "different";
  Check(!service.TryLocalConversionFallback() && service.document.empty());
  in_callback = false;
  Check(callback_io == 0);
  std::puts("PASS provider settings cases=12 callback_io=0 stale_writes=0 pending_conversion=1 conversions=1 deadline_exhaustion=1 certified_fallback=1 mismatch_rejected=1 references=0 stacks=0");
}
