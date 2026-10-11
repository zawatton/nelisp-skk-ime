// Real EngineClient launch control; one real host with a tiny stdio test engine.
#include "engine_client.h"
#include <windows.h>
#include <cstdio>
#include <iostream>
#include <string>
#include <vector>
void Check(bool value, const char* message) {
  if (!value) { std::fprintf(stderr, "FAIL %s error=%lu\n", message, GetLastError()); std::exit(2); }
}
std::wstring Self() { wchar_t path[32768]{}; GetModuleFileNameW(nullptr, path, 32768); return path; }
HANDLE OpenPipe(const std::wstring& pipe) {
  const auto deadline = GetTickCount64() + 5000;
  do {
    if (WaitNamedPipeW(pipe.c_str(), 50)) {
      HANDLE handle = CreateFileW(pipe.c_str(), GENERIC_READ | GENERIC_WRITE, 0,
          nullptr, OPEN_EXISTING, 0, nullptr);
      if (handle != INVALID_HANDLE_VALUE) return handle;
    }
    Sleep(1);
  } while (GetTickCount64() < deadline);
  return INVALID_HANDLE_VALUE;
}
int wmain(int argc, wchar_t** argv) {
  if (argc > 1 && std::wstring(argv[1]) == L"--client") {
    HANDLE event = OpenEventW(SYNCHRONIZE, FALSE, argv[4]);
    Check(event && WaitForSingleObject(event, 5000) == WAIT_OBJECT_0, "launch barrier");
    CloseHandle(event);
    return ddskk::EngineClient::TryStartHost(argv[2], Self(), argv[3], ddskk::EngineClient::Endpoint()) ? 1 : 0;
  }
  if (argc > 1 && std::wstring(argv[1]) == L"--busy") {
    const auto pipe = ddskk::EngineClient::Endpoint();
    HANDLE server = CreateNamedPipeW(pipe.c_str(), PIPE_ACCESS_DUPLEX,
        PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT, 1, 4096, 4096, 0, nullptr);
    Check(server != INVALID_HANDLE_VALUE, "busy fixture server");
    HANDLE client = CreateFileW(pipe.c_str(), GENERIC_READ | GENERIC_WRITE, 0,
        nullptr, OPEN_EXISTING, 0, nullptr);
    Check(client != INVALID_HANDLE_VALUE, "busy fixture client");
    ddskk::EngineClient engine;
    Check(!engine.Connect(1), "busy connect must fail");
    Check(engine.ConnectionError() == ERROR_SEM_TIMEOUT || engine.ConnectionError() == ERROR_PIPE_BUSY,
          "busy error preserved");
    Check(!ddskk::EngineClient::TryStartHost(argv[2], Self(), argv[3], pipe), "busy pipe never spawns");
    CloseHandle(client); DisconnectNamedPipe(server); CloseHandle(server);
    std::puts("PASS busy_pipe_spawns=0"); return 0;
  }
  if (argc > 1 && std::wstring(argv[1]) == L"--run") {
    const auto pipe = ddskk::EngineClient::Endpoint();
    const auto event_name = L"Local\\eh8-start-" + std::to_wstring(GetCurrentProcessId());
    HANDLE event = CreateEventW(nullptr, TRUE, FALSE, event_name.c_str());
    Check(event != nullptr, "barrier event");
    std::vector<HANDLE> clients;
    for (int i = 0; i < 6; ++i) {
      std::wstring command = L"\"" + Self() + L"\" --client \"" + argv[2] + L"\" \"" + argv[3] + L"\" " + event_name;
      STARTUPINFOW startup{}; startup.cb = sizeof(startup);
      startup.dwFlags = STARTF_USESHOWWINDOW; startup.wShowWindow = SW_HIDE;
      PROCESS_INFORMATION process{};
      Check(CreateProcessW(nullptr, command.data(), nullptr, nullptr, FALSE, 0, nullptr,
                           nullptr, &startup, &process), "launch client");
      CloseHandle(process.hThread); clients.push_back(process.hProcess);
    }
    SetEvent(event);
    unsigned spawns = 0;
    for (HANDLE client : clients) {
      Check(WaitForSingleObject(client, 10000) == WAIT_OBJECT_0, "client exits");
      DWORD code = 0; GetExitCodeProcess(client, &code); CloseHandle(client);
      Check(code <= 1, "client result"); spawns += code;
    }
    CloseHandle(event); Check(spawns == 1, "exactly one host launch");
    // Rapid clients deliberately send nothing and disappear immediately.
    for (unsigned i = 0; i < 300; ++i) {
      HANDLE client = OpenPipe(pipe); Check(client != INVALID_HANDLE_VALUE, "accept burst alive");
      CloseHandle(client);
    }
    Sleep(100);
    Check(!ddskk::EngineClient::TryStartHost(argv[2], Self(), argv[3], pipe), "singleton suppresses launch");
    HANDLE client = OpenPipe(pipe); Check(client != INVALID_HANDLE_VALUE, "host survived burst");
    const char request[] = "SHUTDOWN\n"; DWORD written = 0;
    Check(WriteFile(client, request, sizeof(request)-1, &written, nullptr), "shutdown write");
    CloseHandle(client);
    std::puts("PASS startup clients=6 host_spawns=1 burst_clients=300 host_survived=1 singleton_spawns=0");
    return 0;
  }
  // Host invokes this executable with --load runner flags. This is only a
  // protocol fixture, never a production engine or a conversion test.
  std::string line;
  while (std::getline(std::cin, line)) std::cout << "ERR REQUEST\n" << std::flush;
  return 0;
}
