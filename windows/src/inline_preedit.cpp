// SPDX-License-Identifier: GPL-3.0-or-later
#include <winsock2.h>
#include <ws2tcpip.h>
#include "inline_preedit.h"
#include <fstream>
#include <filesystem>
#include <regex>
#include <sstream>
#pragma comment(lib, "ws2_32.lib")

namespace {
std::wstring Env(const wchar_t* name) {
  DWORD size = GetEnvironmentVariableW(name, nullptr, 0);
  if (!size) return {};
  std::wstring value(size, 0);
  DWORD got = GetEnvironmentVariableW(name, value.data(), size);
  if (!got || got >= size) return {};
  value.resize(got); return value;
}
bool Discovery(int* port, std::string* token) {
  auto directory = Env(L"NELISP_IME_INLINE_DIR");
  if (directory.empty()) {
    directory = Env(L"LOCALAPPDATA");
    if (directory.empty()) return false;
    directory += L"\\DDSKK\\emacs-inline";
  }
  std::ifstream file(std::filesystem::path(directory) /
                     (std::to_wstring(GetCurrentProcessId()) + L".json"));
  std::string data(1025, 0);
  file.read(data.data(), static_cast<std::streamsize>(data.size()));
  data.resize(static_cast<size_t>(file.gcount()));
  if (data.size() > 1024) return false;
  // JSON object member order is immaterial. Restrict the object to exactly
  // these three scalar members (no duplicates, nesting, or other endpoints).
  static const std::regex object(R"json(^\s*\{\s*("[a-z]+"\s*:\s*(?:[0-9]+|"[0-9a-fA-F]+")\s*,\s*){2}"[a-z]+"\s*:\s*(?:[0-9]+|"[0-9a-fA-F]+")\s*\}\s*$)json");
  static const std::regex member(R"json("([a-z]+)"\s*:\s*([0-9]+|"[0-9a-fA-F]+"))json");
  if (!std::regex_match(data, object)) return false;
  bool version_seen = false, port_seen = false, token_seen = false;
  for (std::sregex_iterator i(data.begin(), data.end(), member), end; i != end; ++i) {
    const auto name = (*i)[1].str(), value = (*i)[2].str();
    if (name == "version" && value == "1" && !version_seen) version_seen = true;
    else if (name == "port" && !port_seen && value.size() <= 5 && value[0] != '"') {
      *port = std::stoi(value); port_seen = true;
    } else if (name == "token" && !token_seen && value.size() == 34 && value[0] == '"') {
      *token = value.substr(1, 32); token_seen = true;
    } else return false;
  }
  if (!version_seen || !port_seen || !token_seen) return false;
  return *port > 0 && *port <= 65535;
}
bool Ready(SOCKET socket, bool write) {
  fd_set set; FD_ZERO(&set); FD_SET(socket, &set);
  timeval timeout{0, 20000};
  return select(0, write ? nullptr : &set, write ? &set : nullptr,
                nullptr, &timeout) > 0;
}
std::string Encode(const std::wstring& text) {
  int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(),
      static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
  std::string utf8(size, 0);
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(),
      static_cast<int>(text.size()), utf8.data(), size, nullptr, nullptr);
  std::string encoded;
  for (char ch : utf8) {
    switch (ch) {
      case '%': encoded += "%25"; break;
      case ' ': encoded += "%20"; break;
      case '\r': encoded += "%0D"; break;
      case '\n': encoded += "%0A"; break;
      default: encoded += ch;
    }
  }
  return encoded;
}
}
void InlinePreedit::Start(HWND notify, UINT message) {
  if (worker_.joinable()) return;
  notify_ = notify; message_ = message; stop_ = false;
  worker_ = std::thread([this] {
    try { Run(); } catch (...) { epoch_ = 0; PostMessageW(notify_, message_, 0, 0); }
  });
}
void InlinePreedit::Stop() {
  stop_ = true;
  if (worker_.joinable()) worker_.join();
  epoch_ = 0;
}
bool InlinePreedit::Publish(uint64_t epoch, const std::wstring& text, size_t cursor) {
  std::lock_guard lock(mutex_);
  if (!epoch || epoch != epoch_) return false;
  if (text.size() > 65536 || updates_.size() >= 64) {
    epoch_ = 0; return false; // bounded memory, caller falls back losslessly
  }
  if (!updates_.empty() && !updates_.back().clear) updates_.pop_back();
  updates_.push_back({false, text, cursor}); return true;
}
void InlinePreedit::Clear(uint64_t epoch) {
  std::lock_guard lock(mutex_);
  if (!epoch || epoch != epoch_) return;
  if (!updates_.empty() && !updates_.back().clear) updates_.pop_back();
  if (updates_.size() < 64) updates_.push_back({true, {}, 0});
  else epoch_ = 0;
}
bool InlinePreedit::Caret(uint64_t epoch, RECT* rect) {
  std::lock_guard lock(mutex_);
  if (!epoch || epoch != epoch_ || !caret_valid_) return false;
  *rect = caret_; return true;
}
void InlinePreedit::Run() {
  WSADATA startup{};
  if (WSAStartup(MAKEWORD(2, 2), &startup)) return;
  uint64_t generation = 0;
  ULONGLONG next_discovery = 0;
  while (!stop_) {
    if (GetTickCount64() < next_discovery) { Sleep(20); continue; }
    next_discovery = GetTickCount64() + 1000;
    int port = 0; std::string token;
    if (!Discovery(&port, &token)) continue;
    SOCKET socket = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (socket == INVALID_SOCKET) continue;
    u_long nonblocking = 1; ioctlsocket(socket, FIONBIO, &nonblocking);
    sockaddr_in address{}; address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = htons(static_cast<u_short>(port));
    int connected = connect(socket, reinterpret_cast<sockaddr*>(&address), sizeof(address));
    bool failed = connected == SOCKET_ERROR && WSAGetLastError() != WSAEWOULDBLOCK;
    ULONGLONG deadline = GetTickCount64() + 1000;
    while (!failed && connected && !stop_ && GetTickCount64() < deadline) {
      if (!Ready(socket, true)) continue;
      int error = 0, length = sizeof(error);
      getsockopt(socket, SOL_SOCKET, SO_ERROR, reinterpret_cast<char*>(&error), &length);
      failed = error != 0; connected = 0;
    }
    std::string outbound = "HELLO 1 " + token + " " + std::to_string(GetCurrentProcessId()) + "\n";
    std::string incoming;
    bool authenticated = false;
    uint64_t sequence = 0, connection_epoch = 0;
    deadline = GetTickCount64() + 1000;
    ULONGLONG send_deadline = deadline;
    while (!failed && !connected && !stop_) {
      if ((!authenticated && GetTickCount64() >= deadline) ||
          (!outbound.empty() && GetTickCount64() >= send_deadline)) break;
      if (authenticated && Epoch() != connection_epoch) break;
      if (authenticated && outbound.empty()) {
        Update update{}; bool have = false;
        { std::lock_guard lock(mutex_);
          if (!updates_.empty()) { update = std::move(updates_.front()); updates_.pop_front(); have = true; }
        }
        if (have) {
          outbound = update.clear ? "CLEAR " + std::to_string(++sequence) + "\n"
              : "PREEDIT " + std::to_string(++sequence) + " " +
                std::to_string(update.cursor) + " " + Encode(update.text) + "\n";
          send_deadline = GetTickCount64() + 1000;
        }
      }
      if (!outbound.empty()) {
        int sent = send(socket, outbound.data(), static_cast<int>(outbound.size()), 0);
        if (sent > 0) outbound.erase(0, sent);
        else if (sent == 0 || WSAGetLastError() != WSAEWOULDBLOCK) break;
      }
      if (!Ready(socket, false)) continue;
      char buffer[1024]; int count = recv(socket, buffer, sizeof(buffer), 0);
      if (count <= 0) break;
      incoming.append(buffer, count);
      if (incoming.size() > 4096) break;
      size_t end;
      while ((end = incoming.find('\n')) != std::string::npos) {
        std::string line = incoming.substr(0, end); incoming.erase(0, end + 1);
        if (!authenticated) {
          if (line != "OK 1") { failed = true; break; }
          { std::lock_guard lock(mutex_);
            updates_.clear(); caret_valid_ = false;
            connection_epoch = ++generation; epoch_ = connection_epoch;
          }
          authenticated = true;
        } else {
          std::istringstream input(line); std::string command, extra;
          long x, y, height;
          if (!(input >> command >> x >> y >> height) || command != "CARET" ||
              (input >> extra) || x < -1000000 || x > 1000000 ||
              y < -1000000 || y > 1000000 || height < 1 || height > 10000) {
            failed = true; break;
          }
          { std::lock_guard lock(mutex_); caret_ = {x, y, x, y + height}; caret_valid_ = true; }
          PostMessageW(notify_, message_, 0, 0);
        }
      }
    }
    { std::lock_guard lock(mutex_); epoch_ = 0; updates_.clear(); caret_valid_ = false; }
    closesocket(socket);
    if (authenticated && !stop_) PostMessageW(notify_, message_, 0, 0);
  }
  WSACleanup();
}
