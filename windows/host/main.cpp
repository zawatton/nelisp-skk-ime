#include "../src/state_mirror.h"
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
#include <psapi.h>
#include "../src/registry_settings.h"
#include "../src/local_index.h"
#include "learning_queue.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <fstream>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <map>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <string>
#include <string_view>
#include <sstream>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace {
// Diagnostics only; scheduling and timeout clocks retain GetTickCount64.
double ProfileMilliseconds() {
  static const double frequency = [] {
    LARGE_INTEGER value{};
    QueryPerformanceFrequency(&value);
    return static_cast<double>(value.QuadPart);
  }();
  LARGE_INTEGER value{};
  QueryPerformanceCounter(&value);
  return 1000.0 * static_cast<double>(value.QuadPart) / frequency;
}
std::atomic<bool> g_stopping{false};
std::atomic<bool> g_private_handover{false};
HANDLE g_child_job = nullptr;
std::wstring g_log_path;
std::atomic<const char*> g_stop_reason{"accept-loop-ended"};

void LogEvent(const std::string& event) {
  // Intentionally process-lifetime: detached pipe workers can still log
  // during CRT shutdown. Never hold this lock while waiting for a child.
  static auto* mutex = new std::mutex;
  std::lock_guard<std::mutex> lock(*mutex);
  if (g_log_path.empty()) return;
  WIN32_FILE_ATTRIBUTE_DATA info{};
  if (GetFileAttributesExW(g_log_path.c_str(), GetFileExInfoStandard, &info) &&
      (info.nFileSizeHigh || info.nFileSizeLow >= 1024 * 1024)) {
    if (!MoveFileExW(g_log_path.c_str(), (g_log_path + L".1").c_str(),
                    MOVEFILE_REPLACE_EXISTING)) return;
  }
  HANDLE file = CreateFileW(g_log_path.c_str(), FILE_APPEND_DATA,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  SYSTEMTIME now{};
  GetSystemTime(&now);
  char prefix[128]{};
  sprintf_s(prefix, "%04u-%02u-%02uT%02u:%02u:%02u.%03uZ host=%lu ",
      now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute,
      now.wSecond, now.wMilliseconds, GetCurrentProcessId());
  std::string message = event.substr(0, 2048);
  std::replace(message.begin(), message.end(), '\r', ' ');
  std::replace(message.begin(), message.end(), '\n', ' ');
  const std::string line = prefix + message + "\r\n";
  DWORD written = 0;
  WriteFile(file, line.data(), static_cast<DWORD>(line.size()), &written, nullptr);
  CloseHandle(file);
}

void InitializeLog() {
  wchar_t path[32768]{};
  DWORD size = GetEnvironmentVariableW(L"DDSKK_HOST_LOG", path, _countof(path));
  if (size && size < _countof(path)) { g_log_path = path; return; }
  size = GetEnvironmentVariableW(L"LOCALAPPDATA", path, _countof(path));
  if (!size || size >= _countof(path)) return;
  const std::wstring directory = std::wstring(path) + L"\\DDSKK";
  CreateDirectoryW(directory.c_str(), nullptr);
  g_log_path = directory + L"\\host.log";
}
constexpr wchar_t kPipeName[] = L"\\\\.\\pipe\\ddskk-ime-v1";
constexpr wchar_t kStateMapName[] = L"Local\\ddskk-ime-state-v1";

/* A read-only snapshot channel for the Sumi companion UI.  It deliberately
 * is not another request path: keyboard requests retain the engine mutex,
 * while Sumi can observe the newest STATE without queuing behind them. */
using SharedImeState = NativeStateMirror;
HANDLE g_state_map = nullptr;
SharedImeState* g_state_view = nullptr;
HANDLE g_state_owner_map = nullptr, g_state_writer = nullptr;
NativeStateOwner* g_state_owner = nullptr;

void InitializeStateMirror(const std::wstring& pipe_name) {
  std::wstring map_name = kStateMapName;
  if (pipe_name != kPipeName) {
    std::wstring suffix = pipe_name;
    for (wchar_t& ch : suffix) {
      if (ch == L'\\' || ch == L'/') ch = L'_';
    }
    map_name = L"Local\\ddskk-ime-state-v1-" + suffix;
  }
  g_state_map = CreateFileMappingW(INVALID_HANDLE_VALUE, nullptr, PAGE_READWRITE,
                                   0, sizeof(SharedImeState), map_name.c_str());
  const bool existing = GetLastError() == ERROR_ALREADY_EXISTS;
  if (g_state_map == nullptr) return;
  g_state_view = static_cast<SharedImeState*>(
      MapViewOfFile(g_state_map, FILE_MAP_WRITE, 0, 0, sizeof(SharedImeState)));
  if (g_state_view == nullptr) {
    CloseHandle(g_state_map);
    g_state_map = nullptr;
    return;
  }
  if (!existing) std::memset(g_state_view, 0, sizeof(*g_state_view));
  g_state_writer = CreateMutexW(nullptr, FALSE, (map_name + L"-writer").c_str());
  g_state_owner_map = CreateFileMappingW(INVALID_HANDLE_VALUE, nullptr, PAGE_READWRITE,
      0, sizeof(NativeStateOwner), (map_name + L"-owner").c_str());
  if (g_state_owner_map) g_state_owner = static_cast<NativeStateOwner*>(
      MapViewOfFile(g_state_owner_map, FILE_MAP_WRITE, 0, 0, sizeof(NativeStateOwner)));
  if (existing && (!g_state_owner || !g_state_owner->requested_owner)) {
    LONG sequence = 0;
    if (TryOwnStateMirror(g_state_view, &sequence, g_state_writer)) {
      if (!g_state_owner || !g_state_owner->requested_owner) {
        std::memset(g_state_view->line, 0, sizeof(g_state_view->line));
        InterlockedExchange(&g_state_view->sequence, 0); // legacy STATUS bootstrap
        ReleaseMutex(g_state_writer);
      } else ReleaseStateMirror(g_state_view, sequence, g_state_writer);
    }
  }
}

void PublishStateMirror(const std::string& response, DWORD input_pid = 0, bool input = false) {
  if (g_state_view == nullptr || response.compare(0, 6, "STATE ") != 0) return;
  LONG sequence = 0;
  if (!TryOwnStateMirror(g_state_view, &sequence, g_state_writer)) return;
  if (g_state_owner && g_state_owner->requested_owner && g_state_owner->local_owner > 0 && (!input || input_pid == static_cast<DWORD>(g_state_owner->local_owner))) {
    HANDLE process = OpenProcess(SYNCHRONIZE, FALSE, static_cast<DWORD>(g_state_owner->local_owner));
    const bool alive = process && WaitForSingleObject(process, 0) == WAIT_TIMEOUT;
    if (process) CloseHandle(process);
    if (alive) { ReleaseStateMirror(g_state_view, sequence, g_state_writer); return; }
  }
  if (g_state_owner) {
    g_state_owner->local_owner = 0;
    if (input) InterlockedExchange(&g_state_owner->requested_owner, 0);
  }
  const size_t capacity = sizeof(g_state_view->line) - 1;
  const size_t count = response.size() < capacity ? response.size() : capacity;
  std::memcpy(g_state_view->line, response.data(), count);
  g_state_view->line[count] = '\0';
  ReleaseStateMirror(g_state_view, sequence, g_state_writer);
}

std::wstring PipeName() {
  wchar_t value[256]{};
  const DWORD size = GetEnvironmentVariableW(L"DDSKK_PIPE_NAME", value, 256);
  return size > 0 && size < 256 ? value : kPipeName;
}

// Backslash is the Object Manager namespace separator, so a raw pipe name
// like "\\.\pipe\ddskk-ime-v1" pasted directly into a kernel object name
// would be read as several namespace levels instead of one opaque suffix.
// Sanitizing it is what makes SingletonMutexName() below produce a single
// well-formed "Local\..." name.
std::wstring SanitizeForMutexName(const std::wstring& value) {
  std::wstring result = value;
  for (wchar_t& ch : result) {
    if (ch == L'\\') ch = L'_';
  }
  return result;
}

// Derives this host's single-instance mutex name from its own pipe name,
// so a private-pipe test/prewarm host (see deploy-live.ps1's prewarm
// step, or DDSKK_PIPE_NAME overrides generally) never collides with the
// live default-pipe host's singleton guard -- each pipe name gets its own
// independent "only one host" mutex. See the field-incident comment on
// its call site in wmain() for why this guard exists at all.
std::wstring SingletonMutexName(const std::wstring& pipe_name) {
  return L"Local\\ddskk-engine-host-" + SanitizeForMutexName(pipe_name);
}

bool UseNativeEntry() {
  wchar_t value[16]{};
  const DWORD size =
      GetEnvironmentVariableW(L"DDSKK_NELISP_ENTRY", value, 16);
  return size > 0 && size < 16 && _wcsicmp(value, L"native") == 0;
}

// The two runner scripts this host knows how to launch. Both speak the
// same line protocol on stdin/stdout, so everything below StartChild() --
// Dispatch(), the skkserv relay, idle GC -- is identical either way; the
// only difference is which conversion the child performs.
constexpr wchar_t kDdskkRunner[] = L"engine/ddskk-engine-stdio.el";
constexpr wchar_t kFrameworkRunner[] = L"framework/nelisp-ime-stdio.el";

// The engine the user configured, as an id matching what a runner answers
// to `ENGINE LIST'. Env first, then the HKCU\Software\NativeIME\Engine
// value the settings UI writes, then the historical default -- the same
// env-first order as PipeName()/UseNativeEntry() above, so a harness can
// exercise an engine without touching the live configuration.
std::wstring ConfiguredEngineId(bool use_environment = true) {
  wchar_t value[64]{};
  const DWORD size = GetEnvironmentVariableW(L"NELISP_IME_ENGINE", value, 64);
  if (use_environment && size > 0 && size < 64) return value;

  HKEY key = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, NativeImeRegistryKey().c_str(), 0, KEY_READ,
                    &key) != ERROR_SUCCESS) return L"ddskk";
  wchar_t engine[64]{};
  // One wchar_t short of the buffer, so a value stored without its
  // terminating null still leaves room for one.
  DWORD bytes = sizeof(engine) - sizeof(wchar_t);
  const LSTATUS status =
      RegQueryValueExW(key, L"Engine", nullptr, nullptr,
                       reinterpret_cast<BYTE*>(engine), &bytes);
  RegCloseKey(key);
  if (status != ERROR_SUCCESS || engine[0] == L'\0') return L"ddskk";
  return engine;
}

std::string NarrowEngineId(const std::wstring& id) {
  std::string result;
  for (wchar_t ch : id) result.push_back(static_cast<char>(ch));
  return result;
}

// `ddskk' and `passthrough' are the two ids the DDSKK runner answers to
// (see engine/ddskk-engine.el's ENGINE LIST). Every other id belongs to
// the nelisp-ime framework runner, which serves whichever engines the
// engine files it loads registered.
bool IsDdskkEngineId(const std::wstring& id) {
  return id.empty() || _wcsicmp(id.c_str(), L"ddskk") == 0 ||
         _wcsicmp(id.c_str(), L"passthrough") == 0;
}

bool FileExists(const std::wstring& path) {
  const DWORD attributes = GetFileAttributesW(path.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES &&
         (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

// Returns the runner for an explicit child selection. StartChild supplies
// NELISP_IME_ENGINE in the child's own environment block.
//
// Falling back to DDSKK when the repository has no framework runner is
// deliberate rather than defensive tidiness. Field incident: the settings
// UI offered an engine the running stack could not serve, the user
// selected it, and conversion stopped working entirely. A configured
// engine that cannot be launched must degrade to the one that always can.
std::wstring EngineRunnerScript(const std::wstring& repository,
                                const std::wstring& id) {
  if (IsDdskkEngineId(id)) return kDdskkRunner;
  if (!FileExists(repository + L"\\framework\\nelisp-ime-stdio.el")) {
    std::fwprintf(stderr,
                  L"ddskk-engine-host: engine \"%ls\" needs %ls, which this "
                  L"repository does not provide; falling back to DDSKK\n",
                  id.c_str(), kFrameworkRunner);
    return kDdskkRunner;
  }
  return kFrameworkRunner;
}

#include "native_adapter_transport.h"

#include "policy_bundle.h"
#include "native_adapter.h"

// The settings UI (docs/design/sumi-indicator-settings.md, the 辞書 and
// behavior-flag tabs) stores the user dictionary path/save-batch size and
// several engine behavior flags under HKCU\Software\NativeIME:
// UserJisyoPath (REG_SZ), and UserJisyoBatch / BehaviorOkuriStrictly /
// BehaviorDeleteOkuriOnCancel / BehaviorAddKatakanaCand /
// BehaviorLearnDisabled (all REG_DWORD). engine/skk-user-jisyo.el and the
// corresponding behavior-flag Elisp instead read all of these from the
// engine child's own environment (DDSKK_USER_JISYO,
// DDSKK_USER_JISYO_SAVE_BATCH_SIZE, DDSKK_OKURI_STRICTLY,
// DDSKK_DELETE_OKURI_ON_CANCEL, DDSKK_SEARCH_KATAKANA,
// DDSKK_LEARN_DISABLED). This bridges registry -> env right before the
// child is spawned (CreateProcessW below inherits this process's
// environment when lpEnvironment is nullptr, which it is), but only fills
// in a variable that is not already set: every existing test harness sets
// these env vars directly for isolation (private jisyo, specific behavior
// flags under test, etc.), and leaving an already-set value alone keeps
// every one of them working unchanged.
void ApplyEngineEnvFromRegistry() {
  // Only explicit inherited overrides stay pinned. Values imported on a
  // previous spawn must be refreshed (or removed) for ENGINE RELOAD.
  static std::vector<const wchar_t*> imported;
  for (const wchar_t* name : imported) SetEnvironmentVariableW(name, nullptr);
  imported.clear();
  const auto set_imported = [&](const wchar_t* name, const wchar_t* value) {
    SetEnvironmentVariableW(name, value);
    imported.push_back(name);
  };
  HKEY key = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, NativeImeRegistryKey().c_str(), 0, KEY_READ,
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
      /* The settings default intentionally uses %LOCALAPPDATA% so it is
       * portable between users. SetEnvironmentVariableW does not expand
       * embedded references; passing the registry text through unchanged
       * made NeLisp try to open a literal "%LOCALAPPDATA%" path and its
       * best-effort journal write was silently skipped. */
      const DWORD expanded_size = ExpandEnvironmentStringsW(path, nullptr, 0);
      std::vector<wchar_t> expanded(expanded_size > 0 ? expanded_size : 1);
      if (expanded_size > 0 &&
          ExpandEnvironmentStringsW(path, expanded.data(), expanded_size) > 0) {
        set_imported(L"DDSKK_USER_JISYO", expanded.data());
      } else {
        set_imported(L"DDSKK_USER_JISYO", path);
      }
    }
  }

  // Every remaining bridge is registry REG_DWORD -> env var set to its
  // decimal string, so a small table drives all of them instead of
  // repeating the same read/format/set sequence per value. Adding another
  // REG_DWORD behavior flag in the future is just one more row here.
  struct DwordBridge {
    const wchar_t* registry_name;
    const wchar_t* env_name;
  };
  static constexpr DwordBridge kDwordBridges[] = {
      {L"UserJisyoBatch", L"DDSKK_USER_JISYO_SAVE_BATCH_SIZE"},
      {L"BehaviorOkuriStrictly", L"DDSKK_OKURI_STRICTLY"},
      {L"BehaviorDeleteOkuriOnCancel", L"DDSKK_DELETE_OKURI_ON_CANCEL"},
      {L"BehaviorAddKatakanaCand", L"DDSKK_SEARCH_KATAKANA"},
      {L"BehaviorLearnDisabled", L"DDSKK_LEARN_DISABLED"},
  };
  for (const DwordBridge& bridge : kDwordBridges) {
    if (GetEnvironmentVariableW(bridge.env_name, nullptr, 0) != 0) continue;
    DWORD value = 0, value_bytes = sizeof(value);
    if (RegQueryValueExW(key, bridge.registry_name, nullptr, nullptr,
                         reinterpret_cast<BYTE*>(&value), &value_bytes) ==
        ERROR_SUCCESS) {
      set_imported(bridge.env_name,
                              std::to_wstring(value).c_str());
    }
  }

  RegCloseKey(key);
}

bool StartChild(const std::wstring& engine, const std::wstring& repository,
                Child* child, const std::wstring& id, bool warming = false) {
  SECURITY_ATTRIBUTES security{sizeof(security), nullptr, TRUE};
  HANDLE stdout_read = nullptr, stdout_write = nullptr;
  HANDLE stdin_read = nullptr, stdin_write = nullptr;
  if (!CreatePipe(&stdout_read, &stdout_write, &security, 0) ||
      !CreatePipe(&stdin_read, &stdin_write, &security, 0)) {
    Close(stdout_read); Close(stdout_write); Close(stdin_read); Close(stdin_write);
    return false;
  }
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
    const std::wstring runner = EngineRunnerScript(repository, id);
    // The AOT-backed native entry exists for the DDSKK runner only, so an
    // engine served by the framework runner always takes the --load path.
    command += (UseNativeEntry() && runner == kDdskkRunner)
                   ? L" --ddskk-ime-server " + runner
                   : L" --load " + runner;
  }
  const wchar_t* working_directory =
      repository.empty() ? nullptr : repository.c_str();
  ApplyEngineEnvFromRegistry();
  // Each child receives its own engine selection. Do not mutate the host's
  // environment: registry notifications must not see a previous spawn's id.
  std::vector<std::wstring> entries;
  wchar_t* inherited = GetEnvironmentStringsW();
  if (!inherited) { Close(stdin_read); Close(stdin_write); Close(stdout_read); Close(stdout_write); return false; }
  for (const wchar_t* entry = inherited; *entry; entry += wcslen(entry) + 1) {
    if (_wcsnicmp(entry, L"NELISP_IME_ENGINE=", 18) == 0) continue;
    entries.emplace_back(entry);
  }
  FreeEnvironmentStringsW(inherited);
  const std::wstring selection = L"NELISP_IME_ENGINE=" + id;
  entries.push_back(selection);
  std::sort(entries.begin(), entries.end(), [](const auto& a, const auto& b) {
    return _wcsicmp(a.c_str(), b.c_str()) < 0;
  });
  std::vector<wchar_t> environment;
  for (const auto& entry : entries)
    environment.insert(environment.end(), entry.c_str(), entry.c_str() + entry.size() + 1);
  environment.push_back(L'\0');
  const BOOL started = CreateProcessW(
      nullptr, command.data(), nullptr, nullptr, TRUE,
      CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED |
          (warming ? BELOW_NORMAL_PRIORITY_CLASS : NORMAL_PRIORITY_CLASS), environment.data(),
      working_directory, &startup, &process);
  Close(stdin_read);
  Close(stdout_write);
  if (!started) {
    Close(stdout_read);
    Close(stdin_write);
    return false;
  }
  if (g_child_job && !AssignProcessToJobObject(g_child_job, process.hProcess)) {
    TerminateProcess(process.hProcess, 1);
    CloseHandle(process.hProcess);
    CloseHandle(process.hThread);
    Close(stdout_read);
    Close(stdin_write);
    return false;
  }
  ResumeThread(process.hThread);
  CloseHandle(process.hThread);
  child->epoch = ++native_adapter::next_engine_epoch;
  native_adapter::Observe(native_adapter::PolicyKind::Config, IsDdskkEngineId(id) ? 0 : 1,
      FileExists(repository + L"\\framework\\nelisp-ime-stdio.el") ? 1 : 0, 0,
      EngineRunnerScript(repository, id) == kDdskkRunner ? 0 : 1, NarrowEngineId(id), child->epoch);
  child->process = process.hProcess;
  child->input = stdin_write;
  child->output = stdout_read;
  child->engine = NarrowEngineId(id);
  child->started = GetTickCount64();
  LogEvent("child-start pid=" + std::to_string(process.dwProcessId) +
      " engine=" + child->engine + " runner=" +
      NarrowEngineId(EngineRunnerScript(repository, id)) +
      " priority=" + (warming ? "below-normal" : "normal"));
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
  // Optional full command line (CreateProcessW-ready; used as-is, no shell
  // interpretation) to spawn the dictionary server when it turns out to be
  // unreachable. Field incident: after a re-logon, the external skkserv
  // (an Emacs daemon on 127.0.0.1:1179) was not restarted by the user's
  // own startup hooks; with no dictionary, every conversion returned
  // nothing, compositions never closed, and even arrow keys got trapped
  // behind the stuck composition at the application level. See
  // TrySpawnSkkServ(), LookupDictionary(), and the startup probe in
  // wmain(). Env DDSKK_SKKSERV_START_COMMAND takes precedence over the
  // HKCU\Software\NativeIME\SkkServStartCommand registry value -- same
  // env-first pattern as ApplyEngineEnvFromRegistry() above, so a test
  // harness can exercise this without a registry write.
  std::wstring start_command;
  // Optional ';'-separated absolute paths to local SKK-JISYO format
  // dictionary files, in priority order. USER QUESTION driving this:
  // 「辞書サーバー無しで変換出来ないのでしょうか？」 -- the external
  // skkserv (an Emacs daemon owned by the user's own session) has died
  // twice, and the engine's own NeLisp heap cannot hold a multi-MB
  // dictionary (its semispace GC copies all live data; pauses would reach
  // seconds), so the dictionary belongs here, in the host. When set,
  // LookupDictionary() merges all files, then the external server, using
  // stock candidate union order. Network work belongs to ServerCache. Env DDSKK_DICTIONARY_FILES takes precedence over
  // HKCU\Software\NativeIME\DictionaryFiles, same env-first pattern as
  // start_command above.
  std::wstring dictionary_files;
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
  wchar_t start_command[32768]{};
  DWORD start_command_bytes = sizeof(start_command);
  wchar_t dictionary_files[32768]{};
  DWORD dictionary_files_bytes = sizeof(dictionary_files);
  if (RegOpenKeyExW(HKEY_CURRENT_USER, NativeImeRegistryKey().c_str(), 0,
                    KEY_READ, &key) == ERROR_SUCCESS) {
    RegQueryValueExW(key, L"SkkServHost", nullptr, nullptr,
                     reinterpret_cast<BYTE*>(host), &host_bytes);
    RegQueryValueExW(key, L"SkkServPort", nullptr, nullptr,
                     reinterpret_cast<BYTE*>(&port), &port_bytes);
    RegQueryValueExW(key, L"SkkServEnable", nullptr, nullptr,
                     reinterpret_cast<BYTE*>(&enabled), &enabled_bytes);
    RegQueryValueExW(key, L"SkkServStartCommand", nullptr, nullptr,
                     reinterpret_cast<BYTE*>(start_command), &start_command_bytes);
    RegQueryValueExW(key, L"DictionaryFiles", nullptr, nullptr,
                     reinterpret_cast<BYTE*>(dictionary_files),
                     &dictionary_files_bytes);
    RegCloseKey(key);
  }
  config->host = host;
  config->port = port;
  config->enabled = enabled;
  config->start_command = start_command;
  config->dictionary_files = dictionary_files;

  // Env wins over registry -- see DictionaryServerConfig::start_command.
  wchar_t env_start_command[32768]{};
  const DWORD env_size = GetEnvironmentVariableW(
      L"DDSKK_SKKSERV_START_COMMAND", env_start_command, 32768);
  if (env_size > 0 && env_size < 32768) {
    config->start_command = env_start_command;
  }

  // Same env-first pattern -- see DictionaryServerConfig::dictionary_files.
  wchar_t env_dictionary_files[32768]{};
  const DWORD env_dictionary_files_size = GetEnvironmentVariableW(
      L"DDSKK_DICTIONARY_FILES", env_dictionary_files, 32768);
  if (env_dictionary_files_size > 0 && env_dictionary_files_size < 32768) {
    config->dictionary_files = env_dictionary_files;
  }

  // DDSKK_SKKSERV_HOST/PORT: unlike the two bridges above, host/port have
  // no registry-writable settings-UI story of their own to layer onto --
  // these two env vars exist purely so a test harness can point the
  // external-server probe at a deliberately unreachable target without a
  // registry write (needed to test the built-in-dictionary-only,
  // no-server-at-all path; see wmain()'s startup probe and
  // LookupDictionary()).
  wchar_t env_host[256]{};
  const DWORD env_host_size =
      GetEnvironmentVariableW(L"DDSKK_SKKSERV_HOST", env_host, 256);
  if (env_host_size > 0 && env_host_size < 256) config->host = env_host;

  wchar_t env_port[16]{};
  const DWORD env_port_size =
      GetEnvironmentVariableW(L"DDSKK_SKKSERV_PORT", env_port, 16);
  if (env_port_size > 0 && env_port_size < 16) {
    const int parsed = _wtoi(env_port);
    if (parsed > 0) config->port = static_cast<DWORD>(parsed);
  }
  wchar_t env_enabled[8]{};
  const DWORD env_enabled_size =
      GetEnvironmentVariableW(L"DDSKK_SKKSERV_ENABLE", env_enabled, 8);
  if (env_enabled_size > 0 && env_enabled_size < 8) {
    config->enabled = wcscmp(env_enabled, L"0") == 0 ? 0 : 1;
  }
}

// ---------------------------------------------------------------------------
// Built-in (host-local) SKK dictionaries -- see
// DictionaryServerConfig::dictionary_files above for the motivating field
// incident. One std::unordered_map per configured file, populated once by
// LoadBuiltinDictionariesThread() and never mutated again: `ready` is the
// single publish point (std::atomic<bool>, release/acquire), so once a
// reader observes ready == true it is guaranteed to see every map exactly
// as the loader thread left it, and no lock is needed for the read side
// at all -- concurrent LookupDictionary() calls from different
// ServeClient() threads (each already serialized through g_engine_mutex
// for everything else, but that is incidental here, not required) just
// do plain unordered_map lookups against immutable data.
struct BuiltinDictionaryState {
  std::atomic<bool> ready{false};
  std::vector<std::unordered_map<std::string, std::string>> maps;
};
BuiltinDictionaryState g_builtin_dictionary;

// Parses one already-loaded SKK-JISYO file's raw bytes into `*map`.
// Format: ";;"-prefixed lines are comments and skipped; every other
// non-empty line is "MIDASI /cand1/cand2;annotation/.../" (a single space
// separates the midasi from the candidate list, which always starts and
// ends with '/'). The stored value is that "/.../ " tail verbatim,
// including any ";annotation" suffixes and "[okuri ...]" bracket sub-
// entries some candidates carry -- both are kept as opaque text, not
// specially parsed, because MergeBuiltinCandidates() (and the DDSKK
// engine layer downstream of it) already knows how to handle them; this
// function only needs to find where the candidate list starts. Malformed
// lines (no space, or no '/' after it) are silently skipped, not fatal --
// one bad line must not lose the rest of a multi-hundred-thousand-line
// file.
void StripDictionaryLineBreaks(std::string* text) {
  text->erase(std::remove_if(text->begin(), text->end(),
      [](char ch) { return ch == '\r' || ch == '\n'; }), text->end());
}

void ParseSkkJisyo(std::string_view contents,
                   std::unordered_map<std::string, std::string>* map) {
  size_t line_start = 0;
  while (line_start <= contents.size()) {
    size_t line_end = contents.find('\n', line_start);
    if (line_end == std::string_view::npos) line_end = contents.size();
    std::string line(contents.substr(line_start, line_end - line_start));
    StripDictionaryLineBreaks(&line);
    line_start = line_end + 1;

    if (line.empty() || line.substr(0, 2) == ";;") continue;
    const size_t space = line.find(' ');
    if (space == std::string_view::npos) continue;
    const size_t slash = line.find('/', space);
    if (slash == std::string_view::npos) continue;
    (*map)[std::string(line.substr(0, space))] = std::string(line.substr(slash));
  }
}

// Reads `path` in full and hands it to ParseSkkJisyo(). Returns false (map
// left however far it got, i.e. possibly partially populated) on any I/O
// error; *entry_count is only meaningful when this returns true. A UTF-8
// byte-order-mark, if present, is skipped first -- the map's keys/values
// are exact UTF-8 bytes, and a leading BOM would otherwise corrupt the
// very first midasi on the first line.
bool LoadDictionaryFile(const std::wstring& path,
                        std::unordered_map<std::string, std::string>* map,
                        size_t* entry_count) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ,
                            nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                            nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;

  LARGE_INTEGER size{};
  // 2 GiB sanity cap: ReadFile's single-call length is a DWORD anyway, and
  // no real SKK-JISYO file approaches this -- this is purely a guard
  // against an accidentally-misconfigured path (e.g. a device file).
  if (!GetFileSizeEx(file, &size) || size.QuadPart < 0 ||
      size.QuadPart > 0x7FFFFFFF) {
    CloseHandle(file);
    return false;
  }

  std::string contents(static_cast<size_t>(size.QuadPart), '\0');
  size_t total_read = 0;
  bool read_ok = true;
  while (total_read < contents.size()) {
    DWORD chunk = 0;
    if (!ReadFile(file, contents.data() + total_read,
                  static_cast<DWORD>(contents.size() - total_read), &chunk,
                  nullptr) ||
        chunk == 0) {
      read_ok = false;
      break;
    }
    total_read += chunk;
  }
  CloseHandle(file);
  if (!read_ok) return false;

  size_t offset = 0;
  if (contents.size() >= 3 && static_cast<unsigned char>(contents[0]) == 0xEF &&
      static_cast<unsigned char>(contents[1]) == 0xBB &&
      static_cast<unsigned char>(contents[2]) == 0xBF) {
    offset = 3;
  }
  ParseSkkJisyo(std::string_view(contents).substr(offset), map);
  *entry_count = map->size();
  return true;
}

// Runs once on its own detached background thread (started in wmain()
// right after the engine child is up), so file I/O and parsing a
// multi-hundred-thousand-line dictionary never block pipe serving. Splits
// `files_spec` on ';', loads each file's map in priority order, and only
// publishes g_builtin_dictionary.ready after every file has been
// attempted -- a lookup that arrives before that simply skips the
// built-in tier (LookupDictionary() checks the flag first) and falls
// through to the external server exactly as if dictionary_files had never
// been set. A file that fails to load leaves an empty map in its slot
// (logged, not fatal) rather than skipping the slot entirely, so the
// remaining files keep their priority order.
void LoadBuiltinDictionariesThread(std::wstring files_spec) {
  std::vector<std::wstring> paths;
  size_t start = 0;
  while (start <= files_spec.size()) {
    size_t end = files_spec.find(L';', start);
    if (end == std::wstring::npos) end = files_spec.size();
    if (end > start) paths.push_back(files_spec.substr(start, end - start));
    start = end + 1;
  }

  std::vector<std::unordered_map<std::string, std::string>> maps;
  maps.reserve(paths.size());
  for (const std::wstring& path : paths) {
    const auto started = std::chrono::steady_clock::now();
    std::unordered_map<std::string, std::string> map;
    size_t entry_count = 0;
    const bool ok = LoadDictionaryFile(path, &map, &entry_count);
    const long long elapsed_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - started).count();
    if (ok) {
      std::fwprintf(stderr,
                    L"ddskk-engine-host: loaded dictionary %ls (%zu entries, "
                    L"%lld ms)\n",
                    path.c_str(), entry_count, elapsed_ms);
    } else {
      std::fwprintf(stderr,
                    L"ddskk-engine-host: failed to load dictionary %ls (%lu)\n",
                    path.c_str(), static_cast<unsigned long>(GetLastError()));
    }
    maps.push_back(std::move(map));
  }

  g_builtin_dictionary.maps = std::move(maps);
  // Release pairs with LookupDictionary()'s acquire load below: everything
  // written above (every map) must be visible to any thread that observes
  // ready == true afterward.
  g_builtin_dictionary.ready.store(true, std::memory_order_release);
}

// Merges `midasi`'s candidate list across every loaded built-in
// dictionary map, in priority order -- real SKK semantics: the union of
// all candidates in first-occurrence order, not "first file that has it
// wins". Dedup compares the candidate text before any ";annotation"
// suffix (so "候補;何か" and "候補;別の注釈" count as the same candidate;
// only the first-seen copy, annotation included, is kept). Returns an
// empty string if no configured file has `midasi` at all.
std::string MergeBuiltinCandidates(const std::string& midasi) {
  std::vector<std::string> ordered_candidates;  // full text, first-occurrence order
  std::vector<std::string> seen_keys;           // dedup key: text before ';'
  for (const auto& map : g_builtin_dictionary.maps) {
    const auto it = map.find(midasi);
    if (it == map.end()) continue;
    const std::string& raw = it->second;  // "/cand1/cand2;ann/cand3/"
    // SKK-JISYO okuri-ari entries can carry a nested "[okurigana/cand.../]"
    // block after the plain candidates -- keyed by okurigana, not itself a
    // set of ordinary candidates. Example (the actual field bug): the
    // okuri-ari reading "かなs" (roughly "kana" + okurigana "s") stores
    // "/悲/哀/[し/悲/哀/]/" -- the bracket block repeats the candidates
    // that apply specifically when the okurigana resolves to "し" (悲し/
    // 哀しい etc.). Without this skip, splitting on top-level '/' alone
    // surfaced "[し" itself as a bogus candidate ("▼[しし" in the live
    // report) and could surface the block's inner repeats too. `in_bracket`
    // is a straight-line stateful skip: true from the token that STARTS
    // with '[' through the token that is exactly "]" inclusive, reset per
    // file (each file's own raw string gets a fresh false). TODO: actually
    // matching the resolved okurigana against the block to PROMOTE its
    // candidates ahead of the plain ones -- what BehaviorOkuriStrictly
    // implies -- is the fuller feature; today's fix only ensures a
    // bracket-block token is never shown as a candidate at all.
    bool in_bracket = false;
    size_t pos = 0;
    while (pos <= raw.size()) {
      size_t next = raw.find('/', pos);
      if (next == std::string::npos) next = raw.size();
      if (next > pos) {
        std::string candidate = raw.substr(pos, next - pos);
        if (in_bracket) {
          if (candidate == "]") in_bracket = false;
        } else if (!candidate.empty() && candidate.front() == '[') {
          in_bracket = true;
        } else {
          const size_t semicolon = candidate.find(';');
          const std::string key = semicolon == std::string::npos
              ? candidate : candidate.substr(0, semicolon);
          if (std::find(seen_keys.begin(), seen_keys.end(), key) ==
              seen_keys.end()) {
            seen_keys.push_back(key);
            ordered_candidates.push_back(std::move(candidate));
          }
        }
      }
      if (next >= raw.size()) break;
      pos = next + 1;
    }
  }
  if (ordered_candidates.empty()) return std::string();
  std::string merged;
  for (const std::string& candidate : ordered_candidates) {
    merged += '/';
    merged += candidate;
  }
  merged += '/';
  return merged;
}

bool DecodeHexBytes(std::string_view encoded, std::string* decoded) {
  if (encoded.empty() || encoded.size() > 8192 || encoded.size() % 2 != 0)
    return false;
  decoded->clear();
  decoded->reserve(encoded.size() / 2);
  const auto nibble = [](char value) -> int {
    if (value >= '0' && value <= '9') return value - '0';
    if (value >= 'a' && value <= 'f') return value - 'a' + 10;
    if (value >= 'A' && value <= 'F') return value - 'A' + 10;
    return -1;
  };
  for (size_t index = 0; index < encoded.size(); index += 2) {
    const int high = nibble(encoded[index]);
    const int low = nibble(encoded[index + 1]);
    if (high < 0 || low < 0) return false;
    decoded->push_back(static_cast<char>((high << 4) | low));
  }
  return true;
}

std::string PreviewBuiltinDictionary(std::string_view request) {
  constexpr std::string_view prefix = "PREVIEW ";
  std::string midasi;
  if (!request.starts_with(prefix) ||
      !DecodeHexBytes(request.substr(prefix.size()), &midasi) ||
      !g_builtin_dictionary.ready.load(std::memory_order_acquire)) {
    return "PREVIEW -";
  }
  const std::string candidates = MergeBuiltinCandidates(midasi);
  return candidates.empty() ? "PREVIEW -" : "PREVIEW " + candidates;
}
// ---------------------------------------------------------------------------

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

// Observation only: enabled exclusively for an explicitly private OS1 probe.
bool Os1DnsTraceEnabled() {
  wchar_t trace[2]{}, diagnostics[2]{}, registry[256]{}, pipe[256]{};
  return GetEnvironmentVariableW(L"NATIVEIME_TEST_OS1_DNS_TRACE", trace, 2) == 1 && trace[0] == L'1' &&
      GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", diagnostics, 2) == 1 && diagnostics[0] == L'1' &&
      GetEnvironmentVariableW(L"NATIVEIME_REGISTRY_KEY", registry, 256) < 256 &&
      std::wstring(registry).starts_with(L"Software\\NativeIME-test-") &&
      GetEnvironmentVariableW(L"DDSKK_PIPE_NAME", pipe, 256) < 256 &&
      std::wstring(pipe).starts_with(L"\\\\.\\pipe\\EH");
}
// Resolves and connects to the configured dictionary server. Returns
// INVALID_SOCKET on any failure (bad hostname, connection refused, etc.).
// TCP connect is bounded to 150ms per resolved address. Name resolution
// belongs to the background worker, never an input callback.
SOCKET ConnectDictionaryServer(const DictionaryServerConfig& config) {
  const std::string host_utf8 = WideToUtf8(config.host);
  const std::string port_text = std::to_string(config.port);

  ADDRINFOA hints{};
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_protocol = IPPROTO_TCP;
  ADDRINFOA* result = nullptr;
  const bool trace_dns = Os1DnsTraceEnabled();
  const double dns_started = trace_dns ? ProfileMilliseconds() : 0;
  if (trace_dns) LogEvent("os1-dns-enter tid=" + std::to_string(GetCurrentThreadId()) + " host=" + host_utf8);
  const int resolved = getaddrinfo(host_utf8.c_str(), port_text.c_str(), &hints, &result);
  if (trace_dns) LogEvent("os1-dns-exit status=" + std::to_string(resolved) +
      " ms=" + std::to_string(ProfileMilliseconds()-dns_started));
  if (resolved != 0)
    return INVALID_SOCKET;

  SOCKET socket_handle = INVALID_SOCKET;
  for (const ADDRINFOA* candidate = result; candidate != nullptr;
       candidate = candidate->ai_next) {
    socket_handle = socket(candidate->ai_family, candidate->ai_socktype,
                           candidate->ai_protocol);
    if (socket_handle == INVALID_SOCKET) continue;
    u_long nonblocking = 1; ioctlsocket(socket_handle, FIONBIO, &nonblocking);
    int connected = connect(socket_handle, candidate->ai_addr, static_cast<int>(candidate->ai_addrlen));
    if (connected != 0 && WSAGetLastError() == WSAEWOULDBLOCK) {
      // Winsock reports a refused nonblocking connect in exceptfds, rather
      // than writefds. Observe both so a refused server fails immediately.
      fd_set writes, errors; FD_ZERO(&writes); FD_SET(socket_handle, &writes);
      FD_ZERO(&errors); FD_SET(socket_handle, &errors); timeval timeout{0, 150000};
      if (select(0, nullptr, &writes, &errors, &timeout) > 0) {
        int error = 0, bytes = sizeof(error);
        if (getsockopt(socket_handle, SOL_SOCKET, SO_ERROR, reinterpret_cast<char*>(&error), &bytes) == 0 && !error) connected = 0;
      }
    }
    if (connected == 0) { nonblocking = 0; ioctlsocket(socket_handle, FIONBIO, &nonblocking); break; }
    closesocket(socket_handle);
    socket_handle = INVALID_SOCKET;
  }
  freeaddrinfo(result);
  if (socket_handle == INVALID_SOCKET) return INVALID_SOCKET;

  // Worker-owned socket: dead servers cannot block input callbacks.
  // Local/LAN skkserv replies are normally sub-millisecond; a slower reply
  // degrades to the already-loaded local dictionaries for this conversion.
  const DWORD timeout_ms = 150;
  setsockopt(socket_handle, SOL_SOCKET, SO_RCVTIMEO,
            reinterpret_cast<const char*>(&timeout_ms), sizeof(timeout_ms));
  setsockopt(socket_handle, SOL_SOCKET, SO_SNDTIMEO,
            reinterpret_cast<const char*>(&timeout_ms), sizeof(timeout_ms));
  return socket_handle;
}

// Guards TrySpawnSkkServ() below against spawning the dictionary server
// repeatedly in a tight loop -- e.g. a burst of conversions each hitting
// their own failed lookup, or a lookup failure arriving right after the
// one-time startup probe in wmain() already tried. Shared by both call
// sites; 0 means "never spawned yet". Not scoped inside
// DictionaryServerState because the startup probe in wmain() runs before
// (and independently of) any client connection, not just from
// LookupDictionary()'s already-g_engine_mutex-serialized call path.
std::atomic<uint64_t> g_last_skkserv_spawn_tick{0};
constexpr uint64_t kSkkservSpawnCooldownMs = 30000;

// Spawns `command` (DictionaryServerConfig::start_command, verbatim -- no
// shell interpretation) detached and hidden, rate-limited to at most once
// per kSkkservSpawnCooldownMs. Field incident and full rationale: see
// DictionaryServerConfig::start_command above. Logs exactly one stderr
// line either way (spawned, or CreateProcessW itself failed); returns
// false without logging anything if there is no command configured or the
// cooldown has not elapsed yet. Returns true only when a spawn was
// actually attempted (regardless of whether CreateProcessW itself
// succeeded) -- callers use that to decide whether it is worth pausing
// for the dictionary server to come up before one bounded retry.
bool TrySpawnSkkServ(const std::wstring& command) {
  if (command.empty()) return false;

  const uint64_t now = GetTickCount64();
  const uint64_t last = g_last_skkserv_spawn_tick.load(std::memory_order_acquire);
  if (last != 0 && now - last < kSkkservSpawnCooldownMs) return false;
  g_last_skkserv_spawn_tick.store(now, std::memory_order_release);

  // CreateProcessW's lpCommandLine must be a writable buffer -- it may
  // rewrite embedded spaces/quotes in place -- so this makes a mutable
  // copy rather than touching `command` (and thus the cached config).
  std::vector<wchar_t> command_line(command.begin(), command.end());
  command_line.push_back(L'\0');

  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  startup.dwFlags = STARTF_USESHOWWINDOW;
  startup.wShowWindow = SW_HIDE;
  PROCESS_INFORMATION process{};
  // No inherited handles (this is an unrelated helper process, not the
  // engine child), CREATE_NO_WINDOW so a console-subsystem command line
  // never flashes a window, detached (handles closed immediately below --
  // this host does not track or wait on the dictionary server process).
  const BOOL started = CreateProcessW(
      nullptr, command_line.data(), nullptr, nullptr, FALSE,
      CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process);
  if (started) {
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    std::fwprintf(stderr,
                  L"ddskk-engine-host: dictionary server unreachable, spawned "
                  L"SkkServStartCommand [%ls]\n",
                  command.c_str());
  } else {
    std::fwprintf(stderr,
                  L"ddskk-engine-host: SkkServStartCommand CreateProcessW "
                  L"failed (%lu) for [%ls]\n",
                  static_cast<unsigned long>(GetLastError()), command.c_str());
  }
  return true;
}

// Sends `request` in full and reads a single line (up to '\n', which is
// consumed but not included in *raw_response; a trailing '\r' is stripped
// too). Returns false on any send/recv error, timeout, graceful close, or
// if the line exceeds 64 KiB or the total exchange exceeds 150ms.
bool SendAndReceive(SOCKET socket_handle, const std::string& request,
                    std::string* raw_response) {
  const auto deadline = GetTickCount64() + 150;
  const auto budget = [&](int option) {
    const auto now = GetTickCount64(); if (now >= deadline) return false;
    const DWORD remaining = static_cast<DWORD>(deadline - now);
    return setsockopt(socket_handle, SOL_SOCKET, option, reinterpret_cast<const char*>(&remaining), sizeof(remaining)) == 0;
  };
  size_t offset = 0;
  while (offset < request.size()) {
    if (!budget(SO_SNDTIMEO)) return false;
    const int sent = send(socket_handle, request.data() + offset,
                          static_cast<int>(request.size() - offset), 0);
    if (sent <= 0) return false;
    offset += static_cast<size_t>(sent);
  }

  raw_response->clear();
  char buffer[4096];
  for (;;) {
    if (!budget(SO_RCVTIMEO)) return false;
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
  StripDictionaryLineBreaks(raw_response);
  return true;
}

// External I/O runs independently of provider transactions. Pending work and
// replies are bounded. Config generations discard obsolete in-flight replies.
class ServerCache {
 public:
  ~ServerCache() { Stop(); }
  void Start() { worker_ = std::thread([this] { Run(); }); }
  void Stop() {
    if (Os1DnsTraceEnabled()) LogEvent("os1-dns-worker-stop-request");
    { std::lock_guard lock(mutex_); stop_ = true; }
    changed_.notify_all(); if (worker_.joinable()) worker_.join();
    if (Os1DnsTraceEnabled()) LogEvent("os1-dns-worker-stopped");
  }
  std::optional<std::string> Query(const std::string& reading, const std::string& okuri = {}, DWORD wait_ms = 0) {
    // Profile every cache exit, including LOCAL SERVER polls, disabled
    // sources, hits and the provider's bounded wait. Log after unlocking.
    struct CacheProfile {
      bool enabled; double started;
      ~CacheProfile() {
        if (enabled)
          std::fprintf(stderr, "dictionary-source name=skkserv-cache ms=%.6f\n",
                       ProfileMilliseconds()-started);
      }
    };
    const bool debug = GetEnvironmentVariableW(L"DDSKK_HOST_DEBUG", nullptr, 0) > 0;
    const CacheProfile profile{debug, debug ? ProfileMilliseconds() : 0};
    DictionaryServerConfig config; LoadDictionaryServerConfig(&config);
    const auto identity = WideToUtf8(config.host) + ":" + std::to_string(config.port) + ":" +
        std::to_string(config.enabled) + ":" + WideToUtf8(config.dictionary_files) + ":" + WideToUtf8(config.start_command);
    const auto key = reading + '\x1f' + okuri;
    std::unique_lock lock(mutex_);
    if (identity != identity_) { identity_ = identity; ++generation_; cache_.clear(); jobs_.clear(); }
    const auto source = native_adapter::Decide(native_adapter::PolicyKind::Sources, config.enabled != 0,
        !config.dictionary_files.empty(), generation_,
        !config.enabled ? 0 : (config.dictionary_files.empty() ? 2 : 1), identity);
    if (source == 0) return "4";
    auto found = cache_.find(key);
    if (found != cache_.end() && found->second.reply) {
      const auto age = GetTickCount64() - found->second.completed;
      const bool hit = found->second.reply->starts_with("1");
      // The managed policy selects the duration; elapsed-time measurement and
      // cache mutation stay native. S3 expiry observation remains independent.
      const auto native_ttl = hit ? 60000 : 2000;
      const auto ttl = native_adapter::Decide(native_adapter::PolicyKind::CacheTtl,
          hit, 0, 0, native_ttl, identity);
      const bool expired = age >= ttl;
      native_adapter::Observe(native_adapter::PolicyKind::Cache, hit, age, generation_, age >= native_ttl);
      if (expired) { cache_.erase(found); found = cache_.end(); }
    }
    if (found == cache_.end()) {
      auto victim = std::find_if(cache_.begin(), cache_.end(), [](const auto& x) { return x.second.reply.has_value(); });
      if (!native_adapter::Decide(native_adapter::PolicyKind::Capacity,
          cache_.size() >= 256 ? 256 : 0, victim != cache_.end(), generation_,
          cache_.size() < 256 || victim != cache_.end(), identity)) return "4";
      if (cache_.size() >= 256) {
        if (victim == cache_.end()) return "4";
        cache_.erase(victim);
      }
      cache_[key] = {};
      jobs_.push_back({key, reading, config, generation_}); changed_.notify_all();
    }
    const auto generation = generation_;
    if (wait_ms) changed_.wait_for(lock, std::chrono::milliseconds(wait_ms), [&] {
      auto item = cache_.find(key);
      return stop_ || generation != generation_ || (item != cache_.end() && item->second.reply.has_value());
    });
    found = cache_.find(key);
    if (generation != generation_ || found == cache_.end()) return "4";
    return found->second.reply;
  }
 private:
  struct Entry { std::optional<std::string> reply; ULONGLONG completed = 0; };
  struct Job { std::string key, reading; DictionaryServerConfig config; uint64_t generation; };
  std::mutex mutex_; std::condition_variable changed_;
  std::map<std::string, Entry> cache_; std::deque<Job> jobs_;
  std::string identity_; uint64_t generation_ = 0; bool stop_ = false;
  std::thread worker_;
  void Run() {
    WSADATA data{}; const bool winsock = WSAStartup(MAKEWORD(2, 2), &data) == 0;
    for (;;) {
      Job job;
      { std::unique_lock lock(mutex_); changed_.wait(lock, [&] { return stop_ || !jobs_.empty(); });
        if (stop_) break; job = std::move(jobs_.front()); jobs_.pop_front(); }
      std::string reply = "4";
      if (winsock) {
        const bool debug = GetEnvironmentVariableW(L"DDSKK_HOST_DEBUG", nullptr, 0) > 0;
        const double connect_started = debug ? ProfileMilliseconds() : 0;
        SOCKET socket = ConnectDictionaryServer(job.config);
        if (debug)
          std::fprintf(stderr, "dictionary-source name=skkserv-connect ms=%.6f\n",
                       ProfileMilliseconds()-connect_started);
        if (socket != INVALID_SOCKET) {
          std::string response;
          const double server_started = debug ? ProfileMilliseconds() : 0;
          const bool found = SendAndReceive(socket, "1" + job.reading + " ", &response);
          if (debug)
            std::fprintf(stderr, "dictionary-source name=skkserv-query ms=%.6f\n",
                         ProfileMilliseconds()-server_started);
          if (found &&
              !response.empty() && (response[0] == '1' || response[0] == '4')) reply = std::move(response);
          closesocket(socket);
        } else if (!job.config.start_command.empty()) TrySpawnSkkServ(job.config.start_command);
      }
      { std::lock_guard lock(mutex_);
        if (job.generation == generation_) {
          auto item = cache_.find(job.key); if (item != cache_.end()) { item->second.reply = std::move(reply); item->second.completed = GetTickCount64(); }
        }
      }
      changed_.notify_all();
    }
    if (winsock) WSACleanup();
  }
};
ServerCache g_server_cache;
// Keep provider data opaque: expressions and okuri blocks belong to DDSKK,
// and must not be truncated by the local literal-candidate certification cap.
std::string MergeServerReply(std::string_view files, std::string_view server) {
  std::vector<std::string> words;
  for (auto raw : {files, server}) {
    size_t start = 0;
    for (;;) {
      const auto slash = raw.find('/', start); if (slash == raw.npos) break;
      if (slash > start) {
        const std::string word(raw.substr(start, slash - start));
        const bool found = std::any_of(words.begin(), words.end(), [&](const auto& existing) {
          const auto note = existing.find(';');
          return existing == word || (note != existing.npos && existing.substr(0, note) == word.substr(0, word.find(';')));
        });
        if (!found) words.push_back(word);
      }
      start = slash + 1;
    }
  }
  std::string result = "1/"; for (const auto& word : words) result += word + '/';
  return result;
}
// Serialize interpreter request/reply state separately from its metadata
// mutex. The cache/socket relay may wait while metadata/publication stays free;
// another transaction must not write to an interpreter awaiting SERVER input.
std::mutex g_interpreter_mutex;
std::mutex g_engine_mutex;
thread_local std::unique_lock<std::mutex>* g_relay_engine_lock = nullptr;
class EngineTransaction {
 public:
  EngineTransaction() : transaction_(g_interpreter_mutex), engine_(g_engine_mutex) {
    g_relay_engine_lock = &engine_;
  }
  explicit EngineTransaction(std::try_to_lock_t)
      : transaction_(g_interpreter_mutex, std::try_to_lock), engine_(g_engine_mutex, std::defer_lock) {
    if (transaction_.owns_lock() && engine_.try_lock()) g_relay_engine_lock = &engine_;
  }
  ~EngineTransaction() { if (g_relay_engine_lock == &engine_) g_relay_engine_lock = nullptr; }
  bool owns_lock() const { return engine_.owns_lock(); }
 private:
  std::unique_lock<std::mutex> transaction_, engine_;
};
struct RelayMetadataRelease {
  std::unique_lock<std::mutex>* lock = g_relay_engine_lock;
  RelayMetadataRelease() { if (lock) lock->unlock(); }
  ~RelayMetadataRelease() { if (lock) lock->lock(); }
};
std::string LookupDictionary(const std::string& midasi) {
  const bool debug = GetEnvironmentVariableW(L"DDSKK_HOST_DEBUG", nullptr, 0) > 0;
  const double lookup_started = debug ? ProfileMilliseconds() : 0;
  const std::string files = g_builtin_dictionary.ready.load(std::memory_order_acquire) ? MergeBuiltinCandidates(midasi) : "";
  if (debug) {
    std::fprintf(stderr, "dictionary-source name=builtin-index ms=%.6f\n",
                 ProfileMilliseconds()-lookup_started);
    std::fprintf(stderr, "ddskk-engine-host: lookup [%s]\n", midasi.c_str());
    std::fprintf(stderr, "ddskk-engine-host: builtin [%s]\n", files.c_str());
  }
  // Provider keys already run off the input thread. Give a miss at most 200ms
  // before registration; local hits do not use this waiting path.
  std::optional<std::string> server;
  {
    RelayMetadataRelease release;
    server = g_server_cache.Query(midasi, {}, 200);
  }
  if (!server || server->empty() || (*server)[0] != '1') return files.empty() ? "4" : "1" + files;
  const auto order = native_adapter::Decide(native_adapter::PolicyKind::Order,
      !files.empty(), 1, 0, files.empty() ? 2 : 1);
  if (order == 2) return *server;
  if (order == 0) return files.empty() ? "4" : "1" + files;
  return MergeServerReply(files, std::string_view(*server).substr(1));
}

void ShutdownDictionaryServer() {
  CloseDictionarySocket();
  if (g_dictionary_server.winsock_ready) {
    WSACleanup();
    g_dictionary_server.winsock_ready = false;
  }
}
// ---------------------------------------------------------------------------

// Independent of provider transactions so a cache read never queues behind
// conversion. A replacement child publishes its own effective rule table.
std::string g_romaji_rules;
std::mutex g_romaji_mutex;
std::string QuoteEngineString(std::string_view value) {
  std::string result = "\"";
  for (unsigned char ch : value) {
    if (ch == '"' || ch == '\\') { result += '\\'; result += static_cast<char>(ch); }
    else if (ch < 32 || ch == 127) {
      result += '\\';
      result += static_cast<char>('0' + ((ch >> 6) & 7));
      result += static_cast<char>('0' + ((ch >> 3) & 7));
      result += static_cast<char>('0' + (ch & 7));
    } else result += static_cast<char>(ch);
  }
  return result + '"';
}

std::string EngineDictionaryReply(const std::string& reply) {
  // Match the legacy Lisp slash scanner exactly: skip empty fields and
  // ignore any unterminated trailing field. The reader receives data only.
  if (reply.empty() || reply[0] != '1') return "LIST nil";
  std::string result = "LIST (";
  size_t start = 1;
  for (;;) {
    const size_t slash = reply.find('/', start);
    if (slash == std::string::npos) break;
    if (slash > start) result += QuoteEngineString(std::string_view(reply).substr(start, slash - start)) + ' ';
    start = slash + 1;
  }
  return result + ')';
}

// STATE2 is private to the host/engine link. Each body field is a decimal
// scalar count, ':', then UTF-8. Delimiters (including newlines) are data.
// Translate here so every DLL and state-mirror consumer retains STATE v1.
template <class ReadByte>
bool DecodeState2(const std::string& header, ReadByte read_byte,
                  std::string* response) {
  std::istringstream input(header);
  std::string tag, mode, extra;
  int cursor = 0, start = 0, index = 0, count = 0, registration = 0;
  if (!(input >> tag >> mode >> cursor >> start >> index >> count >> registration) ||
      (input >> extra) || tag != "STATE2" || cursor < 0 || start < -1 || index < -1 ||
      count < 0 || count > 4096 || (registration != 0 && registration != 1)) return false;
  size_t bytes = 0;
  const auto next = [&](unsigned char* ch) {
    return ++bytes <= 1048576 && read_byte(ch);
  };
  const auto field = [&](std::string* encoded) {
    unsigned char ch = 0;
    size_t scalars = 0, digits = 0;
    do {
      if (!next(&ch)) return false;
      if (ch == ':') break;
      if (ch < '0' || ch > '9' || ++digits > 6) return false;
      scalars = scalars * 10 + (ch - '0');
    } while (true);
    if (!digits || scalars > 65536) return false;
    encoded->clear();
    for (size_t i = 0; i < scalars; ++i) {
      if (!next(&ch)) return false;
      unsigned int code = ch, minimum = 0;
      int continuation = 0;
      if (ch < 0x80) {}
      else if (ch >= 0xc2 && ch <= 0xdf) { code = ch & 31; continuation = 1; minimum = 0x80; }
      else if (ch >= 0xe0 && ch <= 0xef) { code = ch & 15; continuation = 2; minimum = 0x800; }
      else if (ch >= 0xf0 && ch <= 0xf4) { code = ch & 7; continuation = 3; minimum = 0x10000; }
      else return false;
      for (int j = 0; j < continuation; ++j) {
        if (!next(&ch) || (ch & 0xc0) != 0x80) return false;
        code = (code << 6) | (ch & 63);
      }
      if (code < minimum || code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff)) return false;
      constexpr char hex[] = "0123456789abcdef";
      for (int shift = 20; shift >= 0; shift -= 4) encoded->push_back(hex[(code >> shift) & 15]);
    }
    if (encoded->empty()) *encoded = "-";
    return true;
  };
  std::string text, pending, candidates, reading;
  if (!field(&text) || !field(&pending)) return false;
  for (int i = 0; i < count; ++i) {
    std::string candidate;
    if (!field(&candidate)) return false;
    if (i) candidates += ',';
    candidates += candidate;
  }
  if (registration && !field(&reading)) return false;
  unsigned char end = 0;
  if (!next(&end) || end != '\n') return false;
  *response = "STATE " + mode + " " + std::to_string(cursor) + " " +
      std::to_string(start) + " " + text + " " + pending + " " +
      std::to_string(index) + " " + (count ? candidates : "-") +
      (registration ? " " + reading : "");
  return true;
}

// Raw UTF-8 checkpoint framing avoids interpreted per-character hex encoding.
template <class ReadByte>
bool DecodeLearning2(const std::string& header, ReadByte read_byte, std::string* response) {
  std::istringstream input(header);
  std::string tag, extra, content;
  size_t count = 0;
  if (!(input >> tag >> count) || (input >> extra) || tag != "LEARNING2" ||
      count > 1048576) return false;
  for (size_t i = 0; i < count; ++i) {
    unsigned char ch = 0;
    if (!read_byte(&ch)) return false;
    content.push_back(static_cast<char>(ch));
    int following = ch < 0x80 ? 0 : ch >= 0xc2 && ch <= 0xdf ? 1 :
        ch >= 0xe0 && ch <= 0xef ? 2 : ch >= 0xf0 && ch <= 0xf4 ? 3 : -1;
    if (following < 0) return false;
    for (int j = 0; j < following; ++j) {
      if (!read_byte(&ch) || (ch & 0xc0) != 0x80) return false;
      content.push_back(static_cast<char>(ch));
    }
  }
  unsigned char end = 0;
  if (!read_byte(&end) || end != '\n' || content.empty() ||
      !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, content.data(),
                          static_cast<int>(content.size()), nullptr, 0)) return false;
  *response = "LEARNING2 " + content;
  return true;
}

bool ReadEngineResponse(HANDLE pipe, std::string* response) {
  std::string header;
  if (!ReadLine(pipe, &header)) return false;
  if (!header.starts_with("STATE2 ") && !header.starts_with("LEARNING2 ")) { *response = std::move(header); return true; }
  const ULONGLONG deadline = GetTickCount64() + 90000;
  const auto read_byte = [&](unsigned char* ch) {
    for (;;) {
      DWORD available = 0, read = 0;
      if (g_stopping.load() || GetTickCount64() >= deadline ||
          !PeekNamedPipe(pipe, nullptr, 0, nullptr, &available, nullptr)) return false;
      if (!available) { WaitForEngineData(); continue; }
      return ReadFile(pipe, ch, 1, &read, nullptr) && read == 1;
    }
  };
  return header.starts_with("LEARNING2 ")
      ? DecodeLearning2(header, read_byte, response)
      : DecodeState2(header, read_byte, response);
}

std::string Utf8KeyRequest(const std::string& request) {
  size_t command = 0;
  if (request.starts_with("SESSION ")) {
    command = request.find(' ', 8);
    if (command == std::string::npos) return request;
    ++command;
  }
  for (const auto& name : {"CONVERT", "SYNC", "FEED", "REGISTER"}) {
    const std::string prefix = std::string("CONTROL ") + name + "-KEYS ";
    if (request.compare(command, prefix.size(), prefix)) continue;
    size_t pos = command + prefix.size();
    if (pos == request.size()) return request;
    std::string text;
    while (pos < request.size()) {
      unsigned int code = 0;
      size_t digits = 0;
      while (pos < request.size() && request[pos] != ',') {
        const char ch = request[pos++];
        if (ch < '0' || ch > '9' || ++digits > 7) return request;
        code = code * 10 + static_cast<unsigned int>(ch - '0');
        if (code > 0x10ffff) return request;
      }
      if (!digits || (code >= 0xd800 && code <= 0xdfff) || code == 10 || code == 13)
        return request; // These keys retain the original line-safe decimal path.
      if (code < 0x80) text.push_back(static_cast<char>(code));
      else {
        if (code < 0x800) text.push_back(static_cast<char>(0xc0 | (code >> 6)));
        else {
          if (code < 0x10000) text.push_back(static_cast<char>(0xe0 | (code >> 12)));
          else {
            text.push_back(static_cast<char>(0xf0 | (code >> 18)));
            text.push_back(static_cast<char>(0x80 | ((code >> 12) & 63)));
          }
          text.push_back(static_cast<char>(0x80 | ((code >> 6) & 63)));
        }
        text.push_back(static_cast<char>(0x80 | (code & 63)));
      }
      if (pos < request.size() && ++pos == request.size()) return request;
    }
    return request.substr(0, command) + "CONTROL " + name + "-UTF8 " + text;
  }
  return request;
}

// In-memory learning revisions wake the overlay publisher. Idle
// capability/recovery probes retain the previous one-second cadence.
std::atomic<uint64_t> g_local_ack_activity{0};
bool LearningSchedule(bool ready, bool draining) {
  return native_adapter::Decide(native_adapter::PolicyKind::Learning, ready, 1, draining, ready) != 0;
}
std::unique_ptr<ddskk::LearningQueue> g_learning_queue;
thread_local std::shared_future<bool> g_learning_barrier;
thread_local std::vector<std::shared_ptr<ddskk::LearningQueue::ProducerOperation>> g_learning_producers;
thread_local bool g_learning_producer_capture = false;

std::string LearningReply(std::string response, const std::shared_future<bool>& barrier) {
  bool appended = true;
  for (const auto& operation : g_learning_producers)
    if (!g_learning_queue->SealProducer(operation)) appended = false;
  g_learning_producers.clear();
  if (!appended) return "ERR LOCAL STORAGE";
  // LOCAL ACK retires an existing durable client spool; STATE is volatile session state.
  if (response.starts_with("ACK ") && barrier.valid() && !barrier.get())
    return "ERR LOCAL STORAGE";
  return response;
}

std::wstring LearningTarget() {
  wchar_t value[32768]{};
  DWORD size = GetEnvironmentVariableW(L"DDSKK_USER_JISYO", value, _countof(value));
  if (size && size < _countof(value)) return std::wstring(value, size);
  size = GetEnvironmentVariableW(L"LOCALAPPDATA", value, _countof(value));
  return size && size < _countof(value)
      ? std::wstring(value, size) + L"/DDSKK/user-jisyo.utf8" : L"";
}

bool Dispatch(Child& child, const std::string& request, std::string* response) {
  if (!child.wire_checked) {
    child.wire_checked = true;
    if (child.engine == "ddskk") {
      std::string reply;
      if (!WriteAll(child.input, "WIRE UTF8 1\n")) return false;
      do {
        if (!ReadLine(child.output, &reply)) return false;
      } while (reply.starts_with("PHASE "));
      child.utf8_wire = reply == "OK WIRE UTF8 1";
      if (!WriteAll(child.input, "WIRE LEARNING 2\n")) return false;
      do {
        if (!ReadLine(child.output, &reply)) return false;
      } while (reply.starts_with("PHASE "));
      child.learning_worker = reply == "OK WIRE LEARNING 2";
      if (child.learning_worker) {
        if (!g_learning_queue)
          g_learning_queue = std::make_unique<ddskk::LearningQueue>(LearningTarget(),
              std::function<bool(const std::string&)>{}, LearningSchedule);
        if (!WriteAll(child.input, "LOCAL STATUS\n")) return false;
        do { if (!ReadLine(child.output, &reply)) return false; } while (reply.starts_with("PHASE "));
        child.local_status = reply;
      }
      // Old engines answer ERR REQUEST and retain their original writer.
      // New engines publish immutable checkpoints to the native worker.

    }
  }
  const ULONGLONG started = GetTickCount64();
  const double profile_started = ProfileMilliseconds();
  const bool debug = GetEnvironmentVariableW(L"DDSKK_HOST_DEBUG", nullptr, 0) > 0;
  PROCESS_MEMORY_COUNTERS memory{};
  const auto cpu_time = [&child]() {
    FILETIME created{}, exited{}, kernel{}, user{};
    if (!GetProcessTimes(child.process, &created, &exited, &kernel, &user)) return ULONGLONG{0};
    return (static_cast<ULONGLONG>(kernel.dwHighDateTime) << 32) + kernel.dwLowDateTime +
        (static_cast<ULONGLONG>(user.dwHighDateTime) << 32) + user.dwLowDateTime;
  };
  const ULONGLONG cpu_started = debug ? cpu_time() : 0;
  if (debug) {
    K32GetProcessMemoryInfo(child.process, &memory, sizeof(memory));
    std::fprintf(stderr, "dispatch tick=%llu pid=%lu ws_mb=%llu faults=%lu request=%s\n",
        started, GetProcessId(child.process), memory.WorkingSetSize/1048576,
        memory.PageFaultCount, request.c_str());
  }
  if (!WriteAll(child.input, (child.utf8_wire ? Utf8KeyRequest(request) : request) + "\n")) return false;
  // Bounded guard: a buggy/adversarial engine that keeps emitting
  // "SERVER " lines instead of ever producing a real response must not be
  // able to wedge this loop (and thus the whole host) forever.
  constexpr int kMaxServerExchangesPerRequest = 64;
  int server_exchanges = 0;
  double phase_started = profile_started;
  ULONGLONG legacy_phase_started = started;
  ULONGLONG phase_cpu_started = cpu_started;
  std::string phase = "dispatch";
  for (;;) {
    std::string line;
    if (!ReadEngineResponse(child.output, &line)) return false;
    if (line.starts_with("PHASE ")) {
      const double now = ProfileMilliseconds();
      if (debug) {
        const ULONGLONG tick = GetTickCount64();
        std::fprintf(stderr, "engine-phase name=%s ms=%llu next=%s\n",
            phase.c_str(), tick - legacy_phase_started, line.c_str() + 6);
        legacy_phase_started = tick;
        std::fprintf(stderr, "engine-phase-qpc name=%s ms=%.6f next=%s\n",
            phase.c_str(), now - phase_started, line.c_str() + 6);
      }
      if (debug) {
        const ULONGLONG now_cpu = cpu_time();
        std::fprintf(stderr, "engine-phase-cpu name=%s ms=%llu next=%s\n",
            phase.c_str(), (now_cpu - phase_cpu_started) / 10000, line.c_str() + 6);
        phase_cpu_started = now_cpu;
      }
      phase = line.substr(6);
      phase_started = now;
      continue;
    }
    if (line == "LOCAL-PUBLISH") {
      // Learning and later engine compaction publish the same checkpoint.
      // Neither its target nor its temporary name comes from wire input.
      if (++server_exchanges > kMaxServerExchangesPerRequest)
        return false;
      wchar_t value[32768]{};
      DWORD length = GetEnvironmentVariableW(L"DDSKK_USER_JISYO", value, _countof(value));
      std::wstring target;
      if (length && length < _countof(value)) target.assign(value, length);
      else if (!length) {
        length = GetEnvironmentVariableW(L"LOCALAPPDATA", value, _countof(value));
        if (length && length < _countof(value)) target = std::wstring(value, length) + L"/DDSKK/user-jisyo.utf8";
      }
      const std::wstring temporary = target + L".local-checkpoint";
      HANDLE checkpoint = target.empty() ? INVALID_HANDLE_VALUE :
          CreateFileW(temporary.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
      bool published = checkpoint != INVALID_HANDLE_VALUE && FlushFileBuffers(checkpoint);
      if (checkpoint != INVALID_HANDLE_VALUE) CloseHandle(checkpoint);
      if (published) published = MoveFileExW(temporary.c_str(), target.c_str(),
                                            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
      if (!WriteAll(child.input, published ? "LOCAL-PUBLISHED\n" : "ERR LOCAL STORAGE\n")) return false;
      continue;
    }
    if (line.starts_with("LEARNING2 ")) {
      if (!g_learning_queue)
        g_learning_queue = std::make_unique<ddskk::LearningQueue>(LearningTarget(),
              std::function<bool(const std::string&)>{}, LearningSchedule);
      const auto content = line.substr(10);
      if (content.empty()) return false;
      if (request.starts_with("LOCAL LEARN ") || !g_learning_producer_capture) {
        g_learning_barrier = g_learning_queue->Submit(content);
      } else {
        auto operation = g_learning_queue->ReserveProducer(content);
        if (!operation) return false;
        g_learning_barrier = operation->done;
        g_learning_producers.push_back(std::move(operation));
      }
      g_local_ack_activity.fetch_add(1, std::memory_order_release);
      continue;
    }
    if (line.rfind("SERVER ", 0) == 0) {
      // Out-of-band dictionary lookup: answer it and keep reading for the
      // real response. The engine blocks on its stdin until this arrives.
      if (++server_exchanges > kMaxServerExchangesPerRequest) return false;
      const double relay_started = ProfileMilliseconds();
      const ULONGLONG legacy_relay_started = GetTickCount64();
      const std::string found = LookupDictionary(line.substr(7));
      const std::string reply = child.utf8_wire ? EngineDictionaryReply(found) : found;
      if (debug) {
        std::fprintf(stderr, "dictionary-relay ms=%llu\n", GetTickCount64()-legacy_relay_started);
        std::fprintf(stderr, "dictionary-relay-qpc ms=%.6f\n", ProfileMilliseconds()-relay_started);
      }
      if (!WriteAll(child.input, reply + "\n")) return false;
      continue;
    }
    *response = line;
    if (request.starts_with("LOCAL LEARN ") && line.starts_with("ACK "))
      g_local_ack_activity.fetch_add(1, std::memory_order_release);
    if (debug) {
      PROCESS_MEMORY_COUNTERS after{};
      K32GetProcessMemoryInfo(child.process, &after, sizeof(after));
      std::fprintf(stderr, "dispatch done pid=%lu ms=%llu cpu_ms=%llu ws_mb=%llu faults_delta=%lu relay_count=%d qpc_ms=%.6f\n",
          GetProcessId(child.process), GetTickCount64()-started,
          (cpu_time()-cpu_started)/10000, after.WorkingSetSize/1048576,
          after.PageFaultCount-memory.PageFaultCount, server_exchanges,
          ProfileMilliseconds()-profile_started);
    }
    return true;
  }
}

bool DispatchConvertKeys(Child& child, const std::string& request,
                         std::string* response) {
  constexpr std::string_view prefix = "CONTROL CONVERT-KEYS ";
  if (!request.starts_with(prefix)) return false;
  const std::string_view encoded(request.data() + prefix.size(),
                                 request.size() - prefix.size());
  if (encoded.empty() || encoded.size() > 8192) return false;

  // This entire helper runs under g_engine_mutex.  No other client can see
  // RESET or any replayed intermediate key; only the final candidate STATE
  // is returned/published.
  std::string ignored;
  if (!Dispatch(child, "RESET", &ignored)) return false;
  size_t start = 0;
  size_t count = 0;
  while (start < encoded.size()) {
    const size_t comma = encoded.find(',', start);
    const size_t end = comma == std::string_view::npos ? encoded.size() : comma;
    if (end == start || ++count > 1024) return false;
    uint32_t codepoint = 0;
    for (size_t index = start; index < end; ++index) {
      const char value = encoded[index];
      if (value < '0' || value > '9') return false;
      codepoint = codepoint * 10 + static_cast<uint32_t>(value - '0');
      if (codepoint > 0x10ffff) return false;
    }
    if (codepoint >= 0xd800 && codepoint <= 0xdfff) return false;
    if (!Dispatch(child, "KEY " + std::to_string(codepoint), &ignored))
      return false;
    if (comma == std::string_view::npos) break;
    start = comma + 1;
  }
  // DDSKK starts okuri-ari conversion automatically when the final
  // okurigana syllable resolves (for example KieRu becomes a candidate on
  // the KEY 'u' response). Sending CONTROL CONVERT once more here advances
  // past that freshly produced candidate; a one-candidate entry then looks
  // exhausted and incorrectly opens registration. Preserve the automatic
  // conversion response as the barrier's final result.
  if (ignored.rfind("STATE candidate ", 0) == 0 ||
      ignored.rfind("STATE registration ", 0) == 0) {
    *response = std::move(ignored);
    return true;
  }
  return Dispatch(child, "CONTROL CONVERT", response);
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
// All connections share exactly one `g_child` NeLisp process.  Each native
// client prefixes requests with a stable SESSION id, and the engine swaps a
// complete SKK checkpoint when that id changes. EngineTransaction serializes
// active interpreter access and child replacement/teardown. Its engine metadata
// mutex is released during the bounded SERVER cache wait; its interpreter gate
// prevents another client's bytes from interleaving with that sub-exchange.
// External sockets and native overlay encoding never hold the engine mutex.
// ---------------------------------------------------------------------------
Child g_child;
std::atomic<uint64_t> g_pending_requests{0};
struct PendingRequest {
  PendingRequest() { g_pending_requests.fetch_add(1, std::memory_order_acq_rel); }
  ~PendingRequest() { g_pending_requests.fetch_sub(1, std::memory_order_acq_rel); }
};
std::wstring g_executable, g_repository;
std::string g_current_engine;
std::mutex g_switch_mutex;
std::string g_requested_engine;
std::string g_published_engine; // guarded by g_switch_mutex
uint64_t g_switch_generation = 0;
uint64_t g_completed_generation = 0;
std::wstring g_pipe_name;  // Set once in wmain before any thread starts.
std::atomic<uint64_t> g_next_client_id{1};
// Guarded by g_engine_mutex.  Retained for pre-SESSION clients only; scoped
// clients own their independent engine checkpoints and bypass this legacy
// focus/reset arbitration.
uint64_t g_active_input_client = 0;

// Guarded by g_engine_mutex. A reconnect transfers ownership of its stable
// session id to the new pipe worker. The old worker therefore cannot close a
// session that has already resumed on a replacement connection.
std::unordered_map<std::string, uint64_t> g_session_owners;
std::unordered_set<std::string> g_composing_sessions;

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
// A sub-second/two-second idle window makes ordinary thinking pauses race
// the 300-900 ms collector, so the first key after the pause feels frozen.
// Ten seconds still collects between real work bursts without putting GC
// on the normal type-pause-type path.
constexpr DWORD kDefaultIdleGcMs = 10000;

std::atomic<uint64_t> g_last_activity_tick{0};
std::atomic<bool> g_gc_pending{false};
// True once at least one real client transaction has completed. Gates
// `IdleGcLoop()' so it can never fire while DDSKK is still doing its own
// multi-second synchronous load at process startup (before any client has
// ever connected, there is nothing to collect and no reason to contend
// for `g_engine_mutex' against the first real client's own request).
std::atomic<bool> g_engine_active{false};
// True when any scoped (or legacy) STATE reply on the ServeClient() request
// path reports mode "preedit" or "candidate" -- i.e. DDSKK is mid-composition
// and a user may be reading a candidate before their next keystroke.
// See the "Composition-in-progress suppression" paragraph in the block
// comment above IdleGcLoop() for why this gates collection.
std::atomic<bool> g_session_composing{false};

std::string SessionIdFromRequest(const std::string& request) {
  if (request.rfind("SESSION ", 0) != 0) return {};
  const size_t separator = request.find(' ', 8);
  if (separator == std::string::npos || separator == 8) return {};
  return request.substr(8, separator - 8);
}

void NoteActivity() {
  g_last_activity_tick.store(GetTickCount64(), std::memory_order_release);
  g_gc_pending.store(true, std::memory_order_release);
  g_engine_active.store(true, std::memory_order_release);
}

bool ValidEngineId(const std::string& id) {
  return id == "ddskk" || id == "passthrough" || id == "lattice" || id == "dictionary";
}

void QueueReplacement(const std::string& id, bool force = false) {
  std::lock_guard<std::mutex> lock(g_switch_mutex);
  if (!force && g_switch_generation != g_completed_generation &&
      g_requested_engine == id) return;
  g_requested_engine = id;
  ++g_switch_generation;
  LogEvent(std::string(force ? "reload" : "switch") + " engine=" + id +
      " generation=" + std::to_string(g_switch_generation));
}

// One worker owns all replacement children. Startup/readiness never holds
// the engine mutex; the old child continues to serve complete transactions.
// A killed application cannot run TextService::Deactivate. Sweep only dead
// process IDs, conservatively retaining entries we cannot inspect.
void RemoveDeadClients() {
  const std::wstring path = NativeImeRegistryKey() + L"\\Clients";
  HKEY clients = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, path.c_str(), 0,
      KEY_ENUMERATE_SUB_KEYS | KEY_WRITE, &clients) != ERROR_SUCCESS) return;
  DWORD index = 0;
  wchar_t name[64]{};
  DWORD length = _countof(name);
  while (RegEnumKeyExW(clients, index, name, &length, nullptr, nullptr,
                       nullptr, nullptr) == ERROR_SUCCESS) {
    wchar_t* end = nullptr;
    const unsigned long pid = wcstoul(name, &end, 10);
    bool dead = false;
    if (pid != 0 && end != name && *end == 0) {
      HANDLE process = OpenProcess(SYNCHRONIZE, FALSE, pid);
      if (process != nullptr) {
        dead = WaitForSingleObject(process, 0) == WAIT_OBJECT_0;
        CloseHandle(process);
      } else {
        dead = GetLastError() == ERROR_INVALID_PARAMETER;
      }
    }
    if (!dead || RegDeleteTreeW(clients, name) != ERROR_SUCCESS) ++index;
    length = _countof(name);
  }
  RegCloseKey(clients);
}

void ReplacementLoop() {
  DWORD backoff = 1000;
  ULONGLONG retry_at = 0;
  ULONGLONG next_client_sweep = 0;
  while (!g_stopping.load()) {
    Sleep(100);
    if (GetTickCount64() >= next_client_sweep) {
      RemoveDeadClients();
      next_client_sweep = GetTickCount64() + 1000;
    }
    std::string id;
    uint64_t generation;
    {
      std::lock_guard<std::mutex> lock(g_switch_mutex);
      generation = g_switch_generation;
      if (generation != g_completed_generation) id = g_requested_engine;
    }
    if (id.empty()) {
      EngineTransaction lock;
      if (g_child.process && WaitForSingleObject(g_child.process, 0) == WAIT_TIMEOUT) continue;
      LogChildExit(g_child, false);
      id = g_current_engine;
      LogEvent("respawn engine=" + id);
    }
    if (GetTickCount64() < retry_at) continue;
    std::pair<uint64_t, std::shared_future<bool>> learning_fence;
    {
      EngineTransaction lock;
      if (g_learning_queue) learning_fence = g_learning_queue->Fence();
    }
    // A replacement must load a durable dictionary. Waiting for storage here
    // never holds the active engine's transaction mutex.
    if (learning_fence.second.valid() && !learning_fence.second.get()) {
      // The failed operation was never acknowledged. Respawn from the last
      // durable checkpoint so its existing operation-id spool can retry.
      LogEvent("replacement-learning-storage-failed engine=" + id);
    }
    Child next;
    std::string reply;
    const std::wstring wide_id(id.begin(), id.end());
    bool ready = StartChild(g_executable, g_repository, &next, wide_id, true) &&
        WriteAll(next.input, "ENGINE CURRENT\n") && ReadLine(next.output, &reply);
    LogEvent("replacement-current engine=" + id + " ready=" + (ready ? "true" : "false"));
    std::string next_rules;
    if (ready && id == "ddskk")
      ready = WriteAll(next.input, "ROMAJI RULES 1\n") &&
          ReadLine(next.output, &next_rules) && next_rules.starts_with("RULES 1 ");
    // DDSKK's runner defaults to ddskk; select passthrough before publication.
    if (ready && reply != "ENGINE " + id) {
      ready = WriteAll(next.input, "ENGINE SET " + id + "\n") &&
          ReadLine(next.output, &reply) && reply == "OK ENGINE " + id;
    }
    std::string replacement_state;
    const std::string warmup = "SESSION host-warmup-" +
        std::to_string(GetCurrentProcessId()) + "-" +
        std::to_string(GetProcessId(next.process));
    if (ready) ready = WriteAll(next.input, warmup + " RESET\n") &&
        ReadLine(next.output, &replacement_state) && replacement_state.starts_with("STATE ");
    if (ready) ready = WriteAll(next.input, warmup + " CLOSE\n") &&
        ReadLine(next.output, &reply) && reply == "OK CLOSED";
    // DDSKK wraps even management commands in its legacy checkpoint.
    // Readiness must not leave an unowned session in the published child.
    if (ready) ready = WriteAll(next.input, "SESSION legacy CLOSE\n") &&
        ReadLine(next.output, &reply) && reply == "OK CLOSED";
    LogEvent("replacement-reset engine=" + id + " ready=" + (ready ? "true" : "false"));
    std::vector<std::string> prepared_sessions;
    if (ready) {
      {
        EngineTransaction lock;
        for (const auto& owner : g_session_owners) prepared_sessions.push_back(owner.first);
      }
      // Session creation/reset can itself be cold. Pay it on the unpublished
      // child, never inside the active engine's transaction mutex.
      for (const auto& session : prepared_sessions) {
        ready = WriteAll(next.input, "SESSION " + session + " RESET\n") &&
            ReadLine(next.output, &reply) && reply.starts_with("STATE ");
        if (!ready) break;
      }
    }
    if (!ready || g_stopping.load()) {
      LogEvent("replacement-abandoned engine=" + id);
      StopChild(next);
      retry_at = GetTickCount64() + backoff;
      backoff = static_cast<DWORD>(native_adapter::Decide(native_adapter::PolicyKind::Restart,
          backoff, 0, generation, (std::min)(backoff * 2, DWORD{30000})));
      continue;
    }
    Child old;
    bool swapped = false;
    const ULONGLONG deadline = GetTickCount64() + 5000;
    while (!g_stopping.load()) {
      {
        EngineTransaction engine_lock;
        std::unique_lock<std::mutex> switch_lock(g_switch_mutex);
        if (generation != g_switch_generation || g_private_handover.load()) break; // superseded/quiescing
        if (id == "ddskk" && g_learning_queue &&
            g_learning_queue->Fence().first != learning_fence.first) {
          // A confirmation arrived during cold loading. Retry from the next
          // durable checkpoint, including for an old engine without v2.
          LogEvent("replacement-learning-raced engine=" + id);
          break;
        }
        const bool swap_due = g_composing_sessions.empty() || GetTickCount64() >= deadline;
        const bool policy_swap = native_adapter::Decide(native_adapter::PolicyKind::Replacement,
            1, !g_composing_sessions.empty(), GetTickCount64() >= deadline, swap_due,
            id) != 0;
        // Native readiness/generation/fence checks remain mandatory barriers.
        if (swap_due && policy_swap) {
          old = g_child;
          g_child = next;
          native_adapter::engine_epoch = g_child.epoch;
          if (g_learning_queue) g_learning_queue->Submit("");
          { std::lock_guard<std::mutex> rules_lock(g_romaji_mutex);
            g_romaji_rules = std::move(next_rules); }
          SetPriorityClass(g_child.process, NORMAL_PRIORITY_CLASS);
          next = {};
          g_current_engine = id;
          g_published_engine = id;
          g_completed_generation = generation;
          switch_lock.unlock();
          // Prepared sessions are reset already. Sessions opened during
          // preparation have no checkpoint in the fresh process and start
          // empty on first use. Preserve the host's connection ownership.
          g_composing_sessions.clear();
          g_session_composing.store(false);
          g_active_input_client = 0;
          PublishStateMirror(replacement_state);
          swapped = true;
          LogEvent("replacement-published engine=" + id + " pid=" +
              std::to_string(GetProcessId(g_child.process)));
        }
      }
      if (swapped) break;
      Sleep(50);
    }
    StopChild(old);
    StopChild(next);
    if (swapped && !g_stopping.load()) {
      EngineTransaction lock;
      for (const auto& session : prepared_sessions) {
        if (!g_session_owners.contains(session)) {
          std::string ignored;
          Dispatch(g_child, "SESSION " + session + " CLOSE", &ignored);
        }
      }
    }
    backoff = static_cast<DWORD>(native_adapter::Decide(native_adapter::PolicyKind::Restart,
        backoff, 1, generation, 1000));
    retry_at = 0;
  }
}

void WatchEngineRegistry(std::wstring previous) {
  HKEY key = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, NativeImeRegistryKey().c_str(), 0,
                    KEY_NOTIFY, &key) != ERROR_SUCCESS) return;
  HANDLE changed = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  while (!g_stopping.load()) {
    if (RegNotifyChangeKeyValue(key, FALSE, REG_NOTIFY_CHANGE_LAST_SET,
                                changed, TRUE) != ERROR_SUCCESS) break;
    const std::wstring id = ConfiguredEngineId(false);
    const std::string narrow = NarrowEngineId(id);
    if (id != previous && ValidEngineId(narrow)) QueueReplacement(narrow);
    previous = id;
    DWORD result;
    do { result = WaitForSingleObject(changed, 100); }
    while (result == WAIT_TIMEOUT && !g_stopping.load());
    if (result != WAIT_OBJECT_0) break;
  }
  CloseHandle(changed);
  RegCloseKey(key);
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
  if (RegOpenKeyExW(HKEY_CURRENT_USER, NativeImeRegistryKey().c_str(), 0, KEY_READ,
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
    if (g_pending_requests.load(std::memory_order_acquire)) continue;

    {
      EngineTransaction lock(std::try_to_lock);
      if (!lock.owns_lock() || g_pending_requests.load(std::memory_order_acquire)) continue;
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
      LogEvent("collection reason=idle");
      if (!Dispatch(g_child, "GC", &response)) {
        // Recovery belongs to ReplacementLoop, including death at idle.
        continue;
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
        continue;
      }
    }
  }
}
// ---------------------------------------------------------------------------

// `first_instance` must be true for exactly the very first pipe instance
// this process creates, and false for every spare instance created after
// it (see the accept loop in wmain()). Passing FILE_FLAG_FIRST_PIPE_INSTANCE
// only on that first call is what makes CreateNamedPipeW fail with
// ERROR_ACCESS_DENIED if another process already owns an instance of this
// pipe name -- belt-and-braces alongside the SingletonMutexName() guard
// in wmain() for the same two-hosts-at-once field incident (see there);
// passing it again on a later, same-process spare instance would be
// meaningless (this process already owns the name by then) but is still
// avoided so the flag's presence always means exactly "first instance,
// first process."
HANDLE CreatePipeInstance(bool first_instance) {
  const DWORD open_mode = PIPE_ACCESS_DUPLEX |
      (first_instance ? FILE_FLAG_FIRST_PIPE_INSTANCE : 0);
  return CreateNamedPipeW(
      g_pipe_name.c_str(), open_mode,
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
  if (g_learning_queue) g_learning_queue->BeginDrain();
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
bool LocalConversionRequested() {
  wchar_t registry[256]{}, test_enabled[2]{};
  if (GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", nullptr, 0) &&
      GetEnvironmentVariableW(L"NATIVEIME_REGISTRY_KEY", registry, 256) &&
      std::wstring(registry).starts_with(L"Software\\NativeIME-test-") &&
      GetEnvironmentVariableW(L"NATIVEIME_TEST_LOCAL_CONVERSION", test_enabled, 2)) return test_enabled[0] == L'1';
  HKEY key = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, NativeImeRegistryKey().c_str(), 0, KEY_READ, &key) != ERROR_SUCCESS)
    return false;
  DWORD value = 0, bytes = sizeof(value), type = 0;
  bool enabled = RegQueryValueExW(key, L"LocalConversion", nullptr, &type,
      reinterpret_cast<BYTE*>(&value), &bytes) == ERROR_SUCCESS && type == REG_DWORD && value == 1;
  HKEY apps = nullptr;
  if (!enabled && RegOpenKeyExW(key, L"Apps", 0, KEY_READ, &apps) == ERROR_SUCCESS) {
    for (DWORD n = 0; !enabled; ++n) {
      wchar_t name[256]{}; DWORD size = _countof(name);
      if (RegEnumKeyExW(apps, n, name, &size, nullptr, nullptr, nullptr, nullptr) != ERROR_SUCCESS) break;
      HKEY app = nullptr;
      if (RegOpenKeyExW(apps, name, 0, KEY_READ, &app) == ERROR_SUCCESS) {
        bytes = sizeof(value); value = 0;
        enabled = RegQueryValueExW(app, L"LocalConversion", nullptr, &type,
            reinterpret_cast<BYTE*>(&value), &bytes) == ERROR_SUCCESS && type == REG_DWORD && value == 1;
        RegCloseKey(app);
      }
    }
    RegCloseKey(apps);
  }
  RegCloseKey(key);
  return enabled;
}

// Snapshot discovery includes file metadata, while publication hashes source
// contents only when that metadata changes. Learning never scans a base file.
std::string LocalSourceIdentity(const DictionaryServerConfig& config) {
  std::string identity = ddskk::local::Utf8(config.dictionary_files) + std::to_string(config.enabled) + ":" +
      ddskk::local::Utf8(config.host) + ":" + std::to_string(config.port);
  size_t start = 0;
  while (start < config.dictionary_files.size()) {
    auto end = config.dictionary_files.find(L';', start);
    if (end == config.dictionary_files.npos) end = config.dictionary_files.size();
    if (end > start) {
      const std::filesystem::path file(config.dictionary_files.substr(start, end - start));
      identity += ":" + std::to_string(std::filesystem::file_size(file)) + ":" +
          std::to_string(std::filesystem::last_write_time(file).time_since_epoch().count());
    }
    start = end + 1;
  }
  return identity;
}

// The checkpoint ACK makes replay safe even if the host crashes between
// replay and deletion. Never claim a live process's queue or lease.
void RecoverLocalSpools(const std::filesystem::path& directory) {
  if (!std::filesystem::exists(directory)) return;
  for (const auto& item : std::filesystem::directory_iterator(directory)) {
    const auto name = item.path().filename().string();
    if (!name.starts_with("pending-")) continue;
    const auto end = name.find('-', 8);
    if (end == name.npos) continue;
    const auto digits = name.substr(8, end - 8);
    if (digits.empty() || digits.find_first_not_of("0123456789") != digits.npos) continue;
    const auto pid = static_cast<DWORD>(std::stoull(digits));
    HANDLE process = OpenProcess(SYNCHRONIZE, FALSE, pid);
    const bool exited = process ? WaitForSingleObject(process, 0) == WAIT_OBJECT_0 : GetLastError() == ERROR_INVALID_PARAMETER;
    if (process) CloseHandle(process);
    if (!exited) continue;
    if (name.ends_with(".queue.lock") && !std::filesystem::exists(item.path().wstring().substr(0, item.path().wstring().size() - 5))) {
      HANDLE lease = CreateFileW(item.path().c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, 0, nullptr);
      if (lease != INVALID_HANDLE_VALUE) { CloseHandle(lease); DeleteFileW(item.path().c_str()); }
      continue;
    }
    if (!name.ends_with(".queue")) continue;
    const auto lease_path = item.path().wstring() + L".lock";
    HANDLE lease = CreateFileW(lease_path.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_ALWAYS, 0, nullptr);
    if (lease == INVALID_HANDLE_VALUE) continue;
    bool acknowledged = true;
    {
      std::ifstream input(item.path());
      if (!input) acknowledged = false;
      std::string line;
      while (acknowledged && std::getline(input, line)) {
        std::istringstream row(line);
        std::string id, key, word, okuri; uint64_t sequence = 0;
        if (!(row >> id >> key >> word >> sequence) || id.size() > 96 || key.size() > 1536 || word.size() > 8192) {
          acknowledged = false; break;
        }
        row >> okuri;
        std::string response;
        const auto request = "LOCAL LEARN " + id + " " + key + " " + word + (okuri.empty() || okuri == "-" ? "" : " " + okuri);
        g_learning_barrier = {};
        {
          PendingRequest pending_request;
          NoteActivity();
          EngineTransaction lock;
          acknowledged = g_current_engine == "ddskk" && Dispatch(g_child, request, &response) && response.starts_with("ACK " + id + " ");
        }
        if (acknowledged && g_learning_barrier.valid())
          acknowledged = g_learning_barrier.get();
      }
    }
    if (acknowledged) DeleteFileW(item.path().c_str());
    CloseHandle(lease);
    if (acknowledged) DeleteFileW(lease_path.c_str());
  }
}

void LocalSpoolRecoveryLoop() {
  ULONGLONG next = 0;
  while (!g_stopping.load()) {
    if (GetTickCount64() >= next) {
      try {
        if (LocalConversionRequested()) RecoverLocalSpools(ddskk::local::Directory());
      } catch (const std::exception& error) {
        std::fprintf(stderr, "LOCAL spool recovery unavailable: %s\n", error.what());
      }
      next = GetTickCount64() + 1000;
    }
    Sleep(50);
  }
}

void LocalPublicationLoop() {
  std::string previous;
  ddskk::local::PublicationWindow window;
  std::string published_base;
  bool test_stalled = false;
  std::shared_ptr<const ddskk::local::Index> mapped;
  ULONGLONG next_cleanup = 0, next_probe = 0;
  uint64_t observed_acks = 0;
  while (!g_stopping.load()) {
    try {
      if (!LocalConversionRequested()) {
        // Keep pending mirror fragments bounded even while local conversion
        // is disabled. No full-table serialization or interpreter request.
        if (GetTickCount64() >= next_probe) {
          ddskk::LearningQueue* native = nullptr;
          { std::unique_lock lock(g_engine_mutex, std::try_to_lock);
            if (lock.owns_lock() && g_child.learning_worker) native = g_learning_queue.get(); }
          if (native) native->UpdateOverlay();
          next_probe = GetTickCount64() + 1000;
        }
        Sleep(50); continue;
      }
      {
        const auto directory = ddskk::local::Directory();
        if (GetTickCount64() >= next_cleanup) {
          try {
            auto current = ddskk::local::OpenPublished(directory, mapped);
            ddskk::local::Cleanup(directory, current);
            // The host pins only the reusable base. Current overlays belong
            // to clients; retaining one here would delay collection after exit.
            mapped = current->Base();
          } catch (...) { }
          next_cleanup = GetTickCount64() + 1000;
        }
        const auto now = GetTickCount64();
        const auto acks = g_local_ack_activity.load(std::memory_order_acquire) +
            (g_learning_queue ? g_learning_queue->OverlayGeneration() : 0);
        if (acks != observed_acks) { observed_acks = acks; window.Changed(now); }
        if (now < next_probe && !window.Ready(now)) {
          Sleep(50); continue;
        }
        next_probe = now + 1000;
        DictionaryServerConfig config;
        std::string status, snapshot, rules, source_identity, base_identity;
        ddskk::LearningQueue* native = nullptr;
        uint64_t policy_engine_epoch = 0;
        {
          // Metadata copy only for v2. Never scan, serialize or read dictionary
          // files with interpreter ownership. Legacy engines retain SNAPSHOT.
          std::unique_lock<std::mutex> lock(g_engine_mutex, std::try_to_lock);
          if (!lock.owns_lock() || (g_pending_requests.load() && !g_child.learning_worker)) {
            if (lock.owns_lock()) lock.unlock(); Sleep(1); continue;
          }
          // A legacy snapshot talks to the interpreter. Its queue check is
          // insufficient for an idle/internal transaction awaiting SERVER.
          // Try the gate while holding metadata; never wait in reverse order.
          std::unique_lock<std::mutex> legacy_transaction(g_interpreter_mutex, std::defer_lock);
          if (!g_child.learning_worker && !legacy_transaction.try_lock()) {
            lock.unlock(); Sleep(1); continue;
          }
          config = g_dictionary_server.config;
          policy_engine_epoch = g_child.epoch;
          if (g_current_engine == "ddskk") {
            { std::lock_guard<std::mutex> rules_lock(g_romaji_mutex); rules = g_romaji_rules; }
            if (g_child.learning_worker) { native = g_learning_queue.get(); status = g_child.local_status; }
            else { Dispatch(g_child, "LOCAL STATUS", &status); }
          }
          if (!native && !rules.empty() && status.starts_with("LOCAL "))
            Dispatch(g_child, "LOCAL SNAPSHOT", &snapshot);
        }
        source_identity = LocalSourceIdentity(config);
        std::string native_overlay;
        if (native && status.starts_with("LOCAL ")) {
          native_overlay = native->OverlaySnapshot();
          status = status.substr(0, status.rfind(' ') + 1) + std::to_string(native->OverlayRevision());
          snapshot = "NATIVE";
        }
        const auto overlay_generation = native ? std::to_string(native->SnapshotGeneration()) : "";
        const auto identity = status + rules + source_identity + overlay_generation;
        base_identity = status.substr(0, status.rfind(' ')) + rules + source_identity;
        const bool have_rules = !rules.empty(), have_status = status.starts_with("LOCAL ");
        // Preserve the original short circuit: Due mutates the native window.
        const bool due = have_rules && have_status && window.Due(identity, base_identity, GetTickCount64());
        const auto intent_at = GetTickCount64();
        const bool immediate = previous.empty() || base_identity != published_base;
        const bool publish = native_adapter::Decide(native_adapter::PolicyKind::Intent,
            have_rules && have_status, identity != previous,
            immediate ? 1 : (window.Ready(intent_at) ? 2 : 0), due,
            status + ":" + source_identity, policy_engine_epoch) != 0;
        const auto payload = native_adapter::Decide(native_adapter::PolicyKind::Payload,
            have_rules && have_status, immediate, identity != previous,
            !have_rules || !have_status ? 0 : (immediate ? 2 : (identity != previous ? 1 : 0)),
            status + ":" + source_identity, policy_engine_epoch);
        if (!publish || !payload) snapshot.clear();
        if (!snapshot.empty()) {
          std::vector<std::filesystem::path> files;
          size_t start = 0;
          while (start < config.dictionary_files.size()) {
            auto end = config.dictionary_files.find(L';', start);
            if (end == config.dictionary_files.npos) end = config.dictionary_files.size();
            if (end > start) files.emplace_back(config.dictionary_files.substr(start, end - start));
            start = end + 1;
          }
          const auto overlay = native
              ? native_overlay + (status.starts_with("LOCAL 0 ") ? "" :
                  ";; local-literal-profile 1 879b04a00ff3ffa629025a330ece9b65488fc9494e9b883d4dda104f0751edc8\n")
              : ddskk::local::Utf8(ddskk::local::Unhex(snapshot.substr(8)));
          std::istringstream metadata(status);
          std::string label; uint64_t flags = 0, revision = 0;
          if (!(metadata >> label >> flags >> revision) || label != "LOCAL" || flags > 3)
            throw std::runtime_error("local capability metadata");
          const uint64_t capabilities = flags;
          wchar_t registry[128]{}, delay[16]{};
          if (!test_stalled && !previous.empty() &&
              GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", nullptr, 0) &&
              GetEnvironmentVariableW(L"NATIVEIME_REGISTRY_KEY", registry, 128) &&
              std::wstring(registry).starts_with(L"Software\\NativeIME-test-") &&
              GetEnvironmentVariableW(L"NATIVEIME_TEST_LOCAL_PUBLICATION_STALL_MS", delay, 16)) {
            test_stalled = true;
            const DWORD ms = std::min<DWORD>(10000, wcstoul(delay, nullptr, 10));
            std::fprintf(stderr, "LOCAL_PUBLICATION stalled_ms=%lu\n", ms);
            Sleep(ms); // Snapshot obtained above; engine mutex is released.
          }
          ddskk::local::Publish(ddskk::local::Directory(), files, overlay, rules, capabilities, revision);
          ++native_adapter::publication_generation;
          LogEvent("adapter-publication generation=" + std::to_string(native_adapter::publication_generation.load()));
          LogEvent("policy-intent-publication ms=" + std::to_string(GetTickCount64() - intent_at) +
              " payload=" + (payload == 2 ? "base+overlay" : "overlay"));
          previous = identity; published_base = base_identity;
          window.Published(previous, base_identity);
          std::fprintf(stderr, "LOCAL publication status=%s capabilities=%llu\n", status.c_str(), capabilities);
        }
      }
    } catch (const std::exception& error) {
      std::fprintf(stderr, "LOCAL publication unavailable: %s\n", error.what());
    }
    // A 200 ms window coalesces learning bursts. Durable ACKs are
    // returned by the engine independently; clients fold pending deltas until
    // the matching immutable overlay is verified.
    if (!g_stopping.load()) Sleep(50);
  }
}

void ServeClient(HANDLE pipe, uint64_t client_id) {
  bool connected = true;
  std::unordered_set<std::string> client_sessions;
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
    PendingRequest pending_request;
    NoteActivity();
    g_learning_barrier = {};
    g_learning_producer_capture = true;
    const ULONGLONG received = GetTickCount64();
    const double profile_received = ProfileMilliseconds();
    std::string request(request_buffer.data(), read);
    while (!request.empty() && (request.back() == '\n' || request.back() == '\r'))
      request.pop_back();
    std::string response;
#ifdef NATIVEIME_POLICY_SYNCHRONOUS_CONTROL
    native_adapter::shadow.SynchronousControl();
#endif
    std::string engine_request = request;
    const auto scoped_id = SessionIdFromRequest(request);
    if (!scoped_id.empty()) engine_request = request.substr(9 + scoped_id.size());
    bool publish_response = true;
    bool is_shutdown = request == "SHUTDOWN";
    const bool is_preview = request.rfind("PREVIEW ", 0) == 0;
    const bool private_bundle = GetEnvironmentVariableW(L"DDSKK_HOST_BUNDLE_MANIFEST", nullptr, 0) &&
        NativeImeRegistryKey().starts_with(L"Software\\NativeIME-test-") &&
        g_pipe_name != L"\\\\.\\pipe\\ddskk-ime-v1";
    if (request == "PRIVATE OWNER 1") {
      response = private_bundle ? "OWNER " + std::to_string(GetCurrentProcessId()) : "ERR PRIVATE";
    } else if (request == "PRIVATE HANDOVER 1") {
      // Only a private, manifest-selected host exposes this additive control.
      // Freeze editing under the same transaction gate that tracks composition,
      // then wait for the native durable fence without holding that gate.
      std::pair<uint64_t, std::shared_future<bool>> fence;
      {
        EngineTransaction lock;
        if (!private_bundle)
          response = "ERR PRIVATE";
        else {
          bool composing = !g_composing_sessions.empty();
          if (g_state_owner && g_state_owner->local_owner && g_state_view) {
            LONG sequence = 0;
            if (!TryOwnStateMirror(g_state_view, &sequence, g_state_writer)) composing = true;
            else {
              std::istringstream state(g_state_view->line);
              std::string tag, mode, text, pending; int cursor = 0, start = -1;
              if (!(state >> tag >> mode >> cursor >> start >> text >> pending)) composing = true;
              else composing = composing || mode == "preedit" || mode == "candidate" ||
                  mode == "registration" || start >= 0 || pending != "-";
              ReleaseStateMirror(g_state_view, sequence, g_state_writer);
            }
          }
          if (composing) response = "DEFER COMPOSITION";
          else {
            g_private_handover = true;
            if (g_learning_queue) fence = g_learning_queue->Fence();
          }
        }
      }
      if (response.empty()) {
        const bool durable = !fence.second.valid() ||
            (fence.second.wait_for(std::chrono::seconds(30)) == std::future_status::ready &&
             fence.second.get());
        EngineTransaction lock;
        if (!durable || (g_learning_queue && g_learning_queue->Fence().first != fence.first)) {
          g_private_handover = false;
          response = "DEFER STORAGE";
        } else {
          response = "OK HANDOVER RECONNECT"; is_shutdown = true;
          LogEvent("private-handover fence=" + std::to_string(fence.first) +
              " engine_epoch=" + std::to_string(native_adapter::engine_epoch.load()) +
              " sessions=reconnect");
        }
      }
    } else if (g_private_handover.load()) {
      connected = false; break;
    } else if (is_shutdown) {
      response = "OK";
    } else if (engine_request.starts_with("LOCAL SERVER ")) {
      try {
        std::istringstream fields(engine_request.substr(13));
        std::string key, okuri, extra; fields >> key >> okuri;
        const auto reading = ddskk::local::Unhex(key);
        const auto suffix = okuri == "-" ? std::wstring{} : ddskk::local::Unhex(okuri);
        if ((fields >> extra) || !ddskk::local::LocalReading(reading) || suffix.size() > 32) response = "SERVER 4";
        else {
          const auto reply = g_server_cache.Query(ddskk::local::Utf8(reading), ddskk::local::Utf8(suffix));
          response = reply ? "SERVER " + *reply : "SERVER PENDING";
        }
      } catch (...) { response = "SERVER 4"; }
    } else if (engine_request == "ROMAJI RULES 1") {
      std::lock_guard<std::mutex> lock(g_romaji_mutex);
      response = g_romaji_rules.empty()
          ? "ERR RULES NOT-READY" : g_romaji_rules;
    } else if (engine_request == "ENGINE CURRENT") {
      // This is host publication state. Relaying an unscoped poll to the
      // runner switches DDSKK to its legacy session, forcing a full
      // checkpoint save/restore on the next application's key. Frequent
      // polls then increase allocation and latency on that key.
      std::lock_guard<std::mutex> lock(g_switch_mutex);
      response = "ENGINE " + g_published_engine;
    } else if (engine_request == "ENGINE RELOAD") {
      std::string id;
      { std::lock_guard<std::mutex> lock(g_switch_mutex); id = g_published_engine; }
      QueueReplacement(id, true);
      response = "OK RELOADING";
    } else if (engine_request.starts_with("ENGINE SWITCH ") ||
               engine_request.starts_with("ENGINE SET ")) {
      const bool switching = engine_request.starts_with("ENGINE SWITCH ");
      const std::string id = engine_request.substr(switching ? 14 : 11);
      if (!ValidEngineId(id)) response = "ERR ENGINE";
      else {
        bool different;
        { std::lock_guard<std::mutex> lock(g_switch_mutex); different = id != g_published_engine; }
        if (switching || different) QueueReplacement(id);
        response = switching || different ? "OK SWITCHING " + id : "OK ENGINE " + id;
      }
    } else if (engine_request == "DIAG CHILD-PID") {
      std::lock_guard<std::mutex> lock(g_engine_mutex);
      response = "PID " + std::to_string(g_child.process ? GetProcessId(g_child.process) : 0);
    } else if (is_preview) {
      // Immutable built-in dictionary maps are safe to read without the
      // NeLisp transaction mutex. This path is a display preview only: it
      // never mutates or claims authority over the provider session.
      response = PreviewBuiltinDictionary(request);
    } else {
      // Reserve the interpreter for this whole transaction. SERVER cache
      // waits release metadata ownership, preserving publication access.
      EngineTransaction lock;
      if (g_private_handover.load()) { connected = false; break; }
      if (GetEnvironmentVariableW(L"DDSKK_HOST_DEBUG", nullptr, 0))
        std::fprintf(stderr, "request-lock tick=%llu wait_ms=%llu qpc_wait_ms=%.6f request=%s\n",
            received, GetTickCount64()-received,
            ProfileMilliseconds()-profile_received, request.c_str());
      const std::string session_id = SessionIdFromRequest(request);
      const bool scoped_session = !session_id.empty();
      if (scoped_session) {
        client_sessions.insert(session_id);
        g_session_owners[session_id] = client_id;
      }
      const bool input_request = !scoped_session &&
                                 (request.rfind("KEY ", 0) == 0 ||
                                 request.rfind("CONTROL CONVERT-KEYS ", 0) == 0 ||
                                 request.rfind("CONTROL ", 0) == 0);
      const bool reset_request = !scoped_session && request == "RESET";
      if (reset_request && g_active_input_client != 0 &&
          (g_active_input_client != client_id ||
           g_session_composing.load(std::memory_order_acquire))) {
        // A delayed focus/composition callback, either from an old client
        // or a transient FALSE focus notification in the active client.
        // Acknowledge its local cleanup without touching a live conversion.
        // If a different client really takes focus, its first KEY/CONTROL
        // below performs the authoritative reset before taking ownership.
        response = "STATE hiragana 0 -1 - - -1 -";
        publish_response = false;
      } else {
        if (input_request && g_active_input_client != client_id) {
          std::string ignored;
          if (!Dispatch(g_child, "RESET", &ignored)) {
            connected = false;
            break;
          }
          g_active_input_client = client_id;
        } else if (reset_request) {
          g_active_input_client = client_id;
        }
        const bool convert_keys =
            request.rfind("CONTROL CONVERT-KEYS ", 0) == 0;
        const bool dispatched = convert_keys
            ? DispatchConvertKeys(g_child, request, &response)
            : Dispatch(g_child, request, &response);
        if (!dispatched) {
          connected = false;
          break;
        }
      }
      // Track composition state from this reply for IdleGcLoop() (see its
      // "Composition-in-progress suppression" comment). Only STATE lines
      // carry a mode; OK/ERR/ENGINES/... replies leave the flag as-is.
      // This lives only on the ServeClient() request path -- IdleGcLoop's
      // own "GC" request always gets back "OK GC", never "STATE ...", so
      // it can never affect this flag.
      if (publish_response && response.compare(0, 6, "STATE ") == 0) {
        const size_t mode_start = 6;
        const size_t mode_end = response.find(' ', mode_start);
        const std::string mode = mode_end == std::string::npos
            ? response.substr(mode_start)
            : response.substr(mode_start, mode_end - mode_start);
        std::istringstream fields(response);
        std::string tag, state_mode, text, pending;
        int cursor = 0, start = -1;
        fields >> tag >> state_mode >> cursor >> start >> text >> pending;
        const bool composing = mode == "preedit" || mode == "candidate" ||
                               mode == "registration" || start >= 0 ||
                               (!pending.empty() && pending != "-");
        const std::string state_owner = scoped_session
            ? session_id
            : "legacy:" + std::to_string(client_id);
        if (composing)
          g_composing_sessions.insert(state_owner);
        else
          g_composing_sessions.erase(state_owner);
        g_session_composing.store(!g_composing_sessions.empty(),
                                  std::memory_order_release);
        PublishStateMirror(response, scoped_id.empty() ? 0 : static_cast<DWORD>(std::strtoul(scoped_id.c_str(), nullptr, 10)),
            engine_request.starts_with("KEY ") || engine_request.starts_with("CONTROL "));
      }
      if (scoped_session && request == "SESSION " + session_id + " CLOSE") {
        const auto owner = g_session_owners.find(session_id);
        if (owner != g_session_owners.end() && owner->second == client_id) {
          g_session_owners.erase(owner);
          g_composing_sessions.erase(session_id);
          g_session_composing.store(!g_composing_sessions.empty(),
                                    std::memory_order_release);
        }
      }
    }
    // Session STATE waits only for its small durable producer append. LOCAL ACK remains
    // durable so the existing asynchronous client outbox is safe to retire.
    // Its wait is outside the engine mutex.
    response = LearningReply(std::move(response), g_learning_barrier);
    g_learning_producer_capture = false;
    DWORD written = 0;
    const double profile_write = ProfileMilliseconds();
    if (response.starts_with("ACK ")) ddskk::host_fault::Point(L"ack-before");
    connected = WriteFile(pipe, response.data(), static_cast<DWORD>(response.size()),
                          &written, nullptr) && written == response.size();
    if (connected && response.starts_with("ACK ")) ddskk::host_fault::Point(L"ack-written");
    if (GetEnvironmentVariableW(L"DDSKK_HOST_DEBUG", nullptr, 0))
      std::fprintf(stderr, "request-done tick=%llu total_ms=%llu qpc_total_ms=%.6f qpc_write_ms=%.6f request=%s\n",
          received, GetTickCount64()-received, ProfileMilliseconds()-profile_received,
          ProfileMilliseconds()-profile_write, request.c_str());
    if (is_shutdown) {
      connected = false;
      g_stop_reason.store("SHUTDOWN");
      RequestStop();
    }
  }
  FlushFileBuffers(pipe);
  DisconnectNamedPipe(pipe);
  CloseHandle(pipe);
  // Release this connection's sessions. Process death belongs to the
  // replacement worker; disconnecting a client never stops the host.
  // Locked so this never races StopChild()'s handle teardown in wmain.
  EngineTransaction lock;
  if (g_active_input_client == client_id) g_active_input_client = 0;
  g_composing_sessions.erase("legacy:" + std::to_string(client_id));
  for (const std::string& session_id : client_sessions) {
    const auto owner = g_session_owners.find(session_id);
    if (owner == g_session_owners.end() || owner->second != client_id) continue;
    if (g_child.process != nullptr &&
        WaitForSingleObject(g_child.process, 0) == WAIT_TIMEOUT) {
      std::string ignored;
      Dispatch(g_child, "SESSION " + session_id + " CLOSE", &ignored);
    }
    g_session_owners.erase(owner);
    g_composing_sessions.erase(session_id);
  }
  g_session_composing.store(!g_composing_sessions.empty(),
                            std::memory_order_release);
  // ReplacementLoop observes process death and recovers with back-off.
}
}  // namespace

int wmain(int argc, wchar_t** argv) {
  InitializeLog();
  struct StopLog {
    ~StopLog() { LogEvent(std::string("host-stop reason=") + g_stop_reason.load()); }
  } stop_log;
  if (argc != 2 && argc != 3) {
    g_stop_reason.store("invalid-arguments");
    std::fwprintf(stderr,
                  L"usage: ddskk-engine-host ENGINE_EXE [REPOSITORY]\n");
    return 2;
  }
  g_pipe_name = PipeName();

  // Field incident: after a re-logon, several TSF-hosting applications
  // activated at once. Each independently called EnsureEngineHost(), each
  // saw no pipe up yet, and each spawned its own ddskk-engine-host.exe --
  // TWO processes ended up serving \\.\pipe\ddskk-ime-v1 concurrently,
  // started the same second. Clients then landed on whichever process's
  // pipe instance happened to accept them, silently splitting the one
  // supposed-to-be-shared engine session in two: compositions were left
  // stranded open in whichever app's connection migrated between the two
  // sessions (which also traps arrow keys inside that still-open
  // composition at the application level, since this TIP deliberately
  // never claims arrow keys itself), plus inconsistent modes and a
  // generally sluggish feel from two engines both running live. This
  // named mutex, checked before touching the pipe or spawning the engine
  // child at all, makes only the first host to reach here for a given
  // pipe name actually run; every later one recognizes it lost the race
  // and exits immediately.
  const std::wstring mutex_name = SingletonMutexName(g_pipe_name);
  HANDLE singleton_mutex = CreateMutexW(nullptr, TRUE, mutex_name.c_str());
  if (singleton_mutex == nullptr) {
    // Bundled private replacement fails closed. Preserve the unbundled host's
    // existing failure behaviour until a separately approved live rollout.
    const bool bundled = GetEnvironmentVariableW(L"DDSKK_HOST_BUNDLE_MANIFEST", nullptr, 0) != 0;
    std::fwprintf(stderr,
                  L"ddskk-engine-host: CreateMutexW failed (%lu); %ls\n",
                  static_cast<unsigned long>(GetLastError()),
                  bundled ? L"refusing bundled startup" : L"continuing without the singleton guard");
    if (bundled) return 4;
  } else if (GetLastError() == ERROR_ALREADY_EXISTS) {
    g_stop_reason.store("singleton-already-owned");
    // Lost the race: another host already owns this pipe name's session.
    // Exit 0 on purpose: EnsureEngineHost()'s CreateProcessW callers (see
    // src/text_service.cpp) treat "a host is already running" as success,
    // not a spawn failure that should be retried or surfaced.
    std::fwprintf(stderr,
                  L"ddskk-engine-host: another instance already owns %ls, exiting\n",
                  mutex_name.c_str());
    return 0;
  }
  // singleton_mutex is intentionally never closed: it must be held for the
  // entire process lifetime, and the OS releases/closes it automatically
  // on process exit either way, so leaking the handle here is fine.

  const std::wstring repository = argc == 3 ? argv[2] : L"";
  // All children, including warming replacements, die if their host is
  // killed. This also gives private crash tests deterministic tree cleanup.
  g_child_job = CreateJobObjectW(nullptr, nullptr);
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!g_child_job || !SetInformationJobObject(g_child_job,
      JobObjectExtendedLimitInformation, &limits, sizeof(limits))) {
    g_stop_reason.store("child-job-setup-failed");
    return 3;
  }
  g_executable = argv[1];
  g_repository = repository;
  native_adapter::shadow.Start(argv[1], repository, g_child_job);
  struct PolicyLifetime {
    ~PolicyLifetime() { native_adapter::shadow.Stop(); }
  } policy_lifetime;
  const std::wstring configured = ConfiguredEngineId();
  const std::wstring initial_registry_engine = ConfiguredEngineId(false);
  g_current_engine = NarrowEngineId(configured);
  g_published_engine = g_current_engine;
  ApplyEngineEnvFromRegistry();
  if (!ddskk::LearningQueue::RecoverPending(LearningTarget()))
    LogEvent("learning-pending-recovery-failed");
  if (!ddskk::LearningQueue::RecoverOutbox(LearningTarget())) {
    LogEvent("learning-outbox-recovery-failed");
    return 1; // fail closed rather than discard acknowledged learning
  }
  g_learning_queue = std::make_unique<ddskk::LearningQueue>(LearningTarget(),
              std::function<bool(const std::string&)>{}, LearningSchedule);
  if (!StartChild(argv[1], repository, &g_child, configured)) {
    g_stop_reason.store("initial-child-start-failed");
    StopChild(g_child);
    return 3;
  }
  native_adapter::engine_epoch = g_child.epoch;
  InitializeStateMirror(g_pipe_name);
  // Populate outside the keyboard path, including cold engine startup.
  std::thread([] {
    std::lock_guard<std::mutex> lock(g_engine_mutex);
    std::string exported;
    if (g_current_engine == "ddskk" &&
        Dispatch(g_child, "ROMAJI RULES 1", &exported) &&
        exported.starts_with("RULES 1 ")) {
      std::lock_guard<std::mutex> rules_lock(g_romaji_mutex);
      g_romaji_rules = std::move(exported);
    }
  }).detach();

  if (!g_dictionary_server.config_loaded) {
    LoadDictionaryServerConfig(&g_dictionary_server.config);
    g_dictionary_server.config_loaded = true;
  }

  // Built-in dictionaries (USER QUESTION driving this:
  // 「辞書サーバー無しで変換出来ないのでしょうか？」 -- see
  // DictionaryServerConfig::dictionary_files above for the full field-
  // incident rationale). Started here, detached, so multi-hundred-
  // thousand-line file parsing never blocks pipe serving below: a lookup
  // that arrives before it finishes just skips this tier
  // (BuiltinDictionaryState::ready / LookupDictionary()) and falls
  // through to the external server exactly as if dictionary_files were
  // never configured.
  if (!g_dictionary_server.config.dictionary_files.empty()) {
    std::thread(LoadBuiltinDictionariesThread,
               g_dictionary_server.config.dictionary_files)
        .detach();
  }

  // Self-heal the same SkkServStartCommand field incident this early,
  // once, before any client can even attempt a lookup: if the dictionary
  // server is not reachable and a start command is configured, spawn it
  // here so it is usually already up well before the first real
  // conversion, instead of only ever reacting the first time a lookup
  // fails (see LookupDictionary()/TrySpawnSkkServ() above). Deliberately
  // skipped when the dictionary server is disabled (SkkServEnable=0),
  // matching LookupDictionary()'s own gate.
  if (g_dictionary_server.config.enabled != 0 &&
      !g_dictionary_server.config.start_command.empty() && EnsureWinsock()) {
    const SOCKET probe = ConnectDictionaryServer(g_dictionary_server.config);
    if (probe == INVALID_SOCKET) {
      TrySpawnSkkServ(g_dictionary_server.config.start_command);
    } else {
      // Just a reachability probe, not a connection to keep: closed
      // immediately rather than cached into g_dictionary_server.socket,
      // so the first real lookup (which may happen minutes later) always
      // opens its own fresh connection instead of reusing one that could
      // have gone stale by then.
      closesocket(probe);
    }
  }

  // true: this is the first (and, per the mutex above, should be the
  // only) instance of this pipe name in the whole system -- see
  // CreatePipeInstance()'s own comment for what FILE_FLAG_FIRST_PIPE_INSTANCE
  // buys on top of the mutex.
  HANDLE pipe = CreatePipeInstance(true);
  if (pipe == INVALID_HANDLE_VALUE) {
    if (GetLastError() == ERROR_ACCESS_DENIED) {
      g_stop_reason.store("pipe-already-owned");
      // Belt-and-braces for the same field incident as the mutex above:
      // this means a second process somehow raced past the mutex check
      // (the mutex already makes that effectively impossible, but the
      // flag costs nothing) and already owns the first instance of this
      // pipe name. Exit 0 for the same "already running" reason.
      std::fwprintf(stderr,
                    L"ddskk-engine-host: pipe %ls already owned by another "
                    L"instance, exiting\n",
                    g_pipe_name.c_str());
      StopChild(g_child);
      return 0;
    }
    StopChild(g_child);
    g_stop_reason.store("initial-pipe-create-failed");
    return 4;
  }
  // Started once, detached, never joined -- same discipline as the
  // per-client ServeClient() threads below (see the accept-loop comment):
  // on shutdown this thread simply notices g_stopping within one 100 ms
  // poll tick and returns, and the process exiting reaps it regardless.
  std::thread(IdleGcLoop).detach();
  std::thread replacement_worker(ReplacementLoop);
  std::thread registry_worker(WatchEngineRegistry, initial_registry_engine);
  g_server_cache.Start();
  std::thread local_worker(LocalPublicationLoop);
  std::thread spool_worker(LocalSpoolRecoveryLoop);
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
      g_stop_reason.store("pipe-accept-failed");
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
    // false: every spare instance after the very first one -- see
    // CreatePipeInstance()'s comment on why FILE_FLAG_FIRST_PIPE_INSTANCE
    // must never be passed here too.
    pipe = CreatePipeInstance(false);
    const uint64_t client_id =
        g_next_client_id.fetch_add(1, std::memory_order_relaxed);
    std::thread(ServeClient, connected_pipe, client_id).detach();
    if (pipe == INVALID_HANDLE_VALUE) {
      g_stop_reason.store("spare-pipe-create-failed");
      // Out of resources for further instances: the client just accepted
      // above is still served (thread already started); just stop taking
      // new ones.
      break;
    }
  }
  if (pipe != INVALID_HANDLE_VALUE) CloseHandle(pipe);
  g_stopping.store(true);
  replacement_worker.join();
  registry_worker.join();
  local_worker.join();
  spool_worker.join();
  // Holding g_engine_mutex here waits for any worker thread currently
  // mid-transaction to finish first, so the child's pipes are never closed
  // out from under an in-flight read/write. A worker that acquires the
  // mutex afterward simply finds the now-closed handles and fails its
  // Dispatch() call, which it already treats as an ordinary disconnect.
  {
    EngineTransaction lock;
    StopChild(g_child);
  }
  if (g_learning_queue) g_learning_queue->Drain();
  native_adapter::shadow.Stop();
  g_server_cache.Stop();
  ShutdownDictionaryServer();
  return 0;
}
