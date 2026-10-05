// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "core.h"
namespace keymap {
// Pure inspector capture state; the caller supplies foreground/time policy.
struct Capture {
  bool active = false, cancelled = false, complete = false;
  std::array<bool, 256> held{}, preexisting{};
  Chord chord;
  Event last;
  uint32_t started = 0;
  void begin(uint32_t now) {
    *this = {};
    active = true;
    started = now;
  }
  bool feed(Event e, bool foreground, uint32_t now) noexcept {
    if (!active) return false;
    if (!foreground || now - started >= 10000) {
      active = false;
      cancelled = true;
      return false;
    }
    if (e.injected) return false;
    if (e.key.vk == 0x1b && !e.up) {
      active = false;
      cancelled = true;
      return true;
    }
    if (e.key.vk >= 256) return false;
    // A key already down when capture started belongs to its original owner.
    if (preexisting[e.key.vk]) {
      if (e.up) preexisting[e.key.vk] = false;
      return false;
    }
    // Releases whose presses preceded capture must reach their original owner.
    if (e.up && !held[e.key.vk]) return false;
    if (!e.up && !held[e.key.vk]) {
      held[e.key.vk] = true;
      if (chord.count < chord.keys.size()) chord.keys[chord.count++] = e.key;
      last = e;
    }
    if (e.up) {
      held[e.key.vk] = false;
      bool any = false;
      for (auto h : held) any = any || h;
      if (!any && chord.count) {
        active = false;
        complete = true;
      }
    }
    return true;
  }
};
}  // namespace keymap
