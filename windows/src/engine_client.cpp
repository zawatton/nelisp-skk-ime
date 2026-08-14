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

#include <array>
#include <sstream>

namespace ddskk {
namespace {
constexpr wchar_t kPipeName[] = L"\\\\.\\pipe\\ddskk-ime-v1";
std::wstring PipeName() {
  wchar_t value[256]{};
  const DWORD size = GetEnvironmentVariableW(L"DDSKK_PIPE_NAME", value, 256);
  return size > 0 && size < 256 ? value : kPipeName;
}
}

EngineClient::~EngineClient() { Disconnect(); }

bool EngineClient::Connect(DWORD timeout_ms) {
  if (pipe_ != INVALID_HANDLE_VALUE) return true;
  const std::wstring pipe_name = PipeName();
  if (!WaitNamedPipeW(pipe_name.c_str(), timeout_ms)) return false;
  pipe_ = CreateFileW(pipe_name.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (pipe_ == INVALID_HANDLE_VALUE) return false;
  DWORD mode = PIPE_READMODE_MESSAGE;
  if (!SetNamedPipeHandleState(pipe_, &mode, nullptr, nullptr)) {
    Disconnect();
    return false;
  }
  return true;
}

void EngineClient::Disconnect() {
  if (pipe_ != INVALID_HANDLE_VALUE) {
    CloseHandle(pipe_);
    pipe_ = INVALID_HANDLE_VALUE;
  }
}

std::optional<std::string> EngineClient::Transact(const std::string& request,
                                                  DWORD timeout_ms) {
  if (!Connect(timeout_ms)) return std::nullopt;
  DWORD written = 0;
  if (!WriteFile(pipe_, request.data(), static_cast<DWORD>(request.size()),
                 &written, nullptr) || written != request.size()) {
    Disconnect();
    return std::nullopt;
  }
  std::array<char, 8192> response{};
  DWORD read = 0;
  if (!ReadFile(pipe_, response.data(), static_cast<DWORD>(response.size() - 1),
                &read, nullptr)) {
    Disconnect();
    return std::nullopt;
  }
  std::string result(response.data(), read);
  return result;
}

std::optional<EngineState> EngineClient::SendKey(char32_t codepoint,
                                                 DWORD timeout_ms) {
  const std::string request = EncodeKeyRequest(codepoint);
  if (request.empty()) return std::nullopt;
  const auto response = Transact(request, timeout_ms);
  return response ? ParseStateResponse(*response) : std::nullopt;
}

std::optional<EngineState> EngineClient::SendControl(EngineControl control,
                                                     DWORD timeout_ms) {
  const auto response = Transact(EncodeControlRequest(control), timeout_ms);
  return response ? ParseStateResponse(*response) : std::nullopt;
}

std::optional<std::vector<std::string>> EngineClient::ListEngines(
    DWORD timeout_ms) {
  const auto response = Transact("ENGINE LIST\n", timeout_ms);
  if (!response || !response->starts_with("ENGINES ")) return std::nullopt;
  std::istringstream input(response->substr(8));
  std::vector<std::string> engines;
  for (std::string id; input >> id;) engines.push_back(std::move(id));
  return engines;
}

std::optional<std::string> EngineClient::CurrentEngine(DWORD timeout_ms) {
  const auto response = Transact("ENGINE CURRENT\n", timeout_ms);
  if (!response || !response->starts_with("ENGINE ")) return std::nullopt;
  return response->substr(7);
}

bool EngineClient::SelectEngine(const std::string& engine_id, DWORD timeout_ms) {
  if (engine_id.empty() || engine_id.find_first_not_of(
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_") !=
      std::string::npos) return false;
  const auto response = Transact("ENGINE SET " + engine_id + "\n", timeout_ms);
  return response && *response == "OK ENGINE " + engine_id;
}

}  // namespace ddskk
