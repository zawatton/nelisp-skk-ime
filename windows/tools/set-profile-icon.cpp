// Installs a small Hinomaru .ico and assigns it to the NeLisp IME profile.
#include "guids.h"

#include <msctf.h>
#include <windows.h>

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

namespace {
constexpr LANGID kJapanese = MAKELANGID(LANG_JAPANESE, SUBLANG_DEFAULT);
constexpr wchar_t kDescription[] = L"NeLisp IME";

void Put16(std::vector<BYTE>* bytes, uint16_t value) {
  bytes->push_back(static_cast<BYTE>(value));
  bytes->push_back(static_cast<BYTE>(value >> 8));
}

void Put32(std::vector<BYTE>* bytes, uint32_t value) {
  Put16(bytes, static_cast<uint16_t>(value));
  Put16(bytes, static_cast<uint16_t>(value >> 16));
}

bool WriteHinomaru(const std::wstring& path) {
  constexpr int size = 32;
  constexpr uint32_t pixel_bytes = size * size * 4;
  constexpr uint32_t mask_bytes = size * 4;
  constexpr uint32_t image_bytes = 40 + pixel_bytes + mask_bytes;
  std::vector<BYTE> bytes;
  bytes.reserve(22 + image_bytes);

  Put16(&bytes, 0); Put16(&bytes, 1); Put16(&bytes, 1);  // ICONDIR
  bytes.push_back(size); bytes.push_back(size);          // ICONDIRENTRY
  bytes.push_back(0); bytes.push_back(0);
  Put16(&bytes, 1); Put16(&bytes, 32);
  Put32(&bytes, image_bytes); Put32(&bytes, 22);

  Put32(&bytes, 40); Put32(&bytes, size); Put32(&bytes, size * 2);
  Put16(&bytes, 1); Put16(&bytes, 32); Put32(&bytes, BI_RGB);
  Put32(&bytes, pixel_bytes); Put32(&bytes, 0); Put32(&bytes, 0);
  Put32(&bytes, 0); Put32(&bytes, 0);

  // ICO DIB pixels are bottom-up BGRA.  The flag is an opaque white field
  // with the official deep-crimson disc centred at 3/5 of the field height.
  constexpr int centre2 = size - 1;
  constexpr int radius2 = 19;  // doubled radius: 9.5 px
  for (int y = size - 1; y >= 0; --y) {
    for (int x = 0; x < size; ++x) {
      const int dx2 = x * 2 - centre2;
      const int dy2 = y * 2 - centre2;
      const bool sun = dx2 * dx2 + dy2 * dy2 <= radius2 * radius2;
      bytes.push_back(sun ? 0x1B : 0xFF);  // B
      bytes.push_back(sun ? 0x00 : 0xFF);  // G
      bytes.push_back(sun ? 0xBC : 0xFF);  // R
      bytes.push_back(0xFF);               // A
    }
  }
  bytes.insert(bytes.end(), mask_bytes, 0);  // opaque AND mask

  HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                            CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  DWORD written = 0;
  const bool ok = WriteFile(file, bytes.data(), static_cast<DWORD>(bytes.size()),
                            &written, nullptr) && written == bytes.size();
  CloseHandle(file);
  return ok;
}
}  // namespace

int wmain() {
  wchar_t local_app_data[MAX_PATH]{};
  const DWORD length = GetEnvironmentVariableW(L"LOCALAPPDATA", local_app_data,
                                                MAX_PATH);
  if (length == 0 || length >= MAX_PATH) return 2;
  const std::wstring directory = std::wstring(local_app_data) + L"\\DDSKK";
  CreateDirectoryW(directory.c_str(), nullptr);
  const std::wstring icon_path = directory + L"\\hinomaru.ico";
  if (!WriteHinomaru(icon_path)) return 3;

  HRESULT result = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (FAILED(result)) return 4;
  ITfInputProcessorProfiles* profiles = nullptr;
  result = CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr,
      CLSCTX_INPROC_SERVER, IID_ITfInputProcessorProfiles,
      reinterpret_cast<void**>(&profiles));
  if (SUCCEEDED(result)) {
    result = profiles->Register(CLSID_DdskkTextService);
    std::fwprintf(stderr, L"Register: 0x%08lx\n", static_cast<unsigned long>(result));
    // Register returns E_FAIL when this already-installed service is present;
    // AddLanguageProfile is also the supported update path for its profile
    // description/icon, so run it in both the fresh and existing cases.
    result = profiles->AddLanguageProfile(
        CLSID_DdskkTextService, kJapanese, GUID_DdskkProfile,
        kDescription, static_cast<ULONG>(wcslen(kDescription)),
        icon_path.c_str(), static_cast<ULONG>(icon_path.size()), 0);
    std::fwprintf(stderr, L"AddLanguageProfile: 0x%08lx\n",
                  static_cast<unsigned long>(result));
    if (result == E_FAIL) {
      // The legacy API does not overwrite an existing profile. Replace only
      // that one language-profile row, leaving the COM server/categories and
      // all DDSKK settings untouched, then re-enable it immediately.
      const HRESULT removed = profiles->RemoveLanguageProfile(
          CLSID_DdskkTextService, kJapanese, GUID_DdskkProfile);
      std::fwprintf(stderr, L"RemoveLanguageProfile: 0x%08lx\n",
                    static_cast<unsigned long>(removed));
      if (SUCCEEDED(removed)) {
        result = profiles->AddLanguageProfile(
            CLSID_DdskkTextService, kJapanese, GUID_DdskkProfile,
            kDescription, static_cast<ULONG>(wcslen(kDescription)),
            icon_path.c_str(), static_cast<ULONG>(icon_path.size()), 0);
        std::fwprintf(stderr, L"AddLanguageProfile(replace): 0x%08lx\n",
                      static_cast<unsigned long>(result));
      }
    }
    if (SUCCEEDED(result)) {
      result = profiles->EnableLanguageProfile(
          CLSID_DdskkTextService, kJapanese, GUID_DdskkProfile, TRUE);
      std::fwprintf(stderr, L"EnableLanguageProfile: 0x%08lx\n",
                    static_cast<unsigned long>(result));
    }
    profiles->Release();
  }
  if (FAILED(result)) {
    // This workstation's original install is machine-wide (HKLM). TSF's
    // registration API refuses to replace that row from a normal user
    // token, but CTF intentionally overlays the matching HKCU profile key
    // (the existing Enable value already lives there). Add only the three
    // presentation values to that exact DDSKK profile.
    constexpr wchar_t profile_key[] =
        L"Software\\Microsoft\\CTF\\TIP\\"
        L"{80B44B14-B866-4EF4-A394-4FF1D87D5185}\\LanguageProfile\\"
        L"0x00000411\\{EE0012D5-8306-4388-B071-5C3C3E38F7CE}";
    HKEY key = nullptr;
    const LONG opened = RegCreateKeyExW(HKEY_CURRENT_USER, profile_key, 0,
        nullptr, 0, KEY_SET_VALUE, nullptr, &key, nullptr);
    if (opened == ERROR_SUCCESS) {
      const DWORD icon_index = 0;
      LONG status = RegSetValueExW(key, L"Description", 0, REG_SZ,
          reinterpret_cast<const BYTE*>(kDescription), sizeof(kDescription));
      if (status == ERROR_SUCCESS) {
        status = RegSetValueExW(key, L"IconFile", 0, REG_SZ,
            reinterpret_cast<const BYTE*>(icon_path.c_str()),
            static_cast<DWORD>((icon_path.size() + 1) * sizeof(wchar_t)));
      }
      if (status == ERROR_SUCCESS) {
        status = RegSetValueExW(key, L"IconIndex", 0, REG_DWORD,
            reinterpret_cast<const BYTE*>(&icon_index), sizeof(icon_index));
      }
      RegCloseKey(key);
      result = HRESULT_FROM_WIN32(status);
    } else {
      result = HRESULT_FROM_WIN32(opened);
    }
  }
  CoUninitialize();
  return SUCCEEDED(result) ? 0 : 5;
}
