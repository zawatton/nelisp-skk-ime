#include <windows.h>
// An actual pipe transfer and blocking wait for the import-probe control.
extern "C" __declspec(dllexport) void CallbackIoFixture(HANDLE read, HANDLE write, HANDLE event) {
  DWORD count = 0;
  char bytes[3]{};
  WriteFile(write, "abc", 3, &count, nullptr);
  ReadFile(read, bytes, 3, &count, nullptr);
  WaitForSingleObject(event, 1);
}
