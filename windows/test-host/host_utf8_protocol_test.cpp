// Exercise the production host parser, including its bounded byte reader.
#define wmain host_program_main
#include "../host/main.cpp"
#undef wmain

int main() {
  int checks = 0, failures = 0;
  const auto check = [&](bool value, const char* name) {
    ++checks;
    if (!value) { ++failures; std::fprintf(stderr, "FAIL %s\n", name); }
  };
  const auto decode = [](const std::string& header, const std::string& body,
                         std::string* output) {
    size_t offset = 0;
    return DecodeState2(header, [&](unsigned char* ch) {
      if (offset == body.size()) return false;
      *ch = static_cast<unsigned char>(body[offset++]); return true;
    }, output) && offset == body.size();
  };
  std::string output;
  check(QuoteEngineString(std::string(" \"\\\n\r\t\0", 7)) == "\" \\\"\\\\\\012\\015\\011\\000\"", "quoted controls");
  check(EngineDictionaryReply("1/a b/;annotation/\xf0\x9f\x98\x80//tail") ==
      "LIST (\"a b\" \";annotation\" \"\xf0\x9f\x98\x80\" )", "dictionary delimiters Unicode empty trailing");
  check(EngineDictionaryReply("1x/y/") == "LIST (\"x\" \"y\" )", "legacy leading slash semantics");
  check(EngineDictionaryReply("4") == "LIST nil", "dictionary miss");
  check(EngineDictionaryReply("1///") == "LIST ()", "dictionary empty fields");
  check(Utf8KeyRequest("SESSION a CONTROL CONVERT-KEYS 75,97,110,97") ==
      "SESSION a CONTROL CONVERT-UTF8 Kana", "scoped request");
  check(Utf8KeyRequest("CONTROL SYNC-KEYS 32,47,59,128512") ==
      "CONTROL SYNC-UTF8  /;\xf0\x9f\x98\x80", "Unicode request");
  check(Utf8KeyRequest("CONTROL FEED-KEYS 97") == "CONTROL FEED-UTF8 a", "feed request");
  for (const auto& bad : {"10", "13", "55296", "1114112", "1,", "-1", "", "1,,2", "a"}) {
    const std::string request = std::string("CONTROL SYNC-KEYS ") + bad;
    check(Utf8KeyRequest(request) == request, "legacy request fallback");
  }
  check(decode("STATE2 candidate 6 0 0 2 0", "6: /;\n\r\xf0\x9f\x98\x80" "0:1:\xe6\xbc\xa2" "0:\n", &output), "delimiters Unicode empty candidate");
  check(output == "STATE candidate 6 0 00002000002f00003b00000a00000d01f600 - 0 006f22,-", "legacy bytes");
  check(decode("STATE2 registration 0 -1 -1 0 1", "0:0:0:\n", &output), "empty registration");
  check(output == "STATE registration 0 -1 - - -1 - -", "registration legacy bytes");
  for (const auto& bad : std::vector<std::string>{
      "", "0:0:", "0:0:x", "-1:a0:\n", "a:a0:\n", "65537:a0:\n",
      "1:\xc0\x80" "0:\n", "1:\xed\xa0\x80" "0:\n", "1:\xf4\x90\x80\x80" "0:\n",
      "1:\xe6\x41\x80" "0:\n", "1:\x80" "0:\n", "1:\xe0\x80\x80" "0:\n",
      "1:\xf0\x80\x80\x80" "0:\n", "1:\xf0\x9f"}) {
    check(!decode("STATE2 reading 0 -1 -1 0 0", bad, &output), "reject invalid body");
  }
  for (const auto& bad : {"STATE2 reading -1 -1 -1 0 0", "STATE2 reading 0 -2 -1 0 0",
      "STATE2 reading 0 -1 -2 0 0", "STATE2 reading 0 -1 -1 -1 0",
      "STATE2 reading 0 -1 -1 4097 0", "STATE2 reading 0 -1 -1 0 2",
      "STATE2 reading 0 -1 -1 0 0 trailing", "STATE2 reading 0"}) {
    check(!decode(bad, "0:0:\n", &output), "reject invalid header");
  }
  std::printf("host UTF8 protocol: %d checks, %d failures\n", checks, failures);
  return failures ? 1 : 0;
}
