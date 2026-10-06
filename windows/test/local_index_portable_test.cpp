// GPL-3.0-or-later
#include "local_index.h"

#include <fstream>
#include <iostream>
#include <map>
#include <stdexcept>

using namespace ddskk::local;
namespace {
int checks = 0;
void Check(bool condition, const char* label) {
  if (!condition) throw std::runtime_error(label);
  ++checks;
}
std::wstring DecodeScalarHex(std::string_view hex) {
  std::wstring value;
  if (hex == "-") return value;
  if (hex.size() % 6) throw std::runtime_error("bad scalar hex");
  for (size_t i = 0; i < hex.size(); i += 6) {
    uint32_t scalar = 0;
    for (size_t j = 0; j < 6; ++j) {
      char c = hex[i + j];
      if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) throw std::runtime_error("bad scalar hex digit");
      scalar = (scalar << 4) | (c <= '9' ? c - '0' : c - 'a' + 10);
    }
    if (scalar > 0x10ffff || (scalar >= 0xd800 && scalar <= 0xdfff)) throw std::runtime_error("bad scalar");
    AppendScalar(value, scalar);
  }
  return value;
}
std::string Hex(std::wstring_view value) {
  constexpr char digits[] = "0123456789abcdef";
  std::string out;
  for (size_t i = 0; i < value.size(); ++i) {
    auto scalar = static_cast<uint32_t>(value[i]);
#if WCHAR_MAX <= 0xffff
    if (scalar >= 0xd800 && scalar <= 0xdbff && i + 1 < value.size()) {
      const auto low = static_cast<uint32_t>(value[i + 1]);
      if (low >= 0xdc00 && low <= 0xdfff) {
        scalar = 0x10000 + ((scalar - 0xd800) << 10) + (low - 0xdc00);
        ++i;
      }
    }
#endif
    for (int shift = 20; shift >= 0; shift -= 4) out += digits[(scalar >> shift) & 15];
  }
  return out.empty() ? "-" : out;
}
std::string ReadBytes(const std::string& path) {
  if (path == "-") return {};
  std::ifstream file(path, std::ios::binary);
  if (!file) throw std::runtime_error("cannot read fixture dictionary");
  return std::string((std::istreambuf_iterator<char>(file)), {});
}
using Dictionary = DictionaryTable;
Dictionary ReadDictionary(const std::string& path, bool last_wins) {
  if (path == "-") return {};
  const auto bytes = ReadBytes(path);
  auto parsed = last_wins ? ParseOverlay(bytes, false) : ParseDictionary(bytes, true);
  if (!parsed.valid_utf8) throw std::runtime_error("invalid fixture UTF-8");
  return std::move(parsed.entries);
}
std::string Reason(PlainReason reason) {
  switch (reason) {
    case PlainReason::none: return "plain";
    case PlainReason::invalid_utf8: return "invalid-utf8";
    case PlainReason::expression: return "expression";
    case PlainReason::okuri_block: return "okuri-block";
    case PlainReason::control: return "control";
    case PlainReason::candidate_too_large: return "candidate-too-large";
    case PlainReason::too_many_candidates: return "too-many-candidates";
  }
  return "unknown";
}
std::string Commit(std::wstring_view candidate) {
  return Hex(candidate.substr(0, candidate.find(L';')));
}
void LookupCli(int argc, char** argv) {
  if (argc < 4) throw std::runtime_error("usage: --lookup OVERLAY_OR_DASH SOURCE...");
  const auto overlay_bytes = ReadBytes(argv[2]);
  const auto user = ReadDictionary(argv[2], true);
  std::vector<Dictionary> sources;
  for (int i = 3; i < argc; ++i) sources.push_back(ReadDictionary(argv[i], false));
  const uint64_t capabilities = PublishedCapabilities(3, overlay_bytes);
  const auto shared = CompileSources(sources, capabilities);
  std::string line;
  while (std::getline(std::cin, line)) {
    const auto space = line.find(' ');
    const auto reading = DecodeScalarHex(line.substr(0, space));
    const auto okuri = space == std::string::npos ? std::wstring{} : DecodeScalarHex(line.substr(space + 1));
    const auto key = EncodeUtf8(reading);
    std::string_view user_raw;
    std::vector<std::wstring> personal;
    auto user_found = user.find(VariantKey(key, okuri.empty() ? 'N' : 'A'));
    if (user_found == user.end()) user_found = user.find(VariantKey(key, 'U'));
    if (user_found != user.end()) {
      user_raw = user_found->second.raw;
      const auto parsed = ParsePlain(user_raw, !okuri.empty(), (capabilities & 4) != 0);
      if (!parsed) { std::cout << "NO\t" << Reason(parsed.reason) << "\t-\t-\n"; continue; }
      personal = parsed.candidates;
    }
    PlainReason reason = PlainReason::none;
    auto shared_found = shared.find(VariantKey(key, okuri.empty() ? 'N' : 'A'));
    if (shared_found == shared.end()) shared_found = shared.find(VariantKey(key, 'U'));
    CompiledEntry empty_shared;
    const auto& shared_entry = shared_found == shared.end() ? empty_shared : shared_found->second;
    if (shared_found == shared.end() && personal.empty()) { std::cout << "NO\tmissing\t-\t-\n"; continue; }
    if (!shared_entry.supported) reason = shared_entry.reason;
    const auto shared_bytes = SerializeCandidates(shared_entry.candidates);
    if (reason == PlainReason::none) (void)CertifyEntry(reading, okuri, user_raw, shared_bytes, capabilities, &reason);
    if (reason != PlainReason::none) { std::cout << "NO\t" << Reason(reason) << "\t-\t-\n"; continue; }
    std::vector<std::wstring> all = personal;
    Union(all, shared_entry.candidates);
    std::cout << (all.empty() ? "NO" : "OK") << "\tplain\t";
    if (all.empty()) std::cout << '-';
    else for (size_t i = 0; i < all.size(); ++i) { if (i) std::cout << ','; std::cout << Hex(all[i]); }
    std::cout << '\t' << (all.empty() ? "-" : Hex(DecodeScalarHex(Commit(all.front())) + okuri)) << '\n';
  }
}
void UnitTests() {
  auto plain = ParsePlain("/Ω;literal (注記 #1)/オーム/");
  Check(plain && plain.candidates.size() == 2 && plain.candidates[0] == L"Ω;literal (注記 #1)", "annotation punctuation is plain");
  Check(ParsePlain("/(笑)/").reason == PlainReason::none, "parenthetical word label is plain");
  Check(ParsePlain("/(Ω)/").reason == PlainReason::none, "Greek parenthetical word label is plain");
  Check(ParsePlain("/(text) suffix/").reason == PlainReason::none, "parenthetical suffix is plain");
  Check(ParsePlain("/(concat 1)/").reason == PlainReason::expression, "Lisp word expression rejected");
  Check(ParsePlain("/語;(concat 1)/").reason == PlainReason::expression, "Lisp annotation rejected");
  Check(ParsePlain("/語;*(concat 1)/").reason == PlainReason::expression, "star-prefixed Lisp annotation rejected");
  Check(LiteralProfile().size() == 21 && LiteralProfileAnnotation("(most)"), "pinned literal annotation profile");
  Check(ParsePlain("/語;(most)/").reason == PlainReason::expression &&
        ParsePlain("/語;(most)/", false, true).reason == PlainReason::none,
        "annotation profile applies only to marked context");
  Check(HasLiteralProfileMarker(";; local-literal-profile 1 879b04a00ff3ffa629025a330ece9b65488fc9494e9b883d4dda104f0751edc8\n") &&
        !HasLiteralProfileMarker(";; local-literal-profile 1 forged\n"), "exact profile marker match");
  Check(PublishedCapabilities(7, "") == 3 && PublishedCapabilities(1, ";; local-literal-profile 1 879b04a00ff3ffa629025a330ece9b65488fc9494e9b883d4dda104f0751edc8\n") == 5,
        "literal profile bit requires marker and ordinary capability");
  Check(ParsePlain("/#/").reason == PlainReason::none, "literal hash candidate accepted");
  Check(ParsePlain("/[literal/]/").reason == PlainReason::none, "nasi bracket text is literal");
  Check(LocalReading(L"おーむ") && LocalReading(L"いどう") && LocalReading(L"skk") &&
        !LocalReading(L"123") && !LocalReading(L"#12"), "long vowel, abbreviation, and numeric reading classification");
  Check(LocalReading(L">わたs") && LocalReading(L"カナ") && LocalReading(L"/") && !LocalReading(L"１２"), "plain punctuation and katakana readings");
  Check(IsOkuriKey("かk") && IsOkuriKey(">わたs") && !IsOkuriKey("skk"), "okuri keys require a kana stem");
  auto okuri = ParsePlain("/書/掛/[く/書/掛/]/ignored/", true);
  Check(okuri && okuri.candidates == std::vector<std::wstring>{L"書", L"掛"}, "okuri block and suffix semantics");
  Check(CertifyEntry(L"かk", L"く", "", "/書/掛/[く/書/掛/]/", 3), "certified kana okuri entry");
  std::vector<std::wstring> merged;
  Union(merged, {L"a", L"a"});
  Check(merged.size() == 2, "empty union adopts source duplicates");
  Union(merged, {L"a;note", L"a"});
  Check(merged.size() == 3 && merged[2] == L"a;note", "existing plain does not suppress annotation");
  merged = {L"a;note"}; Union(merged, {L"a", L"a;other"});
  Check(merged.size() == 1, "existing annotation suppresses base candidates");
  std::wstring decoded;
  Check(DecodeUtf8("Ω😀", decoded) && decoded == L"Ω😀", "portable UTF-8 scalar decoding");
  Check(!DecodeUtf8("\xf0\x28\x8c\x28", decoded), "invalid UTF-8 rejected");
  Check(!DecodeUtf8("\xf9\x80\x80\x80", decoded), "invalid UTF-8 lead rejected");
  auto first_wins = ParseDictionary("key /first/\nkey /second/\n", true);
  auto last_wins = ParseDictionary("key /first/\nkey /second/\n", false);
  Check(first_wins.entries.at(VariantKey("key", 'N')).raw == "/first/" &&
        last_wins.entries.at(VariantKey("key", 'N')).raw == "/second/",
        "dictionary duplicate-key policy");
  auto source_a = ParseDictionary("かな /漢字;note/漢字/\nかk /書/[く/書/\n", true).entries;
  auto source_b = ParseDictionary("かな /漢字;later/仮名/\nかk /掛/]/\n", true).entries;
  const auto compiled = CompileSources({source_a, source_b}, 3);
  Check(compiled.at(VariantKey("かな", 'N')).candidates == std::vector<std::wstring>{L"漢字;note", L"漢字", L"仮名"},
        "source merge preserves DDSKK direction and order");
  Check(!compiled.at(VariantKey("かk", 'A')).supported && compiled.at(VariantKey("かk", 'A')).reason == PlainReason::okuri_block,
        "unsupported status remains sticky across files");
  Check(ParsePlain("/(concat \"lfd1-unsupported\")/").reason == PlainReason::expression,
        "publisher fallback sentinel is permanently uncertified");
}
}
int main(int argc, char** argv) {
  try {
    UnitTests();
    if (argc > 1 && std::string_view(argv[1]) == "--lookup") LookupCli(argc, argv);
    else if (argc > 1 && std::string_view(argv[1]) == "--profile") {
      const auto& profile = LiteralProfile();
      for (size_t i = 0; i < profile.size(); ++i) {
        std::wstring decoded;
        if (!DecodeUtf8(profile[i], decoded)) throw std::runtime_error("invalid profile UTF-8");
        if (i) std::cout << ',';
        std::cout << Hex(decoded);
      }
      std::cout << '\n';
    }
    std::cerr << "PASS local-index-portable checks=" << checks << '\n';
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "FAIL local-index-portable checks=" << checks << " error=" << error.what() << '\n';
    return 1;
  }
}
