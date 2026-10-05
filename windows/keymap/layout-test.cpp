// SPDX-License-Identifier: GPL-3.0-or-later
#include <windows.h>
#include <kbd.h>
#include "core.h"
#include <iostream>
#include <string>
using namespace keymap;
int main() {
  unsigned checks = 0, failures = 0;
  wchar_t system[MAX_PATH];
  GetSystemDirectoryW(system, MAX_PATH);
  for (auto name : {L"kbd101.dll", L"kbd106.dll", L"kbdus.dll"}) {
    HMODULE module =
        LoadLibraryExW((std::wstring(system) + L"\\" + name).c_str(), nullptr,
                       LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!module) {
      std::wcerr << name << L": load failed " << GetLastError() << L"\n";
      return 1;
    }
    using Descriptor = PKBDTABLES(WINAPI*)();
    auto descriptor = reinterpret_cast<Descriptor>(
        GetProcAddress(module, "KbdLayerDescriptor"));
    if (!descriptor) {
      FreeLibrary(module);
      return 2;
    }
    auto native = descriptor();
    auto layout =
        std::wstring(name) == L"kbd106.dll" ? Layout::JIS : Layout::US;
    for (auto p : table(layout)) {
      if (!p.plain && !p.shift) continue;
      unsigned vk =
          p.scan < native->bMaxVSCtoVK ? native->pusVSCtoVK[p.scan] & 0xff : 0;
      wchar_t chars[2]{};
      bool found = false;
      for (auto t = native->pVkToWcharTable; t->pVkToWchars; ++t) {
        auto row = reinterpret_cast<const BYTE*>(t->pVkToWchars);
        while (row[0]) {
          if (row[0] == vk) {
            auto w = reinterpret_cast<const WCHAR*>(row + 2);
            for (unsigned sh = 0; sh < 2; ++sh) {
              unsigned mod = native->pCharModifiers->ModNumber[sh];
              if (mod < t->nModifications && w[mod] < 0xf000)
                chars[sh] = w[mod];
            }
            found = true;
            break;
          }
          row += t->cbSize;
        }
        if (found) break;
      }
      ++checks;
      if (vk != p.vk || chars[0] != static_cast<unsigned char>(p.plain) ||
          chars[1] != static_cast<unsigned char>(p.shift)) {
        ++failures;
        std::wcout << name << L" scan=" << std::hex << p.scan
                   << L" vk expected=" << p.vk << L" actual=" << vk
                   << L" glyph expected=" << static_cast<unsigned>(p.plain)
                   << L"," << static_cast<unsigned>(p.shift) << L" actual="
                   << static_cast<unsigned>(chars[0]) << L","
                   << static_cast<unsigned>(chars[1]) << std::dec << L"\n";
      }
    }
    FreeLibrary(module);
  }
  std::cout << "S1.2 native DLL glyph oracle: checks=" << checks
            << " failures=" << failures
            << " layouts activated=0 hooks=0 SendInput=0\n";
  return failures ? 1 : 0;
}
