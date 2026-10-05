// GPL-3.0-or-later
#include "local_conversion.h"
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
    std::cout << "PASS local conversion " << checks << " checks (4 corrupt/source negative controls)\n";
    return 0;
  } catch (const std::exception& error) { std::cerr << "FAIL " << error.what() << '\n'; return 1; }
}
