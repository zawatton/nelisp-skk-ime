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
    std::printf("policy adapter unit: %d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
  }
};
} }
int main() { return native_adapter::ShadowPolicyTest::Run(); }
