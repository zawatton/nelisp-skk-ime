// GPL-3.0-or-later.
#include "mmap_index.h"
#include <psapi.h>
#include <algorithm>
#include <chrono>
#include <fstream>
#include <iostream>
#include <random>
#include <stdexcept>

using Clock = std::chrono::steady_clock;
double Milliseconds(Clock::time_point start) {
  return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}
void Memory() {
  PROCESS_MEMORY_COUNTERS_EX counters{};
  if (!GetProcessMemoryInfo(GetCurrentProcess(), reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&counters), sizeof(counters)))
    throw std::runtime_error("memory counters unavailable");
  std::cout << " ws_bytes=" << counters.WorkingSetSize << " peak_ws_bytes=" << counters.PeakWorkingSetSize
            << " private_bytes=" << counters.PrivateUsage << '\n';
}
void Require(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
void Write(const std::filesystem::path& path, std::string_view text) {
  std::ofstream out(path, std::ios::binary); out << text;
  if (!out) throw std::runtime_error("fixture write failed");
}
void Selftest(const std::filesystem::path& dir) {
  std::filesystem::create_directories(dir);
  const auto shared = dir / "shared.jisyo", user = dir / "user.jisyo", file = dir / "index.bin";
  Write(shared, "\xef\xbb\xbf;; okuri-ari entries.\r\nかk /書;note/掛/[く/掛/書/]/\r\n;; okuri-nasi entries.\nかな /仮名/哉/\nabc /old/\nabc /last/\nbroken\n");
  Write(user, "かな /哉/私語/\nかk /掛/[く/掛/]/\n");
  lf::Build(shared, user, file);
  {
    lf::Index index(file);
    Require(index.count() == 3, "count/BOM/CRLF/invalid lines");
    Require(index.Lookup("abc").shared == "/last/", "duplicate key last wins");
    Require(index.Lookup("missing").shared.empty(), "missing lookup");
    Require(lf::PlainCandidates(index.Lookup("かな")) == std::vector<std::string>{"哉", "私語", "仮名"}, "user first and exact union");
    Require(index.Lookup("かk").shared == "/書;note/掛/[く/掛/書/]/", "raw block preserved");
    Require(lf::PlainCandidates(index.Lookup("かk")) == std::vector<std::string>{"掛", "書;note"}, "plain block exclusion/annotation");
  }
  auto rejects = [&](const char* message) {
    bool rejected = false;
    try { lf::Index bad(file); } catch (const std::runtime_error&) { rejected = true; }
    Require(rejected, message);
  };
  Write(file, "short"); rejects("truncation accepted");
  lf::Build(shared, user, file);
  {
    std::fstream corrupt(file, std::ios::in | std::ios::out | std::ios::binary);
    uint64_t invalid = UINT64_MAX;
    corrupt.seekp(sizeof(lf::Header));
    corrupt.write(reinterpret_cast<const char*>(&invalid), sizeof(invalid));
  }
  rejects("invalid payload bounds accepted");
  lf::Build(shared, user, file);
  {
    std::fstream corrupt(file, std::ios::in | std::ios::out | std::ios::binary);
    uint64_t invalid = 99;
    corrupt.seekp(8); corrupt.write(reinterpret_cast<const char*>(&invalid), sizeof(invalid));
  }
  rejects("unsupported version accepted");
  std::cout << "PASS selftest 6 positive checks; 3 corrupt-index negative controls\n";
}
int wmain(int argc, wchar_t** argv) {
  try {
    if (argc == 3 && std::wstring_view(argv[1]) == L"selftest") { Selftest(argv[2]); return 0; }
    if (argc == 5 && std::wstring_view(argv[1]) == L"build") {
      const auto start = Clock::now();
      const auto bytes = lf::Build(argv[2], argv[3], argv[4]);
      std::cout << "BUILD ms=" << Milliseconds(start) << " index_bytes=" << bytes;
      Memory(); return 0;
    }
    if (argc == 5 && std::wstring_view(argv[1]) == L"bench") {
      const auto start = Clock::now();
      lf::Index index(argv[2]);
      std::cout << "OPEN validation_ms=" << Milliseconds(start) << " entries=" << index.count()
                << " mapped_bytes=" << index.bytes();
      Memory();
      std::ifstream corpus(std::filesystem::path(argv[3]), std::ios::binary);
      if (!corpus) throw std::runtime_error("corpus unreadable");
      std::vector<std::string> keys;
      std::string line;
      while (std::getline(corpus, line)) { if (!line.empty() && line.back() == '\r') line.pop_back(); if (!line.empty()) keys.push_back(line); }
      Require(!keys.empty(), "empty corpus");
      const auto iterations = std::stoull(argv[4]);
      Require(iterations >= 1000 && iterations <= 10000000, "iterations must be 1000..10000000");
      uint64_t checksum = 0, hits = 0;
      std::mt19937 rng(17);
      std::vector<size_t> order;
      order.reserve(iterations);
      for (uint64_t i = 0; i < iterations; ++i) order.push_back(rng() % keys.size());
      for (const auto& key : keys) {
        const auto hit = index.Lookup(key);
        const auto candidates = lf::PlainCandidates(hit);
        if (keys.size() <= 32)
          std::cout << "CORPUS key=" << key << " plain_candidates=" << candidates.size() << '\n';
        checksum += hit.user.size() + hit.shared.size();
      }
      std::cout << "CORPUS keys=" << keys.size() << " seed=17 warmup=one-pass\n";
      for (const bool materialize : {false, true}) {
        std::vector<double> times; times.reserve(iterations);
        hits = 0;
        for (const auto i : order) {
          const auto before = Clock::now();
          const auto hit = index.Lookup(keys[i]);
          if (materialize) checksum += lf::PlainCandidates(hit).size();
          else checksum += hit.user.size() + hit.shared.size();
          times.push_back(std::chrono::duration<double, std::micro>(Clock::now() - before).count());
          hits += !hit.user.empty() || !hit.shared.empty();
        }
        std::sort(times.begin(), times.end());
        std::cout << (materialize ? "LOOKUP_PLUS_PLAIN" : "LOOKUP_VIEWS") << " n=" << iterations
                  << " hits=" << hits << " p50_us=" << times[(iterations * 50 + 99) / 100 - 1]
                  << " p99_us=" << times[(iterations * 99 + 99) / 100 - 1] << " max_us=" << times.back()
                  << " checksum=" << checksum;
        Memory();
      }
      return 0;
    }
    std::cerr << "Usage: local-first-bench build SHARED USER OUTPUT | bench INDEX CORPUS ITERATIONS | selftest DIRECTORY\n";
    return 2;
  } catch (const std::exception& error) { std::cerr << "FAIL " << error.what() << '\n'; return 1; }
}
