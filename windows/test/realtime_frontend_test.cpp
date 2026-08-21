#include "realtime_frontend.h"

#include <cstdio>

#define CHECK(condition)                                                \
  do {                                                                  \
    if (!(condition)) {                                                 \
      std::fprintf(stderr, "CHECK failed at line %d: %s\n", __LINE__, \
                   #condition);                                        \
      return __LINE__;                                                  \
    }                                                                   \
  } while (false)

int main() {
  ddskk::RealtimeFrontend frontend;

  auto state = frontend.Feed(U'k');
  CHECK(state && state->text.empty() && state->pending_romaji == L"k");
  state = frontend.Feed(U'a');
  CHECK(state && state->text == L"か" && state->pending_romaji.empty());
  CHECK(!frontend.composing());

  frontend.Feed(U'K');
  state = frontend.Feed(U'a');
  CHECK(state && state->mode == L"preedit" && state->text == L"▽か");
  frontend.Feed(U'n');
  frontend.Feed(U'a');
  state = frontend.Feed(U'S');
  CHECK(state && state->text == L"▽かな*" && state->pending_romaji == L"s");
  frontend.Feed(U'i');
  state = frontend.Feed(U'm');
  CHECK(state && state->text == L"▽かな*し" && state->pending_romaji == L"m");
  state = frontend.Backspace();
  CHECK(state && state->text == L"▽かな*し" && state->pending_romaji.empty());
  state = frontend.RestorePreedit();
  CHECK(state && state->mode == L"preedit" && state->text == L"▽かな*し");

  state = frontend.ToKatakana();
  CHECK(state && state->text == L"▽カナ*シ");
  state = frontend.Quit();
  CHECK(state && state->text.empty() && !frontend.composing());

  ddskk::RealtimeFrontend q_conversion;
  q_conversion.Feed(U'K');
  q_conversion.Feed(U'a');
  state = q_conversion.CommitKatakana();
  CHECK(state && state->text == L"カ" && state->composition_start == -1);
  CHECK(!q_conversion.composing() && !q_conversion.katakana());

  frontend.Feed(U'n');
  state = frontend.Commit();
  CHECK(state && state->text == L"ン" && state->composition_start == -1);

  ddskk::RealtimeFrontend hiragana;
  hiragana.Feed(U'k');
  state = hiragana.Feed(U'k');
  CHECK(state && state->text == L"っ" && state->pending_romaji == L"k");
  state = hiragana.Feed(U'a');
  CHECK(state && state->text == L"っか");

  state = hiragana.Feed(U'l');
  CHECK(state && state->mode == L"latin" && hiragana.latin());
  state = hiragana.Feed(U'a');
  CHECK(!state);
  state = hiragana.ToHiragana();
  CHECK(state && state->mode == L"hiragana" && !hiragana.latin());

  state = hiragana.Feed(U'L');
  CHECK(state && state->mode == L"wide-latin" && hiragana.wide_latin());
  state = hiragana.Feed(U'a');
  CHECK(state && state->text == L"ａ" && state->composition_start == -1);
  state = hiragana.Feed(U' ');
  CHECK(state && state->text == L"　");
  state = hiragana.ToHiragana();
  CHECK(state && state->mode == L"hiragana" && !hiragana.wide_latin());

  state = hiragana.Feed(U'.');
  CHECK(state && state->text == L"。");
  state = hiragana.Feed(U',');
  CHECK(state && state->text == L"、");
  state = hiragana.Feed(U'-');
  CHECK(state && state->text == L"ー");

  ddskk::RealtimeFrontend continuous;
  continuous.SetContinuousPreedit(true);
  state = continuous.Feed(U'k');
  CHECK(state && state->mode == L"preedit" && state->text == L"▽" &&
        state->pending_romaji == L"k");
  state = continuous.Feed(U'a');
  CHECK(state && state->text == L"▽か" && continuous.composing());
  state = continuous.Feed(U'q');
  CHECK(state && state->text == L"▽かq" && state->pending_romaji.empty() &&
        !continuous.katakana());
  state = continuous.Backspace();
  CHECK(state && state->text == L"▽か" && state->pending_romaji.empty());
  state = continuous.Commit();
  CHECK(state && state->text == L"か" && state->composition_start == -1);
  return 0;
}
