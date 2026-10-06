// GPL-3.0-or-later
#pragma once
#include "engine_protocol.h"
#include <windows.h>
#include <array>
#include <filesystem>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

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
// DDSKK's directional annotation equality, distinct from host file merging.
void Union(std::vector<std::wstring>& into, const std::vector<std::wstring>& from);
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
