// SPDX-License-Identifier: GPL-3.0-or-later
#include "config.h"

#include <algorithm>
#include <cwctype>
#include <iomanip>
#include <sstream>
namespace keymap {
namespace {
std::wstring trim(const std::wstring& s) {
  auto a = s.find_first_not_of(L" \t\r");
  return a == s.npos ? L"" : s.substr(a, s.find_last_not_of(L" \t\r") - a + 1);
}
std::wstring lower(std::wstring s) {
  for (auto& c : s) c = std::towlower(c);
  return s;
}
std::wstring hex(unsigned v) {
  std::wostringstream o;
  o << L"0x" << std::uppercase << std::hex << std::setw(2) << std::setfill(L'0')
    << v;
  return o.str();
}
bool sameSource(const std::wstring& a, const std::wstring& b) {
  return lower(trim(a)) == lower(trim(b));
}
}  // namespace
Document Document::parse(const std::wstring& input) {
  Document d;
  bool enabled = false, pass = true;
  Layout layout = Layout::Os;
  std::wstring section;
  d.bom = input.starts_with(L"\ufeff");
  std::wistringstream stream(d.bom ? input.substr(1) : input);
  std::wstring raw;
  unsigned n = 0;
  while (std::getline(stream, raw)) {
    bool crlf = !raw.empty() && raw.back() == L'\r';
    if (crlf) raw.pop_back();
    Line l{raw, section, L"", L"", ++n, false};
    l.ending = stream.eof() ? L"" : crlf ? L"\r\n" : L"\n";
    if (n == 1 && !l.ending.empty()) d.newline = l.ending;
    auto content = trim(raw.substr(0, raw.find(L'#')));
    if (content.empty()) {
      d.lines.push_back(l);
      continue;
    }
    if (content.front() == L'[' && content.back() == L']') {
      section = lower(trim(content.substr(1, content.size() - 2)));
      l.section = section;
      d.lines.push_back(l);
      continue;
    }
    auto error = [&](std::wstring reason) {
      d.snapshot.errors.push_back(L"line " + std::to_wstring(n) + L": " +
                                  reason);
    };
    if (section == L"exclude") {
      if (content.find_first_of(L"\\/:*?") != content.npos)
        error(L"exclusion must be an executable name, not a path or wildcard");
      else
        d.snapshot.excludes.push_back(lower(content));
      d.lines.push_back(l);
      continue;
    }
    auto eq = content.find(L'=');
    if (eq == content.npos) {
      error(L"expected name = value");
      d.lines.push_back(l);
      continue;
    }
    l.source = trim(content.substr(0, eq));
    l.target = trim(content.substr(eq + 1));
    if (section == L"keys" || section == L"shortcuts") {
      auto s =
          compile(true, layout, pass,
                  section == L"keys" ? std::vector<std::wstring>{content}
                                     : std::vector<std::wstring>{},
                  section == L"shortcuts" ? std::vector<std::wstring>{content}
                                          : std::vector<std::wstring>{},
                  {});
      if (!s.errors.empty())
        error(s.errors[0]);
      else {
        auto& list =
            section == L"keys" ? d.snapshot.keys : d.snapshot.shortcuts;
        Rule r = section == L"keys" ? s.keys[0] : s.shortcuts[0];
        r.line = n;
        if (list.size() >= 256)
          error(L"maximum 256 rules per section");
        else if (std::any_of(list.begin(), list.end(), [&](auto& old) {
                   return old.from.keys == r.from.keys &&
                          old.from.count == r.from.count;
                 }))
          error(L"duplicate source");
        else {
          list.push_back(r);
          l.rule = true;
        }
      }
    } else if (section.empty()) {
      auto name = lower(l.source), value = lower(l.target);
      if (name == L"enabled" || name == L"pass-injected") {
        if (value != L"yes" && value != L"no")
          error(L"expected yes or no");
        else
          (name == L"enabled" ? enabled : pass) = value == L"yes";
      } else if (name == L"layout") {
        if (value == L"us")
          layout = Layout::US;
        else if (value == L"jis")
          layout = Layout::JIS;
        else if (value == L"os")
          layout = Layout::Os;
        else
          error(L"layout must be os, US or JIS");
      } else
        error(L"unknown option (preserved)");
    } else
      error(L"unknown section (preserved)");
    d.lines.push_back(l);
  }
  d.snapshot.enabled = enabled;
  d.snapshot.passInjected = pass;
  d.snapshot.layout = layout;
  return d;
}
std::wstring Document::text() const {
  std::wstring out = bom ? L"\ufeff" : L"";
  for (auto& l : lines) out += l.text + l.ending;
  return out;
}
void Document::setOption(const std::wstring& name, const std::wstring& value) {
  for (auto& l : lines)
    if (l.section.empty() && sameSource(l.source, name)) {
      if (lower(l.target) == lower(value)) return;
      auto hash = l.text.find(L'#');
      l.text = name + L" = " + value +
               (hash == l.text.npos ? L"" : L" " + l.text.substr(hash));
      *this = parse(text());
      return;
    }
  Line option{name + L" = " + value};
  option.ending = newline;
  lines.insert(lines.begin(), option);
  *this = parse(text());
}
void Document::setRule(const std::wstring& section, const std::wstring& source,
                       const std::wstring& target) {
  for (auto& l : lines)
    if (l.section == section && sameSource(l.source, source)) {
      if (l.target == target) return;
      auto hash = l.text.find(L'#');
      l.text = source + L" = " + target +
               (hash == l.text.npos ? L"" : L" " + l.text.substr(hash));
      *this = parse(text());
      return;
    }
  size_t at = lines.size();
  bool found = false;
  for (size_t i = 0; i < lines.size(); ++i) {
    if (lines[i].text == L"[" + section + L"]") {
      found = true;
      at = i + 1;
      while (at < lines.size() &&
             (lines[at].text.empty() || lines[at].text.front() != L'['))
        ++at;
      break;
    }
  }
  if (!lines.empty() && lines.back().ending.empty() && at == lines.size())
    lines.back().ending = newline;
  if (!found) {
    Line blank{L""}, header{L"[" + section + L"]"};
    blank.ending = header.ending = newline;
    lines.push_back(blank);
    lines.push_back(header);
    at = lines.size();
  }
  Line added{source + L" = " + target};
  added.ending = newline;
  lines.insert(lines.begin() + at, added);
  *this = parse(text());
}
void Document::removeRule(const std::wstring& section,
                          const std::wstring& source) {
  std::erase_if(lines, [&](auto& l) {
    if (l.section != section || !sameSource(l.source, source) ||
        l.source.empty())
      return false;
    auto hash = l.text.find(L'#');
    if (hash != l.text.npos) {
      l.text = l.text.substr(hash);
      return false;
    }
    return true;
  });
  *this = parse(text());
}
void Document::setExclusions(const std::vector<std::wstring>& apps) {
  // Retain untouched exclusion lines and all standalone/inline comments.
  std::vector<std::wstring> normalized;
  for (auto app : apps) {
    app = lower(trim(app));
    if (!app.empty() && std::find(normalized.begin(), normalized.end(), app) ==
                            normalized.end())
      normalized.push_back(app);
  }
  std::erase_if(lines, [&](auto& l) {
    if (l.section != L"exclude" || trim(l.text).starts_with(L"[") ||
        trim(l.text.substr(0, l.text.find(L'#'))).empty())
      return false;
    auto name = lower(trim(l.text.substr(0, l.text.find(L'#'))));
    if (std::find(normalized.begin(), normalized.end(), name) !=
        normalized.end())
      return false;
    auto hash = l.text.find(L'#');
    if (hash != l.text.npos) {
      l.text = l.text.substr(hash);
      return false;
    }
    return true;
  });
  auto current = parse(text()).snapshot.excludes;
  for (auto app : normalized)
    if (std::find(current.begin(), current.end(), lower(app)) ==
        current.end()) {
      size_t at = lines.size();
      bool found = false;
      for (size_t i = 0; i < lines.size(); ++i)
        if (lines[i].text == L"[exclude]") {
          at = i + 1;
          while (at < lines.size() && !trim(lines[at].text).starts_with(L"["))
            ++at;
          found = true;
          break;
        }
      if (!lines.empty() && lines.back().ending.empty() && at == lines.size())
        lines.back().ending = newline;
      if (!found) {
        Line header{L"[exclude]"};
        header.ending = newline;
        lines.push_back(header);
        at = lines.size();
      }
      Line added{app};
      added.ending = newline;
      lines.insert(lines.begin() + at, added);
    }
  *this = parse(text());
}
std::wstring keyName(Key k) {
  if (!k.vk)
    return L"sc:" + std::wstring(k.extended ? L"e0:" : L"") + hex(k.scan);
  const wchar_t* names[] = {L"LShift", L"RShift", L"LCtrl",
                            L"RCtrl",  L"LAlt",   L"RAlt"};
  if (k.vk >= 0xa0 && k.vk <= 0xa5) return names[k.vk - 0xa0];
  for (auto name :
       {L"Oem1",        L"OemPlus",   L"OemComma", L"OemMinus", L"OemPeriod",
        L"Oem2",        L"Oem3",      L"Oem4",     L"Oem5",     L"Oem6",
        L"Oem7",        L"Oem8",      L"Oem102",   L"NumLock",  L"ScrollLock",
        L"PrintScreen", L"Pause",     L"Apps",     L"Numpad0",  L"Numpad1",
        L"Numpad2",     L"Numpad3",   L"Numpad4",  L"Numpad5",  L"Numpad6",
        L"Numpad7",     L"Numpad8",   L"Numpad9",  L"Multiply", L"Add",
        L"Subtract",    L"Decimal",   L"Divide",   L"Convert",  L"NonConvert",
        L"Kana",        L"CapsLock",  L"Space",    L"Enter",    L"Tab",
        L"Escape",      L"Backspace", L"Delete",   L"Insert",   L"Home",
        L"End",         L"PageUp",    L"PageDown", L"Left",     L"Up",
        L"Right",       L"Down",      L"Kanji",    L"LWin",     L"RWin",
        L"Shift",       L"Ctrl",      L"Alt"})
    if (parseKey(name).vk == k.vk) return name;
  if (k.vk >= 0x70 && k.vk <= 0x87) return L"F" + std::to_wstring(k.vk - 0x6f);
  if (k.vk >= L'A' && k.vk <= L'Z' || k.vk >= L'0' && k.vk <= L'9')
    return std::wstring(1, static_cast<wchar_t>(k.vk));
  return L"vk:" + hex(k.vk);
}
std::wstring chordName(const Chord& c) {
  std::wstring out;
  for (unsigned i = 0; i < c.count; ++i) {
    if (i) out += L"+";
    out += keyName(c.keys[i]);
  }
  return out;
}
namespace {
Snapshot inspectionRules(const Snapshot& config) {
  auto rules = config;
  rules.enabled = true;
  rules.layout = Layout::Os;
  rules.passInjected = false;
  return rules;
}
State inspectionPrefix(const Chord& chord, const Snapshot& effective) {
  State state;
  for (unsigned n = 0; n + 1 < chord.count; ++n) {
    auto key = chord.keys[n];
    if (!key.vk) key.vk = static_cast<uint16_t>(modifierVk(key));
    decide(Event{key}, state, effective, {});
  }
  return state;
}
unsigned physicalIndex(Key key) {
  return key.scan ? (key.scan & 255) + (key.extended ? 256 : 0)
                  : 512 + (key.vk & 255);
}
}  // namespace
const Rule* matchingRule(const Event& input, const Chord& chord,
                         const Snapshot& config) {
  auto effective = inspectionRules(config);
  auto state = inspectionPrefix(chord, effective);
  auto event = input;
  event.up = false;
  event.injected = false;
  event.extra = 0;
  auto result = decide(event, state, effective, {});
  if (!result.swallow) return nullptr;
  const auto& binding = state.bindings[physicalIndex(event.key)];
  if (!binding.active) return nullptr;
  const auto& list = binding.shortcut ? config.shortcuts : config.keys;
  return binding.rule < list.size() ? &list[binding.rule] : nullptr;
}
Inspection inspect(const Event& e, const Chord& chord, const Snapshot& config,
                   Layout active) {
  Inspection i;
  i.name = chord.count ? chordName(chord) : keyName(e.key);
  i.scan =
      L"sc:" + std::wstring(e.key.extended ? L"e0:" : L"") + hex(e.key.scan);
  i.vk = hex(e.key.vk) + L" (" + keyName({e.key.vk}) + L")";
  i.registration = L"置き換えなし";
  if (auto r = matchingRule(e, chord, config)) {
    std::wstring target = r->action == Action::Toggle ? L"ime-toggle"
                          : r->action == Action::On   ? L"ime-on"
                          : r->action == Action::Off  ? L"ime-off"
                          : r->to.count               ? chordName(r->to)
                                                      : L"none";
    i.registration = L"line " + std::to_wstring(r->line) + L": " + target;
  }
  for (auto p : table(active))
    if (p.scan == e.key.scan) {
      if (p.plain) i.plain = std::wstring(1, static_cast<wchar_t>(p.plain));
      if (p.shift) i.shifted = std::wstring(1, static_cast<wchar_t>(p.shift));
    }
  auto state = inspectionPrefix(chord, inspectionRules(config));
  Snapshot layoutOnly;
  layoutOnly.enabled = true;
  layoutOnly.layout = config.layout;
  auto result = decide(e, state, layoutOnly, {active, false});
  i.conversion = L"OSのまま";
  if (result.swallow)
    for (unsigned n = 0; n < result.count; ++n) {
      auto key = result.events[n].key;
      if (!result.events[n].up && !(key.vk >= 0xa0 && key.vk <= 0xa5))
        i.conversion =
            L"置き換え: " + keyName(key) + L" (scan " + hex(key.scan) + L")";
    }
  return i;
}
std::wstring templateText() {
  return L"# nelisp-ime key remapping. Edit here or in the editor window.\n# "
         L"UTF-8. yes/no; layout: os | US | JIS. Missing file means "
         L"disabled.\n# Keys: CapsLock, LCtrl, RCtrl, LAlt, Shift, A, F1, "
         L"sc:0x3A, sc:e0:0x1D, vk:0x19.\n# Targets: a key, chord, ime-toggle, "
         L"ime-on, ime-off, or none.\n# One rule per line. # starts a comment. "
         L"Invalid lines are preserved/reported.\n# Hook codes are AFTER "
         L"Windows Scancode Map (CapsLock may already be LCtrl).\nenabled = "
         L"no\nlayout = os\npass-injected = yes\n\n[keys]\n# CapsLock = "
         L"LCtrl\n\n[shortcuts]\n# LAlt+Space = ime-toggle\n# Ctrl+Space = "
         L"LWin+Space\n\n[exclude]\n# mstsc.exe\n";
}
}  // namespace keymap
