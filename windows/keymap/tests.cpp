// SPDX-License-Identifier: GPL-3.0-or-later
#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <new>
#include <sstream>

#include "capture.h"
#include "config.h"
#include "core.h"
using namespace keymap;
static bool trackAlloc = false;
static unsigned allocations = 0;
void* operator new(std::size_t n) {
  if (trackAlloc) ++allocations;
  if (auto p = std::malloc(n ? n : 1)) return p;
  throw std::bad_alloc();
}
void operator delete(void* p) noexcept { std::free(p); }
void operator delete(void* p, std::size_t) noexcept { std::free(p); }
namespace {
unsigned checks = 0, failures = 0;
void check(bool b, const char* name) {
  ++checks;
  if (!b) {
    ++failures;
    std::cout << "FAIL " << name << "\n";
  }
}
Event ev(unsigned vk, unsigned scan = 0, bool up = false) {
  return {{static_cast<uint16_t>(vk), static_cast<uint16_t>(scan)}, up};
}
void remaps() {
  trackAlloc = true;
  auto allocationProbe = ::operator new(32);
  ::operator delete(allocationProbe);
  trackAlloc = false;
  check(allocations == 1, "allocation detector negative control");
  allocations = 0;
  auto config =
      compile(true, Layout::Os, true,
              {L"CapsLock=LCtrl", L"A=none", L"B=ime-on", L"sc:e0:0x1D=RAlt"},
              {L"LAlt+Space=ime-toggle", L"Ctrl+Space=LWin+Space"}, {});
  check(config.errors.empty(), "parse defaults");
  State s;
  auto r = decide(ev(0x14, 0x3a), s, config, {});
  check(r.swallow && r.count == 1 && r.events[0].key.vk == 0xa2 &&
            !r.events[0].up,
        "Caps press");
  r = decide(ev(0x14, 0x3a), s, config, {});
  check(r.count == 1 && !r.events[0].up && s.owned[0xa2] == 1,
        "repeat does not grow ownership");
  r = decide(ev(0x14, 0x3a, true), s, config, {});
  check(r.swallow && r.count == 1 && r.events[0].up && s.owned[0xa2] == 0,
        "paired release");
  Event own = ev(0x14, 0x3a);
  own.extra = Tag;
  check(!decide(own, s, config, {}).swallow, "own injected bypass");
  own.extra = 0;
  own.injected = true;
  check(!decide(own, s, config, {}).swallow, "other injected bypass");
  config.passInjected = false;
  check(decide(own, s, config, {}).swallow, "injected opt in");
  release(s);
  auto winNone = compile(true, Layout::Os, true, {}, {L"LWin+Space=none"}, {});
  decide(ev(0x5b, 0x5b), s, winNone, {});
  r = decide(ev(0x20, 0x39), s, winNone, {});
  check(r.count == 6 && r.events[0].key.vk == 0xff &&
            r.events[2].key.vk == 0x5b && r.events[2].up &&
            r.events[4].key.vk == 0xff,
        "Win menu suppression before release and after restore");
  release(s);
  auto generic = compile(true, Layout::Os, true, {L"Ctrl=CapsLock"}, {}, {});
  check(decide(ev(0xa3, 0x1d), s, generic, {}).swallow,
        "generic key modifier matches right side");
  release(s);
  decide(ev(0xa2, 0x1d), s, config, {Layout::US, true});
  check(decide(ev(0x20, 0x39), s, config, {}).swallow,
        "modifier held across exclusion");
  decide(ev(0x20, 0x39, true), s, config, {});
  decide(ev(0xa2, 0x1d, true), s, config, {});
  check(!decide(ev(0x14, 0x3a), s, config, {Layout::US, true}).swallow,
        "exclusion");
  decide(ev(0x14, 0x3a), s, config, {});
  check(decide(ev(0x14, 0x3a), s, config, {Layout::US, true}).swallow,
        "repeat remains paired across exclusion");
  r = decide(ev(0x14, 0x3a, true), s, config, {Layout::US, true});
  check(r.swallow && r.events[0].up, "release across exclusion");
  decide(ev(0xa4, 0x38), s, config, {});
  r = decide(ev(0x20, 0x39), s, config, {});
  check(r.swallow && r.count == 8, "Alt toggle event count");
  check(r.events[0].key.vk == 0xff && !r.events[0].up &&
            r.events[2].key.vk == 0xa4 && r.events[2].up &&
            r.events[3].key.vk == 0x19,
        "dummy precedes Alt release");
  check(r.events[5].key.vk == 0xa4 && !r.events[5].up &&
            r.events[6].key.vk == 0xff,
        "Alt restored and used");
  decide(ev(0xa4, 0x38, true), s, config, {});
  r = decide(ev(0x20, 0x39), s, config, {});
  check(r.swallow, "shortcut repeats after modifier released");
  check(decide(ev(0x20, 0x39, true), s, config, {}).swallow,
        "shortcut release swallowed");
  decide(ev(0xa2, 0x1d), s, config, {});
  r = decide(ev(0x20, 0x39), s, config, {});
  check(r.count == 6 && r.events[0].up && r.events[1].key.vk == 0x5b &&
            r.events[2].key.vk == 0x20 && r.events[3].up && r.events[4].up &&
            !r.events[5].up,
        "Ctrl chord release/emit/restore");
  decide(ev(0x20, 0x39, true), s, config, {});
  decide(ev(0xa2, 0x1d, true), s, config, {});
  check(decide(ev('A', 0x1e), s, config, {}).swallow &&
            decide(ev('A', 0x1e, true), s, config, {}).swallow,
        "none press/up");
  r = decide(ev('B', 0x30), s, config, {});
  check(r.action == Action::On && r.swallow, "key action");
  decide(ev('B', 0x30, true), s, config, {});
  Event raw = ev(0xa3, 0x1d);
  raw.key.extended = true;
  r = decide(raw, s, config, {});
  check(r.swallow && r.events[0].key.vk == 0xa5 && r.events[0].key.extended,
        "extended raw");
  raw.up = true;
  check(decide(raw, s, config, {}).events[0].up, "extended raw up");
  auto rawTarget =
      compile(true, Layout::Os, true, {L"A=sc:e0:0x1D", L"B=sc:e0:0x1D"},
              {L"sc:e0:0x1D+Space=none"}, {});
  release(s);
  r = decide(ev('A', 0x1e), s, rawTarget, {});
  check(
      r.count == 1 && r.events[0].key.extended && r.events[0].key.scan == 0x1d,
      "raw target down");
  check(decide(ev('B', 0x30), s, rawTarget, {}).count == 0,
        "raw shared ownership");
  check(decide(ev(0x20, 0x39), s, rawTarget, {}).swallow, "raw modifier chord");
  decide(ev(0x20, 0x39, true), s, rawTarget, {});
  check(decide(ev('A', 0x1e, true), s, rawTarget, {}).count == 0,
        "raw first release retained");
  r = decide(ev('B', 0x30, true), s, rawTarget, {});
  check(r.count == 1 && r.events[0].up && s.rawOwned[0x11d] == 0,
        "raw final release paired");
  auto aliases =
      compile(true, Layout::Os, true, {L"A=sc:0x1D", L"B=LCtrl"}, {}, {});
  release(s);
  decide(ev('A', 0x1e), s, aliases, {});
  check(decide(ev('B', 0x30), s, aliases, {}).count == 0,
        "raw/VK modifier shared press");
  check(decide(ev('A', 0x1e, true), s, aliases, {}).count == 0,
        "raw/VK modifier shared release");
  check(decide(ev('B', 0x30, true), s, aliases, {}).events[0].up,
        "raw/VK modifier final release");
  // Two sources and a physical modifier share a target without early key-up.
  auto shared =
      compile(true, Layout::Os, true, {L"CapsLock=LCtrl", L"A=LCtrl"}, {}, {});
  decide(ev(0xa2, 0x1d), s, shared, {});
  decide(ev(0x14, 0x3a), s, shared, {});
  decide(ev('A', 0x1e), s, shared, {});
  check(decide(ev(0xa2, 0x1d, true), s, shared, {}).swallow,
        "physical Ctrl up retained");
  check(decide(ev(0x14, 0x3a, true), s, shared, {}).count == 0,
        "shared target retained");
  r = decide(ev('A', 0x1e, true), s, shared, {});
  check(r.count == 1 && r.events[0].up, "shared target final up");
  decide(ev(0x14, 0x3a), s, shared, {});
  r = release(s);
  check(r.count == 1 && r.events[0].up, "lifecycle releases owned");
  for (auto n : s.owned) check(n == 0, "no remaining ownership");
}
void layouts() {
  State unsupported;
  auto options = compile(true, Layout::US, true, {L"CapsLock=LCtrl"}, {}, {});
  check(
      decide(ev(0x14, 0x3a), unsupported, options, {Layout::JIS, false, false})
          .swallow,
      "key remaps work on unsupported layout");
  release(unsupported);
  check(
      !decide(ev(0xc0, 0x1a), unsupported, options, {Layout::JIS, false, false})
           .swallow,
      "unsupported character layout passes");
  State shiftedSpace;
  shiftedSpace.physical[0xa0] = true;
  auto spaceOptions = compile(true, Layout::US, true, {}, {}, {});
  auto spaceResult =
      decide(ev(0x20, 0x39), shiftedSpace, spaceOptions, {Layout::JIS, false});
  check(spaceResult.count == 1 && spaceResult.events[0].key.vk == 0x20,
        "layout keeps Shift when both states give same glyph");
  unsigned events = 0;
  for (auto active : {Layout::US, Layout::JIS})
    for (auto desired : {Layout::US, Layout::JIS})
      for (auto p : table(desired))
        for (bool shift : {false, true})
          for (unsigned mods = 0; mods < 8; ++mods) {
            State s;
            auto config = compile(true, desired, true, {}, {}, {});
            s.physical[0xa0] = shift;
            s.physical[0xa2] = (mods & 1) != 0;
            s.physical[0xa4] = (mods & 2) != 0;
            s.physical[0x5b] = (mods & 4) != 0;
            char expected = shift ? p.shift : p.plain;
            bool possible = false;
            for (auto q : table(active))
              possible = possible || expected && (q.plain == expected ||
                                                  q.shift == expected);
            auto e = ev(p.vk, p.scan);
            trackAlloc = true;
            auto r = decide(e, s, config, {active, false});
            trackAlloc = false;
            ++events;
            check(allocations == 0, "decision no heap");
            if (active == desired || !possible) {
              check(!r.swallow, "unchanged/unrepresentable layout passes");
              continue;
            }
            check(r.swallow, "convert representable glyph");
            bool actualShift = shift;
            char actual = 0;
            for (unsigned i = 0; i < r.count; ++i) {
              auto out = r.events[i];
              check(out.key.vk != 0xa2 && out.key.vk != 0xa4 &&
                        out.key.vk != 0x5b,
                    "keep Ctrl Alt Win");
              if (out.key.vk == 0xa0 || out.key.vk == 0xa1)
                actualShift = !out.up;
              else if (!out.up)
                for (auto q : table(active))
                  if (out.key.scan == q.scan)
                    actual = actualShift ? q.shift : q.plain;
            }
            check(actual == expected, "glyph oracle");
            check(actualShift == shift, "Shift restored after down");
            auto target = s.bindings[p.scan].target;
            e.up = true;
            r = decide(e, s, config, {active, false});
            check(r.swallow, "layout paired up");
            bool paired = false;
            for (unsigned i = 0; i < r.count; ++i)
              paired =
                  paired || (r.events[i].key.vk == target.vk && r.events[i].up);
            check(paired, "layout output release paired");
            for (auto n : s.owned) check(n == 0, "layout no stuck target");
          }
  std::cout << "S1.2 table scenarios=" << events
            << " (kbd101/en-US glyph table, kbd106 glyph table; Shift and 8 "
               "modifier combinations)\n";
}
void configuration() {
  check(!Document::parse(L" \n# missing config\n").snapshot.enabled,
        "empty config is disabled");
  for (unsigned v = 1; v < 256; ++v)
    check(parseKey(keyName({static_cast<uint16_t>(v)})).vk == v,
          "shared readable/raw names roundtrip");
  auto bomDoc =
      Document::parse(L"\ufeff# BOM\r\nenabled = yes\r\n[keys]\r\nA=B\r\n");
  check(bomDoc.text() == L"\ufeff# BOM\r\nenabled = yes\r\n[keys]\r\nA=B\r\n",
        "UTF-8 BOM preserved");
  auto crlf = Document::parse(L"# CRLF\r\n[keys]\r\nA = B # inline\r\n# end");
  auto crlfText = crlf.text();
  check(crlfText == L"# CRLF\r\n[keys]\r\nA = B # inline\r\n# end",
        "CRLF and final newline preserved");
  crlf.setRule(L"keys", L"A", L"C");
  check(crlf.text() == L"# CRLF\r\n[keys]\r\nA = C # inline\r\n# end",
        "only changed line rewritten");
  crlf.removeRule(L"keys", L"A");
  check(crlf.text().find(L"# inline") != crlf.text().npos,
        "delete preserves inline comment");
  auto d = Document::parse(
      L"# preserved\nenabled = yes\nlayout = US # keep\npass-injected = "
      L"no\nunknown = keep\n\n[keys]\nCapsLock = LCtrl # note\nsc:e0:0x1D = "
      L"RAlt\nBadKey = X\nA = none\n[shortcuts]\nCtrl+Space = "
      L"LWin+Space\n[exclude]\nmstsc.exe # exclude note\n");
  check(d.snapshot.enabled && !d.snapshot.passInjected &&
            d.snapshot.layout == Layout::US,
        "file options");
  check(d.snapshot.keys.size() == 3 && d.snapshot.shortcuts.size() == 1,
        "valid lines survive errors");
  check(d.snapshot.errors.size() == 2 &&
            d.snapshot.errors[1].starts_with(L"line 10:"),
        "errors have line numbers");
  check(d.snapshot.excludes[0] == L"mstsc.exe", "file exclusions");
  auto before = d.text();
  d.setRule(L"keys", L"CapsLock", L"LCtrl");
  check(d.text() == before, "unchanged rule byte text preserved");
  d.setRule(L"keys", L"B", L"C");
  check(d.snapshot.keys.size() == 4, "add round trip");
  d.setRule(L"keys", L"B", L"D");
  check(d.snapshot.keys.back().to.keys[0].vk == 'D', "replace round trip");
  d.removeRule(L"keys", L"B");
  check(d.snapshot.keys.size() == 3, "remove round trip");
  d.setRule(L"keys", L"CapsLock", L"RShift");
  check(d.text().find(L"CapsLock = RShift # note") != d.text().npos,
        "changed rule comment preserved");
  d.setOption(L"layout", L"JIS");
  check(d.text().find(L"layout = JIS # keep") != d.text().npos,
        "option comment preserved");
  d.setExclusions({L"mstsc.exe", L"game.exe"});
  check(d.text().find(L"mstsc.exe # exclude note") != d.text().npos,
        "exclusion comment retained");
  check(d.text().find(L"unknown = keep") != d.text().npos,
        "unknown line retained");
  Chord c;
  c.keys[0] = {0x14, 0x3a};
  c.count = 1;
  auto info = inspect(ev(0x14, 0x3a), c, d.snapshot, Layout::US);
  check(info.name == L"CapsLock" &&
            info.registration.find(L"RShift") != info.registration.npos,
        "inspector matching registration");
  info = inspect(ev('Z', 0x2c), {}, d.snapshot, Layout::US);
  check(info.registration == L"置き換えなし" && info.plain == L"z" &&
            info.shifted == L"Z",
        "inspector no rule/glyphs");
  Chord ctrlSpace;
  ctrlSpace.count = 2;
  ctrlSpace.keys[0] = {0xa2, 0x1d};
  ctrlSpace.keys[1] = {0x20, 0x39};
  check(matchingRule(ev(0x20, 0x39), ctrlSpace, d.snapshot) != nullptr,
        "inspector generic Ctrl chord match");
  Chord reordered;
  reordered.count = 3;
  reordered.keys[0] = {0xa0, 0x2a};
  reordered.keys[1] = {0xa2, 0x1d};
  reordered.keys[2] = {0x20, 0x39};
  check(matchingRule(ev(0x20, 0x39), reordered, d.snapshot) != nullptr,
        "inspector uses decision modifier semantics/order");
  auto logicalConfig = Document::parse(
      L"[keys]\nCapsLock=LCtrl\nA=B\n[shortcuts]\nCtrl+Space=ime-toggle\n");
  Chord caps;
  caps.count = 2;
  caps.keys[0] = {0x14, 0x3a};
  caps.keys[1] = {0x20, 0x39};
  auto logical = matchingRule(ev(0x20, 0x39), caps, logicalConfig.snapshot);
  check(logical && logical->action == Action::Toggle,
        "inspector sees logical modifier remap");
  caps.keys[0] = {0xa2, 0x1d};
  caps.keys[1] = {'A', 0x1e};
  logical = matchingRule(ev('A', 0x1e), caps, logicalConfig.snapshot);
  check(logical && logical->to.keys[0].vk == 'B',
        "inspector key rule fallback under modifiers");
  check(keyName({0, 0x1d, true}) == L"sc:e0:0x1D", "raw inspector name");
  Capture capture;
  capture.begin(1);
  capture.preexisting['A'] = true;
  check(!capture.feed(ev('A', 0x1e), true, 2), "pre-capture repeat passes");
  check(!capture.feed(ev('A', 0x1e, true), true, 2),
        "pre-capture release passes");
  check(!capture.feed(ev(0xa2, 0x1d, true), true, 2),
        "pre-capture release passes to original owner");
  check(capture.feed(ev(0xa4, 0x38), true, 2), "capture Alt swallowed");
  check(capture.feed(ev(0x20, 0x39), true, 3), "capture Space swallowed");
  capture.feed(ev(0x20, 0x39, true), true, 4);
  check(capture.active, "capture waits for releases");
  capture.feed(ev(0xa4, 0x38, true), true, 5);
  check(capture.complete && chordName(capture.chord) == L"LAlt+Space",
        "capture chord");
  capture.begin(1);
  check(!capture.feed(ev('A'), false, 2) && capture.cancelled,
        "capture loses foreground");
  capture.begin(1);
  check(!capture.feed(ev('A'), true, 10001) && capture.cancelled,
        "capture timeout");
  capture.begin(1);
  check(capture.feed(ev(0x1b), true, 2) && capture.cancelled, "capture Esc");
}
int benchmark() {
  constexpr unsigned count = 1000000;
  std::vector<std::wstring> keys, shortcuts;
  for (unsigned n = 1; n <= 255; ++n) {
    std::wostringstream raw;
    raw << std::hex << n;
    keys.push_back(L"sc:e0:0x" + raw.str() + L"=LCtrl");
    shortcuts.push_back(L"Ctrl+vk:0x" + raw.str() + L"=Space");
  }
  auto s = compile(true, Layout::JIS, true, keys, shortcuts, {});
  State state;
  std::vector<double> times;
  times.reserve(count);
  uint64_t outputs = 0;
  for (unsigned i = 0; i < count; ++i) {
    bool raw = (i / 2) % 2 == 0;
    auto e = raw ? ev(0xff, 0xff, (i & 1) != 0) : ev(0xc0, 0x1a, (i & 1) != 0);
    e.key.extended = raw;
    auto start = std::chrono::steady_clock::now();
    auto r = decide(e, state, s, {});
    auto end = std::chrono::steady_clock::now();
    outputs += r.count;
    times.push_back(
        std::chrono::duration<double, std::micro>(end - start).count());
  }
  std::sort(times.begin(), times.end());
  std::cout << "S2.1 events=" << count << " p50_us=" << times[count / 2]
            << " p99_us=" << times[count * 99 / 100] << " outputs=" << outputs
            << "\n";
  return times[count * 99 / 100] < 50 ? 0 : 1;
}
}  // namespace
int main(int argc, char**) {
  table(Layout::US);
  table(Layout::JIS);
  if (argc > 1) return benchmark();
  remaps();
  layouts();
  configuration();
  std::cout << "core/inspector/file-roundtrip: checks=" << checks
            << " failures=" << failures << "\n";
  return failures ? 1 : 0;
}
