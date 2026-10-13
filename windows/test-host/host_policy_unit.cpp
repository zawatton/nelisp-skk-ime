// Tests the production queue with no OS/registry setup or managed runtime.
#define wmain host_program_main
#include "../host/main.cpp"
#undef wmain
namespace { namespace native_adapter {
struct ShadowPolicyTest {
  inline static uint64_t now = 0;
  static uint64_t Clock() { return now; }
  static int Run(bool broken_keepalive) {
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
    std::printf("policy adapter unit: %d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
  }
};
} }
int main(int argc, char** argv) {
  if (argc > 2) g_log_path = std::filesystem::path(argv[2]).wstring();
  return native_adapter::ShadowPolicyTest::Run(argc > 1 && std::string(argv[1]) == "broken-keepalive");
}
