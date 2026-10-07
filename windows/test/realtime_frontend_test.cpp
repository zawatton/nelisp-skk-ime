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

std::optional<std::vector<ddskk::RomajiRule>> ReadRules(std::istream& input) {
  std::string line;
  if (!std::getline(input, line) || !line.starts_with("RULES 1 ")) return std::nullopt;
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
    if (fields.size() != 5 && fields.size() != 6) return std::nullopt;
    rules.push_back({std::string(fields[0].begin(), fields[0].end()),
                     std::string(fields[1].begin(), fields[1].end()),
                     fields[2], fields[3], fields[4],
                     fields.size() == 6 ? fields[5] : std::wstring{}});
  }
  return rules;
}

int main(int argc, char** argv) {
  if (argc == 4 && std::string(argv[2]) == "--q-oracle") {
    std::ifstream fixture(argv[1]);
    CHECK(fixture.good());
    std::ifstream rules_file(argv[3]);
    const auto rules = ReadRules(rules_file);
    CHECK(rules && !rules->empty());
    std::string keys, mode, expected;
    size_t tested = 0;
    while (fixture >> keys >> mode >> expected) {
      ddskk::RealtimeFrontend converter;
      converter.SetRules(*rules);
      for (char key : keys) CHECK(converter.Feed(key));
      CHECK(converter.CanCommitKatakanaReading());
      const auto state = converter.CommitKatakana();
      CHECK(state && state->text == Decode(expected) &&
            state->mode == std::wstring(mode.begin(), mode.end()) &&
            state->composition_start == -1 && state->pending_romaji.empty());
      CHECK(!converter.composing() && converter.raw_keys().empty());
      ++tested;
    }
    CHECK(fixture.eof() && tested == 8);
    std::printf("Q STOCK PARITY PASS readings=%zu\n", tested);
    return 0;
  }
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
  CHECK(q_conversion.CanCommitKatakanaReading());
  state = q_conversion.CommitKatakana();
  CHECK(state && state->text == L"カ" && state->composition_start == -1);
  CHECK(!q_conversion.composing() && !q_conversion.katakana());

  for (const auto& keys : {"K", "Kan", "KaT", "qKana", "Kanaq", "Ka1"}) {
    ddskk::RealtimeFrontend unresolved;
    for (char key : std::string(keys)) unresolved.Feed(key);
    CHECK(!unresolved.CanCommitKatakanaReading());
  }
  ddskk::RealtimeFrontend custom_q;
  custom_q.SetRules({{"ka", "", L"か", L"カ", L""},
                     {"q", "", L"く", L"ク", L""}});
  custom_q.Feed(U'K'); custom_q.Feed(U'a');
  CHECK(!custom_q.CanCommitKatakanaReading());
  custom_q.SetRules({{"ka", "", L"か", L"カ", L""},
                     {"q", "", L"", L"", L"custom-command"}});
  CHECK(!custom_q.CanCommitKatakanaReading());

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
  CHECK(!continuous.CanCommitKatakanaReading());
  state = continuous.Feed(U'q');
  CHECK(state && state->text == L"▽かq" && state->pending_romaji.empty() &&
        !continuous.katakana());
  state = continuous.Backspace();
  CHECK(state && state->text == L"▽か" && state->pending_romaji.empty());
  state = continuous.Commit();
  CHECK(state && state->text == L"か" && state->composition_start == -1);
  ddskk::RealtimeFrontend late_rules;
  late_rules.Feed(U'N'); late_rules.Feed(U'a'); late_rules.Feed(U'i');
  const std::vector<ddskk::RomajiRule> published{
      {"na", "", L"な", L"ナ", L""}, {"i", "", L"い", L"イ", L""},
      {".", "", L"。", L"。", L""}, {",", "", L"、", L"、", L""}};
  CHECK(late_rules.preview_reading() == L"ない");
  CHECK(late_rules.TrySetRulesForReading(published));
  auto changed_rules = published; changed_rules[0].hiragana = L"ぬ";
  CHECK(!late_rules.TrySetRulesForReading(changed_rules));
  CHECK(late_rules.preview_reading() == L"ない");
  ddskk::RealtimeFrontend cyclic;
  cyclic.SetRules({ddskk::RomajiRule{"a", "a", L"あ", L"ア", L""}});
  CHECK(cyclic.Feed(U'a').has_value());
  CHECK(!cyclic.Feed(U'b').has_value());
  return 0;
}
