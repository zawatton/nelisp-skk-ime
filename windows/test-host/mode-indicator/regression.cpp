#include <windows.h>
#include <msctf.h>
#include <new>
#include <string>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <atomic>
namespace ddskk { struct EngineState { std::wstring mode; }; }
struct TestRange {
  HRESULT Collapse(TfEditCookie, TfAnchor) { return S_OK; }
  void Release() {}
};
struct TestSelection { TestRange* range; };
struct TestView {
  bool succeeds=false;
  HRESULT GetTextExt(TfEditCookie, TestRange*, RECT* out, BOOL*) {
    if (!succeeds) return E_FAIL;
    *out={10,20,10,25}; return S_OK;
  }
  void Release() {}
};
struct TestContext {
  bool text_ext_succeeds=false;
  TestRange range; TestView view;
  HRESULT GetActiveView(TestView** out) {
    view.succeeds=text_ext_succeeds; *out=&view; return S_OK;
  }
  HRESULT GetSelection(TfEditCookie, ULONG, ULONG, TestSelection* out, ULONG* fetched) {
    *fetched=1; out->range=&range; return S_OK;
  }
  HRESULT RequestEditSession(TfClientId, ITfEditSession* session, DWORD, HRESULT* result) {
    *result=session->DoEditSession(1); return S_OK;
  }
};
#define ITfContext TestContext
#define TF_SELECTION TestSelection
#define ITfRange TestRange
#define ITfContextView TestView
constexpr UINT kModeIndicatorMessage = WM_APP+1, kInlineMessage = WM_APP+2;
int cursor_calls = 0;
BOOL FakeCursor(POINT* point) { ++cursor_calls; *point = {777,888}; return TRUE; }
#define GetCursorPos FakeCursor
GUITHREADINFO fake_gui{};
bool gui_valid = false;
BOOL FakeGui(DWORD, GUITHREADINFO* info) { if (!gui_valid) return FALSE; *info = fake_gui; return TRUE; }
BOOL FakeScreen(HWND, POINT* point) { point->x += 100; point->y += 200; return TRUE; }
#define GetGUIThreadInfo FakeGui
#define ClientToScreen FakeScreen
#include "../../src/mode_indicator.h"
bool other_executable = false;
DWORD FakeModuleName(HMODULE module, LPWSTR buffer, DWORD size) {
  if (other_executable && module == nullptr) { wcscpy_s(buffer,size,L"other.exe"); return 9; }
  return GetModuleFileNameW(module,buffer,size);
}
#define GetModuleFileNameW FakeModuleName
// Compile the actual accessor against controlled connection state.
struct InlinePreedit {
  std::mutex mutex_; std::atomic<uint64_t> epoch_{0};
  bool caret_valid_=false; RECT caret_{4,5,4,6};
  bool LastCaret(RECT*);
};
#include "LastCaret.inc"
std::wstring registry;
std::wstring NativeImeRegistryKey() { return registry; }
long process_publishers = 0;
struct Channel {
  bool valid = false; RECT rect{30,40,30,50};
  bool LastCaret(RECT* out) { if (!valid) return false; *out = rect; return true; }
  void Start(HWND, UINT) {}
};
struct Popup { int shows=0, hides=0; void Show(const std::wstring&, POINT) { ++shows; } void Hide() { ++hides; } };
struct Button { int updates=0; void NotifyUpdate(DWORD) { ++updates; } };
struct TextService {
  void MaybeShowModeIndicator(ITfContext*, const ddskk::EngineState*);
  void FlushModeIndicator(); void LoadApplicationSettings();
  TfClientId client_id_=1;
  void CaptureCaretRect(TfEditCookie, TestContext*, TestRange*);
  void PublishCaretRect(const RECT&) {}
  ITfContext* active_context_=nullptr;
  void QueuePublishedState(const ddskk::EngineState*) {} void RemovePublishedState() {}
  std::wstring CurrentModeLabel() { return L"test"; }
  std::wstring last_engine_mode_, last_mode_label_, application_open_mode_;
  RECT last_caret_rect_{10,20,10,25}; bool last_caret_valid_=false;
  POINT mode_indicator_anchor_{}; bool mode_indicator_anchor_valid_=false;
  bool indicator_update_queued_=false, mode_indicator_enabled_=true;
  int application_mode_indicator_=-1;
  HWND provider_window_=nullptr; void* thread_manager_=this;
  Channel inline_channel_; Popup mode_indicator_; Button button;
  Button* input_mode_button_=&button;
  bool inline_enabled_=false, publish_state_=false, publication_registered_=false, publication_active_=false;
  struct { void (*notify_mode)(void*)=nullptr; void (*publisher_delta)(void*, int)=nullptr; void* owner=nullptr; } shim_;
};
#include "CaptureCaretRect.inc"
#include "MaybeShowModeIndicator.inc"
#include "FlushModeIndicator.inc"
#include "LoadApplicationSettings.inc"
int assertions = 0;
void require(bool ok, const char* label) { ++assertions; if (!ok) { std::printf("FAIL %s cursor_calls=%d\n",label,cursor_calls); std::exit(1); } }
int main() {
  // Failed GetTextExt leaves last_caret_valid_ false; no listener/system caret.
  TextService service;
  ITfContext failed_context;
  service.CaptureCaretRect(1, &failed_context, &failed_context.range);
  service.MaybeShowModeIndicator(&failed_context,nullptr);
  service.FlushModeIndicator();
  std::printf("no caret: anchor=%ld,%ld popup=%d cursor_calls=%d\n",service.mode_indicator_anchor_.x,service.mode_indicator_anchor_.y,service.mode_indicator_.shows,cursor_calls);
  require(service.mode_indicator_.shows==0 && cursor_calls==0,"no caret must suppress popup");
  require(service.button.updates==1,"icon still updates without caret");
  service.last_mode_label_.clear(); service.inline_channel_.valid=true;
  service.MaybeShowModeIndicator(nullptr,nullptr); service.FlushModeIndicator();
  require(service.mode_indicator_anchor_.x==30 && service.mode_indicator_anchor_.y==50 && service.mode_indicator_.shows==1,"inline caret outside episode");
  service.last_mode_label_.clear(); service.last_caret_valid_=true; ITfContext context; context.text_ext_succeeds=true;
  service.MaybeShowModeIndicator(&context,nullptr); service.FlushModeIndicator();
  require(service.mode_indicator_anchor_.x==10 && service.mode_indicator_anchor_.y==25,"TSF wins over inline");
  service.last_mode_label_.clear(); context.text_ext_succeeds=false;
  service.last_caret_valid_=true; service.last_caret_rect_={900,900,900,901};
  service.inline_channel_.rect={35,45,35,55};
  service.MaybeShowModeIndicator(&context,nullptr); service.FlushModeIndicator();
  require(service.mode_indicator_anchor_.x==35 && service.mode_indicator_anchor_.y==55,"stale inline cache must not outrank live listener");
  service.last_mode_label_.clear(); context.text_ext_succeeds=true;
  service.active_context_=&context;
  service.MaybeShowModeIndicator(nullptr,nullptr); service.FlushModeIndicator();
  require(service.mode_indicator_anchor_.x==10 && service.mode_indicator_anchor_.y==25,"active TSF caret for langbar mode change");
  service.active_context_=nullptr;
  fake_gui.hwndFocus=fake_gui.hwndCaret=reinterpret_cast<HWND>(1);
  fake_gui.rcCaret={60,70,60,80}; gui_valid=true;
  service.last_mode_label_.clear(); service.inline_channel_.valid=false; service.last_caret_valid_=false; context.text_ext_succeeds=false;
  service.MaybeShowModeIndicator(&context,nullptr); service.FlushModeIndicator();
  require(service.mode_indicator_anchor_.x==160 && service.mode_indicator_anchor_.y==280,"GUI-thread caret mapped to screen");
  RECT rect{}; fake_gui.hwndFocus=nullptr;
  require(!FocusedSystemCaret(&rect),"no focused window");
  fake_gui.hwndFocus=reinterpret_cast<HWND>(2);
  require(!FocusedSystemCaret(&rect),"caret must belong to focus");
  int calls=0; POINT anchor{};
  auto first=[&](RECT* out){++calls; *out={1,2,3,4}; return true;};
  auto forbidden=[&](RECT*){require(false,"lower priority source queried"); return false;};
  require(ResolveModeIndicatorAnchor(first,forbidden,forbidden,&anchor) && calls==1 && anchor.y==4,"lazy priority");
  auto unavailable=[](RECT*){return false;};
  require(ResolveModeIndicatorAnchor(unavailable,first,forbidden,&anchor),"inline wins without querying system");
  gui_valid=false; service.last_mode_label_.clear();
  const int shown=service.mode_indicator_.shows, hidden=service.mode_indicator_.hides;
  service.MaybeShowModeIndicator(&context,nullptr); service.FlushModeIndicator();
  require(service.mode_indicator_.shows==shown && service.mode_indicator_.hides==hidden+1,"losing all caret sources hides prior popup");
  registry=L"Software\\NativeIME-MI1-test-"+std::to_wstring(GetCurrentProcessId());
  wchar_t exe[32768]{}; GetModuleFileNameW(nullptr,exe,_countof(exe));
  std::wstring name(exe); name=name.substr(name.find_last_of(L"\\/")+1); CharLowerBuffW(name.data(),static_cast<DWORD>(name.size()));
  const std::wstring path=registry+L"\\Apps\\"+name;
  HKEY key=nullptr;
  require(RegCreateKeyExW(HKEY_CURRENT_USER,path.c_str(),0,nullptr,0,KEY_ALL_ACCESS,nullptr,&key,nullptr)==ERROR_SUCCESS,"private app key");
  DWORD value=0; RegSetValueExW(key,L"ModeIndicator",0,REG_DWORD,reinterpret_cast<BYTE*>(&value),sizeof(value));
  service.LoadApplicationSettings(); service.mode_indicator_anchor_valid_=true;
  const int before=service.mode_indicator_.shows; service.FlushModeIndicator();
  require(service.mode_indicator_.shows==before && service.application_mode_indicator_==0,"per-app off suppresses popup");
  value=1; RegSetValueExW(key,L"ModeIndicator",0,REG_DWORD,reinterpret_cast<BYTE*>(&value),sizeof(value));
  service.LoadApplicationSettings(); service.mode_indicator_enabled_=false; service.FlushModeIndicator();
  require(service.mode_indicator_.shows==before+1,"per-app on overrides global off");
  RegDeleteValueW(key,L"ModeIndicator"); service.LoadApplicationSettings(); service.FlushModeIndicator();
  require(service.application_mode_indicator_==-1 && service.mode_indicator_.shows==before+1,"absent inherits global off");
  service.mode_indicator_enabled_=true; service.FlushModeIndicator();
  require(service.mode_indicator_.shows==before+2,"absent inherits global on");
  value=0; RegSetValueExW(key,L"ModeIndicator",0,REG_DWORD,reinterpret_cast<BYTE*>(&value),sizeof(value));
  other_executable=true; service.LoadApplicationSettings(); service.FlushModeIndicator();
  require(service.application_mode_indicator_==-1 && service.mode_indicator_.shows==before+3,"other executable settings remain independent");
  RegCloseKey(key); RegDeleteTreeW(HKEY_CURRENT_USER,registry.c_str());
  require(cursor_calls==0,"mouse never queried");
  InlinePreedit channel;
  require(!channel.LastCaret(&rect),"disconnected caret unavailable");
  channel.epoch_=1;
  require(!channel.LastCaret(&rect),"connected without caret unavailable");
  channel.caret_valid_=true;
  require(channel.LastCaret(&rect) && rect.bottom==6,"connected last caret available");
  channel.epoch_=0;
  require(!channel.LastCaret(&rect),"disconnect rejects cached caret");
  channel.epoch_=2; channel.caret_valid_=false;
  require(!channel.LastCaret(&rect),"new connection needs new caret");
  require(!channel.LastCaret(nullptr),"null output unavailable");
  std::printf("PASS mode indicator regression assertions=%d\n", assertions);
}
