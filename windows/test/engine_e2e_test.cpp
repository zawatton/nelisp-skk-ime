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
#include <cstdio>
#include <cstdlib>
#include <string>
#include <tlhelp32.h>
#include <windows.h>

#ifdef NDEBUG
#undef assert
#define assert(condition) ((condition) ? static_cast<void>(0) : std::abort())
#endif

namespace {
constexpr wchar_t kTestPipe[] = L"\\\\.\\pipe\\ddskk-ime-e2e-v1";

PROCESS_INFORMATION StartHost(wchar_t** argv) {
  std::fprintf(stderr, "E2E: starting host\n");
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
  std::fprintf(stderr, "E2E: host ready pid=%lu\n", process.dwProcessId);
  return process;
}

DWORD FindChildProcess(DWORD parent_pid) {
  const HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) return 0;
  PROCESSENTRY32W entry{};
  entry.dwSize = sizeof(entry);
  DWORD child_pid = 0;
  if (Process32FirstW(snapshot, &entry)) {
    do {
      if (entry.th32ParentProcessID == parent_pid) {
        child_pid = entry.th32ProcessID;
        break;
      }
    } while (Process32NextW(snapshot, &entry));
  }
  CloseHandle(snapshot);
  return child_pid;
}

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

int SessionCount() {
  HANDLE pipe = CreateFileW(kTestPipe, GENERIC_READ | GENERIC_WRITE, 0,
                            nullptr, OPEN_EXISTING, 0, nullptr);
  if (pipe == INVALID_HANDLE_VALUE) return -1;
  constexpr char request[] = "DIAG SESSION-COUNT";
  DWORD written = 0;
  if (!WriteFile(pipe, request, sizeof(request) - 1, &written, nullptr)) {
    CloseHandle(pipe);
    return -1;
  }
  char response[64]{};
  DWORD read = 0;
  const bool ok = ReadFile(pipe, response, sizeof(response) - 1, &read, nullptr);
  CloseHandle(pipe);
  if (!ok) return -1;
  int count = -1;
  return sscanf_s(std::string(response, read).c_str(), "SESSIONS %d",
                  &count) == 1 ? count : -1;
}

bool WaitForSessionCount(int expected) {
  const auto deadline = std::chrono::steady_clock::now() +
                        std::chrono::seconds(5);
  do {
    if (SessionCount() == expected) return true;
    Sleep(10);
  } while (std::chrono::steady_clock::now() < deadline);
  return false;
}
}

int wmain(int argc, wchar_t** argv) {
  assert(argc == 4);
  assert(SetEnvironmentVariableW(L"DDSKK_PIPE_NAME", kTestPipe));
  const std::wstring fixture = std::wstring(argv[3]) +
      L"\\windows\\test-host\\data\\behavior-jisyo.utf8";
  assert(SetEnvironmentVariableW(L"DDSKK_DICTIONARY_FILES", fixture.c_str()));
  assert(SetEnvironmentVariableW(L"DDSKK_SKKSERV_ENABLE", L"0"));
  PROCESS_INFORMATION process = StartHost(argv);
  ddskk::EngineClient client;
  std::optional<ddskk::EngineState> state;
  for (const char32_t key : std::u32string(U"k")) {
    const auto started = std::chrono::steady_clock::now();
    state = client.SendKey(key, 10000);
    assert(state);
    const auto elapsed = std::chrono::steady_clock::now() - started;
    // Cold DDSKK load varies between roughly 5 and 12 seconds on this
    // machine; responsiveness is provided by the native frontend while it
    // warms.  This E2E only requires the explicit 10-second request budget.
    assert(elapsed < std::chrono::seconds(10));
  }
  assert(state->mode == L"hiragana");
  assert(state->text.empty());
  assert(state->pending_romaji == L"k");
  const auto preview = client.PreviewCandidates(L"かな", 1000);
  assert(preview && !preview->empty() && (*preview)[0] == L"仮名");
  // Model the four production targets (Notepad = client, plus Edge,
  // Windows Terminal and Emacs) as four simultaneous cross-pipe clients.
  // Each pending romaji must resume independently when requests interleave.
  {
    ddskk::EngineClient edge;
    ddskk::EngineClient terminal;
    ddskk::EngineClient emacs;
    auto edge_state = edge.SendKey(U'n', 10000);
    auto terminal_state = terminal.SendKey(U'm', 10000);
    auto emacs_state = emacs.SendKey(U's', 10000);
    assert(edge_state && edge_state->pending_romaji == L"n");
    assert(terminal_state && terminal_state->pending_romaji == L"m");
    assert(emacs_state && emacs_state->pending_romaji == L"s");
    assert(WaitForSessionCount(4));
    state = client.SendKey(U'a', 10000);
    edge_state = edge.SendKey(U'a', 10000);
    terminal_state = terminal.SendKey(U'a', 10000);
    emacs_state = emacs.SendKey(U'a', 10000);
    assert(state && state->text == L"か" && state->pending_romaji.empty());
    assert(edge_state && edge_state->text == L"な");
    assert(terminal_state && terminal_state->text == L"ま");
    assert(emacs_state && emacs_state->text == L"さ");
  }
  // Destroying three target applications closes their pipes. The host must
  // close the corresponding provider checkpoints rather than accumulating
  // one session for every application activation over a long uptime.
  assert(WaitForSessionCount(1));
  assert(client.Reset(10000));
  state = client.ConvertKeys(U"Kana", 10000);
  if (!state) {
    std::fprintf(stderr, "ConvertKeys raw response: [%s]\n",
                 client.last_response().c_str());
  }
  assert(state);
  std::fwprintf(stderr, L"ConvertKeys state mode=%ls start=%d text=[%ls]\n",
                state->mode.c_str(), state->composition_start,
                state->text.c_str());
  assert(state->mode == L"candidate");
  assert(state->composition_start >= 0);
  std::fprintf(stderr, "E2E: normal conversion complete\n");

  const auto okuri_started = std::chrono::steady_clock::now();
  state = client.ConvertKeys(U"KieRu", 10000);
  const auto okuri_elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now() - okuri_started);
  std::fprintf(stderr, "Okuri ConvertKeys elapsed=%lldms\n",
               static_cast<long long>(okuri_elapsed.count()));
  if (!state) {
    std::fprintf(stderr, "Okuri ConvertKeys raw response: [%s]\n",
                 client.last_response().c_str());
  }
  assert(state);
  std::fwprintf(stderr, L"Okuri state mode=%ls start=%d text=[%ls]\n",
                state->mode.c_str(), state->composition_start,
                state->text.c_str());
  assert(state->mode == L"candidate");
  assert(state->composition_start >= 0);

  // Killing the provider must fail the in-flight transaction cleanly, stop
  // the now-useless host, and let this same application/client reconnect to
  // a fresh host without restarting the target application.
  DWORD child_pid = 0;
  const auto child_deadline = std::chrono::steady_clock::now() +
                              std::chrono::seconds(5);
  do {
    child_pid = FindChildProcess(process.dwProcessId);
    if (child_pid == 0) Sleep(10);
  } while (child_pid == 0 && std::chrono::steady_clock::now() < child_deadline);
  assert(child_pid != 0);
  std::fprintf(stderr, "E2E: terminating child pid=%lu\n", child_pid);
  const HANDLE child = OpenProcess(PROCESS_TERMINATE | SYNCHRONIZE, FALSE,
                                   child_pid);
  assert(child != nullptr);
  assert(TerminateProcess(child, 77));
  assert(WaitForSingleObject(child, 5000) == WAIT_OBJECT_0);
  CloseHandle(child);
  std::fprintf(stderr, "E2E: child terminated; probing failure\n");
  assert(!client.SendKey(U'x', 1000));
  std::fprintf(stderr, "E2E: transaction failed cleanly; waiting host\n");
  assert(WaitForSingleObject(process.hProcess, 5000) == WAIT_OBJECT_0);
  CloseHandle(process.hProcess);

  std::fprintf(stderr, "E2E: old host exited; restarting\n");
  process = StartHost(argv);
  state = client.SendKey(U'a', 10000);
  assert(state && state->text == L"あ");
  assert(WaitForSessionCount(1));
  std::fprintf(stderr, "E2E: same client recovered\n");

  client.Disconnect();
  assert(WaitForSessionCount(0));
  std::fprintf(stderr, "E2E: requesting clean shutdown\n");
  const bool shutdown_requested = ShutdownHost();
  std::fprintf(stderr, "E2E: shutdown request=%d\n", shutdown_requested ? 1 : 0);
  if (!shutdown_requested) TerminateProcess(process.hProcess, 1);
  const DWORD shutdown_wait = WaitForSingleObject(process.hProcess, 5000);
  std::fprintf(stderr, "E2E: shutdown wait=%lu\n", shutdown_wait);
  assert(shutdown_wait == WAIT_OBJECT_0);
  DWORD exit_code = 1;
  assert(GetExitCodeProcess(process.hProcess, &exit_code));
  std::fprintf(stderr, "E2E: shutdown exit=%lu\n", exit_code);
  assert(exit_code == 0 || !shutdown_requested);
  CloseHandle(process.hProcess);
}
