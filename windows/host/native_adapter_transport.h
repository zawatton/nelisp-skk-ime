// Native adapter owns engine process handles, stdio and bounded wire IO.
#pragma once

struct Child {
  uint64_t epoch = 0;
  HANDLE process = nullptr;
  HANDLE input = nullptr;
  HANDLE output = nullptr;
  std::string engine;
  ULONGLONG started = 0;
  bool exit_logged = false;
  bool wire_checked = false;
  bool utf8_wire = false;
  bool learning_worker = false;
  std::string local_status;
};

void LogChildExit(Child& child, bool expected) {
  if (!child.process || child.exit_logged) return;
  DWORD code = STILL_ACTIVE;
  if (!GetExitCodeProcess(child.process, &code) || code == STILL_ACTIVE) return;
  LogEvent("child-exit pid=" + std::to_string(GetProcessId(child.process)) +
      " engine=" + child.engine + " code=" + std::to_string(code) +
      " uptime_ms=" + std::to_string(GetTickCount64() - child.started) +
      " expected=" + (expected ? "true" : "false"));
  child.exit_logged = true;
}

void Close(HANDLE& handle) {
  if (handle != nullptr && handle != INVALID_HANDLE_VALUE) CloseHandle(handle);
  handle = nullptr;
}

void StopChild(Child& child) {
  LogChildExit(child, false);
  Close(child.input);
  Close(child.output);
  if (child.process != nullptr) {
    if (WaitForSingleObject(child.process, 500) == WAIT_TIMEOUT) {
      TerminateProcess(child.process, 1);
      WaitForSingleObject(child.process, 5000);
    }
    LogChildExit(child, true);
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

// A high resolution timer keeps pipe polling independent of the system's
// roughly 16 ms clock tick. No machine-wide timer resolution is changed.
void WaitForEngineData() {
  struct Timer {
    HANDLE handle = CreateWaitableTimerExW(nullptr, nullptr, 0x00000002, TIMER_ALL_ACCESS);
    ~Timer() { if (handle) CloseHandle(handle); }
  };
  thread_local Timer timer;
  LARGE_INTEGER due; due.QuadPart = -10000;  // one millisecond
  if (!timer.handle || !SetWaitableTimer(timer.handle, &due, 0, nullptr, nullptr, FALSE)) {
    Sleep(2); return;
  }
  WaitForSingleObject(timer.handle, 10);
}

bool ReadLine(HANDLE handle, std::string* line) {
  line->clear();
  const ULONGLONG deadline = GetTickCount64() + 90000;
  for (;;) {
    DWORD available = 0;
    if (g_stopping.load() || GetTickCount64() >= deadline ||
        !PeekNamedPipe(handle, nullptr, 0, nullptr, &available, nullptr)) return false;
    if (available == 0) { WaitForEngineData(); continue; }
    char value = 0;
    DWORD read = 0;
    if (!ReadFile(handle, &value, 1, &read, nullptr) || read != 1) return false;
    if (value == '\n') return true;
    if (value != '\r') line->push_back(value);
    if (line->size() > 65536) return false;
  }
}

