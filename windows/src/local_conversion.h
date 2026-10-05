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
struct Learning { std::string id; std::wstring key, candidate; uint64_t sequence = 0; };
// All file I/O, full validation and engine transactions belong to this
// worker. The input thread only takes published snapshots and queues deltas.
class Store {
 public:
  ~Store() { Stop(); }
  void Start();
  void Stop();
  std::shared_ptr<const Index> Current() const { return current_.load(); }
  std::vector<std::wstring> Pending(std::wstring_view key) const;
  bool Learn(std::wstring key, std::wstring candidate);
  size_t Unsaved() const;
  bool Available() const;
 private:
  void Run();
  std::atomic<std::shared_ptr<const Index>> current_;
  mutable std::mutex mutex_;
  std::condition_variable wake_;
  std::deque<Learning> queue_;
  bool stopping_ = false;
  std::thread worker_;
  std::string client_;
  uint64_t operation_ = 0;
};
class Conversion {
 public:
  bool Begin(std::shared_ptr<const Index> index, const std::wstring& reading,
             const std::vector<std::wstring>& pending = {});
  bool active() const { return index_ != nullptr; }
  EngineState State() const;
  // False means exhausted: hand over one conversion barrier for registration.
  bool Next();
  bool Previous();
  bool Select(size_t index);
  EngineState Commit();
  void Reset();
  const std::wstring& reading() const { return reading_; }
  const std::wstring& selected() const { return visible_[selection_]; }
 private:
  std::shared_ptr<const Index> index_;
  std::wstring reading_;
  std::vector<std::wstring> visible_, shared_;
  size_t selection_ = 0;
  bool shared_loaded_ = false;
};
}
