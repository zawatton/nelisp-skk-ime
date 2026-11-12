// Oracle driver: runs a realtime-cases file against the real C++
// RealtimeFrontend (windows/src/realtime_frontend.cpp) and prints the trace
// that realtime-client.el's EXE prints.  Build (Linux, no Windows headers):
//   g++ -std=c++20 -I windows/src realtime-oracle.cpp windows/src/realtime_frontend.cpp
#include "realtime_frontend.h"

#include <cstdio>
#include <fstream>
#include <iostream>
#include <map>
#include <sstream>
#include <string>

static void Units(const std::wstring& s) {
  if (s.empty()) { std::printf("-"); return; }
  for (size_t i = 0; i < s.size(); ++i)
    std::printf(i ? ".%04x" : "%04x", static_cast<unsigned>(s[i]));
}

int main(int argc, char** argv) {
  if (argc < 2) return 2;
  std::ifstream in(argv[1]);
  std::map<std::string, ddskk::RealtimeFrontend> objs;
  std::string line;
  int idx = 0;
  while (std::getline(in, line)) {
    std::istringstream is(line);
    std::string op, name, arg;
    is >> op >> name >> arg;
    if (op.empty() || op[0] == '#' || op == "CHECK") continue;
    std::optional<ddskk::EngineState> st;
    if (op == "NEW") objs[name] = ddskk::RealtimeFrontend();
    else if (op == "CONT") objs[name].SetContinuousPreedit(arg == "1");
    else if (op == "FEED") st = objs[name].Feed(static_cast<char32_t>(std::stoul(arg, nullptr, 16)));
    else if (op == "BS") st = objs[name].Backspace();
    else if (op == "COMMIT") st = objs[name].Commit();
    else if (op == "QUIT") st = objs[name].Quit();
    else if (op == "RESTORE") st = objs[name].RestorePreedit();
    else if (op == "KATA") st = objs[name].ToKatakana();
    else if (op == "CKATA") st = objs[name].CommitKatakana();
    else if (op == "HIRA") st = objs[name].ToHiragana();
    else if (op == "RESET") objs[name].Reset();
    else { std::fprintf(stderr, "bad op %s\n", op.c_str()); return 2; }
    auto& f = objs[name];
    std::printf("T %x r=%d", idx++, st ? 1 : 0);
    if (st) {
      int m = st->mode == L"hiragana" ? 0 : st->mode == L"katakana" ? 1
            : st->mode == L"latin" ? 2 : st->mode == L"wide-latin" ? 3 : 4;
      std::printf(" m=%d c=%d t=", m, st->composition_start);
      Units(st->text);
      std::printf(" p=");
      if (st->pending_romaji.empty()) std::printf("-");
      for (wchar_t c : st->pending_romaji) std::printf("%c", static_cast<char>(c));
    }
    std::printf(" f=%d%d%d%d%d v=", f.composing(), f.preedit(), f.katakana(),
                f.latin(), f.wide_latin());
    Units(f.preview_reading());
    std::printf(" raw=");
    if (f.raw_keys().empty()) std::printf("-");
    for (size_t i = 0; i < f.raw_keys().size(); ++i)
      std::printf(i ? ".%02x" : "%02x", static_cast<unsigned>(f.raw_keys()[i]));
    std::printf("\n");
  }
  return 0;
}
