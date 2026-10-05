// SPDX-License-Identifier: GPL-3.0-or-later
#include "rules.h"
#include "win_io.h"
DocumentStore* inputApplicationStore = nullptr;
bool InputProviderWarmup() {
  if(keymap::env(L"NELISP_TEST_PROVIDER_WARMUP").empty())return true;
  auto pipe=keymap::env(L"DDSKK_PIPE_NAME");
  if(pipe.empty() || keymap::env(L"NATIVEIME_REGISTRY_KEY").empty())return false;
  HANDLE handle=CreateFileW(pipe.c_str(),GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_EXISTING,0,nullptr);
  if(handle==INVALID_HANDLE_VALUE)return false;
  auto transact=[&](const char* command){
    DWORD written=0,got=0;std::vector<char> response(1024*1024);
    if(!WriteFile(handle,command,static_cast<DWORD>(strlen(command)),&written,nullptr) || written!=strlen(command))return false;
    if(!ReadFile(handle,response.data(),static_cast<DWORD>(response.size()),&got,nullptr))return false;
    return std::string(response.data(),got).starts_with("STATE ");
  };
  // A private throwaway reading warms conversion and registration before
  // the timed script. No fixture candidate or tested buffer is preloaded.
  bool ok=transact("SESSION input-rules-warm CONTROL CONVERT-KEYS 65,105\n");
  DWORD done=0;const char close[]="SESSION input-rules-warm CLOSE\n";
  char response[128]{};
  ok=ok && WriteFile(handle,close,sizeof(close)-1,&done,nullptr) &&
     ReadFile(handle,response,sizeof(response),&done,nullptr);
  CloseHandle(handle);
  std::printf("PROVIDER_WARMUP private=1 success=%d\n",ok);return ok;
}
void InputApplicationKey(const KeyEvent& key) {
  if (!inputApplicationStore || key.ctrl) return;
  if (key.vk == VK_BACK) { inputApplicationStore->ApplicationEdit(L"",true); return; }
  BYTE state[256]{};GetKeyboardState(state);wchar_t output[8]{};
  int count=ToUnicodeEx(key.vk,MapVirtualKeyW(key.vk,MAPVK_VK_TO_VSC),state,output,8,0,GetKeyboardLayout(0));
  if(count>0 && output[0]>=32)inputApplicationStore->ApplicationEdit(std::wstring(output,count),false);
}
bool InputRulesKey(const std::wstring& token, KeyEvent* out) {
  wchar_t ch = 0;
  if (token == L"PAREN") ch = L'(';
  if (token == L"BRACKET") ch = L'[';
  if (token == L"CURLY") ch = L'{';
  if (token == L"PERIOD") ch = L'.';
  if (!ch) return false;
  SHORT mapped = VkKeyScanExW(ch, GetKeyboardLayout(0));
  if (mapped == -1 || ((mapped >> 8) & ~1)) return false;
  *out = KeyEvent{static_cast<UINT>(mapped & 255), ((mapped >> 8) & 1) != 0, false};
  return true;
}
struct InputResident {
  PROCESS_INFORMATION process{};
  ~InputResident() { Stop(); }
  void Stop() {
    if (!process.hProcess) return;
    struct Find { DWORD pid; HWND window; } find{process.dwProcessId,nullptr};
    EnumWindows([](HWND w,LPARAM p)->BOOL {
      auto f=reinterpret_cast<Find*>(p); DWORD pid=0; GetWindowThreadProcessId(w,&pid);
      wchar_t cls[128]{};GetClassNameW(w,cls,128);
      if(pid==f->pid && std::wstring(cls)==L"NelispImeKeymapResident"){f->window=w;return FALSE;}return TRUE;
    },reinterpret_cast<LPARAM>(&find));
    if(find.window)PostMessageW(find.window,WM_APP+1,0,0);
    if(WaitForSingleObject(process.hProcess,3000)!=WAIT_OBJECT_0){TerminateProcess(process.hProcess,1);WaitForSingleObject(process.hProcess,3000);}
    CloseHandle(process.hProcess);CloseHandle(process.hThread);
    process = {};
  }
};
bool InputRulesAction(const std::wstring& token) {
  static InputResident resident;
  if (token == L"IRSTOP") {
    resident.Stop();
    std::printf("INPUT_WATCH stopped=1\n");return true;
  }
  if(token==L"APPCLEAR") { inputApplicationStore->ApplicationClear(); return true; }
  if (token == L"IRWATCH") {
    auto executable=keymap::env(L"NELISP_TEST_KEYMAP_EXE");
    if(executable.empty() || keymap::env(L"NATIVEIME_REGISTRY_KEY").empty() ||
       keymap::env(L"DDSKK_PIPE_NAME").empty() || keymap::env(L"NELISP_IME_INPUT_RULES").empty()) std::exit(2);
    auto path=keymap::inputRulesPath()+L".keymap";
    if(!keymap::writeFileAtomic(path,L"enabled = no\n"))std::exit(2);
    std::wstring command=L"\""+executable+L"\" --no-hook --instance IR1-"+
      std::to_wstring(GetCurrentProcessId())+L" --config-file \""+path+L"\"";
    STARTUPINFOW startup{};startup.cb=sizeof(startup);startup.dwFlags=STARTF_USESHOWWINDOW;startup.wShowWindow=SW_HIDE;
    if(!CreateProcessW(nullptr,command.data(),nullptr,nullptr,FALSE,CREATE_NO_WINDOW,nullptr,nullptr,&startup,&resident.process))std::exit(2);
    std::printf("INPUT_WATCH started=%lu hooks=0 SendInput=0\n",resident.process.dwProcessId);
    return true;
  }
  if (token==L"IRZEN" || token==L"IRHALF" || token==L"IRCUSTOM" || token==L"IROFF") {
    if(keymap::env(L"NELISP_IME_INPUT_RULES").empty())std::exit(2);
    auto path=keymap::inputRulesPath();std::wstring source;DWORD error=0;
    if(!keymap::readFile(path,source,error))std::exit(2);
    auto doc=keymap::InputDocument::Parse(source);
    if(token==L"IRZEN" || token==L"IRHALF")doc.Set(L"",L"width",{token==L"IRZEN"?L"zenkaku":L"hankaku"});
    if(token==L"IRCUSTOM")doc.Set(L"symbols-zenkaku",L".",{L"EDIT "});
    if(token==L"IROFF")doc.Set(L"",L"auto-pair",{L"no"});
    if(!keymap::writeFileAtomic(path,doc.source))std::exit(2);
    std::printf("INPUT_FILE edited=%s\n",Utf8FromWide(token).c_str());return true;
  }
  if(token==L"IRRELOAD") {
    if(keymap::env(L"DDSKK_PIPE_NAME").empty() || !keymap::reloadInputEngine())std::exit(2);
    std::printf("INPUT_RELOAD OK RELOADING\n");return true;
  }
  return false;
}
