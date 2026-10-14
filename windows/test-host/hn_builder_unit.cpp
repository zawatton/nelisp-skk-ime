// Pure C++ HN builder tests. No process, registry, Windows, or Lisp state is used.
#include "../../windows/host/hn_builder.h"

#include <algorithm>
#include <cstdio>
#include <fstream>
#include <iterator>
#include <limits>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace {
using namespace hn_builder;

struct Checks {
  int checks = 0;
  int failures = 0;

  void Check(bool condition, const char* label) {
    ++checks;
    if (!condition) {
      ++failures;
      std::printf("FAIL check=%d label=%s\n", checks, label);
    }
  }
};

std::string Hex(std::string_view bytes) {
  static constexpr char digits[] = "0123456789abcdef";
  std::string result;
  result.reserve(bytes.size() * 2);
  for (unsigned char byte : bytes) {
    result.push_back(digits[byte >> 4]);
    result.push_back(digits[byte & 15]);
  }
  return result;
}

std::string Bom() { return std::string("\xef\xbb\xbf", 3); }

void SetLe(std::string& bytes, size_t offset, uint64_t value, size_t width) {
  for (size_t i = 0; i < width; ++i) {
    bytes[offset + i] = static_cast<char>(value & 0xff);
    value >>= 8;
  }
}

std::string RawFrame(std::string_view magic, uint16_t status, uint32_t flags,
                     uint32_t count, std::string payload) {
  std::string bytes(magic);
  PutLe(bytes, kHeader - 8 + payload.size(), 4);
  PutLe(bytes, kVersion, 2);
  PutLe(bytes, status, 2);
  PutLe(bytes, 1, 8);
  PutLe(bytes, 2, 4);
  PutLe(bytes, 3, 4);
  PutLe(bytes, flags, 4);
  PutLe(bytes, count, 4);
  PutLe(bytes, payload.size(), 4);
  bytes += payload;
  return bytes;
}

Maps Reference(const std::vector<std::string>& files) {
  Maps maps(files.size());
  for (size_t i = 0; i < files.size(); ++i) ParseFileReference(files[i], maps[i]);
  return maps;
}

std::vector<std::string> Chunks(std::string_view contents, size_t width) {
  std::vector<std::string> chunks;
  for (size_t at = 0; at < contents.size(); at += width) {
    chunks.emplace_back(contents.substr(at, std::min(width, contents.size() - at)));
  }
  if (chunks.empty()) chunks.emplace_back();
  return chunks;
}

class FakeInput final : public Input {
 public:
  explicit FakeInput(std::vector<std::vector<std::string>> chunks)
      : chunks_(std::move(chunks)), positions_(chunks_.size()) {}

  size_t FileCount() const override { return chunks_.size(); }

  bool Read(size_t file, std::string& chunk, bool& eof) override {
    ++reads_;
    if (fail_read_ != 0 && reads_ == fail_read_) return false;
    if (file >= chunks_.size() || positions_[file] >= chunks_[file].size()) return false;
    chunk = chunks_[file][positions_[file]++];
    eof = positions_[file] == chunks_[file].size();
    return true;
  }

  size_t fail_read_ = 0;

 private:
  std::vector<std::vector<std::string>> chunks_;
  std::vector<size_t> positions_;
  size_t reads_ = 0;
};

enum class Fault {
  None,
  Start,
  ReadyText,
  ReadyTimeout,
  ReadyTransport,
  Timeout,
  Transport,
  Truncate,
  Echo,
  EchoGeneration,
  EchoFile,
  Status,
  ExtraRecord,
  CorruptRecord,
  DropLast,
};

class FakeChannel final : public Channel {
 public:
  bool Start() override {
    ++starts;
    return fault != Fault::Start;
  }

  IoResult ReadReady(std::string& ready, uint32_t timeout_ms) override {
    ready_timeouts.push_back(timeout_ms);
    if (fault == Fault::ReadyTimeout) return IoResult::Timeout;
    if (fault == Fault::ReadyTransport) return IoResult::Transport;
    ready = fault == Fault::ReadyText ? "HNB READY version=2\n"
                                      : std::string(kReady);
    return IoResult::Ok;
  }

  IoResult Exchange(std::string_view request_wire, std::string& reply_wire,
                    uint32_t timeout_ms) override {
    timeouts.push_back(timeout_ms);
    ++exchanges;
    if (exchanges == fault_exchange) {
      if (fault == Fault::Timeout) return IoResult::Timeout;
      if (fault == Fault::Transport) return IoResult::Transport;
    }
    Request request;
    if (!DecodeRequest(request_wire, request)) return IoResult::Transport;
    requests.push_back(request);
    Reply reply;
    reply.generation = request.generation;
    reply.file_index = request.file_index;
    reply.batch_seq = request.batch_seq;
    for (const auto& line : request.lines) {
      Record record;
      if (ParseReferenceLine(line, record)) reply.records.push_back(std::move(record));
    }
    if (fault == Fault::DropLast && !reply.records.empty()) reply.records.pop_back();
    if (fault == Fault::CorruptRecord && !reply.records.empty()) {
      reply.records.front().tail += "corrupt/";
    }
    if (fault == Fault::ExtraRecord) reply.records.push_back({"extra", "/x/"});
    if (fault == Fault::Echo) ++reply.batch_seq;
    if (fault == Fault::EchoGeneration) ++reply.generation;
    if (fault == Fault::EchoFile) ++reply.file_index;
    if (fault == Fault::Status) {
      reply.status = 1;
      reply.records.clear();
    }
    reply_wire = EncodeReply(reply);
    if (fault == Fault::Truncate && !reply_wire.empty()) reply_wire.pop_back();
    return IoResult::Ok;
  }

  void Retire() noexcept override { ++retires; }

  Fault fault = Fault::None;
  size_t fault_exchange = 1;
  int starts = 0;
  int retires = 0;
  size_t exchanges = 0;
  std::vector<uint32_t> timeouts;
  std::vector<uint32_t> ready_timeouts;
  std::vector<Request> requests;
};

ReferenceLoader Loader(std::vector<std::string> files, int* calls = nullptr) {
  return [files = std::move(files), calls]() {
    if (calls != nullptr) ++*calls;
    return Reference(files);
  };
}

void TestCodec(Checks& t) {
  t.Check(kVersion == 1 && kHeader == 40 && kPayload == 262144 &&
              kReplyPayload == 524288 && kLine == 65536 &&
              kBatchTimeoutMs == 10000 && kReadyTimeoutMs == 65000 &&
              kReady == "HNB READY version=1\n",
          "constants");

  Request request;
  request.generation = 0x0102030405060708ULL;
  request.file_index = 0x11223344;
  request.batch_seq = 0x55667788;
  request.flags = kFirstLine;
  request.lines = {std::string("a\0 /A\xff/", 8), " /"};
  const std::string request_wire = EncodeRequest(request);
  Request decoded_request;
  t.Check(!request_wire.empty() && DecodeRequest(request_wire, decoded_request) &&
              decoded_request.generation == request.generation &&
              decoded_request.file_index == request.file_index &&
              decoded_request.batch_seq == request.batch_seq &&
              decoded_request.flags == request.flags &&
              decoded_request.lines == request.lines,
          "request-roundtrip-opaque");
  t.Check(request_wire.size() == kHeader + 4 + 8 + 4 + 2,
          "request-wire-size");

  Reply reply;
  reply.generation = request.generation;
  reply.file_index = request.file_index;
  reply.batch_seq = request.batch_seq;
  reply.records = {{std::string("a\0", 2), std::string("/A\xff/", 4)}, {"", "/"}};
  const std::string reply_wire = EncodeReply(reply);
  Reply decoded_reply;
  t.Check(!reply_wire.empty() && DecodeReply(reply_wire, decoded_reply) &&
              decoded_reply.generation == reply.generation &&
              decoded_reply.records == reply.records,
          "reply-roundtrip-opaque");

  Request unchanged_request;
  unchanged_request.generation = 99;
  unchanged_request.file_index = 7;
  unchanged_request.batch_seq = 8;
  unchanged_request.flags = kFirstLine;
  unchanged_request.lines = {"sentinel"};
  Reply unchanged_reply;
  unchanged_reply.status = 2;
  unchanged_reply.generation = 98;
  unchanged_reply.file_index = 6;
  unchanged_reply.batch_seq = 5;
  unchanged_reply.records = {{"sentinel", "/keep/"}};
  auto reject_request = [&](std::string_view wire, const char* label) {
    Request out = unchanged_request;
    t.Check(!DecodeRequest(wire, out) && out.generation == 99 &&
                out.file_index == 7 && out.batch_seq == 8 &&
                out.flags == kFirstLine &&
                out.lines == std::vector<std::string>{"sentinel"}, label);
  };
  auto reject_reply = [&](std::string_view wire, const char* label) {
    Reply out = unchanged_reply;
    t.Check(!DecodeReply(wire, out) && out.status == 2 && out.generation == 98 &&
                out.file_index == 6 && out.batch_seq == 5 &&
                out.records == std::vector<Record>{{"sentinel", "/keep/"}}, label);
  };
  t.Check(!DecodeRequest("bad", unchanged_request) &&
              unchanged_request.generation == 99 && unchanged_request.file_index == 7 &&
              unchanged_request.batch_seq == 8 && unchanged_request.flags == kFirstLine &&
              unchanged_request.lines == std::vector<std::string>{"sentinel"},
          "request-failure-unchanged");
  t.Check(!DecodeReply("bad", unchanged_reply) && unchanged_reply.status == 2 &&
              unchanged_reply.generation == 98 && unchanged_reply.file_index == 6 &&
              unchanged_reply.batch_seq == 5 &&
              unchanged_reply.records == std::vector<Record>{{"sentinel", "/keep/"}},
          "reply-failure-unchanged");

  Request invalid = request;
  invalid.flags = 2;
  t.Check(EncodeRequest(invalid).empty(), "request-unknown-flags");
  invalid = request;
  invalid.lines = {std::string(kLine + 1, 'x')};
  t.Check(EncodeRequest(invalid).empty(), "request-overlong-line");
  invalid.lines = {"a\nb"};
  t.Check(EncodeRequest(invalid).empty(), "request-lf");
  invalid.lines.assign(kLine + 1, std::string());
  t.Check(EncodeRequest(invalid).empty(), "request-count");
  invalid.lines.assign(4, std::string(kLine, 'x'));
  t.Check(EncodeRequest(invalid).empty(), "request-payload-over");
  invalid.lines.assign(4, std::string(kLine - 4, 'x'));
  const std::string exact_request = EncodeRequest(invalid);
  t.Check(exact_request.size() == kHeader + kPayload, "request-payload-exact");

  Reply invalid_reply = reply;
  invalid_reply.status = 1;
  t.Check(EncodeReply(invalid_reply).empty(), "reply-error-has-records");
  invalid_reply = reply;
  invalid_reply.status = 3;
  invalid_reply.records.clear();
  t.Check(EncodeReply(invalid_reply).empty(), "reply-status-range");
  const std::vector<Record> bad_records = {
      {"a b", "/x/"}, {"a\rb", "/x/"}, {"a\nb", "/x/"},
      {"a", ""}, {"a", "x/"}, {"a", "/x\r/"}, {"a", "/x\n/"},
      {std::string(kLine, 'a'), "/"}};
  for (const auto& record : bad_records) {
    invalid_reply = reply;
    invalid_reply.records = {record};
    t.Check(EncodeReply(invalid_reply).empty(), "reply-record-shape");
  }
  invalid_reply = reply;
  invalid_reply.records.clear();
  for (int i = 0; i < 7; ++i) {
    invalid_reply.records.push_back({std::string(1, static_cast<char>('a' + i)),
                                     "/" + std::string(kLine - 2, 'x')});
  }
  invalid_reply.records.push_back({"z", "/" + std::string(65470, 'y')});
  const std::string exact_reply = EncodeReply(invalid_reply);
  t.Check(exact_reply.size() == kHeader + kReplyPayload, "reply-payload-exact");
  invalid_reply.records.back().tail.push_back('y');
  t.Check(EncodeReply(invalid_reply).empty(), "reply-payload-over");

  auto corrupt_request = request_wire;
  const std::vector<size_t> request_offsets = {0, 4, 8, 10, 28, 32, 36, 40};
  for (size_t offset : request_offsets) {
    auto value = corrupt_request;
    value[offset] = static_cast<char>(value[offset] ^ 0x7f);
    reject_request(value, "request-header-reject-unchanged");
  }
  for (size_t size = 0; size < request_wire.size(); ++size) {
    reject_request(std::string_view(request_wire).substr(0, size),
                   "request-truncation-unchanged");
  }
  auto request_with_trailing = request_wire + "x";
  Request request_out;
  reject_request(request_with_trailing, "request-trailing-unchanged");

  auto request_count_over = request_wire;
  SetLe(request_count_over, 32, kLine + 1, 4);
  reject_request(request_count_over, "request-count-decode-unchanged");
  std::string oversized_payload(kPayload + 1, 'x');
  reject_request(RawFrame("HNBQ", 0, 0, 0, oversized_payload),
                 "request-payload-limit-decode-unchanged");
  std::string lf_payload;
  PutLe(lf_payload, 3, 4);
  lf_payload += "a\nb";
  reject_request(RawFrame("HNBQ", 0, 0, 1, lf_payload),
                 "request-lf-decode-unchanged");
  std::string long_length;
  PutLe(long_length, kLine + 1, 4);
  reject_request(RawFrame("HNBQ", 0, 0, 1, long_length),
                 "request-length-decode-unchanged");
  auto late_request = request_wire;
  SetLe(late_request, 52, kLine + 1, 4);
  reject_request(late_request, "request-late-second-line-unchanged");
  auto counted_request = request_wire;
  counted_request.append(4, '\0');
  SetLe(counted_request, 4, counted_request.size() - 8, 4);
  SetLe(counted_request, 32, request.lines.size() + 1, 4);
  SetLe(counted_request, 36, counted_request.size() - kHeader, 4);
  t.Check(DecodeRequest(counted_request, request_out) &&
              request_out.lines.size() == request.lines.size() + 1 &&
              request_out.lines.back().empty(),
          "request-counted-extra-field");

  const std::vector<size_t> reply_offsets = {0, 4, 8, 10, 28, 32, 36, 40, 46};
  for (size_t offset : reply_offsets) {
    auto value = reply_wire;
    value[offset] = static_cast<char>(value[offset] ^ 0x7f);
    reject_reply(value, "reply-header-reject-unchanged");
  }
  for (size_t size = 0; size < reply_wire.size(); ++size) {
    reject_reply(std::string_view(reply_wire).substr(0, size),
                 "reply-truncation-unchanged");
  }
  Reply status_reply;
  status_reply.status = 1;
  status_reply.generation = 4;
  auto status_wire = EncodeReply(status_reply);
  t.Check(!status_wire.empty() && DecodeReply(status_wire, decoded_reply) &&
              decoded_reply.status == 1 && decoded_reply.records.empty(),
          "reply-error-shape");
  status_wire[36] = 1;
  reject_reply(status_wire, "reply-error-payload-unchanged");

  auto reply_count_over = reply_wire;
  SetLe(reply_count_over, 32, kLine + 1, 4);
  reject_reply(reply_count_over, "reply-count-decode-unchanged");
  reject_reply(RawFrame("HNBR", 0, 0, 0,
                        std::string(kReplyPayload + 1, 'x')),
               "reply-payload-limit-decode-unchanged");
  for (const auto& record : bad_records) {
    std::string payload;
    PutLe(payload, record.key.size(), 4);
    payload += record.key;
    PutLe(payload, record.tail.size(), 4);
    payload += record.tail;
    reject_reply(RawFrame("HNBR", 0, 0, 1, std::move(payload)),
                 "reply-record-shape-decode-unchanged");
  }
  auto late_reply = reply_wire;
  SetLe(late_reply, 58, 2, 4);
  reject_reply(late_reply, "reply-late-second-record-unchanged");
  auto counted_reply = reply_wire;
  counted_reply.append(4, '\0');
  PutLe(counted_reply, 1, 4);
  counted_reply += "/";
  SetLe(counted_reply, 4, counted_reply.size() - 8, 4);
  SetLe(counted_reply, 32, reply.records.size() + 1, 4);
  SetLe(counted_reply, 36, counted_reply.size() - kHeader, 4);
  t.Check(DecodeReply(counted_reply, decoded_reply) &&
              decoded_reply.records.size() == reply.records.size() + 1 &&
              decoded_reply.records.back() == Record{"", "/"},
          "reply-counted-extra-record");
}

void TestReferenceParser(Checks& t) {
  const std::string opaque = std::string("nul /a\0b/\n", 11);
  const std::string contents = Bom() +
      "a /one/\r\na /two;note/[okuri /x/]/\n;; comment /bad/\n"
      "bad\nno-space/x/\n /empty/\nembedded\rkey /tail\rvalue/\n" + opaque;
  Dictionary map;
  ParseFileReference(contents, map);
  t.Check(map.size() == 4, "parser-size");
  t.Check(map["a"] == "/two;note/[okuri /x/]/", "parser-last-wins-opaque");
  t.Check(map[""] == "/empty/", "parser-empty-key");
  t.Check(map["embeddedkey"] == "/tailvalue/", "parser-remove-all-cr");
  t.Check(map["nul"] == std::string("/a\0b/", 5), "parser-nul");

  Dictionary non_file;
  ParseReference(Bom() + "a /x/", non_file);
  t.Check(non_file.count(Bom() + "a") == 1, "parser-no-bom-strip");
  Dictionary double_bom;
  ParseFileReference(Bom() + Bom() + "a /x/", double_bom);
  t.Check(double_bom.count(Bom() + "a") == 1, "parser-strip-one-bom");
  Dictionary missing_lf;
  ParseFileReference("last /tail/", missing_lf);
  t.Check(missing_lf["last"] == "/tail/", "parser-missing-final-lf");

  Maps left = {map, missing_lf};
  Maps right = left;
  const CompareStats equal = CompareMaps(left, right);
  t.Check(equal.equal && equal.files == 2 && equal.left_counts == equal.right_counts &&
              equal.left_counts == std::vector<size_t>({4, 1}),
          "compare-counts-order");
  right[1]["last"] = "/different/";
  t.Check(!CompareMaps(left, right).equal, "compare-values");
  right = {map};
  t.Check(!CompareMaps(left, right).equal, "compare-file-slots");
}

void TestBatcher(Checks& t) {
  LineBatcher batcher;
  std::vector<std::vector<std::string>> batches;
  std::vector<bool> first;
  std::string error;
  auto emit = [&](const std::vector<std::string>& lines, bool is_first) {
    batches.push_back(lines);
    first.push_back(is_first);
    return true;
  };
  t.Check(batcher.Feed(std::string("\xef", 1), false, emit, error), "bom-split-1");
  t.Check(batcher.Feed(std::string("\xbb", 1), false, emit, error), "bom-split-2");
  t.Check(batcher.Feed(std::string("\xbf", 1) + "a /x/\r\nlast /y/", true,
                       emit, error),
          "bom-split-3");
  t.Check(batches.size() == 1 && batches[0] ==
              std::vector<std::string>({"a /x/\r", "last /y/"}) && first[0],
          "split-lines-cr-missing-lf");

  LineBatcher double_bom;
  batches.clear();
  first.clear();
  error.clear();
  t.Check(double_bom.Feed(Bom() + Bom() + "a /x/\n", true, emit, error) &&
              batches.size() == 1 && batches[0][0] == Bom() + "a /x/",
          "split-strip-one-bom");

  LineBatcher exact;
  batches.clear();
  first.clear();
  error.clear();
  const std::string exact_data = std::string(kLine - 4, 'x') + "\n" +
      std::string(kLine - 4, 'y') + "\n" + std::string(kLine - 4, 'z') +
      "\n" + std::string(kLine - 4, 'q') + "\n";
  t.Check(exact.Feed(exact_data, true, emit, error) && batches.size() == 1 &&
              batches[0].size() == 4,
          "split-exact-payload");

  LineBatcher multi;
  batches.clear();
  first.clear();
  error.clear();
  const std::string max_line(kLine, 'm');
  t.Check(multi.Feed(max_line + "\n" + max_line + "\n" + max_line + "\n" +
                         max_line + "\n",
                     true, emit, error) &&
              batches.size() == 2 && batches[0].size() == 3 &&
              batches[1].size() == 1 && first == std::vector<bool>({true, false}),
          "split-multibatch");

  LineBatcher counted;
  batches.clear();
  first.clear();
  error.clear();
  std::string short_lines;
  for (size_t i = 0; i < kBatchLines + 1; ++i) short_lines += "k /v/\n";
  t.Check(kBatchLines == 1024 && counted.Feed(short_lines, true, emit, error) &&
              batches.size() == 2 && batches[0].size() == kBatchLines &&
              batches[1].size() == 1 && first == std::vector<bool>({true, false}),
          "split-line-count-cap");

#ifndef HN_BUILDER_NEGATIVE_SKIP_OVERLONG
  LineBatcher overlong;
  error.clear();
  t.Check(!overlong.Feed(std::string(kLine + 1, 'x'), true, emit, error) &&
              error == "overlong",
          "split-overlong");
#endif
}

std::string LargeValidLine(char key) {
  std::string line(kLine - 4, key);
  line += " /x/";
  return line;
}

void TestPublisher(Checks& t) {
  Publisher publisher;
  t.Check(!publisher.HasGeneration() && !publisher.Lease(), "publisher-empty");
  Maps first(1);
  first[0]["a"] = "/one/";
  auto lease = publisher.Publish(1, std::move(first));
  t.Check(lease && lease->id == 1 && lease->counts == std::vector<size_t>{1},
          "publisher-first");
  Maps second(1);
  second[0]["a"] = "/two/";
  auto next = publisher.Publish(2, std::move(second));
  t.Check(next != lease && publisher.Lease() == next && lease->id == 1 &&
              lease->maps[0].at("a") == "/one/" && next->maps[0].at("a") == "/two/",
          "publisher-held-lease");
  Maps source(1);
  source[0]["alias"] = "/before/";
  std::string& source_value = source[0].at("alias");
  auto copied = publisher.Publish(3, std::move(source));
  source_value = "/after/";
  t.Check(source_value == "/after/" && copied->maps[0].at("alias") == "/before/",
          "publisher-deep-copy-alias-safe");
}

void TestModesAndDriver(Checks& t) {
  const std::vector<std::string> files = {
      Bom() + "a /one/\na /two/\n /empty/\n", "b /bee/"};
  std::vector<std::vector<std::string>> chunks = {
      {std::string("\xef", 1), std::string("\xbb", 1),
       std::string("\xbf", 1) + "a /one/\na /two/\n /empty/\n"},
      {"b /", "bee/"}};

  {
    FakeInput input(chunks);
    FakeChannel channel;
    Publisher publisher;
    int calls = 0;
    const BuildResult result = Build(input, channel, Loader(files, &calls), publisher,
                                     {Mode::Reference, true, 10});
    t.Check(result.ok && result.published && !result.fallback && calls == 1 &&
                channel.starts == 0 && publisher.Lease()->maps == Reference(files),
            "mode0-reference");
  }
  {
    FakeInput input(chunks);
    FakeChannel channel;
    Publisher publisher;
    int calls = 0;
    const BuildResult result = Build(input, channel, Loader(files, &calls), publisher,
                                     {Mode::Builder, false, 11});
    t.Check(result.ok && calls == 1 && channel.starts == 0 &&
                publisher.Lease()->maps == Reference(files),
            "incompatible-forces-mode0");
  }
  {
    FakeInput input(chunks);
    FakeChannel channel;
    Publisher publisher;
    int calls = 0;
    const BuildResult result = Build(
        input, channel, Loader(files, &calls), publisher,
        {static_cast<Mode>(3), true, 11});
    t.Check(result.ok && calls == 1 && channel.starts == 0 &&
                publisher.Lease()->maps == Reference(files),
            "invalid-mode-forces-mode0");
  }
  {
    FakeInput input(chunks);
    FakeChannel channel;
    Publisher publisher;
    int calls = 0;
    const BuildResult result = Build(input, channel, Loader(files, &calls), publisher,
                                     {Mode::Builder, true, 12});
    t.Check(result.ok && result.published && calls == 0 && channel.retires == 0 &&
                publisher.Lease()->maps == Reference(files),
            "mode1-builder");
    t.Check(channel.requests.size() == 2 && channel.requests[0].flags == kFirstLine &&
                channel.requests[1].flags == kFirstLine,
            "first-line-each-file");
    t.Check(channel.ready_timeouts == std::vector<uint32_t>{65000},
            "driver-ready-timeout-budget");
    t.Check(channel.timeouts.size() == channel.requests.size() &&
                std::all_of(channel.timeouts.begin(), channel.timeouts.end(),
                        [](uint32_t value) { return value == kBatchTimeoutMs; }),
            "driver-timeout-budget");
  }
  {
    FakeInput input(chunks);
    FakeChannel channel;
    Publisher publisher;
    const BuildResult result = Build(input, channel, Loader(files), publisher,
                                     {Mode::Shadow, true, 13});
    t.Check(result.ok && result.compared && result.comparison.equal &&
                result.comparison.left_counts == result.comparison.right_counts &&
                publisher.Lease()->maps == Reference(files),
            "mode2-shadow-publishes-reference");
  }
  {
    FakeInput input(chunks);
    FakeChannel channel;
    channel.fault = Fault::CorruptRecord;
    Publisher publisher;
    const BuildResult result = Build(input, channel, Loader(files), publisher,
                                     {Mode::Shadow, true, 14});
    t.Check(result.ok && result.compared && !result.comparison.equal &&
                !result.fallback && result.published && channel.retires == 0 &&
                result.comparison.left_counts == std::vector<size_t>({2, 1}) &&
                result.comparison.right_counts == std::vector<size_t>({2, 1}) &&
                publisher.Lease()->maps == Reference(files),
            "shadow-mismatch-reports-and-publishes-reference");
  }
  {
    FakeInput input(chunks);
    FakeChannel channel;
    channel.fault = Fault::CorruptRecord;
    Publisher publisher;
    Maps old(1);
    old[0]["old"] = "/old/";
    auto held = publisher.Publish(1, old);
    const BuildResult result = Build(input, channel, Loader(files), publisher,
                                     {Mode::Shadow, true, 14});
    t.Check(result.ok && result.compared && !result.comparison.equal &&
                result.comparison.left_counts == std::vector<size_t>({2, 1}) &&
                result.comparison.right_counts == std::vector<size_t>({2, 1}) &&
                publisher.Lease() != held && publisher.Lease()->maps == Reference(files),
            "shadow-mismatch-rebuild-publishes-reference");
  }

  const std::string multi_contents = LargeValidLine('a') + "\n" +
      LargeValidLine('b') + "\n" + LargeValidLine('c') + "\n" +
      LargeValidLine('d');
  {
    FakeInput input({Chunks(multi_contents, 7000)});
    FakeChannel channel;
    Publisher publisher;
    const BuildResult result = Build(input, channel, Loader({multi_contents}), publisher,
                                     {Mode::Builder, true, 15});
    t.Check(result.ok && channel.exchanges == 2 && channel.requests.size() == 2 &&
                channel.requests[0].lines.size() == 3 &&
                channel.requests[1].lines.size() == 1 &&
                channel.requests[0].batch_seq == 0 &&
                channel.requests[0].flags == kFirstLine &&
                channel.requests[1].batch_seq == 1 && channel.requests[1].flags == 0 &&
                publisher.Lease()->maps == Reference({multi_contents}),
            "driver-multichunk-multibatch");
  }
}

void TestFailures(Checks& t) {
  const std::vector<std::string> files = {"a /one/\n"};
  const std::vector<std::pair<Fault, const char*>> cases = {
      {Fault::Start, "start"},
      {Fault::ReadyText, "ready"},
      {Fault::ReadyTimeout, "ready-timeout"},
      {Fault::ReadyTransport, "transport"},
      {Fault::Timeout, "timeout"},
      {Fault::Transport, "transport"},
      {Fault::Truncate, "protocol"},
      {Fault::Echo, "echo"},
      {Fault::EchoGeneration, "echo"},
      {Fault::EchoFile, "echo"},
      {Fault::Status, "status"},
      {Fault::ExtraRecord, "protocol"},
  };
  for (const auto& [fault, token] : cases) {
    FakeInput input({Chunks(files[0], 3)});
    FakeChannel channel;
    channel.fault = fault;
    Publisher publisher;
    int calls = 0;
    const BuildResult result = Build(input, channel, Loader(files, &calls), publisher,
                                     {Mode::Builder, true, 20});
    t.Check(!result.ok && result.fallback && result.published &&
                result.error == token && calls == 1 && channel.retires == 1 &&
                publisher.Lease()->maps == Reference(files),
            "initial-failure-fallback");
    t.Check(channel.ready_timeouts == (fault == Fault::Start
                ? std::vector<uint32_t>{} : std::vector<uint32_t>{65000}),
            "failure-ready-timeout-budget");
    t.Check(std::all_of(channel.timeouts.begin(), channel.timeouts.end(),
                        [](uint32_t value) { return value == 10000; }),
            "failure-timeout-budget");
    if (fault == Fault::ReadyTimeout || fault == Fault::Timeout) {
      t.Check(channel.exchanges == (fault == Fault::ReadyTimeout ? 0 : 1) &&
                  channel.timeouts.size() == static_cast<size_t>(channel.exchanges),
              "timeout-phase");
    }
  }
  {
    FakeInput input({Chunks(files[0], 3)});
    input.fail_read_ = 1;
    FakeChannel channel;
    Publisher publisher;
    const BuildResult result = Build(input, channel, Loader(files), publisher,
                                     {Mode::Builder, true, 21});
    t.Check(!result.ok && result.error == "io" && result.fallback &&
                channel.retires == 1 && publisher.Lease()->maps == Reference(files),
            "input-io-fallback");
  }

  const std::string prefix = LargeValidLine('a') + "\n" + LargeValidLine('b') +
      "\n" + LargeValidLine('c') + "\n" + LargeValidLine('d') + "\n";
  const std::string overlong = std::string(kLine - 3, 'z') + " /x/";
  const std::string rebuild_contents = prefix + overlong;

  for (Fault fault : {Fault::Timeout, Fault::Transport}) {
    FakeInput input({Chunks(prefix + LargeValidLine('e'), 8192)});
    FakeChannel channel;
    channel.fault = fault;
    channel.fault_exchange = 2;
    Publisher publisher;
    const std::string contents = prefix + LargeValidLine('e');
    const BuildResult result = Build(input, channel, Loader({contents}), publisher,
                                     {Mode::Builder, true, 22});
    t.Check(!result.ok && result.fallback && result.published &&
                result.error == (fault == Fault::Timeout ? "timeout" : "transport") &&
                channel.exchanges == 2 &&
                publisher.Lease()->maps == Reference({contents}),
            "midstream-initial-failure-fallback");
  }
  {
    FakeInput input({Chunks(rebuild_contents, 8192)});
    FakeChannel channel;
    Publisher publisher;
    const BuildResult result = Build(input, channel, Loader({rebuild_contents}),
                                     publisher, {Mode::Builder, true, 22});
#ifndef HN_BUILDER_NEGATIVE_SKIP_OVERLONG
    t.Check(!result.ok && result.fallback && result.published &&
                result.error == "overlong" && channel.exchanges >= 1 &&
                publisher.Lease()->maps == Reference({rebuild_contents}),
            "midstream-initial-overlong-fallback");
#else
    t.Check(result.ok, "mutated-overlong-path");
#endif
  }

  for (Fault fault : {Fault::Timeout, Fault::Transport}) {
    FakeInput input({Chunks(prefix + LargeValidLine('e'), 8192)});
    FakeChannel channel;
    channel.fault = fault;
    channel.fault_exchange = 2;
    Publisher publisher;
    Maps old(1);
    old[0]["old"] = "/kept/";
    auto held = publisher.Publish(1, std::move(old));
    const BuildResult result = Build(input, channel, Loader({prefix + LargeValidLine('e')}),
                                     publisher, {Mode::Builder, true, 22});
    t.Check(!result.ok && !result.published && !result.fallback &&
                publisher.Lease() == held && channel.exchanges == 2 &&
                channel.retires == 1,
            "midstream-rebuild-retains");
  }
  {
    FakeInput input({Chunks(rebuild_contents, 8192)});
    FakeChannel channel;
    Publisher publisher;
    Maps old(1);
    old[0]["old"] = "/kept/";
    auto held = publisher.Publish(1, std::move(old));
    const BuildResult result = Build(input, channel, Loader({rebuild_contents}), publisher,
                                     {Mode::Builder, true, 23});
#ifndef HN_BUILDER_NEGATIVE_SKIP_OVERLONG
    t.Check(!result.ok && result.error == "overlong" && !result.published &&
                publisher.Lease() == held && channel.exchanges >= 1 &&
                channel.retires == 1,
            "overlong-rebuild-retains");
#else
    t.Check(!result.ok && result.error == "overlong" && !result.published &&
                publisher.Lease() == held,
            "overlong-rebuild-retains");
#endif
  }
}

int NegativeDropLast() {
  Checks t;
  const std::vector<std::string> files = {"a /one/\nb /two/\n"};
  FakeInput input({Chunks(files[0], 5)});
  FakeChannel channel;
  channel.fault = Fault::DropLast;
  Publisher publisher;
  const BuildResult result = Build(input, channel, Loader(files), publisher,
                                   {Mode::Shadow, true, 40});
  t.Check(result.ok && result.compared && result.comparison.equal,
          "shadow-acceptance");
  std::printf("FAIL hn-builder control=drop-last rejected checks=%d failures=%d\n",
              t.checks, t.failures);
  return t.failures == 0 ? 0 : 1;
}

int NegativeSkipOverlong() {
  Checks t;
  const std::string prefix = LargeValidLine('a') + "\n" + LargeValidLine('b') +
      "\n" + LargeValidLine('c') + "\n" + LargeValidLine('d') + "\n";
  const std::string overlong = std::string(kLine - 3, 'z') + " /x/";
  const std::string contents = prefix + overlong;
  FakeInput input({Chunks(contents, 4096)});
  FakeChannel channel;
  Publisher publisher;
  Maps old(1);
  old[0]["old"] = "/kept/";
  auto held = publisher.Publish(1, std::move(old));
  const BuildResult result = Build(input, channel, Loader({contents}), publisher,
                                   {Mode::Builder, true, 41});
  t.Check(!result.ok && result.error == "overlong" && publisher.Lease() == held,
          "overlong-acceptance");
  std::printf("%s hn-builder control=skip-overlong rejected checks=%d failures=%d\n",
              t.failures == 0 ? "PASS" : "FAIL", t.checks, t.failures);
  return t.failures == 0 ? 0 : 1;
}

int ContractFixture() {
  Request request;
  request.generation = 0x0102030405060708ULL;
  request.file_index = 0x11223344;
  request.batch_seq = 0x55667788;
  request.flags = kFirstLine;
  request.lines = {"a /A/", " /"};
  Reply reply;
  reply.generation = request.generation;
  reply.file_index = request.file_index;
  reply.batch_seq = request.batch_seq;
  reply.records = {{"a", "/A/"}, {"", "/"}};
  std::printf("request_hex=%s\n", Hex(EncodeRequest(request)).c_str());
  std::printf("reply_hex=%s\n", Hex(EncodeReply(reply)).c_str());
  std::printf("ready_hex=%s\n", Hex(kReady).c_str());
  return 0;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc == 3 && std::string_view(argv[1]) == "--reference-file") {
    std::ifstream input(argv[2], std::ios::binary);
    if (!input) return 1;
    const std::string contents((std::istreambuf_iterator<char>(input)), {});
    if (input.bad()) return 1;
    Dictionary map;
    ParseFileReference(contents, map);
    for (const auto& [key, tail] : map)
      std::printf("%s=%s\n", Hex(key).c_str(), Hex(tail).c_str());
    return 0;
  }
  if (argc == 2 && std::string_view(argv[1]) == "--contract-fixture") {
    return ContractFixture();
  }
  if (argc == 2 && std::string_view(argv[1]) == "--negative-drop-last") {
    return NegativeDropLast();
  }
  if (argc == 2 && std::string_view(argv[1]) == "--negative-skip-overlong") {
    return NegativeSkipOverlong();
  }
  Checks t;
  TestCodec(t);
  TestReferenceParser(t);
  TestBatcher(t);
  TestPublisher(t);
  TestModesAndDriver(t);
  TestFailures(t);
  std::printf("%s hn-builder units checks=%d failures=%d\n",
              t.failures == 0 ? "PASS" : "FAIL", t.checks, t.failures);
  return t.failures == 0 ? 0 : 1;
}
