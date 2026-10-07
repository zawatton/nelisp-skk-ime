// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <windows.h>
#include <algorithm>
#include <filesystem>
#include <fstream>
#include <map>
#include <mutex>
#include <sstream>
#include <string>

namespace ddskk {
// One small, flushed append precedes a provider STATE reply. Complete row
// replacements plus a checkpoint watermark make recovery idempotent. This
// mutex is never held while the learning worker writes the dictionary.
class ProviderOutbox {
 public:
  explicit ProviderOutbox(std::wstring target) : target_(std::move(target)) {}
  static uint64_t Watermark(const std::wstring& target) {
    std::ifstream input(target, std::ios::binary);
    std::string line; uint64_t watermark = 0;
    while (std::getline(input, line)) {
      if (!line.starts_with(";; EG2 provider ")) continue;
      std::istringstream number(line.substr(16)); uint64_t id = 0;
      if (number >> id) watermark = std::max(watermark, id);
    }
    uint64_t cursor = 0;
    if (ReadCursor(target, &cursor)) watermark = std::max(watermark, cursor);
    return watermark;
  }
  bool Append(uint64_t id, const std::string& content) {
    std::lock_guard lock(mutex_);
    if (broken_ || target_.empty() || !id || content.empty() || content.size() > 8*1024*1024 ||
        !content.ends_with(";; EG2 provider " + std::to_string(id) + "\n")) return false;
    std::error_code error;
    const auto parent = std::filesystem::path(target_).parent_path();
    if (!parent.empty()) std::filesystem::create_directories(parent, error);
    if (error) return false;
    HANDLE file = CreateFileW(Path().c_str(), GENERIC_WRITE, FILE_SHARE_READ,
        nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_WRITE_THROUGH, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;
    LARGE_INTEGER zero{}, original{};
    const bool positioned = SetFilePointerEx(file, zero, &original, FILE_END) != FALSE;
    const auto record = "EG2-OUTBOX 1 " + std::to_string(id) + " " +
        std::to_string(content.size()) + " " + std::to_string(Hash(content)) + "\n" +
        content + "\nEG2-END " + std::to_string(id) + "\n";
    DWORD written = 0;
    const bool ok = positioned && record.size() <= MAXDWORD &&
        WriteFile(file, record.data(), static_cast<DWORD>(record.size()), &written, nullptr) &&
        written == record.size() && FlushFileBuffers(file);
    if (!ok && positioned) {
      // A partial failed append must not precede another acknowledged frame.
      if (!(SetFilePointerEx(file, original, nullptr, FILE_BEGIN) &&
            SetEndOfFile(file) && FlushFileBuffers(file))) broken_ = true;
    }
    CloseHandle(file); return ok;
  }
  template<class Publisher> bool Recover(Publisher publish) {
    std::lock_guard lock(mutex_);
    std::map<uint64_t, std::string> records;
    bool exists = false;
    if (!Read(&records, &exists)) return false;
    uint64_t cursor = 0;
    if (!ReadCursor(target_, &cursor)) return false;
    if (!exists) return true;
    auto durable = Watermark(target_);
    for (const auto& [id, content] : records) {
      if (id <= durable) continue;
      if (!publish(content)) return false;
      durable = id;
    }
    // Valid records are durable. Any incomplete tail was never acknowledged.
    return SaveCursor(durable) && Truncate();
  }
  bool Retire(uint64_t durable) {
    // Persist independently too: a legacy engine can rewrite the dictionary
    // without preserving unknown comments. Never retire/release a storage
    // fence until that engine-independent id watermark is durable.
    if (!SaveCursor(durable)) return false;
    std::lock_guard lock(mutex_);
    std::map<uint64_t, std::string> records; bool exists = false;
    // Do not rewrite growing bursts. Once all appended ids are checkpointed,
    // truncate and flush. A failed retirement only causes safe replay/skip.
    if (Read(&records, &exists) && exists && !records.empty() &&
        records.rbegin()->first <= durable) Truncate();
    return true;
  }
 private:
  static bool ReadCursor(const std::wstring& target, uint64_t* cursor) {
    const auto path = target + L".eg2-provider-watermark";
    std::ifstream input(path, std::ios::binary);
    if (!input) {
      const auto attributes = GetFileAttributesW(path.c_str());
      const auto error = GetLastError();
      return attributes == INVALID_FILE_ATTRIBUTES &&
          (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND);
    }
    const std::string text((std::istreambuf_iterator<char>(input)), {});
    std::istringstream fields(text);
    std::string magic, extra; uint64_t version = 0;
    return (fields >> magic >> version >> *cursor) && !(fields >> extra) &&
        magic == "EG2-PROVIDER" && version == 1 &&
        text == "EG2-PROVIDER 1 " + std::to_string(*cursor) + "\n";
  }
  bool SaveCursor(uint64_t durable) {
    if (!durable) return true;
    const auto path = target_ + L".eg2-provider-watermark";
    const auto temporary = path + L".tmp";
    const auto text = "EG2-PROVIDER 1 " + std::to_string(durable) + "\n";
    HANDLE file = CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, nullptr,
        CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_WRITE_THROUGH, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;
    DWORD written = 0;
    bool ok = WriteFile(file, text.data(), static_cast<DWORD>(text.size()), &written, nullptr) &&
        written == text.size() && FlushFileBuffers(file);
    CloseHandle(file);
    if (ok) ok = MoveFileExW(temporary.c_str(), path.c_str(),
        MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != FALSE;
    return ok;
  }
  static uint64_t Hash(const std::string& content) {
    uint64_t value = 14695981039346656037ull;
    for (unsigned char byte : content) { value ^= byte; value *= 1099511628211ull; }
    return value;
  }
  std::wstring Path() const { return target_ + L".eg2-outbox"; }
  bool Read(std::map<uint64_t, std::string>* records, bool* exists) const {
    std::ifstream input(Path(), std::ios::binary);
    if (!input) {
      const auto attributes = GetFileAttributesW(Path().c_str());
      const auto error = GetLastError();
      return attributes == INVALID_FILE_ATTRIBUTES &&
          (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND);
    }
    *exists = true;
    std::string header;
    while (std::getline(input, header)) {
      if (input.eof()) break; // incomplete header
      std::istringstream fields(header);
      std::string magic, extra; uint64_t version = 0, id = 0, length = 0, hash = 0;
      if (!(fields >> magic >> version >> id >> length >> hash) || fields >> extra ||
          magic != "EG2-OUTBOX" || version != 1 || !id || !length || length > 8*1024*1024) return false;
      std::string content(static_cast<size_t>(length), '\0');
      if (!input.read(content.data(), static_cast<std::streamsize>(length))) break;
      const auto separator = input.get();
      if (separator == EOF) break;
      if (separator != '\n') return false;
      std::string footer;
      if (!std::getline(input, footer) || input.eof()) break;
      if (footer != "EG2-END " + std::to_string(id) || Hash(content) != hash ||
          !content.ends_with(";; EG2 provider " + std::to_string(id) + "\n")) return false;
      const auto [found, inserted] = records->emplace(id, content);
      if (!inserted && found->second != content) return false;
    }
    return !input.bad();
  }
  bool Truncate() {
    HANDLE file = CreateFileW(Path().c_str(), GENERIC_WRITE, FILE_SHARE_READ,
        nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_WRITE_THROUGH, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;
    LARGE_INTEGER zero{};
    const bool ok = SetFilePointerEx(file, zero, nullptr, FILE_BEGIN) &&
        SetEndOfFile(file) && FlushFileBuffers(file);
    CloseHandle(file); return ok;
  }
  std::wstring target_;
  std::mutex mutex_;
  bool broken_ = false;
};
}
