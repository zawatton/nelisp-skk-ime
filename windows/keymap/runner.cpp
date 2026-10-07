// SPDX-License-Identifier: GPL-3.0-or-later
#include <windows.h>
#include <imm.h>
#include <immdev.h>
#include <wtsapi32.h>

#include <atomic>
#include <cstdio>
#include <cwctype>
#include <fcntl.h>
#include <io.h>
#include <iostream>
#include <memory>

#include "core.h"
#include "editor.h"
#include "rules.h"
#include "win_io.h"
namespace {
using namespace keymap;
void connectParentOutput() {
  // Save inherited pipes/files before AttachConsole can replace standard handles.
  HANDLE inherited[] = {GetStdHandle(STD_OUTPUT_HANDLE),
                        GetStdHandle(STD_ERROR_HANDLE)};
  bool attached = AttachConsole(ATTACH_PARENT_PROCESS) != FALSE;
  for (int i = 0; i < 2; ++i) {
    HANDLE handle = inherited[i];
    if (!handle || handle == INVALID_HANDLE_VALUE ||
        GetFileType(handle) == FILE_TYPE_UNKNOWN)
      handle = attached ? GetStdHandle(i == 0 ? STD_OUTPUT_HANDLE
                                              : STD_ERROR_HANDLE)
                        : nullptr;
    HANDLE copy = nullptr;
    if (!handle || handle == INVALID_HANDLE_VALUE ||
        !DuplicateHandle(GetCurrentProcess(), handle, GetCurrentProcess(),
                         &copy, 0, FALSE, DUPLICATE_SAME_ACCESS))
      continue;
    // GUI CRT startup may leave FILE descriptors at -2. Initialize the FILE
    // before replacing its descriptor with the saved console/redirect handle.
    FILE* stream = i == 0 ? stdout : stderr;
    FILE* reopened = nullptr;
    if (freopen_s(&reopened, "NUL", "w", stream) != 0) {
      CloseHandle(copy);
      continue;
    }
    int fd = _open_osfhandle(reinterpret_cast<intptr_t>(copy), _O_TEXT);
    if (fd == -1) {
      CloseHandle(copy);
      continue;
    }
    _dup2(fd, _fileno(stream));
    _close(fd);
    clearerr(stream);
  }
  std::cout.clear();
  std::cerr.clear();
}
constexpr UINT Stop = WM_APP + 1, Act = WM_APP + 2, Foreground = WM_APP + 3;
std::atomic<const Snapshot*> current{nullptr};
State state;
Context context;
HHOOK hook = nullptr;
HWND host = nullptr;
HWND target = nullptr;
DWORD hookThread = 0;
bool noHook = false, testing = false;
int activeSlot = 0, dispatchSlot = 0;
unsigned callbackDepth = 0;
struct Forwarding {
  bool active = false;
  int slot = 0;
  WPARAM message = 0;
  KBDLLHOOKSTRUCT key{};
};
Forwarding forwarding;
std::array<Event, 2048> recorded{};
unsigned recordedCount = 0;
void output(const Result& r) {
  if (testing || noHook) {
    for (unsigned i = 0; i < r.count && recordedCount < recorded.size(); ++i)
      recorded[recordedCount++] = r.events[i];
    return;
  }
  std::array<INPUT, 1024> inputs{};
  for (unsigned i = 0; i < r.count; ++i) {
    auto& in = inputs[i];
    in.type = INPUT_KEYBOARD;
    in.ki.wVk = r.events[i].key.vk;
    in.ki.wScan = r.events[i].key.scan;
    in.ki.dwFlags = (r.events[i].up ? KEYEVENTF_KEYUP : 0) |
                    (r.events[i].key.extended ? KEYEVENTF_EXTENDEDKEY : 0);
    if (!in.ki.wVk) in.ki.dwFlags |= KEYEVENTF_SCANCODE;
    in.ki.dwExtraInfo = Tag;
  }
  if (r.count) SendInput(r.count, inputs.data(), sizeof(INPUT));
}
LRESULT forwardNext(int code, WPARAM wp, LPARAM lp) {
  if (testing) return 0;
  auto previous = forwarding;
  forwarding.active = code == HC_ACTION;
  forwarding.slot = dispatchSlot;
  forwarding.message = wp;
  if (forwarding.active)
    forwarding.key = *reinterpret_cast<KBDLLHOOKSTRUCT*>(lp);
  auto result = CallNextHookEx(hook, code, wp, lp);
  forwarding = previous;
  return result;
}
LRESULT CALLBACK keyboard(int code, WPARAM wparam, LPARAM lparam) {
  if (code != HC_ACTION) return testing ? 0 : forwardNext(code, wparam, lparam);
  auto& k = *reinterpret_cast<KBDLLHOOKSTRUCT*>(lparam);
  auto snapshot = current.load(std::memory_order_acquire);
  if (!snapshot) return testing ? 0 : forwardNext(code, wparam, lparam);
  Event e{normalize({static_cast<uint16_t>(k.vkCode),
                     static_cast<uint16_t>(k.scanCode),
                     (k.flags & LLKHF_EXTENDED) != 0}),
          (k.flags & LLKHF_UP) != 0, (k.flags & LLKHF_INJECTED) != 0,
          k.dwExtraInfo, k.time};
  auto r = decide(e, state, *snapshot, context);
  output(r);
  if (r.action != Action::None && !testing && !noHook)
    PostMessageW(host, Act, static_cast<WPARAM>(r.action),
                 reinterpret_cast<LPARAM>(target));
  return r.swallow ? 1 : testing ? 0 : forwardNext(code, wparam, lparam);
}
LRESULT dispatchKeyboard(int slot, int code, WPARAM wp, LPARAM lp) {
  if (code == HC_ACTION && forwarding.active && forwarding.slot != slot &&
      forwarding.message == wp) {
    const auto& k = *reinterpret_cast<KBDLLHOOKSTRUCT*>(lp);
    const auto& f = forwarding.key;
    if (k.vkCode == f.vkCode && k.scanCode == f.scanCode &&
        k.flags == f.flags && k.time == f.time &&
        k.dwExtraInfo == f.dwExtraInfo)
      return testing ? 0 : CallNextHookEx(hook, code, wp, lp);
  }
  const int previous = dispatchSlot;
  dispatchSlot = slot;
  ++callbackDepth;
  auto result = keyboard(code, wp, lp);
  --callbackDepth;
  dispatchSlot = previous;
  return result;
}
LRESULT CALLBACK keyboardA(int code, WPARAM wp, LPARAM lp) {
  return dispatchKeyboard(0, code, wp, lp);
}
LRESULT CALLBACK keyboardB(int code, WPARAM wp, LPARAM lp) {
  return dispatchKeyboard(1, code, wp, lp);
}
bool renewHook() {
  if (noHook || testing) return true;
  const int nextSlot = 1 - activeSlot;
  HHOOK next =
      SetWindowsHookExW(WH_KEYBOARD_LL, nextSlot ? keyboardB : keyboardA,
                        GetModuleHandleW(nullptr), 0);
  if (!next) return false;
  HHOOK old = hook;
  hook = next;
  activeSlot = nextSlot;
  // Install first, then unlink the old hook: no input gap and no idle
  // SendInput. The two thunks suppress duplicate decisions while both are in
  // the chain.
  if (old && !UnhookWindowsHookEx(old)) {
    output(release(state));
  }
  return true;
}
void foreground() {
  target = GetForegroundWindow();
  context.active = activeLayout(target);
  context.layoutSupported = supportedLayout(target);
  context.excluded = GetPropW(target, kCaptureProperty) != nullptr;
  DWORD pid = 0;
  GetWindowThreadProcessId(target, &pid);
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  wchar_t path[32768];
  DWORD n = 32768;
  std::wstring name;
  if (process) {
    if (QueryFullProcessImageNameW(process, 0, path, &n))
      name = std::filesystem::path(path).filename().wstring();
    CloseHandle(process);
  }
  for (auto& c : name) c = std::towlower(c);
  auto s = current.load();
  if (s)
    context.excluded =
        context.excluded || std::find(s->excludes.begin(), s->excludes.end(),
                                      name) != s->excludes.end();
}
void CALLBACK foregroundEvent(HWINEVENTHOOK, DWORD, HWND, LONG, LONG, DWORD,
                              DWORD) {
  PostMessageW(host, Foreground, 0, 0);
}
void physicalModifiers() {
  for (unsigned v : {0xa0u, 0xa1u, 0xa2u, 0xa3u, 0xa4u, 0xa5u, 0x5bu, 0x5cu})
    state.physical[v] = !noHook && (GetAsyncKeyState(v) & 0x8000) != 0;
}
void startupRelease(const Snapshot& s) {
  // A previous process may have died before its finally/release path. Key-up
  // is idempotent; recover the finite set of outputs this config can own.
  if (noHook && !testing) return;
  Result r;
  std::array<bool, 1024> emitted{};
  auto add = [&](Key k) {
    unsigned id = k.vk ? k.vk : 256 + k.scan + (k.extended ? 256 : 0);
    if (!emitted[id]) {
      r.emit(k, true);
      emitted[id] = true;
    }
  };
  for (auto name : []() {
         auto raw = readString(L"RecoveryKeys");
         std::vector<std::wstring> names;
         size_t pos = 0;
         while (pos < raw.size()) {
           auto end = raw.find(L'\0', pos);
           if (end == raw.npos) end = raw.size();
           names.push_back(raw.substr(pos, end - pos));
           pos = end + 1;
         }
         return names;
       }()) {
    try {
      add(parseKey(name));
    } catch (...) {
    }
  }
  for (const auto* list : {&s.keys, &s.shortcuts})
    for (auto& rule : *list)
      for (unsigned i = 0; i < rule.to.count; ++i) add(rule.to.keys[i]);
  if (s.layout != Layout::Os) {
    for (auto p : table(Layout::US)) add({p.vk, p.scan});
    for (auto p : table(Layout::JIS)) add({p.vk, p.scan});
  }
  output(r);
}
struct Runner {
  InputRulesWatch inputRules;
  std::wstring path;
  std::unique_ptr<Snapshot> snapshot;
  HANDLE changes = INVALID_HANDLE_VALUE;
  uint64_t due = 0;
  unsigned ticks = 0;
  void watch() {
    if (changes != INVALID_HANDLE_VALUE) FindCloseChangeNotification(changes);
    changes = FindFirstChangeNotificationW(
        std::filesystem::path(path).parent_path().c_str(), FALSE,
        FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_LAST_WRITE |
            FILE_NOTIFY_CHANGE_SIZE);
    if (changes != INVALID_HANDLE_VALUE) due = GetTickCount64() + 200;
  }
  void reload(bool first = false) {
    auto newPath = configPath();
    if (newPath != path) {
      path = newPath;
      watch();
    }
    std::wstring text;
    DWORD error = 0;
    if (!readFile(path, text, error)) {
      if (!snapshot) {
        snapshot = std::make_unique<Snapshot>();
        snapshot->errors.push_back(L"Config unavailable; retrying");
        current.store(snapshot.get());
        if (first) startupRelease(*snapshot);
      }
      if (snapshot) {
        Snapshot status = *snapshot;
        status.errors.push_back(L"Config read error " + std::to_wstring(error) +
                                L" (retrying)");
        publish(status, path, true);
      }
      due = GetTickCount64() + 200;
      return;
    }
    const bool wasEnabled = snapshot && snapshot->enabled;
    auto next = std::make_unique<Snapshot>(Document::parse(text).snapshot);
    output(release(state));
    if (first) startupRelease(*next);
    // Record possible held outputs before making this generation reachable.
    std::wstring recovery;
    auto saveKey = [&](Key key) {
      recovery += keyName(key);
      recovery.push_back(0);
    };
    for (const auto* rules : {&next->keys, &next->shortcuts})
      for (auto& rule : *rules)
        for (unsigned i = 0; i < rule.to.count; ++i) saveKey(rule.to.keys[i]);
    if (next->layout != Layout::Os) {
      for (auto p : table(Layout::US)) saveKey({p.vk});
      for (auto p : table(Layout::JIS)) saveKey({p.vk});
    }
    recovery.push_back(0);
    if (recovery.size() == 1) recovery.push_back(0);
    HKEY recoveryKey;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, settingsKey().c_str(), 0, nullptr, 0,
                        KEY_SET_VALUE, nullptr, &recoveryKey,
                        nullptr) == ERROR_SUCCESS) {
      RegSetValueExW(recoveryKey, L"RecoveryKeys", 0, REG_MULTI_SZ,
                     reinterpret_cast<const BYTE*>(recovery.data()),
                     static_cast<DWORD>(recovery.size() * sizeof(wchar_t)));
      RegCloseKey(recoveryKey);
    }
    current.store(next.get(), std::memory_order_release);
    snapshot = std::move(next);
    physicalModifiers();
    foreground();
    if (!noHook && !testing) {
      if (!snapshot->enabled) {
        if (hook) UnhookWindowsHookEx(hook);
        hook = nullptr;
      } else if (!wasEnabled || !hook) {
        renewHook();
      }
    }
    publish(*snapshot, path, !noHook && !testing && snapshot->enabled && !hook);
    due = 0;
  }
  void tick() {
    inputRules.Tick();
    ++ticks;
    if (changes != INVALID_HANDLE_VALUE &&
        WaitForSingleObject(changes, 0) == WAIT_OBJECT_0) {
      due = GetTickCount64() + 200;
      if (!FindNextChangeNotification(changes)) {
        FindCloseChangeNotification(changes);
        changes = INVALID_HANDLE_VALUE;
      }
    }
    if (changes == INVALID_HANDLE_VALUE && ticks % 10 == 0) watch();
    if (ticks % 10 == 0 && configPath() != path) reload();
    if (due && GetTickCount64() >= due) reload();
    foreground();
    if (!noHook && snapshot->enabled && ticks % 50 == 0) {
      bool ok = renewHook();
      publish(*snapshot, path, !ok);
    }
  }
  ~Runner() {
    if (changes != INVALID_HANDLE_VALUE) FindCloseChangeNotification(changes);
  }
};
Runner* runner = nullptr;
LRESULT CALLBACK proc(HWND window, UINT msg, WPARAM wp, LPARAM lp) {
  // Read-only decision query for inspectors/test hosts. COPYDATA marshals the
  // request across processes; the resident's published PID scopes discovery.
  // Local scratch state cannot emit input or alter held-key ownership.
  if (msg == WM_COPYDATA && lp) {
    const auto* data = reinterpret_cast<const COPYDATASTRUCT*>(lp);
    if (data->dwData == 0x534b5131 && data->cbData == 3 * sizeof(DWORD) &&
        data->lpData && current.load()) {
      const auto* fields = static_cast<const DWORD*>(data->lpData);
      if (fields[0] > 255 || fields[1] > 255 || fields[2] > 1) return 0;
      State probe;
      Event event{normalize({static_cast<uint16_t>(fields[0]),
                             static_cast<uint16_t>(fields[1]), fields[2] != 0})};
      auto result = decide(event, probe, *current.load(), context);
      return 0x10000000 | (result.swallow ? 0x01000000 : 0) |
             (result.count << 16) | (result.count ? result.events[0].key.vk : 0);
    }
  }
  if (msg == kCaptureReleaseMessage) {
    if (callbackDepth) return 0;
    auto editor = reinterpret_cast<HWND>(lp);
    if (editor == GetForegroundWindow() && GetPropW(editor, kCaptureProperty)) {
      output(release(state));
      physicalModifiers();
      foreground();
      return 1;
    }
    return 0;
  }
  if (msg == WM_TIMER) {
    runner->tick();
    return 0;
  }
  if (msg == Foreground) {
    foreground();
    return 0;
  }
  if (msg == Act) {
    if (reinterpret_cast<HWND>(lp) == GetForegroundWindow()) {
      HWND ime = ImmGetDefaultIMEWnd(reinterpret_cast<HWND>(lp));
      if (ime)
        SendMessageTimeoutW(ime, WM_IME_CONTROL, IMC_SETOPENSTATUS,
                            wp == static_cast<WPARAM>(Action::On),
                            SMTO_ABORTIFHUNG, 200, nullptr);
    }
    return 0;
  }
  if (msg == WM_WTSSESSION_CHANGE && wp == WTS_SESSION_LOCK) {
    output(release(state));
    return 0;
  }
  if (msg == Stop || msg == WM_CLOSE) {
    output(release(state));
    DestroyWindow(window);
    return 0;
  }
  if (msg == WM_DESTROY) {
    PostQuitMessage(0);
    return 0;
  }
  return DefWindowProcW(window, msg, wp, lp);
}
DWORD WINAPI resident(void*) {
  hookThread = GetCurrentThreadId();
  Runner local;
  runner = &local;
  WNDCLASSW cls{};
  cls.lpfnWndProc = proc;
  cls.hInstance = GetModuleHandleW(nullptr);
  cls.lpszClassName = L"NelispImeKeymapResident";
  RegisterClassW(&cls);
  // An invisible top-level window receives WTS notifications and graceful stop.
  host = CreateWindowW(cls.lpszClassName, L"", 0, 0, 0, 0, 0, nullptr, nullptr,
                       cls.hInstance, nullptr);
  if (!host) return 3;
  local.reload(true);
  if (!local.snapshot) {
    Snapshot failure;
    failure.errors.push_back(L"Unable to read config file");
    publish(failure, configPath(), true);
    DestroyWindow(host);
    return 4;
  }
  HWINEVENTHOOK fg = nullptr;
  if (!noHook) {
    fg = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND,
                         nullptr, foregroundEvent, 0, 0, WINEVENT_OUTOFCONTEXT);
    if (local.snapshot->enabled && !hook) {
      publish(*local.snapshot, local.path, true);
      DestroyWindow(host);
      return 5;
    }
  }
  WTSRegisterSessionNotification(host, NOTIFY_FOR_THIS_SESSION);
  SetTimer(host, 1, 100, nullptr);
  MSG msg{};
  while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
    TranslateMessage(&msg);
    DispatchMessageW(&msg);
  }
  output(release(state));
  if (hook) UnhookWindowsHookEx(hook);
  if (fg) UnhookWinEvent(fg);
  WTSUnRegisterSessionNotification(host);
  current.store(nullptr);
  HKEY k;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, settingsKey().c_str(), 0, KEY_SET_VALUE,
                    &k) == ERROR_SUCCESS) {
    DWORD zero = 0;
    RegSetValueExW(k, L"Pid", 0, REG_DWORD, reinterpret_cast<BYTE*>(&zero),
                   sizeof(zero));
    RegCloseKey(k);
  }
  return 0;
}
int selfTest() {
  if (env(L"NELISP_IME_KEYMAP_FILE").empty() ||
      env(L"NATIVEIME_REGISTRY_KEY").empty()) {
    std::cerr << "self-test requires private file and registry overrides\n";
    return 2;
  }
  testing = true;
  noHook = true;
  std::wstring text;
  DWORD error;
  if (!readFile(configPath(), text, error)) return 3;
  auto s = Document::parse(text).snapshot;
  current.store(&s);
  context = {Layout::US, false};
  auto call = [](unsigned vk, unsigned sc, bool up, uintptr_t extra = 0) {
    KBDLLHOOKSTRUCT k{};
    k.vkCode = vk;
    k.scanCode = sc;
    k.flags = up ? LLKHF_UP : 0;
    k.dwExtraInfo = extra;
    return keyboardA(HC_ACTION, up ? WM_KEYUP : WM_KEYDOWN,
                     reinterpret_cast<LPARAM>(&k));
  };
  bool ok = call(VK_CAPITAL, 0x3a, false) == 1 &&
            call(VK_CAPITAL, 0x3a, false) == 1 &&
            call(VK_CAPITAL, 0x3a, true) == 1 && recordedCount == 3 &&
            recorded[0].key.vk == VK_LCONTROL && !recorded[0].up &&
            recorded[2].up;
  ok = ok && call(VK_CAPITAL, 0x3a, false, Tag) == 0 && recordedCount == 3;
  call(VK_LMENU, 0x38, false);
  unsigned start = recordedCount;
  ok = ok && call(VK_SPACE, 0x39, false) == 1;
  bool kanji = false, dummy = false;
  for (unsigned i = start; i < recordedCount; ++i) {
    kanji |= recorded[i].key.vk == VK_KANJI;
    dummy |= recorded[i].key.vk == 0xff;
  }
  ok = ok && kanji && dummy && call(VK_SPACE, 0x39, true) == 1;
  call(VK_LMENU, 0x38, true);
  KBDLLHOOKSTRUCT duplicate{};
  duplicate.vkCode = VK_LCONTROL;
  duplicate.scanCode = 0x1d;
  forwarding = {true, 0, WM_KEYDOWN, duplicate};
  bool priorCtrl = state.physical[VK_LCONTROL];
  ok = ok &&
       keyboardB(HC_ACTION, WM_KEYDOWN, reinterpret_cast<LPARAM>(&duplicate)) ==
           0 &&
       state.physical[VK_LCONTROL] == priorCtrl;
  forwarding = {};
  output(release(state));
  for (auto n : state.owned) ok = ok && n == 0;
  // Exercise the production lifecycle release paths with a recording sink.
  unsigned lifecycle = 0;
  auto held = [&]() {
    context = {Layout::US, false};
    call(VK_CAPITAL, 0x3a, false);
    return recordedCount;
  };
  auto released = [&](unsigned start) {
    ++lifecycle;
    bool found = false;
    for (unsigned i = start; i < recordedCount; ++i)
      found = found || recorded[i].key.vk == VK_LCONTROL && recorded[i].up;
    ok = ok && found && state.owned[VK_LCONTROL] == 0;
  };
  start = held();
  proc(nullptr, WM_WTSSESSION_CHANGE, WTS_SESSION_LOCK, 0);
  released(start);
  Runner reloadTest;
  start = held();
  reloadTest.reload();
  released(start);
  current.store(&s);
  start = held();
  auto disabled = Document::parse(text);
  disabled.setOption(L"enabled", L"no");
  ok = ok && writeFileAtomic(configPath(), disabled.text());
  reloadTest.reload();
  released(start);
  ok = ok && !reloadTest.snapshot->enabled;
  unsigned disabledCount = recordedCount;
  ok = ok && call(VK_CAPITAL, 0x3a, false) == 0 &&
       call(VK_CAPITAL, 0x3a, true) == 0 && recordedCount == disabledCount;
  ok = ok && writeFileAtomic(configPath(), text);
  reloadTest.reload();
  current.store(&s);
  start = held();
  proc(nullptr, WM_CLOSE, 0, 0);
  released(start);
  HKEY recoveryFixture = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, settingsKey().c_str(), 0, nullptr, 0,
                      KEY_SET_VALUE, nullptr, &recoveryFixture,
                      nullptr) == ERROR_SUCCESS) {
    const wchar_t previousTargets[] = L"RAlt\0";
    ok = (RegSetValueExW(recoveryFixture, L"RecoveryKeys", 0, REG_MULTI_SZ,
                         reinterpret_cast<const BYTE*>(previousTargets),
                         sizeof(previousTargets)) == ERROR_SUCCESS) &&
         ok;
    RegCloseKey(recoveryFixture);
  } else
    ok = false;
  start = recordedCount;
  startupRelease(s);
  released(start);
  bool oldTargetReleased = false;
  for (unsigned i = start; i < recordedCount; ++i)
    oldTargetReleased =
        oldTargetReleased || recorded[i].key.vk == VK_RMENU && recorded[i].up;
  ok = ok && oldTargetReleased;
  std::cout << "S2.2 lifecycle synthetic: paths=" << lifecycle
            << " hooks=0 SendInput=0\n";
  publish(s, configPath());
  current.store(nullptr);
  std::cout << "S1.4 real hook synthetic: " << (ok ? "PASS" : "FAIL")
            << " events=" << recordedCount << " hooks=0 SendInput=0\n";
  return ok ? 0 : 1;
}
}  // namespace
int wmain(int argc, wchar_t** argv) {
  connectParentOutput();
  bool self = false, edit = false, ui = false, stop = false, rules = false;
  for (int i = 1; i < argc; ++i) {
    std::wstring a = argv[i];
    if ((a == L"--settings-key" || a == L"--config-file" ||
         a == L"--instance") &&
        i + 1 < argc) {
      SetEnvironmentVariableW(a == L"--settings-key" ? L"NATIVEIME_REGISTRY_KEY"
                              : a == L"--config-file"
                                  ? L"NELISP_IME_KEYMAP_FILE"
                                  : L"NELISP_IME_KEYMAP_INSTANCE",
                              argv[++i]);
    } else if (a == L"--no-hook")
      noHook = true;
    else if (a == L"--self-test")
      self = true;
    else if (a == L"--editor")
      edit = true;
    else if (a == L"--rules")
      rules = true;
    else if (a == L"--self-test-ui")
      ui = true;
    else if (a == L"--stop")
      stop = true;
    else
      return 2;
  }
  // Preinitialize immutable layout tables outside all hook callbacks.
  table(Layout::US);
  table(Layout::JIS);
  if (rules) {
    return keymap::rulesEditor(ui || self);
  }
  if (edit) {
    return keymap::editor(ui || self);
  }
  if (ui) return 2;
  if (self) return selfTest();
  auto suffix = env(L"NELISP_IME_KEYMAP_INSTANCE");
  auto name =
      L"Local\\nelisp-ime-keymap" + (suffix.empty() ? L"" : L"-" + suffix);
  if (stop) {
    HANDLE m = OpenMutexW(SYNCHRONIZE, FALSE, name.c_str());
    if (!m) return 0;
    DWORD pid = 0;
    auto p = readString(L"Pid");
    HKEY k;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, settingsKey().c_str(), 0,
                      KEY_QUERY_VALUE, &k) == ERROR_SUCCESS) {
      DWORD bytes = sizeof(pid);
      RegQueryValueExW(k, L"Pid", nullptr, nullptr,
                       reinterpret_cast<BYTE*>(&pid), &bytes);
      RegCloseKey(k);
    }
    struct Find {
      DWORD pid;
      HWND window;
    };
    Find find{pid, nullptr};
    EnumWindows(
        [](HWND w, LPARAM l) -> BOOL {
          auto* f = reinterpret_cast<Find*>(l);
          DWORD id;
          GetWindowThreadProcessId(w, &id);
          wchar_t cls[128];
          GetClassNameW(w, cls, 128);
          if (id == f->pid && std::wstring(cls) == L"NelispImeKeymapResident") {
            f->window = w;
            return FALSE;
          }
          return TRUE;
        },
        reinterpret_cast<LPARAM>(&find));
    if (find.window) PostMessageW(find.window, Stop, 0, 0);
    CloseHandle(m);
    return find.window ? 0 : 3;
  }
  HANDLE mutex = CreateMutexW(nullptr, FALSE, name.c_str());
  if (!mutex) return 3;
  if (GetLastError() == ERROR_ALREADY_EXISTS) {
    CloseHandle(mutex);
    std::cerr << "instance already running\n";
    return 10;
  }
  HANDLE thread = CreateThread(nullptr, 0, resident, nullptr, 0, nullptr);
  if (!thread) {
    CloseHandle(mutex);
    return 4;
  }
  WaitForSingleObject(thread, INFINITE);
  DWORD code = 0;
  GetExitCodeThread(thread, &code);
  CloseHandle(thread);
  CloseHandle(mutex);
  return static_cast<int>(code);
}
