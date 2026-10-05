// SPDX-License-Identifier: GPL-3.0-or-later
#include "rules.h"
#include "win_io.h"
#include <sstream>
#include <stdexcept>

namespace keymap {
namespace {
struct Token { std::wstring value; bool quoted = false; };
std::vector<Token> tokens(const std::wstring& line) {
  std::vector<Token> out;
  size_t i = 0;
  while (i < line.size()) {
    wchar_t c = line[i];
    if (c == L' ' || c == L'\t' || c == L'\r' || c == 0xfeff) { ++i; continue; }
    if (c == L'#') break;
    if (c == L'=') { out.push_back({L"="}); ++i; continue; }
    if (c == L'"') {
      Token t{{}, true}; bool closed = false; ++i;
      while (i < line.size()) {
        c = line[i++];
        if (c == L'"') { closed = true; break; }
        if (c == L'\\') {
          if (i == line.size()) throw std::runtime_error("unfinished escape");
          c = line[i++];
          if (c != L'\\' && c != L'"') throw std::runtime_error("unsupported escape");
        }
        t.value += c;
      }
      if (!closed) throw std::runtime_error("unterminated string");
      out.push_back(std::move(t));
    } else {
      size_t start = i;
      while (i < line.size() && line[i] != L' ' && line[i] != L'\t' &&
             line[i] != L'\r' && line[i] != L'#' && line[i] != L'=' && line[i] != L'"') ++i;
      out.push_back({line.substr(start, i-start)});
    }
  }
  return out;
}
bool sectionName(const std::wstring& s) {
  return s == L"symbols-hankaku" || s == L"symbols-zenkaku" ||
         s == L"pairs-hankaku" || s == L"pairs-zenkaku" || s == L"pairs";
}
std::wstring quote(const std::wstring& s) {
  std::wstring out = L"\"";
  for (wchar_t c : s) { if (c == L'"' || c == L'\\') out += L'\\'; out += c; }
  return out + L"\"";
}
size_t commentAt(const std::wstring& line) {
  bool quoted = false, escape = false;
  for (size_t i = 0; i < line.size(); ++i) {
    if (escape) { escape = false; continue; }
    if (quoted && line[i] == L'\\') { escape = true; continue; }
    if (line[i] == L'"') quoted = !quoted;
    if (!quoted && line[i] == L'#') return i;
  }
  return line.npos;
}
void parseInto(InputDocument& d, const std::wstring& text, bool report) {
  std::wistringstream in(text); std::wstring line, section; unsigned number = 0;
  while (std::getline(in, line)) {
    ++number;
    try {
      auto t = tokens(line);
      if (t.empty()) continue;
      if (t.size() == 1 && t[0].value.starts_with(L"[") && t[0].value.ends_with(L"]")) {
        section = t[0].value.substr(1, t[0].value.size()-2);
        if (!sectionName(section)) throw std::runtime_error("unknown section");
        continue;
      }
      if (t.size() < 3 || t[1].value != L"=") throw std::runtime_error("expected key = value");
      if (section.empty()) {
        if (t.size() != 3) throw std::runtime_error("expected one option value");
        if (t[0].value == L"width") {
          if (t[2].value != L"hankaku" && t[2].value != L"zenkaku") throw std::runtime_error("invalid width");
          d.width = t[2].value;
        } else if (t[0].value == L"auto-pair") {
          if (t[2].value != L"yes" && t[2].value != L"no") throw std::runtime_error("invalid auto-pair");
          d.autoPair = t[2].value == L"yes";
        } else throw std::runtime_error("unknown option");
      } else {
        if (!sectionName(section)) throw std::runtime_error("unknown section");
        size_t count = section.starts_with(L"symbols-") ? 1 : 2;
        if (t.size() != count+2 || t[0].value.empty()) throw std::runtime_error("wrong number of quoted values");
        InputRow row{section, t[0].value, {}};
        if (count == 1)
          for (auto c : row.key) if (c < 32 || c > 126) throw std::runtime_error("symbol keys must be ASCII");
        for (size_t i = 2; i < t.size(); ++i) {
          if (!t[i].quoted || (count == 2 && t[i].value.empty())) throw std::runtime_error("invalid quoted value");
          row.values.push_back(t[i].value);
        }
        auto existing = std::find_if(d.rows.begin(), d.rows.end(), [&](const auto& r) {
          return r.section == row.section && r.key == row.key;
        });
        if (existing == d.rows.end()) d.rows.push_back(row); else *existing = row;
      }
    } catch (const std::exception& e) {
      if (report) d.errors.push_back(L"行 " + std::to_wstring(number) + L": " + utf16(e.what()));
    }
  }
}
}  // namespace
std::wstring inputRulesTemplate() {
  // Generated at configure time from the shipped, commented UTF-8 template.
  return utf16(
#include "input_rules_template.inc"
  );
}
InputDocument InputDocument::Parse(const std::wstring& text) {
  InputDocument d;
  parseInto(d, inputRulesTemplate(), false);
  d.source = text;
  parseInto(d, text, true);
  return d;
}
void InputDocument::Set(const std::wstring& wanted, const std::wstring& key,
                        const std::vector<std::wstring>& values) {
  std::wstring replacement = wanted.empty() ? key : quote(key);
  replacement += L" = ";
  for (size_t i = 0; i < values.size(); ++i) {
    if (i) replacement += L" ";
    replacement += wanted.empty() ? values[i] : quote(values[i]);
  }
  std::wstring section; size_t at = 0, found = source.npos, len = 0;
  while (at < source.size()) {
    auto end = source.find(L'\n', at);
    if (end == source.npos) end = source.size();
    auto line = source.substr(at, end-at);
    try {
      auto t = tokens(line);
      if (t.size() == 1 && t[0].value.starts_with(L"[") && t[0].value.ends_with(L"]"))
        section = t[0].value.substr(1, t[0].value.size()-2);
      else if (section == wanted && t.size() >= 3 && t[0].value == key && t[1].value == L"=") {
        found = at; len = end-at;
      }
    } catch (...) {}
    at = end+1;
  }
  auto newline = source.find(L"\r\n") == source.npos ? L"\n" : L"\r\n";
  if (found != source.npos) {
    auto old = source.substr(found, len); auto hash = commentAt(old);
    if (hash != old.npos) {
      size_t start = hash;
      while (start && (old[start-1] == L' ' || old[start-1] == L'\t')) --start;
      replacement += old.substr(start);
    } else if (old.ends_with(L"\r")) replacement += L'\r';
    source.replace(found, len, replacement);
  } else if (wanted.empty()) source = replacement + newline + source;
  else {
    if (!source.empty() && !source.ends_with(L"\n")) source += newline;
    source += L"[" + wanted + L"]" + newline + replacement + newline;
  }
  *this = Parse(source);
}
std::wstring inputRulesPath() {
  auto path = env(L"NELISP_IME_INPUT_RULES");
  if (!path.empty()) return std::filesystem::absolute(path).wstring();
  // An isolated settings instance must not read the user's live rules.
  if (!env(L"NATIVEIME_REGISTRY_KEY").empty()) return {};
  auto appdata = env(L"APPDATA");
  return appdata.empty() ? L"" : (std::filesystem::path(appdata) / L"NativeIME" / L"input-rules.conf").wstring();
}
bool reloadInputEngine() {
  auto pipe = env(L"DDSKK_PIPE_NAME");
  // A custom settings instance cannot silently send to the live pipe.
  if (pipe.empty() && !env(L"NATIVEIME_REGISTRY_KEY").empty()) return false;
  if (pipe.empty()) pipe = L"\\\\.\\pipe\\ddskk-ime-v1";
  // Stream pipes do not support CallNamedPipe's message-mode transaction.
  HANDLE h = CreateFileW(pipe.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                        OPEN_EXISTING, FILE_FLAG_OVERLAPPED, nullptr);
  if (h == INVALID_HANDLE_VALUE) return false;
  OVERLAPPED ov{}; ov.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!ov.hEvent) { CloseHandle(h); return false; }
  auto io = [&](bool reading, void* data, DWORD length, DWORD& done) {
    ResetEvent(ov.hEvent);
    BOOL ok = reading ? ReadFile(h, data, length, &done, &ov) : WriteFile(h, data, length, &done, &ov);
    if (!ok && GetLastError() != ERROR_IO_PENDING) return false;
    if (WaitForSingleObject(ov.hEvent, 100) != WAIT_OBJECT_0) {
      CancelIoEx(h, &ov); GetOverlappedResult(h, &ov, &done, TRUE); return false;
    }
    return GetOverlappedResult(h, &ov, &done, FALSE) != 0;
  };
  char request[] = "ENGINE RELOAD\n", response[128]{}; DWORD done = 0;
  bool ok = io(false, request, sizeof(request)-1, done) && done == sizeof(request)-1 &&
            io(true, response, sizeof(response)-1, done) && std::string(response, done).starts_with("OK RELOADING");
  CloseHandle(ov.hEvent); CloseHandle(h); return ok;
}
void InputRulesWatch::Tick() {
  auto path = inputRulesPath(); std::wstring content; DWORD error = 0;
  if (path.empty() || !readFile(path, content, error)) return;
  const auto now = GetTickCount64();
  if (!initialized_) { path_ = path; content_ = content; initialized_ = true; return; }
  if (path != path_ || content != content_) {
    path_ = path; content_ = content; due_ = now + 200;
  }
  if (due_ && now >= due_) due_ = reloadInputEngine() ? 0 : now + 1000;
}
}  // namespace keymap
