#include "realtime_frontend.h"

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>

#define CHECK(condition)                                                \
  do {                                                                  \
    if (!(condition)) {                                                 \
      std::fprintf(stderr, "CHECK failed at line %d: %s\n", __LINE__, \
                   #condition);                                        \
      return __LINE__;                                                  \
    }                                                                   \
  } while (false)

std::wstring Decode(const std::string& hex) {
  if (hex == "-") return {};
  std::wstring result;
  for (size_t i = 0; i < hex.size(); i += 6)
    result.push_back(static_cast<wchar_t>(std::strtoul(hex.substr(i, 6).c_str(), nullptr, 16)));
  return result;
}

int main(int argc, char** argv) {
  if (argc >= 2) {
    const bool fallback = argc == 3 && std::string(argv[2]) == "--fallback";
    std::ifstream fixture(argv[1]);
    CHECK(fixture.good());
    std::string line;
    std::getline(fixture, line);
    CHECK(line.starts_with("RULES 1 "));
    std::vector<ddskk::RomajiRule> rules;
    std::istringstream records(line.substr(8));
    for (std::string record; records >> record;) {
      std::vector<std::wstring> fields;
      size_t start = 0;
      for (;;) {
        const size_t end = record.find(':', start);
        fields.push_back(Decode(record.substr(start, end - start)));
        if (end == std::string::npos) break;
        start = end + 1;
      }
      CHECK(fields.size() == 5);
      rules.push_back({std::string(fields[0].begin(), fields[0].end()),
                       std::string(fields[1].begin(), fields[1].end()),
                       fields[2], fields[3], fields[4]});
    }
    size_t tested = 0;
    while (std::getline(fixture, line)) {
      std::istringstream input(line);
      std::string key, tag, mode, text, pending;
      int cursor, start;
      CHECK(static_cast<bool>(input >> key >> tag >> mode >> cursor >> start >> text >> pending));
      CHECK(tag == "STATE");
      ddskk::RealtimeFrontend converter;
      if (!fallback) converter.SetRules(rules);
      std::wstring output;
      std::optional<ddskk::EngineState> state;
      for (const wchar_t ch : Decode(key)) {
        state = converter.Feed(ch);
        CHECK(state);
        if (state->pending_romaji.empty()) output += state->text;
      }
      if (state && !state->pending_romaji.empty()) output += state->text;
      if (output != Decode(text) || state->pending_romaji != Decode(pending)) {
        std::fprintf(stderr, "PARITY failed key=%s expected_text=%s pending=%s\n",
                     key.c_str(), text.c_str(), pending.c_str());
        return 1;
      }
      ++tested;
    }
    size_t expected = 0;
    for (const auto& rule : rules) if (rule.command.empty()) ++expected;
    CHECK(tested == 2 * expected + 9 && expected > 200);
    for (const auto& sample : std::vector<std::pair<std::string, std::wstring>>{
        {"tya", L"ちゃ"}, {"tyu", L"ちゅ"}, {"tyo", L"ちょ"},
        {"tta", L"った"}, {"nn", L"ん"}, {"n'", L"ん"},
        {"nka", L"んか"}, {"z.", L"…"}, {"z/", L"・"}}) {
      ddskk::RealtimeFrontend converter;
      converter.SetRules(rules);
      std::wstring output;
      for (const char ch : sample.first) {
        auto state = converter.Feed(ch);
        CHECK(state);
        if (state->pending_romaji.empty()) output += state->text;
      }
      CHECK(output == sample.second);
    }
    std::printf("ROMAJI PARITY PASS rules=%zu modes=2 engine_probes=%zu samples=9\n", expected, tested);
    return 0;
  }
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
