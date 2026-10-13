// Native ownership boundary: copied decisions only. Policy has no OS handles,
// storage writers or engine transaction capability. Callers never wait on IPC.
#pragma once
#include "hn3_channel.h"
#include <memory>
#include <bcrypt.h>
#include <filesystem>
#include <sstream>

namespace native_adapter {
inline std::atomic<uint64_t> next_engine_epoch{0}, engine_epoch{0}, publication_generation{0};
enum class PolicyKind { Config = 1, Sources = 2, Restart = 3, Cache = 4, Publication = 5, Learning = 6, Replacement = 7, Capacity = 8, Intent = 9, Order = 10, Payload = 11, CacheTtl = 12, Merge = 13, Startup = 14 };
// Opt-in harness telemetry. Count executed caller algorithms on fallback
// misses or OFF/SHADOW calls; seeds and compilation do not increment them.
struct PolicyCounters {
  static bool Enabled() {
    static const bool enabled = [] {
      wchar_t value[2]{};
      return GetEnvironmentVariableW(L"DDSKK_HOST_POLICY_COUNTERS", value, 2) == 1 && value[0] == L'1';
    }();
    return enabled;
  }
  static int Group(PolicyKind kind) {
    switch (kind) {
      case PolicyKind::Sources: case PolicyKind::Order: return 0;
      case PolicyKind::Cache: case PolicyKind::CacheTtl: case PolicyKind::Capacity: return 1;
      case PolicyKind::Restart: case PolicyKind::Replacement: return 2;
      case PolicyKind::Publication: case PolicyKind::Intent: case PolicyKind::Payload: return 3;
      case PolicyKind::Learning: return 4;
      case PolicyKind::Merge: return 5;
      case PolicyKind::Startup: return 6;
      default: return -1;
    }
  }
  inline static std::array<std::atomic<uint64_t>, 7> native{}, nelisp{};
  static void Native(PolicyKind kind) {
    if (!Enabled()) return;
    const int group = Group(kind);
    if (group >= 0) native[group].fetch_add(1, std::memory_order_relaxed);
  }
  static void Managed(PolicyKind kind) {
    if (!Enabled()) return;
    const int group = Group(kind);
    if (group >= 0) nelisp[group].fetch_add(1, std::memory_order_relaxed);
  }
  static void Log(bool force = false) {
    if (!Enabled()) return;
    // Worker-only sampling; Stop forces the final snapshot after joining it.
    static ULONGLONG last = 0;
    const auto now = GetTickCount64();
    if (!force && now - last < 1000) return;
    last = now;
    const char* names[] = {"SOURCES", "CACHE", "RESTART", "PUBLICATION", "LEARNING", "MERGE", "STARTUP"};
    for (size_t i = 0; i < 7; ++i) {
      if (i >= 5 && !native[i].load() && !nelisp[i].load()) continue;
      LogEvent(std::string("policy-evaluations group=") + names[i] +
          " native=" + std::to_string(native[i].load(std::memory_order_relaxed)) +
          " nelisp-selected=" + std::to_string(nelisp[i].load(std::memory_order_relaxed)));
    }
  }
};
inline void NativeEvaluation(PolicyKind kind) { PolicyCounters::Native(kind); }

struct Observation {
  PolicyKind kind;
  uint64_t engine_epoch, publication_generation, a, b, c, native_decision;
  std::array<char, 1024> context{};
  size_t context_size = 0;
  bool caller_used = false; // Set only by Decide, never by seed/keep-alive work.
  uint64_t caller_tick = 0;
};

class ShadowPolicy {
  friend struct ShadowPolicyTest;
 public:
  static constexpr size_t kFrame = 4096, kRequests = 64, kBytes = 131072;
  ~ShadowPolicy() { Stop(); }
  bool Enabled() const { return enabled_; }
  void Reject() { ++dropped_; }
  void Start(const std::wstring& runtime, const std::wstring& repository, HANDLE job) {
    wchar_t enabled[8]{};
    enabled_ = GetEnvironmentVariableW(L"DDSKK_HOST_POLICY_SHADOW", enabled, 8) == 1 && enabled[0] == L'1';
    const wchar_t* names[] = {L"SOURCES", L"CACHE", L"RESTART", L"PUBLICATION", L"LEARNING"};
    for (size_t i = 0; i < 5; ++i) {
      const auto env = std::wstring(L"DDSKK_HOST_POLICY_") + names[i];
      wchar_t value[16]{};
      const DWORD length = GetEnvironmentVariableW(env.c_str(), value, 16);
      DWORD flag = 0, bytes = sizeof(flag);
      const auto registry = std::wstring(L"HostPolicy") + names[i];
      if (!length) RegGetValueW(HKEY_CURRENT_USER, NativeImeRegistryKey().c_str(),
          registry.c_str(), RRF_RT_REG_DWORD, nullptr, &flag, &bytes);
      switches_[i] = length ? length == 1 && value[0] == L'1' : flag == 1;
      enabled_ = enabled_ || switches_[i];
    }
    const wchar_t* byte_names[] = {L"MERGE", L"STARTUP"};
    const wchar_t* byte_registry[] = {L"HostNativeMerge", L"HostNativeStartup"};
    for (size_t i = 0; i < 2; ++i) {
      wchar_t value[16]{};
      const auto name = std::wstring(L"DDSKK_HOST_NATIVE_") + byte_names[i];
      const DWORD length = GetEnvironmentVariableW(name.c_str(), value, 16);
      DWORD flag = 0, bytes = sizeof(flag);
      if (!length) RegGetValueW(HKEY_CURRENT_USER, NativeImeRegistryKey().c_str(),
          byte_registry[i], RRF_RT_REG_DWORD, nullptr, &flag, &bytes);
      byte_modes_[i] = length ? (length == 1 && (value[0] == L'1' || value[0] == L'2') ? value[0]-L'0' : 0) : (flag <= 2 ? flag : 0);
      enabled_ = enabled_ || byte_modes_[i];
    }
    if (!policy_bundle::Compatible(runtime, repository)) {
      enabled_ = false; switches_.fill(false); byte_modes_.fill(0);
    }
    if (!enabled_) return;
    runtime_ = runtime; repository_ = repository; job_ = job;
    worker_ = std::thread([this] { Run(); });
  }
  unsigned ByteMode(hn3::Operation op) const {
    const auto configured = byte_modes_[op == hn3::Operation::Startup ? 1 : 0];
    return configured && test_shadow_.load() ? 2 : configured;
  }
  bool TestShadow() {
    wchar_t value[2]{};
    const auto key = NativeImeRegistryKey();
    if (GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", value, 2) != 1 || value[0] != L'1' ||
        !key.starts_with(L"Software\\NativeIME-test-") || !byte_modes_[0] || !byte_modes_[1]) return false;
    test_shadow_ = true; LogEvent("hn3-test-shadow-enabled"); return true;
  }
  // Only provider/background workers and startup may pass a positive deadline.
  // Preview/cached callers pass zero: memo lookup plus a bounded try-lock queue.
  template<class NativeResult>
  std::string Bytes(hn3::Operation op, const std::vector<std::string>& fields,
                    ULONGLONG deadline, NativeResult native_result) {
    const auto kind = op == hn3::Operation::Startup ? PolicyKind::Startup : PolicyKind::Merge;
    const auto mode = ByteMode(op);
    if (!mode) return native_result();
    auto fallback = [&] { PolicyCounters::Native(kind); return native_result(); };
    hn3::Frame frame; frame.operation = op; frame.fields = fields;
    frame.engine_epoch = engine_epoch.load(); frame.generation = publication_generation.load();
    const auto key = hn3::Encode(frame);
    if (key.empty()) return fallback();
    std::shared_ptr<ByteRequest> work;
    std::string result; bool answered = false;
    {
      std::unique_lock lock(mutex_, std::defer_lock);
      if (deadline) lock.lock(); else (void)lock.try_lock();
      if (lock.owns_lock()) {
        const auto found = byte_memo_.find(key);
        if (healthy_ && hn3_capable_ && found != byte_memo_.end()) { result = found->second; answered = true; }
        else if (healthy_ && hn3_capable_ && byte_queue_.size() < hn3::kRequests && key.size() <= hn3::kQueueBytes - byte_queued_) {
          work = std::make_shared<ByteRequest>(); work->frame = std::move(frame); work->key = key;
          work->deadline = deadline ? deadline : GetTickCount64() + hn3::kMergeDeadlineMs;
          byte_queue_.push_back(work); byte_queued_ += key.size(); changed_.notify_one();
        }
        // Startup may wait for the fixed policy bootstrap, still bounded by its
        // caller deadline. No request is sent until READY advertises HN3.
        else if (op == hn3::Operation::Startup && deadline && !stop_) {
          changed_.wait_until(lock, std::chrono::steady_clock::now() +
              std::chrono::milliseconds(deadline > GetTickCount64() ? deadline - GetTickCount64() : 0),
              [&] { return stop_ || healthy_; });
          if (healthy_ && hn3_capable_ && byte_queue_.size() < hn3::kRequests && key.size() <= hn3::kQueueBytes - byte_queued_) {
            work = std::make_shared<ByteRequest>(); work->frame = std::move(frame); work->key = key; work->deadline = deadline;
            byte_queue_.push_back(work); byte_queued_ += key.size(); changed_.notify_one();
          }
        }
        if (work && deadline) {
          changed_.wait_until(lock, std::chrono::steady_clock::now() +
              std::chrono::milliseconds(deadline > GetTickCount64() ? deadline - GetTickCount64() : 0),
              [&] { return work->done || stop_; });
          if (work->done && work->valid) { result = work->result; answered = true; }
          else work->cancelled = true;
        }
      }
    }
    if (!answered) return fallback();
    if (mode == 1) PolicyCounters::Managed(kind);
    LogEvent("hn3-answer operation=" + std::to_string(static_cast<unsigned>(op)));
    if (mode == 2) {
      const auto expected = fallback();
      LogEvent(std::string("hn3-shadow ") + (expected == result ? "match" : "mismatch") +
          " operation=" + std::to_string(static_cast<unsigned>(op)));
      return expected;
    }
    return result;
  }
  // Never wait for policy or IO. Contention and saturation drop diagnostics,
  // not native work. Fixed-size value objects cannot retain host pointers.
  void Observe(Observation value) {
    if (!enabled_) return;
    if (value.context_size > value.context.size()) { ++dropped_; return; }
    std::unique_lock lock(mutex_, std::try_to_lock);
    if (!lock.owns_lock() || queue_.size() >= kRequests ||
        (queue_.size() + 1) * sizeof(Observation) > kBytes) { ++dropped_; return; }
    if (Authoritative(value.kind) && std::any_of(queue_.begin(), queue_.end(),
        [&](const Observation& queued) { return Key(queued) == Key(value); })) return;
    queue_.push_back(value); changed_.notify_one();
  }
  bool Authoritative(PolicyKind kind) const {
    switch (kind) {
      case PolicyKind::Sources: case PolicyKind::Order: return switches_[0];
      case PolicyKind::CacheTtl: case PolicyKind::Capacity: return switches_[1];
      case PolicyKind::Restart: case PolicyKind::Replacement: return switches_[2];
      case PolicyKind::Publication: case PolicyKind::Intent: case PolicyKind::Payload: return switches_[3];
      case PolicyKind::Learning: return switches_[4];
      default: return false;
    }
  }
  // Prepare the exact next attempt's backoff and publication predicates without
  // evaluating a caller algorithm. OFF/SHADOW enqueue no additional work.
  void PrefetchRestart(uint64_t engine, uint64_t backoff) {
    if (!Authoritative(PolicyKind::Restart)) return;
    Observe({PolicyKind::Restart, engine, 0, backoff, 0, 0,
        (std::min)(uint64_t{30000}, backoff * 2)});
    Observe({PolicyKind::Restart, engine, 0, backoff, 1, 0, 1000});
    for (uint64_t composing = 0; composing <= 1; ++composing)
      for (uint64_t expired = 0; expired <= 1; ++expired)
        Observe({PolicyKind::Replacement, engine, 0, 1, composing, expired,
            !composing || expired});
  }
  // Exact input memoization, not speculative replay. A miss schedules copied
  // work and returns native immediately. try_lock also makes contention a miss.
  template<class NativeDecision>
  uint64_t Decide(Observation value, NativeDecision native_decision, bool known_native = false) {
    if (!Authoritative(value.kind)) {
      value.native_decision = native_decision();
      Observe(value); return value.native_decision;
    }
    value.caller_used = true; value.caller_tick = MemoNow();
    const auto key = Key(value);
    uint64_t result = 0;
    bool used = false;
    // Caller diagnostics stay bounded and never write logs or wait on IPC.
    unsigned miss = 0; // contention, unhealthy, absent, expired
    uint64_t age = 0;
    {
      std::unique_lock lock(mutex_, std::try_to_lock);
      if (lock.owns_lock() && healthy_) {
        miss = 2;
        const auto found = decisions_.find(key);
        if (found != decisions_.end()) {
          found->second.last_used = value.caller_tick;
          found->second.active = true;
          age = MemoNow() - found->second.at;
          miss = 3;
          if (age <= 30000) { result = found->second.value; used = true; }
        }
      } else if (lock.owns_lock()) miss = 1;
    }
    if (!used && HarnessDiagnostics()) {
      const auto kind = static_cast<unsigned>(value.kind);
      if (kind < misses_.size()) {
        auto& row = misses_[kind][miss];
        row.a = value.a; row.b = value.b; row.c = value.c;
        row.engine = value.engine_epoch; row.age = age; row.tick = GetTickCount64();
        ++row.count;
      }
    }
    if (used) PolicyCounters::Managed(value.kind);
    else result = native_decision();
    // Refresh still queues the same exact inputs. On an authoritative hit the
    // expected value is the memo answer, not a freshly evaluated native oracle.
    // OFF/SHADOW and misses retain the original native comparison value.
    if (!known_native) value.native_decision = result;
    Observe(value);
    const auto kind = static_cast<unsigned>(value.kind);
    if (kind < used_.size()) {
      ++(used ? used_[kind] : fallback_[kind]);
      if (known_native && used && result != value.native_decision) ++divergent_[kind];
    }
    return result;
  }
  // Eager observations are retained for the separate adapter equality tests.
  uint64_t Decide(const Observation& value) {
    return Decide(value, [&] { return value.native_decision; }, true);
  }
  void Stop() {
    stop_ = true; changed_.notify_all();
    if (worker_.joinable()) worker_.join();
    PolicyCounters::Log(true);
  }
  // Compiled only into the test-host control executable: deliberately waits
  // on the managed child from a pipe callback, exercising the actual IPC.
  void SynchronousControl() {
    if (!enabled_) return;
    const auto before = completed_.load();
    Observe({PolicyKind::Cache, 0, 0, 1, 0, 0, 0});
    std::unique_lock lock(mutex_);
    changed_.wait_for(lock, std::chrono::seconds(5), [&] {
      return completed_.load() != before || stop_;
    });
  }
 private:
  std::array<unsigned, 2> byte_modes_{};
  std::atomic<bool> test_shadow_{false};
  bool hn3_capable_ = false; // guarded by mutex_
  struct ByteRequest {
    hn3::Frame frame; std::string key, result;
    ULONGLONG deadline = 0; bool done = false, valid = false, cancelled = false;
  };
  std::deque<std::shared_ptr<ByteRequest>> byte_queue_;
  size_t byte_queued_ = 0, byte_memo_bytes_ = 0;
  std::map<std::string, std::string> byte_memo_;
  bool ReadBytes(std::string& data, size_t size, ULONGLONG deadline) {
    data.clear();
    while (data.size() < size && !stop_ && !g_stopping && GetTickCount64() < deadline) {
      if (WaitForSingleObject(process_, 0) != WAIT_TIMEOUT) return false;
      DWORD available = 0, read = 0;
      if (!PeekNamedPipe(output_, nullptr, 0, nullptr, &available, nullptr)) return false;
      if (!available) { Sleep(1); continue; }
      char chunk[4096]; const auto count = static_cast<DWORD>((std::min)(size-data.size(), (std::min)(size_t{4096}, size_t{available})));
      if (!ReadFile(output_, chunk, count, &read, nullptr) || !read) return false;
      data.append(chunk, read);
    }
    return data.size() == size;
  }
  bool ByteExchange(const std::shared_ptr<ByteRequest>& work) {
    // A caller may expire while queued behind HP2. No bytes were sent, so
    // dropping that work must not retire an otherwise synchronized stream.
    {
      std::lock_guard lock(mutex_);
      if (work->cancelled || GetTickCount64() >= work->deadline) {
        work->done = true; work->valid = false;
        changed_.notify_all();
        LogEvent("hn3-unsent-discard operation=" + std::to_string(static_cast<unsigned>(work->frame.operation)));
        return true;
      }
    }
    auto& f = work->frame; f.correlation = ++request_; f.policy_epoch = epoch_;
    hn3::Outstanding outstanding; outstanding.Begin(f);
    const auto wire = hn3::Encode(f);
    std::string header, tail; hn3::Frame reply;
    const char* step = "write";
    bool valid = !wire.empty() && TimedWriteAll(input_, wire, work->deadline);
    if (valid) { step = "read-header"; valid = ReadBytes(header, hn3::kHeader, work->deadline); }
    if (valid) {
      const auto size = hn3::Get(header,4,4);
      step = "body-length";
      valid = size >= hn3::kHeader-8 && size <= hn3::kHeader-8+hn3::kPayload;
      if (valid) { step = "read-body"; valid = ReadBytes(tail, static_cast<size_t>(size)-(hn3::kHeader-8), work->deadline); }
      if (valid) { step = "decode"; valid = hn3::Decode(header+tail,reply); }
      if (valid) { step = "envelope-fence"; valid = outstanding.Accept(reply); }
    }
    outstanding.Retire();
    {
      std::lock_guard lock(mutex_);
      if (valid) {
        step = "caller-fence";
        valid = !work->cancelled && f.engine_epoch == engine_epoch.load() && f.generation == publication_generation.load();
      }
      work->done = true; work->valid = valid && !reply.status;
      if (work->valid) {
        // Merge replies have one copied field. Startup retains the complete
        // validated frame for the typed native result adapter.
        if (f.operation == hn3::Operation::Startup) {
          auto canonical = reply; canonical.correlation = canonical.policy_epoch = canonical.engine_epoch = canonical.generation = 0;
          work->result = hn3::Encode(canonical);
        } else work->result = reply.fields.front();
        const auto bytes = work->key.size() + work->result.size();
        if (bytes <= hn3::kQueueBytes) {
          while (!byte_memo_.empty() && (byte_memo_.size() >= hn3::kRequests || byte_memo_bytes_ + bytes > hn3::kQueueBytes)) {
            const auto it = byte_memo_.begin(); byte_memo_bytes_ -= it->first.size()+it->second.size(); byte_memo_.erase(it);
          }
          const auto old = byte_memo_.find(work->key);
          if (old != byte_memo_.end()) byte_memo_bytes_ -= old->first.size()+old->second.size();
          byte_memo_[work->key] = work->result; byte_memo_bytes_ += bytes;
        }
      }
    }
    changed_.notify_all();
    if (!valid) LogEvent("hn3-timeout-or-invalid-discard request=" + std::to_string(f.correlation) +
        " operation=" + std::to_string(static_cast<unsigned>(f.operation)) + " step=" + step);
    // Never reuse a timed-out stream. Termination/handle close drains unread
    // late bytes; the next child has a different policy epoch.
    return valid;
  }
  bool enabled_ = false;
  std::array<bool, 5> switches_{};
  std::array<std::atomic<uint64_t>, 13> used_{}, fallback_{};
  std::array<std::atomic<uint64_t>, 13> divergent_{};
  static bool HarnessDiagnostics() {
    static const bool enabled = [] {
      wchar_t value[2]{};
      return GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", value, 2) == 1 && value[0] == L'1' &&
          NativeImeRegistryKey().starts_with(L"Software\\NativeIME-test-");
    }();
    return enabled;
  }
  struct MissSample {
    std::atomic<uint64_t> count{0}, a{0}, b{0}, c{0}, engine{0}, age{0}, tick{0};
  };
  std::array<std::array<MissSample, 4>, 13> misses_{};
  void LogDecisions() {
    PolicyCounters::Log();
    if (HarnessDiagnostics()) {
      const auto now = MemoNow();
      if (now - keepalive_log_at_ >= 1000 && (keepalive_refreshed_ || keepalive_skipped_)) {
        keepalive_log_at_ = now;
        LogEvent("policy-keepalive refreshed=" + std::to_string(keepalive_refreshed_) +
            " skipped=" + std::to_string(keepalive_skipped_));
      }
      const char* reasons[] = {"contention", "unhealthy", "absent", "expired"};
      for (size_t kind = 1; kind < misses_.size(); ++kind) {
        for (size_t reason = 0; reason < 4; ++reason) {
          auto& row = misses_[kind][reason];
          const auto count = row.count.exchange(0);
          if (!count) continue;
          // Last sample per kind/reason, approximate under concurrent callers.
          LogEvent(std::string("policy-miss-detail reason=") + reasons[reason] +
              " kind=" + std::to_string(kind) + " count=" + std::to_string(count) +
              " engine=" + std::to_string(row.engine.load()) +
              " a=" + std::to_string(row.a.load()) + " b=" + std::to_string(row.b.load()) +
              " c=" + std::to_string(row.c.load()) + " age_ms=" + std::to_string(row.age.load()) +
              " call_tick_ms=" + std::to_string(row.tick.load()) +
              " log_tick_ms=" + std::to_string(GetTickCount64()));
        }
      }
    }
    // Only the policy worker writes diagnostics; caller paths increment counters.
    for (size_t i = 1; i < used_.size(); ++i) {
      const auto used = used_[i].exchange(0), fallback = fallback_[i].exchange(0);
      const auto divergent = divergent_[i].exchange(0);
      if (used) LogEvent("policy-authoritative kind=" + std::to_string(i) + " count=" + std::to_string(used));
      if (divergent) LogEvent("policy-authoritative-difference kind=" + std::to_string(i) + " count=" + std::to_string(divergent));
      if (fallback) LogEvent("policy-fallback native reason=unavailable-or-stale kind=" +
          std::to_string(i) + " count=" + std::to_string(fallback));
    }
  }
  bool healthy_ = false; // guarded by mutex_; cleared on timeout/crash/retirement
  // Only memo time is injectable; IPC deadlines always use the real clock.
  uint64_t (*memo_clock_)() = nullptr;
  uint64_t MemoNow() const { return memo_clock_ ? memo_clock_() : GetTickCount64(); }
  static constexpr uint64_t kKeepaliveInterval = 5000, kKeepaliveAge = 20000,
      kKeepaliveRecent = 600000;
  static constexpr size_t kKeepaliveLimit = 64;
  uint64_t keepalive_last_ = 0, keepalive_refreshed_ = 0, keepalive_skipped_ = 0, keepalive_log_at_ = 0;
  struct Decision {
    uint64_t value, at;
    Observation inputs{};
    uint64_t last_used = 0;
    bool active = false;
  };
  // Worker-only selection. Copy under the lock, release it before any IPC.
  std::deque<Observation> Keepalive() {
    std::deque<Observation> work;
    const auto now = MemoNow();
    if (now - keepalive_last_ < kKeepaliveInterval) return work;
    keepalive_last_ = now;
    std::lock_guard lock(mutex_);
    const auto engine = engine_epoch.load();
    for (auto it = decisions_.begin(); it != decisions_.end();) {
      auto& entry = it->second;
      if (entry.inputs.engine_epoch != engine) {
        ++keepalive_skipped_; it = decisions_.erase(it); continue;
      }
      if (!healthy_ || !entry.active || now - entry.last_used > kKeepaliveRecent ||
          !Authoritative(entry.inputs.kind) || now - entry.at < kKeepaliveAge ||
          work.size() >= kKeepaliveLimit) {
        ++keepalive_skipped_; ++it; continue;
      }
      auto value = entry.inputs;
      value.native_decision = entry.value; // Compare against the previous child answer.
      value.caller_used = false;
      work.push_back(value); ++it;
    }
    return work;
  }
  bool KeepaliveCurrent(const Observation& value) {
    std::lock_guard lock(mutex_);
    const auto found = decisions_.find(Key(value));
    return healthy_ && value.engine_epoch == engine_epoch.load() &&
        found != decisions_.end() && found->second.active &&
        MemoNow() - found->second.last_used <= kKeepaliveRecent &&
        MemoNow() - found->second.at >= kKeepaliveAge;
  }
  std::map<std::string, Decision> decisions_;
  static std::string Key(const Observation& v) {
    // Policy algorithms are pure numeric functions: context is an audit label,
    // publication generation is an envelope guard, not a decision input.
    // c is relevant only to replacement/intent/payload. Engine changes discard rules.
    const auto c = v.kind == PolicyKind::Replacement || v.kind == PolicyKind::Intent || v.kind == PolicyKind::Payload ? v.c : 0;
    return std::to_string(static_cast<unsigned>(v.kind)) + ":" + std::to_string(v.engine_epoch) + ":" +
        std::to_string(v.a) + ":" + std::to_string(v.b) + ":" + std::to_string(c);
  }
  void Seed(uint64_t engine) {
    auto seed = [&](PolicyKind kind, uint64_t a, uint64_t b, uint64_t c, uint64_t expected) {
      if (Authoritative(kind)) Observe({kind, engine, 0, a, b, c, expected});
    };
    for (uint64_t a = 0; a <= 1; ++a) for (uint64_t b = 0; b <= 1; ++b) {
      seed(PolicyKind::Sources, a, b, 0, !a ? 0 : (b ? 1 : 2));
      seed(PolicyKind::Order, a, b, 0, a ? (b ? 1 : 0) : (b ? 2 : 0));
      seed(PolicyKind::Cache, a, b ? (a ? 60000 : 2000) : 0, 0, b);
      seed(PolicyKind::Capacity, a ? 256 : 0, b, 0, !a || b);
      for (uint64_t c = 0; c <= 1; ++c) {
        seed(PolicyKind::Replacement, a, b, c, a && (!b || c));
        seed(PolicyKind::Payload, a, b, c, a ? (b ? 2 : (c ? 1 : 0)) : 0);
      }
      for (uint64_t c = 0; c <= 2; ++c) seed(PolicyKind::Intent, a, b, c, a && b && c);
    }
    seed(PolicyKind::CacheTtl, 0, 0, 0, 2000); seed(PolicyKind::CacheTtl, 1, 0, 0, 60000);
    seed(PolicyKind::Learning, 0, 1, 0, 0); seed(PolicyKind::Learning, 1, 1, 0, 1);
    for (uint64_t a : {1000, 2000, 4000, 8000, 16000, 30000}) {
      seed(PolicyKind::Restart, a, 0, 0, (std::min)(uint64_t{30000}, a * 2));
      seed(PolicyKind::Restart, a, 1, 0, 1000);
    }
  }
  static bool ValidDecision(PolicyKind kind, uint64_t value) {
    if (kind == PolicyKind::CacheTtl) return value >= 100 && value <= 60000;
    if (kind == PolicyKind::Restart) return value >= 1000 && value <= 30000;
    if (kind == PolicyKind::Sources || kind == PolicyKind::Order || kind == PolicyKind::Payload) return value <= 2;
    return value <= 1;
  }
  bool Remember(const Observation& value, uint64_t decision, bool keepalive = false) {
    if (!Authoritative(value.kind)) return false;
    std::lock_guard lock(mutex_);
    // An epoch change during IPC must not resurrect a selected keep-alive key.
    if (keepalive && (!healthy_ || value.engine_epoch != engine_epoch.load() ||
        !decisions_.contains(Key(value)))) return false;
    if (decisions_.size() >= kRequests && !decisions_.contains(Key(value)))
      decisions_.erase(decisions_.begin());
    auto& entry = decisions_[Key(value)];
    entry.value = decision; entry.at = MemoNow(); entry.inputs = value;
    if (value.caller_used) {
      entry.last_used = entry.active ? (std::max)(entry.last_used, value.caller_tick) : value.caller_tick;
      entry.active = true;
    }
    if (keepalive) ++keepalive_refreshed_;
    return true;
  }
  void Timeout(const Observation& value) {
    std::lock_guard lock(mutex_); decisions_.erase(Key(value));
  }
  void Invalidate() {
    std::lock_guard lock(mutex_); healthy_ = false; hn3_capable_ = false; decisions_.clear();
    byte_memo_.clear(); byte_memo_bytes_ = 0;
    for (const auto& work : byte_queue_) { work->done = true; work->valid = false; }
    byte_queue_.clear(); byte_queued_ = 0; changed_.notify_all();
  }
  std::atomic<bool> stop_{false};
  std::atomic<uint64_t> dropped_{0};
  std::atomic<uint64_t> completed_{0};
  std::mutex mutex_; std::condition_variable changed_;
  std::deque<Observation> queue_; std::thread worker_;
  std::wstring runtime_, repository_; HANDLE job_ = nullptr;
  bool native_attempt_ = false, interpreted_retry_ = false;
  std::string bundle_summary_;
  static std::wstring Environment(const wchar_t* name) {
    const DWORD size = GetEnvironmentVariableW(name, nullptr, 0);
    if (!size) return {};
    std::wstring value(size, 0);
    const DWORD used = GetEnvironmentVariableW(name, value.data(), size);
    if (!used || used >= size) return {};
    value.resize(used); return value;
  }
  static std::wstring BundlePath(const std::string& text) {
    if (text.empty() || text.find_first_of("\r\n\t\"") != std::string::npos) return {};
    const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), nullptr, 0);
    if (!size) return {};
    std::wstring path(size, 0);
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), path.data(), size);
    return std::filesystem::path(path).is_absolute() ? path : std::wstring{};
  }
  static std::string BundleHash(const std::wstring& path) {
    std::ifstream stream(std::filesystem::path(path), std::ios::binary);
    BCRYPT_ALG_HANDLE algorithm = nullptr; BCRYPT_HASH_HANDLE hash = nullptr;
    if (!stream || BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0) return {};
    std::string result;
    if (BCryptCreateHash(algorithm, &hash, nullptr, 0, nullptr, 0, 0) >= 0) {
      std::array<char, 65536> buffer{}; bool ok = true;
      while (stream) {
        stream.read(buffer.data(), buffer.size());
        if (stream.gcount() && BCryptHashData(hash, reinterpret_cast<PUCHAR>(buffer.data()), static_cast<ULONG>(stream.gcount()), 0) < 0) { ok = false; break; }
      }
      std::array<unsigned char, 32> digest{};
      if (ok && stream.eof() && BCryptFinishHash(hash, digest.data(), static_cast<ULONG>(digest.size()), 0) >= 0) {
        const char* hex = "0123456789abcdef";
        for (auto byte : digest) { result += hex[byte >> 4]; result += hex[byte & 15]; }
      }
      BCryptDestroyHash(hash);
    }
    BCryptCloseAlgorithmProvider(algorithm, 0); return result;
  }
  bool NativeCommand(std::wstring& command) {
    const auto runtime = Environment(L"DDSKK_HOST_POLICY_RUNTIME");
    bundle_summary_.clear();
    const auto bundle = Environment(L"DDSKK_HOST_POLICY_BUNDLE");
    if (runtime.empty() && bundle.empty()) return false;
    try {
      if (runtime.empty() || bundle.empty()) throw std::runtime_error("both runtime and bundle required");
      std::ifstream manifest(std::filesystem::path(bundle) / L"manifest.tsv", std::ios::binary);
      std::string line;
      if (!std::getline(manifest, line) || line != "HN-BUNDLE-1") throw std::runtime_error("manifest header");
      std::map<char, std::wstring> roles; std::vector<std::wstring> dirs;
      std::unordered_set<std::wstring> pinned; size_t hashes = 0;
      while (std::getline(manifest, line)) {
        if (line.size() > 32768 || line.size() < 4 || line[1] != '\t') throw std::runtime_error("manifest row");
        const auto tab = line.find('\t', 2);
        if (tab == std::string::npos) throw std::runtime_error("manifest fields");
        const auto path = BundlePath(line.substr(tab + 1));
        if (path.empty()) throw std::runtime_error("manifest path");
        if (line[0] == 'L') {
          if (line.substr(2, tab - 2) != "-" || !std::filesystem::is_directory(path)) throw std::runtime_error("load directory");
          if (std::find(dirs.begin(), dirs.end(), path) != dirs.end()) throw std::runtime_error("duplicate load directory");
          dirs.push_back(path); continue;
        }
        if (std::string("RCSDBH").find(line[0]) == std::string::npos ||
            line.substr(2, tab - 2).size() != 64 || BundleHash(path) != line.substr(2, tab - 2))
          throw std::runtime_error("manifest hash mismatch");
        ++hashes;
        if (!pinned.insert(std::filesystem::path(path).lexically_normal().wstring()).second) throw std::runtime_error("duplicate pin");
        if (line[0] != 'H' && !roles.emplace(line[0], path).second) throw std::runtime_error("duplicate role");
      }
      if (!manifest.eof() || hashes < 15 || dirs.size() != 5 || roles.size() != 5 ||
          roles['R'] != runtime || roles['C'] != runtime + L".cold" || roles['S'] != runtime + L".native-startup.el" ||
          std::filesystem::path(roles['D']).lexically_normal() != (std::filesystem::path(bundle) / L"driver.el").lexically_normal())
        throw std::runtime_error("manifest runtime/companion/driver mismatch");
      for (const auto* name : {L"host-policy", L"host-native-skk", L"host-native-startup"}) {
        for (const auto& path : {std::filesystem::path(repository_) / L"engine" / (std::wstring(name) + L".el"),
                               std::filesystem::path(bundle) / (std::wstring(name) + L".el"),
                               std::filesystem::path(bundle) / (std::wstring(name) + L".elc")})
          if (!pinned.contains(path.lexically_normal().wstring())) throw std::runtime_error("missing source/bytecode pin");
      }
      if (!pinned.contains((std::filesystem::path(bundle) / L"manifest.json").lexically_normal().wstring()))
        throw std::runtime_error("missing compiler/generation manifest pin");
      if (std::filesystem::path(roles['B']).lexically_normal() !=
          (std::filesystem::path(bundle) / L"bundle-report.txt").lexically_normal() ||
          !pinned.contains((std::filesystem::path(bundle) / L"compiled.el").lexically_normal().wstring()))
        throw std::runtime_error("missing bundle report/state pin");
      std::ifstream report(std::filesystem::path(roles['B']), std::ios::binary);
      if (!std::getline(report, bundle_summary_) || bundle_summary_.size() > 32768)
        throw std::runtime_error("invalid bundle report");
      std::istringstream summary(bundle_summary_);
      std::string tag, native, interpreted, refused, extra;
      summary >> tag >> native >> interpreted >> refused;
      const auto count = [](const std::string& token, const std::string& prefix) {
        if (!token.starts_with(prefix) || token.size() == prefix.size() ||
            token.find_first_not_of("0123456789", prefix.size()) != std::string::npos)
          throw std::runtime_error("invalid bundle count");
        return std::stoull(token.substr(prefix.size()));
      };
      if (tag != "HN-BUNDLE" || (summary >> extra) || count(native, "native=") == 0 ||
          !refused.starts_with("refused=") || refused.size() == 8)
        throw std::runtime_error("invalid bundle report/zero native functions");
      const auto names = refused.substr(8);
      const auto refusals = names == "-" ? 0 : 1 + std::count(names.begin(), names.end(), ',');
      if (count(interpreted, "interpreted=") != static_cast<unsigned long long>(refusals))
        throw std::runtime_error("bundle refusal count mismatch");
      command = L"\"" + runtime + L"\" --cold-load-from \"" + roles['C'] + L"\"";
      for (const auto& dir : dirs) command += L" -L \"" + dir + L"\"";
      command += L" -l \"" + roles['D'] + L"\"";
      return true;
    } catch (const std::exception& error) {
      LogEvent(std::string("policy-native-refused reason=") + error.what()); return false;
    }
  }
  HANDLE process_ = nullptr, input_ = nullptr, output_ = nullptr;
  uint64_t epoch_ = 0, request_ = 0;
  static std::string Digits(uint64_t value, size_t width) {
    std::string result(width, ' ');
    for (size_t i = width; i; --i) { result[i-1] += value & 63; value >>= 6; }
    return result;
  }
  static std::string Frame(uint64_t id, const Observation& v) {
    const auto kind = static_cast<unsigned>(v.kind);
    // Values outside the lossless HP2 range stay native; never truncate them.
    if (kind < 1 || kind > 12 || v.a > 262143 || v.b > 262143 || v.c > 262143 ||
        v.context_size > v.context.size()) return {};
    if (kind == 1 && v.a > 1) return {};
    const auto scalar = kind == 4 ? v.b : (kind == 3 || kind == 8 ? v.a : 0);
    // Saturation at two preserves every zero/one/nonzero predicate. The
    // three genuinely quantitative branches carry their original scalar.
    return "HP2Q" + Digits(id, 11) + char(32 + kind) +
        char(32 + (std::min)(v.a, uint64_t{2})) +
        char(32 + (std::min)(v.b, uint64_t{2})) +
        char(32 + (std::min)(v.c, uint64_t{2})) + Digits(scalar, 3) + "\n";
  }
  static bool ValidReply(const std::string& reply, const std::string& prefix) {
    if (!reply.starts_with(prefix)) return false;
    const auto length = reply.size() - prefix.size();
    return prefix.size() == 15 && length == 3 &&
        std::all_of(reply.begin() + prefix.size(), reply.end(), [](unsigned char ch) { return ch >= 32 && ch <= 95; });
  }

  void Retire() {
    Invalidate();
    if (process_) {
      TerminateProcess(process_, 1); WaitForSingleObject(process_, 5000);
      LogEvent("policy-retire pid=" + std::to_string(GetProcessId(process_)) +
          " epoch=" + std::to_string(epoch_));
    }
    Close(input_); Close(output_); Close(process_);
  }
  bool Launch() {
    SECURITY_ATTRIBUTES security{sizeof(security), nullptr, TRUE};
    HANDLE in_read = nullptr, out_write = nullptr;
    // stdout is the protocol transport. Runtime diagnostics on stderr must
    // never become READY/HP2/HN3 bytes, including interpreted fallback starts.
    HANDLE error_sink = CreateFileW(L"NUL", GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
        &security, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (error_sink == INVALID_HANDLE_VALUE) return false;
    if (!CreatePipe(&in_read, &input_, &security, 4096) ||
        !CreatePipe(&output_, &out_write, &security, 4096)) {
      Close(in_read); Close(out_write); Close(error_sink); Retire(); return false;
    }
    SetHandleInformation(input_, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(output_, HANDLE_FLAG_INHERIT, 0);
    // Only these two child handles are inherited. In particular, no public
    // endpoint, engine stdio, journal or job handle enters the policy process.
    SIZE_T bytes = 0;
    InitializeProcThreadAttributeList(nullptr, 1, 0, &bytes);
    std::vector<unsigned char> attributes(bytes);
    STARTUPINFOEXW si{}; si.StartupInfo.cb = sizeof(si);
    si.lpAttributeList = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attributes.data());
    if (!InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, &bytes)) {
      Close(in_read); Close(out_write); Close(error_sink); Retire(); return false;
    }
    HANDLE handles[] = {in_read, out_write, error_sink};
    const bool updated = UpdateProcThreadAttribute(si.lpAttributeList, 0,
        PROC_THREAD_ATTRIBUTE_HANDLE_LIST, handles, sizeof(handles), nullptr, nullptr) != 0;
    si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    si.StartupInfo.hStdInput = in_read;
    si.StartupInfo.hStdOutput = out_write;
    si.StartupInfo.hStdError = error_sink;
    PROCESS_INFORMATION pi{};
    std::wstring command = L"\"" + runtime_ + L"\" --load engine/host-policy.el";
    native_attempt_ = !interpreted_retry_ && NativeCommand(command);
    interpreted_retry_ = false;
    const bool started = updated && CreateProcessW(nullptr, command.data(), nullptr, nullptr,
        TRUE, EXTENDED_STARTUPINFO_PRESENT | CREATE_SUSPENDED | CREATE_NO_WINDOW |
        BELOW_NORMAL_PRIORITY_CLASS, nullptr, repository_.c_str(), &si.StartupInfo, &pi);
    DeleteProcThreadAttributeList(si.lpAttributeList);
    Close(in_read); Close(out_write); Close(error_sink);
    if (!started) { Retire(); return false; }
    if (!AssignProcessToJobObject(job_, pi.hProcess)) {
      TerminateProcess(pi.hProcess, 1); CloseHandle(pi.hProcess); CloseHandle(pi.hThread);
      Retire(); return false;
    }
    process_ = pi.hProcess; ++epoch_;
    ResumeThread(pi.hThread); CloseHandle(pi.hThread);
    LogEvent("policy-start pid=" + std::to_string(pi.dwProcessId) + " epoch=" + std::to_string(epoch_));
    return true;
  }
  bool Line(std::string& line, DWORD timeout) {
    line.clear(); const auto deadline = GetTickCount64() + timeout;
    while (!stop_ && !g_stopping && GetTickCount64() < deadline) {
      if (WaitForSingleObject(process_, 0) != WAIT_TIMEOUT) return false;
      DWORD available = 0;
      if (!PeekNamedPipe(output_, nullptr, 0, nullptr, &available, nullptr)) return false;
      if (!available) { Sleep(1); continue; }
      char ch; DWORD read = 0;
      if (!ReadFile(output_, &ch, 1, &read, nullptr) || read != 1) return false;
      if (ch == '\n') return true;
      if (ch == '\r' || line.size() >= kFrame) return false;
      line.push_back(ch);
    }
    return false;
  }
  void Run() {
    // This worker exclusively owns launch, READY, every exchange and retire.
    // Callers/prefetch only queue copied work; keep-alive runs below READY and
    // uses the same serial exchange path, never a second transport thread.
    uint64_t seeded_engine = ~uint64_t{0};
    DWORD backoff = 1000;
    while (!stop_ && !g_stopping) {
      const auto start = GetTickCount64(); std::string reply;
      const bool launched = Launch();
      const bool ready = launched && Line(reply, 60000);
      const bool native_ready = reply == "HP2 READY HN3=1 native=1";
      if (!ready || (reply != "HP2 READY" && reply != "HP2 READY HN3=1" && reply != "HP2 READY HN3=1 native=0" && !native_ready) ||
          (native_attempt_ && !native_ready)) {
        // Preserve bounded wire evidence without injecting control characters
        // into logs. Distinguish a bad line from a failed/partial read.
        std::string hex;
        for (unsigned char ch : reply) {
          hex += "0123456789abcdef"[ch >> 4]; hex += "0123456789abcdef"[ch & 15];
        }
        LogEvent("policy-ready-rejected line_complete=" + std::to_string(ready) +
            " bytes=" + std::to_string(reply.size()) + " hex=" + hex);
        if (native_attempt_) {
          LogEvent("policy-native-refused reason=load-or-ready-failed");
          interpreted_retry_ = true;
          LogDecisions(); Retire(); continue;
        }
        if (!reply.empty() && reply != "HP2 READY" && reply != "HP2 READY HN3=1")
          LogEvent("policy-fallback native reason=incompatible-policy-ready-protocol");
        LogDecisions(); LogEvent("policy-start-failed"); Retire();
        const auto until = GetTickCount64() + backoff;
        while (!stop_ && !g_stopping && GetTickCount64() < until) Sleep(10);
        // A failed policy child cannot authorize its own recovery. This native
        // supervisor backoff is excluded from caller-policy retirement/coverage.
        backoff = (std::min)(DWORD{30000}, backoff * 2); continue;
      }
      backoff = 1000; seeded_engine = ~uint64_t{0};
      { std::lock_guard lock(mutex_); healthy_ = true; hn3_capable_ = reply.starts_with("HP2 READY HN3=1"); changed_.notify_all(); }
      if (native_ready) LogEvent(bundle_summary_);
      LogEvent("policy-ready startup_ms=" + std::to_string(GetTickCount64() - start) + " native=" + (native_ready ? "1" : "0"));
      LogEvent("policy-decision-accounting v=1");
      std::deque<Observation> keepalive_work;
      while (!stop_ && !g_stopping) {
        LogDecisions();
        const auto current_engine = engine_epoch.load();
        if (seeded_engine != current_engine) {
          {
            std::lock_guard lock(mutex_);
            // A warming engine can already have genuine restart answers. Keep
            // only those tagged with the epoch being published; all other
            // policy rules retain their original engine-change invalidation.
            const auto restart = "3:" + std::to_string(current_engine) + ":";
            const auto replacement = "7:" + std::to_string(current_engine) + ":";
            for (auto it = decisions_.begin(); it != decisions_.end();) {
              if (it->first.starts_with(restart) || it->first.starts_with(replacement)) ++it;
              else it = decisions_.erase(it);
            }
          }
          { std::lock_guard lock(mutex_); byte_memo_.clear(); byte_memo_bytes_ = 0; }
          keepalive_work.clear();
          seeded_engine = current_engine; Seed(current_engine);
        }
        if (keepalive_work.empty()) keepalive_work = Keepalive();
        std::shared_ptr<ByteRequest> byte_work;
        {
          std::lock_guard lock(mutex_);
          if (!byte_queue_.empty()) { byte_work = byte_queue_.front(); byte_queue_.pop_front(); byte_queued_ -= byte_work->key.size(); }
        }
        if (byte_work) {
          if (!ByteExchange(byte_work)) break;
          continue;
        }
        Observation v{};
        bool keepalive = false;
        if (!keepalive_work.empty()) {
          v = keepalive_work.front(); keepalive_work.pop_front();
          if (!KeepaliveCurrent(v)) { ++keepalive_skipped_; continue; }
          keepalive = true;
        } else {
          std::unique_lock lock(mutex_);
          changed_.wait_for(lock, std::chrono::milliseconds(100), [&] { return stop_ || !queue_.empty() || !byte_queue_.empty(); });
          if (queue_.empty()) {
            if (WaitForSingleObject(process_, 0) != WAIT_TIMEOUT) break;
            continue;
          }
          v = queue_.front(); queue_.pop_front();
        }
        const auto exchange_start = GetTickCount64();
        const auto id = ++request_;
        if (HarnessDiagnostics()) LogEvent("policy-request request=" + std::to_string(id) +
            " kind=" + std::to_string(static_cast<unsigned>(v.kind)) + " key=" + Key(v));
        const auto prefix = "HP2R" + Digits(id, 11);
        const auto frame = Frame(id, v);
        if (frame.empty()) {
          Timeout(v); ++dropped_; if (!keepalive) ++completed_; changed_.notify_all();
          LogEvent("policy-fallback native reason=hp2-input-bounds"); continue;
        }
        // One outstanding frame, <4096 bytes, into an empty 4096-byte pipe.
        // A timed-out channel is retired before another write; no blocked
        // policy can accumulate writes and stall this worker's shutdown.
        if (frame.size() > kFrame || !WriteAll(input_, frame) || !Line(reply, 200)) {
          // A slow refresh invalidates its signature, not independently
          // validated pure answers. Crash/retirement still clears everything.
          Timeout(v);
          if (!keepalive) ++completed_; changed_.notify_all();
          LogEvent("policy-timeout-discard request=" + std::to_string(id));
          // Keep one outstanding ID while the paused child resumes; discard
          // its late response before writing anything else. Hard limit 5 s.
          if (Line(reply, 5000) && ValidReply(reply, prefix)) {
            LogEvent("policy-late-discard request=" + std::to_string(id));
            { std::lock_guard lock(mutex_); healthy_ = true; }
            continue;
          }
          break;
        }
        if (!ValidReply(reply, prefix)) {
          LogEvent("policy-invalid-reply request=" + std::to_string(id)); break;
        }
        const uint64_t decision = (reply[15] - 32) * 4096 +
            (reply[16] - 32) * 64 + reply[17] - 32;
        if (!ValidDecision(v.kind, decision)) { LogEvent("policy-invalid-decision"); break; }
        if (!Remember(v, decision, keepalive) && keepalive) ++keepalive_skipped_;
        const auto expected = prefix + Digits(v.native_decision, 3);
        if (!keepalive) ++completed_; changed_.notify_all();
        LogEvent(std::string("policy-compare ") + (reply == expected ? "match" : "mismatch") +
            " request=" + std::to_string(id) + " kind=" + std::to_string(static_cast<unsigned>(v.kind)) +
            (keepalive ? " keepalive=1" : "") +
            (HarnessDiagnostics() ? " elapsed_ms=" + std::to_string(GetTickCount64() - exchange_start) : ""));
        if (!reply.starts_with(prefix)) break;
      }
      Retire();
      const auto until = GetTickCount64() + 1000;
      while (!stop_ && !g_stopping && GetTickCount64() < until) Sleep(10);
    }
    Retire();
    LogDecisions();
    LogEvent("policy-stop dropped=" + std::to_string(dropped_.load()));
  }
};
// Detached native clients can finish during CRT teardown. Keep the value
// queue/mutex alive for process lifetime; wmain explicitly joins supervision.
inline ShadowPolicy& shadow = *new ShadowPolicy;
template<class NativeDecision>
inline uint64_t Decide(PolicyKind kind, uint64_t a, uint64_t b, uint64_t c, NativeDecision native_decision,
                       const std::string& context = {}, uint64_t observed_epoch = 0) {
  if (!shadow.Enabled()) return native_decision();
  if (context.size() > 1024) { shadow.Reject(); return native_decision(); }
  Observation value{kind, observed_epoch ? observed_epoch : engine_epoch.load(),
      publication_generation.load(), a, b, c, 0};
  value.context_size = context.size();
  std::copy(context.begin(), context.end(), value.context.begin());
  return shadow.Decide(value, native_decision);
}
inline void Observe(PolicyKind kind, uint64_t a, uint64_t b, uint64_t c, uint64_t decision,
                    const std::string& context = {}, uint64_t observed_epoch = 0) {
  // Oversized diagnostic inputs are rejected whole, never truncated into a
  // different source identity. They cannot change the native decision.
  if (!shadow.Enabled()) return;
  if (context.size() > 1024) { shadow.Reject(); return; }
  Observation value{kind, observed_epoch ? observed_epoch : engine_epoch.load(),
      publication_generation.load(), a, b, c, decision};
  value.context_size = context.size();
  std::copy(context.begin(), context.end(), value.context.begin());
  shadow.Observe(value);
}
} // namespace native_adapter
