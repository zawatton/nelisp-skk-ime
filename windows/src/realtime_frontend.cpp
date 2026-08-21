// Copyright (C) 2026 nelisp-skk-ime contributors
// GPL-3.0-or-later

#include "realtime_frontend.h"

#include <array>
#include <cctype>
#include <string_view>
#include <unordered_map>
#include <unordered_set>

namespace ddskk {
namespace {

using Rule = std::pair<std::string_view, std::wstring_view>;
constexpr std::array kRules{
    Rule{"a", L"あ"}, Rule{"i", L"い"}, Rule{"u", L"う"}, Rule{"e", L"え"}, Rule{"o", L"お"},
    Rule{"ka", L"か"}, Rule{"ki", L"き"}, Rule{"ku", L"く"}, Rule{"ke", L"け"}, Rule{"ko", L"こ"},
    Rule{"kya", L"きゃ"}, Rule{"kyu", L"きゅ"}, Rule{"kyo", L"きょ"},
    Rule{"sa", L"さ"}, Rule{"shi", L"し"}, Rule{"si", L"し"}, Rule{"su", L"す"}, Rule{"se", L"せ"}, Rule{"so", L"そ"},
    Rule{"sha", L"しゃ"}, Rule{"shu", L"しゅ"}, Rule{"sho", L"しょ"}, Rule{"sya", L"しゃ"}, Rule{"syu", L"しゅ"}, Rule{"syo", L"しょ"},
    Rule{"ta", L"た"}, Rule{"chi", L"ち"}, Rule{"ti", L"ち"}, Rule{"tsu", L"つ"}, Rule{"tu", L"つ"}, Rule{"te", L"て"}, Rule{"to", L"と"},
    Rule{"cha", L"ちゃ"}, Rule{"chu", L"ちゅ"}, Rule{"cho", L"ちょ"},
    Rule{"na", L"な"}, Rule{"ni", L"に"}, Rule{"nu", L"ぬ"}, Rule{"ne", L"ね"}, Rule{"no", L"の"},
    Rule{"nya", L"にゃ"}, Rule{"nyu", L"にゅ"}, Rule{"nyo", L"にょ"},
    Rule{"ha", L"は"}, Rule{"hi", L"ひ"}, Rule{"fu", L"ふ"}, Rule{"hu", L"ふ"}, Rule{"he", L"へ"}, Rule{"ho", L"ほ"},
    Rule{"hya", L"ひゃ"}, Rule{"hyu", L"ひゅ"}, Rule{"hyo", L"ひょ"},
    Rule{"ma", L"ま"}, Rule{"mi", L"み"}, Rule{"mu", L"む"}, Rule{"me", L"め"}, Rule{"mo", L"も"},
    Rule{"mya", L"みゃ"}, Rule{"myu", L"みゅ"}, Rule{"myo", L"みょ"},
    Rule{"ya", L"や"}, Rule{"yu", L"ゆ"}, Rule{"yo", L"よ"},
    Rule{"ra", L"ら"}, Rule{"ri", L"り"}, Rule{"ru", L"る"}, Rule{"re", L"れ"}, Rule{"ro", L"ろ"},
    Rule{"rya", L"りゃ"}, Rule{"ryu", L"りゅ"}, Rule{"ryo", L"りょ"}, Rule{"wa", L"わ"}, Rule{"wo", L"を"},
    Rule{"ga", L"が"}, Rule{"gi", L"ぎ"}, Rule{"gu", L"ぐ"}, Rule{"ge", L"げ"}, Rule{"go", L"ご"},
    Rule{"gya", L"ぎゃ"}, Rule{"gyu", L"ぎゅ"}, Rule{"gyo", L"ぎょ"},
    Rule{"za", L"ざ"}, Rule{"ji", L"じ"}, Rule{"zi", L"じ"}, Rule{"zu", L"ず"}, Rule{"ze", L"ぜ"}, Rule{"zo", L"ぞ"},
    Rule{"ja", L"じゃ"}, Rule{"ju", L"じゅ"}, Rule{"jo", L"じょ"},
    Rule{"da", L"だ"}, Rule{"di", L"ぢ"}, Rule{"du", L"づ"}, Rule{"de", L"で"}, Rule{"do", L"ど"},
    Rule{"ba", L"ば"}, Rule{"bi", L"び"}, Rule{"bu", L"ぶ"}, Rule{"be", L"べ"}, Rule{"bo", L"ぼ"},
    Rule{"bya", L"びゃ"}, Rule{"byu", L"びゅ"}, Rule{"byo", L"びょ"},
    Rule{"pa", L"ぱ"}, Rule{"pi", L"ぴ"}, Rule{"pu", L"ぷ"}, Rule{"pe", L"ぺ"}, Rule{"po", L"ぽ"},
    Rule{"pya", L"ぴゃ"}, Rule{"pyu", L"ぴゅ"}, Rule{"pyo", L"ぴょ"},
    Rule{"fa", L"ふぁ"}, Rule{"fi", L"ふぃ"}, Rule{"fe", L"ふぇ"}, Rule{"fo", L"ふぉ"},
    Rule{"va", L"ゔぁ"}, Rule{"vi", L"ゔぃ"}, Rule{"vu", L"ゔ"}, Rule{"ve", L"ゔぇ"}, Rule{"vo", L"ゔぉ"},
    Rule{"xa", L"ぁ"}, Rule{"xi", L"ぃ"}, Rule{"xu", L"ぅ"}, Rule{"xe", L"ぇ"}, Rule{"xo", L"ぉ"},
    Rule{"xya", L"ゃ"}, Rule{"xyu", L"ゅ"}, Rule{"xyo", L"ょ"}, Rule{"xtu", L"っ"}, Rule{"ltsu", L"っ"},
    Rule{"nn", L"ん"}, Rule{"n'", L"ん"}};

const std::unordered_map<std::string, std::wstring>& ExactRules() {
  static const auto rules = [] {
    std::unordered_map<std::string, std::wstring> result;
    for (const auto& [roman, kana] : kRules)
      result.emplace(std::string(roman), std::wstring(kana));
    return result;
  }();
  return rules;
}

const std::unordered_set<std::string>& Prefixes() {
  static const auto prefixes = [] {
    std::unordered_set<std::string> result;
    result.emplace();
    for (const auto& [roman, unused] : kRules) {
      (void)unused;
      for (size_t length = 1; length <= roman.size(); ++length)
        result.emplace(roman.substr(0, length));
    }
    return result;
  }();
  return prefixes;
}

bool IsConsonant(char value) {
  return value >= 'a' && value <= 'z' && value != 'a' && value != 'i' &&
         value != 'u' && value != 'e' && value != 'o' && value != 'n';
}

}  // namespace

std::wstring RealtimeFrontend::Katakana(const std::wstring& text) {
  std::wstring result = text;
  for (wchar_t& value : result) {
    if (value >= L'ぁ' && value <= L'ゖ') value += 0x60;
  }
  return result;
}

EngineState RealtimeFrontend::Snapshot(bool terminal) const {
  EngineState state;
  state.mode = preedit_ && !terminal ? L"preedit"
             : latin_ ? L"latin"
             : wide_latin_ ? L"wide-latin"
             : katakana_ ? L"katakana" : L"hiragana";
  state.composition_start = preedit_ && !terminal ? 0 : -1;
  state.text = preedit_ && !terminal ? L"▽" + text_ : text_;
  state.pending_romaji.assign(pending_.begin(), pending_.end());
  return state;
}

std::optional<EngineState> RealtimeFrontend::Feed(char32_t key) {
  if (key > 0x7f || !std::isprint(static_cast<unsigned char>(key)))
    return std::nullopt;
  return FeedAscii(static_cast<char>(key), true);
}

std::optional<EngineState> RealtimeFrontend::FeedAscii(char key, bool record) {
  const bool upper = key >= 'A' && key <= 'Z';
  const char lower = static_cast<char>(std::tolower(static_cast<unsigned char>(key)));

  if (record) raw_keys_.push_back(static_cast<char32_t>(key));
  if (!continuous_preedit_ && !preedit_ && pending_.empty() && key == 'L') {
    wide_latin_ = true;
    latin_ = false;
    raw_keys_.clear();
    return Snapshot();
  }
  if (!continuous_preedit_ && !preedit_ && pending_.empty() && key == 'l') {
    latin_ = true;
    wide_latin_ = false;
    raw_keys_.clear();
    return Snapshot();
  }
  if (latin_) return std::nullopt;
  if (wide_latin_) {
    EngineState state = Snapshot(true);
    state.text = key == ' ' ? std::wstring(1, L'　')
                            : std::wstring(1, static_cast<wchar_t>(
                                  static_cast<unsigned char>(key) + 0xfee0));
    raw_keys_.clear();
    return state;
  }
  if (!continuous_preedit_ && !preedit_ && pending_.empty() &&
      (key == 'q' || key == 'Q')) {
    katakana_ = !katakana_;
    if (record) raw_keys_.clear();
    return Snapshot();
  }
  if (continuous_preedit_ && !preedit_) {
    preedit_ = true;
  } else if (upper && !preedit_) {
    preedit_ = true;
  } else if (!continuous_preedit_ && upper && preedit_ &&
             !okuri_started_ && !text_.empty()) {
    text_ += L'*';
    okuri_started_ = true;
  }

  if (lower < 'a' || lower > 'z') {
    if (!pending_.empty()) {
      text_.append(pending_.begin(), pending_.end());
      pending_.clear();
    }
    switch (key) {
      case '.': text_ += L"。"; break;
      case ',': text_ += L"、"; break;
      case '-': text_ += L"ー"; break;
      case '[': text_ += L"「"; break;
      case ']': text_ += L"」"; break;
      default:
        text_.push_back(static_cast<wchar_t>(static_cast<unsigned char>(key)));
        break;
    }
  } else {
    std::string next = pending_ + lower;
    if (next.size() == 2 && next[0] == next[1] && IsConsonant(next[0])) {
      text_ += katakana_ ? L"ッ" : L"っ";
      next.erase(next.begin());
    }

    const auto exact = ExactRules().find(next);
    if (exact != ExactRules().end()) {
      text_ += katakana_ ? Katakana(exact->second) : exact->second;
      pending_.clear();
    } else if (Prefixes().contains(next)) {
      pending_ = std::move(next);
    } else if (next.size() > 1 && next[0] == 'n') {
      text_ += katakana_ ? L"ン" : L"ん";
      pending_.clear();
      return FeedAscii(lower, false);
    } else {
      text_.push_back(static_cast<wchar_t>(static_cast<unsigned char>(next[0])));
      pending_ = next.substr(1);
    }
  }

  EngineState state = Snapshot();
  if (!preedit_ && pending_.empty()) {
    text_.clear();
    raw_keys_.clear();
  }
  return state;
}

void RealtimeFrontend::RebuildPreedit() {
  const std::u32string keys = raw_keys_;
  preedit_ = false;
  okuri_started_ = false;
  text_.clear();
  pending_.clear();
  raw_keys_.clear();
  for (const char32_t key : keys) FeedAscii(static_cast<char>(key), true);
}

std::optional<EngineState> RealtimeFrontend::Backspace() {
  if (!composing() || raw_keys_.empty()) return std::nullopt;
  raw_keys_.pop_back();
  if (preedit_) {
    RebuildPreedit();
    if (raw_keys_.empty()) Reset();
    return Snapshot();
  }
  if (!pending_.empty()) pending_.pop_back();
  return Snapshot();
}

std::optional<EngineState> RealtimeFrontend::Commit() {
  if (!composing()) return std::nullopt;
  if (pending_ == "n") text_ += katakana_ ? L"ン" : L"ん";
  else text_.append(pending_.begin(), pending_.end());
  pending_.clear();
  EngineState state = Snapshot(true);
  Reset();
  return state;
}

std::optional<EngineState> RealtimeFrontend::Quit() {
  if (!composing()) return std::nullopt;
  EngineState state;
  state.mode = katakana_ ? L"katakana" : L"hiragana";
  state.composition_start = -1;
  Reset();
  return state;
}

EngineState RealtimeFrontend::RestorePreedit() const { return Snapshot(); }

std::optional<EngineState> RealtimeFrontend::ToKatakana() {
  if (!preedit_) return std::nullopt;
  text_ = Katakana(text_);
  katakana_ = true;
  return Snapshot();
}

std::optional<EngineState> RealtimeFrontend::CommitKatakana() {
  if (!preedit_) return std::nullopt;
  if (pending_ == "n") text_ += L"ん";
  else text_.append(pending_.begin(), pending_.end());
  pending_.clear();
  text_ = Katakana(text_);
  EngineState state = Snapshot(true);
  Reset();
  return state;
}

EngineState RealtimeFrontend::ToHiragana() {
  if (preedit_) text_ = Katakana(text_);  // normalized below when needed
  for (wchar_t& value : text_) {
    if (value >= L'ァ' && value <= L'ヶ') value -= 0x60;
  }
  katakana_ = false;
  latin_ = false;
  wide_latin_ = false;
  return Snapshot();
}

void RealtimeFrontend::Reset() {
  preedit_ = false;
  okuri_started_ = false;
  text_.clear();
  pending_.clear();
  raw_keys_.clear();
}

}  // namespace ddskk
