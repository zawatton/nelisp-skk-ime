// GPL-3.0-or-later
#include "local_conversion.h"
#include "state_mirror.h"
#include <fstream>
#include <iostream>
#include <stdexcept>

using namespace ddskk::local;
namespace {
int checks = 0;
void Check(bool value, const char* label) { if (!value) throw std::runtime_error(label); ++checks; }
void File(const std::filesystem::path& path, std::string_view bytes) { std::ofstream(path, std::ios::binary) << bytes; }
std::string rules = "RULES 1 000061:-:003042:0030a2:-";
void Reject(const std::filesystem::path& path, const char* label) {
  bool rejected = false; try { Index index(path); } catch (...) { rejected = true; }
  Check(rejected, label);
}
}
int main(int argc, char** argv) {
  try {
    const auto root = argc > 1 ? std::filesystem::path(argv[1]) : Directory() / "selftest";
    std::filesystem::create_directories(root);
    if (argc > 4) {
      const auto navigation = root / "navigation.jisyo";
      File(navigation, "かな /仮名/佳奈/加奈/可奈/哉/金/香奈/花菜/奏/叶/華奈/河南/\n");
      Publish(root / "navigation", {navigation}, "", rules, 3);
      auto index = OpenPublished(root / "navigation");
      std::ifstream oracle(argv[4]); std::string kind;
      size_t rows = 0;
      while (oracle >> kind) {
        Conversion value; Check(value.Begin(index, L"かな"), "first-only navigation begin");
        if (kind == "previous") {
          size_t from; int to; std::string text;
          oracle >> from >> to >> text;
          Check(value.Select(from), "oracle previous setup");
          const bool previous = value.Previous();
          Check(previous == (to >= 0), "stock previous/reading boundary");
          if (previous) Check(value.State().text == Unhex(text), "stock previous text");
          else Check(Unhex(text) == L"▽かな", "stock first to reading");
        } else if (kind == "menu") {
          std::string events, pages; int to; oracle >> events >> pages >> to;
          Check(value.Select(4), "oracle menu setup");
          if (events.starts_with("32,")) {
            Check(value.NextMenu() && value.State().candidate_index == 11, "stock next menu page");
            Check(value.PreviousMenu() && value.State().candidate_index == to, "stock previous menu page");
          } else Check(value.PreviousMenu() && value.State().candidate_index == to - 1, "stock menu escape then previous");
          Check(pages == (events.starts_with("32,") ? "4,11,4" : "4"), "stock default page offsets");
        } else throw std::runtime_error("Unknown navigation oracle row");
        ++rows;
      }
      Check(rows == 16, "navigation oracle complete");
      std::cout << "Stock DDSKK navigation oracle rows=16 PASS\n";
    }
    const auto source = root / "shared.jisyo", second = root / "second.jisyo";
    File(source, "かな /仮名;first/哉/金/加奈/佳奈/香奈/\nか /蚊/\nかんじ /漢字/幹事/感じ/\nにほん /日本/二本/\nすうじ /(concat 1)/\n");
    File(second, "かな /仮名;later/可奈/\nながい /" + std::string(1025, 'a') + "/\n");
    const std::string user = "かな /佳奈/仮名/\n";
    Publish(root, {source, second}, user, rules, 1);
    auto original = OpenPublished(root);
    Check(original->Lookup(L"かな").shared.size() == 7, "configured file merge");
    Check(original->Lookup(L"かな").shared.front() == L"仮名;first", "first annotation");
    Conversion conversion;
    Check(conversion.Begin(original, L"かな"), "plain conversion");
    Check(conversion.State().candidates.size() == 2, "personal source frontier");
    Check(conversion.State().text == L"▼佳奈", "first candidate");
    Check(conversion.Next() && conversion.State().text == L"▼仮名", "next candidate");
    Check(conversion.Next() && conversion.State().text == L"▼仮名", "directional stock annotation union");
    Check(conversion.State().candidates.size() == 8, "shared frontier union");
    Check(conversion.Previous(), "x traversal");
    Check(conversion.Commit().text == L"仮名", "annotation-free commit");
    Check(!conversion.active(), "commit terminal");
    Check(!conversion.Begin(original, L"すうじ"), "expression provider capability");
    Check(!conversion.Begin(original, L"かな1"), "numeric provider capability");
    Check(!conversion.Begin(original, L"かk"), "okuri provider capability");
    Check(!conversion.Begin(original, L"ながい"), "oversized learning selects provider before conversion");
    Check(!conversion.Begin(original, L"みす"), "missing reading provider registration");
    Check(conversion.Begin(original, L"かな", {L"哉"}) && conversion.State().text == L"▼哉", "pending learning order");
    Publish(root, {source, second}, "かな /哉/佳奈/仮名/\n", rules, 1);
    auto learned = OpenPublished(root);
    Check(original->Lookup(L"かな").user.front() == L"佳奈", "pinned old generation");
    Check(learned->Lookup(L"かな").user.front() == L"哉", "new overlay generation");
    bool failed = false; try { Publish(root, {root / "missing"}, user, rules, 1); } catch (...) { failed = true; }
    Check(failed && OpenPublished(root)->header().generation == learned->header().generation, "missing source retains publication");
    Publish(root, {source}, user, rules, 0);
    Check(!OpenPublished(root)->Lookup(L"かな").supported, "uncertified source plan");
    // Live-shaped source plan: unsorted personal source, six duplicate keys,
    // shared words with and without annotations, plus an overlay of the same word.
    const auto personal = root / "unsorted.jisyo", large = root / "overlap.jisyo";
    File(personal, "ていこうち /抵抗値/\nあたい /値/\nおーむ /Ω/オーム/\nかな /仮名/\nあたい /値/\nていこうち /抵抗値/\nおーむ /Ω/オーム/\nかな /仮名/\nあたい /値/\nていこうち /抵抗値/\n");
    File(large, "あたい /値;value. (字義:そのものの価値)/価;price/\nおーむ /Ω/王蟲/\nていこうち /抵抗値/\nかんじ /漢字/\n");
    Publish(root, {personal, large}, "ていこうち /抵抗値/\n", rules, 1);
    auto overlap = OpenPublished(root);
    Check(overlap->Lookup(L"ていこうち").shared == std::vector<std::wstring>{L"抵抗値"}, "duplicate unsorted source merge");
    Check(overlap->Lookup(L"おーむ").shared == std::vector<std::wstring>{L"Ω", L"オーム", L"王蟲"}, "prolonged kana source order");
    Check(overlap->Lookup(L"あたい").shared == std::vector<std::wstring>{L"値", L"価;price"}, "first source annotation identity");
    Check(conversion.Begin(overlap, L"ていこうち"), "overlapping overlay begin");
    Check(!conversion.Next() && conversion.active(), "duplicate frontier exhausts without stuck state");
    Check(conversion.Commit().text == L"抵抗値", "single overlapping candidate commit");
    Check(conversion.Begin(overlap, L"おーむ"), "prolonged kana local capability");
    Check(conversion.Next() && conversion.State().text == L"▼オーム", "overlap traversal");
    Check(conversion.Next() && conversion.Commit().text == L"王蟲", "third source candidate commit");
    const auto verbs = root / "okuri.jisyo";
    File(verbs, "かk /書/掛/[く/書/掛/]/\nかt /買/飼/[った/買/飼/]/\nしn /死/[んだ/死/]/\n");
    Publish(root, {verbs}, "", rules, 3);
    auto okuri_index = OpenPublished(root);
    Check(conversion.Begin(okuri_index, L"かk", {}, L"く"), "certified okuri");
    Check(conversion.State().text == L"▼書く", "okuri display");
    Check(conversion.Next() && conversion.Commit().text == L"掛く", "okuri traversal commit");
    Check(conversion.Begin(okuri_index, L"かt", {}, L"った") && conversion.Commit().text == L"買った", "sokuon okuri commit");
    Check(conversion.Begin(okuri_index, L"しn", {}, L"んだ") && conversion.Commit().text == L"死んだ", "n okuri commit");
    Publish(root, {verbs}, "かk /掛/書/[く/掛/書/]/\n", rules, 3, 1);
    auto okuri_learned = OpenPublished(root);
    Check(conversion.Begin(okuri_learned, L"かk", {}, L"く") && conversion.State().text == L"▼掛く", "learned okuri order");
    // An open frontier retains its generation and capability through swaps.
    Publish(root, {verbs}, "", rules, 0);
    Check(conversion.Previous() == false && conversion.Commit().text == L"掛く", "capability swap pins open okuri");
    Check(!conversion.Begin(OpenPublished(root), L"かk", {}, L"く"), "new uncertified okuri selects provider");
    Publish(root, {source}, user, rules, 0);
    const auto current = root / "current";
    std::ifstream manifest(current); std::string name; manifest >> name;
    std::ifstream in(root / name, std::ios::binary);
    std::string bytes((std::istreambuf_iterator<char>(in)), {});
    File(root / "truncated.index", bytes.substr(0, bytes.size() - 1)); Reject(root / "truncated.index", "truncated negative control");
    bytes.back() ^= 1; File(root / "corrupt.index", bytes); Reject(root / "corrupt.index", "checksum negative control");
    bytes.back() ^= 1; reinterpret_cast<Header*>(bytes.data())->schema = 99;
    File(root / "schema.index", bytes); Reject(root / "schema.index", "schema negative control");
    File(root / "badutf8.jisyo", "かな /\xff/\n");
    failed = false; try { Publish(root, {root / "badutf8.jisyo"}, user, rules, 1); } catch (...) { failed = true; }
    Check(failed, "malformed UTF8 negative control");
    std::vector<std::wstring> a{L"仮名"}; Union(a, {L"仮名;note"});
    Check(a.size() == 2, "unannotated directional equality");
    a = {L"仮名;note"}; Union(a, {L"仮名", L"仮名;other"});
    Check(a.size() == 1, "annotated directional equality");
    Check(Unhex(ScalarHex(L"漢字😀")) == L"漢字😀", "scalar roundtrip");
    // Store restart must retain pending learning and the producer identity.
    // Every transport/data path is private even when this binary runs directly.
    const auto worker_data = std::filesystem::absolute(root / "worker-data").wstring();
    SetEnvironmentVariableW(L"LOCALAPPDATA", worker_data.c_str());
    const auto registry = L"Software\\NativeIME-test-local-store-" + std::to_wstring(GetCurrentProcessId());
    SetEnvironmentVariableW(L"NATIVEIME_REGISTRY_KEY", registry.c_str());
    const auto pipe = L"\\\\.\\pipe\\local-store-test-" + std::to_wstring(GetCurrentProcessId());
    SetEnvironmentVariableW(L"DDSKK_PIPE_NAME", pipe.c_str());
    Publish(Directory(), {source}, "", rules, 1);
    const HANDLE mirror = CreateFileMappingW(INVALID_HANDLE_VALUE, nullptr, PAGE_READWRITE, 0,
        sizeof(NativeStateMirror), NativeStateMirrorName(pipe).c_str());
    auto* mirror_view = static_cast<NativeStateMirror*>(MapViewOfFile(mirror, FILE_MAP_WRITE, 0, 0, sizeof(NativeStateMirror)));
    Check(mirror_view != nullptr, "private observer mapping");
    const HANDLE owner_map = CreateFileMappingW(INVALID_HANDLE_VALUE, nullptr, PAGE_READWRITE, 0,
        sizeof(NativeStateOwner), (NativeStateMirrorName(pipe) + L"-owner").c_str());
    auto* owner_view = static_cast<NativeStateOwner*>(MapViewOfFile(owner_map, FILE_MAP_WRITE, 0, 0, sizeof(NativeStateOwner)));
    Check(owner_view != nullptr, "private observer ownership mapping");
    const HANDLE writer_mutex = CreateMutexW(nullptr, FALSE, (NativeStateMirrorName(pipe) + L"-writer").c_str());
    Store store; store.Start();
    for (unsigned n = 0; n < 200 && !store.Current(); ++n) Sleep(10);
    Check(store.Current() != nullptr, "worker publishes verified snapshot");
    Conversion observed; Check(observed.Begin(store.Current(), L"かな"), "unlearned observer conversion");
    Check(store.PublishState(observed.State()), "first candidate reaches Sumi mirror offline");
    Check(std::string(mirror_view->line).starts_with("STATE candidate "), "observer has authoritative local mode");
    LONG writer = 0; Check(TryOwnStateMirror(mirror_view, &writer, writer_mutex), "stalled publication writer seam");
    const auto begin = GetTickCount64();
    Check(!store.PublishState(observed.State()), "stalled mirror writer never blocks input");
    Check(GetTickCount64() - begin <= 25, "observer callback watchdog 25 ms");
    store.ReleaseState();
    Check(!owner_view->requested_owner, "stalled writer cannot strand provider handoff");
    Check(store.PublishState(observed.State(), false), "released authority cancels observer retry");
    ReleaseStateMirror(mirror_view, writer, writer_mutex);
    Check(observed.Next() && store.PublishState(observed.State()), "observer progresses after publication stall");
    bool crashed_writer = false;
    std::thread([&] {
      LONG abandoned_sequence = 0;
      if (TryOwnStateMirror(mirror_view, &abandoned_sequence, writer_mutex)) {
        crashed_writer = true; mirror_view->line[0] = '?';
        // Intentional thread exit while owning the mutex: model a dead writer.
      }
    }).join();
    Check(crashed_writer, "dead observer writer exercised");
    Check(store.PublishState(observed.State()) && !(mirror_view->sequence & 1), "dead writer recovers without spinning");
    Check(std::string(mirror_view->line).starts_with("STATE candidate "), "dead writer partial snapshot replaced");
    Check(owner_view->local_owner == static_cast<LONG>(GetCurrentProcessId()), "local observer ownership");
    InterlockedExchange(&owner_view->requested_owner, 0);
    const auto stable = std::string(mirror_view->line);
    Check(store.PublishState(observed.Commit(), false) && stable == mirror_view->line, "focus supersedes stale observer retry");
    ddskk::EngineState settled; settled.mode = L"hiragana"; store.PublishState(settled);
    store.ReleaseState(); Check(!owner_view->local_owner, "provider observer handoff");
    Check(store.Learn(L"かな", L"哉") && store.Learn(L"かな", L"金"), "offline learning enqueue");
    store.Stop(); store.Start();
    const auto recovered = store.Capture();
    Check(recovered.pending.size() == 2 && recovered.pending[1].candidate == L"金", "restart retains pending order");
    Check(store.Learn(L"かな", L"仮名"), "restart continues learning identity");
    bool stopped = false;
    for (unsigned n = 0; n < 300 && !stopped; ++n) { stopped = store.PrepareHandoff(); if (!stopped) Sleep(10); }
    Check(stopped, "handoff drains durable learning off input thread");
    store.Stop();
    CloseHandle(writer_mutex);
    UnmapViewOfFile(owner_view); CloseHandle(owner_map);
    UnmapViewOfFile(mirror_view); CloseHandle(mirror);
    // A verified generation can be available before the observer mapping.
    // First snapshots survive that race; cancellation/new ownership wins.
    auto late_observer = [&](const wchar_t* suffix, int fault) {
      const auto late_pipe = pipe + suffix;
      SetEnvironmentVariableW(L"DDSKK_PIPE_NAME", late_pipe.c_str());
      Publish(Directory(), {source}, "", rules, 1);
      Store late; late.Start();
      for (unsigned n = 0; n < 200 && !late.Current(); ++n) Sleep(10);
      Check(late.Current() != nullptr, "late observer generation ready");
      Conversion first; Check(first.Begin(late.Current(), L"かな"), "late observer first-only reading");
      Check(!late.PublishState(first.State()), "first snapshot waits for absent observer resource");
      if (fault == 1) late.ReleaseState(); // focus/provider handoff before mapping
      const auto late_name = NativeStateMirrorName(late_pipe);
      HANDLE late_map = CreateFileMappingW(INVALID_HANDLE_VALUE, nullptr, PAGE_READWRITE, 0, sizeof(NativeStateMirror), late_name.c_str());
      auto* late_view = static_cast<NativeStateMirror*>(MapViewOfFile(late_map, FILE_MAP_WRITE, 0, 0, sizeof(NativeStateMirror)));
      HANDLE late_owner = CreateFileMappingW(INVALID_HANDLE_VALUE, nullptr, PAGE_READWRITE, 0, sizeof(NativeStateOwner), (late_name + L"-owner").c_str());
      auto* late_intent = static_cast<NativeStateOwner*>(MapViewOfFile(late_owner, FILE_MAP_WRITE, 0, 0, sizeof(NativeStateOwner)));
      HANDLE late_writer = CreateMutexW(nullptr, FALSE, (late_name + L"-writer").c_str());
      Check(late_view && late_intent && late_writer, "late observer resources created");
      if (fault == 2) {
        InterlockedExchange(&late_intent->requested_owner, 12345);
        strcpy_s(late_view->line, "STATE newer-owner");
      }
      for (unsigned n = 0; n < 200; ++n) { if (late.PublishState(first.State(), false)) break; Sleep(10); }
      const auto line = std::string(late_view->line);
      const bool correct = fault == 0 ? line.starts_with("STATE candidate ")
          : fault == 1 ? line.empty() : line == "STATE newer-owner" && late_intent->requested_owner == 12345;
      late.ReleaseState(); late.Stop();
      UnmapViewOfFile(late_intent); UnmapViewOfFile(late_view);
      CloseHandle(late_writer); CloseHandle(late_owner); CloseHandle(late_map);
      Check(correct, fault == 0 ? "first snapshot survives late observer publication"
          : fault == 1 ? "cancel before mapping cannot revive first snapshot" : "newer owner supersedes late first snapshot");
    };
    late_observer(L"-late", 0);
    late_observer(L"-late-cancel", 1);
    late_observer(L"-late-superseded", 2);
    if (argc > 2) {
      // Independent stock oracle: key, complete candidate vector, committed
      // text. Each row exercises traversal from the local source frontier.
      std::ifstream oracle(argv[2]); std::string key, candidates, commit;
      int rows = 0;
      while (oracle >> key >> candidates >> commit) {
        const auto reading = Unhex(key);
        auto index = rows < 4 ? original : learned;
        Check(conversion.Begin(index, reading), "stock oracle begin");
        while (conversion.Next()) {}
        std::wstring list;
        for (const auto& candidate : conversion.State().candidates) { list += L"/"; list += candidate; }
        list += L"/";
        Check(list == Unhex(candidates), "stock DDSKK candidate order");
        Check(conversion.Select(conversion.State().candidates.size() - 1), "stock selected identity");
        Check(conversion.Commit().text == Unhex(commit), "stock commit text");
        ++rows;
      }
      Check(rows == 8, "stock corpus count");
      std::cout << "Stock DDSKK oracle 8 readings/order/commits PASS\n";
    }
    if (argc > 3) {
      const auto corpus = std::filesystem::path(argv[3]);
      auto read = [](const auto& path) { std::ifstream file(path, std::ios::binary); return std::string(std::istreambuf_iterator<char>(file), {}); };
      Publish(root / "oracle-before", {corpus / "lf3-stock-shared.jisyo"}, "", rules, 3);
      Publish(root / "oracle-after", {corpus / "lf3-stock-shared.jisyo"}, read(corpus / "lf3-stock-user.jisyo"), rules, 3);
      auto before = OpenPublished(root / "oracle-before"), after = OpenPublished(root / "oracle-after");
      std::ifstream oracle(corpus / "lf3-stock.oracle");
      unsigned phase, rows = 0; std::string key, suffix, list, commit;
      while (oracle >> phase >> key >> suffix >> list >> commit) {
        Check(conversion.Begin(phase ? after : before, Unhex(key), {}, suffix == "-" ? L"" : Unhex(suffix)), "LF3 stock begin");
        while (conversion.Next()) {}
        std::wstring actual = L"/";
        for (const auto& word : conversion.State().candidates) actual += word + L"/";
        Check(actual == Unhex(list), "LF3 stock candidate vector/order");
        Check(conversion.Commit().text == Unhex(commit), "LF3 stock commit including okuri");
        ++rows;
      }
      Check(rows == 18, "LF3 stock corpus count");
      std::cout << "Stock DDSKK LF3 oracle 18 readings/order/commits PASS\n";
    }
    std::cout << "PASS local conversion " << checks << " checks (4 corrupt/source negative controls)\n";
    return 0;
  } catch (const std::exception& error) { std::cerr << "FAIL " << error.what() << '\n'; return 1; }
}
