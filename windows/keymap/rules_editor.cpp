// SPDX-License-Identifier: GPL-3.0-or-later
#include "rules.h"
#include "win_io.h"
#include <commctrl.h>
#include <shellapi.h>
#include <iostream>

namespace keymap {
namespace {
enum { Rows=201, Width, Pair, Key, Value, Close, Apply, SaveRules, OpenRules, RuleStatus, ReloadRules, TableChoice, NewRule };
struct RulesEditor {
  HWND window = nullptr;
  InputDocument doc;
  std::wstring path, last;
  bool self = false, loading = false, dirty = false;
  int selected = -1;
};
HWND add(HWND w, const wchar_t* cls, const wchar_t* label, DWORD style,
         int x, int y, int width, int height, int id) {
  HWND c = CreateWindowW(cls, label, WS_VISIBLE | WS_CHILD | style, x,y,width,height,
      w, reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), GetModuleHandleW(nullptr), nullptr);
  SendMessageW(c, WM_SETFONT, reinterpret_cast<WPARAM>(GetStockObject(DEFAULT_GUI_FONT)), TRUE);
  return c;
}
std::wstring get(HWND w, int id) {
  HWND c = GetDlgItem(w,id); int n = GetWindowTextLengthW(c);
  std::wstring s(n+1,0); GetWindowTextW(c,s.data(),n+1); s.resize(n); return s;
}
void status(RulesEditor& e, const std::wstring& message = L"") {
  std::wstring s = e.path + L"\r\n" + message;
  for (const auto& error : e.doc.errors) s += L"\r\n" + error;
  SetDlgItemTextW(e.window,RuleStatus,s.c_str());
}
void render(RulesEditor& e) {
  e.loading = true;
  SendDlgItemMessageW(e.window,Width,CB_SETCURSEL,e.doc.width == L"hankaku" ? 0 : 1,0);
  CheckDlgButton(e.window,Pair,e.doc.autoPair ? BST_CHECKED : BST_UNCHECKED);
  HWND list = GetDlgItem(e.window,Rows); ListView_DeleteAllItems(list);
  int index = 0;
  for (const auto& row : e.doc.rows) {
    std::wstring label = row.section == L"pairs" ? L"共通の括弧" :
      std::wstring(row.section.starts_with(L"symbols") ? L"記号・" : L"括弧・") +
      std::wstring(row.section.ends_with(L"hankaku") ? L"半角" : L"全角");
    LVITEMW item{}; item.mask=LVIF_TEXT; item.iItem=index; item.pszText=label.data();
    ListView_InsertItem(list,&item);
    ListView_SetItemText(list,index,1,const_cast<wchar_t*>(row.key.c_str()));
    ListView_SetItemText(list,index,2,const_cast<wchar_t*>(row.values[0].c_str()));
    if (row.values.size() == 2) ListView_SetItemText(list,index,3,const_cast<wchar_t*>(row.values[1].c_str()));
    ++index;
  }
  e.selected=-1; e.loading=false; status(e,e.dirty ? L"未保存" : L"読み込み済み（不正な行は無視されます）");
}
bool load(RulesEditor& e) {
  std::wstring s; DWORD error=0;
  if (!readFile(e.path,s,error)) { status(e,L"読み込みエラー " + std::to_wstring(error)); return false; }
  e.last=s; e.doc=InputDocument::Parse(s.empty() ? inputRulesTemplate() : s);
  e.dirty=false; render(e); return true;
}
bool save(RulesEditor& e) {
  std::wstring current; DWORD error=0;
  if (!readFile(e.path,current,error) || current != e.last) {
    status(e,L"外部で変更されました。再読み込みしてから編集してください。"); return false;
  }
  if (!writeFileAtomic(e.path,e.doc.source)) { status(e,L"保存できませんでした。"); return false; }
  e.last=e.doc.source; e.dirty=false;
  bool applied=e.self || reloadInputEngine();
  status(e,applied ? L"保存済み・エンジン再読み込みを要求しました。" :
                   L"保存済み。再読み込み要求は届きませんでした。常駐プロセスが再試行します。");
  return true;
}
LRESULT CALLBACK proc(HWND w,UINT msg,WPARAM wp,LPARAM lp) {
  auto e=reinterpret_cast<RulesEditor*>(GetWindowLongPtrW(w,GWLP_USERDATA));
  if (msg==WM_NCCREATE) {
    e=static_cast<RulesEditor*>(reinterpret_cast<CREATESTRUCTW*>(lp)->lpCreateParams);
    e->window=w; SetWindowLongPtrW(w,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(e));
  }
  if (!e) return DefWindowProcW(w,msg,wp,lp);
  if (msg==WM_CREATE) {
    add(w,L"STATIC",L"記号の幅",0,16,18,85,24,0);
    auto width=add(w,L"COMBOBOX",L"",CBS_DROPDOWNLIST,100,14,110,100,Width);
    for (auto label : {L"半角",L"全角"}) SendMessageW(width,CB_ADDSTRING,0,reinterpret_cast<LPARAM>(label));
    add(w,L"BUTTON",L"括弧を自動で閉じる",BS_AUTOCHECKBOX,230,14,200,28,Pair);
    add(w,L"BUTTON",L"保存",BS_PUSHBUTTON,450,14,85,28,SaveRules);
    add(w,L"BUTTON",L"再読み込み",BS_PUSHBUTTON,545,14,110,28,ReloadRules);
    auto list=add(w,WC_LISTVIEWW,L"",LVS_REPORT|LVS_SINGLESEL|WS_BORDER,16,55,710,280,Rows);
    ListView_SetExtendedListViewStyle(list,LVS_EX_FULLROWSELECT|LVS_EX_GRIDLINES);
    int col=0; for (auto label : {L"表",L"キー / 開く文字",L"出力 / 開く文字",L"閉じる文字"}) {
      LVCOLUMNW c{}; c.mask=LVCF_TEXT|LVCF_WIDTH; c.pszText=const_cast<wchar_t*>(label); c.cx=175;
      ListView_InsertColumn(list,col++,&c);
    }
    add(w,L"STATIC",L"キー",0,16,351,65,22,0);
    add(w,L"EDIT",L"",WS_BORDER|ES_AUTOHSCROLL,80,345,120,28,Key);
    add(w,L"STATIC",L"出力 / 開く",0,210,351,95,22,0);
    add(w,L"EDIT",L"",WS_BORDER|ES_AUTOHSCROLL,310,345,115,28,Value);
    add(w,L"STATIC",L"閉じる",0,435,351,60,22,0);
    add(w,L"EDIT",L"",WS_BORDER|ES_AUTOHSCROLL,495,345,110,28,Close);
    add(w,L"BUTTON",L"行を適用",BS_PUSHBUTTON,620,345,105,28,Apply);
    add(w,L"BUTTON",L"テキストファイルを開く",BS_PUSHBUTTON,16,385,205,28,OpenRules);
    auto tables=add(w,L"COMBOBOX",L"",CBS_DROPDOWNLIST,235,385,345,160,TableChoice);
    for(auto label : {L"記号・半角",L"記号・全角",L"括弧・半角",L"括弧・全角",L"共通の括弧"})
      SendMessageW(tables,CB_ADDSTRING,0,reinterpret_cast<LPARAM>(label));
    SendMessageW(tables,CB_SETCURSEL,0,0);
    add(w,L"BUTTON",L"新規の行",BS_PUSHBUTTON,600,385,125,28,NewRule);
    add(w,L"EDIT",L"",WS_BORDER|ES_MULTILINE|ES_READONLY|WS_VSCROLL,16,425,710,120,RuleStatus);
    SetTimer(w,1,250,nullptr); return 0;
  }
  if (msg==WM_NOTIFY && reinterpret_cast<NMHDR*>(lp)->idFrom==Rows &&
      reinterpret_cast<NMHDR*>(lp)->code==LVN_ITEMCHANGED && !e->loading) {
    int row=ListView_GetNextItem(GetDlgItem(w,Rows),-1,LVNI_SELECTED);
    if (row>=0 && static_cast<size_t>(row)<e->doc.rows.size()) {
      e->selected=row; auto& r=e->doc.rows[row];
      SetDlgItemTextW(w,Key,r.key.c_str()); SendDlgItemMessageW(w,Key,EM_SETREADONLY,TRUE,0);
      SetDlgItemTextW(w,Value,r.values[0].c_str());
      SetDlgItemTextW(w,Close,r.values.size()==2 ? r.values[1].c_str() : L"");
      EnableWindow(GetDlgItem(w,Close),r.values.size()==2);
      const wchar_t* sections[]={L"symbols-hankaku",L"symbols-zenkaku",L"pairs-hankaku",L"pairs-zenkaku",L"pairs"};
      for(int i=0;i<5;++i)if(r.section==sections[i])SendDlgItemMessageW(w,TableChoice,CB_SETCURSEL,i,0);
    }
    return 0;
  }
  if (msg==WM_COMMAND && !e->loading) {
    int id=LOWORD(wp);
    if (id==Width && HIWORD(wp)==CBN_SELCHANGE) {
      e->doc.Set(L"",L"width",{SendDlgItemMessageW(w,Width,CB_GETCURSEL,0,0)==0 ? L"hankaku" : L"zenkaku"});
      e->dirty=true; status(*e,L"未保存");
    }
    if (id==Pair && HIWORD(wp)==BN_CLICKED) {
      e->doc.Set(L"",L"auto-pair",{IsDlgButtonChecked(w,Pair)==BST_CHECKED ? L"yes" : L"no"});
      e->dirty=true; status(*e,L"未保存");
    }
    if (id==NewRule) {
      e->selected=-1;SendDlgItemMessageW(w,Key,EM_SETREADONLY,FALSE,0);
      SetDlgItemTextW(w,Key,L"");SetDlgItemTextW(w,Value,L"");SetDlgItemTextW(w,Close,L"");
      EnableWindow(GetDlgItem(w,Close),SendDlgItemMessageW(w,TableChoice,CB_GETCURSEL,0,0)>=2);
      SetFocus(GetDlgItem(w,Key));
    }
    if(id==TableChoice && HIWORD(wp)==CBN_SELCHANGE && e->selected<0)
      EnableWindow(GetDlgItem(w,Close),SendDlgItemMessageW(w,TableChoice,CB_GETCURSEL,0,0)>=2);
    if (id==Apply) {
      const wchar_t* sections[]={L"symbols-hankaku",L"symbols-zenkaku",L"pairs-hankaku",L"pairs-zenkaku",L"pairs"};
      int choice=static_cast<int>(SendDlgItemMessageW(w,TableChoice,CB_GETCURSEL,0,0));
      if(choice<0 || choice>=5)return 0;
      InputRow row=e->selected>=0 ? e->doc.rows[e->selected] : InputRow{sections[choice],get(w,Key),{}};
      if(row.key.empty()){status(*e,L"キーを入力してください。");return 0;}
      if(row.section.starts_with(L"symbols-"))for(auto ch:row.key)if(ch<32||ch>126){status(*e,L"記号のキーはASCII文字で指定してください。");return 0;}
      std::vector<std::wstring> values{get(w,Value)};
      if (!row.section.starts_with(L"symbols-")) values.push_back(get(w,Close));
      if (values.size()==2 && (values[0].empty() || values[1].empty())) { status(*e,L"括弧は空にできません。"); return 0; }
      e->doc.Set(row.section,row.key,values); e->dirty=true; render(*e);
    }
    if (id==SaveRules) save(*e);
    if (id==ReloadRules && (!e->dirty || e->self || MessageBoxW(w,L"未保存の編集を破棄しますか？",L"入力規則",MB_YESNO)==IDYES)) load(*e);
    if (id==OpenRules && !e->self) ShellExecuteW(w,L"open",e->path.c_str(),nullptr,nullptr,SW_SHOWNORMAL);
    return 0;
  }
  if (msg==WM_TIMER) {
    std::wstring s; DWORD error=0;
    if (readFile(e->path,s,error) && s!=e->last) {
      if (!e->dirty) load(*e); else status(*e,L"外部変更あり。保存前に再読み込みしてください。");
    }
    return 0;
  }
  if (msg==WM_CLOSE) {
    if (!e->dirty || e->self || MessageBoxW(w,L"未保存の編集を破棄して閉じますか？",L"入力規則",MB_YESNO)==IDYES) DestroyWindow(w);
    return 0;
  }
  return DefWindowProcW(w,msg,wp,lp);
}
int test(RulesEditor& e) {
  int checks=0, failed=0; auto check=[&](bool value){++checks; if(!value){++failed; std::cout<<"RULES failed check="<<checks<<"\n";}};
  check(!IsWindowVisible(e.window)); check(load(e)); check(e.doc.rows.size()==35);
  auto pipe=env(L"DDSKK_PIPE_NAME");SetEnvironmentVariableW(L"DDSKK_PIPE_NAME",nullptr);
  check(!reloadInputEngine());
  SetEnvironmentVariableW(L"DDSKK_PIPE_NAME",pipe.empty()?nullptr:pipe.c_str());
  auto original=e.last;
  SendDlgItemMessageW(e.window,Width,CB_SETCURSEL,1,0);
  SendMessageW(e.window,WM_COMMAND,MAKEWPARAM(Width,CBN_SELCHANGE),0);
  check(save(e)); check(load(e)); check(e.doc.width==L"zenkaku");
  int period=0;for(size_t i=0;i<e.doc.rows.size();++i)if(e.doc.rows[i].section==L"symbols-hankaku" && e.doc.rows[i].key==L".")period=static_cast<int>(i);
  ListView_SetItemState(GetDlgItem(e.window,Rows),period,LVIS_SELECTED,LVIS_SELECTED);
  SetDlgItemTextW(e.window,Value,L".  ");
  SendMessageW(e.window,WM_COMMAND,MAKEWPARAM(Apply,BN_CLICKED),0);
  check(save(e)); check(load(e));
  check(e.doc.source.find(L"# keep comment")!=e.doc.source.npos);
  check(e.doc.source.find(L"\".  \"")!=e.doc.source.npos);
  SendDlgItemMessageW(e.window,TableChoice,CB_SETCURSEL,0,0);
  SendMessageW(e.window,WM_COMMAND,MAKEWPARAM(NewRule,BN_CLICKED),0);
  SetDlgItemTextW(e.window,Key,L"#");SetDlgItemTextW(e.window,Value,L"hash # ");
  SendMessageW(e.window,WM_COMMAND,MAKEWPARAM(Apply,BN_CLICKED),0);
  check(e.doc.rows.size()==36);check(save(e));check(load(e));
  check(e.doc.source.find(L"\"#\" = \"hash # \"")!=e.doc.source.npos);
  CheckDlgButton(e.window,Pair,BST_UNCHECKED);
  SendMessageW(e.window,WM_COMMAND,MAKEWPARAM(Pair,BN_CLICKED),0);
  check(!e.doc.autoPair);check(save(e));check(load(e));check(!e.doc.autoPair);
  check(writeFileAtomic(e.path,L"width = hankaku\ninvalid\n"));
  SendMessageW(e.window,WM_TIMER,1,0); check(e.doc.width==L"hankaku"); check(e.doc.errors.size()==1);
  e.doc.Set(L"",L"auto-pair",{L"no"}); e.dirty=true;
  check(writeFileAtomic(e.path,L"width = zenkaku\n")); check(!save(e));
  check(load(e)); check(e.doc.width==L"zenkaku");
  check(writeFileAtomic(e.path,original));
  std::cout<<"rules hidden self-test: "<<(failed?"FAIL":"PASS")<<" checks="<<checks<<" failures="<<failed<<" hooks=0 SendInput=0\n";
  return failed ? 1 : 0;
}
}  // namespace
int rulesEditor(bool selfTest,HWND parent) {
  if (selfTest && (env(L"NELISP_IME_INPUT_RULES").empty() || env(L"NATIVEIME_REGISTRY_KEY").empty())) return 2;
  INITCOMMONCONTROLSEX icc{sizeof(icc),ICC_LISTVIEW_CLASSES}; InitCommonControlsEx(&icc);
  RulesEditor e; e.self=selfTest; e.path=inputRulesPath(); if(e.path.empty())return 3;
  WNDCLASSW cls{}; cls.hInstance=GetModuleHandleW(nullptr); cls.lpfnWndProc=proc;
  cls.lpszClassName=L"NelispImeInputRulesEditor"; cls.hCursor=LoadCursorW(nullptr,IDC_ARROW);
  cls.hbrBackground=reinterpret_cast<HBRUSH>(COLOR_WINDOW+1); RegisterClassW(&cls);
  HWND w=CreateWindowW(cls.lpszClassName,L"入力規則",WS_OVERLAPPED|WS_CAPTION|WS_SYSMENU|WS_MINIMIZEBOX,
    CW_USEDEFAULT,CW_USEDEFAULT,760,600,parent,nullptr,cls.hInstance,&e);
  if(!w)return 4;
  if(selfTest){int code=test(e);DestroyWindow(w);return code;}
  if(GetFileAttributesW(e.path.c_str())==INVALID_FILE_ATTRIBUTES && !writeFileAtomic(e.path,inputRulesTemplate())){DestroyWindow(w);return 5;}
  load(e); ShowWindow(w,SW_SHOW); MSG msg{};
  while(IsWindow(w) && GetMessageW(&msg,nullptr,0,0)>0){TranslateMessage(&msg);DispatchMessageW(&msg);}
  return 0;
}
}  // namespace keymap
