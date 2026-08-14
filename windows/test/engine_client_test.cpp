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
#include <array>
#include <cstdlib>
#include <string>
#include <thread>
#include <windows.h>

#ifdef NDEBUG
#undef assert
#define assert(condition) ((condition) ? static_cast<void>(0) : std::abort())
#endif

int main() {
  constexpr wchar_t kTestPipe[] = L"\\\\.\\pipe\\ddskk-ime-client-test-v1";
  assert(SetEnvironmentVariableW(L"DDSKK_PIPE_NAME", kTestPipe));
  HANDLE ready = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  assert(ready != nullptr);
  std::thread server([ready] {
    HANDLE pipe = CreateNamedPipeW(
        kTestPipe, PIPE_ACCESS_DUPLEX,
        PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT, 1, 8192, 8192,
        1000, nullptr);
    assert(pipe != INVALID_HANDLE_VALUE);
    SetEvent(ready);
    assert(ConnectNamedPipe(pipe, nullptr) ||
           GetLastError() == ERROR_PIPE_CONNECTED);
    char request_buffer[64] = {};
    DWORD read = 0;
    for (const auto& exchange : std::array{
             std::pair{"ENGINE LIST\n", "ENGINES ddskk experimental"},
             std::pair{"ENGINE CURRENT\n", "ENGINE ddskk"},
             std::pair{"ENGINE SET experimental\n", "OK ENGINE experimental"},
             std::pair{"KEY 107\n", "STATE hiragana 0 -1 - 00006b -1 -"}}) {
      read = 0;
      ZeroMemory(request_buffer, sizeof(request_buffer));
      if (!ReadFile(pipe, request_buffer, sizeof(request_buffer), &read, nullptr) ||
          std::string(request_buffer, read) != exchange.first) std::abort();
      DWORD written = 0;
      const std::string response = exchange.second;
      if (!WriteFile(pipe, response.data(), static_cast<DWORD>(response.size()),
                     &written, nullptr) || written != response.size()) std::abort();
    }
    FlushFileBuffers(pipe);
    DisconnectNamedPipe(pipe);
    CloseHandle(pipe);
  });

  assert(WaitForSingleObject(ready, 1000) == WAIT_OBJECT_0);
  ddskk::EngineClient client;
  const auto engines = client.ListEngines(1000);
  assert(engines && engines->size() == 2 && (*engines)[0] == "ddskk");
  assert(client.CurrentEngine(1000) == "ddskk");
  assert(client.SelectEngine("experimental", 1000));
  assert(!client.SelectEngine("invalid id", 1000));
  auto state = client.SendKey(U'k', 1000);
  assert(state);
  assert(state->mode == L"hiragana");
  assert(state->text.empty());
  assert(state->pending_romaji == L"k");
  client.Disconnect();
  server.join();
  CloseHandle(ready);
}
