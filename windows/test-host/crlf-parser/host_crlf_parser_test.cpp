// Test raw host data before the engine's independent filtering can hide it.
#define wmain host_program_main
#include "../../host/main.cpp"
#undef wmain

int main() {
  int checks = 0, failures = 0;
  const auto check = [&](bool value, const char* label) {
    ++checks;
    if (!value) { ++failures; std::fprintf(stderr, "FAIL %s\n", label); }
  };
  std::unordered_map<std::string, std::string> map;
  ParseSkkJisyo("plain /Alpha/Beta/\r\ncorrupt /\r/Gamma/\r\r\n"
               "last /Delta/\r", &map);
  check(map.size() == 3, "CRLF entry count");
  check(map["plain"] == "/Alpha/Beta/", "ordinary CRLF dictionary");
  check(map["corrupt"] == "//Gamma/", "embedded and repeated CR removed");
  check(map["last"] == "/Delta/", "no final LF");
  std::string relay = "1/Alpha/\r/Beta/\r\n";
  StripDictionaryLineBreaks(&relay);
  check(relay == "1/Alpha//Beta/", "relay strips CR and LF");
  check(EngineDictionaryReply(relay) == "LIST (\"Alpha\" \"Beta\" )",
        "relay contains no quoted line breaks");
  check(QuoteEngineString("\r") == "\"\\015\"", "wire still quotes raw CR");
  std::printf("host CRLF parser: %d checks, %d failures\n", checks, failures);
  return failures ? 1 : 0;
}
