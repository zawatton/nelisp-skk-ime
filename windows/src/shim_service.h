#pragma once
#include "core_abi.h"
#include "guids.h"
#include "langbar_button.h"
#include "display_attribute.h"
#include "registry_watcher.h"
#include <memory>
#include <msctf.h>
#include <ctffunc.h>
struct NativeImeModule;
class ShimService final : public ITfTextInputProcessorEx, public ITfKeyEventSink,
    public ITfDisplayAttributeProvider, public ITfFunctionProvider,
    public ITfFnConfigure, public ITfCompositionSink, public ITfCompartmentEventSink,
    public LangBarButtonHandler {
 public:
  ShimService();
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID, void**) override;
  ULONG STDMETHODCALLTYPE AddRef() override;
  ULONG STDMETHODCALLTYPE Release() override;
  HRESULT STDMETHODCALLTYPE Activate(ITfThreadMgr*, TfClientId) override;
  HRESULT STDMETHODCALLTYPE ActivateEx(ITfThreadMgr* tm, TfClientId id, DWORD) override { return Activate(tm, id); }
  HRESULT STDMETHODCALLTYPE Deactivate() override;
  HRESULT STDMETHODCALLTYPE OnSetFocus(BOOL) override;
  HRESULT STDMETHODCALLTYPE OnTestKeyDown(ITfContext*, WPARAM, LPARAM, BOOL*) override;
  HRESULT STDMETHODCALLTYPE OnKeyDown(ITfContext*, WPARAM, LPARAM, BOOL*) override;
  HRESULT STDMETHODCALLTYPE OnTestKeyUp(ITfContext*, WPARAM, LPARAM, BOOL*) override;
  HRESULT STDMETHODCALLTYPE OnKeyUp(ITfContext*, WPARAM, LPARAM, BOOL*) override;
  HRESULT STDMETHODCALLTYPE OnPreservedKey(ITfContext*, REFGUID, BOOL*) override;
  HRESULT STDMETHODCALLTYPE EnumDisplayAttributeInfo(IEnumTfDisplayAttributeInfo**) override;
  HRESULT STDMETHODCALLTYPE GetDisplayAttributeInfo(REFGUID, ITfDisplayAttributeInfo**) override;
  HRESULT STDMETHODCALLTYPE GetType(GUID*) override;
  HRESULT STDMETHODCALLTYPE GetDescription(BSTR*) override;
  HRESULT STDMETHODCALLTYPE GetFunction(REFGUID, REFIID, IUnknown**) override;
  HRESULT STDMETHODCALLTYPE GetDisplayName(BSTR*) override;
  HRESULT STDMETHODCALLTYPE Show(HWND, LANGID, REFGUID) override;
  HRESULT STDMETHODCALLTYPE OnCompositionTerminated(TfEditCookie, ITfComposition*) override;
  HRESULT STDMETHODCALLTYPE OnChange(REFGUID) override;
  void SelectInputEngine(bool) override;
  void SelectEngineId(const std::string&) override;
  void ReloadEngine() override;
  void ToggleInputMode() override;
  void ShowSettings() override;
  void SelectInputMode(const std::wstring&) override;
  std::wstring CurrentModeLabel() const override;
  ModeIndicatorPalette CurrentModePalette() const override;
 private:
  ~ShimService();
  static uint32_t WINAPI PublicationSequence(void*);
  static uint32_t WINAPI PublisherDelta(void*, int32_t);
  static void WINAPI PublicationLock(void*, BOOL);
  static uint32_t WINAPI PublicationFlushed(void*, uint32_t);
  static void WINAPI TrackEnding(void*, void*, BOOL);
  std::vector<IUnknown*> ending_compositions_;
  static void WINAPI NotifyMode(void*);
  static HRESULT WINAPI QueryService(void*, const GUID*, void**);
  static LRESULT CALLBACK WindowProc(HWND, UINT, WPARAM, LPARAM);
  HRESULT Invoke(uint32_t, NativeImeCall&) const;
  HRESULT Key(uint32_t, ITfContext*, WPARAM, LPARAM, BOOL*);
  HRESULT CreateCore(const std::wstring&, std::shared_ptr<NativeImeModule>&, void**);
  void TrySwap();
  std::wstring RequestedPath() const;
  void AddButtons();
  void RemoveButtons();
  LONG refs_ = 1;
  mutable unsigned calls_ = 0;
  bool switching_ = false, key_pair_ = false;
  ITfThreadMgr* tm_ = nullptr;
  TfClientId id_ = TF_CLIENTID_NULL;
  ITfSource* compartment_source_ = nullptr;
  DWORD compartment_cookie_ = TF_INVALID_COOKIE;
  HWND window_ = nullptr;
  RegistryWatcher watcher_;
  std::shared_ptr<NativeImeModule> module_;
  void* state_ = nullptr;
  std::wstring requested_;
  bool pending_ = false;
  LangBarButton* settings_button_ = nullptr;
  LangBarButton* input_mode_button_ = nullptr;
};
extern HMODULE g_module;
extern LONG g_object_count, g_lock_count;
