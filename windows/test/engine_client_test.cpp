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
#include <atomic>
#include <chrono>
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
    char request_buffer[192] = {};
    DWORD read = 0;
    std::string session_prefix;
    for (const auto& exchange : std::array{
             std::pair{"ENGINE LIST\n", "ENGINES ddskk experimental"},
             std::pair{"ENGINE CURRENT\n", "ENGINE ddskk"},
             std::pair{"ENGINE SET experimental\n", "OK ENGINE experimental"},
             std::pair{"RESET\n", "STATE hiragana 0 -1 - - -1 -"},
             std::pair{"KEY 107\n", "STATE hiragana 0 -1 - 00006b -1 -"},
             std::pair{"CONTROL CONVERT-KEYS 75,97,110,97\n",
                       "STATE candidate 2 0 0025bc004eee00540d - 0 004eee00540d"}}) {
      read = 0;
      ZeroMemory(request_buffer, sizeof(request_buffer));
      if (!ReadFile(pipe, request_buffer, sizeof(request_buffer), &read, nullptr))
        std::abort();
      const std::string request(request_buffer, read);
      const std::string expected_request(exchange.first);
      const size_t command_at = request.find(expected_request);
      if (command_at == std::string::npos || command_at == 0 ||
          request.substr(0, 8) != "SESSION ") std::abort();
      const std::string prefix = request.substr(0, command_at);
      if (session_prefix.empty()) session_prefix = prefix;
      if (prefix != session_prefix ||
          command_at + expected_request.size() != request.size())
        std::abort();
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
  const auto reset = client.Reset(1000);
  assert(reset && reset->mode == L"hiragana" && reset->text.empty());
  auto state = client.SendKey(U'k', 1000);
  assert(state);
  assert(state->mode == L"hiragana");
  assert(state->text.empty());
  assert(state->pending_romaji == L"k");
  state = client.ConvertKeys(U"Kana", 1000);
  assert(state && state->mode == L"candidate" && state->text == L"▼仮名");
  client.Disconnect();
  server.join();
  CloseHandle(ready);

  // A provider timeout must never trap the UI behind the full transaction
  // deadline. CancelPendingIo is invoked by local Ctrl+G and interrupts an
  // already-issued overlapped read from another thread.
  constexpr wchar_t kHungPipe[] =
      L"\\\\.\\pipe\\ddskk-ime-client-hung-test-v1";
  assert(SetEnvironmentVariableW(L"DDSKK_PIPE_NAME", kHungPipe));
  HANDLE hung_ready = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  HANDLE request_seen = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  HANDLE release_server = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  assert(hung_ready && request_seen && release_server);
  std::thread hung_server([=] {
    HANDLE pipe = CreateNamedPipeW(
        kHungPipe, PIPE_ACCESS_DUPLEX,
        PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT, 1, 8192, 8192,
        1000, nullptr);
    assert(pipe != INVALID_HANDLE_VALUE);
    SetEvent(hung_ready);
    assert(ConnectNamedPipe(pipe, nullptr) ||
           GetLastError() == ERROR_PIPE_CONNECTED);
    char request[128]{};
    DWORD read = 0;
    assert(ReadFile(pipe, request, sizeof(request), &read, nullptr));
    SetEvent(request_seen);
    WaitForSingleObject(release_server, 5000);
    DisconnectNamedPipe(pipe);
    CloseHandle(pipe);
  });
  assert(WaitForSingleObject(hung_ready, 1000) == WAIT_OBJECT_0);
  ddskk::EngineClient hung_client;
  std::atomic<bool> returned{false};
  std::thread provider([&] {
    assert(!hung_client.ConvertKeys(U"Kana", 5000));
    returned.store(true, std::memory_order_release);
  });
  assert(WaitForSingleObject(request_seen, 1000) == WAIT_OBJECT_0);
  const auto cancel_started = std::chrono::steady_clock::now();
  hung_client.CancelPendingIo();
  provider.join();
  const auto cancel_elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now() - cancel_started);
  assert(returned.load(std::memory_order_acquire));
  assert(cancel_elapsed.count() < 100);
  SetEvent(release_server);
  hung_server.join();
  CloseHandle(hung_ready);
  CloseHandle(request_seen);
  CloseHandle(release_server);
}
