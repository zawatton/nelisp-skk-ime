#pragma once
#include "registry_settings.h"
#include <atomic>
#include <thread>

// The waiter never calls TSF/COM. The UI thread consumes the dirty flag only
// at an idle key/focus boundary. Stop joins before the service is destroyed.
class RegistryWatcher {
 public:
  ~RegistryWatcher() { Stop(); }
  void Start() {
    Stop();
    stop_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!stop_) return;
    HKEY key = nullptr;
    HANDLE changed = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!changed || RegOpenKeyExW(HKEY_CURRENT_USER,
        NativeImeRegistryKey().c_str(), 0, KEY_NOTIFY, &key) != ERROR_SUCCESS ||
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
        HANDLE waits[] = {stop_, changed};
        while (WaitForMultipleObjects(2, waits, FALSE, INFINITE) == WAIT_OBJECT_0 + 1) {
          const LSTATUS status = RegNotifyChangeKeyValue(key, TRUE,
              REG_NOTIFY_CHANGE_LAST_SET | REG_NOTIFY_CHANGE_NAME, changed, TRUE);
          dirty.store(true, std::memory_order_release);
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
  HANDLE stop_ = nullptr;
  std::thread worker_;
};
