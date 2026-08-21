// Copyright (C) 2026 nelisp-skk-ime contributors
// GPL-3.0-or-later

#pragma once

#include "engine_protocol.h"

#include <optional>
#include <string>

namespace ddskk {

// Native, allocation-bounded romaji/preedit path.  It deliberately performs
// no dictionary work: conversion providers receive raw_keys() only at the
// conversion barrier, while ordinary typing never waits for NeLisp.
class RealtimeFrontend {
 public:
  // Standard providers (for example Lattice) compose every kana sequence.
  // DDSKK leaves this disabled and starts a conversion reading with an
  // uppercase roman key instead.
  void SetContinuousPreedit(bool enabled) { continuous_preedit_ = enabled; }
  std::optional<EngineState> Feed(char32_t key);
  std::optional<EngineState> Backspace();
  std::optional<EngineState> Commit();
  std::optional<EngineState> Quit();
  // Re-render the original reading after a provider candidate replaces it.
  EngineState RestorePreedit() const;
  std::optional<EngineState> ToKatakana();
  // DDSKK q in ▽ mode toggles the region and immediately confirms it.
  std::optional<EngineState> CommitKatakana();
  EngineState ToHiragana();

  void Reset();
  bool composing() const { return preedit_ || !pending_.empty(); }
  bool preedit() const { return preedit_; }
  bool katakana() const { return katakana_; }
  bool latin() const { return latin_; }
  bool wide_latin() const { return wide_latin_; }
  const std::u32string& raw_keys() const { return raw_keys_; }
  // Completed okuri-nasi reading suitable for a non-authoritative native
  // dictionary preview. Empty means the provider must be the first surface.
  std::wstring preview_reading() const {
    return preedit_ && pending_.empty() && !okuri_started_ ? text_ : L"";
  }

 private:
  std::optional<EngineState> FeedAscii(char key, bool record);
  EngineState Snapshot(bool terminal = false) const;
  void RebuildPreedit();
  static std::wstring Katakana(const std::wstring& text);

  bool preedit_ = false;
  bool katakana_ = false;
  bool latin_ = false;
  bool wide_latin_ = false;
  bool okuri_started_ = false;
  bool continuous_preedit_ = false;
  std::wstring text_;
  std::string pending_;
  std::u32string raw_keys_;
};

}  // namespace ddskk
