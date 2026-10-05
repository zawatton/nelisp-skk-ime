// GPL-3.0-or-later.
#include "mmap_index.h"
#include <algorithm>
#include <cstring>
#include <fstream>
#include <limits>
#include <map>
#include <stdexcept>

namespace lf {
namespace {
constexpr uint64_t magic = 0x31495844464c4b53ULL;
using Entries = std::map<std::string, std::pair<std::string, std::string>, std::less<>>;
void Read(const std::filesystem::path& path, bool user, Entries& entries) {
  std::ifstream input(path, std::ios::binary);
  if (!input) throw std::runtime_error("cannot read dictionary");
  std::string line;
  bool first = true;
  while (std::getline(input, line)) {
    if (first && line.starts_with("\xef\xbb\xbf")) line.erase(0, 3);
    first = false;
    line.erase(std::remove(line.begin(), line.end(), '\r'), line.end());
    if (line.empty() || line[0] == ';') continue;
    const auto space = line.find(' ');
    if (space == 0 || space == std::string::npos) continue;
    const auto slash = line.find('/', space);
    if (slash == std::string::npos || line.back() != '/') continue;
    auto& entry = entries[line.substr(0, space)];
    (user ? entry.first : entry.second) = line.substr(slash);
  }
  if (input.bad()) throw std::runtime_error("dictionary read failed");
}
std::vector<std::string> Plain(std::string_view raw) {
  std::vector<std::string> result;
  bool block = false;
  size_t start = 0;
  for (size_t end = 0; end < raw.size(); ++end) {
    if (raw[end] != '/') continue;
    auto field = raw.substr(start, end - start);
    start = end + 1;
    if (field.empty()) continue;
    if (field.front() == '[') { block = true; continue; }
    if (block) { if (field == "]") block = false; continue; }
    if (std::any_of(field.begin(), field.end(), [](unsigned char c) { return c > 32; }))
      result.emplace_back(field);
  }
  return result;
}
}
uint64_t Build(const std::filesystem::path& shared, const std::filesystem::path& user,
               const std::filesystem::path& output) {
  Entries entries;
  Read(shared, false, entries);
  Read(user, true, entries);
  std::vector<Record> records;
  std::string payload;
  const uint64_t beginning = sizeof(Header) + entries.size() * sizeof(Record);
  auto append = [&](const std::string& text) {
    const uint64_t offset = beginning + payload.size();
    payload += text;
    return offset;
  };
  for (const auto& [key, values] : entries) {
    Record r{};
    r.key = append(key); r.key_size = key.size();
    r.user = append(values.first); r.user_size = values.first.size();
    r.shared = append(values.second); r.shared_size = values.second.size();
    records.push_back(r);
  }
  const Header header{magic, 1, records.size(), beginning + payload.size()};
  std::ofstream out(output, std::ios::binary | std::ios::trunc);
  out.write(reinterpret_cast<const char*>(&header), sizeof(header));
  out.write(reinterpret_cast<const char*>(records.data()), records.size() * sizeof(Record));
  out.write(payload.data(), payload.size());
  out.close();
  if (!out) throw std::runtime_error("index write failed");
  return header.bytes;
}
std::vector<std::string> PlainCandidates(Hit hit) {
  auto out = Plain(hit.user);
  for (const auto& candidate : Plain(hit.shared))
    if (std::find(out.begin(), out.end(), candidate) == out.end()) out.push_back(candidate);
  return out;
}
void Index::Close() {
  if (base_) UnmapViewOfFile(base_);
  if (mapping_) CloseHandle(mapping_);
  if (file_ != INVALID_HANDLE_VALUE) CloseHandle(file_);
  base_ = nullptr; mapping_ = nullptr; file_ = INVALID_HANDLE_VALUE;
}
Index::~Index() { Close(); }
Record Index::At(uint64_t index) const {
  Record r;
  std::memcpy(&r, base_ + sizeof(Header) + index * sizeof(Record), sizeof(r));
  return r;
}
std::string_view Index::View(uint64_t offset, uint64_t length) const {
  const uint64_t beginning = sizeof(Header) + header_.count * sizeof(Record);
  if (offset < beginning || offset > header_.bytes || length > header_.bytes - offset)
    throw std::runtime_error("invalid payload bounds");
  return {base_ + offset, static_cast<size_t>(length)};
}
Index::Index(const std::filesystem::path& path) {
  try {
    file_ = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE,
                        nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    LARGE_INTEGER size{};
    if (file_ == INVALID_HANDLE_VALUE || !GetFileSizeEx(file_, &size) || size.QuadPart < sizeof(Header))
      throw std::runtime_error("invalid index file");
    mapping_ = CreateFileMappingW(file_, nullptr, PAGE_READONLY, 0, 0, nullptr);
    if (!mapping_) throw std::runtime_error("mapping failed");
    base_ = static_cast<const char*>(MapViewOfFile(mapping_, FILE_MAP_READ, 0, 0, 0));
    if (!base_) throw std::runtime_error("mapping view failed");
    std::memcpy(&header_, base_, sizeof(header_));
    if (header_.magic != magic || header_.version != 1 || header_.bytes != static_cast<uint64_t>(size.QuadPart) ||
        header_.count > (header_.bytes - sizeof(Header)) / sizeof(Record))
      throw std::runtime_error("invalid index header");
    std::string_view previous;
    for (uint64_t i = 0; i < header_.count; ++i) {
      const auto r = At(i);
      const auto key = View(r.key, r.key_size);
      if (key.empty() || (i && !(previous < key))) throw std::runtime_error("invalid key order");
      (void)View(r.user, r.user_size); (void)View(r.shared, r.shared_size);
      previous = key;
    }
  } catch (...) { Close(); throw; }
}
Hit Index::Lookup(std::string_view key) const {
  uint64_t low = 0, high = header_.count;
  while (low < high) {
    const auto mid = low + (high - low) / 2;
    const auto r = At(mid);
    const auto found = View(r.key, r.key_size);
    if (found < key) low = mid + 1;
    else if (key < found) high = mid;
    else return {View(r.user, r.user_size), View(r.shared, r.shared_size)};
  }
  return {};
}
}
