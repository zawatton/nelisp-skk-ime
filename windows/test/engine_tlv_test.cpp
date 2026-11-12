// Copyright (C) 2026 nelisp-skk-ime contributors
// GPL-3.0-or-later; see src/engine_tlv.h.
//
// Unit test of src/engine_tlv.h (stage S4.1), portable (Linux/MSVC).
//   engine_tlv_test GOLDEN_DIR            verify
//   engine_tlv_test GOLDEN_DIR --update   rewrite golden/tlv/*.bin|.hex|.dump
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <sstream>

#include "../src/engine_tlv.h"

using namespace ddskk;
using namespace ddskk::tlv;

static int g_failures = 0;
#define CHECK(c) do { if (!(c)) { ++g_failures; \
  std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

static std::wstring W(std::initializer_list<uint32_t> cps) {
  std::wstring s;
  for (uint32_t c : cps) s.push_back(static_cast<wchar_t>(c));
  return s;  // code points; Windows callers would pass surrogates themselves
}
static std::string Hex(const std::string& b) {
  std::string out;
  char buf[4];
  for (size_t i = 0; i < b.size(); ++i) {
    std::snprintf(buf, sizeof buf, "%02x", static_cast<unsigned char>(b[i]));
    out += buf;
    out += (i % 16 == 15 || i + 1 == b.size()) ? "\n" : " ";
  }
  return out;
}
static std::string Slurp(const std::string& path, bool* ok) {
  std::ifstream f(path, std::ios::binary);
  *ok = static_cast<bool>(f);
  std::ostringstream ss;
  ss << f.rdbuf();
  return ss.str();
}

struct Case { const char* name; Message msg; };

static std::vector<Case> Cases() {
  std::vector<Case> v;
  { Message m; m.state.mode = L"hiragana"; m.state.cursor = 0;
    m.state.composition_start = -1; m.state.candidate_index = -1;
    v.push_back({"state_idle", m}); }
  { Message m; m.state.mode = L"preedit"; m.state.cursor = 1;
    m.state.composition_start = 0; m.state.text = W({0x3042});
    m.state.pending_romaji = W({'k'}); m.state.candidate_index = -1;
    v.push_back({"state_preedit", m}); }
  { Message m; m.state.mode = L"candidate"; m.state.cursor = 2;
    m.state.composition_start = 0; m.state.text = W({0x6f22, 0x5b57});
    m.state.candidate_index = 1;
    m.state.candidates = {W({0x6f22, 0x5b57}), W({0x20bb7, 0x91ce}), W({0x5e7e, 0x5b57})};
    m.sequence = 4000000000u;
    v.push_back({"state_candidate", m}); }
  { Message m; m.state.mode = L"registration"; m.state.cursor = 0;
    m.state.composition_start = 0; m.state.candidate_index = -1;
    m.state.text = W({0x3042}); m.state.registration_reading = W({0x304b, 0x3093, 0x3058});
    m.has_registration_reading = true;
    v.push_back({"state_registration", m}); }
  { Message m; m.kind = kKindRaw; m.raw_line = "OK GC";
    v.push_back({"raw_ok", m}); }
  return v;
}

// Hand-built message with an unknown tag (0x7f01) between known ones.
static std::string UnknownTagMessage() {
  using namespace detail;
  std::string body;
  PutRecord(&body, kTagMode, WideToUtf16Le(L"hiragana"));
  PutRecord(&body, 0x7f01, std::string("\x01\x02\x03", 3));
  PutRecord(&body, kTagCursor, I32(0));
  PutRecord(&body, kTagCompStart, I32(-1));
  PutRecord(&body, 0x0013, WideToUtf16Le(L"reserved"));
  PutRecord(&body, kTagCandIndex, I32(-1));
  std::string msg = "DSTV";
  PutU32(&msg, static_cast<uint32_t>(kHeaderSize + body.size()));
  msg.push_back(1); msg.push_back(1); PutU16(&msg, 0);
  return msg + body;
}

int main(int argc, char** argv) {
  if (argc < 2) { std::fprintf(stderr, "usage: %s GOLDEN_DIR [--update]\n", argv[0]); return 2; }
  const std::string dir = argv[1];
  const bool update = argc > 2 && std::string(argv[2]) == "--update";

  // 1. Round trip + golden bytes.
  for (const Case& c : Cases()) {
    std::string bytes;
    CHECK(Encode(c.msg, &bytes));
    auto back = Decode(bytes);
    CHECK(back.has_value());
    if (back) CHECK(Dump(*back) == Dump(c.msg));
    if (back && c.msg.kind == kKindState) {
      CHECK(back->state.mode == c.msg.state.mode);
      CHECK(back->state.text == c.msg.state.text);
      CHECK(back->state.candidates == c.msg.state.candidates);
      CHECK(back->state.registration_reading == c.msg.state.registration_reading);
    }
    const std::string base = dir + "/" + c.name;
    if (update) {
      std::ofstream(base + ".bin", std::ios::binary) << bytes;
      std::ofstream(base + ".hex") << Hex(bytes);
      std::ofstream(base + ".dump") << Dump(c.msg) << "\n";
    }
    bool ok = false;
    const std::string golden = Slurp(base + ".bin", &ok);
    CHECK(ok);
    CHECK(golden == bytes);  // encoder output is byte-stable
    auto from_golden = Decode(golden);
    CHECK(from_golden.has_value());
    const std::string dump = Slurp(base + ".dump", &ok);
    CHECK(ok);
    if (from_golden) CHECK(Dump(*from_golden) + "\n" == dump);
    const std::string hex = Slurp(base + ".hex", &ok);
    CHECK(ok && hex == Hex(golden));
  }
  // The unknown-tag message is also a golden file.
  {
    const std::string bytes = UnknownTagMessage();
    const std::string base = dir + "/state_unknown_tags";
    auto m = Decode(bytes);
    CHECK(m.has_value());
    if (m) CHECK(Dump(*m) == "kind=1 mode=006800690072006100670061006e0061 cursor=0 comp=-1 text=- pending=- idx=-1 ncand=0 cands=- reg=none seq=none");
    if (update) {
      std::ofstream(base + ".bin", std::ios::binary) << bytes;
      std::ofstream(base + ".hex") << Hex(bytes);
      std::ofstream(base + ".dump") << Dump(*m) << "\n";
    }
    bool ok = false;
    CHECK(Slurp(base + ".bin", &ok) == bytes && ok);
    CHECK(Slurp(base + ".dump", &ok) == Dump(*m) + "\n" && ok);
  }

  // 2. Text STATE line -> TLV (the host path), and non-STATE wrapping.
  {
    auto m = Decode(FromReplyLine("STATE candidate 2 0 006f22005b57 - 1 006f22005b57,020bb7"));
    CHECK(m.has_value() && m->kind == kKindState && m->state.candidates.size() == 2);
    if (m) CHECK(Dump(*m).find("d842dfb7") != std::string::npos);
    auto r = Decode(FromReplyLine("ENGINES ddskk passthrough"));
    CHECK(r.has_value() && r->kind == kKindRaw && r->raw_line == "ENGINES ddskk passthrough");
    auto bad = Decode(FromReplyLine("STATE garbage"));
    CHECK(bad.has_value() && bad->kind == kKindRaw && bad->raw_line == "STATE garbage");
  }

  // 3. Malformed input rejection.
  {
    std::string good;
    Encode(Cases()[2].msg, &good);
    CHECK(Decode(good).has_value());
    for (size_t n = 0; n < good.size(); ++n) CHECK(!Decode(good.substr(0, n)));  // every truncation
    std::string bad = good; bad[4] = static_cast<char>(bad[4] + 1);             // total too big
    CHECK(!Decode(bad));
    bad = good; bad[4] = static_cast<char>(bad[4] - 1);                         // total too small
    CHECK(!Decode(bad));
    bad = good; bad[0] = 'X'; CHECK(!Decode(bad));                              // magic
    bad = good; bad[8] = 2; CHECK(!Decode(bad));                                // future version
    bad = good; bad[8] = 0; CHECK(!Decode(bad));
    bad = good; bad[9] = 9; CHECK(!Decode(bad));                                // unknown kind
    bad = good; bad[kHeaderSize + 2] = static_cast<char>(0xff);                 // record len huge
    CHECK(!Decode(bad));
    bad = good; bad[kHeaderSize + 2] = 3;                                       // odd string len
    CHECK(!Decode(bad));
    bad = good + std::string("\0", 1); CHECK(!Decode(bad));                     // trailing byte
    // wrong fixed width for CURSOR (len 2 instead of 4, total patched).
    { using namespace detail; std::string body;
      PutRecord(&body, kTagMode, WideToUtf16Le(L"x")); PutRecord(&body, kTagCursor, "ab");
      std::string msg = "DSTV"; PutU32(&msg, kHeaderSize + body.size());
      msg.push_back(1); msg.push_back(1); PutU16(&msg, 0); CHECK(!Decode(msg + body)); }
    // missing required tags.
    { using namespace detail; std::string body;
      PutRecord(&body, kTagMode, WideToUtf16Le(L"x"));
      std::string msg = "DSTV"; PutU32(&msg, kHeaderSize + body.size());
      msg.push_back(1); msg.push_back(1); PutU16(&msg, 0); CHECK(!Decode(msg + body)); }
    // oversized: candidate list / total / single string beyond limits.
    { Message m = Cases()[1].msg; m.state.text = std::wstring(kMaxStringBytes / 2 + 1, L'a');
      std::string o; CHECK(!Encode(m, &o)); }
    { Message m = Cases()[1].msg;
      m.state.candidates.assign(kMaxCandidates + 1, L"a"); std::string o; CHECK(!Encode(m, &o)); }
    { Message m = Cases()[1].msg;
      m.state.candidates.assign(kMaxCandidates, std::wstring(kMaxStringBytes / 2, L'a'));
      std::string o; CHECK(!Encode(m, &o)); }  // exceeds kMaxTotal
    { std::string big(kMaxTotal + 1, '\0'); CHECK(!Decode(big)); }
    CHECK(!Decode(std::string()));
  }
  if (g_failures) { std::fprintf(stderr, "%d failure(s)\n", g_failures); return 1; }
  std::puts("engine_tlv_test: all checks passed");
  return 0;
}
