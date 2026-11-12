// Copyright (C) 2026 nelisp-skk-ime contributors
//
// This program is free software: you can redistribute it and/or
// modify it under the terms of the GNU General Public License as
// published by the Free Software Foundation, either version 3 of
// the License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be
// useful, but WITHOUT ANY WARRANTY; without even the implied
// warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
// PURPOSE.  See the GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

// Binary TLV variant of the engine reply on the DLL <-> host named pipe
// (stage S4.1).  Header-only and free of Windows headers so it builds and is
// unit-tested on Linux.  The wire format is specified in
// docs/design/engine-tlv.md; keep both in sync.
#pragma once

#include <cstddef>
#include <cstdio>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "engine_protocol.h"

namespace ddskk::tlv {

constexpr uint8_t kVersion = 1;
constexpr size_t kHeaderSize = 12;
constexpr size_t kMaxTotal = 65536;       // whole message, header included
constexpr size_t kMaxStringBytes = 16384; // one string value
constexpr size_t kMaxCandidates = 512;

enum Kind : uint8_t { kKindState = 1, kKindRaw = 2 };

enum Tag : uint16_t {
  kTagMode = 0x0001,
  kTagCursor = 0x0002,
  kTagCompStart = 0x0003,
  kTagText = 0x0004,
  kTagPending = 0x0005,
  kTagCandIndex = 0x0006,
  kTagCandidate = 0x0007,
  kTagRegReading = 0x0008,
  kTagSequence = 0x0009,
  // 0x0010..0x00FF reserved for engine-state extensions (segments, commit
  // text, status, needs-resync); v1 decoders skip them.
  kTagRawLine = 0x0020,
};

// Neutral decoded message: a STATE reply (EngineState + extras) or a raw
// non-STATE reply line (OK/ERR/ENGINES/...) carried verbatim as UTF-8.
struct Message {
  uint8_t kind = kKindState;
  EngineState state;
  bool has_registration_reading = false;  // nine-field registration STATE
  std::optional<uint32_t> sequence;
  std::string raw_line;  // kKindRaw only
};

namespace detail {

inline void PutU16(std::string* out, uint16_t v) {
  out->push_back(static_cast<char>(v & 0xff));
  out->push_back(static_cast<char>(v >> 8));
}
inline void PutU32(std::string* out, uint32_t v) {
  for (int i = 0; i < 4; ++i) out->push_back(static_cast<char>((v >> (8 * i)) & 0xff));
}
inline uint16_t GetU16(const unsigned char* p) {
  return static_cast<uint16_t>(p[0] | (p[1] << 8));
}
inline uint32_t GetU32(const unsigned char* p) {
  return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
         (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
}

// std::wstring holds UTF-16 on Windows and UTF-32 elsewhere; the wire is
// always UTF-16LE.
inline std::string WideToUtf16Le(const std::wstring& s) {
  std::string out;
  for (const wchar_t wc : s) {
    uint32_t c = static_cast<uint32_t>(wc);
    if (sizeof(wchar_t) == 2 || c <= 0xffff) {
      PutU16(&out, static_cast<uint16_t>(c));
    } else {
      c -= 0x10000;
      PutU16(&out, static_cast<uint16_t>(0xd800 + (c >> 10)));
      PutU16(&out, static_cast<uint16_t>(0xdc00 + (c & 0x3ff)));
    }
  }
  return out;
}
inline std::wstring Utf16LeToWide(const unsigned char* p, size_t bytes) {
  std::wstring out;
  for (size_t i = 0; i + 2 <= bytes; i += 2) {
    const uint32_t u = GetU16(p + i);
    if (sizeof(wchar_t) > 2 && u >= 0xd800 && u <= 0xdbff && i + 4 <= bytes) {
      const uint32_t lo = GetU16(p + i + 2);
      if (lo >= 0xdc00 && lo <= 0xdfff) {
        out.push_back(static_cast<wchar_t>(0x10000 + ((u - 0xd800) << 10) + (lo - 0xdc00)));
        i += 2;
        continue;
      }
    }
    out.push_back(static_cast<wchar_t>(u));
  }
  return out;
}

inline void PutRecord(std::string* out, uint16_t tag, const std::string& value) {
  PutU16(out, tag);
  PutU32(out, static_cast<uint32_t>(value.size()));
  out->append(value);
}
inline std::string I32(int32_t v) {
  std::string s;
  PutU32(&s, static_cast<uint32_t>(v));
  return s;
}

}  // namespace detail

// Encodes MESSAGE.  Returns false (OUT untouched) when a size limit is hit.
inline bool Encode(const Message& m, std::string* out) {
  using namespace detail;
  std::string body;
  if (m.kind == kKindRaw) {
    if (m.raw_line.size() > kMaxStringBytes) return false;
    PutRecord(&body, kTagRawLine, m.raw_line);
  } else if (m.kind == kKindState) {
    const EngineState& s = m.state;
    if (s.candidates.size() > kMaxCandidates) return false;
    PutRecord(&body, kTagMode, WideToUtf16Le(s.mode));
    PutRecord(&body, kTagCursor, I32(s.cursor));
    PutRecord(&body, kTagCompStart, I32(s.composition_start));
    PutRecord(&body, kTagText, WideToUtf16Le(s.text));
    PutRecord(&body, kTagPending, WideToUtf16Le(s.pending_romaji));
    PutRecord(&body, kTagCandIndex, I32(s.candidate_index));
    for (const auto& c : s.candidates) PutRecord(&body, kTagCandidate, WideToUtf16Le(c));
    if (m.has_registration_reading)
      PutRecord(&body, kTagRegReading, WideToUtf16Le(s.registration_reading));
    if (m.sequence) {
      std::string v;
      PutU32(&v, *m.sequence);
      PutRecord(&body, kTagSequence, v);
    }
  } else {
    return false;
  }
  std::string msg = "DSTV";
  PutU32(&msg, static_cast<uint32_t>(kHeaderSize + body.size()));
  msg.push_back(static_cast<char>(kVersion));
  msg.push_back(static_cast<char>(m.kind));
  PutU16(&msg, 0);
  msg.append(body);
  if (msg.size() > kMaxTotal) return false;
  // Every string value must also respect the per-string cap.
  std::vector<std::wstring> all = {m.state.mode, m.state.text, m.state.pending_romaji,
                                   m.state.registration_reading};
  all.insert(all.end(), m.state.candidates.begin(), m.state.candidates.end());
  for (const auto& w : all)
    if (WideToUtf16Le(w).size() > kMaxStringBytes) return false;
  *out = std::move(msg);
  return true;
}

// Decodes exactly one message occupying all of DATA.  Returns nullopt on any
// framing or field error (bad magic, version > kVersion, total != size,
// truncated or overrunning record, wrong fixed width, odd UTF-16 length,
// missing required tag, size limits).  Unknown tags are skipped.
inline std::optional<Message> Decode(const unsigned char* data, size_t size) {
  using namespace detail;
  if (size < kHeaderSize || size > kMaxTotal) return std::nullopt;
  if (data[0] != 'D' || data[1] != 'S' || data[2] != 'T' || data[3] != 'V')
    return std::nullopt;
  if (GetU32(data + 4) != size) return std::nullopt;
  if (data[8] == 0 || data[8] > kVersion) return std::nullopt;
  Message m;
  m.kind = data[9];
  if (m.kind != kKindState && m.kind != kKindRaw) return std::nullopt;
  unsigned seen = 0;  // bit per required tag: mode, cursor, comp, idx, raw
  size_t pos = kHeaderSize;
  while (pos < size) {
    if (size - pos < 6) return std::nullopt;
    const uint16_t tag = GetU16(data + pos);
    const uint32_t len = GetU32(data + pos + 2);
    pos += 6;
    if (len > size - pos) return std::nullopt;
    const unsigned char* v = data + pos;
    pos += len;
    const bool is_str = tag == kTagMode || tag == kTagText || tag == kTagPending ||
                        tag == kTagCandidate || tag == kTagRegReading;
    if (is_str && (len % 2 != 0 || len > kMaxStringBytes)) return std::nullopt;
    const bool is_i32 = tag == kTagCursor || tag == kTagCompStart || tag == kTagCandIndex ||
                        tag == kTagSequence;
    if (is_i32 && len != 4) return std::nullopt;
    switch (tag) {
      case kTagMode: m.state.mode = Utf16LeToWide(v, len); seen |= 1; break;
      case kTagCursor: m.state.cursor = static_cast<int32_t>(GetU32(v)); seen |= 2; break;
      case kTagCompStart:
        m.state.composition_start = static_cast<int32_t>(GetU32(v)); seen |= 4; break;
      case kTagText: m.state.text = Utf16LeToWide(v, len); break;
      case kTagPending: m.state.pending_romaji = Utf16LeToWide(v, len); break;
      case kTagCandIndex:
        m.state.candidate_index = static_cast<int32_t>(GetU32(v)); seen |= 8; break;
      case kTagCandidate:
        if (m.state.candidates.size() >= kMaxCandidates) return std::nullopt;
        m.state.candidates.push_back(Utf16LeToWide(v, len));
        break;
      case kTagRegReading:
        m.state.registration_reading = Utf16LeToWide(v, len);
        m.has_registration_reading = true;
        break;
      case kTagSequence: m.sequence = GetU32(v); break;
      case kTagRawLine:
        if (len > kMaxStringBytes) return std::nullopt;
        m.raw_line.assign(reinterpret_cast<const char*>(v), len);
        seen |= 16;
        break;
      default: break;  // unknown or reserved tag: skipped
    }
  }
  if (m.kind == kKindState && (seen & 15) != 15) return std::nullopt;
  if (m.kind == kKindRaw && (seen & 16) == 0) return std::nullopt;
  return m;
}

inline std::optional<Message> Decode(const std::string& data) {
  return Decode(reinterpret_cast<const unsigned char*>(data.data()), data.size());
}

// Canonical one-line field dump shared by the C++ test, the golden *.dump
// files and the Elisp decoder test (strings as UTF-16 code units in hex).
inline std::string Dump(const Message& m) {
  auto units = [](const std::wstring& w) {
    const std::string b = detail::WideToUtf16Le(w);
    if (b.empty()) return std::string("-");
    std::string s;
    char buf[8];
    for (size_t i = 0; i + 1 < b.size(); i += 2) {
      snprintf(buf, sizeof buf, "%04x",
               detail::GetU16(reinterpret_cast<const unsigned char*>(b.data()) + i));
      s += buf;
    }
    return s;
  };
  std::string s;
  if (m.kind == kKindRaw) {
    s = "kind=2 raw=";
    char buf[4];
    if (m.raw_line.empty()) s += "-";
    for (const unsigned char c : m.raw_line) {
      snprintf(buf, sizeof buf, "%02x", c);
      s += buf;
    }
    return s;
  }
  s = "kind=1 mode=" + units(m.state.mode) + " cursor=" + std::to_string(m.state.cursor) +
      " comp=" + std::to_string(m.state.composition_start) + " text=" + units(m.state.text) +
      " pending=" + units(m.state.pending_romaji) +
      " idx=" + std::to_string(m.state.candidate_index) + " ncand=" +
      std::to_string(m.state.candidates.size()) + " cands=";
  if (m.state.candidates.empty()) s += "-";
  for (size_t i = 0; i < m.state.candidates.size(); ++i)
    s += (i ? "," : "") + units(m.state.candidates[i]);
  s += " reg=" + (m.has_registration_reading ? units(m.state.registration_reading)
                                              : std::string("none"));
  s += " seq=" + (m.sequence ? std::to_string(*m.sequence) : std::string("none"));
  return s;
}

// Host-side helper: converts one engine reply line (without trailing
// newline) into a TLV message.  "STATE ..." lines that ParseStateResponse
// accepts become kKindState; everything else (and any state that exceeds a
// limit) is carried as kKindRaw so the DLL never has to parse text.
inline std::string FromReplyLine(const std::string& line) {
  Message m;
  std::string out;
  if (line.compare(0, 6, "STATE ") == 0) {
    if (auto st = ParseStateResponse(line)) {
      m.kind = kKindState;
      m.state = std::move(*st);
      m.has_registration_reading = m.state.mode == L"registration";
      if (Encode(m, &out)) return out;
    }
  }
  Message raw;
  raw.kind = kKindRaw;
  raw.raw_line = line.size() > kMaxStringBytes ? "ERR tlv-reply-too-large" : line;
  Encode(raw, &out);
  return out;
}

}  // namespace ddskk::tlv
