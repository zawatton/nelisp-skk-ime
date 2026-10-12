// Production adapter state tests; no worker, child, registry or stack starts.
#define wmain host_program_main
#include "../../windows/host/main.cpp"
#undef wmain
namespace { namespace native_adapter {
struct ShadowPolicyTest {
  static int Run() {
    ShadowPolicy policy; policy.enabled_ = true; policy.byte_modes_.fill(1);
    int checks = 0, failures = 0, native = 0;
    auto check = [&](bool ok) { ++checks; if (!ok) { ++failures; std::printf("FAIL HN3 adapter check=%d\n", checks); } };
    auto fallback = [&] { ++native; return std::string("C++"); };
    auto call = [&](const std::string& data) { return policy.Bytes(hn3::Operation::Dictionary,{data},0,fallback); };
    policy.healthy_ = true; policy.hn3_capable_ = false;
    check(call("4") == "C++" && policy.byte_queue_.empty()); // legacy HP2 peer
    policy.hn3_capable_ = true;
    check(call("4") == "C++" && policy.byte_queue_.size() == 1); // nonblocking cold miss
    hn3::Frame f; f.operation = hn3::Operation::Dictionary; f.fields = {"4"};
    f.engine_epoch = engine_epoch; f.generation = publication_generation;
    const auto key = hn3::Encode(f);
    policy.byte_memo_[key] = "Lisp"; policy.byte_memo_bytes_ = key.size()+4;
    const auto before = native;
    check(call("4") == "Lisp" && native == before); // lazy ON memo
    policy.byte_modes_[0] = 2;
    check(call("4") == "C++" && native == before+1); // SHADOW uses C++
    policy.byte_modes_[0] = 1;
    ++engine_epoch; check(call("4") == "C++"); // epoch fencing
    ++publication_generation; check(call("4") == "C++"); // generation fencing
    policy.Invalidate(); check(policy.byte_queue_.empty() && policy.byte_memo_.empty() && !policy.hn3_capable_);
    policy.healthy_ = true; policy.hn3_capable_ = true;
    for (int i = 0; i < 70; ++i) call(std::to_string(i));
    check(policy.byte_queue_.size() == hn3::kRequests && policy.byte_queued_ <= hn3::kQueueBytes);
    policy.Invalidate(); policy.healthy_ = true; policy.hn3_capable_ = true;
    call(std::string(70000,'x')); call(std::string(70000,'y'));
    check(policy.byte_queue_.size() == 1 && policy.byte_queued_ <= hn3::kQueueBytes);
    const auto queued = policy.byte_queue_.size(); call(std::string("\xe3\x81",2));
    check(policy.byte_queue_.size() == queued);
    policy.Invalidate(); policy.healthy_ = true; policy.hn3_capable_ = true;
    policy.Bytes(hn3::Operation::Dictionary,{"4"},GetTickCount64(),fallback);
    check(policy.byte_queue_.size() == 1 && policy.byte_queue_.front()->cancelled);
    auto expired = policy.byte_queue_.front();
    const auto request_before = policy.request_;
    check(policy.ByteExchange(expired) && expired->done && !expired->valid && policy.request_ == request_before);
    policy.Invalidate();
    policy.byte_modes_.fill(0); check(call("4") == "C++" && policy.byte_queue_.empty());
    const std::string opaque("\xff\0\r\n",4);
    check(policy.Bytes(hn3::Operation::Dictionary,{opaque},0,[&] { return opaque; }) == opaque);
    wchar_t runtime[32768]{};
    if (GetEnvironmentVariableW(L"HN_IME_RUNTIME", runtime, 32768)) {
      wchar_t log[32768]{};
      if (GetEnvironmentVariableW(L"DDSKK_HOST_LOG", log, 32768)) g_log_path = log;
      ShadowPolicy live; live.enabled_ = true; live.byte_modes_.fill(1);
      live.runtime_ = runtime;
      wchar_t repository[32768]{}; GetCurrentDirectoryW(32768, repository);
      live.repository_ = repository; live.job_ = CreateJobObjectW(nullptr, nullptr);
      live.worker_ = std::thread([&] { live.Run(); });
      auto ask = [&](hn3::Operation op, std::vector<std::string> fields, DWORD budget) {
        const auto started = GetTickCount64();
        const auto result = live.Bytes(op, fields, started+budget, [] { return std::string("FALLBACK"); });
        std::printf("HN3 live op=%u elapsed_ms=%llu result=%s\n", static_cast<unsigned>(op), GetTickCount64()-started, result == "FALLBACK" ? "fallback" : "answered");
        return result;
      };
      // First cold startup exercises the real supervisor and interpreted child.
      const auto startup = ask(hn3::Operation::Startup,{"0","","1","0","0","0","","0","0","0"},60000);
      hn3::Frame reply;
      check(hn3::Decode(startup,reply) && reply.fields.front() == "ddskk");
      check(ask(hn3::Operation::Builtins,{"/仮名;one/","/仮名;two/次/"},static_cast<DWORD>(hn3::kMergeDeadlineMs)) == "/仮名;one/次/");
      check(ask(hn3::Operation::Server,{"/Alpha/","/Alpha;server/Gamma/"},static_cast<DWORD>(hn3::kMergeDeadlineMs)) == "1/Alpha/Alpha;server/Gamma/");
      check(ask(hn3::Operation::Dictionary,{"1/Alpha/Gamma/"},static_cast<DWORD>(hn3::kMergeDeadlineMs)) == "LIST (\"Alpha\" \"Gamma\" )");
      live.byte_modes_.fill(2);
      bool native_called = false;
      const auto shadow_reply = live.Bytes(hn3::Operation::Dictionary,{"1/Alpha/Gamma/"},
          GetTickCount64()+hn3::kMergeDeadlineMs,[&] {
            native_called = true; return EngineDictionaryReply("1/Alpha/Gamma/");
          });
      check(native_called && shadow_reply == "LIST (\"Alpha\" \"Gamma\" )");
      live.Stop();
      check(live.epoch_ == 1); // No retirement between ON and SHADOW traffic.
      Close(live.job_);
      std::printf("HN3 production supervisor interpreted-child checks=6 stacks=0\n");
    }
    std::printf("HN3 adapter checks=%d failures=%d stacks=0\n", checks, failures);
    return failures ? 1 : 0;
  }
};
} }
int main() { return native_adapter::ShadowPolicyTest::Run(); }
