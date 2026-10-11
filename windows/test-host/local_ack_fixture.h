// Only complete, distinct durable receipts advance the harness learning fence.
#pragma once
#include <set>
#include <string>
#include <string_view>
inline size_t CountLocalAcks(std::string_view log) {
  std::set<std::string> ids;
  size_t pos = 0;
  while (pos < log.size()) {
    const auto end = log.find('\n', pos);
    if (end == std::string_view::npos) break;
    const auto line = log.substr(pos, end - pos);
    if (line.starts_with("LOCAL_ACK id=")) {
      const auto sequence = line.find(" sequence=", 13);
      if (sequence != std::string_view::npos && sequence > 13 &&
          sequence + 10 < line.size() && line[sequence + 10] >= '1' &&
          line[sequence + 10] <= '9') ids.emplace(line.substr(13, sequence - 13));
    }
    pos = end + 1;
  }
  return ids.size();
}
