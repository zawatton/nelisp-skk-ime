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
  std::atomic<unsigned> fixture_requests{0}, fixture_completed{0};
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
      ++fixture_completed;
    }
  });
  g_dictionary_server.config_loaded = true;
  g_dictionary_server.config.enabled = 1; g_dictionary_server.config.port = 31101;
  hn_builder::Maps dictionary_maps = {{{"present", "/file/"}}};
  g_builtin_dictionary.Publish(1, dictionary_maps);
  g_server_cache.Start();
  check(LookupDictionary("present") == "1/file/server-extra/", "fixture file plus server");
  check(LookupDictionary("missing") == "1/server-only/", "fixture server-only");
  const auto requests = fixture_requests.load();
  check(LookupDictionary("present") == "1/file/server-extra/" && fixture_requests == requests, "cache reuse");
  auto cache_started = GetTickCount64();
  check(!g_server_cache.Query("slow"), "slow request queues without waiting");
  check(GetTickCount64() - cache_started < 30, "slow server cannot stall cache consumer");
  cache_started = GetTickCount64();
  check(LookupDictionary("slow") == "4", "slow server degrades to miss");
  check(GetTickCount64() - cache_started < 250, "provider server miss bounded");
  {
    const auto before = fixture_requests.load();
    const auto previous_done = GetTickCount64() + 1000;
    while (fixture_completed < before && GetTickCount64() < previous_done) Sleep(1);
    std::promise<void> begun;
    std::string reply;
    std::thread provider([&] {
      EngineTransaction transaction;
      begun.set_value();
      reply = LookupDictionary("slow-engine-mutex");
    });
    begun.get_future().wait();
    const auto deadline = GetTickCount64() + 500;
    while (fixture_requests == before && GetTickCount64() < deadline) Sleep(1);
    check(fixture_requests > before, "slow provider relay reaches socket worker");
    const bool metadata_free = g_engine_mutex.try_lock();
    check(metadata_free, "provider cache wait releases engine metadata mutex");
    if (metadata_free) g_engine_mutex.unlock();
    const bool interpreter_free = g_interpreter_mutex.try_lock();
    check(!interpreter_free, "relay retains interpreter transaction identity");
    if (interpreter_free) g_interpreter_mutex.unlock();
    provider.join();
    check(reply == "4", "unlocked slow relay retains bounded miss behavior");
  }
  SetEnvironmentVariableW(L"DDSKK_SKKSERV_ENABLE", L"0");
  check(LookupDictionary("present") == "1/file/", "config disables server and invalidates cache");
  const auto disabled_requests = fixture_requests.load();
  dictionary_maps[0]["\xe3\x81\x8bk"] = "/written;note/hung/[ku/written/]/";
  g_builtin_dictionary.Publish(2, dictionary_maps);
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
  const auto learning = [&](const std::string& header, const std::string& body) {
    size_t offset = 0;
    return DecodeLearning2(header, [&](unsigned char* ch) {
      if (offset == body.size()) return false;
      *ch = static_cast<unsigned char>(body[offset++]); return true;
    }, &output) && offset == body.size();
  };
  check(learning("LEARNING2 3", "a\n\xe6\xbc\xa2\n"), "learning Unicode scalar framing");
  check(output == "LEARNING2 a\n\xe6\xbc\xa2", "learning raw UTF8 contents");
  check(!learning("LEARNING2 1", "\xc0\x80\n"), "learning invalid UTF8 rejected");
  check(!learning("LEARNING2 1048577", ""), "learning size bound");
  check(!learning("LEARNING2 1", "a"), "learning truncated frame rejected");
  // Worker I/O must leave the engine mutex available and preserve FIFO.
  std::promise<void> started, release;
  auto released = release.get_future().share();
  std::vector<std::string> order;
  {
    ddskk::LearningQueue queue(L"", [&](const std::string& content) {
      if (order.empty()) { started.set_value(); released.wait(); }
      order.push_back(content); return true;
    });
    auto first = queue.Submit(";; EG2 delta v2\n;; EG2 revision 7\n;; local-ack test 1 7\n;; okuri-nasi entries.\na /one/two/\n");
    started.get_future().wait();
    auto second = queue.Submit(";; EG2 delta v2\n;; EG2 revision 8\n;; local-ack test 2 8\n;; okuri-nasi entries.\na /two/one/\n");
    check(first.wait_for(std::chrono::milliseconds(0)) == std::future_status::timeout,
          "learning submission does not wait for I/O");
    const bool unlocked = g_engine_mutex.try_lock();
    check(unlocked, "learning I/O releases engine mutex");
    if (unlocked) g_engine_mutex.unlock();
    const auto overlay = queue.OverlaySnapshot();
    check(overlay.find("a /two/one/") != std::string::npos && queue.OverlayRevision() == 8,
          "overlay reflects pending learning while storage is blocked");
    check(first.wait_for(std::chrono::milliseconds(0)) == std::future_status::timeout,
          "overlay publication does not wait for storage");
    check(overlay.find(";; local-ack ") == std::string::npos,
          "volatile overlay cannot retire an unacknowledged producer spool");
    const auto volatile_generation = queue.SnapshotGeneration();
    release.set_value();
    check(first.get() && second.get(), "learning barriers complete");
    queue.Drain();
    const auto durable_overlay = queue.OverlaySnapshot();
    check(durable_overlay.find(";; local-ack test 2 8") != std::string::npos,
          "overlay publishes latest retirement watermark after durable FIFO completion");
    check(queue.SnapshotGeneration() > volatile_generation,
          "durable watermark publication advances generation without another revision");
  }
  check(order.size() == 2 && order[0].find("a /one/two/") != std::string::npos &&
      order[1].find("a /two/one/") != std::string::npos, "learning FIFO and shutdown drain");
  {
    std::promise<bool> durable;
    auto future = durable.get_future().share();
    const double start = ProfileMilliseconds();
    std::thread slow([&] { Sleep(150); durable.set_value(true); });
    auto response = LearningReply("STATE hiragana 1 -1 006f22 - -1 -", future);
    const double wait = ProfileMilliseconds() - start;
    check(future.wait_for(std::chrono::milliseconds(0)) == std::future_status::timeout,
          "commit reply leaves durability pending");
    std::printf("commit durability reply QPC wait_ms=%.6f\n", wait);
    slow.join();
    check(response.starts_with("STATE "), "commit final state preserved");
    check(LearningReply("ACK client.1 1", future) == "ACK client.1 1", "durable local ACK retained");
  }
  {
    std::atomic<unsigned> attempts{0};
    ddskk::LearningQueue retry(L"", [&](const std::string&) { return ++attempts > 1; });
    check(retry.Submit("retry").get() && attempts == 2, "transient storage failure retries the same FIFO operation");
    retry.Drain();
  }
  const auto directory = ddskk::local::Directory() / "eg2-worker-test";
  std::filesystem::create_directories(directory);
  const auto target = directory / "user.jisyo";
  {
    ddskk::LearningQueue queue(target.wstring());
    check(queue.Submit(";; EG2 checkpoint v2\n;; first\n").get(), "durable first checkpoint");
    check(queue.Submit(";; EG2 checkpoint v2\n;; last\n").get(), "durable ordered checkpoint");
  }
  std::ifstream checkpoint(target, std::ios::binary);
  std::string stored((std::istreambuf_iterator<char>(checkpoint)), {});
  checkpoint.close();
  check(stored == ";; EG2 journal 0 -\n;; EG2 checkpoint v2\n;; last\n;; EG2 length 48\n", "atomic checkpoint contents");
  check(std::filesystem::file_size(target.wstring() + L".journal") == 0,
        "superseded journal cleared");
  {
    ddskk::LearningQueue queue(target.wstring());
    check(queue.Submit(";; EG2 delta v2\n;; local-ack a 1 2\n;; okuri-ari entries.\nk /write/[u/write/]/\n;; okuri-nasi entries.\na /one/two/\n").get(), "durable entry fragments");
    check(queue.Submit(";; EG2 delta v2\n;; local-ack a 2 3\n;; okuri-nasi entries.\na /two/one/\n").get(), "delta preserves operation order");
    queue.Drain();
  }
  std::ifstream delta_file(target, std::ios::binary);
  std::string delta_stored((std::istreambuf_iterator<char>(delta_file)), {});
  delta_file.close();
  check(delta_stored.find("a /two/one/") != std::string::npos &&
        delta_stored.find("k /write/[u/write/]/") != std::string::npos,
        "delta preserves other readings and okuri blocks");
  check(delta_stored.find(";; local-ack a 2 3") != std::string::npos &&
        delta_stored.find(";; local-ack a 1 2") == std::string::npos,
        "delta preserves latest operation watermark atomically");
  {
    ddskk::LearningQueue queue(target.wstring());
    check(queue.Submit(";; EG2 delta v2\n;; okuri-nasi entries.\nc /third/\n").get(), "initial native cache");
    std::ofstream legacy(target.wstring() + L".journal", std::ios::binary);
    legacy << "a /fresh-legacy/\n"; legacy.close();
    check(queue.Submit("").get(), "replacement resets native cache without I/O");
    check(queue.Submit(";; EG2 delta v2\n;; okuri-nasi entries.\nb /new/\n").get(), "replacement reloads legacy learning");
  }
  std::ifstream restarted_file(target, std::ios::binary);
  std::string restarted((std::istreambuf_iterator<char>(restarted_file)), {});
  restarted_file.close();
  check(restarted.find("a /fresh-legacy/") != std::string::npos &&
        restarted.find("b /new/") != std::string::npos,
        "fresh legacy journal survives engine replacement");
  {
    std::ofstream journal(target.wstring() + L".journal", std::ios::binary);
    journal << "かな /古い/\n"; journal.close();
    ddskk::LearningQueue queue(target.wstring());
    check(queue.Submit("").get() && queue.Submit(";; EG2 delta v2\n;; okuri-nasi entries.\nd /fourth/\n").get(),
          "Unicode legacy journal checkpoint");
  }
  std::ifstream unicode_file(target, std::ios::binary);
  std::string unicode_stored((std::istreambuf_iterator<char>(unicode_file)), {});
  unicode_file.close();
  check(unicode_stored.starts_with(";; EG2 journal 8 00304b00306a00002000002f0053e400304400002f00000a\n"),
        "exact journal identity matches Lisp scalar encoding");
  {
    ddskk::LearningQueue bad(directory.wstring());
    auto failed = bad.Submit("cannot replace a directory");
    bad.BeginDrain();
    check(!failed.get(), "publication failure is not acknowledged");
  }
  {
    const auto recovery = directory / "recover.jisyo";
    const std::string rows = ";; EG2 journal 0 -\n;; EG2 checkpoint v2\n;; local-ack retry 1 9\n;; okuri-nasi entries.\na /recovered/\n";
    const auto contents = rows + ";; EG2 length " + std::to_string(rows.size()) + "\n";
    { std::ofstream pending(recovery.wstring() + L".eg2-checkpoint", std::ios::binary); pending << contents; }
    check(ddskk::LearningQueue::RecoverPending(recovery.wstring()), "restart publishes flushed pending checkpoint");
    std::ifstream recovered(recovery, std::ios::binary);
    check(std::string((std::istreambuf_iterator<char>(recovered)), {}) == contents,
          "restart preserves operation identity and candidate order");
    { std::ofstream torn(recovery.wstring() + L".eg2-checkpoint", std::ios::binary); torn << contents.substr(0, contents.size()-1); }
    check(!ddskk::LearningQueue::RecoverPending(recovery.wstring()), "torn pending checkpoint rejected");
  }
  {
    const auto producer_target = (directory / "producer.jisyo").wstring();
    std::atomic<unsigned> calls{0}; std::vector<uint64_t> observed;
    ddskk::LearningQueue queue(producer_target, [&](const std::string& content) {
      ++calls;
      observed.push_back(content.find("a /first/\n") != std::string::npos ? 1 : 2);
      return true;
    });
    auto first = queue.ReserveProducer(";; EG2 delta v2\n;; EG2 revision 1\n;; okuri-nasi entries.\na /first/\n");
    auto second = queue.ReserveProducer(";; EG2 delta v2\n;; EG2 revision 2\n;; okuri-nasi entries.\na /second/first/\n");
    check(first && second && first->id == 1 && second->id == 2, "producer operation ids ordered");
    check(queue.SealProducer(second), "later client appends without waiting for earlier client");
    check(second->done.wait_for(std::chrono::milliseconds(20)) == std::future_status::timeout && !calls,
          "worker cannot overtake an unsealed provider operation");
    check(queue.SealProducer(first) && first->done.get() && second->done.get(), "outbox flush releases FIFO work");
    queue.Drain();
    check(observed == std::vector<uint64_t>{1, 2}, "producer FIFO despite append completion order");
    check(ddskk::LearningQueue::RecoverOutbox(producer_target), "startup replays outbox in operation order");
    std::ifstream file(producer_target, std::ios::binary);
    const std::string producer_stored((std::istreambuf_iterator<char>(file)), {});
    file.close();
    check(producer_stored.find("a /second/first/\n") != std::string::npos &&
        producer_stored.find(";; EG2 provider 2\n") != std::string::npos, "replay stores rows and operation watermark atomically");
    check(std::filesystem::file_size(producer_target + L".eg2-outbox") == 0, "replayed outbox retired");
    ddskk::ProviderOutbox old(producer_target);
    check(old.Append(first->id, first->content), "simulate checkpoint-before-retirement crash");
    check(ddskk::LearningQueue::RecoverOutbox(producer_target), "checkpointed id is skipped on replay");
    std::ifstream again(producer_target, std::ios::binary);
    check(std::string((std::istreambuf_iterator<char>(again)), {}) == producer_stored, "stale replay cannot reorder current candidates");
    again.close();
    { std::ofstream torn(producer_target + L".eg2-outbox", std::ios::binary); torn << "EG2-OUTBOX 1 3"; }
    check(ddskk::LearningQueue::RecoverOutbox(producer_target), "unacknowledged torn suffix is discarded");
    { std::ofstream corrupt(producer_target + L".eg2-outbox", std::ios::binary); corrupt << "EG2-OUTBOX 1 3 1 0\nx\nEG2-END 3\n"; }
    check(!ddskk::LearningQueue::RecoverOutbox(producer_target), "complete corrupt record fails closed");
    std::filesystem::remove(producer_target + L".eg2-outbox");
    ddskk::LearningQueue producer_restarted(producer_target);
    auto next = producer_restarted.ReserveProducer(";; EG2 delta v2\n;; EG2 revision 3\n;; okuri-nasi entries.\nb /third/\n");
    check(next && next->id == 3 && producer_restarted.SealProducer(next) && next->done.get(), "restart advances durable provider identity");
    producer_restarted.Drain();
    check(std::filesystem::file_size(producer_target + L".eg2-outbox") == 0, "worker retires operation after durability");
    // Model an old engine save which preserves rows but drops unknown comments.
    std::ifstream legacy_input(producer_target, std::ios::binary);
    std::string legacy_contents((std::istreambuf_iterator<char>(legacy_input)), {}); legacy_input.close();
    const auto watermark_start = legacy_contents.find(";; EG2 provider ");
    legacy_contents.erase(watermark_start, legacy_contents.find('\n', watermark_start)-watermark_start+1);
    { std::ofstream legacy_save(producer_target, std::ios::binary); legacy_save << legacy_contents; }
    check(old.Append(first->id, first->content) && ddskk::LearningQueue::RecoverOutbox(producer_target),
          "legacy save cannot lose durable provider replay identity");
    std::ifstream legacy_verify(producer_target, std::ios::binary);
    check(std::string((std::istreambuf_iterator<char>(legacy_verify)), {}) == legacy_contents,
          "old-engine rewrite does not reapply retired learning"); legacy_verify.close();
    ddskk::LearningQueue after_legacy(producer_target);
    auto fourth = after_legacy.ReserveProducer(";; EG2 delta v2\n;; okuri-nasi entries.\nc /fourth/\n");
    check(fourth && fourth->id == 4 && after_legacy.SealProducer(fourth) && fourth->done.get(),
          "provider ids stay monotonic after old-engine rewrite"); after_legacy.Drain();
    { std::ofstream cursor(producer_target + L".eg2-provider-watermark", std::ios::binary); cursor << "EG2-PROVIDER 1 broken\n"; }
    check(!ddskk::LearningQueue::RecoverOutbox(producer_target), "corrupt durable provider cursor fails closed");
    { std::ofstream cursor(producer_target + L".eg2-provider-watermark", std::ios::binary); cursor << "EG2-PROVIDER 1 4\n"; }
    check(ddskk::LearningQueue::RecoverOutbox(producer_target), "valid provider cursor preserves restart readiness");


  }
  {
    const auto unavailable_target = (directory / "unavailable.jisyo").wstring();
    std::filesystem::create_directory(directory / "unavailable.jisyo.eg2-outbox");
    g_learning_queue = std::make_unique<ddskk::LearningQueue>(unavailable_target);
    auto operation = g_learning_queue->ReserveProducer(";; EG2 delta v2\n;; okuri-nasi entries.\na /lost/\n");
    g_learning_producers.push_back(operation);
    check(LearningReply("STATE hiragana 1 -1 006f22 - -1 -", operation->done) == "ERR LOCAL STORAGE",
          "failed producer append prevents STATE acknowledgement");
    check(!operation->done.get(), "failed producer append never reaches dictionary writer");
    g_learning_queue->Drain(); g_learning_queue.reset();
  }
  std::filesystem::remove_all(directory);
  std::printf("host UTF8 protocol: %d checks, %d failures\n", checks, failures);
  return failures ? 1 : 0;
}
