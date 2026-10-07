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
#include <cstdio>
#include <string>
#include <thread>
#include <windows.h>

#ifdef NDEBUG
#undef assert
#define assert(condition) ((condition) ? static_cast<void>(0) : std::abort())
#endif

int main() {
  wchar_t private_pipe[256]{};
  assert(GetEnvironmentVariableW(L"DDSKK_PIPE_NAME", private_pipe, _countof(private_pipe)) > 0);
  const wchar_t* kTestPipe = private_pipe;
  HANDLE ready = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  assert(ready != nullptr);
  std::thread server([ready, kTestPipe] {
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
             std::pair{"ENGINE SET lattice\n", "OK SWITCHING lattice"},
             std::pair{"ENGINE RELOAD\n", "OK RELOADING"},
             std::pair{"RESET\n", "STATE hiragana 0 -1 - - -1 -"},
             std::pair{"KEY 107\n", "STATE hiragana 0 -1 - 00006b -1 -"},
             std::pair{"OPEN 2\n", "ERR REQUEST"},
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
    read = 0;
    ZeroMemory(request_buffer, sizeof(request_buffer));
    if (!ReadFile(pipe, request_buffer, sizeof(request_buffer), &read, nullptr) ||
        std::string(request_buffer, read) != "PREVIEW e3818be381aa\n")
      std::abort();
    const std::string preview = "PREVIEW /仮名/佳奈;name/";
    DWORD written = 0;
    if (!WriteFile(pipe, preview.data(), static_cast<DWORD>(preview.size()),
                   &written, nullptr) || written != preview.size()) std::abort();
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
  assert(client.SelectEngine("lattice", 1000));
  assert(client.ReloadEngine(1000));
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
  const auto preview = client.PreviewCandidates(L"かな", 1000);
  assert(preview && preview->size() == 2 && (*preview)[0] == L"仮名" &&
         (*preview)[1] == L"佳奈;name");
  client.Disconnect();
  server.join();
  CloseHandle(ready);

  // Version 2 on a real private pipe: eviction recovery and old-engine
  // replacement preserve the uncommitted candidate navigation history.
  HANDLE persistent_ready = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  std::thread persistent_server([=] {
    HANDLE pipe = CreateNamedPipeW(kTestPipe, PIPE_ACCESS_DUPLEX,
        PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT, 1, 8192, 8192, 1000, nullptr);
    assert(pipe != INVALID_HANDLE_VALUE);
    SetEvent(persistent_ready);
    assert(ConnectNamedPipe(pipe, nullptr) || GetLastError() == ERROR_PIPE_CONNECTED);
    for (const auto& exchange : std::array{
        std::pair{"OPEN 2\n", "OK OPEN 2"},
        std::pair{"V2 PREPARE 2 75,97,110,97\n", "STATE hiragana 3 0 0025bd00304b00306a - -1 -"},
        std::pair{"V2 SPACE 2\n", "STATE candidate 2 0 0025bc004eee00540d - 0 004eee00540d,004f73004808"},
        std::pair{"V2 CONTROL CONVERT\n", "ERR SESSION LOST"},
        std::pair{"OPEN 2\n", "OK OPEN 2"},
        std::pair{"V2 PREPARE 2 75,97,110,97\n", "STATE hiragana 3 0 0025bd00304b00306a - -1 -"},
        std::pair{"V2 SPACE 2\n", "STATE candidate 2 0 0025bc004eee00540d - 0 004eee00540d,004f73004808"},
        std::pair{"V2 CONTROL CONVERT\n", "STATE candidate 2 0 0025bc004f73004808 - 1 004eee00540d,004f73004808"},
        std::pair{"V2 CONTROL PREVIOUS\n", "ERR REQUEST"},
        std::pair{"RESET", "STATE hiragana 0 -1 - - -1 -"},
        std::pair{"SYNC-KEYS 75,97,110,97\n", "STATE candidate 2 0 0025bc004eee00540d - 0 004eee00540d,004f73004808"},
        std::pair{"CONTROL CONVERT", "STATE candidate 2 0 0025bc004eee00540d - 0 004eee00540d,004f73004808"},
        std::pair{"CONTROL CONVERT\n", "STATE candidate 2 0 0025bc004f73004808 - 1 004eee00540d,004f73004808"},
        std::pair{"CONTROL PREVIOUS\n", "STATE candidate 2 0 0025bc004eee00540d - 0 004eee00540d,004f73004808"}}) {
      char buffer[512]{}; DWORD read = 0, written = 0;
      assert(ReadFile(pipe, buffer, sizeof(buffer), &read, nullptr));
      const std::string request(buffer, read);
      if (!request.starts_with("SESSION ") || request.find(exchange.first) == std::string::npos)
        std::fprintf(stderr, "Persistent request mismatch expected=%s actual=%s\n", exchange.first, request.c_str());
      assert(request.starts_with("SESSION ") && request.find(exchange.first) != std::string::npos);
      const std::string response(exchange.second);
      assert(WriteFile(pipe, response.data(), static_cast<DWORD>(response.size()), &written, nullptr));
    }
    FlushFileBuffers(pipe); DisconnectNamedPipe(pipe); CloseHandle(pipe);
  });
  assert(WaitForSingleObject(persistent_ready, 1000) == WAIT_OBJECT_0);
  ddskk::EngineClient persistent;
  assert(persistent.PrepareKeys(U"Kana", 1000));
  assert(persistent.ConvertKeys(U"Kana", 1000)->candidate_index == 0);
  assert(persistent.SendControl(ddskk::EngineControl::kConvert, 1000)->candidate_index == 1);
  assert(persistent.SendControl(ddskk::EngineControl::kPrevious, 1000)->candidate_index == 0);
  persistent.Disconnect(); persistent_server.join(); CloseHandle(persistent_ready);

  // Abandoning a refused edit must rebuild even an already-prepared reading.
  HANDLE recovery_ready = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  std::atomic<bool> recovery_matched{true};
  std::thread recovery_server([&] {
    HANDLE pipe = CreateNamedPipeW(kTestPipe, PIPE_ACCESS_DUPLEX,
        PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT, 1, 8192, 8192, 1000, nullptr);
    assert(pipe != INVALID_HANDLE_VALUE);
    SetEvent(recovery_ready);
    assert(ConnectNamedPipe(pipe, nullptr) || GetLastError() == ERROR_PIPE_CONNECTED);
    for (const char* expected : {"OPEN 2", "V2 PREPARE 2 75,97,110,97", "RESET",
                                 "V2 CONVERT-LIVE 2 75,97,110,97"}) {
      char buffer[512]{}; DWORD count = 0;
      assert(ReadFile(pipe, buffer, sizeof(buffer), &count, nullptr));
      const std::string request(buffer, count);
      if (request.find(expected) == std::string::npos) {
        recovery_matched = false;
        std::fprintf(stderr, "Abandon recovery expected=%s actual=%s", expected, request.c_str());
      }
      const std::string reply = std::string(expected) == "OPEN 2" ? "OK OPEN 2"
          : "STATE hiragana 0 -1 - - -1 -";
      assert(WriteFile(pipe, reply.data(), static_cast<DWORD>(reply.size()), &count, nullptr));
    }
    FlushFileBuffers(pipe); DisconnectNamedPipe(pipe); CloseHandle(pipe);
  });
  assert(WaitForSingleObject(recovery_ready, 1000) == WAIT_OBJECT_0);
  ddskk::EngineClient abandoned;
  assert(abandoned.PrepareKeys(U"Kana", 1000));
  abandoned.MarkNeedsResync();
  assert(abandoned.ConvertKeys(U"Kana", 1000));
  abandoned.Disconnect(); recovery_server.join(); CloseHandle(recovery_ready);
  assert(recovery_matched);

  int failures = 0;
  client.SetConnectionFailureHandler([&failures] { ++failures; });
  assert(!client.Reset(2));
  assert(failures == 1);
  assert(!client.ConvertKeys(U"Ka", 2));
  assert(failures == 2);  // Negotiation preserves host-start notification.
  client.SetConnectionFailureHandler({});

  // A provider timeout must never trap the UI behind the full transaction
  // deadline. CancelPendingIo is invoked by local Ctrl+G and interrupts an
  // already-issued overlapped read from another thread.
  const std::wstring hung_pipe = std::wstring(private_pipe) + L"-hung";
  const wchar_t* kHungPipe = hung_pipe.c_str();
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
