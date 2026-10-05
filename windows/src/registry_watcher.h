#pragma once
#include "registry_settings.h"
#include <atomic>
#include <thread>
#include <vector>
#include <algorithm>

// Clients is telemetry, never a settings reload. All hashing runs on the
// watcher thread, not in a TSF key callback.
inline uint64_t NativeImeSettingsFingerprint(HKEY key, bool root = true, bool include_core = true) {
  uint64_t hash = 14695981039346656037ULL;
  const auto mix = [&hash](const void* data, size_t size) {
    const auto* bytes = static_cast<const unsigned char*>(data);
    for (size_t i = 0; i < size; ++i) { hash ^= bytes[i]; hash *= 1099511628211ULL; }
  };
  DWORD max_name = 0, max_data = 0, max_subkey = 0;
  RegQueryInfoKeyW(key, nullptr, nullptr, nullptr, nullptr, &max_subkey,
      nullptr, nullptr, &max_name, &max_data, nullptr, nullptr);
  std::vector<wchar_t> name((std::max)(max_name, max_subkey) + 2);
  std::vector<BYTE> data(max_data + 1);
  for (DWORD i = 0;; ++i) {
    DWORD length = static_cast<DWORD>(name.size()), size = static_cast<DWORD>(data.size()), type = 0;
    if (RegEnumValueW(key, i, name.data(), &length, nullptr, &type,
                     data.data(), &size) != ERROR_SUCCESS) break;
    if (root && !include_core && _wcsicmp(name.data(), L"CoreDll") == 0) continue;
    mix(name.data(), length * sizeof(wchar_t)); mix(&type, sizeof(type)); mix(data.data(), size);
  }
  for (DWORD i = 0;; ++i) {
    DWORD length = static_cast<DWORD>(name.size());
    if (RegEnumKeyExW(key, i, name.data(), &length, nullptr, nullptr,
                     nullptr, nullptr) != ERROR_SUCCESS) break;
    if (root && _wcsicmp(name.data(), L"Clients") == 0) continue;
    mix(name.data(), length * sizeof(wchar_t));
    HKEY child = nullptr;
    if (RegOpenKeyExW(key, name.data(), 0, KEY_READ, &child) == ERROR_SUCCESS) {
      const uint64_t child_hash = NativeImeSettingsFingerprint(child, false, include_core);
      mix(&child_hash, sizeof(child_hash)); RegCloseKey(child);
    }
  }
  return hash;
}

// The waiter never calls TSF/COM. The UI thread consumes the dirty flag only
// at an idle key/focus boundary. Stop joins before the service is destroyed.
class RegistryWatcher {
 public:
  explicit RegistryWatcher(bool include_core = true) : include_core_(include_core) {}
  ~RegistryWatcher() { Stop(); }
  void Start() {
    Stop();
    stop_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!stop_) return;
    HKEY key = nullptr;
    HANDLE changed = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!changed || RegOpenKeyExW(HKEY_CURRENT_USER,
        NativeImeRegistryKey().c_str(), 0, KEY_NOTIFY | KEY_READ, &key) != ERROR_SUCCESS ||
        RegNotifyChangeKeyValue(key, TRUE,
            REG_NOTIFY_CHANGE_LAST_SET | REG_NOTIFY_CHANGE_NAME,
            changed, TRUE) != ERROR_SUCCESS) {
      if (key) RegCloseKey(key);
      if (changed) CloseHandle(changed);
      Stop();
      return;
    }
    // Cover a write between the initial LoadSettings and this first arm.
    dirty.store(true);
    try {
      worker_ = std::thread([this, key, changed] {
        uint64_t fingerprint = NativeImeSettingsFingerprint(key, true, include_core_);
        HANDLE waits[] = {stop_, changed};
        while (WaitForMultipleObjects(2, waits, FALSE, INFINITE) == WAIT_OBJECT_0 + 1) {
          const LSTATUS status = RegNotifyChangeKeyValue(key, TRUE,
              REG_NOTIFY_CHANGE_LAST_SET | REG_NOTIFY_CHANGE_NAME, changed, TRUE);
          const uint64_t next = NativeImeSettingsFingerprint(key, true, include_core_);
          if (next != fingerprint) dirty.store(true, std::memory_order_release);
          fingerprint = next;
          if (status != ERROR_SUCCESS) break;
        }
        RegCloseKey(key);
        CloseHandle(changed);
      });
    } catch (...) {
      RegCloseKey(key);
      CloseHandle(changed);
      Stop();
    }
  }
  void Stop() {
    if (stop_) SetEvent(stop_);
    if (worker_.joinable()) worker_.join();
    if (stop_) CloseHandle(stop_);
    stop_ = nullptr;
  }
  std::atomic<bool> dirty{false};
 private:
  bool include_core_;
  HANDLE stop_ = nullptr;
  std::thread worker_;
};
