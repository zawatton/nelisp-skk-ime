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
std::string SpoolBytes(const std::deque<Learning>& queue) {
  std::string bytes;
  for (const auto& item : queue)
    bytes += item.id + " " + ScalarHex(item.key) + " " + ScalarHex(item.candidate) + " " + std::to_string(item.sequence) + " " + (item.okuri.empty() ? "-" : ScalarHex(item.okuri)) + "\n";
  return bytes;
}
void Spool(const std::filesystem::path& path, const std::string& bytes) {
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
void Store::Persist(const std::filesystem::path& path, const std::deque<Learning>& queue) {
  auto bytes = SpoolBytes(queue);
  if (bytes == durable_spool_) return;
  Spool(path, bytes);
  durable_spool_ = std::move(bytes); // Advance only after flush + atomic publication.
  const auto writes = ++spool_writes_;
  if (GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", nullptr, 0))
    std::printf("LOCAL_SPOOL writes=%llu count=%zu\n", writes, queue.size());
}
void Store::Start() {
  if (worker_.joinable()) {
    if (WaitForSingleObject(worker_.native_handle(), 0) != WAIT_OBJECT_0) return;
    worker_.join(); // OS thread already ended; this cannot wait for I/O.
  }
  if (client_.empty()) client_ = Identity();
  else {
    const auto captured = Capture();
    restart_pending_.assign(captured.pending.begin(), captured.pending.end());
  }
  stopping_ = false;
  worker_ = std::thread([this] { Run(); });
}
bool Store::PrepareHandoff() {
  if (!worker_.joinable()) return true;
  if (WaitForSingleObject(worker_.native_handle(), 0) == WAIT_OBJECT_0 &&
      persisted_.load() != written_.load()) Start();
  stopping_ = true; wake_.notify_one();
  return WaitForSingleObject(worker_.native_handle(), 0) == WAIT_OBJECT_0 &&
         persisted_.load() == written_.load();
}
void Store::Stop() {
  stopping_ = true;
  wake_.notify_one();
  if (worker_.joinable()) worker_.join();
}
size_t Store::Unsaved() const {
  return ui_pending_.size();
}
bool Store::Available() const {
  return ui_pending_.size() < kQueueLimit;
}
std::shared_ptr<const Index> Store::Current() const {
  const auto state = published_.load();
  return state ? state->index : nullptr;
}
Selection Store::Capture() {
  Selection out;
  const auto state = published_.load();
  if (!state) return out;
  out.index = state->index;
  if (out.index && out.index->header().overlay_sequence >= state->acknowledged_sequence) {
    while (!ui_pending_.empty() &&
           std::stoull(ui_pending_.front().id.substr(client_.size() + 1)) <= state->acknowledged_operation)
      ui_pending_.pop_front();
  }
  for (const auto& item : state->pending)
    if (!out.index || !item.sequence || item.sequence > out.index->header().overlay_sequence)
      out.pending.push_back(item);
  for (const auto& item : ui_pending_)
    if (std::none_of(out.pending.begin(), out.pending.end(), [&](const auto& x) { return x.id == item.id; }))
      out.pending.push_back(item);
  out.available = out.pending.size() < kQueueLimit;
  return out;
}
std::vector<std::wstring> Store::Pending(std::wstring_view key) const {
  std::vector<std::wstring> words;
  auto add = [&](const auto& deltas) {
    for (const auto& item : deltas) if (item.key == key) {
      words.erase(std::remove(words.begin(), words.end(), item.candidate), words.end());
      words.insert(words.begin(), item.candidate);
    }
  };
  add(ui_pending_);
  return words;
}
bool Store::Learn(std::wstring key, std::wstring candidate, std::wstring okuri) {
  const auto written = written_.load(std::memory_order_relaxed);
  if (ui_pending_.size() >= kQueueLimit || written - consumed_.load(std::memory_order_acquire) == kQueueLimit) return false;
  Learning item{client_ + "." + std::to_string(++operation_), std::move(key), std::move(candidate), 0, std::move(okuri)};
  ui_pending_.push_back(item);
  inbound_[written % kQueueLimit] = std::move(item);
  written_.store(written + 1, std::memory_order_release);
  wake_.notify_one(); return true;
}
void Store::Run() {
  EngineClient learner;
  std::filesystem::path directory, spool;
  std::optional<std::filesystem::file_time_type> manifest_time;
  std::chrono::steady_clock::time_point next_mapping_retry{};
  HANDLE lease = INVALID_HANDLE_VALUE;
  std::deque<Learning> queue = std::move(restart_pending_);
  std::shared_ptr<const Index> mapped;
  uint64_t acknowledged_operation = 0, acknowledged_sequence = 0;
  bool stalled = false;
  bool spool_dirty = true;
  try {
    directory = Directory(); std::filesystem::create_directories(directory);
    spool = directory / ("pending-" + std::to_string(GetCurrentProcessId()) + "-" + client_ + ".queue");
    lease = CreateFileW((spool.wstring() + L".lock").c_str(), GENERIC_READ | GENERIC_WRITE,
                        FILE_SHARE_READ, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
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
      std::string line;
      while (std::getline(input, line)) {
        std::istringstream record(line);
        std::string id, key, word, okuri; uint64_t sequence;
        if (!(record >> id >> key >> word >> sequence)) throw std::runtime_error("recovered learning record");
        record >> okuri;
        if (recovered.size() == kQueueLimit || id.size() > 96 || key.size() > 1536 || word.size() > 8192)
          throw std::runtime_error("recovered learning limit");
        recovered.push_back({id, Unhex(key), Unhex(word), sequence, okuri.empty() || okuri == "-" ? L"" : Unhex(okuri)});
      }
      input.close(); // Windows deletion requires releasing the recovery reader.
      {
        if (queue.size() + recovered.size() > kQueueLimit) {
          continue;
        }
        queue.insert(queue.begin(), recovered.begin(), recovered.end());
      }
      Persist(spool, queue); // Durable ownership transfer precedes source deletion.
      std::filesystem::remove(entry.path());
      if (claim != INVALID_HANDLE_VALUE) { CloseHandle(claim); ownership.handle = INVALID_HANDLE_VALUE; }
      std::filesystem::remove(entry.path().wstring() + L".lock");
    }
  } catch (...) { /* Pending memory remains usable; Unsaved reports it. */ }
  while (true) {
    auto consumed = consumed_.load(std::memory_order_relaxed);
    while (consumed != written_.load(std::memory_order_acquire)) {
      auto& item = *inbound_[consumed % kQueueLimit];
      if (std::none_of(queue.begin(), queue.end(), [&](const auto& x) { return x.id == item.id; }))
        { queue.push_back(std::move(item)); spool_dirty = true; }
      inbound_[consumed % kQueueLimit].reset();
      consumed_.store(++consumed, std::memory_order_release);
    }
    bool durable = false;
    try {
      if (!spool.empty()) {
        if (spool_dirty) { Persist(spool, queue); spool_dirty = false; }
        durable = true;
        persisted_.store(consumed_.load());
      }
    }
    catch (const std::exception& error) {
      if (GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", nullptr, 0))
        std::printf("LOCAL_UNSAVED count=%zu error=%s win32=%lu\n", queue.size(), error.what(), GetLastError());
    }
    if (stopping_) break;
    try {
      const auto time = std::filesystem::last_write_time(directory / "current");
      const auto now = std::chrono::steady_clock::now();
      if (!manifest_time || time != *manifest_time || (!mapped && now >= next_mapping_retry)) {
        // Keep successful unchanged mappings pinned. Without a mapping,
        // retry failures at most once per second for an unchanged current.
        manifest_time = time;
        next_mapping_retry = now + std::chrono::seconds(1);
        ++mapping_opens_;
        mapped = OpenPublished(directory);
      }
      // Retire even when an ACK arrives after its generation was mapped.
      while (mapped && !queue.empty() && queue.front().sequence && queue.front().sequence <= mapped->header().overlay_sequence) {
        const auto& item = queue.front();
        if (item.id.starts_with(client_ + ".")) {
          acknowledged_operation = std::stoull(item.id.substr(client_.size() + 1));
          acknowledged_sequence = item.sequence;
        }
        queue.pop_front();
        spool_dirty = true;
      }
    } catch (...) { /* Keep the last verified mapping. */ }
    // Mapping availability must not depend on an ACK. This also covers a
    // freshly activated core recovering a spool while the engine is stalled.
    published_.store(std::make_shared<Published>(Published{mapped, queue, acknowledged_operation, acknowledged_sequence}));
    const auto unacked = std::find_if(queue.begin(), queue.end(), [](const auto& item) { return item.sequence == 0; });
    if (durable && unacked != queue.end()) {
      wchar_t registry[128]{}, delay[16]{};
      if (!stalled && GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", nullptr, 0) &&
          GetEnvironmentVariableW(L"NATIVEIME_REGISTRY_KEY", registry, 128) &&
          std::wstring(registry).starts_with(L"Software\\NativeIME-test-") &&
          GetEnvironmentVariableW(L"NATIVEIME_TEST_LOCAL_WORKER_STALL_MS", delay, 16)) {
        stalled = true;
        const DWORD ms = std::min<DWORD>(10000, wcstoul(delay, nullptr, 10));
        std::printf("LOCAL_WORKER stalled_ms=%lu\n", ms); std::fflush(stdout);
        Sleep(ms); // No lock or input-owned object is held across the stall.
      }
      const auto& item = *unacked;
      if (auto sequence = learner.LearnLocal(item.id, ScalarHex(item.key), ScalarHex(item.candidate), 1500, item.okuri.empty() ? "" : ScalarHex(item.okuri))) {
        if (GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", nullptr, 0))
          std::printf("LOCAL_ACK id=%s sequence=%llu\n", item.id.c_str(), *sequence);
        for (auto& pending : queue) if (pending.id == item.id && pending.sequence != *sequence) {
          pending.sequence = *sequence;
          spool_dirty = true;
        }
      } else if (GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", nullptr, 0))
        std::printf("LOCAL_PENDING id=%s response=%.160s\n", item.id.c_str(), learner.last_response().c_str());
    }
    published_.store(std::make_shared<Published>(Published{mapped, queue, acknowledged_operation, acknowledged_sequence}));
    std::unique_lock lock(wait_mutex_);
    wake_.wait_for(lock, std::chrono::milliseconds(50), [this] { return stopping_.load() || written_.load() != consumed_.load(); });
  }
  if (lease != INVALID_HANDLE_VALUE) CloseHandle(lease);
}
bool Conversion::Begin(std::shared_ptr<const Index> index, const std::wstring& reading,
                       const std::vector<std::wstring>& pending, std::wstring okuri) {
  if (!index) return false;
  auto entry = index->Lookup(reading, okuri);
  if (!entry.supported) return false;
  index_ = std::move(index); reading_ = reading; okuri_ = std::move(okuri); selection_ = 0;
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
  state.text = L"▼" + selected().substr(0, selected().find(L';')) + okuri_;
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
  state.mode = L"hiragana"; state.text = selected().substr(0, selected().find(L';')) + okuri_;
  state.cursor = static_cast<int>(state.text.size()); Reset(); return state;
}
void Conversion::Reset() { index_.reset(); visible_.clear(); shared_.clear(); reading_.clear(); okuri_.clear(); selection_ = 0; shared_loaded_ = false; }
}
