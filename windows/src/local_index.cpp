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
#include <mutex>
#include <stdexcept>

namespace ddskk::local {
namespace {
constexpr uint64_t kMagic = 0x32495844464c4b53ULL;
constexpr uint64_t kSchema = 4;
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
using Table = DictionaryTable;
Table Parse(std::string_view bytes, uint64_t& bad, bool first_key_wins = false, bool overlay = false) {
  auto parsed = overlay ? ParseOverlay(bytes, first_key_wins) : ParseDictionary(bytes, first_key_wins);
  if (!parsed.valid_utf8) throw std::runtime_error("invalid UTF8");
  bad += parsed.bad_lines;
  return std::move(parsed.entries);
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
Index::Index(const std::filesystem::path& path, std::shared_ptr<const Index> base, bool base_only) : path_(path) {
  try {
    VerifyAccess(path);
    file_ = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ,
                        nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    LARGE_INTEGER size{};
    if (file_ == INVALID_HANDLE_VALUE || !GetFileSizeEx(file_, &size) ||
        size.QuadPart < sizeof(Header) || size.QuadPart > kLimit) throw std::runtime_error("index size");
    mapping_ = CreateFileMappingW(file_, nullptr, PAGE_READONLY, 0, 0, nullptr);
    if (!mapping_) throw std::runtime_error("index mapping");
    base_ = static_cast<const char*>(MapViewOfFile(mapping_, FILE_MAP_READ, 0, 0, 0));
    if (!base_) throw std::runtime_error("index view");
    std::memcpy(&header_, base_, sizeof(header_));
    if (header_.magic != kMagic || header_.schema != kSchema || header_.bytes != static_cast<uint64_t>(size.QuadPart) ||
        header_.count > (header_.bytes - sizeof(Header)) / sizeof(Record) || header_.capabilities > 7)
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
    const auto metadata = View(header_.rules_offset, header_.rules_bytes);
    if (metadata.starts_with("BASE ")) {
      const std::string name(metadata.substr(5));
      if (base_only || name.size() > 100 || !name.starts_with("generation-") || !name.ends_with(".index") ||
          name.find_first_not_of("abcdefghijklmnopqrstuvwxyz0123456789-.") != name.npos)
        throw std::runtime_error("invalid overlay base reference");
      const auto base_path = path.parent_path() / name;
      if (!base || base->Path() != base_path) base = std::make_shared<Index>(base_path, nullptr, true);
      if (base->Base() || base->header().config != header_.config || base->header().capabilities != header_.capabilities)
        throw std::runtime_error("overlay base identity");
      base_index_ = std::move(base);
      // Rules remain owned by the pinned base; overlay swaps do not parse them.
    } else {
      (void)Wide(metadata);
      auto rules = ParseRomajiRules(std::string(metadata));
      if (!rules || rules->empty()) throw std::runtime_error("invalid rule export");
      rules_ = std::move(*rules);
    }
  } catch (...) { Close(); throw; }
}
std::string_view Index::Rules() const {
  return base_index_ ? base_index_->Rules() : View(header_.rules_offset, header_.rules_bytes);
}
std::optional<Record> Index::Find(std::string_view key, char section) const {
  const auto variant = VariantKey(key, section);
  uint64_t low = 0, high = header_.count;
  while (low < high) {
    const auto mid = low + (high - low) / 2; const auto r = At(mid);
    const auto found = View(r.key, r.key_bytes);
    if (found < variant) low = mid + 1;
    else if (variant < found) high = mid;
    else return r;
  }
  return std::nullopt;
}
Entry Index::Lookup(std::wstring_view reading, std::wstring_view okuri) const {
  Entry entry;
  if (!(header_.capabilities & 1) || reading.empty() || Utf16Units(reading) > 256) return entry;
  const auto key = Utf8(reading);
  const char section = okuri.empty() ? 'N' : 'A';
  auto record = Find(key, section);
  if (!record) record = Find(key, 'U');
  std::string_view user_raw, shared_raw;
  if (record) {
    user_raw = View(record->user, record->user_bytes);
    shared_raw = View(record->shared, record->shared_bytes);
  }
  if (base_index_) {
    auto shared = base_index_->Find(key, section);
    if (!shared) shared = base_index_->Find(key, 'U');
    if (shared) shared_raw = base_index_->View(shared->shared, shared->shared_bytes);
    if (!record && !shared) return entry;
  } else if (!record) return entry;
  entry.supported = CertifyEntry(reading, okuri, user_raw, shared_raw, header_.capabilities);
  entry.user = ParsePlain(user_raw, !okuri.empty(), (header_.capabilities & 4) != 0).candidates;
  entry.shared = ParsePlain(shared_raw, !okuri.empty(), (header_.capabilities & 4) != 0).candidates;
  return entry;
}
namespace {
uint64_t Generation() {
  FILETIME clock{}; GetSystemTimePreciseAsFileTime(&clock);
  const uint64_t now = (static_cast<uint64_t>(clock.dwHighDateTime) << 32) | clock.dwLowDateTime;
  static std::atomic<uint64_t> last{0};
  auto previous = last.load(); uint64_t value;
  do { value = std::max(now, previous + 1); } while (!last.compare_exchange_weak(previous, value));
  return value;
}
using Entries = std::map<std::string, std::pair<std::string, std::string>, std::less<>>;
std::string WriteIndex(const std::filesystem::path& directory, const Entries& entries,
                       std::string_view metadata, uint64_t capabilities, uint64_t bad,
                       uint64_t sequence, const Digest& config, bool overlay) {
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
  const auto generation = Generation();
  Header header{kMagic, kSchema, beginning + payload.size() + metadata.size(), records.size(), generation,
                capabilities, bad, sequence, beginning + payload.size(), metadata.size(), config, {}};
  if (header.bytes > kLimit) throw std::runtime_error("generation limit");
  std::string bytes(reinterpret_cast<const char*>(&header), sizeof(header));
  bytes.append(reinterpret_cast<const char*>(records.data()), records.size() * sizeof(Record));
  bytes += payload; bytes += metadata;
  header.checksum = Hash(bytes); std::memcpy(bytes.data(), &header, sizeof(header));
  const auto name = std::string(overlay ? "overlay-" : "generation-") + std::to_string(generation) + "-" + std::to_string(GetCurrentProcessId()) + ".index";
  Write(directory / name, bytes);
  return name;
}
std::string SourceStamp(const std::vector<std::filesystem::path>& files, std::string_view rules, uint64_t capabilities) {
  std::string stamp = std::to_string(capabilities) + std::string(rules);
  for (const auto& path : files) {
    stamp += Utf8(path.wstring()) + ":" + std::to_string(std::filesystem::file_size(path)) + ":" +
        std::to_string(std::filesystem::last_write_time(path).time_since_epoch().count()) + "\n";
  }
  return stamp;
}
struct Publication {
  std::string stamp, name;
  std::shared_ptr<const Index> base;
};
std::mutex publication_mutex;
std::map<std::filesystem::path, Publication> publications;
}
void Publish(const std::filesystem::path& directory, const std::vector<std::filesystem::path>& files,
             std::string_view overlay, std::string_view rules, uint64_t capabilities, uint64_t overlay_sequence) {
  if (files.empty() || files.size() > 64 || rules.empty()) throw std::runtime_error("source plan unavailable");
  std::lock_guard lock(publication_mutex);
  std::filesystem::create_directories(directory);
  Secure(directory);
  const auto flags = PublishedCapabilities(capabilities, overlay);
  const auto stamp = SourceStamp(files, rules, flags);
  auto& publication = publications[directory];
  if (stamp != publication.stamp || !publication.base) {
    uint64_t bad = 0;
    std::vector<DictionaryTable> sources;
    std::string config = std::to_string(flags) + std::string(rules);
    for (const auto& file : files) {
      const auto bytes = Read(file);
      config += Utf8(file.wstring());
      const auto digest = Hash(bytes); config.append(reinterpret_cast<const char*>(digest.data()), digest.size());
      sources.push_back(Parse(bytes, bad, true));
    }
    const auto digest = Hash(config);
    // On host restart reuse the verified base referenced by current.
    if (!publication.base) {
      try {
        auto current = OpenPublished(directory);
        if (current->Base()) { publication.base = current->Base(); publication.name = publication.base->Path().filename().string(); }
      } catch (...) { }
    }
    if (!publication.base || publication.base->header().config != digest) {
      Entries entries;
      for (const auto& [key, value] : CompileSources(sources, flags))
        entries[key].second = value.supported ? SerializeCandidates(value.candidates) : "/(concat \"lfd1-unsupported\")/";
      const auto name = WriteIndex(directory, entries, rules, flags, bad, 0, digest, false);
      auto base = std::make_shared<Index>(directory / name, nullptr, true);
      publication.name = name; publication.base = std::move(base);
    }
    publication.stamp = stamp;
  }
  uint64_t bad = 0;
  Entries entries;
  for (const auto& [key, value] : Parse(overlay, bad, false, true)) entries[key].first = value.raw;
  const auto name = WriteIndex(directory, entries, "BASE " + publication.name, flags, bad,
                              overlay_sequence, publication.base->header().config, true);
  auto verified = std::make_shared<Index>(directory / name, publication.base);
  const auto temp = directory / (name + ".manifest");
  Write(temp, name);
  if (!MoveFileExW(temp.c_str(), (directory / "current").c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
    throw std::runtime_error("manifest publication");
  // Housekeeping runs on the host sweep, outside overlay publication.
}
std::shared_ptr<const Index> OpenPublished(const std::filesystem::path& directory, std::shared_ptr<const Index> previous) {
  VerifyAccess(directory / "current");
  const auto name = Read(directory / "current");
  if (name.size() > 100 || (!name.starts_with("generation-") && !name.starts_with("overlay-")) || !name.ends_with(".index") ||
      name.find_first_not_of("abcdefghijklmnopqrstuvwxyz0123456789-.") != name.npos)
    throw std::runtime_error("invalid generation manifest");
  if (previous && previous->Path() == directory / name) return previous;
  return std::make_shared<Index>(directory / name, previous ? (previous->Base() ? previous->Base() : previous) : nullptr);
}
void Cleanup(const std::filesystem::path& directory, std::shared_ptr<const Index> current) {
  // Readers deny delete sharing. Old files survive exactly while a conversion
  // or client pins them; a later sweep (including host startup) retries deletion.
  current = OpenPublished(directory, std::move(current));
  const auto base = current->Base();
  for (const auto& item : std::filesystem::directory_iterator(directory)) {
    const auto name = item.path().filename().string();
    if ((name.starts_with("generation-") || name.starts_with("overlay-")) &&
        (name.ends_with(".index") || name.ends_with(".manifest")) &&
        item.path() != current->Path() && (!base || item.path() != base->Path())) {
      std::error_code error; std::filesystem::remove(item.path(), error);
    }
  }
}
}
