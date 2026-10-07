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
  // Fixture uses only a test port and never reads registry or personal data.
  SetEnvironmentVariableW(L"NATIVEIME_REGISTRY_KEY", L"Software\\NativeIME-test-sk1-unit");
  SetEnvironmentVariableW(L"DDSKK_SKKSERV_ENABLE", L"1");
  SetEnvironmentVariableW(L"DDSKK_SKKSERV_HOST", L"127.0.0.1");
  SetEnvironmentVariableW(L"DDSKK_SKKSERV_PORT", L"31101");
  EnsureWinsock();
  SOCKET listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  sockaddr_in address{}; address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK); address.sin_port = htons(31101);
  check(bind(listener, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0, "fixture bind");
  check(listen(listener, 4) == 0, "fixture listen");
  std::atomic<bool> fixture_stop{false};
  std::atomic<unsigned> fixture_requests{0};
  std::thread fixture([&] {
    while (!fixture_stop) {
      fd_set reads; FD_ZERO(&reads); FD_SET(listener, &reads); timeval wait{0, 100000};
      if (select(0, &reads, nullptr, nullptr, &wait) <= 0) continue;
      SOCKET client = accept(listener, nullptr, nullptr);
      if (client == INVALID_SOCKET) continue;
      DWORD timeout = 300; setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<char*>(&timeout), sizeof(timeout));
      char request[1024]{}; int count = recv(client, request, sizeof(request), 0);
      ++fixture_requests;
      if (count > 0 && std::string_view(request, count).find("slow") != std::string_view::npos) Sleep(350);
      const std::string reply = count > 0 && std::string_view(request, count).find("missing") != std::string_view::npos
          ? "1/server-only/\n" : "1/file/server-extra/\n";
      send(client, reply.data(), static_cast<int>(reply.size()), 0); closesocket(client);
    }
  });
  g_dictionary_server.config_loaded = true;
  g_dictionary_server.config.enabled = 1; g_dictionary_server.config.port = 31101;
  g_builtin_dictionary.maps = {{{"present", "/file/"}}};
  g_builtin_dictionary.ready = true;
  g_server_cache.Start();
  check(LookupDictionary("present") == "1/file/server-extra/", "fixture file plus server");
  check(LookupDictionary("missing") == "1/server-only/", "fixture server-only");
  const auto requests = fixture_requests.load();
  check(LookupDictionary("present") == "1/file/server-extra/" && fixture_requests == requests, "cache reuse");
  auto started = GetTickCount64();
  check(!g_server_cache.Query("slow"), "slow request queues without waiting");
  check(GetTickCount64() - started < 30, "slow server cannot stall cache consumer");
  started = GetTickCount64();
  check(LookupDictionary("slow") == "4", "slow server degrades to miss");
  check(GetTickCount64() - started < 250, "provider server miss bounded");
  SetEnvironmentVariableW(L"DDSKK_SKKSERV_ENABLE", L"0");
  check(LookupDictionary("present") == "1/file/", "config disables server and invalidates cache");
  const auto disabled_requests = fixture_requests.load();
  g_builtin_dictionary.maps[0]["\xe3\x81\x8bk"] = "/written;note/hung/[ku/written/]/";
  // The existing file relay removes bracket blocks; keep that exact base
  // behavior, including candidate annotations and the okuri-bearing key.
  check(LookupDictionary("\xe3\x81\x8bk") == "1/written;note/hung/",
        "disabled provider preserves base okuri file reply");
  check(LookupDictionary("disabled-missing") == "4", "disabled provider preserves miss");
  check(fixture_requests == disabled_requests, "disabled provider never requests external server");
  SetEnvironmentVariableW(L"DDSKK_SKKSERV_ENABLE", L"1");
  SetEnvironmentVariableW(L"DDSKK_SKKSERV_PORT", L"31199");
  const auto refused_started = std::chrono::steady_clock::now();
  check(!g_server_cache.Query("unreachable-async"), "unreachable request queues without waiting");
  check(std::chrono::steady_clock::now() - refused_started < std::chrono::milliseconds(30),
        "unreachable server cannot stall cache consumer");
  check(LookupDictionary("missing") == "4", "unreachable server degrades to miss");
  check(LookupDictionary("present") == "1/file/", "unreachable provider preserves file reply");
  check(LookupDictionary("\xe3\x81\x8bk") == "1/written;note/hung/",
        "unreachable provider preserves base okuri file reply");
  SetEnvironmentVariableW(L"DDSKK_SKKSERV_PORT", L"31101");
  check(LookupDictionary("present") == "1/file/server-extra/", "config enables server fresh reply");
  check(g_server_cache.Query("present", "okuri", 200) == std::optional<std::string>{"1/file/server-extra/"}, "okuri cache key");
  check(fixture_requests > requests, "config and okuri require new request");
  g_server_cache.Stop();
  fixture_stop = true; fixture.join(); closesocket(listener);
  ShutdownDictionaryServer();
  check(MergeServerReply("/file;note/", "/file;later/(concat a b)/[u/x/]/") ==
      "1/file;note/(concat a b)/[u/x/]/", "provider preserves expressions and blocks");
  std::string many = "/"; for (unsigned n = 0; n < 1100; ++n) many += "word" + std::to_string(n) + '/';
  check(MergeServerReply("/first/", many) == "1/first" + many, "provider retains large server source");
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
