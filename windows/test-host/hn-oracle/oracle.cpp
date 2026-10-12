// Test-only linkage of exact production bodies. All startup OS reads/writes
// below operate on an explicit in-memory snapshot. No host is launched.
#include <windows.h>
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <stdexcept>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>
#include "../../src/local_index.h"

namespace snapshot {
struct Value { DWORD type; std::vector<BYTE> bytes; };
std::map<std::wstring,std::wstring> env;
std::map<std::wstring,Value> registry;
std::vector<std::wstring> operations;
std::wstring expanded=L"public/expanded.jisyo";
bool key_present=true, framework=true, expansion=true;
ULONGLONG tick=0;
ULONGLONG WINAPI Tick() { return tick; }
std::vector<wchar_t> block;
DWORD WINAPI GetEnv(LPCWSTR name, LPWSTR out, DWORD capacity) {
  auto it=env.find(name); if (it==env.end()) return 0;
  const DWORD count=static_cast<DWORD>(it->second.size());
  if (!out || capacity<=count) return count+1;
  std::copy(it->second.begin(),it->second.end(),out); out[count]=0; return count;
}
BOOL WINAPI SetEnv(LPCWSTR name,LPCWSTR value) {
  operations.push_back(std::wstring(value ? L"set:" : L"remove:")+name+(value ? L"="+std::wstring(value) : L""));
  if (value) env[name]=value; else env.erase(name); return TRUE;
}
LSTATUS WINAPI Open(HKEY,LPCWSTR,DWORD,REGSAM,PHKEY key) {
  *key=reinterpret_cast<HKEY>(1); return key_present ? ERROR_SUCCESS : ERROR_FILE_NOT_FOUND;
}
LSTATUS WINAPI Query(HKEY,LPCWSTR name,LPDWORD,LPDWORD type,LPBYTE out,LPDWORD bytes) {
  auto it=registry.find(name); if (it==registry.end()) return ERROR_FILE_NOT_FOUND;
  if (type) *type=it->second.type;
  if (*bytes<it->second.bytes.size()) { *bytes=static_cast<DWORD>(it->second.bytes.size()); return ERROR_MORE_DATA; }
  *bytes=static_cast<DWORD>(it->second.bytes.size()); std::memcpy(out,it->second.bytes.data(),*bytes); return ERROR_SUCCESS;
}
LSTATUS WINAPI CloseKey(HKEY) { return ERROR_SUCCESS; }
DWORD WINAPI Attributes(LPCWSTR) { return framework ? FILE_ATTRIBUTE_NORMAL : INVALID_FILE_ATTRIBUTES; }
DWORD WINAPI Expand(LPCWSTR,LPWSTR out,DWORD capacity) {
  if (!expansion) return 0;
  const auto count=static_cast<DWORD>(expanded.size()+1);
  if (out && capacity>=count) std::copy(expanded.c_str(),expanded.c_str()+count,out); return count;
}
LPWCH WINAPI Strings() {
  block.clear(); for (const auto& [name,value]:env) {
    const auto entry=name+L"="+value; block.insert(block.end(),entry.c_str(),entry.c_str()+entry.size()+1);
  }
  block.push_back(0); if (block.size()==1) block.push_back(0); return block.data();
}
BOOL WINAPI FreeStrings(LPWCH) { return TRUE; }
void Text(const wchar_t* name,const std::wstring& value,DWORD type=REG_SZ) {
  const auto* data=reinterpret_cast<const BYTE*>(value.c_str());
  registry[name]={type,std::vector<BYTE>(data,data+(value.size()+1)*sizeof(wchar_t))};
}
void Number(const wchar_t* name,DWORD value,DWORD type=REG_DWORD) {
  const auto* data=reinterpret_cast<const BYTE*>(&value); registry[name]={type,std::vector<BYTE>(data,data+sizeof(value))};
}
}

#define GetEnvironmentVariableW snapshot::GetEnv
#define SetEnvironmentVariableW snapshot::SetEnv
#define RegOpenKeyExW snapshot::Open
#define RegQueryValueExW snapshot::Query
#define RegCloseKey snapshot::CloseKey
#define GetFileAttributesW snapshot::Attributes
#define ExpandEnvironmentStringsW snapshot::Expand
#define GetEnvironmentStringsW snapshot::Strings
#define FreeEnvironmentStringsW snapshot::FreeStrings
#define GetTickCount64 snapshot::Tick
std::wstring NativeImeRegistryKey() { return L"synthetic-snapshot-only"; }
void Close(HANDLE) { throw std::runtime_error("unexpected OS cleanup"); }
constexpr wchar_t kDdskkRunner[]=L"engine/ddskk-engine-stdio.el";
constexpr wchar_t kFrameworkRunner[]=L"framework/nelisp-ime-stdio.el";
struct { std::vector<std::unordered_map<std::string,std::string>> maps; } g_builtin_dictionary;
#include "production.inc"

std::string Hex(std::string_view value) {
  std::string out; for (unsigned char byte:value) { out+="0123456789abcdef"[byte>>4]; out+="0123456789abcdef"[byte&15]; } return out;
}
std::string WideBytes(const std::wstring& value) {
  return std::string(reinterpret_cast<const char*>(value.data()),value.size()*sizeof(wchar_t));
}
std::string Json(std::string_view value) {
  std::string out="\""; for (unsigned char ch:value) {
    if (ch=='"' || ch=='\\') { out+='\\'; out+=ch; }
    else if (ch<32) { char b[7]; std::snprintf(b,sizeof(b),"\\u%04x",ch); out+=b; }
    else out+=ch;
  } return out+'"';
}
std::ofstream report;
void Record(const std::string& name,const std::vector<std::string>& inputs,const std::string& result) {
  report << "{\"case\":" << Json(name) << ",\"inputs_hex\":[";
  for (size_t i=0;i<inputs.size();++i) { if (i) report << ','; report << Json(Hex(inputs[i])); }
  report << "],\"result_hex\":" << Json(Hex(result)) << "}\n";
}
void Merges() {
  const std::vector<std::vector<std::string>> cases={
    {},{""},{"//"},{"/a/b;a-first/","/b;b-later/c/a;late/"},
    {"/a;first/b/","/a/b;later/"},{"/a/","/a;later/"},
    {"/a;first/","/a/"},{"/before/[x/inside/]/after/","/inside/"},
    {"/[unterminated/hidden/","/visible/"},{"/a//tail"},
    {"/(concat \"x\" \"y\")/z;note/[literal]/"},
    {"/slash;semi/back\\slash/quote\"/line\nbreak/close]/"},
    {"/\xf0\x9f\x98\x80/\xe6\xbc\xa2;note/"},
    {"/"+std::string(262145,'x')+";large/","/small/"}
  };
  for (size_t i=0;i<cases.size();++i) {
    g_builtin_dictionary.maps.clear();
    for (const auto& raw:cases[i]) g_builtin_dictionary.maps.push_back({{"key",raw}});
    Record("builtin-"+std::to_string(i),cases[i],MergeBuiltinCandidates("key"));
    Record("builtin-missing-"+std::to_string(i),cases[i],MergeBuiltinCandidates("missing"));
    const auto files=cases[i].empty() ? "" : cases[i][0];
    const auto server=cases[i].size()<2 ? "" : cases[i][1];
    const auto merged=MergeServerReply(files,server);
    Record("server-"+std::to_string(i),{files,server},merged);
    Record("engine-"+std::to_string(i),{merged},EngineDictionaryReply(merged));
    Record("quote-"+std::to_string(i),{files},QuoteEngineString(files));
  }
  for (const auto& raw:std::vector<std::string>{"","4","0/a/","1","1/","1//a//tail","1a/b/last","1/[x/a/]/","1/(concat \"x\" \"y\")/"})
    Record("engine-status",{raw},EngineDictionaryReply(raw));
  const std::string controls("\0\t\n\r\x1f\x7f\"\\/;[]",13);
  Record("quote-controls",{controls},QuoteEngineString(controls));
}
void Parser(const std::filesystem::path& input,const std::filesystem::path& output) {
  std::ifstream file(input,std::ios::binary); const std::string bytes((std::istreambuf_iterator<char>(file)),{});
  if (!file.eof() && !file.good()) throw std::runtime_error("fixture read failed");
  std::unordered_map<std::string,std::string> parsed;
  size_t count=0; if (!LoadDictionaryFile(input.wstring(),&parsed,&count)) throw std::runtime_error("production fixture load failed");
  std::map<std::string,std::string> ordered(parsed.begin(),parsed.end());
  std::ofstream binary(output/"parsed.bin",std::ios::binary);
  // uint32 LE byte lengths followed by exact key/tail UTF-8 bytes.
  const auto length=[&](size_t size) { for (unsigned i=0;i<4;++i) binary.put(static_cast<char>((size>>(i*8))&255)); };
  for (const auto& [key,tail]:ordered) { length(key.size()); binary.write(key.data(),key.size()); length(tail.size()); binary.write(tail.data(),tail.size()); Record("parsed-entry",{key},tail); }
  Record("parser-file",{bytes},std::to_string(count));
  parsed.clear(); ParseSkkJisyo(bytes,&parsed);
  ordered={parsed.begin(),parsed.end()};
  for (const auto& [key,tail]:ordered) Record("parser-raw-bom",{key},tail);
}
void Startup() {
  // A sequence pins static imported-variable provenance across reloads.
  for (unsigned i=0;i<20;++i) {
    if (i!=2 && i!=3) {
      // Reset the production static provenance before independent snapshots;
      // cases 2/3 deliberately continue case 1's imported-variable lineage.
      snapshot::key_present=false; snapshot::env.clear(); ApplyEngineEnvFromRegistry();
    }
    snapshot::operations.clear(); snapshot::registry.clear();
    if (i!=2 && i!=3) snapshot::env.clear();
    snapshot::key_present=i!=4; snapshot::framework=i!=7; snapshot::expansion=i!=9;
    snapshot::expanded=L"public/expanded.jisyo";
    if (i!=3) {
      snapshot::Text(L"Engine",i==5 ? L"" : i==6 || i==7 ? L"other" : L"ddskk");
      snapshot::Text(L"UserJisyoPath",L"%PUBLIC%/synthetic.jisyo");
      const wchar_t* names[]={L"UserJisyoBatch",L"BehaviorOkuriStrictly",L"BehaviorDeleteOkuriOnCancel",L"BehaviorAddKatakanaCand",L"BehaviorLearnDisabled"};
      for (unsigned j=0;j<5;++j) snapshot::Number(names[j],i==2 ? 9 : j);
    }
    if (i==1) { snapshot::env[L"NELISP_IME_ENGINE"]=L"PaSsThRoUgH"; snapshot::env[L"DDSKK_USER_JISYO"]=L"public/override"; snapshot::env[L"DDSKK_OKURI_STRICTLY"]=L"0"; }
    if (i==8) {
      snapshot::env[L"NELISP_IME_ENGINE"]=L""; snapshot::env[L"DDSKK_USER_JISYO"]=L"";
      for (const auto* name:{L"DDSKK_USER_JISYO_SAVE_BATCH_SIZE",L"DDSKK_OKURI_STRICTLY",L"DDSKK_DELETE_OKURI_ON_CANCEL",L"DDSKK_SEARCH_KATAKANA",L"DDSKK_LEARN_DISABLED"}) snapshot::env[name]=L"";
    }
    if (i==10) snapshot::env[L"NELISP_IME_ENGINE"]=std::wstring(64,L'x');
    if (i==11) snapshot::Text(L"Engine",std::wstring(64,L'x'));
    if (i==12) { snapshot::Text(L"Engine",L"other",REG_BINARY); snapshot::Number(L"BehaviorOkuriStrictly",7,REG_BINARY); }
    if (i==13) { snapshot::Text(L"UserJisyoPath",L""); snapshot::Text(L"BehaviorOkuriStrictly",L"too long",REG_SZ); }
    if (i==14) snapshot::Text(L"UserJisyoPath",std::wstring(32768,L'p'));
    if (i==15) snapshot::env[L"NELISP_IME_ENGINE"]=std::wstring(63,L'x');
    if (i==16 || i==17) { snapshot::env[L"DDSKK_NELISP_ENTRY"]=i==16 ? L"NaTiVe" : std::wstring(16,L'n'); snapshot::env[L"NELISP_IME_ENGINE"]=i==16 ? L"DDSKK" : L"other"; }
    if (i==18) { snapshot::Text(L"Engine",L"other"); snapshot::registry[L"Engine"].bytes.resize(10); snapshot::Number(L"UserJisyoBatch",0xffffffff); }
    if (i==19) { snapshot::env[L"NELISP_IME_ENGINE"]=L"other"; snapshot::env[L"DDSKK_NELISP_ENTRY"]=L"native"; snapshot::Text(L"UserJisyoPath",L"%PUBLIC%/synthetic.jisyo",REG_EXPAND_SZ); }
    std::vector<std::string> inputs;
    inputs.push_back(std::to_string(snapshot::key_present)+","+std::to_string(snapshot::framework)+","+std::to_string(snapshot::expansion));
    inputs.push_back(WideBytes(snapshot::expanded));
    for (const auto& [name,value]:snapshot::env) inputs.push_back("env:"+WideBytes(name)+"="+WideBytes(value));
    for (const auto& [name,value]:snapshot::registry) inputs.push_back("reg:"+WideBytes(name)+":"+std::to_string(value.type)+":"+std::string(reinterpret_cast<const char*>(value.bytes.data()),value.bytes.size()));
    const auto id=ConfiguredEngineId(); const auto runner=EngineRunnerScript(L"public-fixture",id);
    const bool native=UseNativeEntry() && runner==kDdskkRunner;
    ApplyEngineEnvFromRegistry();
    const auto block=ChildEnvironment(id);
    Record("startup-"+std::to_string(i),inputs,WideBytes(id)+"|"+WideBytes(runner)+"|"+(native ? "native" : "load")+"|"+std::string(reinterpret_cast<const char*>(block.data()),block.size()*sizeof(wchar_t)));
    for (const auto& operation:snapshot::operations) Record("startup-operation-"+std::to_string(i),{},WideBytes(operation));
  }
}
void Policies() {
  struct Decision { const char* name; uint64_t (*run)(uint64_t,uint64_t,uint64_t); };
  const Decision decisions[]={
    {"SOURCES/Sources",FallbackSources0},{"SOURCES/Order",FallbackOrder0},
    {"CACHE/CacheTtl",FallbackCacheTtl0},{"CACHE/Cache",FallbackCache0},{"CACHE/Capacity",FallbackCapacity0},
    {"RESTART/failure",FallbackRestart0},{"RESTART/success",FallbackRestart1},{"RESTART/Replacement",FallbackReplacement0},
    {"PUBLICATION/Intent",FallbackIntent0},{"PUBLICATION/Payload",FallbackPayload0},{"LEARNING/Learning",FallbackLearning0},
    {"STARTUP/Config",FallbackConfig0}
  };
  for (const auto& decision:decisions) {
    for (uint64_t a: {0ULL,1ULL,255ULL,256ULL,1000ULL,15000ULL,30000ULL,60000ULL})
      for (uint64_t b: {0ULL,1ULL,1999ULL,2000ULL,59999ULL,60000ULL})
        for (uint64_t c: {0ULL,1ULL,2ULL}) {
          Record(decision.name,{std::to_string(a),std::to_string(b),std::to_string(c)},std::to_string(decision.run(a,b,c)));
        }
  }
}
int main(int argc,char** argv) {
  try {
    if (argc!=3) throw std::runtime_error("usage: hn-oracle PUBLIC_SYNTHETIC_FIXTURE OUTPUT_DIRECTORY");
    const std::filesystem::path output=argv[2]; std::filesystem::create_directories(output);
    report.open(output/"oracle.jsonl",std::ios::binary); if (!report) throw std::runtime_error("output open failed");
    Merges(); Parser(argv[1],output); Startup(); Policies(); report.close();
    if (!report) throw std::runtime_error("output write failed"); return 0;
  } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
