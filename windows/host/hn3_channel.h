// HN3 v1 copied byte envelopes. No OS handles or executable IPC data.
#pragma once
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace hn3 {
constexpr size_t kHeader = 52, kPayload = 262144, kRequests = 64, kQueueBytes = 131072;
constexpr uint64_t kMergeDeadlineMs = 1000;
enum class Operation : uint16_t { Builtins = 1, Server = 2, Dictionary = 3, Quote = 4, Startup = 5 };
struct Frame {
  bool reply = false;
  Operation operation = Operation::Builtins;
  uint16_t status = 0;
  uint64_t correlation = 0, policy_epoch = 0, engine_epoch = 0, generation = 0;
  std::vector<std::string> fields;
};
inline bool Utf8(std::string_view s) {
  size_t i = 0;
  while (i < s.size()) {
    uint32_t c = static_cast<unsigned char>(s[i++]);
    if (c < 128) continue;
    unsigned n; uint32_t minimum;
    if (c >= 0xc2 && c <= 0xdf) { n = 1; minimum = 0x80; c &= 31; }
    else if (c >= 0xe0 && c <= 0xef) { n = 2; minimum = 0x800; c &= 15; }
    else if (c >= 0xf0 && c <= 0xf4) { n = 3; minimum = 0x10000; c &= 7; }
    else return false;
    if (s.size() - i < n) return false;
    while (n--) {
      const auto b = static_cast<unsigned char>(s[i++]);
      if ((b & 0xc0) != 0x80) return false;
      c = (c << 6) | (b & 63);
    }
    if (c < minimum || c > 0x10ffff || (c >= 0xd800 && c <= 0xdfff)) return false;
  }
  return true;
}
inline void Put(std::string& s, uint64_t n, size_t width) {
  while (width--) { s.push_back(static_cast<char>(n & 255)); n >>= 8; }
}
inline uint64_t Get(std::string_view s, size_t at, size_t width) {
  uint64_t n = 0;
  for (size_t i = 0; i < width; ++i) n |= uint64_t(static_cast<unsigned char>(s[at+i])) << (8*i);
  return n;
}
inline bool Shape(const Frame& f) {
  const auto op = static_cast<unsigned>(f.operation);
  if (op < 1 || op > 5 || f.status > 2 || (!f.reply && f.status) || f.fields.size() > 4096) return false;
  if (f.reply) return f.status ? f.fields.empty() : (op == 5 ? f.fields.size() >= 5 : f.fields.size() == 1);
  return op == 1 || (op == 2 ? f.fields.size() == 2 : op == 5 ? f.fields.size() >= 8 : f.fields.size() == 1);
}
inline std::string Encode(const Frame& f) {
  if (!Shape(f)) return {};
  size_t bytes = 0;
  for (const auto& v : f.fields) {
    if (!Utf8(v) || v.size() > kPayload || bytes > kPayload - v.size()) return {};
    bytes += v.size();
  }
  if (f.fields.size()*4 > kPayload - bytes) return {};
  std::string s = f.reply ? "HN3R" : "HN3Q";
  Put(s, kHeader - 8 + bytes + f.fields.size()*4, 4);
  Put(s, static_cast<unsigned>(f.operation), 2); Put(s, f.status, 2);
  Put(s, f.correlation, 8); Put(s, f.policy_epoch, 8); Put(s, f.engine_epoch, 8); Put(s, f.generation, 8);
  Put(s, f.fields.size(), 4); Put(s, bytes, 4);
  for (const auto& v : f.fields) { Put(s, v.size(), 4); s += v; }
  return s;
}
inline bool Decode(std::string_view s, Frame& f) {
  if (s.size() < kHeader || (s.substr(0,4) != "HN3Q" && s.substr(0,4) != "HN3R") ||
      Get(s,4,4) != s.size()-8 || s.size()-kHeader > kPayload) return false;
  Frame v; v.reply = s[3] == 'R'; v.operation = static_cast<Operation>(Get(s,8,2));
  v.status = static_cast<uint16_t>(Get(s,10,2)); v.correlation = Get(s,12,8);
  v.policy_epoch = Get(s,20,8); v.engine_epoch = Get(s,28,8); v.generation = Get(s,36,8);
  const auto count = Get(s,44,4), payload = Get(s,48,4);
  if (count > 4096 || payload > kPayload) return false;
  size_t at = kHeader, bytes = 0;
  for (uint64_t i = 0; i < count; ++i) {
    if (s.size()-at < 4) return false;
    const auto length = Get(s,at,4); at += 4;
    if (length > s.size()-at) return false;
    auto field = s.substr(at,static_cast<size_t>(length));
    if (!Utf8(field)) return false;
    v.fields.emplace_back(field); bytes += length; at += length;
  }
  if (at != s.size() || bytes != payload || !Shape(v)) return false;
  f = std::move(v); return true;
}
// A timeout permanently disarms this correlation. The supervisor drains or
// retires the pipe before arming another one; old epochs can never be reused.
struct Outstanding {
  Frame request; bool armed = false;
  void Begin(const Frame& f) { request = f; armed = true; }
  void Retire() { armed = false; }
  bool Accept(const Frame& f) const {
    return armed && f.reply && f.operation == request.operation &&
        f.correlation == request.correlation && f.policy_epoch == request.policy_epoch &&
        f.engine_epoch == request.engine_epoch && f.generation == request.generation;
  }
};
} // namespace hn3
