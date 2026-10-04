#include "registry_watcher.h"
#include <cassert>
#include <cstdlib>

#ifdef NDEBUG
#undef assert
#define assert(condition) ((condition) ? static_cast<void>(0) : std::abort())
#endif

int main() {
  const auto key_path = NativeImeRegistryKey();
  assert(key_path.starts_with(L"Software\\NativeIME-test-"));
  HKEY key = nullptr;
  assert(RegOpenKeyExW(HKEY_CURRENT_USER, key_path.c_str(), 0,
                      KEY_SET_VALUE | KEY_CREATE_SUB_KEY, &key) == ERROR_SUCCESS);
  RegistryWatcher watcher;
  watcher.Start();
  watcher.dirty.store(false);
  // Repeat writes to cover the thread's initial notification registration.
  // A broken override/watch implementation never observes our private key.
  const ULONGLONG deadline = GetTickCount64() + 2000;
  while (!watcher.dirty.load() && GetTickCount64() < deadline) {
    const DWORD value = static_cast<DWORD>(GetTickCount64());
    assert(RegSetValueExW(key, L"InitialKanaMode", 0, REG_DWORD,
        reinterpret_cast<const BYTE*>(&value), sizeof(value)) == ERROR_SUCCESS);
    Sleep(20);
  }
  assert(watcher.dirty.exchange(false));
  // Telemetry beneath Clients must not reset modes on the next idle key.
  Sleep(100);
  watcher.dirty.store(false);
  HKEY client = nullptr;
  assert(RegCreateKeyExW(key, L"Clients\\123", 0, nullptr, 0,
      KEY_SET_VALUE, nullptr, &client, nullptr) == ERROR_SUCCESS);
  const DWORD sequence = 1;
  assert(RegSetValueExW(client, L"sequence", 0, REG_DWORD,
      reinterpret_cast<const BYTE*>(&sequence), sizeof(sequence)) == ERROR_SUCCESS);
  RegCloseKey(client);
  Sleep(100);
  assert(!watcher.dirty.load());
  watcher.Stop();
  RegCloseKey(key);
}
