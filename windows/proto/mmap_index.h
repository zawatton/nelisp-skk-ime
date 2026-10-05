// GPL-3.0-or-later. Measurement prototype; deliberately independent of TSF.
#pragma once
#include <windows.h>
#include <cstdint>
#include <filesystem>
#include <string_view>
#include <string>
#include <vector>

namespace lf {
// File layout is fixed-width little-endian, Windows x64 only in this experiment.
struct Header { uint64_t magic, version, count, bytes; };
struct Record { uint64_t key, key_size, user, user_size, shared, shared_size; };
static_assert(sizeof(Header) == 32 && sizeof(Record) == 48);
struct Hit { std::string_view user, shared; };
uint64_t Build(const std::filesystem::path& shared, const std::filesystem::path& user,
               const std::filesystem::path& output);
// Parses plain fields only. Raw views preserve all annotations/okuri blocks.
// Full DDSKK okuri/numeric semantics are outside this lookup experiment.
std::vector<std::string> PlainCandidates(Hit hit);
class Index {
 public:
  explicit Index(const std::filesystem::path& path);
  ~Index();
  Index(const Index&) = delete;
  Index& operator=(const Index&) = delete;
  Hit Lookup(std::string_view key) const;
  uint64_t count() const { return header_.count; }
  uint64_t bytes() const { return header_.bytes; }
 private:
  Record At(uint64_t index) const;
  std::string_view View(uint64_t offset, uint64_t length) const;
  void Close();
  HANDLE file_ = INVALID_HANDLE_VALUE, mapping_ = nullptr;
  const char* base_ = nullptr;
  Header header_{};
};
}
