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
void Print(const wchar_t* stage, HRESULT result) {
  std::wcout << stage << L": 0x" << std::hex
             << static_cast<unsigned long>(result) << L'\n';
}
}  // namespace

// Registers (or, with --unregister, unregisters) the three taskbar-facing
// TSF categories used by CorvusSKK: SYSTRAYSUPPORT, IMMERSIVESUPPORT and
// INPUTMODECOMPARTMENT. They are also applied by dllmain.cpp's normal
// registration path and let Windows render the TIP identity and
// GUID_LBI_INPUTMODE as separate taskbar items (see
// TextService::AddLangBarButton()). DllRegisterServer itself is never run
// against the live installation on this machine, so this standalone tool
// lets an operator apply just these category registrations to an
// already-installed DLL without touching anything else
// DllRegisterServer would (the COM CLSID keys, the language profile,
// HKCU\Software\NativeIME defaults). It does not run itself as part of
// any build or install step here; an operator invokes it explicitly,
// once, outside of this repository's normal workflow.
//
// Requires the DLL to already be registered (CLSID_DdskkTextService must
// already resolve to an InprocServer32), since RegisterCategory only
// associates a category GUID with an already-known CLSID -- it does not
// create the CLSID registration itself.
int wmain(int argc, wchar_t** argv) {
  const bool unregister = argc > 1 && wcscmp(argv[1], L"--unregister") == 0;

  HRESULT result = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (FAILED(result)) { Print(L"CoInitializeEx", result); return 2; }

  ITfCategoryMgr* categories = nullptr;
  result = CoCreateInstance(CLSID_TF_CategoryMgr, nullptr, CLSCTX_INPROC_SERVER,
      IID_ITfCategoryMgr, reinterpret_cast<void**>(&categories));
  Print(L"Create categories", result);
  if (FAILED(result)) { CoUninitialize(); return 3; }

  HRESULT tray_result;
  HRESULT immersive_result;
  HRESULT input_mode_result;
  if (unregister) {
    tray_result = categories->UnregisterCategory(
        CLSID_DdskkTextService, GUID_TFCAT_TIPCAP_SYSTRAYSUPPORT,
        CLSID_DdskkTextService);
    Print(L"UnregisterCategory SysTraySupport", tray_result);
    immersive_result = categories->UnregisterCategory(
        CLSID_DdskkTextService, GUID_TFCAT_TIPCAP_IMMERSIVESUPPORT,
        CLSID_DdskkTextService);
    Print(L"UnregisterCategory ImmersiveSupport", immersive_result);
    input_mode_result = categories->UnregisterCategory(
        CLSID_DdskkTextService, GUID_TFCAT_TIPCAP_INPUTMODECOMPARTMENT,
        CLSID_DdskkTextService);
    Print(L"UnregisterCategory InputModeCompartment", input_mode_result);
  } else {
    tray_result = categories->RegisterCategory(
        CLSID_DdskkTextService, GUID_TFCAT_TIPCAP_SYSTRAYSUPPORT,
        CLSID_DdskkTextService);
    Print(L"RegisterCategory SysTraySupport", tray_result);
    immersive_result = categories->RegisterCategory(
        CLSID_DdskkTextService, GUID_TFCAT_TIPCAP_IMMERSIVESUPPORT,
        CLSID_DdskkTextService);
    Print(L"RegisterCategory ImmersiveSupport", immersive_result);
    input_mode_result = categories->RegisterCategory(
        CLSID_DdskkTextService, GUID_TFCAT_TIPCAP_INPUTMODECOMPARTMENT,
        CLSID_DdskkTextService);
    Print(L"RegisterCategory InputModeCompartment", input_mode_result);
  }
  categories->Release();
  CoUninitialize();
  return (FAILED(tray_result) || FAILED(immersive_result) ||
          FAILED(input_mode_result)) ? 4 : 0;
}
