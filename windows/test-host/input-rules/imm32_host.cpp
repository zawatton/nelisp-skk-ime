// SPDX-License-Identifier: GPL-3.0-or-later
// Reuse the private DLL loader and key sink driver, but provide a real
// legacy EDIT window instead of the test fixture's ITextStoreACP.
#define wmain StockTsfMain
#include "../tsf_host.cpp"
#undef wmain
#include <imm.h>

int wmain() {
  wchar_t key[1024]{},pipe[256]{};
  if(!GetEnvironmentVariableW(L"NATIVEIME_REGISTRY_KEY",key,1024) ||
     !GetEnvironmentVariableW(L"DDSKK_PIPE_NAME",pipe,256) ||
     !GetEnvironmentVariableW(L"DDSKK_HARNESS_DLL_PATH",nullptr,0))return 2;
  HRESULT hr=CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);if(FAILED(hr))return 3;
  ITfThreadMgr* manager=nullptr;ITfDocumentMgr* document=nullptr;ITfContext* context=nullptr;
  ITfTextInputProcessor* tip=nullptr;ITfKeyEventSink* sink=nullptr;TfClientId id=0;
  HWND parent=nullptr,edit=nullptr;bool activated=false,tipActive=false;int result=1;
  do {
    hr=CoCreateInstance(CLSID_TF_ThreadMgr,nullptr,CLSCTX_INPROC_SERVER,IID_ITfThreadMgr,reinterpret_cast<void**>(&manager));
    if(FAILED(hr))break;
    ITfThreadMgrEx* extended=nullptr;
    hr=manager->QueryInterface(IID_ITfThreadMgrEx,reinterpret_cast<void**>(&extended));if(FAILED(hr))break;
    hr=extended->ActivateEx(&id,TF_TMAE_NOACTIVATETIP);extended->Release();if(FAILED(hr))break;activated=true;
    parent=CreateHiddenWindow(GetModuleHandleW(nullptr));
    edit=CreateWindowExW(0,L"EDIT",L"",WS_CHILD|WS_VISIBLE|ES_MULTILINE,0,0,180,70,parent,nullptr,GetModuleHandleW(nullptr),nullptr);
    if(!edit){hr=HRESULT_FROM_WIN32(GetLastError());break;}
    ShowWindow(parent,SW_SHOWNOACTIVATE);SetFocus(edit);PumpMessages(500);
    HIMC imm=ImmGetContext(edit);
    std::printf("IMM32 himc=%d textstore=CUAS SendInput=0\n",imm!=nullptr);
    if(imm)ImmReleaseContext(edit,imm);
    hr=manager->GetFocus(&document);if(FAILED(hr)||!document){hr=E_NOINTERFACE;break;}
    hr=document->GetTop(&context);if(FAILED(hr)||!context){hr=E_NOINTERFACE;break;}
    tip=CreateTipFromDllPath();if(!tip){hr=E_FAIL;break;}
    auto proxy=new DirectThreadMgr(manager);hr=tip->Activate(proxy,id);proxy->Release();if(FAILED(hr))break;tipActive=true;
    hr=SetKeyboardOpen(manager,id,true);if(FAILED(hr))break;
    hr=tip->QueryInterface(IID_ITfKeyEventSink,reinterpret_cast<void**>(&sink));if(FAILED(hr))break;
    SHORT mapped=VkKeyScanExW(L'(',GetKeyboardLayout(0));
    if(mapped==-1){hr=E_FAIL;break;}
    SendScriptedKey(sink,nullptr,context,KeyEvent{static_cast<UINT>(mapped&255),((mapped>>8)&1)!=0,false},L"PAREN");
    PumpMessages(500);
    wchar_t text[128]{};GetWindowTextW(edit,text,128);DWORD start=0,end=0;SendMessageW(edit,EM_GETSEL,reinterpret_cast<WPARAM>(&start),reinterpret_cast<LPARAM>(&end));
    std::printf("IMM32 BUF=[%s] SEL=%lu,%lu\n",Utf8FromWide(text).c_str(),start,end);
    result=std::wstring(text)==L"()" && start==1 && end==1 ? 0 : 1;
  }while(false);
  PrintHr("IMM32_CUAS",hr);
  if(sink)sink->Release();if(tipActive)tip->Deactivate();if(tip)tip->Release();
  if(context)context->Release();if(document)document->Release();
  if(edit)DestroyWindow(edit);if(parent)DestroyWindow(parent);
  if(activated)manager->Deactivate();if(manager)manager->Release();CoUninitialize();
  std::printf("IMM32 pair caret: %s\n",result?"FAIL":"PASS");return result;
}
