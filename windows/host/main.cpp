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

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <string>
#include <string_view>
#include <thread>
#include <unordered_map>
#include <vector>

namespace {
constexpr wchar_t kPipeName[] = L"\\\\.\\pipe\\ddskk-ime-v1";

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
std::wstring ConfiguredEngineId() {
  wchar_t value[64]{};
  const DWORD size = GetEnvironmentVariableW(L"NELISP_IME_ENGINE", value, 64);
  if (size > 0 && size < 64) return value;

  HKEY key = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\NativeIME", 0, KEY_READ,
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

// Returns the repository-relative runner script for the configured engine,
// and exports NELISP_IME_ENGINE for the child when that is the framework
// runner so it starts on the configured engine rather than its own
// default. (The child inherits this process's environment: CreateProcessW
// is called with lpEnvironment=nullptr, same as ApplyEngineEnvFromRegistry
// relies on.)
//
// Falling back to DDSKK when the repository has no framework runner is
// deliberate rather than defensive tidiness. Field incident: the settings
// UI offered an engine the running stack could not serve, the user
// selected it, and conversion stopped working entirely. A configured
// engine that cannot be launched must degrade to the one that always can.
std::wstring EngineRunnerScript(const std::wstring& repository) {
  const std::wstring id = ConfiguredEngineId();
  if (IsDdskkEngineId(id)) return kDdskkRunner;
  if (!FileExists(repository + L"\\framework\\nelisp-ime-stdio.el")) {
    std::fwprintf(stderr,
                  L"ddskk-engine-host: engine \"%ls\" needs %ls, which this "
                  L"repository does not provide; falling back to DDSKK\n",
                  id.c_str(), kFrameworkRunner);
    return kDdskkRunner;
  }
  SetEnvironmentVariableW(L"NELISP_IME_ENGINE", id.c_str());
  return kFrameworkRunner;
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
      SetEnvironmentVariableW(bridge.env_name,
                              std::to_wstring(value).c_str());
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
    const std::wstring runner = EngineRunnerScript(repository);
    // The AOT-backed native entry exists for the DDSKK runner only, so an
    // engine served by the framework runner always takes the --load path.
    command += (UseNativeEntry() && runner == kDdskkRunner)
                   ? L" --ddskk-ime-server " + runner
                   : L" --load " + runner;
  }
  const wchar_t* working_directory =
      repository.empty() ? nullptr : repository.c_str();
  ApplyEngineEnvFromRegistry();
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
  // LookupDictionary() merges candidates from every configured file
  // (SKK semantics: union across files, not first-file-wins) and only
  // ever falls through to the external server for words none of them
  // have -- see LoadBuiltinDictionariesThread()/MergeBuiltinCandidates()
  // below. Env DDSKK_DICTIONARY_FILES takes precedence over
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
  if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\NativeIME", 0,
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
void ParseSkkJisyo(std::string_view contents,
                   std::unordered_map<std::string, std::string>* map) {
  size_t line_start = 0;
  while (line_start <= contents.size()) {
    size_t line_end = contents.find('\n', line_start);
    if (line_end == std::string_view::npos) line_end = contents.size();
    std::string_view line = contents.substr(line_start, line_end - line_start);
    if (!line.empty() && line.back() == '\r') line.remove_suffix(1);
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
// here), first against the built-in dictionaries (if configured and
// loaded -- see BuiltinDictionaryState/MergeBuiltinCandidates() above),
// then, only if that comes up empty, against the external dictionary
// server. Returns the single line to hand back to the engine, matching
// the skkserv wire protocol's own reply forms byte-for-byte either way:
// "1/cand/cand/.../" on a hit (built-in or external), or "4" for
// not-found / disabled / any failure. Never throws and never blocks
// longer than the configured send/recv timeouts (plus, in the worst case,
// one OS-level connect timeout on the retry -- see
// ConnectDictionaryServer()).
std::string LookupDictionary(const std::string& midasi) {
  try {
    if (!g_dictionary_server.config_loaded) {
      LoadDictionaryServerConfig(&g_dictionary_server.config);
      g_dictionary_server.config_loaded = true;
    }

    // Built-in dictionaries take priority over the external server, and
    // are consulted even if the external server is disabled or
    // unreachable -- this is what makes conversion work with no
    // dictionary server running at all. A lookup that arrives before the
    // loader thread has published its maps just falls through to the
    // external-server logic below unchanged, exactly as if
    // dictionary_files were never configured.
    if (g_builtin_dictionary.ready.load(std::memory_order_acquire)) {
      const std::string merged = MergeBuiltinCandidates(midasi);
      if (!merged.empty()) return "1" + merged;
    }

    if (g_dictionary_server.config.enabled == 0) return "4";
    if (!EnsureWinsock()) return "4";

    const std::string request = "1" + midasi + " ";
    std::string raw_response;

    // Up to two attempts total: reuse (or make) the cached connection, and
    // on any failure drop it and retry exactly once with a fresh one.
    for (int attempt = 0; attempt < 2; ++attempt) {
      if (g_dictionary_server.socket == INVALID_SOCKET) {
        g_dictionary_server.socket = ConnectDictionaryServer(g_dictionary_server.config);
        if (g_dictionary_server.socket == INVALID_SOCKET) {
          // Self-heal the field incident this connect failure might be:
          // the dictionary server may simply not be running. Spawn it
          // (rate-limited by TrySpawnSkkServ's cooldown) and give it
          // ~1.5s to come up for exactly one bounded extra retry here,
          // rather than silently degrading every conversion for the rest
          // of the session -- see DictionaryServerConfig::start_command.
          // This adds at most one fixed sleep on top of the existing
          // connect timeout; if the retry also fails, the loop below
          // falls through to the unchanged "4" (not-found/unavailable)
          // path exactly as before.
          if (TrySpawnSkkServ(g_dictionary_server.config.start_command)) {
            Sleep(1500);
            g_dictionary_server.socket =
                ConnectDictionaryServer(g_dictionary_server.config);
          }
        }
      }
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
    // Extremely unlikely (e.g. object-manager exhaustion). Fail open --
    // log and keep going -- rather than silently refuse to start the
    // IME's only engine host over a guard that could not even be set up.
    std::fwprintf(stderr,
                  L"ddskk-engine-host: CreateMutexW failed (%lu); continuing "
                  L"without the singleton guard\n",
                  static_cast<unsigned long>(GetLastError()));
  } else if (GetLastError() == ERROR_ALREADY_EXISTS) {
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
  if (!StartChild(argv[1], repository, &g_child)) {
    StopChild(g_child);
    return 3;
  }

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
    // false: every spare instance after the very first one -- see
    // CreatePipeInstance()'s comment on why FILE_FLAG_FIRST_PIPE_INSTANCE
    // must never be passed here too.
    pipe = CreatePipeInstance(false);
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
