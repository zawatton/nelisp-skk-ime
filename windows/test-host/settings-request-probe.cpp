// Compiles the actual ShowSettings body extracted by test-resident-settings.ps1.
// ShellExecuteEx supplies the child handle so the test owns all spawned UIs.
#define UNICODE
#define _UNICODE
#include <windows.h>
#include <shellapi.h>
#include <cstdio>
#include <cstring>
#include <string>
#include "../../windows/src/registry_settings.h"
HMODULE g_module = nullptr;
int launches = 0;
bool hang_request = false;
HINSTANCE ObservedShellExecute(HWND parent, LPCWSTR verb, LPCWSTR file,
                               LPCWSTR args, LPCWSTR dir, int show) {
  SHELLEXECUTEINFOW info{};
  info.cbSize = sizeof(info);
  info.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI;
  info.hwnd = parent; info.lpVerb = verb; info.lpFile = file;
  info.lpParameters = args; info.lpDirectory = dir; info.nShow = show;
  ++launches;
  const BOOL ok = ShellExecuteExW(&info);
  if (info.hProcess) {
    std::printf("SPAWN pid=%lu\n", GetProcessId(info.hProcess));
    CloseHandle(info.hProcess);
  }
  return ok ? info.hInstApp : reinterpret_cast<HINSTANCE>(31);
}
#define ShellExecuteW ObservedShellExecute
struct TextService { void ShowSettings(); };
#include "ShowSettings.inc"
LRESULT CALLBACK RejectRequest(HWND window, UINT message, WPARAM wp, LPARAM lp) {
  if (message == RegisterWindowMessageW(L"NativeIME.Sumi.ShowSettings.v1")) {
    if (hang_request) Sleep(1500);
    return 0;
  }
  return DefWindowProcW(window, message, wp, lp);
}
int main(int argc, char** argv) {
  const std::wstring identity = NativeImeRegistryKey();
  if (!identity.starts_with(L"Software\\NativeIME-Tests\\SN1-")) return 2;
  if (argc > 1) {
    hang_request = std::strcmp(argv[1], "--hang") == 0;
    WNDCLASSW cls{};
    cls.lpfnWndProc = RejectRequest; cls.hInstance = GetModuleHandleW(nullptr);
    cls.lpszClassName = L"NeLispSumiSettingsV1";
    if (!RegisterClassW(&cls)) return 3;
    if (!CreateWindowExW(0, cls.lpszClassName, identity.c_str(), 0, 0,0,0,0,
                         HWND_MESSAGE, nullptr, cls.hInstance, nullptr)) return 4;
    std::puts("READY reject-endpoint"); std::fflush(stdout);
    MSG message{};
    while (GetMessageW(&message, nullptr, 0, 0) > 0) DispatchMessageW(&message);
    return 0;
  }
  TextService service;
  service.ShowSettings();
  std::printf("REQUEST launches=%d\n", launches);
  return 0;
}
