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
#include <atomic>
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

EngineClient::EngineClient() {
  static std::atomic<uint64_t> next_session{1};
  session_id_ = std::to_string(GetCurrentProcessId()) + "-" +
                std::to_string(next_session.fetch_add(1));
}

std::string EngineClient::SessionRequest(const std::string& request) const {
  std::string line = request;
  while (!line.empty() && (line.back() == '\n' || line.back() == '\r'))
    line.pop_back();
  return "SESSION " + session_id_ + " " + line + "\n";
}

EngineClient::~EngineClient() { Disconnect(); }

bool EngineClient::Connect(DWORD timeout_ms) {
  if (pipe_.load(std::memory_order_acquire) != INVALID_HANDLE_VALUE) return true;
  const std::wstring pipe_name = PipeName();
  if (!WaitNamedPipeW(pipe_name.c_str(), timeout_ms)) return false;
  // FILE_FLAG_OVERLAPPED is required so Transact()/RawTransact() can bound
  // WriteFile/ReadFile with timeout_ms via WaitForSingleObject; without it
  // both calls block indefinitely regardless of any timeout passed here.
  HANDLE opened = CreateFileW(pipe_name.c_str(), GENERIC_READ | GENERIC_WRITE,
                              0, nullptr, OPEN_EXISTING,
                              FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OVERLAPPED,
                              nullptr);
  if (opened == INVALID_HANDLE_VALUE) return false;
  pipe_.store(opened, std::memory_order_release);
  DWORD mode = PIPE_READMODE_MESSAGE;
  if (!SetNamedPipeHandleState(opened, &mode, nullptr, nullptr)) {
    Disconnect();
    return false;
  }
  return true;
}

void EngineClient::Disconnect() {
  const HANDLE pipe = pipe_.exchange(INVALID_HANDLE_VALUE,
                                     std::memory_order_acq_rel);
  if (pipe != INVALID_HANDLE_VALUE) CloseHandle(pipe);
}

void EngineClient::CancelPendingIo() {
  const HANDLE pipe = pipe_.load(std::memory_order_acquire);
  if (pipe != INVALID_HANDLE_VALUE) CancelIoEx(pipe, nullptr);
}

void EngineClient::MarkNeedsResync() { needs_resync_ = true; }

std::optional<std::string> EngineClient::Transact(const std::string& request,
                                                  DWORD timeout_ms) {
  last_response_.clear();
  if (!Connect(timeout_ms)) return std::nullopt;
  if (needs_resync_) {
    // A previous transaction on an earlier connection may have timed out
    // (or hit an I/O error) after the request had already reached the
    // host; the host can still be processing it and mutate the shared
    // engine session after we stopped listening for the reply. RESET on
    // this fresh connection forces the session back to a known-empty
    // state first, so the display here and the engine's actual state
    // can't silently diverge. Only clear needs_resync_ once RESET itself
    // is confirmed to have gone through -- if it fails too, RawTransact()
    // has already disconnected us again and the flag stays set for the
    // next attempt.
    const auto reset = RawTransact(SessionRequest("RESET"), timeout_ms);
    if (!reset) return std::nullopt;
    needs_resync_ = false;
  }
  auto response = RawTransact(SessionRequest(request), timeout_ms);
  if (response) last_response_ = *response;
  return response;
}

std::optional<std::string> EngineClient::RawTransact(const std::string& request,
                                                      DWORD timeout_ms) {
  const HANDLE pipe = pipe_.load(std::memory_order_acquire);
  if (pipe == INVALID_HANDLE_VALUE) return std::nullopt;
  OVERLAPPED overlapped{};
  overlapped.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (overlapped.hEvent == nullptr) return std::nullopt;

  // Cancels whatever is still in flight and waits for the cancellation (or
  // a late completion) to actually land -- CancelIoEx is asynchronous, and
  // the OVERLAPPED/response buffers must outlive it -- before
  // disconnecting and flagging the session for a resync on the next
  // Transact(). Only valid once an operation has actually been queued to
  // the driver (WriteFile/ReadFile returned TRUE, or FALSE with
  // ERROR_IO_PENDING); otherwise there is nothing pending to cancel and
  // GetOverlappedResult(..., TRUE) below would block forever waiting on a
  // completion event nobody will ever signal.
  const auto cancel_pending_and_fail = [this, pipe, &overlapped] {
    CancelIoEx(pipe, &overlapped);
    DWORD ignored = 0;
    GetOverlappedResult(pipe, &overlapped, &ignored, TRUE);
    CloseHandle(overlapped.hEvent);
    Disconnect();
    needs_resync_ = true;
  };
  // Used when WriteFile/ReadFile failed outright (anything other than
  // ERROR_IO_PENDING): nothing was queued, so skip the cancel/wait dance
  // above -- it would hang on the never-to-be-signaled event.
  const auto fail_immediately = [this, &overlapped] {
    CloseHandle(overlapped.hEvent);
    Disconnect();
    needs_resync_ = true;
  };

  DWORD written = 0;
  if (!WriteFile(pipe, request.data(), static_cast<DWORD>(request.size()),
                 &written, &overlapped) &&
      GetLastError() != ERROR_IO_PENDING) {
    fail_immediately();
    return std::nullopt;
  }
  // Whether WriteFile completed synchronously or is still pending, the
  // event is signaled on completion either way, so waiting here is safe
  // (and returns immediately in the synchronous case).
  if (WaitForSingleObject(overlapped.hEvent, timeout_ms) != WAIT_OBJECT_0 ||
      !GetOverlappedResult(pipe, &overlapped, &written, FALSE) ||
      written != request.size()) {
    cancel_pending_and_fail();
    return std::nullopt;
  }

  ResetEvent(overlapped.hEvent);
  std::array<char, 8192> response{};
  DWORD read = 0;
  if (!ReadFile(pipe, response.data(), static_cast<DWORD>(response.size() - 1),
               &read, &overlapped) &&
      GetLastError() != ERROR_IO_PENDING) {
    fail_immediately();
    return std::nullopt;
  }
  if (WaitForSingleObject(overlapped.hEvent, timeout_ms) != WAIT_OBJECT_0 ||
      !GetOverlappedResult(pipe, &overlapped, &read, FALSE)) {
    cancel_pending_and_fail();
    return std::nullopt;
  }
  CloseHandle(overlapped.hEvent);
  return std::string(response.data(), read);
}

std::optional<EngineState> EngineClient::SendKey(char32_t codepoint,
                                                  DWORD timeout_ms) {
  const std::string request = EncodeKeyRequest(codepoint);
  if (request.empty()) return std::nullopt;
  const auto response = Transact(request, timeout_ms);
  return response ? ParseStateResponse(*response) : std::nullopt;
}

std::optional<EngineState> EngineClient::ConvertKeys(
    const std::u32string& keys, DWORD timeout_ms) {
  const std::string request = EncodeConvertKeysRequest(keys);
  if (request.empty()) return std::nullopt;
  const auto response = Transact(request, timeout_ms);
  return response ? ParseStateResponse(*response) : std::nullopt;
}

std::optional<EngineState> EngineClient::SendKeys(
    const std::u32string& keys, DWORD timeout_ms) {
  const std::string request = EncodeFeedKeysRequest(keys);
  if (request.empty()) return std::nullopt;
  const auto response = Transact(request, timeout_ms);
  return response ? ParseStateResponse(*response) : std::nullopt;
}

std::optional<EngineState> EngineClient::Reset(DWORD timeout_ms) {
  const auto response = Transact("RESET\n", timeout_ms);
  // RESET is the recovery primitive.  If even it cannot complete (including
  // failure before a pipe connection is established), the next successful
  // transaction must try RESET first rather than continuing a possibly
  // stranded candidate/registration session.
  if (!response) needs_resync_ = true;
  return response ? ParseStateResponse(*response) : std::nullopt;
}

std::optional<EngineState> EngineClient::SendControl(EngineControl control,
                                                     DWORD timeout_ms) {
  const auto response = Transact(EncodeControlRequest(control), timeout_ms);
  return response ? ParseStateResponse(*response) : std::nullopt;
}

std::optional<std::vector<std::wstring>> EngineClient::PreviewCandidates(
    const std::wstring& reading, DWORD timeout_ms) {
  if (reading.empty() || !Connect(timeout_ms)) return std::nullopt;
  const int utf8_size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
      reading.data(), static_cast<int>(reading.size()), nullptr, 0, nullptr,
      nullptr);
  if (utf8_size <= 0) return std::nullopt;
  std::string utf8(static_cast<size_t>(utf8_size), '\0');
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, reading.data(),
      static_cast<int>(reading.size()), utf8.data(), utf8_size, nullptr,
      nullptr) != utf8_size) return std::nullopt;
  static constexpr char hex[] = "0123456789abcdef";
  std::string request = "PREVIEW ";
  request.reserve(request.size() + utf8.size() * 2 + 1);
  for (const unsigned char value : utf8) {
    request.push_back(hex[value >> 4]);
    request.push_back(hex[value & 0x0f]);
  }
  request.push_back('\n');
  const auto response = RawTransact(request, timeout_ms);
  if (!response || !response->starts_with("PREVIEW ")) return std::nullopt;
  if (*response == "PREVIEW -") return std::vector<std::wstring>{};
  std::vector<std::wstring> candidates;
  const std::string_view raw(response->data() + 8, response->size() - 8);
  size_t start = 0;
  while (start <= raw.size()) {
    size_t end = raw.find('/', start);
    if (end == std::string_view::npos) end = raw.size();
    if (end > start) {
      const std::string_view candidate = raw.substr(start, end - start);
      const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
          candidate.data(), static_cast<int>(candidate.size()), nullptr, 0);
      if (size <= 0) return std::nullopt;
      std::wstring wide(static_cast<size_t>(size), L'\0');
      if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
          candidate.data(), static_cast<int>(candidate.size()), wide.data(),
          size) != size) return std::nullopt;
      candidates.push_back(std::move(wide));
    }
    if (end >= raw.size()) break;
    start = end + 1;
  }
  return candidates;
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

bool EngineClient::Ping(DWORD timeout_ms) {
  return Transact("GC\n", timeout_ms).has_value();
}

}  // namespace ddskk
