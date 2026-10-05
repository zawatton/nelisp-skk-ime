// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <windows.h>
#include <atomic>
#include <deque>
#include <mutex>
#include <string>
#include <thread>

// Socket and discovery I/O belong exclusively to the worker. The TSF thread
// only copies a bounded snapshot under a mutex; it never waits for a peer.
class InlinePreedit final {
 public:
  ~InlinePreedit() { Stop(); }
  void Start(HWND notify, UINT message);
  void Stop();
  uint64_t Epoch() const { return epoch_.load(); }
  bool Publish(uint64_t epoch, const std::wstring& text, size_t cursor);
  void Clear(uint64_t epoch);
  // Queued only for a live listener advertising Protocol v1.1 pairing.
  bool Pair(uint64_t epoch, const std::wstring& opener, const std::wstring& closer);
  bool Caret(uint64_t epoch, RECT* rect);
  // Last listener caret for the live connection, including outside preedit.
  bool LastCaret(RECT* rect);
 private:
  void Run();
  struct Update {
    enum Kind { Preedit, Clear, Pair } kind;
    std::wstring text;
    size_t cursor;
    std::wstring closer;
  };
  std::atomic<bool> stop_{false};
  std::atomic<uint64_t> epoch_{0};
  std::thread worker_;
  std::mutex mutex_;
  std::deque<Update> updates_;
  RECT caret_{};
  bool caret_valid_ = false;
  bool pair_capable_ = false;
  HWND notify_ = nullptr;
  UINT message_ = 0;
};
