// Native ownership boundary: copied shadow observations only. No policy reply
// is a capability to publish, learn, dispatch an engine request or answer IO.
#pragma once

namespace native_adapter {
enum class PolicyKind { Config = 1, Sources = 2, Restart = 3, Cache = 4, Publication = 5 };
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
    queue_.push_back(value); changed_.notify_one();
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
  std::atomic<bool> stop_{false};
  std::atomic<uint64_t> dropped_{0};
  std::atomic<uint64_t> completed_{0};
  std::mutex mutex_; std::condition_variable changed_;
  std::deque<Observation> queue_; std::thread worker_;
  std::wstring runtime_, repository_; HANDLE job_ = nullptr;
  HANDLE process_ = nullptr, input_ = nullptr, output_ = nullptr;
  uint64_t epoch_ = 0, request_ = 0;
  static bool ValidReply(const std::string& reply, const std::string& prefix) {
    if (!reply.starts_with(prefix)) return false;
    const auto length = reply.size() - prefix.size();
    return length > 0 && length <= 20 &&
        std::all_of(reply.begin() + prefix.size(), reply.end(), [](char ch) { return ch >= '0' && ch <= '9'; });
  }

  void Retire() {
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
    DWORD backoff = 1000;
    while (!stop_ && !g_stopping) {
      const auto start = GetTickCount64(); std::string reply;
      if (!Launch() || !Line(reply, 60000) || reply != "HP1 READY") {
        LogEvent("policy-start-failed"); Retire();
        const auto until = GetTickCount64() + backoff;
        while (!stop_ && !g_stopping && GetTickCount64() < until) Sleep(10);
        backoff = (std::min)(DWORD{30000}, backoff * 2); continue;
      }
      backoff = 1000;
      LogEvent("policy-ready startup_ms=" + std::to_string(GetTickCount64() - start));
      while (!stop_ && !g_stopping) {
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
        const auto prefix = std::to_string(id) + " " + std::to_string(epoch_) + " " +
            std::to_string(v.engine_epoch) + " " + std::to_string(v.publication_generation) + " " +
            std::to_string(static_cast<unsigned>(v.kind));
        std::string context;
        constexpr char hex[] = "0123456789abcdef";
        for (size_t i = 0; i < v.context_size; ++i) {
          const auto ch = static_cast<unsigned char>(v.context[i]);
          context += hex[ch >> 4]; context += hex[ch & 15];
        }
        const auto frame = "HP1 Q " + prefix + " " + std::to_string(v.a) + " " +
            std::to_string(v.b) + " " + std::to_string(v.c) + " " +
            (context.empty() ? "-" : context) + "\n";
        // One outstanding frame, <4096 bytes, into an empty 4096-byte pipe.
        // A timed-out channel is retired before another write; no blocked
        // policy can accumulate writes and stall this worker's shutdown.
        if (frame.size() > kFrame || !WriteAll(input_, frame) || !Line(reply, 200)) {
          ++completed_; changed_.notify_all();
          LogEvent("policy-timeout-discard request=" + std::to_string(id));
          // Keep one outstanding ID while the paused child resumes; discard
          // its late response before writing anything else. Hard limit 5 s.
          if (Line(reply, 5000) && ValidReply(reply, "HP1 R " + prefix + " ")) {
            LogEvent("policy-late-discard request=" + std::to_string(id));
            continue;
          }
          break;
        }
        if (!ValidReply(reply, "HP1 R " + prefix + " ")) {
          LogEvent("policy-invalid-reply request=" + std::to_string(id)); break;
        }
        const auto expected = "HP1 R " + prefix + " " + std::to_string(v.native_decision);
        ++completed_; changed_.notify_all();
        LogEvent(std::string("policy-compare ") + (reply == expected ? "match" : "mismatch") +
            " request=" + std::to_string(id) + " kind=" + std::to_string(static_cast<unsigned>(v.kind)));
        if (!reply.starts_with("HP1 R " + prefix + " ")) break;
      }
      Retire();
      const auto until = GetTickCount64() + 1000;
      while (!stop_ && !g_stopping && GetTickCount64() < until) Sleep(10);
    }
    Retire();
    LogEvent("policy-stop dropped=" + std::to_string(dropped_.load()));
  }
};
// Detached native clients can finish during CRT teardown. Keep the value
// queue/mutex alive for process lifetime; wmain explicitly joins supervision.
inline ShadowPolicy& shadow = *new ShadowPolicy;
inline std::atomic<uint64_t> next_engine_epoch{0}, engine_epoch{0}, publication_generation{0};
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
