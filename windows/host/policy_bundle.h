// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <wincrypt.h>
#include <filesystem>

namespace policy_bundle {
inline std::string Sha256(const std::wstring& path) {
  HCRYPTPROV provider = 0; HCRYPTHASH hash = 0;
  if (!CryptAcquireContextW(&provider, nullptr, nullptr, PROV_RSA_AES,
                            CRYPT_VERIFYCONTEXT)) return {};
  std::string result;
  if (CryptCreateHash(provider, CALG_SHA_256, 0, 0, &hash)) {
    std::ifstream input(path, std::ios::binary);
    char buffer[65536]; bool ok = input.is_open();
    while (ok && input.read(buffer, sizeof(buffer)).gcount()) {
      ok = CryptHashData(hash, reinterpret_cast<BYTE*>(buffer),
                         static_cast<DWORD>(input.gcount()), 0) != FALSE;
    }
    BYTE digest[32]; DWORD size = sizeof(digest);
    if (ok && input.eof() && CryptGetHashParam(hash, HP_HASHVAL, digest, &size, 0)) {
      constexpr char hex[] = "0123456789abcdef";
      for (BYTE byte : digest) { result += hex[byte >> 4]; result += hex[byte & 15]; }
    }
    CryptDestroyHash(hash);
  }
  CryptReleaseContext(provider, 0); return result;
}
// An absent manifest preserves S1-S4 startup. A supplied incompatible bundle
// disables every managed switch before any child starts; CLI stays unchanged.
inline bool Compatible(const std::wstring& runtime, const std::wstring& repository) {
  wchar_t path[32768]{};
  const auto length = GetEnvironmentVariableW(L"DDSKK_HOST_BUNDLE_MANIFEST", path, 32768);
  if (!length) return true;
  std::map<std::string, std::string> fields;
  std::ifstream input(path, std::ios::binary); std::string line;
  bool valid = length < 32768 && input.is_open(); size_t bytes = 0;
  while (valid && std::getline(input, line)) {
    bytes += line.size(); if (bytes > 16384) { valid = false; break; }
    if (!line.empty() && line.back() == '\r') line.pop_back();
    const auto equal = line.find('=');
    if (equal == std::string::npos || !fields.emplace(line.substr(0, equal), line.substr(equal+1)).second)
      valid = false;
  }
  wchar_t executable[32768]{}; GetModuleFileNameW(nullptr, executable, 32768);
  auto matches = [&](const char* key, const std::wstring& file) {
    const auto actual = Sha256(file);
    return !actual.empty() && fields[key] == actual;
  };
  valid = valid && input.eof() && fields.size() == 7 && fields["schema"] == "1" &&
      fields["contract"] == "engine-host-v1" && fields["policy_ipc"] == "HP2" &&
      (fields["mode"] == "native" || fields["mode"] == "policy") &&
      matches("host_sha256", executable) && matches("runtime_sha256", runtime) &&
      matches("policy_sha256", (std::filesystem::path(repository) / "engine/host-policy.el").wstring());
  LogEvent(valid ? "bundle-compatible contract=engine-host-v1 ipc=HP2" :
      "policy-fallback native reason=incompatible-bundle-image-or-protocol");
  return valid && fields["mode"] == "policy";
}
}
