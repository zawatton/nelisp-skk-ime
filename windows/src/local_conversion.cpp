// GPL-3.0-or-later
#include "local_conversion.h"
#include "engine_client.h"
#include <bcrypt.h>
#include <algorithm>
#include <fstream>
#include <sstream>
#include <cstdio>

namespace ddskk::local {
namespace {
constexpr size_t kQueueLimit = 256;
struct Claim {
  HANDLE handle;
  ~Claim() { if (handle != INVALID_HANDLE_VALUE) CloseHandle(handle); }
};
std::string Identity() {
  unsigned char random[16]{};
  if (BCryptGenRandom(nullptr, random, sizeof(random), BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0)
    throw std::runtime_error("learning identity failed");
  constexpr char digits[] = "0123456789abcdef";
  std::string out;
  for (auto c : random) { out += digits[c >> 4]; out += digits[c & 15]; }
  return out;
}
void Spool(const std::filesystem::path& path, const std::deque<Learning>& queue) {
  std::string bytes;
  for (const auto& item : queue)
    bytes += item.id + " " + ScalarHex(item.key) + " " + ScalarHex(item.candidate) + " " + std::to_string(item.sequence) + "\n";
  const auto temp = path.wstring() + L".tmp";
  HANDLE file = CreateFileW(temp.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) throw std::runtime_error("learning spool create");
  DWORD n = 0;
  bool ok = WriteFile(file, bytes.data(), static_cast<DWORD>(bytes.size()), &n, nullptr) && n == bytes.size() && FlushFileBuffers(file);
  CloseHandle(file);
  if (!ok || !MoveFileExW(temp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
    throw std::runtime_error("learning spool publication");
}
}
void Store::Start() {
  if (worker_.joinable()) return;
  client_ = Identity(); stopping_ = false;
  worker_ = std::thread([this] { Run(); });
}
void Store::Stop() {
  { std::lock_guard lock(mutex_); stopping_ = true; }
  wake_.notify_one();
  if (worker_.joinable()) worker_.join();
}
size_t Store::Unsaved() const {
  std::lock_guard lock(mutex_);
  return static_cast<size_t>(std::count_if(queue_.begin(), queue_.end(), [](const auto& item) { return item.sequence == 0; }));
}
bool Store::Available() const {
  std::lock_guard lock(mutex_);
  return queue_.size() < kQueueLimit;
}
std::vector<std::wstring> Store::Pending(std::wstring_view key) const {
  std::lock_guard lock(mutex_);
  std::vector<std::wstring> words;
  auto add = [&](const auto& deltas) {
    for (const auto& item : deltas) if (item.key == key) {
      words.erase(std::remove(words.begin(), words.end(), item.candidate), words.end());
      words.insert(words.begin(), item.candidate);
    }
  };
  add(queue_);
  return words;
}
bool Store::Learn(std::wstring key, std::wstring candidate) {
  std::lock_guard lock(mutex_);
  if (queue_.size() >= kQueueLimit) return false;
  queue_.push_back({client_ + "." + std::to_string(++operation_), std::move(key), std::move(candidate)});
  wake_.notify_one(); return true;
}
void Store::Run() {
  EngineClient learner;
  std::filesystem::path directory, spool;
  std::filesystem::file_time_type manifest_time{};
  HANDLE lease = INVALID_HANDLE_VALUE;
  try {
    directory = Directory(); std::filesystem::create_directories(directory);
    spool = directory / ("pending-" + std::to_string(GetCurrentProcessId()) + "-" + client_ + ".queue");
    lease = CreateFileW((spool.wstring() + L".lock").c_str(), GENERIC_READ | GENERIC_WRITE,
                        FILE_SHARE_READ, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (lease == INVALID_HANDLE_VALUE) throw std::runtime_error("learning spool ownership");
    // Recover spools only from exited processes. Concurrent live clients
    // retain ownership; duplicate crash recovery is harmless at the engine.
    for (const auto& entry : std::filesystem::directory_iterator(directory)) {
      auto name = entry.path().filename().string();
      if (!name.starts_with("pending-") || entry.path().extension() != ".queue") continue;
      const auto end = name.find('-', 8);
      DWORD pid = static_cast<DWORD>(std::stoul(name.substr(8, end - 8)));
      HANDLE claim = CreateFileW((entry.path().wstring() + L".lock").c_str(), GENERIC_READ | GENERIC_WRITE,
                                 0, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
      Claim ownership{claim};
      bool exited = claim != INVALID_HANDLE_VALUE;
      if (!exited && GetLastError() == ERROR_FILE_NOT_FOUND) {
        HANDLE process = OpenProcess(SYNCHRONIZE, FALSE, pid);
        exited = process ? WaitForSingleObject(process, 0) == WAIT_OBJECT_0 : GetLastError() == ERROR_INVALID_PARAMETER;
        if (process) CloseHandle(process);
      }
      if (!exited) continue;
      std::ifstream input(entry.path());
      std::deque<Learning> recovered;
      std::string id, key, word; uint64_t sequence;
      while (input >> id >> key >> word >> sequence) {
        if (recovered.size() == kQueueLimit || id.size() > 96 || key.size() > 1536 || word.size() > 8192)
          throw std::runtime_error("recovered learning limit");
        recovered.push_back({id, Unhex(key), Unhex(word), sequence});
      }
      std::deque<Learning> all;
      { std::lock_guard lock(mutex_);
        if (queue_.size() + recovered.size() > kQueueLimit) {
          continue;
        }
        queue_.insert(queue_.begin(), recovered.begin(), recovered.end());
        all = queue_;
      }
      Spool(spool, all);
      std::filesystem::remove(entry.path());
      if (claim != INVALID_HANDLE_VALUE) { CloseHandle(claim); ownership.handle = INVALID_HANDLE_VALUE; }
      std::filesystem::remove(entry.path().wstring() + L".lock");
    }
  } catch (...) { /* Pending memory remains usable; Unsaved reports it. */ }
  while (true) {
    std::deque<Learning> queue;
    bool stop;
    { std::lock_guard lock(mutex_); queue = queue_; stop = stopping_; }
    bool durable = false;
    try { if (!spool.empty()) { Spool(spool, queue); durable = true; } }
    catch (const std::exception& error) {
      if (GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", nullptr, 0))
        std::printf("LOCAL_UNSAVED count=%zu error=%s win32=%lu\n", queue.size(), error.what(), GetLastError());
    }
    if (stop) break;
    try {
      const auto time = std::filesystem::last_write_time(directory / "current");
      if (!current_.load() || time != manifest_time) {
        current_.store(OpenPublished(directory));
        manifest_time = time;
      }
      const auto mapped = current_.load();
      std::lock_guard lock(mutex_);
      // Retire even when an ACK arrives after its generation was mapped.
      while (!queue_.empty() && queue_.front().sequence && queue_.front().sequence <= mapped->header().overlay_sequence)
        queue_.pop_front();
    } catch (...) { /* Keep the last verified mapping. */ }
    const auto unacked = std::find_if(queue.begin(), queue.end(), [](const auto& item) { return item.sequence == 0; });
    if (durable && unacked != queue.end()) {
      const auto& item = *unacked;
      if (auto sequence = learner.LearnLocal(item.id, ScalarHex(item.key), ScalarHex(item.candidate))) {
        if (GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", nullptr, 0))
          std::printf("LOCAL_ACK id=%s sequence=%llu\n", item.id.c_str(), *sequence);
        std::lock_guard lock(mutex_);
        for (auto& pending : queue_) if (pending.id == item.id) pending.sequence = *sequence;
      } else if (GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", nullptr, 0))
        std::printf("LOCAL_PENDING id=%s response=%.160s\n", item.id.c_str(), learner.last_response().c_str());
    }
    std::unique_lock lock(mutex_);
    wake_.wait_for(lock, std::chrono::milliseconds(250), [this] { return stopping_; });
  }
  if (lease != INVALID_HANDLE_VALUE) CloseHandle(lease);
}
bool Conversion::Begin(std::shared_ptr<const Index> index, const std::wstring& reading,
                       const std::vector<std::wstring>& pending) {
  if (!index) return false;
  auto entry = index->Lookup(reading);
  if (!entry.supported) return false;
  index_ = std::move(index); reading_ = reading; selection_ = 0;
  visible_ = pending; Union(visible_, entry.user);
  shared_ = std::move(entry.shared); shared_loaded_ = visible_.empty();
  if (shared_loaded_) Union(visible_, shared_);
  if (visible_.empty()) { Reset(); return false; }
  return true;
}
EngineState Conversion::State() const {
  EngineState state;
  state.mode = L"candidate"; state.composition_start = 0;
  state.candidate_index = static_cast<int>(selection_); state.candidates = visible_;
  state.text = L"▼" + selected().substr(0, selected().find(L';'));
  state.cursor = static_cast<int>(state.text.size()); return state;
}
bool Conversion::Next() {
  if (selection_ + 1 == visible_.size() && !shared_loaded_) { Union(visible_, shared_); shared_loaded_ = true; }
  if (selection_ + 1 >= visible_.size()) return false;
  ++selection_; return true;
}
bool Conversion::Previous() { if (!selection_) return false; --selection_; return true; }
bool Conversion::Select(size_t index) { if (index >= visible_.size()) return false; selection_ = index; return true; }
EngineState Conversion::Commit() {
  EngineState state;
  state.mode = L"hiragana"; state.text = selected().substr(0, selected().find(L';'));
  state.cursor = static_cast<int>(state.text.size()); Reset(); return state;
}
void Conversion::Reset() { index_.reset(); visible_.clear(); shared_.clear(); reading_.clear(); selection_ = 0; shared_loaded_ = false; }
}
