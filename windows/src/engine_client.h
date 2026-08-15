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

#pragma once

#include "engine_protocol.h"

#include <optional>
#include <string>
#include <windows.h>

namespace ddskk {

class EngineClient {
 public:
  EngineClient() = default;
  ~EngineClient();
  EngineClient(const EngineClient&) = delete;
  EngineClient& operator=(const EngineClient&) = delete;

  bool Connect(DWORD timeout_ms = 25);
  void Disconnect();
  std::optional<EngineState> SendKey(char32_t codepoint, DWORD timeout_ms = 25);
  std::optional<EngineState> SendControl(EngineControl control,
                                         DWORD timeout_ms = 25);
  std::optional<std::vector<std::string>> ListEngines(DWORD timeout_ms = 1000);
  std::optional<std::string> CurrentEngine(DWORD timeout_ms = 1000);
  bool SelectEngine(const std::string& engine_id, DWORD timeout_ms = 1000);
  // Sends a lightweight "GC\n" request and reports whether the host
  // answered within timeout_ms. Used by TextService::Activate's warm-up
  // thread to pay the engine's cold-load cost off the UI thread instead of
  // on the user's first keystroke.
  bool Ping(DWORD timeout_ms);

 private:
  std::optional<std::string> Transact(const std::string& request,
                                      DWORD timeout_ms);
  // One write followed by one read over the already-connected pipe_, using
  // overlapped I/O + WaitForSingleObject so timeout_ms actually bounds both
  // directions (plain blocking WriteFile/ReadFile ignore timeout_ms
  // entirely -- the caller-visible bug this fixes). On timeout or I/O
  // error this cancels the pending I/O, disconnects, and sets
  // needs_resync_ so the next Transact() resynchronizes the session before
  // sending anything else.
  std::optional<std::string> RawTransact(const std::string& request,
                                         DWORD timeout_ms);
  HANDLE pipe_ = INVALID_HANDLE_VALUE;
  // Set whenever a transaction is abandoned mid-flight (timeout or I/O
  // error) after the request was already written to the pipe. The host may
  // still be sitting on that request and could apply it to the shared
  // engine session after we have stopped listening for the reply, so the
  // *next* Transact() call must send "RESET\n" first -- otherwise the
  // display state here and the engine's actual state could silently
  // diverge with no way to tell.
  bool needs_resync_ = false;
};

}  // namespace ddskk
