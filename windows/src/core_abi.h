// Versioned C ABI. Only POD, buffers, and Windows COM service interfaces cross it.
#pragma once
#include <stdint.h>
#include <windows.h>
#define NATIVEIME_CORE_ABI 1u
#ifdef __cplusplus
extern "C" {
#endif
typedef struct NativeImeCallbacks {
  uint32_t size, version;
  void* owner;
  HRESULT (WINAPI *query_service)(void*, const GUID*, void**);
  void (WINAPI *notify_mode)(void*);
  void (WINAPI *track_ending_composition)(void*, void*, BOOL);
  uint32_t (WINAPI *publication_sequence)(void*);
  uint32_t (WINAPI *publisher_delta)(void*, int32_t);
  void (WINAPI *publication_lock)(void*, BOOL);
  uint32_t (WINAPI *publication_flushed)(void*, uint32_t);
} NativeImeCallbacks;
typedef struct NativeImeSnapshot {
  uint32_t size, version;
  uint32_t open, kana, closed_kana, needs_resync;
  wchar_t mode[32], closed_mode[32];
  char session[96];
  uintptr_t engine_pipe; // Export duplicates; the shim closes this borrowed snapshot handle.
} NativeImeSnapshot;
typedef enum NativeImeOperation {
  NI_FOCUS, NI_TEST_DOWN, NI_DOWN, NI_TEST_UP, NI_UP, NI_PRESERVED,
  NI_COMPOSITION_END, NI_COMPARTMENT, NI_ENGINE, NI_ENGINE_ID,
  NI_RELOAD, NI_TOGGLE, NI_SETTINGS, NI_MODE, NI_LABEL, NI_PALETTE
} NativeImeOperation;
typedef struct NativeImeCall {
  void* context;
  uintptr_t wparam;
  intptr_t lparam;
  BOOL* eaten;
  const GUID* guid;
  const wchar_t* text;
  const char* narrow;
  wchar_t label[32];
  uint32_t palette[3];
} NativeImeCall;
typedef struct NativeImeCoreApi {
  uint32_t size, version;
  const char* diagnostic_version;
  HRESULT (WINAPI *create)(const NativeImeCallbacks*, void**);
  void (WINAPI *destroy)(void*);
  HRESULT (WINAPI *activate)(void*, void*, uint32_t);
  void (WINAPI *deactivate)(void*);
  HRESULT (WINAPI *invoke)(void*, uint32_t, NativeImeCall*);
  BOOL (WINAPI *quiescent)(void*);
  HRESULT (WINAPI *export_state)(void*, NativeImeSnapshot*);
  HRESULT (WINAPI *import_state)(void*, const NativeImeSnapshot*);
  BOOL (WINAPI *can_unload)(void);
  void (WINAPI *prepare_unload)(void);
} NativeImeCoreApi;
typedef HRESULT (WINAPI *NativeImeGetCoreApiFn)(uint32_t, uint32_t, NativeImeCoreApi*);
#ifdef __cplusplus
}
#endif
