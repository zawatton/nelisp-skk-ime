// Tests the production queue with no OS/registry setup or managed runtime.
#include <windows.h>
// Negative control restores exactly the old stderr/stdout transport routing.
static bool broken_stderr = false;
static BOOL WINAPI PolicyUnitCreateProcessW(LPCWSTR application, LPWSTR command,
    LPSECURITY_ATTRIBUTES process_security, LPSECURITY_ATTRIBUTES thread_security,
    BOOL inherit, DWORD flags, LPVOID environment, LPCWSTR directory,
    LPSTARTUPINFOW startup, LPPROCESS_INFORMATION process) {
  const auto error = startup->hStdError;
  if (broken_stderr) startup->hStdError = startup->hStdOutput;
  const auto result = CreateProcessW(application, command, process_security, thread_security,
      inherit, flags, environment, directory, startup, process);
  startup->hStdError = error;
  return result;
}
#define CreateProcessW PolicyUnitCreateProcessW
#define wmain host_program_main
#include "../host/main.cpp"
#undef wmain
#undef CreateProcessW
namespace { namespace native_adapter {
struct ShadowPolicyTest {
  inline static uint64_t now = 0;
  static uint64_t Clock() { return now; }
  inline static std::atomic<uint64_t> transport_now{0};
  static uint64_t TransportClock() { return transport_now.load(); }
  static int FakeChild() {
    // Deliberately interleave a diagnostic with a fragmented READY. stderr is
    // not a protocol channel, and its CRLF must not poison the stdout reader.
    WriteAll(GetStdHandle(STD_OUTPUT_HANDLE), "HP2 RE");
    WriteAll(GetStdHandle(STD_ERROR_HANDLE), "fake diagnostic\r\n");
    Sleep(25);
    WriteAll(GetStdHandle(STD_OUTPUT_HANDLE), "ADY HN3=1\n");
    const auto input = GetStdHandle(STD_INPUT_HANDLE);
    std::string frame;
    for (;;) {
      char ch; DWORD read = 0;
      if (!ReadFile(input, &ch, 1, &read, nullptr) || read != 1) return 0;
      frame += ch;
      if (ch != '\n') continue;
      if (frame.size() != 23 || !frame.starts_with("HP2Q")) return 2;
      const unsigned kind = static_cast<unsigned char>(frame[15]) - 32;
      if (kind == 1) return 0; // Parent requests a crash after a real refresh.
      const uint64_t value = kind == 2 ? 2 : 0;
      if (!WriteAll(GetStdHandle(STD_OUTPUT_HANDLE), "HP2R" + frame.substr(4, 11) +
          ShadowPolicy::Digits(value, 3) + "\n")) return 0;
      frame.clear();
    }
  }
  static int Transport() {
    ShadowPolicy policy;
    policy.enabled_ = true; policy.switches_[0] = true;
    policy.memo_clock_ = TransportClock; transport_now = 0; engine_epoch = 7;
    wchar_t executable[32768]{};
    if (!GetModuleFileNameW(nullptr, executable, 32768)) return 2;
    policy.runtime_ = executable;
    policy.repository_ = std::filesystem::current_path().wstring();
    policy.job_ = CreateJobObjectW(nullptr, nullptr);
    if (!policy.job_) return 2;
    auto wait = [&](auto predicate) {
      const auto deadline = GetTickCount64() + 5000;
      while (GetTickCount64() < deadline) {
        { std::lock_guard lock(policy.mutex_); if (predicate()) return true; }
        Sleep(5);
      }
      return false;
    };
    Observation key{PolicyKind::Sources, 7, 0, 2, 1, 0, 0}; // Outside Seed's inputs.
    // Copied first caller observation; enqueue before starting the real worker
    // so fixture setup cannot be dropped by its nonblocking queue contract.
    key.caller_used = true;
    policy.Observe(key);
    key.caller_used = false;
    // Use production Launch/Run/Retire with an actual pipe-backed fake child.
    policy.worker_ = std::thread([&] { policy.Run(); });
    int native_calls = 0, contention_calls = 0;
    auto fallback = [&] {
      ++native_calls;
      // This real concurrent worker can win the caller's try-lock. Verify
      // authority is fresh before treating a retry as fixture contention.
      std::lock_guard lock(policy.mutex_);
      const auto found = policy.decisions_.find(ShadowPolicy::Key(key));
      if (policy.healthy_ && found != policy.decisions_.end() &&
          TransportClock() - found->second.at <= 30000) ++contention_calls;
      return uint64_t{0};
    };
    auto memo_hit = [&] {
      const auto deadline = GetTickCount64() + 5000;
      while (GetTickCount64() < deadline) {
        if (policy.Decide(key, fallback) == 2) return native_calls == contention_calls;
        if (native_calls != contention_calls) return false;
        Sleep(5);
      }
      return false;
    };
    auto exercise = [&] {
      if (!wait([&] { return policy.healthy_ && policy.decisions_.contains(ShadowPolicy::Key(key)) &&
          policy.decisions_.at(ShadowPolicy::Key(key)).active; })) return false;
      uint64_t refreshed = 0;
      { std::lock_guard lock(policy.mutex_); refreshed = policy.keepalive_refreshed_; }
      transport_now.fetch_add(25000);
      if (!wait([&] { return policy.keepalive_refreshed_ > refreshed &&
          policy.decisions_.contains(ShadowPolicy::Key(key)) &&
          policy.decisions_.at(ShadowPolicy::Key(key)).at == TransportClock(); })) return false;
      return memo_hit();
    };
    bool pass = exercise();
    if (pass) {
      // Observe may legitimately drop on contention, including fault setup.
      // Retry only a rejected enqueue, never an accepted crash request.
      for (;;) {
        const auto dropped = policy.dropped_.load();
        policy.Observe({PolicyKind::Config, 7, 0, 1, 0, 0, 0});
        if (policy.dropped_ == dropped) break;
        Sleep(5);
      }
      pass = wait([&] { return !policy.healthy_ && policy.decisions_.empty(); });
      // Queue caller/prefetch work during relaunch. Neither can consume READY.
      policy.PrefetchRestart(7, 1000);
      pass = pass && exercise();
    }
    policy.Stop();
    Close(policy.job_);
    std::printf("policy transport unit: ready_relaunch=%d native_calls=%d contention_fallbacks=%d\n",
        pass, native_calls, contention_calls);
    return pass ? 0 : 1;
  }
  static int Run(bool broken_keepalive, bool broken_reseed = false, bool broken_candidate = false) {
    ShadowPolicy policy;
    policy.enabled_ = true;
    int checks = 0, failures = 0;
    auto check = [&](bool pass) { ++checks; if (!pass) ++failures; };
    Observation v{PolicyKind::Config, 7, 9, 1, 1, 0, 1};
    v.context[0] = 'a'; v.context_size = 1;
    policy.Observe(v); v.context[0] = 'b';
    check(policy.queue_.front().context[0] == 'a');
    check(policy.queue_.front().engine_epoch == 7 && policy.queue_.front().publication_generation == 9);
    for (size_t i = 1; i < ShadowPolicy::kRequests; ++i) policy.Observe(v);
    check(policy.queue_.size() == ShadowPolicy::kRequests);
    policy.Observe(v);
    check(policy.queue_.size() == ShadowPolicy::kRequests && policy.dropped_ == 1);
    check(policy.queue_.size() * sizeof(Observation) <= ShadowPolicy::kBytes);
    v.context_size = 1025; policy.Observe(v);
    check(policy.dropped_ == 2);
    policy.queue_.clear(); v.context_size = 1;
    std::unique_lock lock(policy.mutex_);
    const auto start = GetTickCount64();
    std::thread caller([&] { policy.Observe(v); }); caller.join();
    check(GetTickCount64() - start < 50 && policy.queue_.empty() && policy.dropped_ == 3);
    lock.unlock(); policy.enabled_ = false; policy.Observe(v);
    check(policy.queue_.empty());
    const std::string prefix = "HP2R" + ShadowPolicy::Digits(1, 11);
    check(ShadowPolicy::ValidReply(prefix + "  !", prefix));
    check(!ShadowPolicy::ValidReply("HP2R" + ShadowPolicy::Digits(2, 11) + "  !", prefix));
    check(!ShadowPolicy::ValidReply("HP1R" + prefix.substr(4) + "  !", prefix));
    check(!ShadowPolicy::ValidReply(prefix + "  `", prefix));
    check(!ShadowPolicy::ValidReply(prefix + "  \x1f", prefix));
    check(!ShadowPolicy::ValidReply(prefix + "    ", prefix));
    check(!ShadowPolicy::ValidReply(prefix, prefix));
    check(!ShadowPolicy::ValidReply(prefix + "garbage", prefix));
    check(ShadowPolicy::Frame(1, v).size() == 23);
    check(ShadowPolicy::Digits(~uint64_t{0}, 11) == "/__________");
    v.a = 262144; check(ShadowPolicy::Frame(1, v).empty());
    v.a = 1; v.kind = static_cast<PolicyKind>(13); check(ShadowPolicy::Frame(1, v).empty());
    v.kind = PolicyKind::Cache; v.b = 262143;
    check(ShadowPolicy::Frame(1, v).substr(19, 3) == "___");
    // A differing, valid managed answer must actually replace the native
    // branch; equality-only plumbing would fail this authority control.
    policy.enabled_ = true; policy.switches_[0] = true; policy.healthy_ = true;
    v = {PolicyKind::Sources, 7, 9, 1, 1, 0, 1};
    policy.Remember(v, 2);
    auto diagnostic = v; diagnostic.kind = PolicyKind::Config;
    for (uint64_t i = 0; i < 100; ++i) { diagnostic.b = i; policy.Remember(diagnostic, 0); }
    check(policy.decisions_.size() == 1); // Shadow traffic cannot evict authority.
    check(policy.Decide(v) == 2);
    check(policy.divergent_[static_cast<unsigned>(PolicyKind::Sources)] == 1);
    policy.switches_[0] = false; check(policy.Decide(v) == 1);
    check(policy.divergent_[static_cast<unsigned>(PolicyKind::Sources)] == 1);
    policy.switches_[0] = true;
    auto changed = v; changed.engine_epoch++; check(policy.Decide(changed) == 1);
    changed = v; changed.publication_generation++; check(policy.Decide(changed) == 2);
    changed = v; changed.context[0] = 'x'; changed.context_size = 1; check(policy.Decide(changed) == 2);
    policy.decisions_[ShadowPolicy::Key(v)].at = GetTickCount64() - 30001;
    check(policy.Decide(v) == 1);
    policy.decisions_[ShadowPolicy::Key(v)].at = GetTickCount64();
    auto other = v; other.kind = PolicyKind::CacheTtl; other.a = 1; other.b = other.c = 0;
    policy.decisions_[ShadowPolicy::Key(other)] = {60000, GetTickCount64()};
    policy.Timeout(other);
    check(policy.decisions_.contains(ShadowPolicy::Key(v)) && !policy.decisions_.contains(ShadowPolicy::Key(other)));
    policy.Invalidate(); check(policy.Decide(v) == 1 && policy.decisions_.empty());
    policy.healthy_ = true;
    policy.decisions_[ShadowPolicy::Key(v)] = {2, GetTickCount64()};
    std::unique_lock busy(policy.mutex_);
    uint64_t result = 99;
    const auto begin = GetTickCount64();
    std::thread nonblocking([&] { result = policy.Decide(v); }); nonblocking.join();
    check(result == 1 && GetTickCount64() - begin < 50);
    busy.unlock();
    check(!ShadowPolicy::ValidDecision(PolicyKind::Restart, 999));
    check(!ShadowPolicy::ValidDecision(PolicyKind::Cache, 2));
    check(!ShadowPolicy::ValidDecision(PolicyKind::Sources, 3));
    // Fake clock and child: use production selection, fencing and memo commit.
    // A differing child answer proves the 45 s call skips native evaluation.
    ShadowPolicy live;
    live.enabled_ = true; live.switches_.fill(true); live.healthy_ = true;
    live.memo_clock_ = Clock; engine_epoch = 7; now = 0;
    Observation key{PolicyKind::Sources, 7, 0, 1, 1, 0, 0};
    int native_calls = 0, child_calls = 0;
    auto fallback = [&] { ++native_calls; NativeEvaluation(key.kind); return uint64_t{0}; };
    auto child = [&](const Observation& input) {
      ++child_calls;
      // The fake IPC callback can acquire the memo mutex: selection released it.
      { std::unique_lock free(live.mutex_, std::try_to_lock); check(free.owns_lock()); }
      check(ShadowPolicy::ValidDecision(input.kind, 2));
      return live.Remember(input, 2, true);
    };
    key.caller_used = true; live.Remember(key, 2); key.caller_used = false;
    check(live.Decide(key, fallback) == 2 && native_calls == 0);
    live.queue_.clear();
    const auto managed_before = PolicyCounters::nelisp[0].load();
    const auto native_before = PolicyCounters::native[0].load();
    const auto used_before = live.used_[2].load(), completed_before = live.completed_.load();
    now = 19999; check(live.Keepalive().empty());
    for (now = 25000; now <= 45000; now += 5000) {
      for (const auto& input : broken_keepalive ? std::deque<Observation>{} : live.Keepalive()) {
        check(live.KeepaliveCurrent(input)); check(child(input));
      }
    }
    now = 45000;
    check(child_calls == 2 && live.keepalive_refreshed_ == 2);
    check(PolicyCounters::nelisp[0] == managed_before && PolicyCounters::native[0] == native_before);
    check(live.used_[2] == used_before && live.completed_ == completed_before);
    live.LogDecisions(); // Sample real private-harness refresh diagnostics.
    check(live.Decide(key, fallback) == 2 && native_calls == 0);
    // Negative control: the same timeline with worker keep-alive disabled.
    ShadowPolicy disabled;
    disabled.enabled_ = true; disabled.switches_.fill(true); disabled.healthy_ = true;
    disabled.memo_clock_ = Clock; now = 0;
    disabled.Remember(key, 2); check(disabled.Decide(key, fallback) == 2);
    now = 45000; check(disabled.Decide(key, fallback) == 0 && native_calls == 1);
    // Refresh does not extend caller recency, even after repeated child replies.
    live.queue_.clear(); now = 65000;
    auto pending = live.Keepalive(); check(pending.size() == 1);
    live.healthy_ = false; check(!live.KeepaliveCurrent(pending.front()));
    now = 70000; check(live.Keepalive().empty());
    check(child_calls == 2); live.healthy_ = true;
    now = 75000; pending = live.Keepalive(); check(pending.size() == 1);
    engine_epoch = 8;
    check(!live.KeepaliveCurrent(pending.front()));
    check(!live.Remember(pending.front(), 2, true)); // epoch changed during IPC
    now = 80000; check(live.Keepalive().empty() && live.decisions_.empty());
    engine_epoch = 7; now = 0; key.caller_used = true;
    live.Remember(key, 2); key.caller_used = false;
    now = 600000; pending = live.Keepalive(); check(pending.size() == 1);
    check(child(pending.front()));
    check(live.decisions_.at(ShadowPolicy::Key(key)).last_used == 0);
    now = 625000; check(live.Keepalive().empty());
    // Seeds never used by a caller are not refreshed.
    live.decisions_.clear(); now = 0; live.Remember(key, 2);
    now = 650000; check(live.Keepalive().empty());
    // Bound a full memo to 64 keys per 5 s; no second batch in that interval.
    live.decisions_.clear(); live.keepalive_last_ = 0; now = 0;
    key.caller_used = true;
    for (size_t n = 0; n < ShadowPolicy::kRequests; ++n) {
      key.a = n; live.Remember(key, 2);
    }
    now = 25000; pending = live.Keepalive();
    check(pending.size() == ShadowPolicy::kKeepaliveLimit);
    check(live.Keepalive().empty());
    now = 29999; check(live.Keepalive().empty());
    for (const auto& input : pending) check(child(input));
    now = 30000; check(live.Keepalive().empty()); // all answers freshly committed
    now = 50000; pending = live.Keepalive(); check(pending.size() == 64);
    live.Timeout(pending.front());
    check(!live.KeepaliveCurrent(pending.front()));
    check(!live.Remember(pending.front(), 2, true)); // late reply cannot recreate a dropped key
    // Retirement discards authority, but READY re-asks recent caller inputs.
    // No callers execute between the old epoch and the use 40 s after READY.
    ShadowPolicy restarted;
    restarted.enabled_ = true; restarted.switches_.fill(true); restarted.healthy_ = true;
    restarted.memo_clock_ = Clock; engine_epoch = 7; now = 0;
    key = {PolicyKind::Intent, 7, 0, 1, 1, 2, 0}; // Not a Sources seed.
    key.caller_used = true; restarted.Remember(key, 1); key.caller_used = false;
    auto restart_fallback = [&] { ++native_calls; NativeEvaluation(key.kind); return uint64_t{0}; };
    const auto restart_native = native_calls;
    check(restarted.Decide(key, restart_fallback) == 1);
    restarted.queue_.clear(); restarted.Invalidate();
    check(restarted.decisions_.empty() && restarted.recent_.size() == 1);
    now = 1000; restarted.healthy_ = true;
    const auto restart_managed = PolicyCounters::nelisp[3].load();
    const auto restart_cpp = PolicyCounters::native[3].load();
    const auto restart_used = restarted.used_[9].load(), restart_completed = restarted.completed_.load();
    auto reask = broken_reseed ? std::deque<Observation>{} : restarted.Keepalive(true);
    check(reask.size() == 1);
    for (const auto& input : reask) {
      check(restarted.KeepaliveCurrent(input, true));
      check(restarted.Remember(input, 1, true, true));
    }
    for (now = 6000; now <= 41000; now += 5000)
      for (const auto& input : restarted.Keepalive())
        check(restarted.Remember(input, 1, true));
    check(PolicyCounters::nelisp[3] == restart_managed && PolicyCounters::native[3] == restart_cpp);
    check(restarted.used_[9] == restart_used && restarted.completed_ == restart_completed);
    now = 41000; check(restarted.Decide(key, restart_fallback) == 1 && native_calls == restart_native);
    check(restarted.recent_.at(ShadowPolicy::Key(key)).last_used == 0);
    // Explicit no-keepalive control uses the same restart/40 s timeline.
    ShadowPolicy no_refresh;
    no_refresh.enabled_ = true; no_refresh.switches_.fill(true); no_refresh.healthy_ = true;
    no_refresh.memo_clock_ = Clock; now = 0; key.caller_used = true;
    no_refresh.Remember(key, 1); key.caller_used = false;
    no_refresh.Invalidate(); now = 1000; no_refresh.healthy_ = true;
    now = 41000; check(no_refresh.Decide(key, restart_fallback) == 0);
    std::printf("policy restart unit: reseed=%zu native_calls=%d\n", reask.size(), native_calls - restart_native);
    restarted.queue_.clear(); now = 700000; restarted.Invalidate(); restarted.healthy_ = true;
    check(restarted.Keepalive(true).empty()); // Recency expires across retirement.
    // Reproduce the S4.3 candidate warmup crossing a periodic sweep.
    // The reset caller runs only once after publication, unlike prefetch.
    ShadowPolicy candidate;
    candidate.enabled_ = true; candidate.switches_.fill(true); candidate.healthy_ = true;
    candidate.memo_clock_ = Clock; engine_epoch = 7; now = 0;
    candidate.PrefetchRestart(8, 1000);
    for (const auto& input : candidate.queue_) candidate.Remember(input, input.native_decision);
    candidate.queue_.clear(); now = 5000;
    candidate.Keepalive();
    if (broken_candidate) candidate.decisions_.clear(); // Old future-epoch pruning.
    now = 6500; engine_epoch = 8;
    Observation reset{PolicyKind::Restart, 8, 0, 1000, 1, 99, 0};
    int reset_native = 0;
    const auto reset_count = PolicyCounters::nelisp[2].load();
    check(candidate.Decide(reset, [&] { ++reset_native; return uint64_t{2000}; }) == 1000);
    check(reset_native == 0 && candidate.used_[3] == 1);
    check(PolicyCounters::nelisp[2] == reset_count + (PolicyCounters::Enabled() ? 1 : 0));
    check(candidate.Keepalive().empty()); // Under 5 s since last sweep.
    engine_epoch = 9; now = 10000; candidate.Keepalive();
    check(candidate.decisions_.empty()); // Old epochs still retire normally.
    std::printf("policy candidate unit: warmup_ms=6500 reset_native=%d\n", reset_native);
    ShadowPolicy bounded;
    bounded.enabled_ = true; bounded.switches_.fill(true); bounded.healthy_ = true;
    bounded.memo_clock_ = Clock; engine_epoch = 7; now = 0;
    key = {PolicyKind::Sources, 7, 0, 1, 1, 0, 0};
    bounded.Remember(key, 2); bounded.Invalidate(); bounded.healthy_ = true;
    check(bounded.Keepalive(true).empty()); // Unused seeds have no restart history.
    key.caller_used = true;
    for (size_t n = 0; n < ShadowPolicy::kKeepaliveLimit + 8; ++n) {
      key.a = n; bounded.Remember(key, 2);
    }
    check(bounded.recent_.size() == ShadowPolicy::kKeepaliveLimit);
    bounded.Invalidate(); bounded.healthy_ = true; now = 1000;
    auto bounded_reask = bounded.Keepalive(true);
    check(bounded_reask.size() == ShadowPolicy::kKeepaliveLimit);
    bounded.healthy_ = false;
    check(!bounded.KeepaliveCurrent(bounded_reask.front(), true));
    check(!bounded.Remember(bounded_reask.front(), 2, true, true));
    bounded.healthy_ = true; engine_epoch = 8;
    check(!bounded.KeepaliveCurrent(bounded_reask.front(), true));
    check(!bounded.Remember(bounded_reask.front(), 2, true, true));
    check(bounded.Keepalive(true).empty() && bounded.recent_.empty());
    std::printf("policy adapter unit: %d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
  }
};
} }
int main(int argc, char** argv) {
  if (argc > 1 && std::string(argv[1]) == "--load")
    return native_adapter::ShadowPolicyTest::FakeChild();
  if (argc > 2) g_log_path = std::filesystem::path(argv[2]).wstring();
  if (argc > 1 && (std::string(argv[1]) == "transport" || std::string(argv[1]) == "broken-stderr")) {
    broken_stderr = std::string(argv[1]) == "broken-stderr";
    return native_adapter::ShadowPolicyTest::Transport();
  }
  const auto mode = argc > 1 ? std::string(argv[1]) : "normal";
  return native_adapter::ShadowPolicyTest::Run(mode == "broken-keepalive",
      mode == "broken-reseed", mode == "broken-candidate");
}
