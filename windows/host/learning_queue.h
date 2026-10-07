// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <windows.h>
#include "provider_outbox.h"
#include <condition_variable>
#include <chrono>
#include <cstdio>
#include <algorithm>
#include <atomic>
#include <deque>
#include <future>
#include <functional>
#include <filesystem>
#include <fstream>
#include <map>
#include <sstream>
#include <mutex>
#include <string>
#include <thread>

namespace ddskk {
// Immutable checkpoints preserve candidate order and operation ids together.
// The worker owns learning writes; the publication thread owns its native
// row snapshot. Producer records are flushed outside interpreter ownership.
class LearningQueue {
 public:
  struct ProducerOperation {
    uint64_t id = 0;
    std::string content;
    std::shared_future<bool> done;
    bool ready = false, accepted = false; // guarded by queue mutex
  };
  explicit LearningQueue(std::wstring target,
      std::function<bool(const std::string&)> publisher = {})
      : target_(std::move(target)), publisher_(std::move(publisher)),
        outbox_(target_), next_provider_(ProviderOutbox::Watermark(target_)),
        worker_([this] { Run(); }) {}
  ~LearningQueue() { Drain(); }
  static bool RecoverOutbox(const std::wstring& target) {
    LearningQueue recovery(target);
    return recovery.outbox_.Recover([&](const std::string& content) { return recovery.Publish(content); });
  }
  // Reserve in interpreter order; disk I/O waits until interpreter ownership
  // is released. A later client cannot overtake this unsealed FIFO job.
  std::shared_ptr<ProducerOperation> ReserveProducer(std::string content) {
    auto operation = std::make_shared<ProducerOperation>();
    std::lock_guard lock(mutex_);
    if (closing_) return {};
    operation->id = ++next_provider_;
    content += ";; EG2 provider " + std::to_string(operation->id) + "\n";
    operation->content = content;
    Job job{std::move(content), {}, operation};
    operation->done = job.done.get_future().share();
    overlay_jobs_.push_back(OverlayRows(job.content, false));
    overlay_generation_.fetch_add(1, std::memory_order_release);
    jobs_.push_back(std::move(job));
    ++sequence_; latest_ = operation->done;
    return operation;
  }
  bool SealProducer(const std::shared_ptr<ProducerOperation>& operation) {
    const auto start = std::chrono::steady_clock::now();
    bool ok = false;
    try { ok = outbox_.Append(operation->id, operation->content); } catch (...) { ok = false; }
    const auto ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now()-start).count();
    std::fprintf(stderr, "LEARNING_OUTBOX append id=%llu bytes=%zu qpc_ms=%.6f ok=%d\n",
        operation->id, operation->content.size(), ms, ok ? 1 : 0);
    { std::lock_guard lock(mutex_); operation->accepted = ok; operation->ready = true; }
    wake_.notify_one();
    return ok;
  }
  static bool RecoverPending(const std::wstring& target) {
    const auto pending = target + L".eg2-checkpoint";
    std::ifstream file(pending, std::ios::binary);
    if (!file) return true;
    const std::string content((std::istreambuf_iterator<char>(file)), {});
    file.close();
    const auto footer = content.rfind(";; EG2 length ");
    if (!content.starts_with(";; EG2 journal ") || footer == std::string::npos ||
        content.substr(footer) != ";; EG2 length " + std::to_string(footer) + "\n" ||
        content.find(";; EG2 checkpoint v2\n") == std::string::npos) return false;
    HANDLE durable = CreateFileW(pending.c_str(), GENERIC_WRITE, FILE_SHARE_READ,
        nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (durable == INVALID_HANDLE_VALUE) return false;
    const bool flushed = FlushFileBuffers(durable) != FALSE;
    CloseHandle(durable);
    if (!flushed || !MoveFileExW(pending.c_str(), target.c_str(),
        MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) return false;
    // Replay of complete rows is idempotent. Preserve fresh legacy journal
    // entries; clear only the exact journal incorporated by this checkpoint.
    std::ifstream journal_file(target + L".journal", std::ios::binary);
    const std::string journal((std::istreambuf_iterator<char>(journal_file)), {});
    journal_file.close();
    Rows identity;
    if (!content.starts_with(";; EG2 journal " + identity.JournalSignature(journal) + "\n")) return true;
    HANDLE old = CreateFileW((target + L".journal").c_str(), GENERIC_WRITE,
        FILE_SHARE_READ, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (old == INVALID_HANDLE_VALUE) return false;
    const bool ok = FlushFileBuffers(old) != FALSE; CloseHandle(old); return ok;
  }
  std::shared_future<bool> Submit(std::string content) {
    Job job{std::move(content), {}, {}};
    const auto staged_overlay = OverlayRows(job.content, false);
    auto done = job.done.get_future().share();
    {
      std::lock_guard lock(mutex_);
      if (closing_) { job.done.set_value(false); return done; }
      overlay_jobs_.push_back(staged_overlay);
      overlay_generation_.fetch_add(1, std::memory_order_release);
      jobs_.push_back(std::move(job));
      ++sequence_; latest_ = done;
    }
    wake_.notify_one();
    return done;
  }
  std::pair<uint64_t, std::shared_future<bool>> Fence() {
    std::lock_guard lock(mutex_);
    return {sequence_, latest_};
  }
  // Sole publication-thread API. Dictionary I/O, merges and full-table
  // encoding occur after releasing the enqueue mutex, without interpreter use.
  void UpdateOverlay() {
    std::deque<std::string> jobs;
    { std::lock_guard lock(mutex_); jobs.swap(overlay_jobs_);
      overlay_snapshot_generation_ = overlay_generation_.load(std::memory_order_relaxed); }
    overlay_.Apply(target_, ";; EG2 delta v2\n");
    for (const auto& content : jobs) {
      if (content.empty()) { overlay_ = {}; overlay_.Apply(target_, ";; EG2 delta v2\n"); }
      else overlay_.Apply(target_, content);
    }
  }
  std::string OverlaySnapshot() {
    UpdateOverlay();
    return overlay_.Checkpoint(target_, ";; EG2 delta v2\n");
  }
  uint64_t OverlayGeneration() const { return overlay_generation_.load(std::memory_order_acquire); }
  uint64_t SnapshotGeneration() const { return overlay_snapshot_generation_; }
  uint64_t OverlayRevision() const { return overlay_.revision_; }
  void BeginDrain() {
    { std::lock_guard lock(mutex_); closing_ = true; }
    wake_.notify_one();
  }
  void Drain() {
    BeginDrain();
    if (worker_.joinable()) worker_.join();
  }
 private:
  struct Job { std::string content; std::promise<bool> done; std::shared_ptr<ProducerOperation> producer; };
  static std::string OverlayRows(const std::string& content, bool durable_metadata) {
    if (content.empty()) return content;
    std::istringstream input(content);
    std::string line, result = durable_metadata ? ";; EG2 delta v2\n" : "";
    while (std::getline(input, line)) {
      const bool metadata = line.starts_with(";; local-ack ");
      if (metadata == durable_metadata) result += line + '\n';
    }
    return result;
  }
  struct Rows {
  void Merge(const std::string& content) {
    std::istringstream input(content);
    std::string line;
    int section = -1;
    while (std::getline(input, line)) {
      if (line == ";; okuri-ari entries.") { section = 1; continue; }
      if (line == ";; okuri-nasi entries.") { section = 0; continue; }
      if (line.starts_with(";; EG2 revision ")) {
        revision_ = std::stoull(line.substr(16)); continue;
      }
      if (line.starts_with(";; EG2 provider ")) {
        provider_ = std::max(provider_, std::stoull(line.substr(16))); continue;
      }
      if (line.starts_with(";; local-ack ")) {
        const auto end = line.find(' ', 13);
        if (end != std::string::npos) {
          metadata_[line.substr(13, end - 13)] = line;
          const auto sequence = line.find(' ', end + 1);
          if (sequence != std::string::npos) revision_ = std::max(revision_, std::stoull(line.substr(sequence + 1)));
        }
        continue;
      }
      if (line.empty() || line[0] == ';') continue;
      const auto space = line.find(" /");
      if (space == std::string::npos) continue;
      const auto key = line.substr(0, space);
      const bool ari = section >= 0 ? section == 1 : ari_.contains(key) ||
          (!nasi_.contains(key) && !key.empty() && key.back() >= 'a' && key.back() <= 'z');
      ari_.erase(key); nasi_.erase(key);
      if (line.substr(space) != " //") (ari ? ari_ : nasi_)[key] = line;
    }
  }
  void Apply(const std::wstring& target_, const std::string& content) {
    if (!loaded_) {
      std::ifstream base(target_, std::ios::binary);
      std::string previous((std::istreambuf_iterator<char>(base)), {});
      Merge(previous);
      std::ifstream journal_file(target_ + L".journal", std::ios::binary);
      const std::string journal((std::istreambuf_iterator<char>(journal_file)), {});
      if (previous.find(";; EG2 journal " + JournalSignature(journal) + "\n") == std::string::npos)
        Merge(journal);
      loaded_ = true;
    }
    if (!content.starts_with(";; EG2 delta v2\n")) {
      ari_.clear(); nasi_.clear(); metadata_.clear(); revision_ = 0;
    }
    Merge(content);
  }
  std::string Checkpoint(const std::wstring& target_, const std::string& content) {
    Apply(target_, content);
    if (!content.starts_with(";; EG2 delta v2\n")) return content;
    std::string result = ";; EG2 checkpoint v2\n;;; -*- coding: utf-8 -*-\n";
    result += ";; EG2 revision " + std::to_string(revision_) + "\n";
    if (provider_) result += ";; EG2 provider " + std::to_string(provider_) + "\n";
    for (const auto& [id, row] : metadata_) result += row + '\n';
    result += ";; okuri-ari entries.\n";
    for (const auto& [key, row] : ari_) result += row + '\n';
    result += ";; okuri-nasi entries.\n";
    for (const auto& [key, row] : nasi_) result += row + '\n';
    return result;
  }
  std::string JournalSignature(const std::string& journal) {
    const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
        journal.data(), static_cast<int>(journal.size()), nullptr, 0);
    std::wstring wide(static_cast<size_t>(count), L'\0');
    if (count) MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, journal.data(),
        static_cast<int>(journal.size()), wide.data(), count);
    uint64_t scalars = 0;
    std::string encoded;
    constexpr char hex[] = "0123456789abcdef";
    for (size_t i = 0; i < wide.size(); ++i) {
      uint32_t code = wide[i];
      if (code >= 0xd800 && code <= 0xdbff && i + 1 < wide.size()) {
        code = 0x10000 + ((code - 0xd800) << 10) + (wide[++i] - 0xdc00);
      }
      for (int shift = 20; shift >= 0; shift -= 4) encoded += hex[(code >> shift) & 15];
      ++scalars;
    }
    return std::to_string(scalars) + " " + (encoded.empty() ? "-" : encoded);
  }
    uint64_t revision_ = 0, provider_ = 0;
    bool loaded_ = false;
    std::map<std::string, std::string> ari_, nasi_, metadata_;
  };
  bool Publish(const std::string& input) {
    const auto snapshot = rows_.Checkpoint(target_, input);
    std::ifstream old_journal(target_ + L".journal", std::ios::binary);
    const std::string journal((std::istreambuf_iterator<char>(old_journal)), {});
    old_journal.close();
    std::string content = ";; EG2 journal " + rows_.JournalSignature(journal) + "\n" + snapshot;
    content += ";; EG2 length " + std::to_string(content.size()) + "\n";
    if (target_.empty()) return false;
    std::error_code error;
    std::filesystem::create_directories(std::filesystem::path(target_).parent_path(), error);
    if (error) return false;
    const auto temporary = target_ + L".eg2-checkpoint";
    HANDLE file = CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, nullptr,
        CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;
    DWORD written = 0;
    bool ok = content.size() <= MAXDWORD && WriteFile(file, content.data(),
        static_cast<DWORD>(content.size()), &written, nullptr) &&
        written == content.size() && FlushFileBuffers(file);
    CloseHandle(file);
    // Fault injection is confined to explicitly diagnostic private harnesses.
    wchar_t registry[256]{}, hold[32768]{};
    if (ok && GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", nullptr, 0) &&
        GetEnvironmentVariableW(L"NATIVEIME_REGISTRY_KEY", registry, 256) &&
        std::wstring(registry).starts_with(L"Software\\NativeIME-test-") &&
        GetEnvironmentVariableW(L"NATIVEIME_TEST_LEARNING_HOLD_FILE", hold, 32768) &&
        GetFileAttributesW(hold) != INVALID_FILE_ATTRIBUTES) {
      const auto start = GetTickCount64();
      std::fprintf(stderr, "LEARNING_IO held\n"); std::fflush(stderr);
      while (GetFileAttributesW(hold) != INVALID_FILE_ATTRIBUTES && GetTickCount64() - start < 10000) Sleep(10);
      std::fprintf(stderr, "LEARNING_IO released_ms=%llu\n", GetTickCount64()-start); std::fflush(stderr);
    }
    if (ok) ok = MoveFileExW(temporary.c_str(), target_.c_str(),
        MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != FALSE;
    if (ok) {
      // New engines recognize the checkpoint marker if a crash happens
      // between atomic replacement and clearing the superseded journal.
      const auto journal_path = target_ + L".journal";
      HANDLE old = CreateFileW(journal_path.c_str(), GENERIC_WRITE, FILE_SHARE_READ,
          nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
      if (old == INVALID_HANDLE_VALUE) return false;
      ok = FlushFileBuffers(old) != FALSE;
      CloseHandle(old);
    }
    // A fully flushed checkpoint is a recoverable outbox. Never delete it
    // on a failed rename: restart retries publication before engine loading.
    if (!ok && written != content.size()) DeleteFileW(temporary.c_str());
    return ok;
  }
  void Run() {
    for (;;) {
      Job job;
      {
        std::unique_lock lock(mutex_);
        wake_.wait(lock, [this] { return closing_ || (!jobs_.empty() &&
            (!jobs_.front().producer || jobs_.front().producer->ready)); });
        if (jobs_.empty()) return;
        job = std::move(jobs_.front()); jobs_.pop_front();
        if (job.producer && (!job.producer->ready || !job.producer->accepted)) {
          job.done.set_value(false); continue;
        }
      }
      if (job.content.empty()) {
        // A newly published engine may have read a fresh legacy journal.
        // Rebuild the native row cache from storage before its first delta.
        rows_ = {};
        job.done.set_value(true); continue;
      }
      bool ok = false;
      do {
        try {
          ok = publisher_ ? publisher_(job.content) : Publish(job.content);
          if (ok && job.producer && !publisher_) ok = outbox_.Retire(job.producer->id);
        }
        catch (...) { ok = false; }
        if (ok) break;
        // Preserve FIFO across transient storage failures. Neither this retry
        // nor file publication holds the engine or queue mutex.
        std::fprintf(stderr, "LEARNING_IO retry\n");
        std::unique_lock lock(mutex_);
        if (closing_) break;
        wake_.wait_for(lock, std::chrono::milliseconds(100), [this] { return closing_; });
        if (closing_) break;
      } while (!ok);
      if (ok) {
        // Immutable overlays can retire producer spools too. Publish operation
        // watermarks only after durable storage; candidate rows need not wait.
        const auto metadata = OverlayRows(job.content, true);
        if (metadata != ";; EG2 delta v2\n") {
          std::lock_guard lock(mutex_);
          overlay_jobs_.push_back(metadata);
          overlay_generation_.fetch_add(1, std::memory_order_release);
        }
      }
      job.done.set_value(ok);
    }
  }
  std::wstring target_;
  Rows rows_, overlay_;
  std::deque<std::string> overlay_jobs_;
  std::atomic<uint64_t> overlay_generation_{0};
  uint64_t overlay_snapshot_generation_ = 0;
  std::function<bool(const std::string&)> publisher_;
  ProviderOutbox outbox_;
  uint64_t next_provider_ = 0;
  std::mutex mutex_;
  std::condition_variable wake_;
  std::deque<Job> jobs_;
  bool closing_ = false;
  uint64_t sequence_ = 0;
  std::shared_future<bool> latest_;
  std::thread worker_;
};
}
