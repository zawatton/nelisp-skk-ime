// GPL-3.0-or-later
#pragma once
#include "local_index.h"
#include "engine_protocol.h"
#include <atomic>
#include <condition_variable>
#include <deque>
#include <map>
#include <mutex>
#include <thread>

namespace ddskk::local {
struct MirrorMapping;
struct Learning { std::string id; std::wstring key, candidate; uint64_t sequence = 0; std::wstring okuri; };
struct Selection { std::shared_ptr<const Index> index; std::vector<Learning> pending; bool available = false; };
// All file I/O, full validation and engine transactions belong to this
// worker. The input thread only takes published snapshots and queues deltas.
class Store {
 public:
  ~Store() { Stop(); }
  void Start();
  void Stop();
  bool PrepareHandoff();
  bool started() const { return !client_.empty(); }
  std::shared_ptr<const Index> Current() const;
  Selection Capture();
  std::vector<std::wstring> Pending(std::wstring_view key) const;
  bool Learn(std::wstring key, std::wstring candidate, std::wstring okuri = {});
  size_t Unsaved() const;
  bool Available() const;
  bool PublishState(const EngineState& state, bool claim = true);
  void ReleaseState();
  uint64_t SpoolWritesForDiagnostics() const { return spool_writes_.load(); }
  uint64_t MappingOpensForDiagnostics() const { return mapping_opens_.load(); }
 private:
  void Run();
  void Persist(const std::filesystem::path& path, const std::deque<Learning>& queue);
  struct Published {
    std::shared_ptr<const Index> index;
    std::deque<Learning> pending;
    uint64_t acknowledged_operation = 0, acknowledged_sequence = 0;
  };
  std::atomic<std::shared_ptr<const Published>> published_;
  std::atomic<std::shared_ptr<MirrorMapping>> mirror_;
  // One TSF producer, one worker consumer. No worker-held lock is acquired
  // by Capture/Learn or any key/edit callback.
  std::array<std::optional<Learning>, 256> inbound_;
  std::atomic<uint64_t> written_{0}, consumed_{0}, persisted_{0};
  std::atomic<uint64_t> spool_writes_{0};
  std::atomic<uint64_t> mapping_opens_{0};
  // Worker-owned; retained across Start/Stop so restarting an unchanged
  // queue (including an empty queue) does not republish its spool.
  std::string durable_spool_;
  std::deque<Learning> ui_pending_;
  std::deque<Learning> restart_pending_;
  std::mutex wait_mutex_;
  std::condition_variable wake_;
  std::atomic<bool> stopping_{false};
  std::thread worker_;
  std::string client_;
  uint64_t operation_ = 0;
  LONG mirror_cookie_ = 0;
  bool mirror_claim_pending_ = false; // UI-thread intent while resources open
};
class Conversion {
 public:
  bool Begin(std::shared_ptr<const Index> index, const std::wstring& reading,
             const std::vector<std::wstring>& pending = {}, std::wstring okuri = {});
  bool active() const { return index_ != nullptr; }
  EngineState State() const;
  // False means exhausted: hand over one conversion barrier for registration.
  bool Next();
  bool Previous();
  void Materialize();
  bool NextMenu();
  bool PreviousMenu();
  bool Select(size_t index);
  EngineState Commit();
  void Reset();
  const std::wstring& reading() const { return reading_; }
  const std::wstring& okuri() const { return okuri_; }
  const std::wstring& selected() const { return visible_[selection_]; }
 private:
  std::shared_ptr<const Index> index_;
  std::wstring reading_, okuri_;
  std::vector<std::wstring> visible_, shared_;
  size_t selection_ = 0;
  bool shared_loaded_ = false;
};
}
