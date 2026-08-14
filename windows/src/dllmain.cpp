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
#include "text_service.h"

#include <msctf.h>
#include <new>
#include <filesystem>
#include <string>

HMODULE g_module = nullptr;

namespace {
constexpr wchar_t kDescription[] = L"DDSKK (NeLisp)";
constexpr LANGID kJapanese = MAKELANGID(LANG_JAPANESE, SUBLANG_DEFAULT);

class ClassFactory final : public IClassFactory {
 public:
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** object) override {
    if (object == nullptr) return E_POINTER;
    *object = nullptr;
    if (iid != IID_IUnknown && iid != IID_IClassFactory) return E_NOINTERFACE;
    *object = static_cast<IClassFactory*>(this);
    AddRef();
    return S_OK;
  }
  ULONG STDMETHODCALLTYPE AddRef() override {
    return InterlockedIncrement(&ref_count_);
  }
  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG count = InterlockedDecrement(&ref_count_);
    if (count == 0) delete this;
    return count;
  }
  HRESULT STDMETHODCALLTYPE CreateInstance(IUnknown* outer, REFIID iid,
                                           void** object) override {
    if (outer != nullptr) return CLASS_E_NOAGGREGATION;
    auto* service = new (std::nothrow) TextService();
    if (service == nullptr) return E_OUTOFMEMORY;
    const HRESULT result = service->QueryInterface(iid, object);
    service->Release();
    return result;
  }
  HRESULT STDMETHODCALLTYPE LockServer(BOOL lock) override {
    lock ? InterlockedIncrement(&g_lock_count) : InterlockedDecrement(&g_lock_count);
    return S_OK;
  }
 private:
  ~ClassFactory() = default;
  LONG ref_count_ = 1;
};

std::wstring GuidString(REFGUID guid) {
  wchar_t text[40] = {};
  StringFromGUID2(guid, text, static_cast<int>(std::size(text)));
  return text;
}

HRESULT RegisterComServer() {
  wchar_t module_path[MAX_PATH] = {};
  if (GetModuleFileNameW(g_module, module_path, MAX_PATH) == 0) {
    return HRESULT_FROM_WIN32(GetLastError());
  }
  const std::wstring key_path = L"Software\\Classes\\CLSID\\" +
                                GuidString(CLSID_DdskkTextService);
  HKEY class_key = nullptr;
  LONG status = RegCreateKeyExW(HKEY_CURRENT_USER, key_path.c_str(), 0, nullptr,
                                0, KEY_WRITE, nullptr, &class_key, nullptr);
  if (status != ERROR_SUCCESS) return HRESULT_FROM_WIN32(status);
  RegSetValueExW(class_key, nullptr, 0, REG_SZ,
                 reinterpret_cast<const BYTE*>(kDescription), sizeof(kDescription));
  HKEY server_key = nullptr;
  status = RegCreateKeyExW(class_key, L"InprocServer32", 0, nullptr, 0,
                           KEY_WRITE, nullptr, &server_key, nullptr);
  if (status == ERROR_SUCCESS) {
    RegSetValueExW(server_key, nullptr, 0, REG_SZ,
                   reinterpret_cast<const BYTE*>(module_path),
                   static_cast<DWORD>((wcslen(module_path) + 1) * sizeof(wchar_t)));
    constexpr wchar_t threading[] = L"Apartment";
    RegSetValueExW(server_key, L"ThreadingModel", 0, REG_SZ,
                   reinterpret_cast<const BYTE*>(threading), sizeof(threading));
    RegCloseKey(server_key);
  }
  RegCloseKey(class_key);
  if (status == ERROR_SUCCESS) {
    HKEY settings = nullptr;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\NativeIME", 0, nullptr,
        0, KEY_WRITE, nullptr, &settings, nullptr) == ERROR_SUCCESS) {
      const std::filesystem::path dll(module_path);
      const auto host = dll.parent_path() / L"ddskk-engine-host.exe";
      const auto standalone = dll.parent_path() / L"nelisp-ddskk.exe";
      const auto repository = dll.parent_path().parent_path().parent_path().parent_path();
      const auto nelisp = repository.parent_path() / L"nelisp" / L"target" / L"nelisp.exe";
      const auto write = [settings](const wchar_t* name, const std::wstring& value) {
        RegSetValueExW(settings, name, 0, REG_SZ,
            reinterpret_cast<const BYTE*>(value.c_str()),
            static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
      };
      write(L"EngineHost", host.wstring());
      if (std::filesystem::exists(standalone)) {
        write(L"EngineExecutable", standalone.wstring());
        write(L"Repository", L"");
      } else {
        write(L"EngineExecutable", nelisp.wstring());
        write(L"Repository", repository.wstring());
      }
      DWORD kana = 1;
      DWORD type = 0, size = sizeof(kana);
      if (RegQueryValueExW(settings, L"InitialKanaMode", nullptr, &type,
                          reinterpret_cast<BYTE*>(&kana), &size) != ERROR_SUCCESS) {
        kana = 1;
        RegSetValueExW(settings, L"InitialKanaMode", 0, REG_DWORD,
                       reinterpret_cast<const BYTE*>(&kana), sizeof(kana));
      }
      RegCloseKey(settings);
    }
  }
  return HRESULT_FROM_WIN32(status);
}

void UnregisterComServer() {
  const std::wstring key_path = L"Software\\Classes\\CLSID\\" +
                                GuidString(CLSID_DdskkTextService);
  RegDeleteTreeW(HKEY_CURRENT_USER, key_path.c_str());
}

HRESULT RegisterProfile() {
  ITfInputProcessorProfiles* profiles = nullptr;
  HRESULT result = CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr,
      CLSCTX_INPROC_SERVER, IID_ITfInputProcessorProfiles,
      reinterpret_cast<void**>(&profiles));
  if (FAILED(result)) return result;
  result = profiles->Register(CLSID_DdskkTextService);
  if (SUCCEEDED(result)) {
    result = profiles->AddLanguageProfile(
        CLSID_DdskkTextService, kJapanese, GUID_DdskkProfile, kDescription,
        static_cast<ULONG>(wcslen(kDescription)), nullptr, 0, 0);
  }
  if (SUCCEEDED(result)) {
    result = profiles->EnableLanguageProfile(
        CLSID_DdskkTextService, kJapanese, GUID_DdskkProfile, TRUE);
  }
  profiles->Release();
  return result;
}

HRESULT RegisterCategories() {
  ITfCategoryMgr* categories = nullptr;
  HRESULT result = CoCreateInstance(
      CLSID_TF_CategoryMgr, nullptr, CLSCTX_INPROC_SERVER, IID_ITfCategoryMgr,
      reinterpret_cast<void**>(&categories));
  if (FAILED(result)) return result;
  result = categories->RegisterCategory(CLSID_DdskkTextService,
                                        GUID_TFCAT_TIP_KEYBOARD,
                                        CLSID_DdskkTextService);
  if (SUCCEEDED(result)) {
    result = categories->RegisterCategory(
        CLSID_DdskkTextService, GUID_TFCAT_DISPLAYATTRIBUTEPROVIDER,
        CLSID_DdskkTextService);
  }
  if (SUCCEEDED(result)) {
    result = categories->RegisterCategory(
        CLSID_DdskkTextService, GUID_TFCAT_TIPCAP_UIELEMENTENABLED,
        CLSID_DdskkTextService);
  }
  categories->Release();
  return result;
}

void UnregisterCategories() {
  ITfCategoryMgr* categories = nullptr;
  if (SUCCEEDED(CoCreateInstance(
          CLSID_TF_CategoryMgr, nullptr, CLSCTX_INPROC_SERVER,
          IID_ITfCategoryMgr, reinterpret_cast<void**>(&categories)))) {
    categories->UnregisterCategory(CLSID_DdskkTextService,
                                   GUID_TFCAT_TIP_KEYBOARD,
                                   CLSID_DdskkTextService);
    categories->UnregisterCategory(
        CLSID_DdskkTextService, GUID_TFCAT_DISPLAYATTRIBUTEPROVIDER,
        CLSID_DdskkTextService);
    categories->UnregisterCategory(
        CLSID_DdskkTextService, GUID_TFCAT_TIPCAP_UIELEMENTENABLED,
        CLSID_DdskkTextService);
    categories->Release();
  }
}

void UnregisterProfile() {
  ITfInputProcessorProfiles* profiles = nullptr;
  if (SUCCEEDED(CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr,
          CLSCTX_INPROC_SERVER, IID_ITfInputProcessorProfiles,
          reinterpret_cast<void**>(&profiles)))) {
    profiles->EnableLanguageProfile(CLSID_DdskkTextService, kJapanese,
                                    GUID_DdskkProfile, FALSE);
    profiles->RemoveLanguageProfile(CLSID_DdskkTextService, kJapanese,
                                    GUID_DdskkProfile);
    profiles->Unregister(CLSID_DdskkTextService);
    profiles->Release();
  }
}
}  // namespace

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, void*) {
  if (reason == DLL_PROCESS_ATTACH) {
    g_module = instance;
    DisableThreadLibraryCalls(instance);
  }
  return TRUE;
}

STDAPI DllGetClassObject(REFCLSID clsid, REFIID iid, void** object) {
  if (clsid != CLSID_DdskkTextService) return CLASS_E_CLASSNOTAVAILABLE;
  auto* factory = new (std::nothrow) ClassFactory();
  if (factory == nullptr) return E_OUTOFMEMORY;
  const HRESULT result = factory->QueryInterface(iid, object);
  factory->Release();
  return result;
}

STDAPI DllCanUnloadNow() {
  return (g_object_count == 0 && g_lock_count == 0) ? S_OK : S_FALSE;
}

STDAPI DllRegisterServer() {
  HRESULT result = RegisterComServer();
  if (FAILED(result)) return result;
  result = RegisterProfile();
  if (SUCCEEDED(result)) result = RegisterCategories();
  if (FAILED(result)) {
    UnregisterCategories();
    UnregisterProfile();
    UnregisterComServer();
  }
  return result;
}

STDAPI DllUnregisterServer() {
  UnregisterCategories();
  UnregisterProfile();
  UnregisterComServer();
  return S_OK;
}
