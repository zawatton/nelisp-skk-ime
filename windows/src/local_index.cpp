// GPL-3.0-or-later
#include "local_index.h"
#include <atomic>
#include "registry_settings.h"
#include <bcrypt.h>
#include <aclapi.h>
#include <sddl.h>
#include <algorithm>
#include <cstring>
#include <fstream>
#include <map>
#include <stdexcept>

namespace ddskk::local {
namespace {
constexpr uint64_t kMagic = 0x32495844464c4b53ULL;
constexpr uint64_t kLimit = 256ULL * 1024 * 1024;
using Digest = std::array<unsigned char, 32>;
std::vector<unsigned char> User() {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) throw std::runtime_error("user token");
  DWORD bytes = 0; GetTokenInformation(token, TokenUser, nullptr, 0, &bytes);
  std::vector<unsigned char> data(bytes);
  bool ok = GetTokenInformation(token, TokenUser, data.data(), bytes, &bytes) != 0;
  CloseHandle(token);
  if (!ok) throw std::runtime_error("user identity");
  return data;
}
void Secure(const std::filesystem::path& directory) {
  if (GetFileAttributesW(directory.c_str()) & FILE_ATTRIBUTE_REPARSE_POINT)
    throw std::runtime_error("reparse generation directory");
  const auto user = User();
  LPWSTR sid = nullptr;
  if (!ConvertSidToStringSidW(reinterpret_cast<const TOKEN_USER*>(user.data())->User.Sid, &sid))
    throw std::runtime_error("user SID");
  const std::wstring descriptor = L"D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;" + std::wstring(sid) + L")";
  LocalFree(sid);
  PSECURITY_DESCRIPTOR security = nullptr;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(descriptor.c_str(), SDDL_REVISION_1, &security, nullptr))
    throw std::runtime_error("generation ACL");
  bool ok = SetFileSecurityW(directory.c_str(), DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION, security) != 0;
  LocalFree(security);
  if (!ok) throw std::runtime_error("protect generation directory");
}
void VerifyAccess(const std::filesystem::path& path) {
  const auto attributes = GetFileAttributesW(path.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_REPARSE_POINT))
    throw std::runtime_error("generation file unavailable/reparse");
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  PSID owner = nullptr; PACL acl = nullptr;
  if (GetNamedSecurityInfoW(path.c_str(), SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
      &owner, nullptr, &acl, nullptr, &descriptor) != ERROR_SUCCESS) throw std::runtime_error("generation access validation");
  const auto user = User();
  const auto sid = reinterpret_cast<const TOKEN_USER*>(user.data())->User.Sid;
  unsigned char system[SECURITY_MAX_SID_SIZE]{}; DWORD bytes = sizeof(system);
  CreateWellKnownSid(WinLocalSystemSid, nullptr, system, &bytes);
  bool ok = owner && EqualSid(owner, sid) && acl;
  if (acl) for (DWORD n = 0; n < acl->AceCount; ++n) {
    void* data = nullptr;
    if (!GetAce(acl, n, &data)) { ok = false; break; }
    const auto ace = static_cast<ACCESS_ALLOWED_ACE*>(data);
    if (ace->Header.AceType == ACCESS_ALLOWED_ACE_TYPE &&
        !EqualSid(&ace->SidStart, sid) && !EqualSid(&ace->SidStart, system)) ok = false;
    if (ace->Header.AceType != ACCESS_ALLOWED_ACE_TYPE && ace->Header.AceType != ACCESS_DENIED_ACE_TYPE) ok = false;
  }
  LocalFree(descriptor);
  if (!ok) throw std::runtime_error("generation permissions");
}
Digest Hash(std::string_view bytes) {
  Digest out{};
  if (BCryptHash(BCRYPT_SHA256_ALG_HANDLE, nullptr, 0,
      reinterpret_cast<PUCHAR>(const_cast<char*>(bytes.data())),
      static_cast<ULONG>(bytes.size()), out.data(), static_cast<ULONG>(out.size())) < 0)
    throw std::runtime_error("SHA256 failed");
  return out;
}
std::string Read(const std::filesystem::path& path) {
  std::ifstream in(path, std::ios::binary | std::ios::ate);
  if (!in || in.tellg() < 0 || in.tellg() > kLimit) throw std::runtime_error("source unavailable/too large");
  std::string value(static_cast<size_t>(in.tellg()), '\0');
  in.seekg(0); in.read(value.data(), value.size());
  if (!in) throw std::runtime_error("source read failed");
  return value;
}
void Write(const std::filesystem::path& path, std::string_view bytes) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW,
                           FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) throw std::runtime_error("generation create failed");
  DWORD written = 0;
  bool ok = WriteFile(file, bytes.data(), static_cast<DWORD>(bytes.size()), &written, nullptr) &&
            written == bytes.size() && FlushFileBuffers(file);
  CloseHandle(file);
  if (!ok) throw std::runtime_error("generation flush failed");
}
std::vector<std::wstring> Plain(std::string_view raw, bool* supported, bool okuri = false) {
  std::vector<std::wstring> result;
  if (raw.size() > 65536) { *supported = false; return result; }
  bool block = false;
  size_t start = 0;
  for (size_t end = 0; end < raw.size(); ++end) {
    if (raw[end] != '/') continue;
    const auto field = raw.substr(start, end - start); start = end + 1;
    if (field.empty()) continue;
    if (field.front() == '[') { block = true; if (!okuri || field.size() == 1) *supported = false; continue; }
    if (block) { if (field == "]") block = false; continue; }
    const auto word = field.substr(0, field.find(';'));
    if (word.empty() || word.front() == '(' || word.find('#') != word.npos ||
        word.find_first_of("\t\n\r") != word.npos) *supported = false;
    auto candidate = Wide(field);
    // Scalar-hex learning must fit the host's existing 8 KiB request.
    // A larger source entry belongs to the provider before conversion.
    if (candidate.size() > 1024) *supported = false;
    result.push_back(std::move(candidate));
    if (result.size() > 1024) { *supported = false; return {}; }
  }
  if (block) *supported = false;
  return result;
}
using Table = std::map<std::string, std::string, std::less<>>;
Table Parse(std::string_view bytes, uint64_t& bad) {
  (void)Wide(bytes); // Reject invalid UTF-8 before parsing any entries.
  if (bytes.starts_with("\xef\xbb\xbf")) bytes.remove_prefix(3);
  Table table;
  while (!bytes.empty()) {
    const auto end = bytes.find('\n');
    auto line = bytes.substr(0, end);
    bytes = end == bytes.npos ? std::string_view{} : bytes.substr(end + 1);
    if (!line.empty() && line.back() == '\r') line.remove_suffix(1);
    if (line.empty() || line.front() == ';') continue;
    const auto space = line.find(' ');
    if (!space || space == line.npos || space + 1 >= line.size() ||
        line[space + 1] != '/' || line.back() != '/') { ++bad; continue; }
    table[std::string(line.substr(0, space))] = std::string(line.substr(space + 1));
  }
  return table;
}
std::string Raw(const std::vector<std::wstring>& fields) {
  std::string out = "/";
  for (const auto& field : fields) { out += Utf8(field); out += '/'; }
  return fields.empty() ? "" : out;
}
}
std::string Utf8(std::wstring_view value) {
  if (value.empty()) return {};
  const int count = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  if (!count) throw std::runtime_error("invalid UTF16");
  std::string out(count, '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()),
                      out.data(), count, nullptr, nullptr);
  return out;
}
std::wstring Wide(std::string_view value) {
  if (value.empty()) return {};
  const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                                       static_cast<int>(value.size()), nullptr, 0);
  if (!count) throw std::runtime_error("invalid UTF8");
  std::wstring out(count, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()),
                      out.data(), count);
  return out;
}
std::string ScalarHex(std::wstring_view value) {
  constexpr char digits[] = "0123456789abcdef";
  std::string out;
  for (size_t n = 0; n < value.size(); ++n) {
    uint32_t code = value[n];
    if (IS_HIGH_SURROGATE(code) && n + 1 < value.size() && IS_LOW_SURROGATE(value[n + 1])) {
      code = 0x10000 + ((code - 0xd800) << 10) + (value[++n] - 0xdc00);
    }
    for (int shift = 20; shift >= 0; shift -= 4) out += digits[(code >> shift) & 15];
  }
  return out.empty() ? "-" : out;
}
std::wstring Unhex(std::string_view value) {
  if (value == "-") return {};
  if (value.size() % 6) throw std::runtime_error("invalid scalar hex");
  std::wstring out;
  for (size_t n = 0; n < value.size(); n += 6) {
    uint32_t code = 0;
    for (size_t i = 0; i < 6; ++i) {
      char c = value[n + i];
      if (!(c >= '0' && c <= '9') && !(c >= 'a' && c <= 'f')) throw std::runtime_error("invalid hex digit");
      code = (code << 4) | (c <= '9' ? c - '0' : c - 'a' + 10);
    }
    if (code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff)) throw std::runtime_error("invalid scalar");
    if (code >= 0x10000) { code -= 0x10000; out += static_cast<wchar_t>(0xd800 + (code >> 10)); out += static_cast<wchar_t>(0xdc00 + (code & 1023)); }
    else out += static_cast<wchar_t>(code);
  }
  return out;
}
std::filesystem::path Directory() {
  wchar_t root[32768]{};
  DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", root, _countof(root));
  if (!n || n >= _countof(root)) throw std::runtime_error("LOCALAPPDATA unavailable");
  const auto digest = Hash(Utf8(NativeImeRegistryKey()));
  std::string id;
  constexpr char digits[] = "0123456789abcdef";
  for (auto c : digest) { id += digits[c >> 4]; id += digits[c & 15]; }
  auto path = (std::filesystem::path(root) / L"DDSKK" / L"local-v2" / id).lexically_normal().wstring();
  // Spools can exceed MAX_PATH in deep private artifact directories.
  // Use the Win32 extended path syntax for every worker-owned file.
  if (!path.starts_with(L"\\\\?\\")) {
    if (path.starts_with(L"\\\\")) path = L"\\\\?\\UNC\\" + path.substr(2);
    else path = L"\\\\?\\" + path;
  }
  return std::filesystem::path(path);
}
void Union(std::vector<std::wstring>& into, const std::vector<std::wstring>& from) {
  for (const auto& y : from) {
    const bool found = std::any_of(into.begin(), into.end(), [&](const auto& x) {
      const auto semicolon = x.find(L';');
      return x == y || (semicolon != x.npos && x.substr(0, semicolon) == y.substr(0, y.find(L';')));
    });
    if (!found) into.push_back(y);
  }
}
void Index::Close() {
  if (base_) UnmapViewOfFile(base_);
  if (mapping_) CloseHandle(mapping_);
  if (file_ != INVALID_HANDLE_VALUE) CloseHandle(file_);
  base_ = nullptr; mapping_ = nullptr; file_ = INVALID_HANDLE_VALUE;
}
Index::~Index() { Close(); }
Record Index::At(uint64_t n) const {
  Record r{}; std::memcpy(&r, base_ + sizeof(Header) + n * sizeof(Record), sizeof(r)); return r;
}
std::string_view Index::View(uint64_t offset, uint64_t bytes) const {
  const auto begin = sizeof(Header) + header_.count * sizeof(Record);
  if (offset < begin || offset > header_.bytes || bytes > header_.bytes - offset)
    throw std::runtime_error("payload bounds");
  return {base_ + offset, static_cast<size_t>(bytes)};
}
Index::Index(const std::filesystem::path& path) {
  try {
    VerifyAccess(path);
    file_ = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE,
                        nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    LARGE_INTEGER size{};
    if (file_ == INVALID_HANDLE_VALUE || !GetFileSizeEx(file_, &size) ||
        size.QuadPart < sizeof(Header) || size.QuadPart > kLimit) throw std::runtime_error("index size");
    mapping_ = CreateFileMappingW(file_, nullptr, PAGE_READONLY, 0, 0, nullptr);
    if (!mapping_) throw std::runtime_error("index mapping");
    base_ = static_cast<const char*>(MapViewOfFile(mapping_, FILE_MAP_READ, 0, 0, 0));
    if (!base_) throw std::runtime_error("index view");
    std::memcpy(&header_, base_, sizeof(header_));
    if (header_.magic != kMagic || header_.schema != 2 || header_.bytes != static_cast<uint64_t>(size.QuadPart) ||
        header_.count > (header_.bytes - sizeof(Header)) / sizeof(Record) || header_.capabilities > 3)
      throw std::runtime_error("index header");
    Header copy = header_; copy.checksum = {};
    std::string checked(base_, static_cast<size_t>(header_.bytes));
    std::memcpy(checked.data(), &copy, sizeof(copy));
    if (Hash(checked) != header_.checksum) throw std::runtime_error("index checksum");
    uint64_t next = sizeof(Header) + header_.count * sizeof(Record);
    std::string_view previous;
    for (uint64_t n = 0; n < header_.count; ++n) {
      const auto r = At(n);
      if (r.key != next || r.user != r.key + r.key_bytes || r.shared != r.user + r.user_bytes)
        throw std::runtime_error("overlapping index sections");
      const auto key = View(r.key, r.key_bytes);
      if (key.empty() || (n && !(previous < key))) throw std::runtime_error("index key order");
      (void)Wide(key); (void)Wide(View(r.user, r.user_bytes)); (void)Wide(View(r.shared, r.shared_bytes));
      next = r.shared + r.shared_bytes; previous = key;
    }
    if (header_.rules_offset != next || header_.rules_bytes != header_.bytes - next)
      throw std::runtime_error("index rules bounds");
    (void)Wide(Rules());
    auto rules = ParseRomajiRules(std::string(Rules()));
    if (!rules || rules->empty()) throw std::runtime_error("invalid rule export");
    rules_ = std::move(*rules);
  } catch (...) { Close(); throw; }
}
std::string_view Index::Rules() const { return View(header_.rules_offset, header_.rules_bytes); }
Entry Index::Lookup(std::wstring_view reading, std::wstring_view okuri) const {
  Entry entry;
  if (!(header_.capabilities & 1) || reading.empty() || reading.size() > 256) return entry;
  // Completed kana and certified stem+okuri are local. Abbrev, numeric and
  // unsupported commands choose the provider before constructing candidates.
  auto stem = reading;
  if (!okuri.empty()) {
    if (okuri.size() > 32) return entry;
    if (!(header_.capabilities & 2) || reading.back() < L'a' || reading.back() > L'z') return entry;
    stem.remove_suffix(1);
    for (auto c : okuri) if ((c < 0x3041 || c > 0x3096) && c != L'ー') return entry;
  }
  for (auto c : stem) if ((c < 0x3041 || c > 0x3096) && c != L'ー') return entry;
  const auto key = Utf8(reading);
  uint64_t low = 0, high = header_.count;
  while (low < high) {
    const auto mid = low + (high - low) / 2; const auto r = At(mid);
    const auto found = View(r.key, r.key_bytes);
    if (found < key) low = mid + 1;
    else if (key < found) high = mid;
    else {
      entry.supported = true;
      entry.user = Plain(View(r.user, r.user_bytes), &entry.supported, !okuri.empty());
      entry.shared = Plain(View(r.shared, r.shared_bytes), &entry.supported, !okuri.empty());
      for (const auto* tier : {&entry.user, &entry.shared})
        for (const auto& word : *tier)
          if ((word.size() + reading.size() + okuri.size()) * 6 + 128 > 8192) entry.supported = false;
      return entry;
    }
  }
  // A miss is routed to the engine's registration editor in this slice.
  return entry;
}
void Publish(const std::filesystem::path& directory, const std::vector<std::filesystem::path>& files,
             std::string_view overlay, std::string_view rules, uint64_t capabilities, uint64_t overlay_sequence) {
  if (files.empty() || files.size() > 64 || rules.empty()) throw std::runtime_error("source plan unavailable");
  std::filesystem::create_directories(directory);
  Secure(directory);
  uint64_t bad = 0;
  auto user = Parse(overlay, bad);
  std::map<std::string, std::vector<std::wstring>, std::less<>> merged;
  std::map<std::string, std::string, std::less<>> unsupported;
  std::string config = std::to_string(capabilities) + std::string(rules);
  for (const auto& file : files) {
    const auto bytes = Read(file);
    config += Utf8(file.wstring());
    const auto digest = Hash(bytes); config.append(reinterpret_cast<const char*>(digest.data()), digest.size());
    const auto source = Parse(bytes, bad);
    for (const auto& [key, raw] : source) {
      bool supported = true;
      const auto values = Plain(raw, &supported, (capabilities & 2) && !key.empty() && key.back() >= 'a' && key.back() <= 'z');
      auto& into = merged[key];
      for (const auto& candidate : values) {
        const auto word = candidate.substr(0, candidate.find(L';'));
        if (std::none_of(into.begin(), into.end(), [&](const auto& x) { return x.substr(0, x.find(L';')) == word; }))
          into.push_back(candidate);
      }
      // Preserve uncertified expressions/options as opaque source bytes.
      // Their presence selects the engine before conversion starts.
      if (!supported) unsupported[key] += raw;
    }
  }
  std::map<std::string, std::pair<std::string, std::string>, std::less<>> entries;
  for (const auto& [key, raw] : user) entries[key].first = raw;
  for (const auto& [key, values] : merged)
    entries[key].second = unsupported.contains(key) ? unsupported[key] : Raw(values);
  const uint64_t beginning = sizeof(Header) + entries.size() * sizeof(Record);
  std::vector<Record> records;
  std::string payload;
  const auto append = [&](const std::string& value) { const auto n = beginning + payload.size(); payload += value; return n; };
  for (const auto& [key, value] : entries) {
    Record r{};
    r.key = append(key); r.key_bytes = key.size();
    r.user = append(value.first); r.user_bytes = value.first.size();
    r.shared = append(value.second); r.shared_bytes = value.second.size();
    records.push_back(r);
  }
  FILETIME clock{}; GetSystemTimePreciseAsFileTime(&clock);
  const uint64_t now = (static_cast<uint64_t>(clock.dwHighDateTime) << 32) | clock.dwLowDateTime;
  static std::atomic<uint64_t> last_generation{0};
  auto previous_generation = last_generation.load();
  uint64_t generation;
  do { generation = std::max(now, previous_generation + 1); }
  while (!last_generation.compare_exchange_weak(previous_generation, generation));
  Header header{kMagic, 2, beginning + payload.size() + rules.size(), records.size(), generation,
                capabilities, bad, overlay_sequence, beginning + payload.size(), rules.size(), Hash(config), {}};
  if (header.bytes > kLimit) throw std::runtime_error("generation limit");
  std::string bytes(reinterpret_cast<const char*>(&header), sizeof(header));
  bytes.append(reinterpret_cast<const char*>(records.data()), records.size() * sizeof(Record));
  bytes += payload; bytes += rules;
  header.checksum = Hash(bytes); std::memcpy(bytes.data(), &header, sizeof(header));
  const auto name = "generation-" + std::to_string(generation) + "-" + std::to_string(GetCurrentProcessId()) + ".index";
  const auto path = directory / name;
  Write(path, bytes);
  Index verified(path);
  const auto temp = directory / (name + ".manifest");
  Write(temp, name);
  if (!MoveFileExW(temp.c_str(), (directory / "current").c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
    throw std::runtime_error("manifest publication");
  // Delete sharing keeps pinned mappings alive. Retain the current and two
  // newest older files; failed/incomplete files never become publications.
  std::vector<std::filesystem::path> generations;
  for (const auto& item : std::filesystem::directory_iterator(directory))
    if (item.path().extension() == ".index") generations.push_back(item.path());
  std::sort(generations.rbegin(), generations.rend());
  for (size_t i = 3; i < generations.size(); ++i) {
    if (generations[i] == path) continue;
    std::error_code error; std::filesystem::remove(generations[i], error);
  }
}
std::shared_ptr<const Index> OpenPublished(const std::filesystem::path& directory) {
  VerifyAccess(directory / "current");
  const auto name = Read(directory / "current");
  if (name.size() > 100 || !name.starts_with("generation-") || !name.ends_with(".index") ||
      name.find_first_not_of("abcdefghijklmnopqrstuvwxyz0123456789-.") != name.npos)
    throw std::runtime_error("invalid generation manifest");
  return std::make_shared<Index>(directory / name);
}
}
