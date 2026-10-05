#include "core_abi.h"
#include "text_service.h"
#include <new>
#include <cstdio>
#ifndef NATIVEIME_CORE_LABEL
#define NATIVEIME_CORE_LABEL "production"
#endif
HMODULE g_module = nullptr;
namespace {
template<class F> HRESULT CoreTry(F&& f) noexcept {
  try { return f(); }
  catch (const std::bad_alloc&) { return E_OUTOFMEMORY; }
  catch (...) { return E_FAIL; }
}
HRESULT WINAPI Create(const NativeImeCallbacks* cb, void** state) {
  return CoreTry([&]() -> HRESULT {
  if (!cb || !state || cb->size != sizeof(*cb) || cb->version != NATIVEIME_CORE_ABI ||
      !cb->query_service) return E_INVALIDARG;
  *state = nullptr;
#ifdef NATIVEIME_CORE_FAIL_INIT
  return E_FAIL;
#else
  auto* service = new (std::nothrow) TextService;
  if (!service) return E_OUTOFMEMORY;
  service->SetShimCallbacks(*cb); *state = service; return S_OK;
#endif
  });
}
void WINAPI Destroy(void* state) { static_cast<TextService*>(state)->Release(); }
HRESULT WINAPI Activate(void* state, void* tm, uint32_t id) {
  return CoreTry([&]() -> HRESULT {
  return static_cast<TextService*>(state)->Activate(static_cast<ITfThreadMgr*>(tm), id);
  });
}
void WINAPI Deactivate(void* state) { static_cast<TextService*>(state)->Deactivate(); }
HRESULT WINAPI Invoke(void* state, uint32_t op, NativeImeCall* a) {
  return CoreTry([&]() -> HRESULT {
  if (!state || !a) return E_POINTER;
  auto* s = static_cast<TextService*>(state);
  auto* c = static_cast<ITfContext*>(a->context);
  switch (op) {
    case NI_FOCUS: return s->OnSetFocus(static_cast<BOOL>(a->wparam));
    case NI_TEST_DOWN: return s->OnTestKeyDown(c, a->wparam, a->lparam, a->eaten);
    case NI_DOWN: {
      wchar_t diagnostics[2]{};
      if (GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", diagnostics, 2)) {
        std::printf("COREKEY version=%s vk=%02llX pid=%lu\n", NATIVEIME_CORE_LABEL,
          static_cast<unsigned long long>(a->wparam), GetCurrentProcessId()); std::fflush(stdout);
      }
      return s->OnKeyDown(c, a->wparam, a->lparam, a->eaten); }
    case NI_TEST_UP: return s->OnTestKeyUp(c, a->wparam, a->lparam, a->eaten);
    case NI_UP: return s->OnKeyUp(c, a->wparam, a->lparam, a->eaten);
    case NI_PRESERVED: return s->OnPreservedKey(c, *a->guid, a->eaten);
    case NI_COMPOSITION_END: return s->OnCompositionTerminated(static_cast<TfEditCookie>(a->wparam), static_cast<ITfComposition*>(a->context));
    case NI_COMPARTMENT: return s->OnChange(*a->guid);
    case NI_ENGINE: s->SelectInputEngine(a->wparam != 0); break;
    case NI_ENGINE_ID: s->SelectEngineId(a->narrow); break;
    case NI_RELOAD: s->ReloadEngine(); break;
    case NI_TOGGLE: s->ToggleInputMode(); break;
    case NI_SETTINGS: s->ShowSettings(); break;
    case NI_MODE: s->SelectInputMode(a->text); break;
    case NI_LABEL: wcscpy_s(a->label, s->CurrentModeLabel().c_str()); break;
    case NI_PALETTE: { auto p = s->CurrentModePalette(); a->palette[0] = p.background; a->palette[1] = p.border; a->palette[2] = p.text; break; }
    default: return E_INVALIDARG;
  }
  return S_OK;
  });
}
BOOL WINAPI Quiescent(void* s) { return static_cast<TextService*>(s)->CoreQuiescent(); }
HRESULT WINAPI Export(void* s, NativeImeSnapshot* v) { return CoreTry([&] { return static_cast<TextService*>(s)->ExportCoreState(v); }); }
HRESULT WINAPI Import(void* s, const NativeImeSnapshot* v) { return CoreTry([&] { return static_cast<TextService*>(s)->ImportCoreState(v); }); }
BOOL WINAPI CanUnload() { return InterlockedCompareExchange(&g_object_count, 0, 0) == 0; }
void WINAPI PrepareUnload() {
  UnregisterClassW(L"NeLispImeProviderResultWindow", g_module);
  UnregisterClassW(L"DdskkModeIndicatorWindow", g_module);
}
}
extern "C" __declspec(dllexport) HRESULT WINAPI NativeImeGetCoreApi(uint32_t version, uint32_t size, NativeImeCoreApi* api) {
  if (!api || version != NATIVEIME_CORE_ABI || size < sizeof(*api)) return E_INVALIDARG;
  *api = {sizeof(*api), NATIVEIME_CORE_ABI, NATIVEIME_CORE_LABEL, Create, Destroy,
    Activate, Deactivate, Invoke, Quiescent, Export, Import, CanUnload, PrepareUnload};
#ifdef NATIVEIME_CORE_BAD_ABI
  api->version = 999;
#endif
  return S_OK;
}
BOOL WINAPI DllMain(HINSTANCE module, DWORD reason, void*) {
  if (reason == DLL_PROCESS_ATTACH) { g_module = module; DisableThreadLibraryCalls(module); }
  return TRUE;
}
