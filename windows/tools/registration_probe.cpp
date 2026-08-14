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

#include "guids.h"

#include <msctf.h>
#include <windows.h>

#include <iostream>

namespace {
constexpr LANGID kJapanese = MAKELANGID(LANG_JAPANESE, SUBLANG_DEFAULT);
constexpr wchar_t kDescription[] = L"DDSKK (NeLisp)";

void Print(const wchar_t* stage, HRESULT result) {
  std::wcout << stage << L": 0x" << std::hex
             << static_cast<unsigned long>(result) << L'\n';
}
}

int wmain() {
  HRESULT result = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (FAILED(result)) { Print(L"CoInitializeEx", result); return 2; }

  ITfInputProcessorProfiles* profiles = nullptr;
  result = CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr,
      CLSCTX_INPROC_SERVER, IID_ITfInputProcessorProfiles,
      reinterpret_cast<void**>(&profiles));
  Print(L"Create profiles", result);
  if (SUCCEEDED(result)) {
    result = profiles->Register(CLSID_DdskkTextService);
    Print(L"Profiles.Register", result);
    if (SUCCEEDED(result)) {
      result = profiles->AddLanguageProfile(
          CLSID_DdskkTextService, kJapanese, GUID_DdskkProfile,
          kDescription, static_cast<ULONG>(wcslen(kDescription)), nullptr, 0, 0);
      Print(L"Profiles.AddLanguageProfile", result);
      if (SUCCEEDED(result)) {
        result = profiles->EnableLanguageProfile(
            CLSID_DdskkTextService, kJapanese, GUID_DdskkProfile, TRUE);
        Print(L"Profiles.EnableLanguageProfile", result);
        profiles->EnableLanguageProfile(CLSID_DdskkTextService, kJapanese,
                                        GUID_DdskkProfile, FALSE);
      }
      profiles->RemoveLanguageProfile(CLSID_DdskkTextService, kJapanese,
                                      GUID_DdskkProfile);
      profiles->Unregister(CLSID_DdskkTextService);
    }
    profiles->Release();
  }

  ITfCategoryMgr* categories = nullptr;
  result = CoCreateInstance(CLSID_TF_CategoryMgr, nullptr, CLSCTX_INPROC_SERVER,
      IID_ITfCategoryMgr, reinterpret_cast<void**>(&categories));
  Print(L"Create categories", result);
  if (SUCCEEDED(result)) {
    result = categories->RegisterCategory(CLSID_DdskkTextService,
        GUID_TFCAT_TIP_KEYBOARD, CLSID_DdskkTextService);
    Print(L"Categories.Keyboard", result);
    if (SUCCEEDED(result)) categories->UnregisterCategory(
        CLSID_DdskkTextService, GUID_TFCAT_TIP_KEYBOARD,
        CLSID_DdskkTextService);
    result = categories->RegisterCategory(CLSID_DdskkTextService,
        GUID_TFCAT_DISPLAYATTRIBUTEPROVIDER, CLSID_DdskkTextService);
    Print(L"Categories.DisplayAttribute", result);
    if (SUCCEEDED(result)) categories->UnregisterCategory(
        CLSID_DdskkTextService, GUID_TFCAT_DISPLAYATTRIBUTEPROVIDER,
        CLSID_DdskkTextService);
    categories->Release();
  }
  CoUninitialize();
  return 0;
}
