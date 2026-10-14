// HN builder protocol and publication primitives. This header has no OS dependencies.
#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <limits>
#include <memory>
#include <mutex>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

namespace hn_builder {

constexpr uint16_t kVersion = 1;
constexpr size_t kHeader = 40;
constexpr size_t kPayload = 262144;
constexpr size_t kReplyPayload = 524288;
constexpr size_t kLine = 65536;
// Native batching policy, below the contract count limit: keeps one batch of
// short lines well inside kBatchTimeoutMs for an interpreted child.
constexpr size_t kBatchLines = 1024;
constexpr uint32_t kBatchTimeoutMs = 10000;
constexpr uint32_t kReadyTimeoutMs = 65000;
constexpr std::string_view kReady = "HNB READY version=1\n";
constexpr uint32_t kFirstLine = 1;

using Dictionary = std::unordered_map<std::string, std::string>;
using Maps = std::vector<Dictionary>;

struct Record {
  std::string key;
  std::string tail;
  bool operator==(const Record&) const = default;
};

struct Request {
  uint64_t generation = 0;
  uint32_t file_index = 0;
  uint32_t batch_seq = 0;
  uint32_t flags = 0;
  std::vector<std::string> lines;
};

struct Reply {
  uint16_t status = 0;
  uint64_t generation = 0;
  uint32_t file_index = 0;
  uint32_t batch_seq = 0;
  std::vector<Record> records;
};

inline void PutLe(std::string& out, uint64_t value, size_t width) {
  while (width-- != 0) {
    out.push_back(static_cast<char>(value & 0xff));
    value >>= 8;
  }
}

inline bool GetLe(std::string_view bytes, size_t offset, size_t width,
                  uint64_t& value) {
  if (offset > bytes.size() || width > bytes.size() - offset || width > 8) {
    return false;
  }
  value = 0;
  for (size_t i = 0; i < width; ++i) {
    value |= static_cast<uint64_t>(
                 static_cast<unsigned char>(bytes[offset + i]))
             << (8 * i);
  }
  return true;
}

inline bool ValidRequest(const Request& request, size_t* payload_size = nullptr) {
  if ((request.flags & ~kFirstLine) != 0 || request.lines.size() > kLine) {
    return false;
  }
  size_t payload = 0;
  for (const auto& line : request.lines) {
    if (line.size() > kLine || line.find('\n') != std::string::npos ||
        payload > kPayload - 4 || line.size() > kPayload - payload - 4) {
      return false;
    }
    payload += 4 + line.size();
  }
  if (payload_size != nullptr) *payload_size = payload;
  return true;
}

inline bool ValidRecord(const Record& record) {
  if (record.key.size() > kLine || record.tail.size() > kLine ||
      record.key.size() > kLine - record.tail.size() || record.tail.empty() ||
      record.tail.front() != '/' || record.key.find(' ') != std::string::npos ||
      record.key.find('\r') != std::string::npos ||
      record.key.find('\n') != std::string::npos ||
      record.tail.find('\r') != std::string::npos ||
      record.tail.find('\n') != std::string::npos) {
    return false;
  }
  return true;
}

inline bool ValidReply(const Reply& reply, size_t* payload_size = nullptr) {
  if (reply.status > 2 || reply.records.size() > kLine) return false;
  if (reply.status != 0) {
    if (!reply.records.empty()) return false;
    if (payload_size != nullptr) *payload_size = 0;
    return true;
  }
  size_t payload = 0;
  for (const auto& record : reply.records) {
    if (!ValidRecord(record) || payload > kReplyPayload - 8 ||
        record.key.size() > kReplyPayload - payload - 8 ||
        record.tail.size() > kReplyPayload - payload - 8 - record.key.size()) {
      return false;
    }
    payload += 8 + record.key.size() + record.tail.size();
  }
  if (payload_size != nullptr) *payload_size = payload;
  return true;
}

inline std::string EncodeRequest(const Request& request) {
  size_t payload = 0;
  if (!ValidRequest(request, &payload)) return {};
  std::string out;
  out.reserve(kHeader + payload);
  out += "HNBQ";
  PutLe(out, kHeader - 8 + payload, 4);
  PutLe(out, kVersion, 2);
  PutLe(out, 0, 2);
  PutLe(out, request.generation, 8);
  PutLe(out, request.file_index, 4);
  PutLe(out, request.batch_seq, 4);
  PutLe(out, request.flags, 4);
  PutLe(out, request.lines.size(), 4);
  PutLe(out, payload, 4);
  for (const auto& line : request.lines) {
    PutLe(out, line.size(), 4);
    out += line;
  }
  return out;
}

inline std::string EncodeReply(const Reply& reply) {
  size_t payload = 0;
  if (!ValidReply(reply, &payload)) return {};
  std::string out;
  out.reserve(kHeader + payload);
  out += "HNBR";
  PutLe(out, kHeader - 8 + payload, 4);
  PutLe(out, kVersion, 2);
  PutLe(out, reply.status, 2);
  PutLe(out, reply.generation, 8);
  PutLe(out, reply.file_index, 4);
  PutLe(out, reply.batch_seq, 4);
  PutLe(out, 0, 4);
  PutLe(out, reply.records.size(), 4);
  PutLe(out, payload, 4);
  for (const auto& record : reply.records) {
    PutLe(out, record.key.size(), 4);
    out += record.key;
    PutLe(out, record.tail.size(), 4);
    out += record.tail;
  }
  return out;
}

inline bool DecodeCommon(std::string_view bytes, std::string_view magic,
                         size_t payload_limit, uint16_t& status,
                         uint64_t& generation, uint32_t& file_index,
                         uint32_t& batch_seq, uint32_t& flags,
                         uint32_t& count, uint32_t& payload) {
  if (bytes.size() < kHeader || bytes.substr(0, 4) != magic ||
      bytes.size() - kHeader > payload_limit) {
    return false;
  }
  uint64_t body = 0, version = 0, raw_status = 0, raw_file = 0, raw_seq = 0;
  uint64_t raw_flags = 0, raw_count = 0, raw_payload = 0;
  if (!GetLe(bytes, 4, 4, body) || body != bytes.size() - 8 ||
      !GetLe(bytes, 8, 2, version) || version != kVersion ||
      !GetLe(bytes, 10, 2, raw_status) || !GetLe(bytes, 12, 8, generation) ||
      !GetLe(bytes, 20, 4, raw_file) || !GetLe(bytes, 24, 4, raw_seq) ||
      !GetLe(bytes, 28, 4, raw_flags) || !GetLe(bytes, 32, 4, raw_count) ||
      !GetLe(bytes, 36, 4, raw_payload) || raw_payload != bytes.size() - kHeader ||
      raw_count > kLine) {
    return false;
  }
  status = static_cast<uint16_t>(raw_status);
  file_index = static_cast<uint32_t>(raw_file);
  batch_seq = static_cast<uint32_t>(raw_seq);
  flags = static_cast<uint32_t>(raw_flags);
  count = static_cast<uint32_t>(raw_count);
  payload = static_cast<uint32_t>(raw_payload);
  return true;
}

inline bool DecodeRequest(std::string_view bytes, Request& output) {
  uint16_t status = 0;
  uint64_t generation = 0;
  uint32_t file = 0, seq = 0, flags = 0, count = 0, payload = 0;
  if (!DecodeCommon(bytes, "HNBQ", kPayload, status, generation, file, seq,
                    flags, count, payload) ||
      status != 0 || (flags & ~kFirstLine) != 0) {
    return false;
  }
  Request value;
  value.generation = generation;
  value.file_index = file;
  value.batch_seq = seq;
  value.flags = flags;
  size_t at = kHeader;
  value.lines.reserve(count);
  for (uint32_t i = 0; i < count; ++i) {
    uint64_t length = 0;
    if (!GetLe(bytes, at, 4, length)) return false;
    at += 4;
    if (length > kLine || length > bytes.size() - at) return false;
    std::string_view line = bytes.substr(at, static_cast<size_t>(length));
    if (line.find('\n') != std::string_view::npos) return false;
    value.lines.emplace_back(line);
    at += static_cast<size_t>(length);
  }
  if (at != bytes.size() || !ValidRequest(value)) return false;
  output = std::move(value);
  return true;
}

inline bool DecodeReply(std::string_view bytes, Reply& output) {
  uint16_t status = 0;
  uint64_t generation = 0;
  uint32_t file = 0, seq = 0, flags = 0, count = 0, payload = 0;
  if (!DecodeCommon(bytes, "HNBR", kReplyPayload, status, generation, file,
                    seq, flags, count, payload) ||
      flags != 0 || status > 2 || (status != 0 && (count != 0 || payload != 0))) {
    return false;
  }
  Reply value;
  value.status = status;
  value.generation = generation;
  value.file_index = file;
  value.batch_seq = seq;
  size_t at = kHeader;
  value.records.reserve(count);
  for (uint32_t i = 0; i < count; ++i) {
    uint64_t key_length = 0, tail_length = 0;
    if (!GetLe(bytes, at, 4, key_length)) return false;
    at += 4;
    if (key_length > bytes.size() - at) return false;
    std::string key(bytes.substr(at, static_cast<size_t>(key_length)));
    at += static_cast<size_t>(key_length);
    if (!GetLe(bytes, at, 4, tail_length)) return false;
    at += 4;
    if (tail_length > bytes.size() - at) return false;
    std::string tail(bytes.substr(at, static_cast<size_t>(tail_length)));
    at += static_cast<size_t>(tail_length);
    value.records.push_back({std::move(key), std::move(tail)});
  }
  if (at != bytes.size() || !ValidReply(value)) return false;
  output = std::move(value);
  return true;
}

inline bool ParseReferenceLine(std::string_view raw_line, Record& output) {
  std::string line;
  line.reserve(raw_line.size());
  for (char ch : raw_line) {
    if (ch != '\r' && ch != '\n') line.push_back(ch);
  }
  if (line.empty() || line.substr(0, 2) == ";;") return false;
  const size_t space = line.find(' ');
  if (space == std::string::npos) return false;
  const size_t slash = line.find('/', space);
  if (slash == std::string::npos) return false;
  output = {line.substr(0, space), line.substr(slash)};
  return true;
}

inline void ParseReference(std::string_view contents, Dictionary& map) {
  size_t line_start = 0;
  while (line_start <= contents.size()) {
    size_t line_end = contents.find('\n', line_start);
    if (line_end == std::string_view::npos) line_end = contents.size();
    Record record;
    if (ParseReferenceLine(contents.substr(line_start, line_end - line_start),
                           record)) {
      map[std::move(record.key)] = std::move(record.tail);
    }
    line_start = line_end + 1;
  }
}

inline void ParseFileReference(std::string_view contents, Dictionary& map) {
  if (contents.size() >= 3 &&
      static_cast<unsigned char>(contents[0]) == 0xef &&
      static_cast<unsigned char>(contents[1]) == 0xbb &&
      static_cast<unsigned char>(contents[2]) == 0xbf) {
    contents.remove_prefix(3);
  }
  ParseReference(contents, map);
}

class LineBatcher {
 public:
  using Emit = std::function<bool(const std::vector<std::string>&, bool)>;

  bool Feed(std::string_view chunk, bool eof, const Emit& emit,
            std::string& error) {
    if (done_) {
      error = "io";
      return false;
    }
    size_t offset = 0;
    if (!prefix_decided_) {
      while (offset < chunk.size() && prefix_.size() < 3) {
        prefix_.push_back(chunk[offset++]);
        if ((prefix_.size() == 1 &&
             static_cast<unsigned char>(prefix_[0]) != 0xef) ||
            (prefix_.size() == 2 &&
             static_cast<unsigned char>(prefix_[1]) != 0xbb)) {
          prefix_decided_ = true;
          break;
        }
      }
      if (prefix_.size() == 3 || eof) prefix_decided_ = true;
      if (prefix_decided_) {
        const bool bom = prefix_.size() >= 3 &&
            static_cast<unsigned char>(prefix_[0]) == 0xef &&
            static_cast<unsigned char>(prefix_[1]) == 0xbb &&
            static_cast<unsigned char>(prefix_[2]) == 0xbf;
        const size_t begin = bom ? 3 : 0;
        if (!Consume(std::string_view(prefix_).substr(begin), emit, error)) {
          return false;
        }
        prefix_.clear();
      }
    }
    if (prefix_decided_ &&
        !Consume(chunk.substr(offset), emit, error)) {
      return false;
    }
    if (eof) {
      if (!line_.empty() && !QueueLine(std::move(line_), emit, error)) {
        return false;
      }
      line_.clear();
      if (!Flush(emit, error)) return false;
      done_ = true;
    }
    return true;
  }

 private:
  bool Consume(std::string_view bytes, const Emit& emit, std::string& error) {
    for (char ch : bytes) {
      if (ch == '\n') {
        if (!QueueLine(std::move(line_), emit, error)) return false;
        line_.clear();
      } else {
        if (line_.size() == kLine) {
#ifndef HN_BUILDER_NEGATIVE_SKIP_OVERLONG
          error = "overlong";
          return false;
#else
          continue;
#endif
        }
        line_.push_back(ch);
      }
    }
    return true;
  }

  bool QueueLine(std::string line, const Emit& emit, std::string& error) {
    const size_t encoded = 4 + line.size();
    if (!batch_.empty() &&
        (batch_bytes_ > kPayload - encoded || batch_.size() >= kBatchLines) &&
        !Flush(emit, error)) {
      return false;
    }
    if (encoded > kPayload || batch_bytes_ > kPayload - encoded) {
      error = "overlong";
      return false;
    }
    batch_bytes_ += encoded;
    batch_.push_back(std::move(line));
    return true;
  }

  bool Flush(const Emit& emit, std::string& error) {
    if (batch_.empty()) return true;
    if (!emit(batch_, first_batch_)) {
      if (error.empty()) error = "transport";
      return false;
    }
    first_batch_ = false;
    batch_.clear();
    batch_bytes_ = 0;
    return true;
  }

  bool prefix_decided_ = false;
  bool first_batch_ = true;
  bool done_ = false;
  size_t batch_bytes_ = 0;
  std::string prefix_;
  std::string line_;
  std::vector<std::string> batch_;
};

struct Generation {
  uint64_t id = 0;
  Maps maps;
  std::vector<size_t> counts;
};

struct CompareStats {
  bool equal = false;
  size_t files = 0;
  std::vector<size_t> left_counts;
  std::vector<size_t> right_counts;
};

class Publisher {
 public:
  std::shared_ptr<const Generation> Lease() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return current_;
  }

  bool HasGeneration() const { return static_cast<bool>(Lease()); }

  std::shared_ptr<const Generation> Publish(uint64_t id, const Maps& maps) {
    Generation generation;
    generation.id = id;
    generation.counts.reserve(maps.size());
    for (const auto& map : maps) generation.counts.push_back(map.size());
    generation.maps = maps;
    auto fresh = std::make_shared<const Generation>(std::move(generation));
    std::lock_guard<std::mutex> lock(mutex_);
    current_ = fresh;
    return fresh;
  }

 private:
  mutable std::mutex mutex_;
  std::shared_ptr<const Generation> current_;
};

class Input {
 public:
  virtual ~Input() = default;
  virtual size_t FileCount() const = 0;
  virtual bool Read(size_t file_index, std::string& chunk, bool& eof) = 0;
};

enum class IoResult { Ok, Timeout, Transport };

class Channel {
 public:
  virtual ~Channel() = default;
  virtual bool Start() = 0;
  virtual IoResult ReadReady(std::string& ready, uint32_t timeout_ms) = 0;
  virtual IoResult Exchange(std::string_view request, std::string& reply,
                            uint32_t timeout_ms) = 0;
  // Phase B implementations must kill/close/drain the child here.
  virtual void Retire() noexcept = 0;
};

enum class Mode : uint8_t { Reference = 0, Builder = 1, Shadow = 2 };

struct BuildOptions {
  Mode mode = Mode::Reference;
  bool bundle_compatible = true;
  uint64_t generation = 0;
};

struct BuildResult {
  bool ok = false;
  bool published = false;
  bool fallback = false;
  std::string error;
  bool compared = false;
  CompareStats comparison;
};

using ReferenceLoader = std::function<Maps()>;

inline const char* IoError(IoResult result) {
  return result == IoResult::Timeout ? "timeout" : "transport";
}

inline bool SameMaps(const Maps& left, const Maps& right) {
  if (left.size() != right.size()) return false;
  for (size_t i = 0; i < left.size(); ++i) {
    if (left[i].size() != right[i].size() || left[i] != right[i]) return false;
  }
  return true;
}

inline CompareStats CompareMaps(const Maps& left, const Maps& right) {
  CompareStats stats;
  stats.files = left.size();
  stats.left_counts.reserve(left.size());
  stats.right_counts.reserve(right.size());
  for (const auto& map : left) stats.left_counts.push_back(map.size());
  for (const auto& map : right) stats.right_counts.push_back(map.size());
  stats.equal = SameMaps(left, right);
  return stats;
}

inline BuildResult Build(Input& input, Channel& channel,
                         const ReferenceLoader& reference, Publisher& publisher,
                         BuildOptions options) {
  if (options.mode != Mode::Reference && options.mode != Mode::Builder &&
      options.mode != Mode::Shadow) {
    options.mode = Mode::Reference;
  }
  if (!options.bundle_compatible) options.mode = Mode::Reference;
  if (options.mode == Mode::Reference) {
    publisher.Publish(options.generation, reference());
    return {true, true, false, {}};
  }

  const bool had_generation = publisher.HasGeneration();
  Maps reference_maps;
  if (options.mode == Mode::Shadow) reference_maps = reference();

  auto fail = [&](std::string error) {
    channel.Retire();
    if (!had_generation) {
      Maps fallback_maps = options.mode == Mode::Shadow ? std::move(reference_maps)
                                                        : reference();
      publisher.Publish(options.generation, std::move(fallback_maps));
      return BuildResult{false, true, true, std::move(error)};
    }
    return BuildResult{false, false, false, std::move(error)};
  };

  if (!channel.Start()) return fail("start");
  std::string ready;
  const IoResult ready_result = channel.ReadReady(ready, kReadyTimeoutMs);
  if (ready_result != IoResult::Ok) {
    return fail(ready_result == IoResult::Timeout ? "ready-timeout"
                                                 : IoError(ready_result));
  }
  if (ready != kReady) return fail("ready");

  const size_t file_count = input.FileCount();
  if (file_count > static_cast<uint64_t>((std::numeric_limits<uint32_t>::max)()) + 1) {
    return fail("io");
  }
  Maps built(file_count);
  for (size_t file = 0; file < file_count; ++file) {
    LineBatcher batcher;
    uint32_t batch_seq = 0;
    std::string batch_error;
    auto emit = [&](const std::vector<std::string>& lines, bool first) {
      if (batch_seq == (std::numeric_limits<uint32_t>::max)()) {
        batch_error = "protocol";
        return false;
      }
      Request request;
      request.generation = options.generation;
      request.file_index = static_cast<uint32_t>(file);
      request.batch_seq = batch_seq;
      request.flags = first ? kFirstLine : 0;
      request.lines = lines;
      const std::string wire = EncodeRequest(request);
      if (wire.empty()) {
        batch_error = "protocol";
        return false;
      }
      std::string reply_wire;
      const IoResult exchange =
          channel.Exchange(wire, reply_wire, kBatchTimeoutMs);
      if (exchange != IoResult::Ok) {
        batch_error = IoError(exchange);
        return false;
      }
      Reply reply;
      if (!DecodeReply(reply_wire, reply)) {
        batch_error = "protocol";
        return false;
      }
      if (reply.generation != request.generation ||
          reply.file_index != request.file_index ||
          reply.batch_seq != request.batch_seq) {
        batch_error = "echo";
        return false;
      }
      if (reply.status != 0) {
        batch_error = "status";
        return false;
      }
      if (reply.records.size() > request.lines.size()) {
        batch_error = "protocol";
        return false;
      }
      for (auto& record : reply.records) {
        built[file][std::move(record.key)] = std::move(record.tail);
      }
      ++batch_seq;
      return true;
    };

    bool eof = false;
    while (!eof) {
      std::string chunk;
      if (!input.Read(file, chunk, eof) || (chunk.empty() && !eof)) {
        return fail("io");
      }
      if (!batcher.Feed(chunk, eof, emit, batch_error)) {
        return fail(batch_error.empty() ? "protocol" : batch_error);
      }
    }
  }

  if (options.mode == Mode::Shadow) {
    CompareStats comparison = CompareMaps(built, reference_maps);
    publisher.Publish(options.generation, reference_maps);
    BuildResult result{true, true, false, {}};
    result.compared = true;
    result.comparison = std::move(comparison);
    return result;
  } else {
    publisher.Publish(options.generation, built);
  }
  return {true, true, false, {}};
}

}  // namespace hn_builder
