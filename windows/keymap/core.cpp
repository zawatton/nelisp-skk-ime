// SPDX-License-Identifier: GPL-3.0-or-later
#include "core.h"

#include <algorithm>
#include <cwctype>
#include <stdexcept>
namespace keymap {
namespace {
std::wstring trim(std::wstring s) {
  auto a = s.find_first_not_of(L" \t\r\n");
  if (a == s.npos) return {};
  return s.substr(a, s.find_last_not_of(L" \t\r\n") - a + 1);
}
std::wstring lower(std::wstring s) {
  for (auto& c : s) c = std::towlower(c);
  return s;
}
bool modifier(unsigned v) {
  return v >= 0xa0 && v <= 0xa5 || v == 0x5b || v == 0x5c;
}
unsigned index(Key k) {
  return k.scan ? ((k.scan & 255) + (k.extended ? 256 : 0))
                : 512 + (k.vk & 255);
}
bool matches(Key pattern, Key key) {
  return pattern.scan
             ? pattern.scan == key.scan && pattern.extended == key.extended
             : pattern.vk == key.vk ||
                   pattern.vk == 0x10 && (key.vk == 0xa0 || key.vk == 0xa1) ||
                   pattern.vk == 0x11 && (key.vk == 0xa2 || key.vk == 0xa3) ||
                   pattern.vk == 0x12 && (key.vk == 0xa4 || key.vk == 0xa5);
}
bool down(unsigned vk, const State& s) {
  if (vk == 0x10) return down(0xa0, s) || down(0xa1, s);
  if (vk == 0x11) return down(0xa2, s) || down(0xa3, s);
  if (vk == 0x12) return down(0xa4, s) || down(0xa5, s);
  unsigned raw = vk == 0xa2   ? 0x1d
                 : vk == 0xa3 ? 0x11d
                 : vk == 0xa0 ? 0x2a
                 : vk == 0xa1 ? 0x36
                 : vk == 0xa4 ? 0x38
                 : vk == 0xa5 ? 0x138
                 : vk == 0x5b ? 0x15b
                 : vk == 0x5c ? 0x15c
                              : 0;
  return vk < 256 &&
         (s.physical[vk] || s.owned[vk] || (raw && s.rawOwned[raw]));
}
Chord chord(const std::wstring& text) {
  Chord c;
  size_t p = 0;
  do {
    auto n = text.find(L'+', p);
    if (c.count == c.keys.size()) throw std::runtime_error("chord too long");
    c.keys[c.count++] =
        parseKey(trim(text.substr(p, n == text.npos ? n : n - p)));
    if (n == text.npos) break;
    p = n + 1;
  } while (true);
  return c;
}
void shiftAround(Result& r, State& s, bool wanted, bool before) {
  const bool actual = down(0x10, s);
  if (actual == wanted) return;
  if (wanted)
    r.emit({0xa0}, !before);
  else {
    for (unsigned v : {0xa0u, 0xa1u})
      if (down(v, s)) r.emit({static_cast<uint16_t>(v)}, before);
  }
}
void tap(Result& r, State& s, const Chord& c) {
  std::array<bool, 256> held{};
  if (down(0x12, s) || down(0x5b, s) || down(0x5c, s)) {
    r.emit({0xff}, false);
    r.emit({0xff}, true);
  }
  for (unsigned v = 0; v < 256; ++v)
    if (modifier(v) && down(v, s)) {
      held[v] = true;
      r.emit({static_cast<uint16_t>(v), 0,
              v == 0xa3 || v == 0xa5 || v == 0x5b || v == 0x5c},
             true);
    }
  for (unsigned i = 0; i < c.count; ++i) r.emit(c.keys[i], false);
  for (unsigned i = c.count; i > 0; --i) r.emit(c.keys[i - 1], true);
  for (unsigned v = 0; v < 256; ++v)
    if (held[v])
      r.emit({static_cast<uint16_t>(v), 0,
              v == 0xa3 || v == 0xa5 || v == 0x5b || v == 0x5c},
             false);
  if (held[0xa4] || held[0xa5] || held[0x5b] || held[0x5c]) {
    r.emit({0xff}, false);
    r.emit({0xff}, true);
  }
}
}  // namespace
unsigned modifierVk(Key k) noexcept {
  if (k.vk) return k.vk;
  switch (k.scan) {
    case 0x1d:
      return k.extended ? 0xa3 : 0xa2;
    case 0x2a:
      return 0xa0;
    case 0x36:
      return 0xa1;
    case 0x38:
      return k.extended ? 0xa5 : 0xa4;
    case 0x5b:
      return k.extended ? 0x5b : 0;
    case 0x5c:
      return k.extended ? 0x5c : 0;
    default:
      return 0;
  }
}
Key parseKey(const std::wstring& input) {
  auto s = lower(trim(input));
  if (s.starts_with(L"vk:") || s.starts_with(L"sc:")) {
    size_t end = 0;
    bool ext = s.starts_with(L"sc:e0:");
    auto raw = s.substr(ext ? 6 : 3);
    auto n = std::stoul(raw, &end, 0);
    if (end != raw.size() || n == 0 || n > 255)
      throw std::runtime_error("raw key outside 1..255");
    return s[0] == L'v' ? Key{static_cast<uint16_t>(n)}
                        : Key{0, static_cast<uint16_t>(n), ext};
  }
  const std::pair<const wchar_t*, unsigned> names[] = {
      {L"capslock", 0x14},   {L"lctrl", 0xa2},      {L"rctrl", 0xa3},
      {L"ctrl", 0x11},       {L"lalt", 0xa4},       {L"ralt", 0xa5},
      {L"alt", 0x12},        {L"lshift", 0xa0},     {L"rshift", 0xa1},
      {L"shift", 0x10},      {L"lwin", 0x5b},       {L"rwin", 0x5c},
      {L"win", 0x5b},        {L"space", 0x20},      {L"enter", 0x0d},
      {L"tab", 9},           {L"escape", 0x1b},     {L"backspace", 8},
      {L"delete", 0x2e},     {L"insert", 0x2d},     {L"home", 0x24},
      {L"end", 0x23},        {L"pageup", 0x21},     {L"pagedown", 0x22},
      {L"left", 0x25},       {L"up", 0x26},         {L"right", 0x27},
      {L"down", 0x28},       {L"kanji", 0x19},      {L"oem1", 0xba},
      {L"oemplus", 0xbb},    {L"oemcomma", 0xbc},   {L"oemminus", 0xbd},
      {L"oemperiod", 0xbe},  {L"oem2", 0xbf},       {L"oem3", 0xc0},
      {L"oem4", 0xdb},       {L"oem5", 0xdc},       {L"oem6", 0xdd},
      {L"oem7", 0xde},       {L"oem8", 0xdf},       {L"oem102", 0xe2},
      {L"numlock", 0x90},    {L"scrolllock", 0x91}, {L"printscreen", 0x2c},
      {L"pause", 0x13},      {L"apps", 0x5d},       {L"numpad0", 0x60},
      {L"numpad1", 0x61},    {L"numpad2", 0x62},    {L"numpad3", 0x63},
      {L"numpad4", 0x64},    {L"numpad5", 0x65},    {L"numpad6", 0x66},
      {L"numpad7", 0x67},    {L"numpad8", 0x68},    {L"numpad9", 0x69},
      {L"multiply", 0x6a},   {L"add", 0x6b},        {L"subtract", 0x6d},
      {L"decimal", 0x6e},    {L"divide", 0x6f},     {L"convert", 0x1c},
      {L"nonconvert", 0x1d}, {L"kana", 0x15}};
  for (auto [name, v] : names)
    if (s == name)
      return {static_cast<uint16_t>(v), 0,
              v == 0xa3 || v == 0xa5 || v == 0x5b || v == 0x5c || v == 0x5d ||
                  v == 0x6f || v == 0x90 || v >= 0x21 && v <= 0x2e};
  if (s.size() == 1 &&
      ((s[0] >= L'a' && s[0] <= L'z') || (s[0] >= L'0' && s[0] <= L'9')))
    return {static_cast<uint16_t>(std::towupper(s[0]))};
  if (s.size() > 1 && s[0] == L'f') {
    size_t end;
    auto n = std::stoul(s.substr(1), &end);
    if (end == s.size() - 1 && n >= 1 && n <= 24)
      return {static_cast<uint16_t>(0x6f + n)};
  }
  throw std::runtime_error("unknown key");
}
Snapshot compile(bool enabled, Layout layout, bool passInjected,
                 const std::vector<std::wstring>& keys,
                 const std::vector<std::wstring>& shortcuts,
                 const std::vector<std::wstring>& excludes) {
  Snapshot s;
  s.enabled = enabled;
  s.layout = layout;
  s.passInjected = passInjected;
  for (auto name : excludes) {
    name = lower(trim(name));
    if (!name.empty()) s.excludes.push_back(name);
  }
  for (unsigned kind = 0; kind < 2; ++kind)
    for (auto line : kind ? shortcuts : keys) {
      line = trim(line);
      if (line.empty()) continue;
      try {
        auto eq = line.find(L'=');
        if (eq == line.npos || line.find(L'=', eq + 1) != line.npos)
          throw std::runtime_error("expected one equals sign");
        Rule r;
        r.from = chord(line.substr(0, eq));
        auto rhs = lower(trim(line.substr(eq + 1)));
        if (rhs == L"ime-toggle")
          r.action = Action::Toggle;
        else if (rhs == L"ime-on")
          r.action = Action::On;
        else if (rhs == L"ime-off")
          r.action = Action::Off;
        else if (rhs != L"none")
          r.to = chord(rhs);
        if (!kind && r.from.count != 1)
          throw std::runtime_error("key source requires one key");
        if (kind && r.from.count < 2)
          throw std::runtime_error("shortcut requires modifier plus key");
        for (unsigned i = 0; i + 1 < r.from.count; ++i)
          if (!modifier(modifierVk(r.from.keys[i])) &&
              modifierVk(r.from.keys[i]) != 0x10 &&
              modifierVk(r.from.keys[i]) != 0x11 &&
              modifierVk(r.from.keys[i]) != 0x12)
            throw std::runtime_error("prefix must be a modifier");
        // Generic destination modifiers are normalized to their left-hand key.
        for (unsigned i = 0; i < r.to.count; ++i) {
          auto& k = r.to.keys[i];
          if (k.vk == 0x10) k.vk = 0xa0;
          if (k.vk == 0x11) k.vk = 0xa2;
          if (k.vk == 0x12) k.vk = 0xa4;
        }
        auto& rules = kind ? s.shortcuts : s.keys;
        if (std::any_of(rules.begin(), rules.end(), [&](auto& old) {
              return old.from.keys == r.from.keys &&
                     old.from.count == r.from.count;
            }))
          throw std::runtime_error("duplicate source");
        rules.push_back(r);
      } catch (const std::exception& e) {
        std::string reason = e.what();
        s.errors.push_back(line + L": " +
                           std::wstring(reason.begin(), reason.end()));
      }
    }
  return s;
}
const std::vector<Printable>& table(Layout layout) {
  // Set-1 positions, Windows VKs and ASCII glyphs. Unrepresentable JIS yen
  // and kana keys are intentionally absent: conversion must pass them through.
  static const std::vector<Printable> us = [] {
    std::vector<Printable> t;
    const char* a = "1234567890";
    const char* b = "!@#$%^&*()";
    for (int i = 0; i < 10; ++i)
      t.push_back({static_cast<uint16_t>(2 + i), static_cast<uint16_t>(a[i]),
                   a[i], b[i]});
    const char* rows[] = {"qwertyuiop", "asdfghjkl", "zxcvbnm"};
    unsigned starts[] = {0x10, 0x1e, 0x2c};
    for (int row = 0; row < 3; ++row)
      for (unsigned i = 0; rows[row][i]; ++i) {
        char c = rows[row][i];
        t.push_back({static_cast<uint16_t>(starts[row] + i),
                     static_cast<uint16_t>(c - 32), c,
                     static_cast<char>(c - 32)});
      }
    for (auto p : std::vector<Printable>{{0xc, 0xbd, '-', '_'},
                                         {0xd, 0xbb, '=', '+'},
                                         {0x1a, 0xdb, '[', '{'},
                                         {0x1b, 0xdd, ']', '}'},
                                         {0x27, 0xba, ';', ':'},
                                         {0x28, 0xde, '\'', '"'},
                                         {0x29, 0xc0, '`', '~'},
                                         {0x2b, 0xdc, '\\', '|'},
                                         {0x33, 0xbc, ',', '<'},
                                         {0x34, 0xbe, '.', '>'},
                                         {0x35, 0xbf, '/', '?'},
                                         {0x39, 0x20, ' ', ' '}})
      t.push_back(p);
    return t;
  }();
  static const std::vector<Printable> jis = [] {
    auto t = us;
    const char* shift = "!\"#$%&'()";
    for (unsigned i = 0; i < 9; ++i) t[i].shift = shift[i];
    t[9].shift = 0;
    for (auto& p : t) switch (p.scan) {
        case 0xc:
          p = {0xc, 0xbd, '-', '='};
          break;
        case 0xd:
          p = {0xd, 0xde, '^', '~'};
          break;
        case 0x1a:
          p = {0x1a, 0xc0, '@', '`'};
          break;
        case 0x1b:
          p = {0x1b, 0xdb, '[', '{'};
          break;
        case 0x27:
          p = {0x27, 0xbb, ';', '+'};
          break;
        case 0x28:
          p = {0x28, 0xba, ':', '*'};
          break;
        case 0x29:
          p.plain = p.shift = 0;
          break;
        case 0x2b:
          p = {0x2b, 0xdd, ']', '}'};
          break;
        default:
          break;
      }
    t.push_back({0x73, 0xe2, '\\', '_'});
    t.push_back({0x7d, 0xdc, '\\', '|'});
    return t;
  }();
  return layout == Layout::JIS ? jis : us;
}
Result decide(const Event& e, State& s, const Snapshot& rules,
              Context ctx) noexcept {
  Result r;
  if (e.extra == Tag || (e.injected && rules.passInjected)) return r;
  if (e.key.vk >= 256) return r;
  auto& binding = s.bindings[index(e.key)];
  if (e.up && binding.active) {
    r.swallow = true;
    if (!binding.tap) {
      if (binding.layout) shiftAround(r, s, binding.shifted, true);
      auto v = binding.target.vk;
      if (v) {
        if (s.owned[v] == 0 || (--s.owned[v] == 0 && !down(v, s)))
          r.emit(binding.target, true);
      } else {
        auto& n = s.rawOwned[index(binding.target)];
        if (n && --n == 0 &&
            (!modifierVk(binding.target) ||
             !down(modifierVk(binding.target), s)))
          r.emit(binding.target, true);
      }
      if (binding.layout) shiftAround(r, s, binding.shifted, false);
    }
    binding = {};
    s.physical[e.key.vk] = false;
    return r;
  }
  if (binding.active && !binding.tap) {
    r.swallow = true;
    if (binding.layout) shiftAround(r, s, binding.shifted, true);
    if ((down(0x12, s) && modifierVk(binding.target) != 0xa4 &&
         modifierVk(binding.target) != 0xa5) ||
        ((down(0x5b, s) || down(0x5c, s)) &&
         modifierVk(binding.target) != 0x5b &&
         modifierVk(binding.target) != 0x5c)) {
      r.emit({0xff}, false);
      r.emit({0xff}, true);
    }
    r.emit(binding.target, false);
    if (binding.layout) shiftAround(r, s, binding.shifted, false);
    return r;
  }
  auto emitRule = [&](const Rule& rule) {
    r.swallow = true;
    if (rule.action == Action::Toggle) {
      Chord c;
      c.keys[0] = {0x19};
      c.count = 1;
      tap(r, s, c);
    } else if (rule.action != Action::None) {
      Chord empty;
      tap(r, s, empty);
      r.action = rule.action;
    } else
      tap(r, s, rule.to);
  };
  if (binding.active && binding.tap) {
    const auto& list = binding.shortcut ? rules.shortcuts : rules.keys;
    if (binding.rule < list.size()) emitRule(list[binding.rule]);
    return r;
  }
  if (!rules.enabled || ctx.excluded) {
    s.physical[e.key.vk] = !e.up;
    if (e.up && down(e.key.vk, s)) r.swallow = true;
    return r;
  }
  if (e.up) {
    s.physical[e.key.vk] = false;
    if (down(e.key.vk, s)) r.swallow = true;
    return r;
  }
  // Match against logical modifiers before recording this event as physical.
  for (unsigned n = 0; n < rules.shortcuts.size(); ++n) {
    const auto& rule = rules.shortcuts[n];
    if (!matches(rule.from.keys[rule.from.count - 1], e.key)) continue;
    bool match = true;
    for (unsigned i = 0; i + 1 < rule.from.count; ++i)
      match = match && down(modifierVk(rule.from.keys[i]), s);
    if (!match) continue;
    binding.active = binding.tap = binding.shortcut = true;
    binding.rule = n;
    emitRule(rule);
    return r;
  }
  for (unsigned n = 0; n < rules.keys.size(); ++n) {
    const auto& rule = rules.keys[n];
    if (!matches(rule.from.keys[0], e.key)) continue;
    binding.active = true;
    binding.rule = n;
    s.physical[e.key.vk] = false;
    if (rule.to.count != 1 || rule.action != Action::None) {
      binding.tap = true;
      emitRule(rule);
      return r;
    }
    binding.target = rule.to.keys[0];
    r.swallow = true;
    if ((down(0x12, s) && modifierVk(binding.target) != 0xa4 &&
         modifierVk(binding.target) != 0xa5) ||
        ((down(0x5b, s) || down(0x5c, s)) &&
         modifierVk(binding.target) != 0x5b &&
         modifierVk(binding.target) != 0x5c)) {
      r.emit({0xff}, false);
      r.emit({0xff}, true);
    }
    if (binding.target.vk) {
      bool already = down(binding.target.vk, s);
      if (s.owned[binding.target.vk]++ == 0 && !already)
        r.emit(binding.target, false);
    } else {
      bool already =
          modifierVk(binding.target) && down(modifierVk(binding.target), s);
      if (s.rawOwned[index(binding.target)]++ == 0 && !already)
        r.emit(binding.target, false);
    }
    return r;
  }
  s.physical[e.key.vk] = true;
  if (ctx.layoutSupported && !e.key.extended && rules.layout != Layout::Os &&
      rules.layout != ctx.active) {
    char glyph = 0;
    bool shifted = down(0x10, s);
    for (auto p : table(rules.layout))
      if (p.scan == e.key.scan) glyph = shifted ? p.shift : p.plain;
    if (glyph)
      for (auto p : table(ctx.active))
        for (unsigned choice = 0; choice < 2; ++choice) {
          unsigned sh = shifted ? 1 - choice : choice;
          if ((sh ? p.shift : p.plain) == glyph) {
            binding = {true, false, {p.vk, p.scan, false}, sh != 0, true};
            s.physical[e.key.vk] = false;
            r.swallow = true;
            shiftAround(r, s, sh != 0, true);
            if (s.owned[p.vk]++ == 0) r.emit(binding.target, false);
            shiftAround(r, s, sh != 0, false);
            return r;
          }
        }
  }
  return r;
}
Result release(State& s) noexcept {
  Result r;
  for (unsigned v = 0; v < 256; ++v)
    if (s.owned[v] && !s.physical[v])
      r.emit({static_cast<uint16_t>(v), 0,
              v == 0xa3 || v == 0xa5 || v == 0x5b || v == 0x5c},
             true);
  for (unsigned n = 0; n < s.rawOwned.size(); ++n)
    if (s.rawOwned[n])
      r.emit({0, static_cast<uint16_t>(n & 255), n >= 256}, true);
  s = {};
  return r;
}
}  // namespace keymap
