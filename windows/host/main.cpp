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
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <string>
#include <thread>

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

// The settings UI (docs/design/sumi-indicator-settings.md, the 辞書 tab)
// stores the user dictionary path and save-batch size as
// HKCU\Software\NativeIME\UserJisyoPath (REG_SZ) and \UserJisyoBatch
// (REG_DWORD); engine/skk-user-jisyo.el instead reads them from the
// engine child's own environment, as DDSKK_USER_JISYO and
// DDSKK_USER_JISYO_SAVE_BATCH_SIZE. This bridges registry -> env right
// before the child is spawned (CreateProcessW below inherits this
// process's environment when lpEnvironment is nullptr, which it is), but
// only fills in a variable that is not already set: every existing test
// harness sets these env vars directly for private-jisyo isolation, and
// leaving an already-set value alone keeps every one of them working
// unchanged.
void ApplyUserJisyoEnvFromRegistry() {
  HKEY key = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\NativeIME", 0, KEY_READ,
                    &key) != ERROR_SUCCESS) return;

  // GetEnvironmentVariableW(name, nullptr, 0) returns 0 only when the
  // variable is absent (a present-but-empty value still needs a 1-char
  // buffer for the terminating null, so it returns 1); this is a pure
  // presence check, no probe buffer required.
  if (GetEnvironmentVariableW(L"DDSKK_USER_JISYO", nullptr, 0) == 0) {
    wchar_t path[32768]{};
    DWORD path_bytes = sizeof(path);
    if (RegQueryValueExW(key, L"UserJisyoPath", nullptr, nullptr,
                         reinterpret_cast<BYTE*>(path), &path_bytes) ==
            ERROR_SUCCESS &&
        path[0] != L'\0') {
      SetEnvironmentVariableW(L"DDSKK_USER_JISYO", path);
    }
  }

  if (GetEnvironmentVariableW(L"DDSKK_USER_JISYO_SAVE_BATCH_SIZE", nullptr,
                              0) == 0) {
    DWORD batch = 0, batch_bytes = sizeof(batch);
    if (RegQueryValueExW(key, L"UserJisyoBatch", nullptr, nullptr,
                         reinterpret_cast<BYTE*>(&batch), &batch_bytes) ==
        ERROR_SUCCESS) {
      SetEnvironmentVariableW(L"DDSKK_USER_JISYO_SAVE_BATCH_SIZE",
                              std::to_wstring(batch).c_str());
    }
  }

  RegCloseKey(key);
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
  ApplyUserJisyoEnvFromRegistry();
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

// ---------------------------------------------------------------------------
// Multi-client serving.
//
// The named pipe is created with PIPE_UNLIMITED_INSTANCES so more than one
// application can hold an open connection at once. Previously it was
// created with nMaxInstances = 1: a single client that connected and never
// disconnected (observed in practice as a background process's embedded
// browser control activating the text service and never deactivating it)
// permanently held the only instance, so every other application's
// EngineClient::Connect() failed and its keystrokes fell through
// untranslated. Each connected instance is now accepted on the main thread
// and handed off to its own detached worker thread in ServeClient().
//
// All connections share exactly one `g_child` NeLisp process, which holds a
// single SKK session (composition state, kana mode, the session buffer) --
// two clients interleaving requests would corrupt it. `g_engine_mutex`
// makes each client's request/response transaction atomic with respect to
// the others: it is held for the entire Dispatch() call, which already
// contains the nested "SERVER " dictionary-lookup sub-exchange loop (and
// therefore LookupDictionary()'s cached socket in g_dictionary_server), so
// a dictionary round trip can never be interleaved with another client's
// request either. The same mutex is held while tearing the child down on
// shutdown (see wmain), so its pipes are never closed out from under a
// worker thread that is still mid-transaction.
// ---------------------------------------------------------------------------
Child g_child;
std::mutex g_engine_mutex;
std::atomic<bool> g_stopping{false};
std::wstring g_pipe_name;  // Set once in wmain before any thread starts.

// Forward declaration: defined below (just above ServeClient()), used by
// IdleGcLoop() immediately below this point.
void RequestStop();

// ---------------------------------------------------------------------------
// Idle-triggered GC.
//
// The NeLisp engine has no automatic collector (`gc-cons-threshold' is
// unbound in this standalone runtime), so ddskk-engine.el used to run an
// explicit `garbage-collect' at every confirmed-word boundary. That kept
// memory flat but cost ~180 ms extra on every single CONTROL COMMIT (this
// runtime's collector is a semispace copier whose cost tracks the ~311 MB
// live heap, not the amount of garbage produced) -- unacceptable for an
// IME. The fix implemented here moves that same collection off the
// request/response critical path entirely: this host now decides WHEN to
// collect, based on when its own named pipe goes quiet, and asks the
// engine to do it via an explicit "GC" protocol line (see the "GC
// scheduling" comment in engine/ddskk-engine.el) that the engine answers
// like any other request.
//
// Ordering argument for why an incoming keystroke can never queue up
// behind a GC that had not yet started:
//
//   `NoteActivity()' stamps `g_last_activity_tick' the instant a
//   request's `ReadFile()' returns in `ServeClient()' -- BEFORE that
//   request even tries to acquire `g_engine_mutex', let alone before it
//   is dispatched. `IdleGcLoop()' below only ever attempts a collection
//   after independently observing, itself, that the pipe has been quiet
//   for `IdleGcIntervalMs()' -- and it re-checks that observation a
//   SECOND time immediately after acquiring `g_engine_mutex' (a real
//   request may have been dispatched, and thus called `NoteActivity()',
//   while this thread was waiting for the lock). So the moment any
//   keystroke's `ReadFile()' returns, `g_last_activity_tick' is already
//   fresh, and every subsequent freshness check this loop makes -- both
//   the cheap one before taking the lock and the authoritative one after
//   -- will see that and decline to fire. The ONLY way a keystroke can
//   still be delayed is if this thread has ALREADY taken
//   `g_engine_mutex' and is already inside `Dispatch(g_child, "GC", ...)'
//   at the moment the keystroke's own `Dispatch()' call tries to acquire
//   that same mutex -- i.e. a GC that had genuinely already started, not
//   one merely decided upon or pending. That one case is unavoidable
//   (the whole point of sharing `g_engine_mutex' is that a GC and a real
//   request can never interleave, so once a GC has actually started
//   something has to wait), and it is exactly the case the task
//   description itself carves out as acceptable.
//
// Only one GC per idle period: `g_gc_pending' is cleared (via
// `exchange') the moment a collection actually runs, and is only set
// back to true by the next `NoteActivity()' call, i.e. the next real
// request. `IdleGcLoop()' polls on a plain `sleep_for' rather than a
// condition variable -- at a 100 ms tick this is not a busy spin (it
// sleeps essentially all the time), and it bounds shutdown latency
// exactly the same way `StopChild()''s existing 500 ms
// `WaitForSingleObject' timeout already does elsewhere in this file, so
// `g_stopping' is never invisible to this thread for more than one tick.
//
// Composition-in-progress suppression: measured GC cost on the live
// engine is 523-920 ms per collection, and the single worst moment for
// one to start is right after the user pauses on a candidate (SPACE) to
// read it before pressing Enter -- that Enter is the very next request,
// and without this check it would queue up behind a GC that just started
// (observed in the wild as a consistent ~1.4 s stall, twice, in the DLL
// debug log). `g_session_composing' tracks whether the last STATE reply
// on the ServeClient() request path reported mode "preedit" or
// "candidate" (see ServeClient()); IdleGcLoop() below refuses to collect
// at all while it is true, checked both before and after acquiring
// `g_engine_mutex' for the same "may have changed while this thread
// waited for the lock" reason as the idle-freshness re-check.
constexpr DWORD kIdleGcPollMs = 100;
constexpr DWORD kDefaultIdleGcMs = 800;

std::atomic<uint64_t> g_last_activity_tick{0};
std::atomic<bool> g_gc_pending{false};
// True once at least one real client transaction has completed. Gates
// `IdleGcLoop()' so it can never fire while DDSKK is still doing its own
// multi-second synchronous load at process startup (before any client has
// ever connected, there is nothing to collect and no reason to contend
// for `g_engine_mutex' against the first real client's own request).
std::atomic<bool> g_engine_active{false};
// True when the last STATE reply on the ServeClient() request path
// reported mode "preedit" or "candidate" -- i.e. DDSKK is mid-composition
// and the user may be reading a candidate before their next keystroke.
// See the "Composition-in-progress suppression" paragraph in the block
// comment above IdleGcLoop() for why this gates collection.
std::atomic<bool> g_session_composing{false};

void NoteActivity() {
  g_last_activity_tick.store(GetTickCount64(), std::memory_order_release);
  g_gc_pending.store(true, std::memory_order_release);
  g_engine_active.store(true, std::memory_order_release);
}

// Mirrors LoadDictionaryServerConfig()'s idiom exactly: env var checked
// first (lets a benchmarking harness override the interval per-run
// without touching the registry, matching PipeName()/UseNativeEntry()'s
// env-first pattern above), then the registry, then the measured default.
// Result is cached after the first call -- this is read on every 100 ms
// poll tick, so it must not hit the registry that often.
DWORD IdleGcIntervalMs() {
  static DWORD cached_ms = 0;
  if (cached_ms != 0) return cached_ms;

  wchar_t env_value[16]{};
  const DWORD env_size =
      GetEnvironmentVariableW(L"DDSKK_ENGINE_IDLE_GC_MS", env_value, 16);
  if (env_size > 0 && env_size < 16) {
    const int parsed = _wtoi(env_value);
    if (parsed > 0) {
      cached_ms = static_cast<DWORD>(parsed);
      return cached_ms;
    }
  }

  HKEY key = nullptr;
  DWORD interval = kDefaultIdleGcMs, interval_bytes = sizeof(interval);
  if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\NativeIME", 0, KEY_READ,
                    &key) == ERROR_SUCCESS) {
    RegQueryValueExW(key, L"IdleGcMs", nullptr, nullptr,
                     reinterpret_cast<BYTE*>(&interval), &interval_bytes);
    RegCloseKey(key);
  }
  cached_ms = interval > 0 ? interval : kDefaultIdleGcMs;
  return cached_ms;
}

// Runs for the lifetime of the process on its own detached thread (started
// once in wmain, never joined -- same discipline as the per-client
// ServeClient() threads; see the accept-loop comment below for why
// detached threads never block shutdown). See the block comment above for
// the full ordering argument.
void IdleGcLoop() {
  for (;;) {
    std::this_thread::sleep_for(std::chrono::milliseconds(kIdleGcPollMs));
    if (g_stopping.load(std::memory_order_relaxed)) return;
    if (!g_engine_active.load(std::memory_order_acquire)) continue;

    const DWORD idle_ms = IdleGcIntervalMs();
    const uint64_t last = g_last_activity_tick.load(std::memory_order_acquire);
    if (GetTickCount64() - last < idle_ms) continue;
    if (!g_gc_pending.load(std::memory_order_acquire)) continue;
    if (g_session_composing.load(std::memory_order_acquire)) continue;

    {
      std::lock_guard<std::mutex> lock(g_engine_mutex);
      // Re-validate now that the lock is held: a real request may have
      // been dispatched -- and thus called NoteActivity() -- while this
      // thread was waiting to acquire g_engine_mutex.
      if (GetTickCount64() - g_last_activity_tick.load(std::memory_order_acquire) <
          idle_ms) {
        continue;
      }
      // Same re-validation for composition state: a keystroke that
      // entered preedit/candidate mode while this thread waited for the
      // lock must also suppress the collection.
      if (g_session_composing.load(std::memory_order_acquire)) continue;
      if (!g_gc_pending.exchange(false, std::memory_order_acq_rel)) continue;

      std::string response;
      if (!Dispatch(g_child, "GC", &response)) {
        // Mirrors ServeClient()'s own "child appears to have exited"
        // check below: whichever thread notices first is the one that
        // requests the full shutdown.
        if (g_child.process == nullptr ||
            WaitForSingleObject(g_child.process, 0) != WAIT_TIMEOUT) {
          RequestStop();
        }
      }
      // response is intentionally discarded: the host does not need the
      // engine's "OK GC" / "ERR GC ..." payload, only that the request/
      // response cycle completed (or, on failure, that it noticed).

      // Piggyback the dictionary-compaction verb onto this same idle
      // window, still inside this lock and this loop iteration: the
      // pre-lock and post-lock freshness/composing-suppression checks
      // above already cover it too, so there is no separate idle or
      // composing gate to write for COMPACT. It costs 300-500 ms when the
      // engine's append-journal has actually grown past its threshold (a
      // quick no-op reply otherwise) -- exactly the class of cost that
      // must never ride on a keystroke, same reasoning as GC above. If
      // the connected engine predates this verb it replies with an ERR
      // line; that is still a successful Dispatch() (a reply arrived), so
      // no special handling is needed beyond the same child-exit check.
      std::string response2;
      if (!Dispatch(g_child, "COMPACT", &response2)) {
        if (g_child.process == nullptr ||
            WaitForSingleObject(g_child.process, 0) != WAIT_TIMEOUT) {
          RequestStop();
        }
      }
    }
  }
}
// ---------------------------------------------------------------------------

HANDLE CreatePipeInstance() {
  return CreateNamedPipeW(
      g_pipe_name.c_str(), PIPE_ACCESS_DUPLEX,
      PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT,
      PIPE_UNLIMITED_INSTANCES, 8192, 8192, 0, nullptr);
}

// Wakes the main thread out of a blocked ConnectNamedPipe() call so it can
// notice g_stopping and exit the accept loop. ConnectNamedPipe only returns
// when a client connects (or the instance is torn down from under it), so
// flipping the flag alone would leave the main thread waiting forever for
// an application that may never come -- this opens and immediately closes
// a throwaway connection to the same pipe name, which is exactly the event
// the blocked call is waiting for. If no instance happens to be listening
// at that exact moment (another RequestStop() call, or a genuine client,
// already claimed the one spare instance), the throwaway connect harmlessly
// fails: the main thread is either already awake because that other
// connection woke it, or it will see g_stopping the next time it checks,
// before it would block again -- see the loop in wmain.
void RequestStop() {
  g_stopping.store(true, std::memory_order_relaxed);
  HANDLE wake = CreateFileW(g_pipe_name.c_str(), GENERIC_READ | GENERIC_WRITE,
                            0, nullptr, OPEN_EXISTING, 0, nullptr);
  if (wake != INVALID_HANDLE_VALUE) CloseHandle(wake);
}

// Services one already-connected pipe instance until its client
// disconnects, the child dies, or a "SHUTDOWN" request arrives. Runs on its
// own detached thread; the pipe handle passed in belongs to this thread
// alone. Everything else it touches (g_child, g_engine_mutex, g_stopping,
// g_pipe_name) is shared with other worker threads and the main thread,
// and is only ever touched through the synchronization documented above.
void ServeClient(HANDLE pipe) {
  bool connected = true;
  while (connected) {
    std::array<char, 8192> request_buffer{};
    DWORD read = 0;
    if (!ReadFile(pipe, request_buffer.data(),
                  static_cast<DWORD>(request_buffer.size()), &read, nullptr)) break;
    // Stamped the instant a real request arrives, before it is parsed,
    // dispatched, or even attempts to acquire g_engine_mutex -- this is
    // what lets IdleGcLoop() always see fresh activity ahead of trying to
    // acquire that same mutex itself; see the ordering argument in the
    // block comment above IdleGcLoop().
    NoteActivity();
    std::string request(request_buffer.data(), read);
    while (!request.empty() && (request.back() == '\n' || request.back() == '\r'))
      request.pop_back();
    std::string response;
    const bool is_shutdown = request == "SHUTDOWN";
    if (is_shutdown) {
      response = "OK";
    } else {
      // Locked for the whole transaction, including any nested "SERVER "
      // dictionary exchanges inside Dispatch() -- see the block comment
      // above.
      std::lock_guard<std::mutex> lock(g_engine_mutex);
      if (!Dispatch(g_child, request, &response)) { connected = false; break; }
      // Track composition state from this reply for IdleGcLoop() (see its
      // "Composition-in-progress suppression" comment). Only STATE lines
      // carry a mode; OK/ERR/ENGINES/... replies leave the flag as-is.
      // This lives only on the ServeClient() request path -- IdleGcLoop's
      // own "GC" request always gets back "OK GC", never "STATE ...", so
      // it can never affect this flag.
      if (response.compare(0, 6, "STATE ") == 0) {
        const size_t mode_start = 6;
        const size_t mode_end = response.find(' ', mode_start);
        const std::string mode = mode_end == std::string::npos
            ? response.substr(mode_start)
            : response.substr(mode_start, mode_end - mode_start);
        g_session_composing.store(mode == "preedit" || mode == "candidate",
                                  std::memory_order_release);
      }
    }
    DWORD written = 0;
    connected = WriteFile(pipe, response.data(), static_cast<DWORD>(response.size()),
                          &written, nullptr) && written == response.size();
    if (is_shutdown) {
      connected = false;
      RequestStop();
    }
  }
  FlushFileBuffers(pipe);
  DisconnectNamedPipe(pipe);
  CloseHandle(pipe);
  // Mirrors the pre-multithreading behaviour: once the underlying NeLisp
  // child has exited, the whole host stops (it has nothing left to relay
  // to). Any client's worker thread may be the one to notice this first.
  // Locked so this never races StopChild()'s handle teardown in wmain.
  std::lock_guard<std::mutex> lock(g_engine_mutex);
  if (g_child.process == nullptr ||
      WaitForSingleObject(g_child.process, 0) != WAIT_TIMEOUT) {
    RequestStop();
  }
}
}  // namespace

int wmain(int argc, wchar_t** argv) {
  if (argc != 2 && argc != 3) {
    std::fwprintf(stderr,
                  L"usage: ddskk-engine-host ENGINE_EXE [REPOSITORY]\n");
    return 2;
  }
  const std::wstring repository = argc == 3 ? argv[2] : L"";
  if (!StartChild(argv[1], repository, &g_child)) {
    StopChild(g_child);
    return 3;
  }
  g_pipe_name = PipeName();
  HANDLE pipe = CreatePipeInstance();
  if (pipe == INVALID_HANDLE_VALUE) {
    StopChild(g_child);
    return 4;
  }
  // Started once, detached, never joined -- same discipline as the
  // per-client ServeClient() threads below (see the accept-loop comment):
  // on shutdown this thread simply notices g_stopping within one 100 ms
  // poll tick and returns, and the process exiting reaps it regardless.
  std::thread(IdleGcLoop).detach();
  // Accept loop: each iteration blocks in ConnectNamedPipe() on `pipe` (the
  // one spare, not-yet-connected instance), then immediately opens the next
  // spare instance before handing the newly connected one to its own
  // detached ServeClient() thread -- so a second application can connect
  // right away instead of queuing behind whatever the first client's
  // transaction takes. Worker threads are never joined: on shutdown this
  // function returns (see below) without waiting for them, which is what
  // lets a squatting client -- one that connected but never sends
  // anything, permanently blocked in its own ReadFile() -- never block
  // shutdown. The process exiting (ExitProcess, via the CRT's normal
  // post-wmain path) reaps any such thread; it holds no engine-side state
  // outside of a Dispatch() call, and Dispatch() calls always hold
  // g_engine_mutex, which StopChild() below also waits for.
  while (!g_stopping.load(std::memory_order_relaxed)) {
    if (!ConnectNamedPipe(pipe, nullptr) && GetLastError() != ERROR_PIPE_CONNECTED) {
      CloseHandle(pipe);
      pipe = INVALID_HANDLE_VALUE;
      break;
    }
    if (g_stopping.load(std::memory_order_relaxed)) {
      // Almost certainly RequestStop()'s own throwaway wakeup connection
      // (or, rarely, a real client that raced in right as shutdown began);
      // either way the host is stopping, so it is never handed to a
      // worker thread.
      DisconnectNamedPipe(pipe);
      CloseHandle(pipe);
      pipe = INVALID_HANDLE_VALUE;
      break;
    }
    HANDLE connected_pipe = pipe;
    pipe = CreatePipeInstance();
    std::thread(ServeClient, connected_pipe).detach();
    if (pipe == INVALID_HANDLE_VALUE) {
      // Out of resources for further instances: the client just accepted
      // above is still served (thread already started); just stop taking
      // new ones.
      break;
    }
  }
  if (pipe != INVALID_HANDLE_VALUE) CloseHandle(pipe);
  // Holding g_engine_mutex here waits for any worker thread currently
  // mid-transaction to finish first, so the child's pipes are never closed
  // out from under an in-flight read/write. A worker that acquires the
  // mutex afterward simply finds the now-closed handles and fails its
  // Dispatch() call, which it already treats as an ordinary disconnect.
  {
    std::lock_guard<std::mutex> lock(g_engine_mutex);
    StopChild(g_child);
  }
  ShutdownDictionaryServer();
  return 0;
}
