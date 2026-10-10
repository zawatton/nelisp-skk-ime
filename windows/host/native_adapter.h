// Native ownership boundary: copied decisions only. Policy has no OS handles,
// storage writers or engine transaction capability. Callers never wait on IPC.
#pragma once

namespace native_adapter {
inline std::atomic<uint64_t> next_engine_epoch{0}, engine_epoch{0}, publication_generation{0};
enum class PolicyKind { Config = 1, Sources = 2, Restart = 3, Cache = 4, Publication = 5, Learning = 6, Replacement = 7, Capacity = 8, Intent = 9, Order = 10, Payload = 11, CacheTtl = 12 };
struct Observation {
  PolicyKind kind;
  uint64_t engine_epoch, publication_generation, a, b, c, native_decision;
  std::array<char, 1024> context{};
  size_t context_size = 0;
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
    if (!policy_bundle::Compatible(runtime, repository)) {
      enabled_ = false; switches_.fill(false);
    }
    if (!enabled_) return;
    runtime_ = runtime; repository_ = repository; job_ = job;
    worker_ = std::thread([this] { Run(); });
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
  // Exact input memoization, not speculative replay. A miss schedules copied
  // work and returns native immediately. try_lock also makes contention a miss.
  uint64_t Decide(const Observation& value) {
    if (!Authoritative(value.kind)) { Observe(value); return value.native_decision; }
    const auto key = Key(value);
    uint64_t result = value.native_decision;
    bool used = false;
    {
      std::unique_lock lock(mutex_, std::try_to_lock);
      if (lock.owns_lock() && healthy_) {
        const auto found = decisions_.find(key);
        if (found != decisions_.end() && GetTickCount64() - found->second.at <= 30000) {
          result = found->second.value; used = true;
        }
      }
    }
    Observe(value);
    const auto kind = static_cast<unsigned>(value.kind);
    if (kind < used_.size()) {
      ++(used ? used_[kind] : fallback_[kind]);
      if (used && result != value.native_decision) ++divergent_[kind];
    }
    return result;
  }
  void Stop() {
    stop_ = true; changed_.notify_all();
    if (worker_.joinable()) worker_.join();
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
  bool enabled_ = false;
  std::array<bool, 5> switches_{};
  std::array<std::atomic<uint64_t>, 13> used_{}, fallback_{};
  std::array<std::atomic<uint64_t>, 13> divergent_{};
  void LogDecisions() {
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
  struct Decision { uint64_t value, at; };
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
  void Remember(const Observation& value, uint64_t decision) {
    if (!Authoritative(value.kind)) return;
    std::lock_guard lock(mutex_);
    if (decisions_.size() >= kRequests && !decisions_.contains(Key(value)))
      decisions_.erase(decisions_.begin());
    decisions_[Key(value)] = {decision, GetTickCount64()};
  }
  void Timeout(const Observation& value) {
    std::lock_guard lock(mutex_); decisions_.erase(Key(value));
  }
  void Invalidate() {
    std::lock_guard lock(mutex_); healthy_ = false; decisions_.clear();
  }
  std::atomic<bool> stop_{false};
  std::atomic<uint64_t> dropped_{0};
  std::atomic<uint64_t> completed_{0};
  std::mutex mutex_; std::condition_variable changed_;
  std::deque<Observation> queue_; std::thread worker_;
  std::wstring runtime_, repository_; HANDLE job_ = nullptr;
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
    if (!CreatePipe(&in_read, &input_, &security, 4096) ||
        !CreatePipe(&output_, &out_write, &security, 4096)) {
      Close(in_read); Close(out_write); Retire(); return false;
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
      Close(in_read); Close(out_write); Retire(); return false;
    }
    HANDLE handles[] = {in_read, out_write};
    const bool updated = UpdateProcThreadAttribute(si.lpAttributeList, 0,
        PROC_THREAD_ATTRIBUTE_HANDLE_LIST, handles, sizeof(handles), nullptr, nullptr) != 0;
    si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    si.StartupInfo.hStdInput = in_read;
    si.StartupInfo.hStdOutput = out_write;
    si.StartupInfo.hStdError = out_write;
    PROCESS_INFORMATION pi{};
    std::wstring command = L"\"" + runtime_ + L"\" --load engine/host-policy.el";
    const bool started = updated && CreateProcessW(nullptr, command.data(), nullptr, nullptr,
        TRUE, EXTENDED_STARTUPINFO_PRESENT | CREATE_SUSPENDED | CREATE_NO_WINDOW |
        BELOW_NORMAL_PRIORITY_CLASS, nullptr, repository_.c_str(), &si.StartupInfo, &pi);
    DeleteProcThreadAttributeList(si.lpAttributeList);
    Close(in_read); Close(out_write);
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
    uint64_t seeded_engine = ~uint64_t{0};
    DWORD backoff = 1000;
    while (!stop_ && !g_stopping) {
      const auto start = GetTickCount64(); std::string reply;
      if (!Launch() || !Line(reply, 60000) || reply != "HP2 READY") {
        if (!reply.empty() && reply != "HP2 READY")
          LogEvent("policy-fallback native reason=incompatible-policy-ready-protocol");
        LogDecisions(); LogEvent("policy-start-failed"); Retire();
        const auto until = GetTickCount64() + backoff;
        while (!stop_ && !g_stopping && GetTickCount64() < until) Sleep(10);
        backoff = (std::min)(DWORD{30000}, backoff * 2); continue;
      }
      backoff = 1000; seeded_engine = ~uint64_t{0};
      { std::lock_guard lock(mutex_); healthy_ = true; }
      LogEvent("policy-ready startup_ms=" + std::to_string(GetTickCount64() - start));
      LogEvent("policy-decision-accounting v=1");
      while (!stop_ && !g_stopping) {
        LogDecisions();
        const auto current_engine = engine_epoch.load();
        if (seeded_engine != current_engine) {
          { std::lock_guard lock(mutex_); decisions_.clear(); }
          seeded_engine = current_engine; Seed(current_engine);
        }
        Observation v{};
        {
          std::unique_lock lock(mutex_);
          changed_.wait_for(lock, std::chrono::milliseconds(100), [&] { return stop_ || !queue_.empty(); });
          if (queue_.empty()) {
            if (WaitForSingleObject(process_, 0) != WAIT_TIMEOUT) break;
            continue;
          }
          v = queue_.front(); queue_.pop_front();
        }
        const auto id = ++request_;
        const auto prefix = "HP2R" + Digits(id, 11);
        const auto frame = Frame(id, v);
        if (frame.empty()) {
          Timeout(v); ++dropped_; ++completed_; changed_.notify_all();
          LogEvent("policy-fallback native reason=hp2-input-bounds"); continue;
        }
        // One outstanding frame, <4096 bytes, into an empty 4096-byte pipe.
        // A timed-out channel is retired before another write; no blocked
        // policy can accumulate writes and stall this worker's shutdown.
        if (frame.size() > kFrame || !WriteAll(input_, frame) || !Line(reply, 200)) {
          // A slow refresh invalidates its signature, not independently
          // validated pure answers. Crash/retirement still clears everything.
          Timeout(v);
          ++completed_; changed_.notify_all();
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
        Remember(v, decision);
        const auto expected = prefix + Digits(v.native_decision, 3);
        ++completed_; changed_.notify_all();
        LogEvent(std::string("policy-compare ") + (reply == expected ? "match" : "mismatch") +
            " request=" + std::to_string(id) + " kind=" + std::to_string(static_cast<unsigned>(v.kind)));
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
inline uint64_t Decide(PolicyKind kind, uint64_t a, uint64_t b, uint64_t c, uint64_t decision,
                       const std::string& context = {}, uint64_t observed_epoch = 0) {
  if (!shadow.Enabled()) return decision;
  if (context.size() > 1024) { shadow.Reject(); return decision; }
  Observation value{kind, observed_epoch ? observed_epoch : engine_epoch.load(),
      publication_generation.load(), a, b, c, decision};
  value.context_size = context.size();
  std::copy(context.begin(), context.end(), value.context.begin());
  return shadow.Decide(value);
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
