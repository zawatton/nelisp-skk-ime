// Tests the production queue with no OS/registry setup or managed runtime.
#define wmain host_program_main
#include "../host/main.cpp"
#undef wmain
namespace { namespace native_adapter {
struct ShadowPolicyTest {
  static int Run() {
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
    const std::string prefix = "HP1 R 1 2 3 4 5 ";
    check(ShadowPolicy::ValidReply(prefix + "1", prefix));
    check(!ShadowPolicy::ValidReply("HP1 R 2 2 3 4 5 1", prefix));
    check(!ShadowPolicy::ValidReply("HP1 R 1 3 3 4 5 1", prefix));
    check(!ShadowPolicy::ValidReply("HP1 R 1 2 4 4 5 1", prefix));
    check(!ShadowPolicy::ValidReply("HP1 R 1 2 3 5 5 1", prefix));
    check(!ShadowPolicy::ValidReply("HP2 R 1 2 3 4 5 1", prefix));
    check(!ShadowPolicy::ValidReply(prefix, prefix));
    check(!ShadowPolicy::ValidReply(prefix + "garbage", prefix));
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
    std::printf("policy adapter unit: %d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
  }
};
} }
int main() { return native_adapter::ShadowPolicyTest::Run(); }
