// GPL-3.0-or-later
#pragma once
#include "engine_protocol.h"
#include <algorithm>
#include <array>
#include <climits>
#include <cstdint>
#include <iterator>
#include <map>
#include <string>
#include <string_view>
#include <vector>

namespace ddskk::local {
// These helpers are deliberately platform independent: production uses them
// while decoding the published index, and Linux tests exercise the same code.
enum class PlainReason { none, invalid_utf8, expression, okuri_block, control,
                         candidate_too_large, too_many_candidates };
struct PlainResult {
  std::vector<std::wstring> candidates;
  PlainReason reason = PlainReason::none;
  explicit operator bool() const { return reason == PlainReason::none; }
};

inline bool DecodeScalar(std::string_view bytes, size_t& at, uint32_t& scalar) {
  const auto first = static_cast<unsigned char>(bytes[at++]);
  if (first < 0x80) { scalar = first; return true; }
  if (first > 0xf4) return false;
  unsigned need = first >= 0xf0 ? 3 : first >= 0xe0 ? 2 : first >= 0xc2 ? 1 : 0;
  if (!need) return false;
  scalar = first & (need == 3 ? 0x07 : need == 2 ? 0x0f : 0x1f);
  if (at + need > bytes.size()) return false;
  for (unsigned i = 0; i < need; ++i) {
    const auto next = static_cast<unsigned char>(bytes[at++]);
    if ((next & 0xc0) != 0x80) return false;
    scalar = (scalar << 6) | (next & 0x3f);
  }
  return !((need == 1 && scalar < 0x80) || (need == 2 && scalar < 0x800) ||
           (need == 3 && scalar < 0x10000) || scalar > 0x10ffff ||
           (scalar >= 0xd800 && scalar <= 0xdfff));
}
inline void AppendScalar(std::wstring& out, uint32_t scalar) {
#if WCHAR_MAX <= 0xffff
  if (scalar >= 0x10000) {
    scalar -= 0x10000;
    out.push_back(static_cast<wchar_t>(0xd800 + (scalar >> 10)));
    out.push_back(static_cast<wchar_t>(0xdc00 + (scalar & 0x3ff)));
  } else out.push_back(static_cast<wchar_t>(scalar));
#else
  out.push_back(static_cast<wchar_t>(scalar));
#endif
}
inline bool DecodeUtf8(std::string_view bytes, std::wstring& out) {
  size_t at = 0;
  while (at < bytes.size()) {
    uint32_t scalar = 0;
    if (!DecodeScalar(bytes, at, scalar)) return false;
    AppendScalar(out, scalar);
  }
  return true;
}
inline void AppendUtf8(std::string& out, uint32_t scalar) {
  if (scalar < 0x80) out.push_back(static_cast<char>(scalar));
  else if (scalar < 0x800) {
    out.push_back(static_cast<char>(0xc0 | (scalar >> 6)));
    out.push_back(static_cast<char>(0x80 | (scalar & 0x3f)));
  } else if (scalar < 0x10000) {
    out.push_back(static_cast<char>(0xe0 | (scalar >> 12)));
    out.push_back(static_cast<char>(0x80 | ((scalar >> 6) & 0x3f)));
    out.push_back(static_cast<char>(0x80 | (scalar & 0x3f)));
  } else {
    out.push_back(static_cast<char>(0xf0 | (scalar >> 18)));
    out.push_back(static_cast<char>(0x80 | ((scalar >> 12) & 0x3f)));
    out.push_back(static_cast<char>(0x80 | ((scalar >> 6) & 0x3f)));
    out.push_back(static_cast<char>(0x80 | (scalar & 0x3f)));
  }
}
inline std::string EncodeUtf8(std::wstring_view value) {
  std::string out;
  for (size_t i = 0; i < value.size(); ++i) {
    uint32_t scalar = static_cast<uint32_t>(value[i]);
#if WCHAR_MAX <= 0xffff
    if (scalar >= 0xd800 && scalar <= 0xdbff && i + 1 < value.size()) {
      const auto low = static_cast<uint32_t>(value[i + 1]);
      if (low >= 0xdc00 && low <= 0xdfff) {
        scalar = 0x10000 + ((scalar - 0xd800) << 10) + (low - 0xdc00);
        ++i;
      }
    }
#endif
    AppendUtf8(out, scalar);
  }
  return out;
}
inline size_t Utf16Units(std::wstring_view value);
inline bool LispLikeExpression(std::string_view field) {
  // SKK evaluates a candidate/annotation as Lisp only when its entire
  // semicolon-separated component is a complete parenthesized ASCII form.
  // Japanese parenthetical labels such as (笑) remain literal.
  if (field.size() < 3 || field.front() != '(' || field.back() != ')') return false;
  const auto second = static_cast<unsigned char>(field[1]);
  return second < 0x80;
}
inline const std::array<std::string_view, 21>& LiteralProfile() {
  static constexpr std::array<std::string_view, 21> profile = {
      "(-肉)", "(<galley)", "(<蘭語)", "(=すすg)「汚名を-ぐ」(cf.「雪辱」)", "([中国史])",
      "([二十四節気]2.19頃)", "([二十四節気]4.5頃)", "([二十四節気]9.8頃)", "([八卦]陽陰陽)",
      "([日本史]=年序)", "([部首]=貝偏)", "(attract)", "(difficult)", "(enlarge)", "(feel)",
      "(generic)", "(most)", "(order)", "(send)", "(sorrow)", "(worry)"};
  return profile;
}
inline bool LiteralProfileAnnotation(std::string_view value) {
  const auto& profile = LiteralProfile();
  return std::find(profile.begin(), profile.end(), value) != profile.end();
}
inline PlainResult ParsePlain(std::string_view raw, bool okuri = false, bool literal_profile = false) {
  PlainResult result;
  if (raw.size() > 65536) { result.reason = PlainReason::candidate_too_large; return result; }
  bool block = false;
  bool saw_block = false;
  size_t start = 0;
  for (size_t end = 0; end < raw.size(); ++end) {
    if (raw[end] != '/') continue;
    auto field = raw.substr(start, end - start); start = end + 1;
    if (field.empty()) continue;
    if (saw_block) {
      if (block && field == "]") block = false;
      continue;
    }
    if (okuri && field.front() == '[') {
      block = true;
      saw_block = true;
      if (field.size() == 1) result.reason = PlainReason::okuri_block;
      continue;
    }
    if (block) { if (field == "]") block = false; continue; }
    size_t part = 0;
    const auto word_end = field.find(';');
    while (part <= field.size()) {
      const auto semicolon = field.find(';', part);
      auto segment = field.substr(part, semicolon == field.npos ? field.size() - part : semicolon - part);
      const bool annotation = word_end != field.npos && part > word_end;
      if (part == word_end + 1 && annotation && !segment.empty() && segment.front() == '*')
        segment.remove_prefix(1);
      if (LispLikeExpression(segment) && !(literal_profile && annotation && LiteralProfileAnnotation(segment)))
        result.reason = PlainReason::expression;
      if (semicolon == field.npos) break;
      part = semicolon + 1;
    }
    if (field.empty() || field.find_first_of("\t\n\r") != field.npos) result.reason = PlainReason::control;
    std::wstring candidate;
    if (!DecodeUtf8(field, candidate)) { result.reason = PlainReason::invalid_utf8; continue; }
    if (Utf16Units(candidate) > 1024) result.reason = PlainReason::candidate_too_large;
    result.candidates.push_back(std::move(candidate));
    if (result.candidates.size() > 1024) { result.reason = PlainReason::too_many_candidates; result.candidates.clear(); return result; }
  }
  if (block) result.reason = PlainReason::okuri_block;
  return result;
}
inline bool LocalReading(std::wstring_view reading) {
  if (reading.empty() || Utf16Units(reading) > 256) return false;
  for (auto c : reading) {
    const auto scalar = static_cast<uint32_t>(c);
    if (c == L'#' || (c >= L'0' && c <= L'9') ||
        (c >= 0x0660 && c <= 0x0669) || (c >= 0x06f0 && c <= 0x06f9) ||
        (c >= 0xff10 && c <= 0xff19) || scalar <= 0x20 || (scalar >= 0x7f && scalar <= 0x9f) ||
        (scalar >= 0x2000 && scalar <= 0x200a) || scalar == 0x2028 || scalar == 0x2029 ||
        scalar == 0x202f || scalar == 0x205f || scalar == 0x3000) return false;
  }
  return true;
}
inline bool KanaReading(std::wstring_view reading) {
  if (reading.empty() || Utf16Units(reading) > 256) return false;
  if (reading.front() == L'>' || reading.front() == L'<') reading.remove_prefix(1);
  if (reading.empty()) return false;
  for (auto c : reading) if ((c < 0x3041 || c > 0x3096) && c != L'ー') return false;
  return true;
}
inline size_t Utf16Units(std::wstring_view value) {
#if WCHAR_MAX <= 0xffff
  return value.size();
#else
  size_t count = 0;
  for (auto c : value) count += static_cast<uint32_t>(c) > 0xffff ? 2 : 1;
  return count;
#endif
}
inline bool IsOkuriKey(std::string_view key) {
  std::wstring decoded;
  if (!DecodeUtf8(key, decoded) || decoded.size() < 2 || decoded.back() < L'a' || decoded.back() > L'z') return false;
  decoded.pop_back();
  if (KanaReading(decoded)) return true;
  const bool has_non_ascii = std::any_of(decoded.begin(), decoded.end(), [](wchar_t c) { return static_cast<uint32_t>(c) > 0x7f; });
  return has_non_ascii && LocalReading(decoded);
}
inline bool HasLiteralProfileMarker(std::string_view bytes) {
  constexpr std::string_view marker =
      ";; local-literal-profile 1 879b04a00ff3ffa629025a330ece9b65488fc9494e9b883d4dda104f0751edc8";
  while (!bytes.empty()) {
    const auto end = bytes.find('\n');
    auto line = bytes.substr(0, end);
    if (!line.empty() && line.back() == '\r') line.remove_suffix(1);
    if (line == marker) return true;
    bytes = end == bytes.npos ? std::string_view{} : bytes.substr(end + 1);
  }
  return false;
}
inline uint64_t PublishedCapabilities(uint64_t requested, std::string_view overlay) {
  uint64_t published = requested & 3;
  if ((published & 1) && HasLiteralProfileMarker(overlay)) published |= 4;
  return published;
}
inline bool CertifyEntry(std::wstring_view reading, std::wstring_view okuri,
                         std::string_view user_raw, std::string_view shared_raw,
                         uint64_t capabilities, PlainReason* reason = nullptr) {
  auto fail = [&](PlainReason why) { if (reason) *reason = why; return false; };
  if (!(capabilities & 1) || reading.empty() || Utf16Units(reading) > 256) return fail(PlainReason::control);
  auto stem = reading;
  if (!okuri.empty()) {
    if (Utf16Units(okuri) > 32 || !(capabilities & 2) || reading.back() < L'a' || reading.back() > L'z')
      return fail(PlainReason::control);
    stem.remove_suffix(1);
    if (!LocalReading(stem)) return fail(PlainReason::control);
    for (auto c : okuri)
      if ((c < 0x3041 || c > 0x3096) && c != L'ー') return fail(PlainReason::control);
  }
  if (!LocalReading(stem)) return fail(PlainReason::control);
  auto user = ParsePlain(user_raw, !okuri.empty(), (capabilities & 4) != 0);
  if (!user) return fail(user.reason);
  auto shared = ParsePlain(shared_raw, !okuri.empty(), (capabilities & 4) != 0);
  if (!shared) return fail(shared.reason);
  for (const auto* tier : {&user.candidates, &shared.candidates})
    for (const auto& candidate : *tier)
      if ((Utf16Units(candidate) + Utf16Units(reading) + Utf16Units(okuri)) * 6 + 128 > 8192)
        return fail(PlainReason::candidate_too_large);
  if (reason) *reason = PlainReason::none;
  return true;
}
struct DictionaryValue { std::string raw; char section = 'U'; };
using DictionaryTable = std::map<std::string, DictionaryValue, std::less<>>;
inline std::string VariantKey(std::string_view key, char section) {
  std::string out(key); out.push_back('\x1f'); out.push_back(section); return out;
}
inline std::string_view BaseKey(std::string_view key) {
  return key.size() >= 2 && key[key.size() - 2] == '\x1f' ? key.substr(0, key.size() - 2) : key;
}
inline char KeySection(std::string_view key) {
  return key.size() >= 2 && key[key.size() - 2] == '\x1f' ? key.back() : 'U';
}
inline char EffectiveSection(std::string_view key, std::string_view, char section) {
  if (section == 'A' || section == 'N') return section;
  return IsOkuriKey(key) ? 'A' : 'N';
}
struct DictionaryParse { DictionaryTable entries; uint64_t bad_lines = 0; bool valid_utf8 = true; };
inline DictionaryParse ParseDictionary(std::string_view bytes, bool first_key_wins) {
  DictionaryParse out;
  std::wstring validation;
  out.valid_utf8 = DecodeUtf8(bytes, validation);
  if (!out.valid_utf8) return out;
  if (bytes.starts_with("\xef\xbb\xbf")) bytes.remove_prefix(3);
  char section = 'U';
  while (!bytes.empty()) {
    const auto end = bytes.find('\n');
    auto line = bytes.substr(0, end);
    bytes = end == bytes.npos ? std::string_view{} : bytes.substr(end + 1);
    if (!line.empty() && line.back() == '\r') line.remove_suffix(1);
    if (line.empty()) continue;
    if (line.front() == ';') {
      if (line == ";; okuri-ari entries.") section = 'A';
      else if (line == ";; okuri-nasi entries.") section = 'N';
      continue;
    }
    const auto space = line.find(' ');
    if (space == 0 || space == line.npos || space + 1 >= line.size() ||
        line[space + 1] != '/' || line.back() != '/') { ++out.bad_lines; continue; }
    const auto base_key = line.substr(0, space);
    auto raw = std::string(line.substr(space + 1));
    const auto effective_section = EffectiveSection(base_key, raw, section);
    auto key = VariantKey(base_key, effective_section);
    DictionaryValue value{std::move(raw), effective_section};
    if (first_key_wins) out.entries.try_emplace(std::move(key), std::move(value));
    else out.entries[std::move(key)] = std::move(value);
  }
  return out;
}
inline DictionaryParse ParseOverlay(std::string_view bytes, bool first_key_wins = false) {
  auto parsed = ParseDictionary(bytes, first_key_wins);
  if (!parsed.valid_utf8) return parsed;
  DictionaryTable normalized;
  for (auto& [tagged_key, value] : parsed.entries) {
    const auto key = BaseKey(tagged_key);
    if (value.section == 'A' && !IsOkuriKey(key) && value.raw.find("/[") == value.raw.npos) value.section = 'N';
    auto normalized_key = VariantKey(key, value.section);
    if (first_key_wins) normalized.try_emplace(std::move(normalized_key), std::move(value));
    else normalized[std::move(normalized_key)] = std::move(value);
  }
  parsed.entries = std::move(normalized);
  return parsed;
}
inline void Union(std::vector<std::wstring>& into, const std::vector<std::wstring>& from) {
  if (into.empty()) { into = from; return; }
  for (const auto& y : from) {
    const bool found = std::any_of(into.begin(), into.end(), [&](const auto& x) {
      const auto semicolon = x.find(L';');
      return x == y || (semicolon != x.npos && x.substr(0, semicolon) == y.substr(0, y.find(L';')));
    });
    if (!found) into.push_back(y);
  }
}
struct CompiledEntry {
  std::vector<std::wstring> candidates;
  bool supported = true;
  PlainReason reason = PlainReason::none;
};
using CompiledTable = std::map<std::string, CompiledEntry, std::less<>>;
inline CompiledTable CompileSources(const std::vector<DictionaryTable>& sources, uint64_t capabilities) {
  CompiledTable merged;
  for (const auto& source : sources) {
    for (const auto& [tagged_key, source_value] : source) {
      const auto key = BaseKey(tagged_key);
      const char section = EffectiveSection(key, source_value.raw, source_value.section);
      auto& into = merged[VariantKey(key, section)];
      const bool okuri_key = section == 'A';
      auto parsed = ParsePlain(source_value.raw, okuri_key, (capabilities & 4) != 0);
      if (okuri_key && !(capabilities & 2)) {
        into.supported = false;
        if (into.reason == PlainReason::none) into.reason = PlainReason::okuri_block;
      }
      if (!parsed) {
        into.supported = false;
        if (into.reason == PlainReason::none) into.reason = parsed.reason;
      }
      Union(into.candidates, parsed.candidates);
    }
  }
  return merged;
}
inline std::string SerializeCandidates(const std::vector<std::wstring>& candidates) {
  if (candidates.empty()) return {};
  std::string raw = "/";
  for (const auto& candidate : candidates) { raw += EncodeUtf8(candidate); raw += '/'; }
  return raw;
}
}

#ifdef _WIN32
#include <windows.h>
#include <array>
#include <filesystem>
#include <memory>

namespace ddskk::local {

// All offsets are little endian byte offsets; no process pointers are stored.
struct Header {
  uint64_t magic, schema, bytes, count, generation, capabilities, bad_lines, overlay_sequence;
  uint64_t rules_offset, rules_bytes;
  std::array<unsigned char, 32> config, checksum;
};
struct Record { uint64_t key, key_bytes, user, user_bytes, shared, shared_bytes; };
static_assert(sizeof(Header) == 144 && sizeof(Record) == 48);
struct Entry { std::vector<std::wstring> user, shared; bool supported = false; };
std::string Utf8(std::wstring_view value);
std::wstring Wide(std::string_view value);
std::string ScalarHex(std::wstring_view value);
std::wstring Unhex(std::string_view value);
std::filesystem::path Directory();
class Index {
 public:
  explicit Index(const std::filesystem::path& path);
  ~Index();
  Index(const Index&) = delete;
  Index& operator=(const Index&) = delete;
  Entry Lookup(std::wstring_view reading, std::wstring_view okuri = {}) const;
  std::string_view Rules() const;
  const std::vector<RomajiRule>& ParsedRules() const { return rules_; }
  const Header& header() const { return header_; }
 private:
  std::string_view View(uint64_t offset, uint64_t bytes) const;
  Record At(uint64_t n) const;
  void Close();
  HANDLE file_ = INVALID_HANDLE_VALUE, mapping_ = nullptr;
  const char* base_ = nullptr;
  Header header_{};
  std::vector<RomajiRule> rules_;
};
// Host only. Parse/flush/validate a new file, then replace the manifest.
// A failed build leaves the last verified publication intact.
void Publish(const std::filesystem::path& directory,
             const std::vector<std::filesystem::path>& files,
             std::string_view overlay, std::string_view rules,
             uint64_t capabilities, uint64_t overlay_sequence = 0);
std::shared_ptr<const Index> OpenPublished(const std::filesystem::path& directory);
}
#endif
