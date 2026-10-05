// SPDX-License-Identifier: GPL-3.0-or-later
#include "auto_pair.h"
#include "realtime_frontend.h"
#include <fstream>
#include <iostream>
#include <sstream>
#include <set>
int wmain(int argc,wchar_t** argv) {
  if(argc!=2)return 2;
  std::ifstream file(argv[1]);std::string line;std::getline(file,line);
  auto rules=ddskk::ParseRomajiRules(line);if(!rules)return 3;
  unsigned checks=0,failed=0,symbols=0;
  const std::set<std::string> wanted{"!",",",".",":",";","?","z "};
  ddskk::AutoPair pairs;pairs.SetRules(*rules);
  for(const auto& r:*rules)if(wanted.contains(r.key))++symbols;
  while(std::getline(file,line)) {
    const auto space=line.find(' ');if(space==line.npos)continue;
    auto hex=line.substr(0,space);auto oracle=ddskk::ParseStateResponse(line.substr(space+1));
    if(!oracle){++failed;continue;}
    std::u32string keys;
    for(size_t i=0;i<hex.size();i+=6)keys.push_back(static_cast<char32_t>(std::stoul(hex.substr(i,6),nullptr,16)));
    ddskk::RealtimeFrontend frontend;frontend.SetRules(*rules);
    std::optional<ddskk::EngineState> actual;
    for(auto key:keys)actual=frontend.Feed(key);
    ++checks;
    if(!actual || actual->text!=oracle->text || actual->pending_romaji!=oracle->pending_romaji || actual->mode!=oracle->mode) {
      ++failed;std::cout<<"PARITY mismatch key="<<hex<<"\n";
    }
  }
  ddskk::EngineState state;state.mode=L"hiragana";state.text=L"(";
  bool enabled=false;for(const auto& r:*rules)if(r.command==L"input-pair")enabled=true;
  ++checks;if(pairs.Closer(state)!=(enabled?L")":L""))++failed;
  state.mode=L"latin";++checks;if(!pairs.Closer(state).empty())++failed;
  state.mode=L"preedit";state.composition_start=0;++checks;if(!pairs.Closer(state).empty())++failed;
  state.mode=L"candidate";++checks;if(!pairs.Closer(state).empty())++failed;
  for (char key : {'l','L','q','Q'}) {
    auto customized=*rules;
    std::erase_if(customized,[&](const auto& r){return r.key==std::string(1,key);});
    customized.push_back({std::string(1,key),"",L"literal",L"literal",L"",L""});
    ddskk::RealtimeFrontend frontend;frontend.SetRules(customized);
    auto actual=frontend.Feed(key);++checks;
    if(!actual || actual->text!=L"literal" || actual->mode!=L"hiragana")++failed;
  }
  std::cout<<"INPUT_PARITY checks="<<checks<<" symbols="<<symbols<<" failures="<<failed<<"\n";
  return failed || symbols!=7 || checks<=3 ? 1 : 0;
}
