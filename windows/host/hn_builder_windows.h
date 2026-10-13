// Private builder process and streamed source IO. Included after native_adapter.h.
#pragma once
#include "hn_builder.h"

namespace hn_builder_windows {
inline bool HarnessDiagnostics() {
  wchar_t value[2]{};
  return GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", value, 2) == 1 &&
      value[0] == L'1' && NativeImeRegistryKey().starts_with(L"Software\\NativeIME-test-");
}

inline std::wstring Fault() {
  if (!HarnessDiagnostics()) return {};
  wchar_t value[32]{};
  const auto size = GetEnvironmentVariableW(L"DDSKK_HOST_BUILDER_TEST_FAULT", value, 32);
  if (!size || size >= 32) return {};
  const std::wstring fault(value);
  return fault == L"midstream" || fault == L"timeout" || fault == L"overlong" ? fault : L"";
}

inline hn_builder::Mode Mode() {
  wchar_t value[16]{};
  const auto size = GetEnvironmentVariableW(L"DDSKK_HOST_NATIVE_BUILDER", value, 16);
  DWORD flag = 0, bytes = sizeof(flag);
  if (!size) RegGetValueW(HKEY_CURRENT_USER, NativeImeRegistryKey().c_str(),
      L"HostNativeBuilder", RRF_RT_REG_DWORD, nullptr, &flag, &bytes);
  const auto mode = size ? (size == 1 && (value[0] == L'1' || value[0] == L'2') ? value[0] - L'0' : 0)
                         : (flag <= 2 ? flag : 0);
  return static_cast<hn_builder::Mode>(mode);
}

class FileInput final : public hn_builder::Input {
 public:
  FileInput(const std::vector<std::wstring>& paths, bool overlong)
      : paths_(paths), overlong_(overlong) {}
  ~FileInput() override { Close(file_); }
  size_t FileCount() const override { return paths_.size(); }
  bool Read(size_t index, std::string& chunk, bool& eof) override {
    if (index >= paths_.size()) return false;
    if (!file_ || index != index_) {
      Close(file_);
      file_ = CreateFileW(paths_[index].c_str(), GENERIC_READ, FILE_SHARE_READ,
          nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
      if (file_ == INVALID_HANDLE_VALUE) { file_ = nullptr; return false; }
      LARGE_INTEGER size{};
      if (!GetFileSizeEx(file_, &size) || size.QuadPart < 0 || size.QuadPart > 0x7fffffff)
        return false;
      remaining_ = static_cast<uint64_t>(size.QuadPart); index_ = index;
    }
    if (overlong_) {
      overlong_ = false; chunk.assign(hn_builder::kLine + 1, 'x');
      chunk += '\n'; eof = false; return true;
    }
    const auto size = static_cast<DWORD>((std::min)(remaining_, uint64_t{65536}));
    chunk.resize(size); DWORD read = 0;
    if (size && (!ReadFile(file_, chunk.data(), size, &read, nullptr) || read != size))
      return false;
    remaining_ -= size; eof = remaining_ == 0;
    return true;
  }
 private:
  const std::vector<std::wstring>& paths_;
  bool overlong_;
  HANDLE file_ = nullptr;
  size_t index_ = 0;
  uint64_t remaining_ = 0;
};

class Channel final : public hn_builder::Channel {
 public:
  Channel(const std::wstring& repository, HANDLE job, std::wstring fault)
      : repository_(repository), fault_(std::move(fault)), job_(job) {}
  ~Channel() override { Retire(); }
  const std::string& StartReason() const { return start_reason_; }
  bool Start() override {
    std::wstring command;
    if (!native_adapter::ShadowPolicy::BuilderCommand(repository_, command)) {
      start_reason_ = "bundle-missing-or-unpinned"; return false;
    }
    // Copy the environment; entry selection never mutates the host/policy env.
    std::vector<std::wstring> entries;
    auto* inherited = GetEnvironmentStringsW();
    if (!inherited) return false;
    for (auto* row = inherited; *row; row += wcslen(row) + 1) {
      const std::wstring_view entry(row);
      const auto eq = entry.find('=');
      const std::wstring name(entry.substr(0, eq));
      if (_wcsicmp(name.c_str(), L"DDSKK_HOST_BUNDLE_ENTRY") == 0 ||
          _wcsicmp(name.c_str(), L"DDSKK_HOST_BUILDER_TEST_FAULT") == 0) continue;
      entries.emplace_back(entry);
    }
    FreeEnvironmentStringsW(inherited);
    entries.push_back(L"DDSKK_HOST_BUNDLE_ENTRY=index");
    if (!fault_.empty()) entries.push_back(L"DDSKK_HOST_BUILDER_TEST_FAULT=" + fault_);
    std::sort(entries.begin(), entries.end(), [](const auto& a, const auto& b) {
      return _wcsicmp(a.c_str(), b.c_str()) < 0;
    });
    std::vector<wchar_t> environment;
    for (const auto& entry : entries)
      environment.insert(environment.end(), entry.c_str(), entry.c_str() + entry.size() + 1);
    environment.push_back(0);
    SECURITY_ATTRIBUTES security{sizeof(security), nullptr, TRUE};
    HANDLE in_read = nullptr, out_write = nullptr;
    HANDLE error_sink = CreateFileW(L"NUL", GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
        &security, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (error_sink == INVALID_HANDLE_VALUE) return false;
    if (!CreatePipe(&in_read, &input_, &security, 4096) ||
        !CreatePipe(&output_, &out_write, &security, 4096) ||
        !SetHandleInformation(input_, HANDLE_FLAG_INHERIT, 0) ||
        !SetHandleInformation(output_, HANDLE_FLAG_INHERIT, 0)) {
      Close(in_read); Close(out_write); Close(error_sink); Retire(); return false;
    }
    SIZE_T bytes = 0;
    InitializeProcThreadAttributeList(nullptr, 1, 0, &bytes);
    std::vector<unsigned char> attributes(bytes);
    STARTUPINFOEXW si{}; si.StartupInfo.cb = sizeof(si);
    si.lpAttributeList = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attributes.data());
    if (!InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, &bytes)) {
      Close(in_read); Close(out_write); Close(error_sink); Retire(); return false;
    }
    HANDLE handles[] = {in_read, out_write, error_sink};
    const bool updated = UpdateProcThreadAttribute(si.lpAttributeList, 0,
        PROC_THREAD_ATTRIBUTE_HANDLE_LIST, handles, sizeof(handles), nullptr, nullptr) != 0;
    si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    si.StartupInfo.hStdInput = in_read; si.StartupInfo.hStdOutput = out_write;
    si.StartupInfo.hStdError = error_sink;
    PROCESS_INFORMATION pi{};
    const bool started = updated && CreateProcessW(nullptr, command.data(), nullptr, nullptr,
        TRUE, EXTENDED_STARTUPINFO_PRESENT | CREATE_SUSPENDED | CREATE_NO_WINDOW |
        CREATE_UNICODE_ENVIRONMENT | BELOW_NORMAL_PRIORITY_CLASS, environment.data(),
        repository_.c_str(), &si.StartupInfo, &pi);
    DeleteProcThreadAttributeList(si.lpAttributeList);
    Close(in_read); Close(out_write); Close(error_sink);
    if (!started) { Retire(); return false; }
    process_ = pi.hProcess;
    if (!AssignProcessToJobObject(job_, process_) || ResumeThread(pi.hThread) == static_cast<DWORD>(-1)) {
      CloseHandle(pi.hThread); Retire(); return false;
    }
    CloseHandle(pi.hThread);
    LogEvent("builder-start pid=" + std::to_string(pi.dwProcessId));
    return true;
  }
  hn_builder::IoResult ReadReady(std::string& ready, uint32_t timeout_ms) override {
    ready.clear(); const auto deadline = GetTickCount64() + timeout_ms;
    while (ready.size() < hn_builder::kReady.size()) {
      std::string byte;
      const auto result = Read(1, byte, deadline);
      if (result != hn_builder::IoResult::Ok) return result;
      ready += byte;
      if (byte[0] == '\n') return hn_builder::IoResult::Ok;
    }
    return hn_builder::IoResult::Ok;
  }
  hn_builder::IoResult Exchange(std::string_view request, std::string& reply,
                                uint32_t timeout_ms) override {
    // A short deadline is possible only through the doubly guarded test fault.
    if (fault_ == L"timeout") timeout_ms = 100;
    const auto deadline = GetTickCount64() + timeout_ms;
    if (!TimedWriteAll(input_, std::string(request), deadline))
      return GetTickCount64() >= deadline ? hn_builder::IoResult::Timeout : hn_builder::IoResult::Transport;
    std::string header;
    auto result = Read(hn_builder::kHeader, header, deadline);
    if (result != hn_builder::IoResult::Ok) return result;
    uint64_t body = 0;
    if (header.substr(0, 4) != "HNBR" || !hn_builder::GetLe(header, 4, 4, body) ||
        body < hn_builder::kHeader - 8 || body > hn_builder::kHeader - 8 + hn_builder::kReplyPayload)
      return hn_builder::IoResult::Transport;
    std::string payload;
    result = Read(static_cast<size_t>(body) - (hn_builder::kHeader - 8), payload, deadline);
    if (result == hn_builder::IoResult::Ok) reply = header + payload;
    return result;
  }
  void Retire() noexcept override {
    if (process_) {
      TerminateProcess(process_, 1); WaitForSingleObject(process_, 5000);
      LogEvent("builder-retire pid=" + std::to_string(GetProcessId(process_)));
    }
    // No reader survives this operation; closing stdout discards late bytes.
    Close(input_); Close(output_); Close(process_);
  }
 private:
  hn_builder::IoResult Read(size_t size, std::string& bytes, ULONGLONG deadline) {
    bytes.clear(); bytes.reserve(size);
    while (bytes.size() < size) {
      if (g_stopping) return hn_builder::IoResult::Transport;
      if (GetTickCount64() >= deadline) return hn_builder::IoResult::Timeout;
      DWORD available = 0;
      if (!PeekNamedPipe(output_, nullptr, 0, nullptr, &available, nullptr))
        return hn_builder::IoResult::Transport;
      if (!available) {
        if (WaitForSingleObject(process_, 0) != WAIT_TIMEOUT) return hn_builder::IoResult::Transport;
        Sleep(1); continue;
      }
      const auto count = static_cast<DWORD>((std::min)(size - bytes.size(), static_cast<size_t>(available)));
      const auto offset = bytes.size(); bytes.resize(offset + count); DWORD read = 0;
      if (!ReadFile(output_, bytes.data() + offset, count, &read, nullptr) || read != count)
        return hn_builder::IoResult::Transport;
    }
    return hn_builder::IoResult::Ok;
  }
  std::wstring repository_, fault_;
  HANDLE job_, process_ = nullptr, input_ = nullptr, output_ = nullptr;
  std::string start_reason_;
};
}  // namespace hn_builder_windows
