// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <array>
#include <cstdint>
#include <string>
#include <vector>
namespace keymap {
constexpr uintptr_t Tag = 0x4e494b4d;
struct Key {
  uint16_t vk = 0, scan = 0;
  bool extended = false;
  bool operator==(const Key&) const = default;
};
struct Event {
  Key key;
  bool up = false, injected = false;
  uintptr_t extra = 0;
  uint32_t time = 0;
};
enum class Layout { Os, US, JIS };
enum class Action { None, Toggle, On, Off };
struct Chord {
  std::array<Key, 8> keys{};
  unsigned count = 0;
};
struct Rule {
  Chord from, to;
  Action action = Action::None;
  unsigned line = 0;
};
struct Snapshot {
  bool enabled = false, passInjected = true;
  Layout layout = Layout::Os;
  std::vector<Rule> keys, shortcuts;
  std::vector<std::wstring> excludes, errors;
};
struct Binding {
  bool active = false, tap = false;
  Key target{};
  bool shifted = false, layout = false;
  unsigned rule = 0;
  bool shortcut = false;
};
struct State {
  std::array<bool, 256> physical{};
  std::array<unsigned, 256> owned{};
  std::array<unsigned, 512> rawOwned{};
  std::array<Binding, 1024> bindings{};
};
struct Result {
  bool swallow = false;
  std::array<Event, 1024> events{};
  unsigned count = 0;
  Action action = Action::None;
  void emit(Key key, bool up) noexcept {
    if (count < events.size()) events[count++] = {key, up, true, Tag, 0};
  }
};
struct Context {
  Layout active = Layout::US;
  bool excluded = false;
  bool layoutSupported = true;
};
Snapshot compile(bool enabled, Layout layout, bool passInjected,
                 const std::vector<std::wstring>& keys,
                 const std::vector<std::wstring>& shortcuts,
                 const std::vector<std::wstring>& excludes);
Key parseKey(const std::wstring& name);
unsigned modifierVk(Key) noexcept;
Result decide(const Event&, State&, const Snapshot&, Context) noexcept;
Result release(State&) noexcept;
struct Printable {
  uint16_t scan, vk;
  char plain, shift;
};
const std::vector<Printable>& table(Layout);
}  // namespace keymap
