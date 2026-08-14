// Copyright (C) 2026 nelisp-skk-ime contributors
//
// This program is free software: you can redistribute it and/or
// modify it under the terms of the GNU General Public License as
// published by the Free Software Foundation, either version 3 of
// the License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be
// useful, but WITHOUT ANY WARRANTY; without even the implied
// warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
// PURPOSE.  See the GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

#include "engine_client.h"

#include <cassert>
#include <chrono>
#include <cstdlib>
#include <string>
#include <windows.h>

namespace {
constexpr wchar_t kTestPipe[] = L"\\\\.\\pipe\\ddskk-ime-e2e-v1";
bool ShutdownHost() {
  HANDLE pipe = INVALID_HANDLE_VALUE;
  const auto deadline = std::chrono::steady_clock::now() +
                        std::chrono::seconds(5);
  do {
    pipe = CreateFileW(kTestPipe, GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                       OPEN_EXISTING, 0, nullptr);
    if (pipe != INVALID_HANDLE_VALUE) break;
    WaitNamedPipeW(kTestPipe, 100);
    Sleep(10);
  } while (std::chrono::steady_clock::now() < deadline);
  if (pipe == INVALID_HANDLE_VALUE) return false;
  constexpr char request[] = "SHUTDOWN";
  DWORD written = 0;
  if (!WriteFile(pipe, request, sizeof(request) - 1, &written, nullptr)) {
    CloseHandle(pipe);
    return false;
  }
  char response[8]{};
  DWORD read = 0;
  const bool ok = ReadFile(pipe, response, sizeof(response), &read, nullptr) &&
                  std::string(response, read) == "OK";
  CloseHandle(pipe);
  return ok;
}
}

#ifdef NDEBUG
#undef assert
#define assert(condition) ((condition) ? static_cast<void>(0) : std::abort())
#endif

int wmain(int argc, wchar_t** argv) {
  assert(argc == 4);
  assert(SetEnvironmentVariableW(L"DDSKK_PIPE_NAME", kTestPipe));
  std::wstring command = L"\"" + std::wstring(argv[1]) + L"\" \"" +
                         argv[2] + L"\" \"" + argv[3] + L"\"";
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  assert(CreateProcessW(nullptr, command.data(), nullptr, nullptr, FALSE,
                        0, nullptr, argv[3], &startup, &process));
  CloseHandle(process.hThread);
  const auto pipe_deadline = std::chrono::steady_clock::now() +
                             std::chrono::seconds(90);
  while (!WaitNamedPipeW(kTestPipe, 250)) {
    assert(std::chrono::steady_clock::now() < pipe_deadline);
    assert(WaitForSingleObject(process.hProcess, 0) == WAIT_TIMEOUT);
    Sleep(25);
  }
  ddskk::EngineClient client;
  std::optional<ddskk::EngineState> state;
  for (const char32_t key : std::u32string(U"k")) {
    const auto started = std::chrono::steady_clock::now();
    state = client.SendKey(key, 10000);
    assert(state);
    const auto elapsed = std::chrono::steady_clock::now() - started;
    assert(elapsed < std::chrono::seconds(5));
  }
  assert(state->mode == L"hiragana");
  assert(state->text.empty());
  assert(state->pending_romaji == L"k");
  client.Disconnect();
  const bool shutdown_requested = ShutdownHost();
  if (!shutdown_requested) TerminateProcess(process.hProcess, 1);
  assert(WaitForSingleObject(process.hProcess, 5000) == WAIT_OBJECT_0);
  DWORD exit_code = 1;
  assert(GetExitCodeProcess(process.hProcess, &exit_code));
  assert(exit_code == 0 || !shutdown_requested);
  CloseHandle(process.hProcess);
}
