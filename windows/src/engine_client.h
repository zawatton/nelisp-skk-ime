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

 private:
  std::optional<std::string> Transact(const std::string& request,
                                      DWORD timeout_ms);
  HANDLE pipe_ = INVALID_HANDLE_VALUE;
};

}  // namespace ddskk
