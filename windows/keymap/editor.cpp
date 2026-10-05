// SPDX-License-Identifier: GPL-3.0-or-later
#include <windows.h>
#include "editor.h"
#include "rules.h"

#include <commctrl.h>
#include <shellapi.h>

#include <iostream>
#include <sstream>

#include "capture.h"
#include "win_io.h"
namespace keymap {
namespace {
enum Id {
  List = 100,
  Enabled,
  LayoutChoice,
  Source,
  Target,
  Exclusions,
  Save,
  Add,
  Delete,
  Inspect,
  Remap,
  Apply,
  Open,
  Details,
  Status,
  PassInjected,
  InputRules
};
constexpr UINT Captured = WM_APP + 10;
struct Editor {
  HWND window = nullptr;
  std::wstring path, lastText, registeredSource;
  Document doc;
  bool dirty = false, loading = false, self = false, targetCapture = false;
  HHOOK hook = nullptr;
  Capture capture;
  Chord source;
  Event sourceEvent;
};
Editor* active = nullptr;
void description(Editor& e);
std::wstring controlText(HWND w, int id) {
  HWND c = GetDlgItem(w, id);
  int n = GetWindowTextLengthW(c);
  std::wstring s(n + 1, 0);
  GetWindowTextW(c, s.data(), n + 1);
  s.resize(n);
  return s;
}
void text(HWND w, int id, const std::wstring& s) {
  SetDlgItemTextW(w, id, s.c_str());
}
HWND control(HWND w, const wchar_t* cls, const wchar_t* label, DWORD style,
             int x, int y, int width, int height, int id) {
  HWND c = CreateWindowW(cls, label, WS_CHILD | WS_VISIBLE | style, x, y, width,
                         height, w,
                         reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)),
                         GetModuleHandleW(nullptr), nullptr);
  SendMessageW(c, WM_SETFONT,
               reinterpret_cast<WPARAM>(GetStockObject(DEFAULT_GUI_FONT)),
               TRUE);
  return c;
}
void stopCapture(Editor& e) {
  RemovePropW(e.window, kCaptureProperty);
  if (e.hook) {
    UnhookWindowsHookEx(e.hook);
    e.hook = nullptr;
  }
  e.capture.active = false;
}
LRESULT CALLBACK captureHook(int code, WPARAM wp, LPARAM lp) {
  auto& e = *active;
  if (code != HC_ACTION)
    return e.self ? 0 : CallNextHookEx(e.hook, code, wp, lp);
  auto& k = *reinterpret_cast<KBDLLHOOKSTRUCT*>(lp);
  Event event{normalize({static_cast<uint16_t>(k.vkCode),
                         static_cast<uint16_t>(k.scanCode),
                         (k.flags & LLKHF_EXTENDED) != 0}),
              (k.flags & LLKHF_UP) != 0, (k.flags & LLKHF_INJECTED) != 0,
              k.dwExtraInfo, k.time};
  bool swallow = e.capture.feed(
      event, e.self || GetForegroundWindow() == e.window, GetTickCount());
  if (!e.capture.active) PostMessageW(e.window, Captured, 0, 0);
  return swallow ? 1 : e.self ? 0 : CallNextHookEx(e.hook, code, wp, lp);
}
void list(Editor& e) {
  HWND l = GetDlgItem(e.window, List);
  ListView_DeleteAllItems(l);
  int row = 0;
  for (auto& line : e.doc.lines)
    if (line.rule) {
      std::wstring section =
          line.section == L"keys" ? L"キー" : L"ショートカット";
      LVITEMW item{};
      item.mask = LVIF_TEXT | LVIF_PARAM;
      item.iItem = row;
      item.pszText = section.data();
      item.lParam = line.number;
      ListView_InsertItem(l, &item);
      auto source = line.source, target = line.target,
           number = std::to_wstring(line.number);
      ListView_SetItemText(l, row, 1, source.data());
      ListView_SetItemText(l, row, 2, target.data());
      ListView_SetItemText(l, row, 3, number.data());
      ++row;
    }
}
std::vector<std::wstring> lines(const std::wstring& text) {
  std::wistringstream in(text);
  std::wstring s;
  std::vector<std::wstring> out;
  while (std::getline(in, s)) {
    if (!s.empty() && s.back() == L'\r') s.pop_back();
    if (!s.empty()) out.push_back(s);
  }
  return out;
}
void status(Editor& e) {
  auto errors = readString(L"Errors");
  for (auto& c : errors)
    if (!c) c = L'\n';
  std::wstring s = L"状態: " + readString(L"Status") + L"   " + e.path;
  if (!errors.empty()) s += L"\r\n" + errors;
  for (auto& error : e.doc.snapshot.errors) s += L"\r\n" + error;
  text(e.window, Status, s);
}
void view(Editor& e) {
  e.loading = true;
  CheckDlgButton(e.window, Enabled,
                 e.doc.snapshot.enabled ? BST_CHECKED : BST_UNCHECKED);
  CheckDlgButton(e.window, PassInjected,
                 e.doc.snapshot.passInjected ? BST_CHECKED : BST_UNCHECKED);
  SendDlgItemMessageW(e.window, LayoutChoice, CB_SETCURSEL,
                      e.doc.snapshot.layout == Layout::US    ? 1
                      : e.doc.snapshot.layout == Layout::JIS ? 2
                                                             : 0,
                      0);
  std::wstring apps;
  for (auto& a : e.doc.snapshot.excludes) apps += a + L"\r\n";
  text(e.window, Exclusions, apps);
  list(e);
  status(e);
  e.loading = false;
  if (e.source.count && !e.capture.active) description(e);
}
bool load(Editor& e) {
  std::wstring content;
  DWORD error;
  if (!readFile(e.path, content, error)) return false;
  e.lastText = content;
  e.doc = Document::parse(content);
  e.dirty = false;
  view(e);
  return true;
}
bool save(Editor& e) {
  e.doc.setOption(L"pass-injected",
                  IsDlgButtonChecked(e.window, PassInjected) == BST_CHECKED
                      ? L"yes"
                      : L"no");
  e.doc.setOption(
      L"enabled",
      IsDlgButtonChecked(e.window, Enabled) == BST_CHECKED ? L"yes" : L"no");
  auto layout = SendDlgItemMessageW(e.window, LayoutChoice, CB_GETCURSEL, 0, 0);
  e.doc.setOption(L"layout", layout == 1   ? L"US"
                             : layout == 2 ? L"JIS"
                                           : L"os");
  e.doc.setExclusions(lines(controlText(e.window, Exclusions)));
  // Do not overwrite an external edit which arrived between timer ticks.
  std::wstring disk;
  DWORD error;
  if (!readFile(e.path, disk, error)) return false;
  if (disk != e.lastText) {
    if (e.self) return false;
    if (MessageBoxW(e.window,
                    L"外部で変更されました。現在の編集内容で上書きしますか？",
                    L"キー置き換え", MB_YESNO | MB_ICONQUESTION) != IDYES) {
      load(e);
      return false;
    }
  }
  if (!writeFileAtomic(e.path, e.doc.text())) return false;
  e.lastText = e.doc.text();
  e.dirty = false;
  view(e);
  return true;
}
void applyRule(Editor& e, bool immediate) {
  auto source = controlText(e.window, Source),
       target = controlText(e.window, Target);
  if (source == chordName(e.source) && !e.registeredSource.empty())
    source = e.registeredSource;
  if (source == chordName(e.source) && e.registeredSource.empty() &&
      e.source.count > 1) {
    auto logical = e.source;
    for (unsigned n = 0; n + 1 < logical.count; ++n) {
      if (auto rule =
              matchingRule(Event{logical.keys[n]}, Chord{}, e.doc.snapshot)) {
        if (rule->to.count == 1 && modifierVk(rule->to.keys[0]) >= 0xa0 &&
                modifierVk(rule->to.keys[0]) <= 0xa5 ||
            rule->to.count == 1 && (modifierVk(rule->to.keys[0]) == 0x5b ||
                                    modifierVk(rule->to.keys[0]) == 0x5c))
          logical.keys[n] = rule->to.keys[0];
      }
    }
    source = chordName(logical);
  }
  auto section = source.find(L'+') == source.npos ? L"keys" : L"shortcuts";
  auto checked = compile(true, Layout::Os, true,
                         section == std::wstring(L"keys")
                             ? std::vector<std::wstring>{source + L"=" + target}
                             : std::vector<std::wstring>{},
                         section == std::wstring(L"shortcuts")
                             ? std::vector<std::wstring>{source + L"=" + target}
                             : std::vector<std::wstring>{},
                         {});
  if (!checked.errors.empty()) {
    if (!e.self)
      MessageBoxW(e.window, checked.errors[0].c_str(),
                  L"ルールを追加できません", MB_OK | MB_ICONERROR);
    return;
  }
  e.doc.setRule(section, source, target);
  e.dirty = true;
  list(e);
  if (immediate && !save(e) && !e.self)
    MessageBoxW(e.window, L"ファイルを保存できませんでした。", L"キー置き換え",
                MB_OK | MB_ICONERROR);
}
std::wstring scancodeMap() {
  HKEY k;
  std::wstring out = L"Windows Scancode Map: ";
  if (RegOpenKeyExW(HKEY_LOCAL_MACHINE,
                    L"SYSTEM\\CurrentControlSet\\Control\\Keyboard Layout", 0,
                    KEY_QUERY_VALUE, &k) != ERROR_SUCCESS)
    return out + L"読み取り不可";
  DWORD size = 0, type = 0;
  RegQueryValueExW(k, L"Scancode Map", nullptr, &type, nullptr, &size);
  if (type == REG_BINARY && size >= 16 && size < 65536) {
    std::vector<BYTE> b(size);
    if (RegQueryValueExW(k, L"Scancode Map", nullptr, &type, b.data(), &size) ==
        ERROR_SUCCESS) {
      DWORD count = 0;
      memcpy(&count, b.data() + 8, 4);
      for (DWORD n = 0; n + 1 < count && 12 + 4 * n + 4 <= size; ++n) {
        WORD to = 0, from = 0;
        memcpy(&to, b.data() + 12 + 4 * n, 2);
        memcpy(&from, b.data() + 14 + 4 * n, 2);
        wchar_t value[64];
        swprintf_s(value, L"0x%04X → 0x%04X  ", from, to);
        out += value;
      }
    }
  } else
    out += L"なし";
  RegCloseKey(k);
  return out +
         L"\r\nフックはこの変換後のコードを表示します。物理キーは推測しません"
         L"。";
}
std::wstring characters(Key key, bool shift, HKL hkl) {
  BYTE state[256]{};
  if (shift) state[VK_SHIFT] = state[VK_LSHIFT] = 0x80;
  wchar_t buf[8]{};
  int n = ToUnicodeEx(key.vk, key.scan, state, buf, 8, 4, hkl);
  return n > 0 ? std::wstring(buf, n) : n < 0 ? L"デッドキー" : L"(なし)";
}
void description(Editor& e) {
  e.registeredSource.clear();
  if (auto rule = matchingRule(e.sourceEvent, e.source, e.doc.snapshot))
    if ((rule->from.count > 1) == (e.source.count > 1))
      for (auto& line : e.doc.lines)
        if (line.number == rule->line) e.registeredSource = line.source;
  auto info =
      inspect(e.sourceEvent, e.source, e.doc.snapshot, activeLayout(e.window));
  if (!supportedLayout(e.window))
    info.conversion = L"OSのまま (このレイアウトの文字変換は未対応)";
  HKL hkl = GetKeyboardLayout(GetWindowThreadProcessId(e.window, nullptr));
  auto key = e.sourceEvent.key;
  wchar_t vkName[128]{};
  GetKeyNameTextW(
      static_cast<LONG>((key.scan << 16) | (key.extended ? 1u << 24 : 0)),
      vkName, 128);
  info.plain = characters(key, false, hkl);
  info.shifted = characters(key, true, hkl);
  text(e.window, Details,
       L"キー: " + info.name + L"\r\nScan: " + info.scan + L"  VK: " + info.vk +
           L" " + vkName + L"\r\n文字: " + info.plain + L"  Shift: " +
           info.shifted + L"\r\n登録: " + info.registration +
           L"\r\nレイアウト: " + info.conversion + L"\r\n" + scancodeMap());
}
bool flushResidentBeforeCapture(Editor& e) {
  if (e.self) return true;
  struct Find {
    DWORD pid;
    HWND window;
  };
  Find find{runtimePid(), nullptr};
  if (!find.pid) return true;
  EnumWindows(
      [](HWND w, LPARAM data) -> BOOL {
        auto f = reinterpret_cast<Find*>(data);
        DWORD pid = 0;
        GetWindowThreadProcessId(w, &pid);
        wchar_t cls[128]{};
        GetClassNameW(w, cls, 128);
        if (pid == f->pid && wcscmp(cls, L"NelispImeKeymapResident") == 0) {
          f->window = w;
          return FALSE;
        }
        return TRUE;
      },
      reinterpret_cast<LPARAM>(&find));
  if (!find.window) return true;
  DWORD_PTR result = 0;
  return SendMessageTimeoutW(find.window, kCaptureReleaseMessage, 0,
                             reinterpret_cast<LPARAM>(e.window),
                             SMTO_ABORTIFHUNG, 200, &result) != 0 &&
         result == 1;
}
void begin(Editor& e, bool target) {
  if (!e.self && GetForegroundWindow() != e.window) return;
  stopCapture(e);
  e.targetCapture = target;
  e.capture.begin(GetTickCount());
  SetPropW(e.window, kCaptureProperty, reinterpret_cast<HANDLE>(1));
  if (!flushResidentBeforeCapture(e)) {
    stopCapture(e);
    text(e.window, Details,
         L"置き換えプロセスが応答しません。キー確認を開始できませんでした。");
    return;
  }
  if (!e.self) {
    if (GetForegroundWindow() != e.window || !e.capture.active) {
      stopCapture(e);
      return;
    }
    for (unsigned vk = 8; vk < 256; ++vk)
      e.capture.preexisting[vk] = (GetAsyncKeyState(vk) & 0x8000) != 0;
  }

  text(e.window, Details,
       target ? L"置き換え先のキーを押して離してください (Esc: 中止、10秒)。"
              : L"押しているキーを先に離し、キーまたはショートカットを押して離"
                L"してください (Esc: "
                L"中止、10秒)。\r\nCtrl+Alt+Del は確認できません。\r\nWindows "
                L"Scancode Map 適用後のキーを表示します (例: 物理 CapsLock が "
                L"LCtrl)。");
  if (!e.self) {
    e.hook = SetWindowsHookExW(WH_KEYBOARD_LL, captureHook,
                               GetModuleHandleW(nullptr), 0);
    if (!e.hook) {
      stopCapture(e);
      text(e.window, Details, L"キー確認フックを開始できませんでした。");
    }
  }
}
void selected(Editor& e) {
  HWND l = GetDlgItem(e.window, List);
  int row = ListView_GetNextItem(l, -1, LVNI_SELECTED);
  if (row < 0) return;
  wchar_t source[512]{}, target[512]{};
  ListView_GetItemText(l, row, 1, source, 512);
  ListView_GetItemText(l, row, 2, target, 512);
  text(e.window, Source, source);
  text(e.window, Target, target);
}
LRESULT CALLBACK editorProc(HWND w, UINT msg, WPARAM wp, LPARAM lp) {
  auto* e = reinterpret_cast<Editor*>(GetWindowLongPtrW(w, GWLP_USERDATA));
  if (msg == WM_NCCREATE) {
    e = static_cast<Editor*>(
        reinterpret_cast<CREATESTRUCTW*>(lp)->lpCreateParams);
    e->window = w;
    SetWindowLongPtrW(w, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(e));
  }
  if (!e) return DefWindowProcW(w, msg, wp, lp);
  if (msg == WM_CREATE) {
    control(w, L"BUTTON", L"入力規則", BS_PUSHBUTTON, 635, 550, 90, 28, InputRules);
    control(w, L"BUTTON", L"キー置き換えを有効にする", BS_AUTOCHECKBOX, 16, 12,
            240, 24, Enabled);
    auto combo = control(w, L"COMBOBOX", L"", CBS_DROPDOWNLIST, 270, 12, 145,
                         120, LayoutChoice);
    for (auto value : {L"OSのまま", L"US", L"JIS"})
      SendMessageW(combo, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(value));
    control(w, L"BUTTON", L"テキストファイルを開く", BS_PUSHBUTTON, 435, 10,
            190, 28, Open);
    control(w, L"BUTTON", L"保存", BS_PUSHBUTTON, 635, 10, 90, 28, Save);
    auto l =
        control(w, WC_LISTVIEWW, L"", LVS_REPORT | LVS_SINGLESEL | WS_BORDER,
                16, 50, 710, 175, List);
    ListView_SetExtendedListViewStyle(l,
                                      LVS_EX_FULLROWSELECT | LVS_EX_GRIDLINES);
    int col = 0;
    for (auto label : {L"種類", L"元のキー", L"置き換え先", L"行"}) {
      LVCOLUMNW c{};
      c.mask = LVCF_TEXT | LVCF_WIDTH;
      c.pszText = const_cast<wchar_t*>(label);
      c.cx = col == 3 ? 60 : col == 0 ? 110 : 260;
      ListView_InsertColumn(l, col++, &c);
    }
    control(w, L"STATIC", L"元のキー", 0, 16, 237, 100, 20, 0);
    control(w, L"EDIT", L"", WS_BORDER | ES_AUTOHSCROLL, 120, 232, 230, 26,
            Source);
    control(w, L"STATIC", L"置き換え先", 0, 360, 237, 90, 20, 0);
    auto target = control(w, L"COMBOBOX", L"", CBS_DROPDOWN | WS_VSCROLL, 455,
                          232, 270, 150, Target);
    for (auto action : {L"ime-toggle", L"ime-on", L"ime-off", L"none"})
      SendMessageW(target, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(action));
    control(w, L"BUTTON", L"追加 / 編集", BS_PUSHBUTTON, 16, 270, 125, 28, Add);
    control(w, L"BUTTON", L"削除", BS_PUSHBUTTON, 150, 270, 80, 28, Delete);
    control(w, L"BUTTON", L"キーを確認", BS_PUSHBUTTON, 240, 270, 125, 28,
            Inspect);
    control(w, L"BUTTON", L"このキーを置き換える", BS_PUSHBUTTON, 375, 270, 195,
            28, Remap);
    control(w, L"BUTTON", L"選択した置き換えを適用", BS_PUSHBUTTON, 580, 270,
            145, 28, Apply);
    control(w, L"STATIC", L"除外アプリ (1行1件)", 0, 16, 312, 180, 20, 0);
    control(w, L"EDIT", L"",
            WS_BORDER | ES_MULTILINE | ES_AUTOVSCROLL | WS_VSCROLL, 16, 336,
            215, 85, Exclusions);
    control(w, L"BUTTON", L"他の注入イベントを通す", BS_AUTOCHECKBOX, 16, 435,
            215, 28, PassInjected);
    control(w, L"EDIT",
            L"キーを確認してから、置き換え先を押すか、アクション / none "
            L"を選択できます。\r\nCtrl+Alt+Del は確認できません。",
            WS_BORDER | ES_MULTILINE | ES_READONLY | WS_VSCROLL, 240, 312, 485,
            160, Details);
    control(w, L"EDIT", L"",
            WS_BORDER | ES_MULTILINE | ES_READONLY | WS_VSCROLL, 16, 487, 710,
            100, Status);
    if (!e->self) SetTimer(w, 1, 300, nullptr);
    return 0;
  }
  if (msg == WM_NOTIFY) {
    auto* n = reinterpret_cast<NMHDR*>(lp);
    if (n->idFrom == List && n->code == LVN_ITEMCHANGED) selected(*e);
    return 0;
  }
  if (msg == WM_COMMAND) {
    int id = LOWORD(wp), notify = HIWORD(wp);
    if (!e->loading &&
        ((id == Enabled || id == PassInjected) && notify == BN_CLICKED ||
         id == LayoutChoice && notify == CBN_SELCHANGE ||
         id == Exclusions && notify == EN_CHANGE))
      e->dirty = true;
    if (notify == BN_CLICKED) {
      if (id == Save) {
        if (!save(*e) && !e->self)
          MessageBoxW(w, L"ファイルを保存できませんでした。", L"キー置き換え",
                      MB_OK | MB_ICONERROR);
      }
      if (id == Add) applyRule(*e, false);
      if (id == Apply) applyRule(*e, true);
      if (id == Delete) {
        auto source = controlText(w, Source);
        if (source == chordName(e->source) && !e->registeredSource.empty())
          source = e->registeredSource;
        e->doc.removeRule(
            source.find(L'+') == source.npos ? L"keys" : L"shortcuts", source);
        e->dirty = true;
        list(*e);
      }
      if (id == Inspect) begin(*e, false);
      if (id == Remap) begin(*e, true);
      if (id == InputRules && !e->self) rulesEditor(false, w);
      if (id == Open && !e->self)
        ShellExecuteW(w, L"open", e->path.c_str(), nullptr, nullptr,
                      SW_SHOWNORMAL);
    }
    return 0;
  }
  if (msg == Captured) {
    stopCapture(*e);
    if (e->capture.complete) {
      if (e->targetCapture) {
        text(w, Target, chordName(e->capture.chord));
        applyRule(*e, true);
      } else {
        e->source = e->capture.chord;
        e->sourceEvent = e->capture.last;
        text(w, Source, chordName(e->source));
        description(*e);
      }
    } else
      text(w, Details, L"キー確認を中止しました。");
    return 0;
  }
  if (msg == WM_ACTIVATE && LOWORD(wp) == WA_INACTIVE) {
    stopCapture(*e);
    return 0;
  }
  if (msg == WM_TIMER) {
    if (e->capture.active && GetTickCount() - e->capture.started >= 10000) {
      stopCapture(*e);
      text(w, Details, L"キー確認は時間切れです。");
    }
    std::wstring content;
    DWORD error;
    if (readFile(e->path, content, error) && content != e->lastText) {
      if (!e->dirty || e->self ||
          MessageBoxW(
              w,
              L"外部で変更されました。未保存の編集を破棄して読み直しますか？",
              L"キー置き換え", MB_YESNO | MB_ICONQUESTION) == IDYES)
        load(*e);
      else
        e->lastText = content;
    }
    status(*e);
    return 0;
  }
  if (msg == WM_CLOSE) {
    if (e->dirty && !e->self &&
        MessageBoxW(w, L"未保存の編集を破棄して閉じますか？", L"キー置き換え",
                    MB_YESNO | MB_ICONQUESTION) != IDYES)
      return 0;
    DestroyWindow(w);
    return 0;
  }
  if (msg == WM_DESTROY) {
    stopCapture(*e);
    PostQuitMessage(0);
    return 0;
  }
  return DefWindowProcW(w, msg, wp, lp);
}
int uiTest(Editor& e) {
  unsigned checks = 0;
  bool ok = true;
  auto check = [&](bool v) {
    ++checks;
    ok = ok && v;
    if (!v) std::cout << "UI check failed " << checks << "\n";
  };
  check(load(e));
  auto original = e.lastText;
  check(!IsWindowVisible(e.window));
  text(e.window, Source, L"A");
  text(e.window, Target, L"B");
  SendMessageW(e.window, WM_COMMAND, MAKEWPARAM(Add, BN_CLICKED), 0);
  check(save(e));
  check(load(e));
  check(e.doc.snapshot.keys.size() == 2);
  text(e.window, Target, L"C");
  SendMessageW(e.window, WM_COMMAND, MAKEWPARAM(Apply, BN_CLICKED), 0);
  check(load(e));
  check(e.doc.snapshot.keys.back().to.keys[0].vk == 'C');
  SendMessageW(e.window, WM_COMMAND, MAKEWPARAM(Delete, BN_CLICKED), 0);
  check(save(e));
  check(load(e));
  check(e.doc.snapshot.keys.size() == 1);
  check(e.lastText.find(L"# fixture comment") != e.lastText.npos);
  check(e.lastText.find(L"unknown = keep") != e.lastText.npos);
  check(writeFileAtomic(e.path, e.lastText + L"\n[keys]\nB = C\n"));
  SendMessageW(e.window, WM_TIMER, 1, 0);
  check(e.doc.snapshot.keys.size() == 2);
  // The real inspector hook procedure is called in-process, never installed.
  begin(e, false);
  auto call = [&](unsigned vk, unsigned scan, bool up) {
    KBDLLHOOKSTRUCT k{};
    k.vkCode = vk;
    k.scanCode = scan;
    k.flags = up ? LLKHF_UP : 0;
    return captureHook(HC_ACTION, up ? WM_KEYUP : WM_KEYDOWN,
                       reinterpret_cast<LPARAM>(&k));
  };
  check(call(VK_RSHIFT, 0x36, true) == 0);
  check(call(VK_LCONTROL, 0x1d, false) == 1);
  check(call('A', 0x1e, false) == 1);
  check(call('A', 0x1e, true) == 1);
  check(call(VK_LCONTROL, 0x1d, true) == 1);
  SendMessageW(e.window, Captured, 0, 0);
  check(controlText(e.window, Source) == L"LCtrl+A");
  begin(e, true);
  check(call('D', 0x20, false) == 1);
  check(call('D', 0x20, true) == 1);
  SendMessageW(e.window, Captured, 0, 0);
  check(e.doc.snapshot.shortcuts.back().to.keys[0].vk == 'D');
  begin(e, false);
  check(call(VK_LCONTROL, 0x1d, false) == 1);
  check(call(VK_SPACE, 0x39, false) == 1);
  check(call(VK_SPACE, 0x39, true) == 1);
  check(call(VK_LCONTROL, 0x1d, true) == 1);
  SendMessageW(e.window, Captured, 0, 0);
  text(e.window, Target, L"none");
  SendMessageW(e.window, WM_COMMAND, MAKEWPARAM(Apply, BN_CLICKED), 0);
  check(load(e));
  auto generic = matchingRule(e.sourceEvent, e.source, e.doc.snapshot);
  check(generic && generic->to.count == 0 &&
        e.doc.snapshot.shortcuts.size() == 3);
  SendMessageW(e.window, WM_COMMAND, MAKEWPARAM(Delete, BN_CLICKED), 0);
  check(save(e));
  check(load(e));
  check(e.doc.snapshot.shortcuts.size() == 2);
  begin(e, false);
  check(call(VK_ESCAPE, 1, false) == 1);
  check(e.capture.cancelled);
  stopCapture(e);
  HWND l = GetDlgItem(e.window, List);
  std::cout << "UI list rows=" << ListView_GetItemCount(l) << "\n";
  for (int row = 0; row < ListView_GetItemCount(l); ++row) {
    wchar_t a[256], b[256];
    ListView_GetItemText(l, row, 1, a, 256);
    ListView_GetItemText(l, row, 2, b, 256);
    std::cout << utf8(a) << "=" << utf8(b) << "\n";
  }
  check(e.hook == nullptr);
  check(writeFileAtomic(e.path, original));
  std::cout << "editor hidden self-test: " << (ok ? "PASS" : "FAIL")
            << " checks=" << checks << " hooks=0 SendInput=0\n";
  return ok ? 0 : 1;
}
}  // namespace
int editor(bool selfTest) {
  if (selfTest && (env(L"NELISP_IME_KEYMAP_FILE").empty() ||
                   env(L"NATIVEIME_REGISTRY_KEY").empty()))
    return 2;
  INITCOMMONCONTROLSEX icc{sizeof(icc), ICC_LISTVIEW_CLASSES};
  InitCommonControlsEx(&icc);
  Editor e;
  e.self = selfTest;
  e.path = configPath();
  active = &e;
  if (e.path.empty()) return 3;
  if (GetFileAttributesW(e.path.c_str()) == INVALID_FILE_ATTRIBUTES &&
      !selfTest && !writeFileAtomic(e.path, templateText()))
    return 4;
  WNDCLASSW cls{};
  cls.hInstance = GetModuleHandleW(nullptr);
  cls.lpfnWndProc = editorProc;
  cls.lpszClassName = L"NelispImeKeymapEditor";
  cls.hCursor = LoadCursorW(nullptr, IDC_ARROW);
  cls.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
  RegisterClassW(&cls);
  auto w = CreateWindowW(
      cls.lpszClassName, L"キー置き換え / キー確認",
      WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX, CW_USEDEFAULT,
      CW_USEDEFAULT, 760, 640, nullptr, nullptr, cls.hInstance, &e);
  if (!w) return 5;
  if (selfTest) {
    int code = uiTest(e);
    DestroyWindow(w);
    active = nullptr;
    return code;
  }
  load(e);
  ShowWindow(w, SW_SHOW);
  UpdateWindow(w);
  MSG msg{};
  while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
    TranslateMessage(&msg);
    DispatchMessageW(&msg);
  }
  active = nullptr;
  return 0;
}
}  // namespace keymap
