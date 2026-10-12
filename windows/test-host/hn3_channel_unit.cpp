// No processes, registry, host stack or dictionaries are opened.
#include "../../windows/host/hn3_channel.h"
#include <cstdio>
#include <limits>
int main() {
  int checks = 0, failures = 0;
  auto check = [&](bool ok) { ++checks; if (!ok) ++failures; };
  hn3::Frame f; f.operation = hn3::Operation::Server;
  f.correlation = (std::numeric_limits<uint64_t>::max)();
  f.policy_epoch = 0xfedcba9876543210ULL; f.engine_epoch = 42; f.generation = 17;
  f.fields = {std::string("/a\0b/",6), "/仮名;note/"};
  const auto wire = hn3::Encode(f); hn3::Frame got;
  check(!wire.empty() && hn3::Decode(wire,got));
  check(got.fields == f.fields && got.correlation == f.correlation && got.policy_epoch == f.policy_epoch);
  check(hn3::Get(wire,4,4) == wire.size()-8 && hn3::Get(wire,44,4) == 2);
  for (size_t n = 0; n < wire.size(); ++n) check(!hn3::Decode(std::string_view(wire).substr(0,n),got));
  auto corrupt = wire; corrupt[4] ^= 1; check(!hn3::Decode(corrupt,got));
  corrupt = wire; corrupt[44] = 3; check(!hn3::Decode(corrupt,got));
  corrupt = wire; corrupt[48] ^= 1; check(!hn3::Decode(corrupt,got));
  corrupt = wire; corrupt[52] = 127; check(!hn3::Decode(corrupt,got));
  corrupt = wire; corrupt[10] = 1; check(!hn3::Decode(corrupt,got));
  corrupt = wire; corrupt[8] = 6; check(!hn3::Decode(corrupt,got));
  hn3::Frame large; large.fields = {std::string(hn3::kPayload-4,'x')};
  check(!hn3::Encode(large).empty()); large.fields[0] += 'x'; check(hn3::Encode(large).empty());
  for (const auto& invalid : {std::string("\xc0\xaf",2), std::string("\xe3\x81",2), std::string("\xed\xa0\x80",3),
       std::string("\xf4\x90\x80\x80",4), std::string("\x80",1), std::string("\xe3\x41\x82",3)}) {
    check(!hn3::Utf8(invalid)); f.fields = {invalid,""}; check(hn3::Encode(f).empty());
  }
  check(hn3::Utf8("\xf4\x8f\xbf\xbf")); check(hn3::Utf8("\xe3\x81\x82"));
  hn3::Outstanding outstanding; outstanding.Begin(f);
  auto reply = f; reply.reply = true; reply.fields = {"result"};
  check(outstanding.Accept(reply));
  for (int field = 0; field < 5; ++field) {
    auto stale = reply;
    if (field == 0) ++stale.correlation;
    if (field == 1) ++stale.policy_epoch;
    if (field == 2) ++stale.engine_epoch;
    if (field == 3) ++stale.generation;
    if (field == 4) stale.operation = hn3::Operation::Quote;
    check(!outstanding.Accept(stale));
  }
  outstanding.Retire(); check(!outstanding.Accept(reply)); // late reply after timeout
  ++f.policy_epoch; ++f.correlation; outstanding.Begin(f); check(!outstanding.Accept(reply));
  check(hn3::kRequests == 64 && hn3::kQueueBytes == 128*1024);
  std::printf("HN3 codec checks=%d failures=%d stacks=0\n",checks,failures);
  return failures ? 1 : 0;
}
