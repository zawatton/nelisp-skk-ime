#include "realtime_frontend.h"
#include <cstdio>
#include <string>
int main() {
  int failures = 0;
  for (bool continuous : {false, true}) {
    for (const auto& keys : {U"", U"k", U"N", U"Na", U"Nai"}) {
      ddskk::RealtimeFrontend frontend;
      frontend.SetContinuousPreedit(continuous);
      for (char32_t key : std::u32string(keys)) frontend.Feed(key);
      const std::wstring expected = std::u32string(keys) == U"k" ? L"k" :
          std::u32string(keys) == U"N" ? L"ん" :
          std::u32string(keys) == U"Na" ? L"な" :
          std::u32string(keys) == U"Nai" ? L"ない" : L"";
      auto latin = frontend.Feed(U'l');
      bool pass = latin && latin->mode == L"latin" &&
          latin->text == expected &&
          latin->pending_romaji.empty() && latin->composition_start == -1 &&
          frontend.raw_keys().empty() && !frontend.composing() && frontend.latin();
      if (!pass) ++failures;
      if (frontend.Feed(U'l') || frontend.Feed(U'a')) ++failures;
    }
  }
  ddskk::RealtimeFrontend custom;
  custom.SetRules({{"la", "", L"ぁ", L"ァ", L""}});
  auto latin = custom.Feed(U'l');
  if (!latin || latin->mode != L"latin") ++failures;
  ddskk::RealtimeFrontend upper;
  auto wide = upper.Feed(U'L');
  if (!wide || wide->mode != L"wide-latin") ++failures;
  ddskk::RealtimeFrontend upper_prefix;
  upper_prefix.Feed(U'N');
  const auto upper_pending = upper_prefix.Feed(U'L');
  if (upper_prefix.latin()) ++failures;
  const auto old_upper = upper_prefix.RestorePreedit();
  std::printf("upper-prefix present=%d preedit=%d latin=%d text=%zu pending=%zu raw=%zu\n",
      upper_pending.has_value(), upper_prefix.preedit(), upper_prefix.latin(),
      old_upper.text.size(), old_upper.pending_romaji.size(), upper_prefix.raw_keys().size());
  ddskk::RealtimeFrontend carry;
  carry.SetRules({{"n", "l", L"ん", L"ン", L"", L""},
                  {"ll", "", L"ぁ", L"ァ", L"", L""}});
  carry.Feed(U'N');
  const auto carried = carry.Feed(U'L');
  if (carry.latin()) ++failures;
  const auto old_carry = carry.RestorePreedit();
  std::printf("upper-carry present=%d preedit=%d latin=%d text=%zu pending=%zu raw=%zu\n",
      carried.has_value(), carry.preedit(), carry.latin(), old_carry.text.size(),
      old_carry.pending_romaji.size(), carry.raw_keys().size());
  std::printf("force-latin-frontend cases=14 failures=%d\n", failures);
  return failures ? 1 : 0;
}
