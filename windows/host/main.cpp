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

// <winsock2.h> and <ws2tcpip.h> must be included before <windows.h>: if
// <windows.h> were included first without WIN32_LEAN_AND_MEAN, it would drag
// in the legacy <winsock.h>, whose declarations collide with <winsock2.h>.
// This build already defines WIN32_LEAN_AND_MEAN (see CMakeLists.txt), which
// on its own keeps <windows.h> from pulling in <winsock.h>, but the include
// order below is kept regardless so this file stays correct even if that
// define is ever dropped or the build options change.
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

#include <array>
#include <cstdio>
#include <string>

namespace {
constexpr wchar_t kPipeName[] = L"\\\\.\\pipe\\ddskk-ime-v1";

std::wstring PipeName() {
  wchar_t value[256]{};
  const DWORD size = GetEnvironmentVariableW(L"DDSKK_PIPE_NAME", value, 256);
  return size > 0 && size < 256 ? value : kPipeName;
}

bool UseNativeEntry() {
  wchar_t value[16]{};
  const DWORD size =
      GetEnvironmentVariableW(L"DDSKK_NELISP_ENTRY", value, 16);
  return size > 0 && size < 16 && _wcsicmp(value, L"native") == 0;
}

struct Child {
  HANDLE process = nullptr;
  HANDLE input = nullptr;
  HANDLE output = nullptr;
};

void Close(HANDLE& handle) {
  if (handle != nullptr && handle != INVALID_HANDLE_VALUE) CloseHandle(handle);
  handle = nullptr;
}

void StopChild(Child& child) {
  Close(child.input);
  Close(child.output);
  if (child.process != nullptr) {
    if (WaitForSingleObject(child.process, 500) == WAIT_TIMEOUT)
      TerminateProcess(child.process, 1);
    Close(child.process);
  }
}

bool WriteAll(HANDLE handle, const std::string& text) {
  size_t offset = 0;
  while (offset < text.size()) {
    DWORD written = 0;
    if (!WriteFile(handle, text.data() + offset,
                   static_cast<DWORD>(text.size() - offset), &written, nullptr) ||
        written == 0) return false;
    offset += written;
  }
  return true;
}

bool ReadLine(HANDLE handle, std::string* line) {
  line->clear();
  for (;;) {
    char value = 0;
    DWORD read = 0;
    if (!ReadFile(handle, &value, 1, &read, nullptr) || read != 1) return false;
    if (value == '\n') return true;
    if (value != '\r') line->push_back(value);
    if (line->size() > 65536) return false;
  }
}

bool StartChild(const std::wstring& engine, const std::wstring& repository,
                Child* child) {
  SECURITY_ATTRIBUTES security{sizeof(security), nullptr, TRUE};
  HANDLE stdout_read = nullptr, stdout_write = nullptr;
  HANDLE stdin_read = nullptr, stdin_write = nullptr;
  if (!CreatePipe(&stdout_read, &stdout_write, &security, 0) ||
      !CreatePipe(&stdin_read, &stdin_write, &security, 0)) return false;
  SetHandleInformation(stdout_read, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(stdin_write, HANDLE_FLAG_INHERIT, 0);

  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  startup.dwFlags = STARTF_USESTDHANDLES;
  startup.hStdInput = stdin_read;
  startup.hStdOutput = stdout_write;
  startup.hStdError = GetStdHandle(STD_ERROR_HANDLE);
  PROCESS_INFORMATION process{};
  std::wstring command = L"\"" + engine + L"\"";
  if (!repository.empty()) {
    command += UseNativeEntry()
                   ? L" --ddskk-ime-server engine/ddskk-engine-stdio.el"
                   : L" --load engine/ddskk-engine-stdio.el";
  }
  const wchar_t* working_directory =
      repository.empty() ? nullptr : repository.c_str();
  const BOOL started = CreateProcessW(
      nullptr, command.data(), nullptr, nullptr, TRUE, 0, nullptr,
      working_directory, &startup, &process);
  Close(stdin_read);
  Close(stdout_write);
  if (!started) {
    Close(stdout_read);
    Close(stdin_write);
    return false;
  }
  CloseHandle(process.hThread);
  child->process = process.hProcess;
  child->input = stdin_write;
  child->output = stdout_read;
  return true;
}

// ---------------------------------------------------------------------------
// SKK dictionary-server relay.
//
// The NeLisp engine cannot open TCP sockets itself, so when it needs a
// dictionary lookup it writes a line "SERVER <midasi>" on its own stdout
// (in place of a real response) and then blocks reading its stdin for the
// answer. This host process, which already owns both pipe ends to the
// engine and has full Winsock access, performs the lookup against a
// SKK dictionary server (skkserv-compatible, see registry config below) on
// the engine's behalf and writes the answer back to the engine's stdin.

struct DictionaryServerConfig {
  std::wstring host = L"127.0.0.1";
  DWORD port = 1178;
  DWORD enabled = 1;
};

// Cached across lookups so a fresh TCP connection is not paid on every
// keystroke; see LookupDictionary().
struct DictionaryServerState {
  bool winsock_ready = false;
  bool config_loaded = false;
  DictionaryServerConfig config;
  SOCKET socket = INVALID_SOCKET;
};

DictionaryServerState g_dictionary_server;

// Mirrors the RegOpenKeyExW/RegQueryValueExW idiom used by
// TextService::LoadSettings() in src/text_service.cpp: defaults are preset
// in the locals, RegQueryValueExW return values are ignored (a missing or
// unreadable value simply leaves the preset default in place), and the key
// is closed before returning.
void LoadDictionaryServerConfig(DictionaryServerConfig* config) {
  HKEY key = nullptr;
  wchar_t host[256] = L"127.0.0.1";
  DWORD host_bytes = sizeof(host);
  DWORD port = 1178, port_bytes = sizeof(port);
  DWORD enabled = 1, enabled_bytes = sizeof(enabled);
  if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\NativeIME", 0,
                    KEY_READ, &key) == ERROR_SUCCESS) {
    RegQueryValueExW(key, L"SkkServHost", nullptr, nullptr,
                     reinterpret_cast<BYTE*>(host), &host_bytes);
    RegQueryValueExW(key, L"SkkServPort", nullptr, nullptr,
                     reinterpret_cast<BYTE*>(&port), &port_bytes);
    RegQueryValueExW(key, L"SkkServEnable", nullptr, nullptr,
                     reinterpret_cast<BYTE*>(&enabled), &enabled_bytes);
    RegCloseKey(key);
  }
  config->host = host;
  config->port = port;
  config->enabled = enabled;
}

// The dictionary host name is read from the registry as UTF-16 (RegQueryValueExW)
// but getaddrinfo() takes a narrow (ANSI/UTF-8) hostname on all Windows
// versions this targets, so convert explicitly rather than relying on any
// ambient codepage.
std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) return std::string();
  const int size = WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, nullptr,
                                       0, nullptr, nullptr);
  if (size <= 0) return std::string();
  std::string result(static_cast<size_t>(size) - 1, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, result.data(), size,
                      nullptr, nullptr);
  return result;
}

bool EnsureWinsock() {
  if (g_dictionary_server.winsock_ready) return true;
  WSADATA data{};
  if (WSAStartup(MAKEWORD(2, 2), &data) != 0) return false;
  g_dictionary_server.winsock_ready = true;
  return true;
}

void CloseDictionarySocket() {
  if (g_dictionary_server.socket != INVALID_SOCKET) {
    closesocket(g_dictionary_server.socket);
    g_dictionary_server.socket = INVALID_SOCKET;
  }
}

// Resolves and connects to the configured dictionary server. Returns
// INVALID_SOCKET on any failure (bad hostname, connection refused, etc.).
// Note: connect() itself is not bounded by the SO_RCVTIMEO/SO_SNDTIMEO set
// below (those only cover send()/recv() after the connection is up), so a
// server whose TCP stack accepts SYNs but never completes the handshake
// could still stall for the OS-level connect timeout; the intended target
// is a local/LAN skkserv, where that is not expected to happen in practice.
SOCKET ConnectDictionaryServer(const DictionaryServerConfig& config) {
  const std::string host_utf8 = WideToUtf8(config.host);
  const std::string port_text = std::to_string(config.port);

  ADDRINFOA hints{};
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_protocol = IPPROTO_TCP;
  ADDRINFOA* result = nullptr;
  if (getaddrinfo(host_utf8.c_str(), port_text.c_str(), &hints, &result) != 0)
    return INVALID_SOCKET;

  SOCKET socket_handle = INVALID_SOCKET;
  for (const ADDRINFOA* candidate = result; candidate != nullptr;
       candidate = candidate->ai_next) {
    socket_handle = socket(candidate->ai_family, candidate->ai_socktype,
                           candidate->ai_protocol);
    if (socket_handle == INVALID_SOCKET) continue;
    if (connect(socket_handle, candidate->ai_addr,
               static_cast<int>(candidate->ai_addrlen)) == 0) {
      break;
    }
    closesocket(socket_handle);
    socket_handle = INVALID_SOCKET;
  }
  freeaddrinfo(result);
  if (socket_handle == INVALID_SOCKET) return INVALID_SOCKET;

  const DWORD timeout_ms = 1000;
  setsockopt(socket_handle, SOL_SOCKET, SO_RCVTIMEO,
            reinterpret_cast<const char*>(&timeout_ms), sizeof(timeout_ms));
  setsockopt(socket_handle, SOL_SOCKET, SO_SNDTIMEO,
            reinterpret_cast<const char*>(&timeout_ms), sizeof(timeout_ms));
  return socket_handle;
}

// Sends `request` in full and reads a single line (up to '\n', which is
// consumed but not included in *raw_response; a trailing '\r' is stripped
// too). Returns false on any send/recv error, timeout, graceful close, or
// if the line exceeds the 64 KiB cap -- the caller treats all of those as
// "retry with a fresh connection, then give up".
bool SendAndReceive(SOCKET socket_handle, const std::string& request,
                    std::string* raw_response) {
  size_t offset = 0;
  while (offset < request.size()) {
    const int sent = send(socket_handle, request.data() + offset,
                          static_cast<int>(request.size() - offset), 0);
    if (sent <= 0) return false;
    offset += static_cast<size_t>(sent);
  }

  raw_response->clear();
  char buffer[4096];
  for (;;) {
    const int received = recv(socket_handle, buffer, sizeof(buffer), 0);
    if (received <= 0) return false;  // 0 = peer closed, <0 = error/timeout
    raw_response->append(buffer, static_cast<size_t>(received));
    const size_t newline = raw_response->find('\n');
    if (newline != std::string::npos) {
      raw_response->erase(newline);
      break;
    }
    if (raw_response->size() > 65536) return false;
  }
  while (!raw_response->empty() && raw_response->back() == '\r')
    raw_response->pop_back();
  return true;
}

// Looks up `midasi` (already UTF-8 encoded by the engine; not transcoded
// here) against the configured dictionary server and returns the single
// line to hand back to the engine: the server's raw "1/cand/cand/.../"
// answer on success, or "4" for not-found / disabled / any failure. Never
// throws and never blocks longer than the configured send/recv timeouts
// (plus, in the worst case, one OS-level connect timeout on the retry --
// see ConnectDictionaryServer()).
std::string LookupDictionary(const std::string& midasi) {
  try {
    if (!g_dictionary_server.config_loaded) {
      LoadDictionaryServerConfig(&g_dictionary_server.config);
      g_dictionary_server.config_loaded = true;
    }
    if (g_dictionary_server.config.enabled == 0) return "4";
    if (!EnsureWinsock()) return "4";

    const std::string request = "1" + midasi + " ";
    std::string raw_response;

    // Up to two attempts total: reuse (or make) the cached connection, and
    // on any failure drop it and retry exactly once with a fresh one.
    for (int attempt = 0; attempt < 2; ++attempt) {
      if (g_dictionary_server.socket == INVALID_SOCKET)
        g_dictionary_server.socket = ConnectDictionaryServer(g_dictionary_server.config);
      if (g_dictionary_server.socket == INVALID_SOCKET) continue;
      if (SendAndReceive(g_dictionary_server.socket, request, &raw_response) &&
          !raw_response.empty()) {
        return raw_response;
      }
      CloseDictionarySocket();
    }
    return "4";
  } catch (...) {
    return "4";
  }
}

void ShutdownDictionaryServer() {
  CloseDictionarySocket();
  if (g_dictionary_server.winsock_ready) {
    WSACleanup();
    g_dictionary_server.winsock_ready = false;
  }
}
// ---------------------------------------------------------------------------

bool Dispatch(Child& child, const std::string& request, std::string* response) {
  if (!WriteAll(child.input, request + "\n")) return false;
  // Bounded guard: a buggy/adversarial engine that keeps emitting
  // "SERVER " lines instead of ever producing a real response must not be
  // able to wedge this loop (and thus the whole host) forever.
  constexpr int kMaxServerExchangesPerRequest = 64;
  int server_exchanges = 0;
  for (;;) {
    std::string line;
    if (!ReadLine(child.output, &line)) return false;
    if (line.rfind("SERVER ", 0) == 0) {
      // Out-of-band dictionary lookup: answer it and keep reading for the
      // real response. The engine blocks on its stdin until this arrives.
      if (++server_exchanges > kMaxServerExchangesPerRequest) return false;
      const std::string reply = LookupDictionary(line.substr(7));
      if (!WriteAll(child.input, reply + "\n")) return false;
      continue;
    }
    *response = line;
    return true;
  }
}
}  // namespace

int wmain(int argc, wchar_t** argv) {
  if (argc != 2 && argc != 3) {
    std::fwprintf(stderr,
                  L"usage: ddskk-engine-host ENGINE_EXE [REPOSITORY]\n");
    return 2;
  }
  Child child;
  const std::wstring repository = argc == 3 ? argv[2] : L"";
  if (!StartChild(argv[1], repository, &child)) {
    StopChild(child);
    return 3;
  }
  const std::wstring pipe_name = PipeName();
  HANDLE pipe = CreateNamedPipeW(
      pipe_name.c_str(), PIPE_ACCESS_DUPLEX,
      PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT,
      1, 8192, 8192, 0, nullptr);
  if (pipe == INVALID_HANDLE_VALUE) {
    StopChild(child);
    return 4;
  }
  bool stopping = false;
  while (!stopping) {
    if (!ConnectNamedPipe(pipe, nullptr) && GetLastError() != ERROR_PIPE_CONNECTED)
      break;
    bool connected = true;
    while (connected) {
      std::array<char, 8192> request_buffer{};
      DWORD read = 0;
      if (!ReadFile(pipe, request_buffer.data(),
                    static_cast<DWORD>(request_buffer.size()), &read, nullptr)) break;
      std::string request(request_buffer.data(), read);
      while (!request.empty() && (request.back() == '\n' || request.back() == '\r'))
        request.pop_back();
      std::string response;
      if (request == "SHUTDOWN") {
        response = "OK";
        stopping = true;
      } else if (!Dispatch(child, request, &response)) {
        connected = false;
        break;
      }
      DWORD written = 0;
      connected = WriteFile(pipe, response.data(), static_cast<DWORD>(response.size()),
                            &written, nullptr) && written == response.size();
      if (stopping) connected = false;
    }
    FlushFileBuffers(pipe);
    DisconnectNamedPipe(pipe);
    if (WaitForSingleObject(child.process, 0) != WAIT_TIMEOUT) break;
  }
  CloseHandle(pipe);
  StopChild(child);
  ShutdownDictionaryServer();
  return 0;
}
