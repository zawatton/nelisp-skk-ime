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
//
// tsf-host: a minimal, self-contained TSF (Text Services Framework) client
// that drives the REAL, already-registered ddskk-ime text service
// end-to-end -- key events in, document text out -- with no human typing
// and no UI beyond a single hidden top-level window.
//
// This program does not implement any SKK/DDSKK logic itself. It only
// implements the client-side plumbing every TSF host needs regardless of
// which text service is attached: a thread manager, a document/context
// pair backed by a minimal ITextStoreACP, and a keystroke feed through
// ITfKeystrokeMgr. Whatever composition/candidate/commit behavior shows up
// in the printed log is entirely the attached text service's (ddskk-ime's)
// doing.
//
// Usage:
//   tsf-host.exe ["TOKEN TOKEN TOKEN ..."]
//
// With no argument, the program only initializes TSF, attempts to
// activate the ddskk-ime language profile, and exits -- useful as a smoke
// test that does not require a scripted session.
//
// The optional argument is a single, space-separated list of tokens.
// Each token is one of:
//   a-z, 0-9      unshifted key (VK for the letter/digit)
//   A-Z           shifted key (Shift + the letter's VK)
//   S0..S9        Shift + digit
//   SPACE         VK_SPACE
//   ENTER         VK_RETURN
//   BS            VK_BACK
//   ESC           VK_ESCAPE
//   CTRLJ         Ctrl+J (skk-kakutei-key)
//   CTRLC/CTRLW   arbitrary Ctrl + letter shortcut
//   LEFT/RIGHT    segment navigation
//   SLEFT/SRIGHT  Shift+arrow segment resize
//   F6..F10       character-class conversion
//   IMEOFF/IMEON  set TSF keyboard open/close compartment
//   WAIT500       sleep 500 ms (no key event)
//   SETTLE30000   pump until provider idle and document quiet for 100 ms;
//                 fail after 30000 ms. SETTLE30000:label retains an AFTER
//                 observation label (e.g. WAIT500) for existing log consumers.
//   KEYSTATE:SHIFT/KEYSTATE:CLEAR  seed ambient modifiers in this private thread
//
// After every token the program prints one UTF-8 line to stdout:
//   AFTER <token> BUF=[<buffer>] SEL=<start>,<end> COMP=<span-or-dash>
//
// Any failed HRESULT along the way is reported as:
//   HR <where>=<hex>
// and execution continues wherever that is sensible, so a single failed
// step does not abort the whole script.

// WIN32_LEAN_AND_MEAN / NOMINMAX / UNICODE / _UNICODE are supplied by
// CMakeLists.txt's target_compile_definitions(tsf-host ...), matching the
// rest of this project's targets.
#include <windows.h>
#include "callback_io_probe.h"
#include <tlhelp32.h>

#include <objidl.h>
#include <olectl.h>
#include <textstor.h>
#include <msctf.h>

#include "guids.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cwctype>
#include <new>
#include <sstream>
#include <string>

namespace {

// ---------------------------------------------------------------------
// Small diagnostic helpers.
// ---------------------------------------------------------------------

void PrintHr(const char* where, HRESULT hr) {
  std::printf("HR %s=%08lx\n", where, static_cast<unsigned long>(hr));
}

void PrintHrStr(const std::string& where, HRESULT hr) {
  std::printf("HR %s=%08lx\n", where.c_str(), static_cast<unsigned long>(hr));
}

// DDSKK_HARNESS_DLL_PATH, if set, loads the TIP directly from that DLL
// file (LoadLibraryW + DllGetClassObject + IClassFactory::CreateInstance)
// instead of the normal CoCreateInstance(CLSID_DdskkTextService, ...)
// path below, which always resolves through the registered
// HKCU\...\CLSID\{...}\InprocServer32 path -- a fixed, already-deployed
// DLL copy this harness has no way to repoint without a registry write.
// This exists purely for verifying a freshly built DLL (e.g. this
// repository's own windows/build/Release/ddskk-ime.dll) that has not
// been deployed over that registered path, especially when the
// registered copy is locked (in use by some other already-running
// process) and can't simply be overwritten in place either. Returns
// nullptr if loading fails. The harness fails closed in that case; it never
// falls back to the installed COM service.
// The unregistered direct TIP has no Windows foreground-sink slot. Supply
// only that slot locally, while all document/compartment interfaces remain
// the real isolated Windows TSF manager. Scripted keys call the real TIP.
class DirectThreadMgr final : public ITfThreadMgr, public ITfKeystrokeMgr {
 public:
  explicit DirectThreadMgr(ITfThreadMgr* manager) : manager_(manager) { manager_->AddRef(); }
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override {
    if (!out) return E_POINTER;
    if (iid == IID_IUnknown || iid == IID_ITfThreadMgr) *out = static_cast<ITfThreadMgr*>(this);
    else if (iid == IID_ITfKeystrokeMgr) *out = static_cast<ITfKeystrokeMgr*>(this);
    else return manager_->QueryInterface(iid, out);
    AddRef(); return S_OK;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++refs_; }
  ULONG STDMETHODCALLTYPE Release() override { const ULONG n = --refs_; if (!n) delete this; return n; }
  HRESULT STDMETHODCALLTYPE Activate(TfClientId* id) override { return manager_->Activate(id); }
  HRESULT STDMETHODCALLTYPE Deactivate() override { return manager_->Deactivate(); }
  HRESULT STDMETHODCALLTYPE CreateDocumentMgr(ITfDocumentMgr** out) override { return manager_->CreateDocumentMgr(out); }
  HRESULT STDMETHODCALLTYPE EnumDocumentMgrs(IEnumTfDocumentMgrs** out) override { return manager_->EnumDocumentMgrs(out); }
  HRESULT STDMETHODCALLTYPE GetFocus(ITfDocumentMgr** out) override { return manager_->GetFocus(out); }
  HRESULT STDMETHODCALLTYPE SetFocus(ITfDocumentMgr* doc) override { return manager_->SetFocus(doc); }
  HRESULT STDMETHODCALLTYPE AssociateFocus(HWND window, ITfDocumentMgr* doc, ITfDocumentMgr** old) override { return manager_->AssociateFocus(window, doc, old); }
  HRESULT STDMETHODCALLTYPE IsThreadFocus(BOOL* value) override { return manager_->IsThreadFocus(value); }
  HRESULT STDMETHODCALLTYPE GetFunctionProvider(REFCLSID id, ITfFunctionProvider** out) override { return manager_->GetFunctionProvider(id, out); }
  HRESULT STDMETHODCALLTYPE EnumFunctionProviders(IEnumTfFunctionProviders** out) override { return manager_->EnumFunctionProviders(out); }
  HRESULT STDMETHODCALLTYPE GetGlobalCompartment(ITfCompartmentMgr** out) override { return manager_->GetGlobalCompartment(out); }
  HRESULT STDMETHODCALLTYPE AdviseKeyEventSink(TfClientId, ITfKeyEventSink* sink, BOOL) override {
    if (!sink || sink_) return E_INVALIDARG;
    sink_ = sink; sink_->AddRef(); return S_OK;
  }
  HRESULT STDMETHODCALLTYPE UnadviseKeyEventSink(TfClientId) override {
    if (sink_) { auto* sink = sink_; sink_ = nullptr; sink->Release(); } return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetForeground(CLSID*) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE TestKeyDown(WPARAM, LPARAM, BOOL*) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE TestKeyUp(WPARAM, LPARAM, BOOL*) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE KeyDown(WPARAM, LPARAM, BOOL*) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE KeyUp(WPARAM, LPARAM, BOOL*) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE GetPreservedKey(ITfContext*, const TF_PRESERVEDKEY*, GUID*) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE IsPreservedKey(REFGUID, const TF_PRESERVEDKEY*, BOOL*) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE PreserveKey(TfClientId, REFGUID, const TF_PRESERVEDKEY*, const WCHAR*, ULONG) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE UnpreserveKey(REFGUID, const TF_PRESERVEDKEY*) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE SetPreservedKeyDescription(REFGUID, const WCHAR*, ULONG) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE GetPreservedKeyDescription(REFGUID, BSTR*) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE SimulatePreservedKey(ITfContext*, REFGUID, BOOL*) override { return E_NOTIMPL; }
 private:
  ~DirectThreadMgr() { manager_->Release(); }
  ULONG refs_ = 1;
  ITfThreadMgr* manager_;
  ITfKeyEventSink* sink_ = nullptr;
};

ITfTextInputProcessor* CreateTipFromDllPath() {
  wchar_t dll_path[MAX_PATH]{};
  const DWORD size =
      GetEnvironmentVariableW(L"DDSKK_HARNESS_DLL_PATH", dll_path, MAX_PATH);
  if (size == 0 || size >= MAX_PATH) return nullptr;

  const HMODULE module = LoadLibraryW(dll_path);
  if (module == nullptr) {
    std::printf("HR LoadLibraryW(DDSKK_HARNESS_DLL_PATH)=%08lx\n",
               static_cast<unsigned long>(HRESULT_FROM_WIN32(GetLastError())));
    return nullptr;
  }

  using DllGetClassObjectFn = HRESULT(WINAPI*)(REFCLSID, REFIID, void**);
  const auto get_class_object = reinterpret_cast<DllGetClassObjectFn>(
      GetProcAddress(module, "DllGetClassObject"));
  if (get_class_object == nullptr) return nullptr;

  IClassFactory* factory = nullptr;
  HRESULT hr = get_class_object(CLSID_DdskkTextService, IID_IClassFactory,
                                reinterpret_cast<void**>(&factory));
  if (FAILED(hr) || factory == nullptr) {
    PrintHr("DllGetClassObject(DDSKK_HARNESS_DLL_PATH)", hr);
    return nullptr;
  }

  ITfTextInputProcessor* tip = nullptr;
  hr = factory->CreateInstance(nullptr, IID_ITfTextInputProcessor,
                               reinterpret_cast<void**>(&tip));
  factory->Release();
  if (FAILED(hr)) {
    PrintHr("IClassFactory::CreateInstance(DDSKK_HARNESS_DLL_PATH)", hr);
    return nullptr;
  }
  std::printf("TIP_DIRECT loaded from DDSKK_HARNESS_DLL_PATH\n");
  return tip;
}

std::string Utf8FromWide(const std::wstring& wide) {
  if (wide.empty()) return std::string();
  const int needed = WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                                          static_cast<int>(wide.size()),
                                          nullptr, 0, nullptr, nullptr);
  if (needed <= 0) return std::string();
  std::string out(static_cast<size_t>(needed), '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
                       out.data(), needed, nullptr, nullptr);
  return out;
}

// ---------------------------------------------------------------------
// DocumentStore: a minimal, honest ITextStoreACP +
// ITfContextOwnerCompositionSink. It backs a single ACP document with an
// in-memory buffer and a single selection, and grants locks synchronously
// (re-entrantly if needed) exactly the way the TSF documentation describes
// for a document that never has to defer to another thread.
// ---------------------------------------------------------------------
class DocumentStore final : public ITextStoreACP,
                            public ITfContextOwnerCompositionSink {
 public:
  explicit DocumentStore(HWND hwnd) : hwnd_(hwnd) {}

  // --- IUnknown -------------------------------------------------------
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** obj) override {
    if (obj == nullptr) return E_POINTER;
    *obj = nullptr;
    if (iid == IID_IUnknown || iid == IID_ITextStoreACP) {
      *obj = static_cast<ITextStoreACP*>(this);
    } else if (iid == IID_ITfContextOwnerCompositionSink) {
      *obj = static_cast<ITfContextOwnerCompositionSink*>(this);
    } else {
      return E_NOINTERFACE;
    }
    AddRef();
    return S_OK;
  }
  ULONG STDMETHODCALLTYPE AddRef() override {
    return static_cast<ULONG>(InterlockedIncrement(&ref_count_));
  }
  ULONG STDMETHODCALLTYPE Release() override {
    const LONG count = InterlockedDecrement(&ref_count_);
    if (count == 0) delete this;
    return static_cast<ULONG>(count);
  }

  // --- ITextStoreACP: sink advise/unadvise --------------------------
  HRESULT STDMETHODCALLTYPE AdviseSink(REFIID riid, IUnknown* punk,
                                       DWORD dwMask) override {
    if (punk == nullptr) return E_INVALIDARG;
    if (riid != IID_ITextStoreACPSink) return E_INVALIDARG;
    ITextStoreACPSink* sink = nullptr;
    const HRESULT hr =
        punk->QueryInterface(IID_ITextStoreACPSink,
                             reinterpret_cast<void**>(&sink));
    if (FAILED(hr)) return hr;
    if (sink_ != nullptr) sink_->Release();
    sink_ = sink;
    sink_mask_ = dwMask;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE UnadviseSink(IUnknown* punk) override {
    if (punk == nullptr) return E_INVALIDARG;
    ITextStoreACPSink* candidate = nullptr;
    if (FAILED(punk->QueryInterface(IID_ITextStoreACPSink,
                                    reinterpret_cast<void**>(&candidate)))) {
      return CONNECT_E_NOCONNECTION;
    }
    const bool match = candidate == sink_;
    candidate->Release();
    if (!match) return CONNECT_E_NOCONNECTION;
    sink_->Release();
    sink_ = nullptr;
    sink_mask_ = 0;
    return S_OK;
  }

  // --- Locking ----------------------------------------------------------
  // Granted synchronously and, when requested re-entrantly while already
  // locked, either rejected (TS_LF_SYNC) or queued and granted right
  // after the outer lock releases (async) -- see the TSF documentation
  // for ITextStoreACP::RequestLock.
  HRESULT STDMETHODCALLTYPE RequestLock(DWORD dwLockFlags,
                                        HRESULT* phrSession) override {
    if (phrSession == nullptr) return E_INVALIDARG;
    if (sink_ == nullptr) {
      *phrSession = E_UNEXPECTED;
      return E_UNEXPECTED;
    }
    if ((refuse_next_write_ || GetTickCount64() < refuse_write_until_) &&
        (dwLockFlags & TS_LF_READWRITE) == TS_LF_READWRITE) {
      refuse_next_write_ = false;
      *phrSession = TS_E_READONLY;
      std::printf("EDIT_REFUSED flags=%lu\n", dwLockFlags);
      return S_OK;
    }
    // DENYWRITE models refusal, not a request to retry asynchronously. It
    // must reject ASYNCDONTCARE/ASYNC writes too, before the delayed-lock seam.
    if ((deny_next_write_ || GetTickCount64() < deny_write_until_) &&
        (dwLockFlags & TS_LF_READWRITE) == TS_LF_READWRITE) {
      deny_next_write_ = false;
      *phrSession = TS_E_READONLY;
      std::printf("EDIT_DENIED sync=%d flags=%lu\n", (dwLockFlags & TS_LF_SYNC) != 0, dwLockFlags);
      return S_OK;
    }
    if (async_writes_ && (dwLockFlags & TS_LF_READWRITE) == TS_LF_READWRITE) {
      if (dwLockFlags & TS_LF_SYNC) {
        *phrSession = TS_E_SYNCHRONOUS;
      } else {
        pending_lock_ = true;
        pending_lock_flags_ = dwLockFlags;
        *phrSession = TS_S_ASYNC;
      }
      std::printf("EDIT_ASYNC queued=%d flags=%lu tick=%llu\n",
                  pending_lock_ ? 1 : 0, dwLockFlags, GetTickCount64());
      return S_OK;
    }
    if (locked_) {
      if (dwLockFlags & TS_LF_SYNC) {
        *phrSession = TS_E_SYNCHRONOUS;
        return S_OK;
      }
      pending_lock_ = true;
      pending_lock_flags_ = dwLockFlags;
      *phrSession = TS_S_ASYNC;
      return S_OK;
    }
    locked_ = true;
    current_lock_flags_ = dwLockFlags;
    ++lock_sequence_;
    *phrSession = sink_->OnLockGranted(dwLockFlags);
    locked_ = false;
    current_lock_flags_ = 0;
    // Grant any lock(s) that arrived re-entrantly while we were locked,
    // now that the outer lock has released. sink_->OnLockGranted() below
    // may itself re-enter RequestLock and queue another one, so this is a
    // loop, not a single follow-up call.
    while (pending_lock_ && !async_writes_) {
      pending_lock_ = false;
      const DWORD flags = pending_lock_flags_;
      locked_ = true;
      current_lock_flags_ = flags;
      ++lock_sequence_;
      sink_->OnLockGranted(flags);
      locked_ = false;
      current_lock_flags_ = 0;
    }
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE GetStatus(TS_STATUS* pdcs) override {
    if (pdcs == nullptr) return E_INVALIDARG;
    pdcs->dwDynamicFlags = 0;  // not TS_SD_LOADING: a normal, ready document
    pdcs->dwStaticFlags = 0;   // a plain top-level document, no restrictions
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE QueryInsert(LONG acpTestStart, LONG acpTestEnd,
                                        ULONG /*cch*/,
                                        LONG* pacpResultStart,
                                        LONG* pacpResultEnd) override {
    if (pacpResultStart == nullptr || pacpResultEnd == nullptr) {
      return E_INVALIDARG;
    }
    const LONG len = static_cast<LONG>(buffer_.size());
    LONG start = std::clamp(acpTestStart, 0L, len);
    LONG end = std::clamp(acpTestEnd, 0L, len);
    if (end < start) std::swap(start, end);
    *pacpResultStart = start;
    *pacpResultEnd = end;
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE GetSelection(ULONG ulIndex, ULONG ulCount,
                                         TS_SELECTION_ACP* pSelection,
                                         ULONG* pcFetched) override {
    if (pSelection == nullptr || pcFetched == nullptr) return E_INVALIDARG;
    *pcFetched = 0;
    if (!locked_) return TS_E_NOLOCK;
    if (ulCount == 0) return S_OK;
    (void)ulIndex;  // only one selection is ever modeled
    pSelection[0].acpStart = sel_start_;
    pSelection[0].acpEnd = sel_end_;
    pSelection[0].style.ase = TS_AE_END;
    pSelection[0].style.fInterimChar = FALSE;
    *pcFetched = 1;
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE SetSelection(
      ULONG ulCount, const TS_SELECTION_ACP* pSelection) override {
    if (!locked_ || !IsReadWriteLocked()) return TS_E_NOLOCK;
    if (ulCount == 0) return S_OK;
    if (pSelection == nullptr) return E_INVALIDARG;
    if (GetEnvironmentVariableW(L"NATIVEIME_TEST_SELECTION_UNAVAILABLE", nullptr, 0)) {
      std::printf("SELECTION unavailable=E_NOINTERFACE\n");
      return E_NOINTERFACE;
    }
    const LONG len = static_cast<LONG>(buffer_.size());
    LONG s = std::clamp(pSelection[0].acpStart, 0L, len);
    LONG e = std::clamp(pSelection[0].acpEnd, 0L, len);
    if (e < s) std::swap(s, e);
    sel_start_ = s;
    sel_end_ = e;
    NotifySelectionChange();
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE GetText(LONG acpStart, LONG acpEnd,
                                    WCHAR* pchPlain, ULONG cchPlainReq,
                                    ULONG* pcchPlainOut,
                                    TS_RUNINFO* prgRunInfo,
                                    ULONG ulRunInfoReq, ULONG* pulRunInfoOut,
                                    LONG* pacpNext) override {
    if (pcchPlainOut == nullptr || pulRunInfoOut == nullptr ||
        pacpNext == nullptr) {
      return E_INVALIDARG;
    }
    *pcchPlainOut = 0;
    *pulRunInfoOut = 0;
    if (!locked_) return TS_E_NOLOCK;
    const LONG len = static_cast<LONG>(buffer_.size());
    LONG start = std::clamp(acpStart, 0L, len);
    LONG end = (acpEnd < 0) ? len : std::clamp(acpEnd, 0L, len);
    if (end < start) return E_INVALIDARG;
    const ULONG avail = static_cast<ULONG>(end - start);
    const ULONG copy = (std::min)(avail, cchPlainReq);
    if (pchPlain != nullptr && copy > 0) {
      memcpy(pchPlain, buffer_.data() + start, copy * sizeof(WCHAR));
    }
    *pcchPlainOut = copy;
    if (ulRunInfoReq > 0 && prgRunInfo != nullptr) {
      prgRunInfo[0].uCount = copy;
      prgRunInfo[0].type = TS_RT_PLAIN;
      *pulRunInfoOut = 1;
    }
    *pacpNext = start + static_cast<LONG>(copy);
    return S_OK;
  }

  // Implements the write in terms of an explicit ACP range, exactly like
  // InsertTextAtSelection but for an arbitrary [acpStart, acpEnd) rather
  // than the current selection -- this is how the real text service
  // renders composition/commit text via ITfRange::SetText().
  HRESULT STDMETHODCALLTYPE SetText(DWORD /*dwFlags*/, LONG acpStart,
                                    LONG acpEnd, const WCHAR* pchText,
                                    ULONG cch, TS_TEXTCHANGE* pChange) override {
    if (pchText == nullptr && cch > 0) return E_INVALIDARG;
    if (!locked_ || !IsReadWriteLocked()) return TS_E_NOLOCK;
    const LONG len = static_cast<LONG>(buffer_.size());
    LONG start = std::clamp(acpStart, 0L, len);
    LONG end = (acpEnd < 0) ? len : std::clamp(acpEnd, 0L, len);
    if (end < start) std::swap(start, end);
    buffer_.replace(static_cast<size_t>(start),
                    static_cast<size_t>(end - start), pchText, cch);
    const LONG new_end = start + static_cast<LONG>(cch);
    sel_start_ = sel_end_ = new_end;
    if (GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", nullptr, 0))
      std::printf("VISIBLE tick=%llu units=%zu\n", GetTickCount64(), buffer_.size());
    if (pChange != nullptr) {
      pChange->acpStart = start;
      pChange->acpOldEnd = end;
      pChange->acpNewEnd = new_end;
    }
    NotifyTextChange(start, end, new_end);
    NotifySelectionChange();
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE GetFormattedText(LONG, LONG,
                                             IDataObject**) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE GetEmbedded(LONG, REFGUID, REFIID,
                                        IUnknown**) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE QueryInsertEmbedded(const GUID*,
                                                const FORMATETC*,
                                                BOOL* pfInsertable) override {
    // No embedded/OLE content is ever accepted by this test document.
    if (pfInsertable != nullptr) *pfInsertable = FALSE;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE InsertEmbedded(DWORD, LONG, LONG, IDataObject*,
                                           TS_TEXTCHANGE*) override {
    return E_NOTIMPL;
  }

  HRESULT STDMETHODCALLTYPE InsertTextAtSelection(DWORD dwFlags,
                                                  const WCHAR* pchText,
                                                  ULONG cch, LONG* pacpStart,
                                                  LONG* pacpEnd,
                                                  TS_TEXTCHANGE* pChange) override {
    if (dwFlags & TS_IAS_QUERYONLY) {
      if (pacpStart != nullptr) *pacpStart = sel_start_;
      if (pacpEnd != nullptr) *pacpEnd = sel_end_;
      return S_OK;
    }
    if (pchText == nullptr && cch > 0) return E_INVALIDARG;
    if (!locked_ || !IsReadWriteLocked()) return TS_E_NOLOCK;
    const LONG start = sel_start_;
    const LONG end = sel_end_;
    buffer_.replace(static_cast<size_t>(start),
                    static_cast<size_t>(end - start), pchText, cch);
    const LONG new_end = start + static_cast<LONG>(cch);
    sel_start_ = sel_end_ = new_end;
    if (pacpStart != nullptr) *pacpStart = start;
    if (pacpEnd != nullptr) *pacpEnd = new_end;
    if (pChange != nullptr) {
      pChange->acpStart = start;
      pChange->acpOldEnd = end;
      pChange->acpNewEnd = new_end;
    }
    NotifyTextChange(start, end, new_end);
    NotifySelectionChange();
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE InsertEmbeddedAtSelection(DWORD, IDataObject*,
                                                       LONG*, LONG*,
                                                       TS_TEXTCHANGE*) override {
    return E_NOTIMPL;
  }

  HRESULT STDMETHODCALLTYPE RequestSupportedAttrs(
      DWORD, ULONG, const TS_ATTRID*) override {
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE RequestAttrsAtPosition(
      LONG, ULONG, const TS_ATTRID*, DWORD) override {
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE RequestAttrsTransitioningAtPosition(
      LONG, ULONG, const TS_ATTRID*, DWORD) override {
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE FindNextAttrTransition(
      LONG /*acpStart*/, LONG acpHalt, ULONG, const TS_ATTRID*, DWORD,
      LONG* pacpNext, BOOL* pfFound, LONG* plFoundOffset) override {
    if (pacpNext != nullptr) *pacpNext = acpHalt;
    if (pfFound != nullptr) *pfFound = FALSE;
    if (plFoundOffset != nullptr) *plFoundOffset = 0;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE RetrieveRequestedAttrs(
      ULONG, TS_ATTRVAL*, ULONG* pcFetched) override {
    if (pcFetched != nullptr) *pcFetched = 0;
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE GetEndACP(LONG* pacp) override {
    if (pacp == nullptr) return E_INVALIDARG;
    if (!locked_) return TS_E_NOLOCK;
    *pacp = static_cast<LONG>(buffer_.size());
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE GetActiveView(TsViewCookie* pvcView) override {
    if (pvcView == nullptr) return E_INVALIDARG;
    *pvcView = kViewCookie;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetACPFromPoint(TsViewCookie, const POINT*, DWORD,
                                            LONG*) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE GetTextExt(TsViewCookie, LONG, LONG, RECT* prc,
                                       BOOL* pfClipped) override {
    if (prc == nullptr || pfClipped == nullptr) return E_INVALIDARG;
    // A fixed, plausible on-screen rect. Real coordinates are irrelevant
    // here: this test document is never actually painted, but the text
    // service reads caret rects for its mode-indicator popup and must get
    // *something* usable back rather than fail outright.
    *prc = RECT{100, 100, 220, 124};
    *pfClipped = FALSE;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetScreenExt(TsViewCookie, RECT* prc) override {
    if (prc == nullptr) return E_INVALIDARG;
    *prc = RECT{0, 0, 1920, 1080};
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetWnd(TsViewCookie, HWND* phwnd) override {
    if (phwnd == nullptr) return E_INVALIDARG;
    *phwnd = hwnd_;
    return S_OK;
  }

  // --- ITfContextOwnerCompositionSink ----------------------------------
  HRESULT STDMETHODCALLTYPE OnStartComposition(ITfCompositionView* pComposition,
                                               BOOL* pfOk) override {
    ++revision_;
    if (pfOk != nullptr) *pfOk = TRUE;
    composition_active_ = true;
    UpdateCompositionSpan(pComposition);
    std::printf("COMPOSITION START range=%ld,%ld\n",
                static_cast<long>(comp_start_), static_cast<long>(comp_end_));
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE OnUpdateComposition(ITfCompositionView* pComposition,
                                                ITfRange* /*pRangeNew*/) override {
    ++revision_;
    UpdateCompositionSpan(pComposition);
    std::printf("COMPOSITION UPDATE range=%ld,%ld\n",
                static_cast<long>(comp_start_), static_cast<long>(comp_end_));
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE OnEndComposition(
      ITfCompositionView* pComposition) override {
    ++revision_;
    UpdateCompositionSpan(pComposition);
    std::printf("COMPOSITION END range=%ld,%ld\n",
                static_cast<long>(comp_start_), static_cast<long>(comp_end_));
    // Result-only consumer: document SetText outside a composition is invisible
    // to this model. Snapshot the ended range before another episode edits it.
    if (comp_start_ >= 0 && comp_end_ >= comp_start_ &&
        static_cast<size_t>(comp_end_) <= buffer_.size()) {
      imm_last_ = buffer_.substr(comp_start_, comp_end_ - comp_start_);
      imm_text_ += imm_last_;
      ++imm_results_;
      std::printf("IMMRESULT count=%zu lock=%llu range=%ld,%ld hex=%s\n", imm_results_,
                  lock_sequence_, comp_start_, comp_end_, ResultHex(imm_last_).c_str());
    } else std::printf("IMMRESULT invalid-range=1\n");
    composition_active_ = false;
    return S_OK;
  }

  // --- Test-harness accessors -------------------------------------------
  std::wstring BufferSnapshot() const { return buffer_; }
  static std::string ResultHex(const std::wstring& text) {
    std::string result;
    for (const auto ch : text) { char hex[5]{}; std::snprintf(hex, sizeof(hex), "%04x", static_cast<unsigned>(ch)); result += hex; }
    return result.empty() ? "-" : result;
  }
  void PrintImmSnapshot(const std::wstring& token) const {
    std::printf("IMM AFTER %ls COUNT=%zu LAST=%s TEXT=%s\n", token.c_str(), imm_results_,
                ResultHex(imm_last_).c_str(), ResultHex(imm_text_).c_str());
  }
  void DelayWrites() { async_writes_ = true; }
  void FlushWrites() {
    async_writes_ = false;
    if (!pending_lock_ || !sink_) return;
    pending_lock_ = false;
    locked_ = true; current_lock_flags_ = pending_lock_flags_;
    const auto started = GetTickCount64();
    ++lock_sequence_;
    const HRESULT result = sink_->OnLockGranted(pending_lock_flags_);
    locked_ = false; current_lock_flags_ = 0;
    std::printf("EDIT_ASYNC executed=1 hr=%08lx elapsed_ms=%llu tick=%llu\n",
                result, GetTickCount64() - started, GetTickCount64());
  }
  void RefuseNextWrite() { refuse_next_write_ = true; }
  void RefuseWrites(DWORD ms) { refuse_write_until_ = GetTickCount64() + ms; }
  void DenyNextWrite() { deny_next_write_ = true; }
  void DenyWrites(DWORD ms) { deny_write_until_ = GetTickCount64() + ms; }
  void ApplicationClear() {
    const LONG previous = static_cast<LONG>(buffer_.size());
    buffer_.clear();
    imm_text_.clear(); imm_last_.clear(); imm_results_ = 0;
    sel_start_ = sel_end_ = 0;
    NotifyTextChange(0, previous, 0);
    NotifySelectionChange();
  }
  void SelectionSnapshot(LONG* start, LONG* end) const {
    *start = sel_start_;
    *end = sel_end_;
  }
  bool CompositionActive() const { return composition_active_; }
  LONG CompositionStart() const { return comp_start_; }
  LONG CompositionEnd() const { return comp_end_; }
  uint64_t Revision() const { return revision_; }

 private:
  static constexpr TsViewCookie kViewCookie = 1;

  bool IsReadWriteLocked() const {
    return (current_lock_flags_ & TS_LF_READWRITE) == TS_LF_READWRITE;
  }

  void NotifyTextChange(LONG start, LONG old_end, LONG new_end) {
    ++revision_;
    if (sink_ != nullptr && (sink_mask_ & TS_AS_TEXT_CHANGE)) {
      TS_TEXTCHANGE change{start, old_end, new_end};
      sink_->OnTextChange(0, &change);
    }
  }
  void NotifySelectionChange() {
    ++revision_;
    if (sink_ != nullptr && (sink_mask_ & TS_AS_SEL_CHANGE)) {
      sink_->OnSelectionChange();
    }
  }

  // ITfRangeACP::GetExtent() reports ACP anchor/length directly, without
  // needing a TfEditCookie -- unlike the generic ITfRange accessors, ACP
  // ranges are absolute offsets into a document we already own, so this
  // is safe to call from composition-sink callbacks that carry no cookie.
  void UpdateCompositionSpan(ITfCompositionView* view) {
    if (view == nullptr) return;
    ITfRange* range = nullptr;
    if (FAILED(view->GetRange(&range)) || range == nullptr) return;
    ITfRangeACP* acp_range = nullptr;
    if (SUCCEEDED(range->QueryInterface(IID_ITfRangeACP,
                                        reinterpret_cast<void**>(&acp_range)))) {
      LONG anchor = 0, length = 0;
      if (SUCCEEDED(acp_range->GetExtent(&anchor, &length))) {
        comp_start_ = anchor;
        comp_end_ = anchor + length;
      }
      acp_range->Release();
    }
    range->Release();
  }

  bool async_writes_ = false;
  bool refuse_next_write_ = false;
  ULONGLONG refuse_write_until_ = 0;
  bool deny_next_write_ = false;
  ULONGLONG deny_write_until_ = 0;
  LONG ref_count_ = 1;
  HWND hwnd_ = nullptr;
  std::wstring buffer_;
  std::wstring imm_text_, imm_last_;
  size_t imm_results_ = 0;
  unsigned long long lock_sequence_ = 0;
  LONG sel_start_ = 0;
  LONG sel_end_ = 0;

  ITextStoreACPSink* sink_ = nullptr;
  DWORD sink_mask_ = 0;

  bool locked_ = false;
  DWORD current_lock_flags_ = 0;
  bool pending_lock_ = false;
  DWORD pending_lock_flags_ = 0;

  bool composition_active_ = false;
  LONG comp_start_ = 0;
  LONG comp_end_ = 0;
  uint64_t revision_ = 0;
};

// ---------------------------------------------------------------------
// Hidden top-level window: just a message-pump owner and a GetWnd()
// target. Never shown.
// ---------------------------------------------------------------------
LRESULT CALLBACK HiddenWndProc(HWND hwnd, UINT msg, WPARAM wparam,
                               LPARAM lparam) {
  return DefWindowProcW(hwnd, msg, wparam, lparam);
}

HWND CreateHiddenWindow(HINSTANCE instance) {
  static const wchar_t kClassName[] = L"DdskkTsfHostWindow";
  WNDCLASSW wc{};
  wc.lpfnWndProc = HiddenWndProc;
  wc.hInstance = instance;
  wc.lpszClassName = kClassName;
  RegisterClassW(&wc);
  return CreateWindowExW(0, kClassName, L"ddskk-tsf-host",
                         WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT,
                         200, 100, nullptr, nullptr, instance, nullptr);
}

// ---------------------------------------------------------------------
// IME activation. ActivateLanguageProfile requires the calling thread's
// input language to already include Japanese; on a non-Japanese-enabled
// Windows install this can legitimately fail, so a second attempt via
// ITfInputProcessorProfileMgr::ActivateProfile with
// TF_IPPMF_DONTCARECURRENTINPUTLANGUAGE is made as a fallback. Both
// outcomes are always printed, per spec ("call it and report the
// HRESULT"), not just failures.
// ---------------------------------------------------------------------
void ActivateIme() {
  const LANGID kJapanese = MAKELANGID(LANG_JAPANESE, SUBLANG_DEFAULT);

  ITfInputProcessorProfiles* profiles = nullptr;
  HRESULT hr = CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr,
                                CLSCTX_INPROC_SERVER,
                                IID_ITfInputProcessorProfiles,
                                reinterpret_cast<void**>(&profiles));
  HRESULT activate_hr = hr;
  if (SUCCEEDED(hr)) {
    activate_hr = profiles->ActivateLanguageProfile(
        CLSID_DdskkTextService, kJapanese, GUID_DdskkProfile);
    profiles->Release();
  }
  std::printf("PROFILE_ACTIVATE method=ActivateLanguageProfile hr=%08lx\n",
             static_cast<unsigned long>(activate_hr));

  // ActivateLanguageProfile returns S_OK even when the thread's current
  // input language is not Japanese -- the profile is then merely marked
  // active for Japanese without ever instantiating the TIP (observed:
  // S_OK, but ddskk-ime.dll never loaded and no key sink advised). Always
  // follow up with ActivateProfile + DONTCARECURRENTINPUTLANGUAGE, which
  // forces the switch regardless of the host thread's language.
  ITfInputProcessorProfileMgr* profile_mgr = nullptr;
  hr = CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr,
                        CLSCTX_INPROC_SERVER, IID_ITfInputProcessorProfileMgr,
                        reinterpret_cast<void**>(&profile_mgr));
  HRESULT fallback_hr = hr;
  if (SUCCEEDED(hr)) {
    fallback_hr = profile_mgr->ActivateProfile(
        TF_PROFILETYPE_INPUTPROCESSOR, kJapanese, CLSID_DdskkTextService,
        GUID_DdskkProfile, nullptr,
        TF_IPPMF_DONTCARECURRENTINPUTLANGUAGE | TF_IPPMF_FORPROCESS |
            TF_IPPMF_FORSESSION);
    profile_mgr->Release();
  }
  std::printf("PROFILE_ACTIVATE method=ActivateProfile(force) hr=%08lx\n",
             static_cast<unsigned long>(fallback_hr));
  std::printf("TIP_DLL loaded=%d\n",
             GetModuleHandleW(L"ddskk-ime.dll") != nullptr ? 1 : 0);
}

// ---------------------------------------------------------------------
// Key scripting.
// ---------------------------------------------------------------------
struct KeyEvent {
  UINT vk;
  bool shift;
  bool ctrl;
};

bool TokenToKey(const std::wstring& token, KeyEvent* out) {
  // OEM names identify virtual keys; the active keyboard layout determines
  // their characters. Prefix S for the shifted variant (for example SPERIOD).
  const struct { const wchar_t* name; UINT vk; } punctuation[] = {
      {L"PERIOD", VK_OEM_PERIOD}, {L"COMMA", VK_OEM_COMMA},
      {L"SLASH", VK_OEM_2}, {L"SEMICOLON", VK_OEM_1},
      {L"QUOTE", VK_OEM_7}, {L"BACKQUOTE", VK_OEM_3},
      {L"BACKSLASH", VK_OEM_5}, {L"LBRACKET", VK_OEM_4},
      {L"RBRACKET", VK_OEM_6}, {L"MINUS", VK_OEM_MINUS},
      {L"EQUALS", VK_OEM_PLUS}, {L"OEM102", VK_OEM_102}};
  for (const auto& item : punctuation) {
    if (token == item.name || token == std::wstring(L"S") + item.name) {
      *out = KeyEvent{item.vk, token != item.name, false}; return true;
    }
  }
  if (token == L"." || token == L",") {
    *out = KeyEvent{static_cast<UINT>(token == L"." ? VK_OEM_PERIOD : VK_OEM_COMMA), false, false}; return true;
  }
  if (token == L"BRACKET") { *out = KeyEvent{VK_OEM_4, false, false}; return true; }
  if (token == L"SSPACE") { *out = KeyEvent{VK_SPACE, true, false}; return true; }
  if (token == L"PGUP") { *out = KeyEvent{VK_PRIOR, false, false}; return true; }
  if (token == L"PGDN") { *out = KeyEvent{VK_NEXT, false, false}; return true; }
  if (token == L"SPACE") { *out = KeyEvent{VK_SPACE, false, false}; return true; }
  if (token == L"ENTER") { *out = KeyEvent{VK_RETURN, false, false}; return true; }
  if (token == L"BS") { *out = KeyEvent{VK_BACK, false, false}; return true; }
  if (token == L"ESC") { *out = KeyEvent{VK_ESCAPE, false, false}; return true; }
  if (token == L"CTRLJ") {
    *out = KeyEvent{static_cast<UINT>(L'J'), false, true};
    return true;
  }
  if (token == L"CTRLG") {
    *out = KeyEvent{static_cast<UINT>(L'G'), false, true};
    return true;
  }
  if (token.size() == 5 && token.rfind(L"CTRL", 0) == 0 &&
      token[4] >= L'A' && token[4] <= L'Z') {
    *out = KeyEvent{static_cast<UINT>(token[4]), false, true};
    return true;
  }
  if (token == L"LEFT") { *out = KeyEvent{VK_LEFT, false, false}; return true; }
  if (token == L"RIGHT") { *out = KeyEvent{VK_RIGHT, false, false}; return true; }
  if (token == L"SLEFT") { *out = KeyEvent{VK_LEFT, true, false}; return true; }
  if (token == L"SRIGHT") { *out = KeyEvent{VK_RIGHT, true, false}; return true; }
  if (token.size() == 2 && token[0] == L'F' && token[1] >= L'6' && token[1] <= L'9') {
    *out = KeyEvent{static_cast<UINT>(VK_F1 + (token[1] - L'1')), false, false}; return true;
  }
  if (token == L"F10") { *out = KeyEvent{VK_F10, false, false}; return true; }
  if (token == L"UP") { *out = KeyEvent{VK_UP, false, false}; return true; }
  if (token == L"DOWN") { *out = KeyEvent{VK_DOWN, false, false}; return true; }
  if (token == L"DEL") { *out = KeyEvent{VK_DELETE, false, false}; return true; }
  if (token == L"HOME") { *out = KeyEvent{VK_HOME, false, false}; return true; }
  if (token == L"END") { *out = KeyEvent{VK_END, false, false}; return true; }
  if (token.size() == 2 && token[0] == L'S' &&
      token[1] >= L'0' && token[1] <= L'9') {
    *out = KeyEvent{static_cast<UINT>(token[1]), true, false};
    return true;
  }
  if (token.size() == 1) {
    const wchar_t ch = token[0];
    if (ch == L'-') {
      *out = KeyEvent{VK_OEM_MINUS, false, false};
      return true;
    }
    if (ch >= L'a' && ch <= L'z') {
      *out = KeyEvent{static_cast<UINT>(towupper(ch)), false, false};
      return true;
    }
    if (ch >= L'0' && ch <= L'9') {
      *out = KeyEvent{static_cast<UINT>(ch), false, false};
      return true;
    }
    if (ch >= L'A' && ch <= L'Z') {
      *out = KeyEvent{static_cast<UINT>(ch), true, false};
      return true;
    }
  }
  return false;
}

// DDSKK_HARNESS_DIRECT_KEYDOWN=1 makes SendScriptedKey() below skip
// OnTestKeyDown/OnTestKeyUp entirely and call OnKeyDown/OnKeyUp directly
// for every token, reproducing the call order many real host applications
// actually use: ITfKeystrokeMgr::KeyDown for every key, without ever
// consulting TestKeyDown first. The well-behaved default path this
// harness normally takes (TestKeyDown -> only call KeyDown if claimed)
// had been masking a field bug this validates the fix for: on the direct
// call order, OnKeyDown's own TranslateKey()-miss fallback used to
// unconditionally swallow the key, killing arrows/Home/End/Delete/F-keys
// in exactly the applications that call KeyDown this way. See
// TextService::WouldClaimKey()/OnKeyDown() in src/text_service.cpp.
bool DirectKeyDownMode() {
  static const bool direct = [] {
    wchar_t value[8]{};
    const DWORD size =
        GetEnvironmentVariableW(L"DDSKK_HARNESS_DIRECT_KEYDOWN", value, 8);
    return size > 0 && size < 8 && wcscmp(value, L"1") == 0;
  }();
  return direct;
}

constexpr DWORD kPumpMs = 15;

bool CompactHarnessMode() {
  static const bool compact = [] {
    wchar_t value[8]{};
    const DWORD size = GetEnvironmentVariableW(
        L"NELISP_IME_HARNESS_COMPACT", value,
        static_cast<DWORD>(_countof(value)));
    return size > 0 && size < _countof(value) && value[0] != L'0';
  }();
  return compact;
}

DWORD scripted_key_gap = MAXDWORD;
DWORD PerKeyPumpMs() {
  if (scripted_key_gap != MAXDWORD) return scripted_key_gap;
  // The normal harness leaves enough time to observe asynchronous UI work.
  // Compact mode is used by long throughput/ordering soaks, where a 15 ms
  // delay after both key-down and key-up would dominate the run entirely.
  return CompactHarnessMode() ? 0 : kPumpMs;
}

void PumpMessages(DWORD duration_ms) {
  MSG msg;
  while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
    TranslateMessage(&msg);
    DispatchMessageW(&msg);
  }
  if (duration_ms == 0) return;

  const ULONGLONG deadline = GetTickCount64() + duration_ms;
  do {
    while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&msg);
      DispatchMessageW(&msg);
    }
    Sleep(1);
  } while (GetTickCount64() < deadline);

  // A provider result can be posted during the final Sleep(1).  Drain once
  // more at the observation boundary so the following scripted key cannot
  // overtake a result that arrived within the requested wait interval.
  while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
    TranslateMessage(&msg);
    DispatchMessageW(&msg);
  }
}

// Drives the TIP's ITfKeyEventSink directly instead of routing through
// ITfKeystrokeMgr::TestKeyDown/KeyDown. Rationale: TSF's own routing only
// engages after it has activated the TIP for this thread, and in this
// minimal host TSF loads the TIP DLL but never calls its Activate()
// (observed even with the profile force-activated and the keyboard
// compartment open). The harness therefore instantiates the TIP itself,
// calls Activate(), and feeds keys straight into the sink -- which is the
// exact same entry point ITfKeystrokeMgr would call, with the same
// context, so everything under test (claim logic, engine I/O, edit
// sessions, compositions) still runs unmodified.
unsigned long long EpochMicroseconds() {
  FILETIME time{}; GetSystemTimePreciseAsFileTime(&time);
  ULARGE_INTEGER value{}; value.LowPart = time.dwLowDateTime; value.HighPart = time.dwHighDateTime;
  return (value.QuadPart - 116444736000000000ULL) / 10;
}
void SendScriptedKey(ITfKeyEventSink* key_sink, ITfKeystrokeMgr* keystroke_mgr,
                     ITfContext* context, const KeyEvent& key,
                     const std::wstring& token) {
  callback_io_probe::Record io_record;
  // SetKeyboardState below isolates thread state, but the real TIP also
  // consults GetAsyncKeyState for hosts that dispatch before thread state
  // updates. A physical modifier would turn this scripted event into a
  // different chord. Wait before starting callback measurements; never
  // synthesize a release into the user's desktop or change TIP key claiming.
  const auto physical_modifiers = [] {
    unsigned mask = 0;
    for (const auto vk : {VK_SHIFT, VK_CONTROL, VK_MENU, VK_LWIN, VK_RWIN})
      if (GetAsyncKeyState(vk) & 0x8000) mask |= 1u << (vk == VK_SHIFT ? 0 :
          vk == VK_CONTROL ? 1 : vk == VK_MENU ? 2 : vk == VK_LWIN ? 3 : 4);
    return mask;
  };
  if (const unsigned mask = physical_modifiers()) {
    std::printf("SCRIPTKEY physical-modifiers token=%s mask=%u waiting=1\n",
                Utf8FromWide(token).c_str(), mask);
    const auto deadline = GetTickCount64() + 10000;
    while (physical_modifiers() && GetTickCount64() < deadline) PumpMessages(5);
    if (physical_modifiers()) {
      std::printf("SCRIPTKEY FAIL physical modifier still held token=%s\n",
                  Utf8FromWide(token).c_str());
      std::fflush(stdout); std::exit(1);
    }
  }
  BYTE state_before[256]{};
  GetKeyboardState(state_before);
  // Script tokens describe the complete key event. Inheriting a physical
  // Shift/Ctrl/Caps Lock from the harness thread changes lowercase readings
  // into okuri or shortcuts. Restore that state only after dispatch finishes.
  BYTE state[256]{};
  if (key.shift) state[VK_SHIFT] |= 0x80;
  if (key.ctrl) state[VK_CONTROL] |= 0x80;
  SetKeyboardState(state);
  if (GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", nullptr, 0)) {
    std::printf("SCRIPTKEY token=%s inherited_shift=%d shift=%d control=%d tick=%llu utc_us=%llu async_shift=%d async_control=%d\n",
                Utf8FromWide(token).c_str(), (state_before[VK_SHIFT] & 0x80) != 0,
                key.shift, key.ctrl, GetTickCount64(), EpochMicroseconds(),
                (GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0,
                (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0);
  }

  const UINT scan = MapVirtualKeyW(key.vk, MAPVK_VK_TO_VSC);
  const LPARAM lparam_down = (static_cast<LPARAM>(scan) << 16) | 1;

  // Prefer feeding the TIP's ITfKeyEventSink directly (deterministic,
  // needs no TSF-side routing); fall back to ITfKeystrokeMgr when TSF's
  // own instance already owns the key sink registration.
  const auto test_down = [&](BOOL* e) {
    callback_io_probe::Scope scope;
    return key_sink != nullptr
        ? key_sink->OnTestKeyDown(context, key.vk, lparam_down, e)
        : keystroke_mgr->TestKeyDown(key.vk, lparam_down, e);
  };
  const auto down = [&](BOOL* e) {
    callback_io_probe::Scope scope;
    return key_sink != nullptr
        ? key_sink->OnKeyDown(context, key.vk, lparam_down, e)
        : keystroke_mgr->KeyDown(key.vk, lparam_down, e);
  };

  if (DirectKeyDownMode()) {
    // Ill-behaved-app repro: call KeyDown directly, never consulting
    // TestKeyDown at all, for every token -- see DirectKeyDownMode().
    BOOL eaten = FALSE;
    const auto started = std::chrono::steady_clock::now();
    HRESULT hr = down(&eaten);
    const auto completed = std::chrono::steady_clock::now();
    if (FAILED(hr)) PrintHr("KeyDown", hr);
    std::printf("DIRECT KEYDOWN vk=%02X eaten=%d\n", key.vk, eaten);
    std::printf("KEYLAT token=%s test_us=0 down_us=%lld total_us=%lld "
                "claimed=%d direct=1\n",
                Utf8FromWide(token).c_str(),
                static_cast<long long>(std::chrono::duration_cast<
                    std::chrono::microseconds>(completed - started).count()),
                static_cast<long long>(std::chrono::duration_cast<
                    std::chrono::microseconds>(completed - started).count()),
                eaten ? 1 : 0);
    std::fflush(stdout);
    PumpMessages(PerKeyPumpMs());

    const LPARAM lparam_up = lparam_down | (static_cast<LPARAM>(1) << 30) |
                             (static_cast<LPARAM>(1) << 31);
    BOOL eaten_up = FALSE;
    {
      callback_io_probe::Scope scope;
      hr = key_sink != nullptr
          ? key_sink->OnKeyUp(context, key.vk, lparam_up, &eaten_up)
          : keystroke_mgr->KeyUp(key.vk, lparam_up, &eaten_up);
    }
    if (FAILED(hr)) PrintHr("KeyUp", hr);
    PumpMessages(PerKeyPumpMs());
    SetKeyboardState(state_before);
    return;
  }

  BOOL eaten = FALSE;
  const auto started = std::chrono::steady_clock::now();
  HRESULT hr = test_down(&eaten);
  const auto tested = std::chrono::steady_clock::now();
  auto completed = tested;
  const bool claimed = SUCCEEDED(hr) && eaten;
  if (FAILED(hr)) {
    PrintHr("TestKeyDown", hr);
  } else if (eaten) {
    // Private regression model: the host updates modifier state after
    // TestKeyDown. The core must consume the original tested key event.
    wchar_t modifier_race[2]{};
    if (GetEnvironmentVariableW(L"NATIVEIME_TEST_KEYSTATE_AFTER_TEST", modifier_race, 2) &&
        modifier_race[0] == L'1') {
      BYTE changed[256]{};
      SetKeyboardState(changed);
      std::printf("KEYSTATE_AFTER_TEST injected=1 token=%s\n", Utf8FromWide(token).c_str());
    }
    eaten = FALSE;
    hr = down(&eaten);
    completed = std::chrono::steady_clock::now();
    SetKeyboardState(state);
    if (FAILED(hr)) PrintHr("KeyDown", hr);
    std::printf("KEYDOWN vk=%02X eaten=%d\n", key.vk, eaten);
  } else {
    std::printf("TESTKEYDOWN vk=%02X eaten=0 (key not claimed)\n", key.vk);
  }
  const auto test_us = std::chrono::duration_cast<std::chrono::microseconds>(
      tested - started).count();
  const auto total_us = std::chrono::duration_cast<std::chrono::microseconds>(
      completed - started).count();
  std::printf("KEYLAT token=%s test_us=%lld down_us=%lld total_us=%lld "
              "claimed=%d direct=0\n",
              Utf8FromWide(token).c_str(), static_cast<long long>(test_us),
              static_cast<long long>(total_us - test_us),
              static_cast<long long>(total_us), claimed ? 1 : 0);
  std::fflush(stdout);
  PumpMessages(PerKeyPumpMs());

  // Standard WM_KEYUP lparam convention: previous-key-state (bit 30) and
  // transition-state (bit 31) both set, on top of the same repeat/scan
  // fields used for the down event.
  const LPARAM lparam_up =
      lparam_down | (static_cast<LPARAM>(1) << 30) | (static_cast<LPARAM>(1) << 31);
  BOOL eaten_up = FALSE;
  hr = key_sink != nullptr
      ? key_sink->OnTestKeyUp(context, key.vk, lparam_up, &eaten_up)
      : keystroke_mgr->TestKeyUp(key.vk, lparam_up, &eaten_up);
  if (FAILED(hr)) {
    PrintHr("TestKeyUp", hr);
  } else if (eaten_up) {
    eaten_up = FALSE;
    {
      callback_io_probe::Scope scope;
      hr = key_sink != nullptr
          ? key_sink->OnKeyUp(context, key.vk, lparam_up, &eaten_up)
          : keystroke_mgr->KeyUp(key.vk, lparam_up, &eaten_up);
    }
    if (FAILED(hr)) PrintHr("KeyUp", hr);
  }
  PumpMessages(PerKeyPumpMs());

  SetKeyboardState(state_before);
}

// Observe the existing KEYBRANCH diagnostic in this private host's own log.
// F24 is unclaimed in every input mode, including registration; call only the
// TIP callback, never forward a key to the application or the engine. An open
// frontend preedit/candidate is allowed: idle means no outstanding request,
// not absence of a composition. This also works with pre-core-split DLLs.
void Settle(ITfKeyEventSink* key_sink, ITfKeystrokeMgr* keystroke_mgr,
            ITfContext* context, DocumentStore* store, DWORD max_ms,
            const std::wstring& token) {
  wchar_t path[32768]{};
  GetEnvironmentVariableW(L"NATIVEIME_HARNESS_TSF_OUTPUT", path, _countof(path));
  HANDLE log = CreateFileW(path, GENERIC_READ,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (log == INVALID_HANDLE_VALUE) {
    std::printf("SETTLE FAIL token=%s cannot observe private TSF log error=%lu\n",
                Utf8FromWide(token).c_str(), GetLastError());
    std::fflush(stdout); std::exit(1);
  }
  wchar_t diagnostics[32768]{};
  const DWORD saved = GetEnvironmentVariableW(
      L"DDSKK_HARNESS_DIAGNOSTICS", diagnostics, _countof(diagnostics));
  SetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", L"1");
  const ULONGLONG started = GetTickCount64();
  ULONGLONG quiet_since = started;
  uint64_t revision = store->Revision();
  bool idle = false, observed = false, success = false;
  HRESULT probe_hr = S_OK;
  for (;;) {
    PumpMessages(0);
    std::fflush(stdout);
    LARGE_INTEGER offset{};
    const bool positioned = GetFileSizeEx(log, &offset) &&
        SetFilePointerEx(log, offset, nullptr, FILE_BEGIN);
    BOOL eaten = FALSE;
    probe_hr = key_sink
        ? key_sink->OnKeyDown(context, VK_F24, 0, &eaten)
        : keystroke_mgr->KeyDown(VK_F24, 0, &eaten);
    std::fflush(stdout);
    char bytes[16384]{};
    DWORD count = 0;
    const bool read = ReadFile(log, bytes, sizeof(bytes) - 1, &count, nullptr);
    const std::string trace(bytes, count);
    const size_t marker = trace.rfind("KEYBRANCH vk=87 branch=passthrough ");
    const size_t end = trace.find('\n', marker);
    const std::string branch = marker == std::string::npos ? ""
        : trace.substr(marker, end - marker);
    observed = positioned && read && SUCCEEDED(probe_hr) && !eaten &&
        branch.find("provider_pending=") != std::string::npos;
    idle = observed && branch.find("provider_pending=0 ") != std::string::npos;
    const ULONGLONG now = GetTickCount64();
    if (!idle || revision != store->Revision()) quiet_since = now;
    revision = store->Revision();
    if (now - started >= max_ms) break;
    if (idle && now - quiet_since >= 100) { success = true; break; }
    PumpMessages(10);
  }
  CloseHandle(log);
  SetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS",
                           saved ? diagnostics : nullptr);
  std::printf("SETTLE %s token=%s elapsed_ms=%llu max_ms=%lu quiet_ms=100 "
              "observed=%d provider_idle=%d probe_hr=%08lX revision=%llu\n",
      success ? "OK" : "TIMEOUT", Utf8FromWide(token).c_str(),
      GetTickCount64() - started, max_ms, observed, idle,
      static_cast<unsigned long>(probe_hr),
      static_cast<unsigned long long>(revision));
  std::fflush(stdout);
  if (!success) std::exit(1);
}

void WaitForRemap(DWORD max_ms) {
  wchar_t path[32768]{};
  GetEnvironmentVariableW(L"NATIVEIME_HARNESS_TSF_OUTPUT", path, _countof(path));
  HANDLE log = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE |
      FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  const auto started = GetTickCount64();
  bool observed = false;
  while (log != INVALID_HANDLE_VALUE && GetTickCount64() - started < max_ms) {
    std::fflush(stdout);
    SetFilePointer(log, 0, nullptr, FILE_BEGIN);
    char bytes[131072]{}; DWORD count = 0;
    if (ReadFile(log, bytes, sizeof(bytes) - 1, &count, nullptr)) {
      const std::string text(bytes, count);
      auto offset = text.find("LOCAL_MAPPING delay_ms=");
      while (offset != std::string::npos) {
        const auto end = text.find('\n', offset);
        if (text.substr(offset, end - offset).find("retained=1") != std::string::npos) {
          observed = true; break;
        }
        offset = text.find("LOCAL_MAPPING delay_ms=", offset + 1);
      }
    }
    if (observed) break;
    PumpMessages(5);
  }
  if (log != INVALID_HANDLE_VALUE) CloseHandle(log);
  std::printf("REMAP %s elapsed_ms=%llu\n", observed ? "OK" : "TIMEOUT", GetTickCount64() - started);
  std::fflush(stdout);
  if (!observed) std::exit(1);
}
void PrintAfterLine(const std::wstring& token, const DocumentStore* store) {
  const std::wstring buf = store->BufferSnapshot();
  const bool compact = CompactHarnessMode();
  LONG sel_start = 0, sel_end = 0;
  store->SelectionSnapshot(&sel_start, &sel_end);
  std::wstring comp;
  if (store->CompositionActive()) {
    comp = std::to_wstring(store->CompositionStart()) + L"," +
          std::to_wstring(store->CompositionEnd());
  } else {
    comp = L"-";
  }
  const std::wstring line = compact
      ? L"AFTER " + token + L" BUF_LEN=" + std::to_wstring(buf.size()) +
            L" SEL=" + std::to_wstring(sel_start) + L"," +
            std::to_wstring(sel_end) + L" COMP=" + comp
      : L"AFTER " + token + L" BUF=[" + buf + L"] SEL=" +
            std::to_wstring(sel_start) + L"," +
            std::to_wstring(sel_end) + L" COMP=" + comp;
  std::printf("%s\n", Utf8FromWide(line).c_str());
  store->PrintImmSnapshot(token);
  std::fflush(stdout);
}

void PrintFinalLine(const DocumentStore* store) {
  const std::wstring buf = store->BufferSnapshot();
  uint64_t hash = 14695981039346656037ull;
  for (const wchar_t value : buf) {
    hash ^= static_cast<uint16_t>(value);
    hash *= 1099511628211ull;
  }
  std::printf("FINAL BUF_LEN=%zu BUF_FNV=%016llx\n", buf.size(),
              static_cast<unsigned long long>(hash));
  std::fflush(stdout);
}

HRESULT SetKeyboardOpen(ITfThreadMgr* thread_mgr, TfClientId client_id,
                        bool open) {
  ITfCompartmentMgr* manager = nullptr;
  ITfCompartment* compartment = nullptr;
  HRESULT result = thread_mgr->QueryInterface(
      IID_ITfCompartmentMgr, reinterpret_cast<void**>(&manager));
  if (SUCCEEDED(result)) {
    result = manager->GetCompartment(GUID_COMPARTMENT_KEYBOARD_OPENCLOSE,
                                     &compartment);
  }
  if (SUCCEEDED(result)) {
    VARIANT value;
    VariantInit(&value);
    value.vt = VT_I4;
    value.lVal = open ? 1 : 0;
    result = compartment->SetValue(client_id, &value);
    VariantClear(&value);
    VARIANT observed;
    VariantInit(&observed);
    const HRESULT get_result = compartment->GetValue(&observed);
    std::printf("COMPARTMENT open=%ld vt=%u get=%08lx\n",
                observed.vt == VT_I4 ? observed.lVal : -1L,
                static_cast<unsigned>(observed.vt),
                static_cast<unsigned long>(get_result));
    VariantClear(&observed);
  }
  if (compartment != nullptr) compartment->Release();
  if (manager != nullptr) manager->Release();
  return result;
}

#include "inline_context_alias.h"
#include "../src/state_mirror.h"

void RunScript(ITfKeyEventSink* key_sink, ITfKeystrokeMgr* keystroke_mgr,
               ITfThreadMgr* thread_mgr, TfClientId client_id,
               ITfContext* const contexts[2], DocumentStore* const stores[2],
               ITfDocumentMgr* const documents[2],
               const std::wstring& script) {
  struct HeldMirror {
    HANDLE map = nullptr, writer = nullptr; NativeStateMirror* view = nullptr; LONG sequence = 0;
    void Clear() {
      if (view) { ReleaseStateMirror(view, sequence, writer); UnmapViewOfFile(view); view = nullptr; }
      if (map) { CloseHandle(map); map = nullptr; }
      if (writer) { CloseHandle(writer); writer = nullptr; }
    }
    ~HeldMirror() { Clear(); }
  } held;
  std::wstringstream stream(script);
  std::wstring token;
  size_t active = 0;
  bool alias_next = false;
  while (stream >> token) {
    if (token == L"SKKSERV0" || token == L"SKKSERV1") {
      wchar_t key_name[256]{}; GetEnvironmentVariableW(L"NATIVEIME_REGISTRY_KEY", key_name, 256);
      HKEY key = nullptr; LONG status = ERROR_ACCESS_DENIED;
      if (std::wstring(key_name).starts_with(L"Software\\NativeIME-test-") &&
          RegOpenKeyExW(HKEY_CURRENT_USER, key_name, 0, KEY_SET_VALUE, &key) == ERROR_SUCCESS) {
        DWORD enabled = token == L"SKKSERV1" ? 1 : 0;
        status = RegSetValueExW(key, L"SkkServEnable", 0, REG_DWORD, reinterpret_cast<BYTE*>(&enabled), sizeof(enabled));
        RegCloseKey(key);
      }
      std::printf("SKKSERV toggle status=%ld\n", status); continue;
    }
    if (token == L"MIRRORUNLOCK") { held.Clear(); std::printf("MIRROR unlocked=1\n"); continue; }
    if (token == L"MIRRORLOCK") {
      wchar_t pipe[256]{}; const DWORD n = GetEnvironmentVariableW(L"DDSKK_PIPE_NAME", pipe, 256);
      if (!n || n >= 256 || held.view) { std::printf("MIRROR lock_failed=1\n"); continue; }
      held.map = OpenFileMappingW(FILE_MAP_WRITE, FALSE, NativeStateMirrorName(pipe).c_str());
      auto* view = held.map ? static_cast<NativeStateMirror*>(MapViewOfFile(held.map, FILE_MAP_WRITE, 0, 0, sizeof(NativeStateMirror))) : nullptr;
      held.writer = OpenMutexW(SYNCHRONIZE | MUTEX_MODIFY_STATE, FALSE, (NativeStateMirrorName(pipe) + L"-writer").c_str());
      if (!view || !TryOwnStateMirror(view, &held.sequence, held.writer)) {
        if (view) UnmapViewOfFile(view); held.Clear(); std::printf("MIRROR lock_failed=1\n"); continue;
      }
      held.view = view; std::printf("MIRROR locked=1\n"); continue;
    }
    if (token == L"MIRROR") {
      wchar_t pipe[256]{};
      const DWORD n = GetEnvironmentVariableW(L"DDSKK_PIPE_NAME", pipe, 256);
      if (!n || n >= 256) { std::printf("MIRROR unavailable=pipe\n"); continue; } // Private test only.
      std::wstring suffix(pipe);
      for (auto& c : suffix) if (c == L'\\' || c == L'/') c = L'_';
      const auto name = L"Local\\ddskk-ime-state-v1-" + suffix;
      HANDLE map = OpenFileMappingW(FILE_MAP_READ, FALSE, name.c_str());
      struct Mirror { volatile LONG sequence; char line[8192]; };
      const auto* view = map ? static_cast<const Mirror*>(MapViewOfFile(map, FILE_MAP_READ, 0, 0, sizeof(Mirror))) : nullptr;
      if (!view) { if (map) CloseHandle(map); std::printf("MIRROR unavailable=mapping\n"); continue; }
      const LONG before = view->sequence;
      char line[8192]{}; memcpy(line, view->line, sizeof(line)-1); MemoryBarrier();
      const LONG after = view->sequence;
      std::printf("MIRROR stable=%d line=%s\n", before == after && !(after & 1), line);
      UnmapViewOfFile(view); CloseHandle(map);
      continue;
    }
    if (token == L"KEYSTATE:SHIFT" || token == L"KEYSTATE:CLEAR") {
      BYTE ambient[256]{};
      ambient[VK_SHIFT] = token == L"KEYSTATE:SHIFT" ? 0x80 : 0;
      SetKeyboardState(ambient);
      std::printf("INHERITED_MODIFIERS shift=%d\n", ambient[VK_SHIFT] != 0);
    } else if (token == L"CONTEXTALIAS") {
      alias_next = true;
    } else if (token == L"SETTINGS") {
      // Exercise the real toolbar item and its core callback, without
      // posting clicks to any live taskbar or launching an engine.
      ITfLangBarItemMgr* manager = nullptr;
      ITfLangBarItem* item = nullptr;
      ITfLangBarItemButton* button = nullptr;
      HRESULT hr = thread_mgr->QueryInterface(IID_ITfLangBarItemMgr,
          reinterpret_cast<void**>(&manager));
      if (SUCCEEDED(hr)) hr = manager->GetItem(GUID_DdskkSettingsButton, &item);
      if (SUCCEEDED(hr)) hr = item->QueryInterface(IID_ITfLangBarItemButton,
          reinterpret_cast<void**>(&button));
      if (SUCCEEDED(hr)) hr = button->OnMenuSelect(3);
      PrintHr("ToolbarSettings", hr);
      if (button) button->Release();
      if (item) item->Release();
      if (manager) manager->Release();
    } else if (token == L"EXITNOW") {
      wchar_t root[1024]{};
      GetEnvironmentVariableW(L"NATIVEIME_REGISTRY_KEY", root, _countof(root));
      if (!std::wstring(root).starts_with(L"Software\\NativeIME-test-")) std::exit(1);
      std::printf("CLIENT_ABRUPT_EXIT pid=%lu\n", GetCurrentProcessId());
      std::fflush(stdout);
      ExitProcess(0); // Deliberately skips COM/TIP teardown for dead-PID cleanup.
    } else if (token.starts_with(L"CORE:")) {
      wchar_t root[1024]{}, directory[32768]{};
      GetEnvironmentVariableW(L"NATIVEIME_REGISTRY_KEY", root, _countof(root));
      GetEnvironmentVariableW(L"NATIVEIME_TEST_CORE_DIRECTORY", directory, _countof(directory));
      if (!std::wstring(root).starts_with(L"Software\\NativeIME-test-") || !directory[0]) std::exit(1);
      const std::wstring variant = token.substr(5);
      if (variant == L"DEPLOY" || variant == L"ROLLBACK") {
        wchar_t action_script[32768]{};
        GetEnvironmentVariableW(L"NATIVEIME_TEST_CORE_ACTION_SCRIPT", action_script, _countof(action_script));
        if (!action_script[0]) std::exit(1);
        const std::wstring action = variant == L"DEPLOY" ? L"deploy" : L"rollback";
        std::wstring command = L"powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"" +
            std::wstring(action_script) + L"\" -Action " + action + L" -CoreSource \"" +
            directory + L"\\ddskk-ime-core-B.dll\"";
        STARTUPINFOW startup{}; startup.cb = sizeof(startup);
        startup.dwFlags = STARTF_USESHOWWINDOW; startup.wShowWindow = SW_HIDE;
        PROCESS_INFORMATION process{};
        if (!CreateProcessW(nullptr, command.data(), nullptr, nullptr, FALSE,
            CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process)) std::exit(1);
        const DWORD wait = WaitForSingleObject(process.hProcess, 15000);
        DWORD exit_code = 1;
        if (wait != WAIT_OBJECT_0) { TerminateProcess(process.hProcess, 1); WaitForSingleObject(process.hProcess, 5000); }
        else GetExitCodeProcess(process.hProcess, &exit_code);
        std::printf("CORE_ACTION action=%s helper_pid=%lu exit=%lu pid=%lu\n",
            Utf8FromWide(action).c_str(), process.dwProcessId, exit_code, GetCurrentProcessId());
        CloseHandle(process.hThread); CloseHandle(process.hProcess); std::fflush(stdout);
        if (exit_code != 0) std::exit(1);
        PumpMessages(700);
        PrintAfterLine(token, stores[active]);
        continue;
      }
      if (variant != L"production" && variant != L"B" && variant != L"bad-abi" &&
          variant != L"bad-init" && variant != L"missing") std::exit(1);
      const std::wstring file = std::wstring(directory) + L"\\ddskk-ime-core" +
          (variant == L"production" ? L"" : L"-" + variant) + L".dll";
      HKEY key = nullptr;
      LONG status = RegOpenKeyExW(HKEY_CURRENT_USER, root, 0, KEY_SET_VALUE, &key);
      if (status == ERROR_SUCCESS) {
        status = RegSetValueExW(key, L"CoreDll", 0, REG_SZ,
            reinterpret_cast<const BYTE*>(file.c_str()), static_cast<DWORD>((file.size() + 1) * sizeof(wchar_t)));
        RegCloseKey(key);
      }
      std::printf("CORE_REQUEST version=%s status=%ld pid=%lu\n",
          Utf8FromWide(variant).c_str(), status, GetCurrentProcessId()); std::fflush(stdout);
      if (status != ERROR_SUCCESS) std::exit(1);
    } else if (token == L"CLIENT") {
      PumpMessages(30);
      wchar_t root[1024]{};
      GetEnvironmentVariableW(L"NATIVEIME_REGISTRY_KEY", root, _countof(root));
      if (!std::wstring(root).starts_with(L"Software\\NativeIME-test-")) std::exit(1);
      const std::wstring path = std::wstring(root) + L"\\Clients\\" +
          std::to_wstring(GetCurrentProcessId());
      HKEY key = nullptr;
      if (RegOpenKeyExW(HKEY_CURRENT_USER, path.c_str(), 0, KEY_READ, &key) != ERROR_SUCCESS) {
        std::printf("CLIENT missing=1\n");
      } else {
        wchar_t mode[64]{};
        DWORD bytes = sizeof(mode), open = 0, composing = 0, sequence = 0;
        RegQueryValueExW(key, L"mode", nullptr, nullptr, reinterpret_cast<BYTE*>(mode), &bytes);
        auto read = [key](const wchar_t* name, DWORD* value) {
          DWORD size = sizeof(*value);
          RegQueryValueExW(key, name, nullptr, nullptr, reinterpret_cast<BYTE*>(value), &size);
        };
        read(L"open", &open); read(L"composing", &composing); read(L"sequence", &sequence);
        RegCloseKey(key);
        std::printf("CLIENT mode=%s open=%lu composing=%lu sequence=%lu\n",
                    Utf8FromWide(mode).c_str(), open, composing, sequence);
      }
    } else if (token.starts_with(L"ENGINE:")) {
      wchar_t path[1024]{};
      GetEnvironmentVariableW(L"NATIVEIME_REGISTRY_KEY", path, _countof(path));
      if (std::wstring(path).starts_with(L"Software\\NativeIME-test-")) {
        HKEY key = nullptr;
        if (RegOpenKeyExW(HKEY_CURRENT_USER, path, 0, KEY_SET_VALUE, &key) == ERROR_SUCCESS) {
          const std::wstring id = token.substr(7);
          RegSetValueExW(key, L"Engine", 0, REG_SZ,
              reinterpret_cast<const BYTE*>(id.c_str()), static_cast<DWORD>((id.size()+1)*sizeof(wchar_t)));
          RegCloseKey(key);
        }
      }
    } else if (token == L"KILLHOST" || token == L"KILLCHILD") {
      wchar_t value[32]{};
      GetEnvironmentVariableW(L"NATIVEIME_TEST_HOST_PID", value, _countof(value));
      DWORD pid = wcstoul(value, nullptr, 10);
      const DWORD parent_pid = pid;
      if (token == L"KILLCHILD") {
        wchar_t engine_name[MAX_PATH]{};
        GetEnvironmentVariableW(L"NATIVEIME_TEST_ENGINE_NAME", engine_name, _countof(engine_name));
        HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        PROCESSENTRY32W entry{}; entry.dwSize = sizeof(entry);
        DWORD child = 0;
        if (Process32FirstW(snapshot, &entry)) do {
          if (entry.th32ParentProcessID == pid && engine_name[0] &&
              _wcsicmp(entry.szExeFile, engine_name) == 0) {
            child = entry.th32ProcessID; break;
          }
        } while (Process32NextW(snapshot, &entry));
        CloseHandle(snapshot); pid = child;
      }
      if (pid != 0) {
        HANDLE process = OpenProcess(PROCESS_TERMINATE, FALSE, pid);
        const BOOL killed = process && TerminateProcess(process, 1);
        std::printf("TEST_KILL token=%s parent=%lu target=%lu success=%d error=%lu\n",
            Utf8FromWide(token).c_str(), parent_pid, pid, killed, killed ? 0 : GetLastError());
        if (process) CloseHandle(process);
        if (!killed) std::exit(1);
      } else {
        std::printf("TEST_KILL token=%s parent=%lu target=0 success=0\n", Utf8FromWide(token).c_str(), parent_pid);
        std::exit(1);
      }
    } else if (token == L"REFUSEWRITE") {
      stores[active]->RefuseNextWrite();
    } else if (token.starts_with(L"REFUSEWRITES")) {
      stores[active]->RefuseWrites(std::min<DWORD>(10000, wcstoul(token.c_str() + 12, nullptr, 10)));
    } else if (token.starts_with(L"DENYWRITES") && token.size() > 10) {
      const auto ms = wcstoul(token.c_str() + 10, nullptr, 10);
      if (ms && ms <= 10000) stores[active]->DenyWrites(ms);
    } else if (token.starts_with(L"WAITREMAP")) {
      WaitForRemap(std::min<DWORD>(10000, wcstoul(token.c_str() + 9, nullptr, 10)));
    } else if (token.starts_with(L"KEYGAP")) {
      scripted_key_gap = std::min<DWORD>(20, wcstoul(token.c_str() + 6, nullptr, 10));
    } else if (token == L"ASYNCWRITE") {
      stores[active]->DelayWrites();
    } else if (token == L"ASYNCFLUSH") {
      stores[active]->FlushWrites();
      // Confirmation deliberately schedules fresh keys after unlock. Drain
      // those queued continuations before observing the completed flush;
      // never execute them from within the text-store write lock.
      PumpMessages(0);
    } else if (token == L"DENYWRITE") {
      stores[active]->DenyNextWrite();
    } else if (token == L"APPCLEAR") {
      stores[active]->ApplicationClear();
    } else if (token == L"CTX1" || token == L"CTX2") {
      active = token == L"CTX1" ? 0 : 1;
      const HRESULT hr = thread_mgr->SetFocus(documents[active]);
      PrintHrStr(Utf8FromWide(token), hr);
    } else if (token == L"CHECK1" || token == L"CHECK2") {
      const size_t observed = token == L"CHECK1" ? 0 : 1;
      PrintAfterLine(token, stores[observed]);
      continue;
    } else if (token.starts_with(L"SETTLE")) {
      wchar_t* end = nullptr;
      const unsigned long milliseconds = wcstoul(token.c_str() + 6, &end, 10);
      if (end == token.c_str() + 6 || milliseconds == 0 || milliseconds > 60000 ||
          (*end != L'\0' && (*end != L':' || end[1] == L'\0'))) {
        PrintHrStr("InvalidSettle:" + Utf8FromWide(token), E_INVALIDARG);
        std::exit(1);
      }
      Settle(key_sink, keystroke_mgr, contexts[active], stores[active],
             static_cast<DWORD>(milliseconds), token);
      if (*end == L':') {
        PrintAfterLine(end + 1, stores[active]);
        continue;
      }
    } else if (token.size() > 4 && token.starts_with(L"WAIT")) {
      // Provider conversion completes through the TSF thread's message
      // queue. Sleeping here starves that queue and cannot test async IME
      // behavior, so keep pumping for the requested observation window.
      wchar_t* end = nullptr;
      const unsigned long milliseconds = wcstoul(token.c_str() + 4, &end, 10);
      if (end != token.c_str() + 4 && *end == L'\0' && milliseconds <= 60000)
        PumpMessages(static_cast<DWORD>(milliseconds));
      else
        PrintHrStr("UnknownToken:" + Utf8FromWide(token), E_INVALIDARG);
    } else if (token == L"IMEOFF" || token == L"IMEON") {
      const HRESULT hr =
          SetKeyboardOpen(thread_mgr, client_id, token == L"IMEON");
      PrintHrStr(Utf8FromWide(token), hr);
    } else {
      KeyEvent key{};
      if (TokenToKey(token, &key)) {
        if (alias_next) {
          auto* alias = new InlineContextAlias(contexts[active]);
          IUnknown* base_identity = nullptr;
          IUnknown* alias_identity = nullptr;
          contexts[active]->QueryInterface(IID_IUnknown, reinterpret_cast<void**>(&base_identity));
          alias->QueryInterface(IID_IUnknown, reinterpret_cast<void**>(&alias_identity));
          std::printf("CONTEXT_ALIAS distinct=%d same_identity=%d\n",
                      alias != contexts[active], base_identity == alias_identity);
          if (base_identity) base_identity->Release();
          if (alias_identity) alias_identity->Release();
          SendScriptedKey(key_sink, keystroke_mgr, alias, key, token);
          alias->Release();
          alias_next = false;
        } else {
          SendScriptedKey(key_sink, keystroke_mgr, contexts[active], key, token);
        }
      } else {
        PrintHrStr("UnknownToken:" + Utf8FromWide(token), E_INVALIDARG);
      }
    }
    PrintAfterLine(token, stores[active]);
  }
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  wchar_t private_key[1024]{}, private_pipe[256]{}, private_dll[32768]{};
  GetEnvironmentVariableW(L"NATIVEIME_REGISTRY_KEY", private_key, _countof(private_key));
  GetEnvironmentVariableW(L"DDSKK_PIPE_NAME", private_pipe, _countof(private_pipe));
  GetEnvironmentVariableW(L"DDSKK_HARNESS_DLL_PATH", private_dll, _countof(private_dll));
  if (!std::wstring(private_key).starts_with(L"Software\\NativeIME-test-") ||
      !std::wstring(private_pipe).starts_with(L"\\\\.\\pipe\\ddskk-test-") || !private_dll[0]) {
    std::fprintf(stderr, "tsf-host requires private registry/pipe and an explicit DLL; use run-harness.ps1\n");
    return 2;
  }
  SetConsoleOutputCP(CP_UTF8);
  // Join every argument: callers (notably PowerShell's Start-Process) may
  // deliver the space-separated script as one argv entry per token.
  std::wstring script;
  for (int i = 1; i < argc; ++i) {
    if (!script.empty()) script += L' ';
    script += argv[i];
  }

  ITfThreadMgr* thread_mgr = nullptr;
  ITfDocumentMgr* doc_mgr = nullptr;
  ITfDocumentMgr* doc_mgr2 = nullptr;
  ITfContext* context = nullptr;
  ITfContext* context2 = nullptr;
  ITfKeystrokeMgr* keystroke_mgr = nullptr;
  ITfTextInputProcessor* tip = nullptr;
  ITfKeyEventSink* key_sink = nullptr;
  bool tip_activated = false;
  DocumentStore* store = nullptr;
  DocumentStore* store2 = nullptr;
  TfClientId client_id = TF_CLIENTID_NULL;
  bool thread_mgr_activated = false;
  HWND hwnd = nullptr;
  bool co_initialized = false;

  do {
    HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (FAILED(hr)) {
      PrintHr("CoInitializeEx", hr);
      break;
    }
    co_initialized = true;

    hwnd = CreateHiddenWindow(GetModuleHandleW(nullptr));
    if (hwnd == nullptr) {
      PrintHr("CreateHiddenWindow", HRESULT_FROM_WIN32(GetLastError()));
      break;
    }

    hr = CoCreateInstance(CLSID_TF_ThreadMgr, nullptr, CLSCTX_INPROC_SERVER,
                          IID_ITfThreadMgr,
                          reinterpret_cast<void**>(&thread_mgr));
    if (FAILED(hr)) {
      PrintHr("CoCreateInstance(ThreadMgr)", hr);
      break;
    }

    ITfThreadMgrEx* isolated_manager = nullptr;
    hr = thread_mgr->QueryInterface(IID_ITfThreadMgrEx,
        reinterpret_cast<void**>(&isolated_manager));
    if (SUCCEEDED(hr)) {
      hr = isolated_manager->ActivateEx(&client_id, TF_TMAE_NOACTIVATETIP);
      isolated_manager->Release();
    }
    if (FAILED(hr)) {
      PrintHr("ThreadMgr::Activate", hr);
      break;
    }
    thread_mgr_activated = true;
    std::printf("INIT hwnd=%p client_id=%lu\n", static_cast<void*>(hwnd),
               static_cast<unsigned long>(client_id));

    store = new (std::nothrow) DocumentStore(hwnd);
    if (store == nullptr) {
      PrintHr("DocumentStoreAlloc", E_OUTOFMEMORY);
      break;
    }

    hr = thread_mgr->CreateDocumentMgr(&doc_mgr);
    if (FAILED(hr)) {
      PrintHr("CreateDocumentMgr", hr);
      break;
    }

    TfEditCookie edit_cookie = 0;
    hr = doc_mgr->CreateContext(
        client_id, 0, static_cast<IUnknown*>(static_cast<ITextStoreACP*>(store)),
        &context, &edit_cookie);
    if (FAILED(hr)) {
      PrintHr("CreateContext", hr);
      break;
    }

    // No explicit AdviseSink() for ITfContextOwnerCompositionSink here:
    // that is not a general multi-subscriber sink advised through
    // ITfSource (a real attempt to do so fails with
    // CONNECT_E_CANNOTCONNECT -- confirmed while building this harness).
    // Per CreateContext()'s own contract, the "context owner" -- the punk
    // passed in above -- is QueryInterface'd by TSF itself for
    // ITfContextOwnerCompositionSink (and ITfContextOwnerServices,
    // ITfCompartmentEventSink, ...) if it supports them. DocumentStore
    // already implements that interface, so TSF picks it up automatically
    // from the very same object handed to CreateContext, with no separate
    // registration step.

    hr = doc_mgr->Push(context);
    if (FAILED(hr)) {
      PrintHr("DocumentMgr::Push", hr);
      break;
    }

    // A second independent document/context lets scripts reproduce Edge,
    // Terminal and editor tab focus changes inside one TIP instance. The
    // active composition must be ended in its original document before the
    // first key is accepted in the new one.
    store2 = new (std::nothrow) DocumentStore(hwnd);
    if (store2 == nullptr) {
      PrintHr("DocumentStore2Alloc", E_OUTOFMEMORY);
      break;
    }
    hr = thread_mgr->CreateDocumentMgr(&doc_mgr2);
    if (FAILED(hr)) {
      PrintHr("CreateDocumentMgr2", hr);
      break;
    }
    hr = doc_mgr2->CreateContext(
        client_id, 0, static_cast<IUnknown*>(static_cast<ITextStoreACP*>(store2)),
        &context2, &edit_cookie);
    if (FAILED(hr)) {
      PrintHr("CreateContext2", hr);
      break;
    }
    hr = doc_mgr2->Push(context2);
    if (FAILED(hr)) {
      PrintHr("DocumentMgr2::Push", hr);
      break;
    }
    std::printf("CONTEXTS first=%p second=%p\n",
                static_cast<void*>(context), static_cast<void*>(context2));

    hr = thread_mgr->SetFocus(doc_mgr);
    if (FAILED(hr)) PrintHr("ThreadMgr::SetFocus", hr);

    // Classic minimal-host gotcha: keyboard TIPs are only activated while
    // the thread's keyboard compartment is OPEN. Real apps get this from
    // CUAS; a raw host must set GUID_COMPARTMENT_KEYBOARD_OPENCLOSE = 1
    // itself, or TSF loads the TIP DLL but never calls its Activate() --
    // exactly the "TIP_DLL loaded=1 yet no key ever claimed" symptom this
    // harness first produced.
    {
      ITfCompartmentMgr* compartment_mgr = nullptr;
      hr = thread_mgr->QueryInterface(IID_ITfCompartmentMgr,
                                      reinterpret_cast<void**>(&compartment_mgr));
      if (SUCCEEDED(hr)) {
        ITfCompartment* keyboard = nullptr;
        hr = compartment_mgr->GetCompartment(GUID_COMPARTMENT_KEYBOARD_OPENCLOSE,
                                             &keyboard);
        if (SUCCEEDED(hr)) {
          VARIANT value;
          VariantInit(&value);
          value.vt = VT_I4;
          value.lVal = 1;
          hr = keyboard->SetValue(client_id, &value);
          if (FAILED(hr)) PrintHr("KeyboardOpenClose::SetValue", hr);
          keyboard->Release();
        } else {
          PrintHr("GetCompartment(KeyboardOpenClose)", hr);
        }
        compartment_mgr->Release();
      } else {
        PrintHr("QI(ITfCompartmentMgr)", hr);
      }
    }

    // Deliberately NOT activating the language profile here: when TSF
    // creates its own TIP instance it claims the key-event-sink slot, the
    // direct instance below then fails AdviseKeyEventSink with
    // E_INVALIDARG, and yet ITfKeystrokeMgr still refuses to forward keys
    // to TSF's instance in this minimal host (observed repeatedly). One
    // instance, driven directly, is deterministic.
    (void)&ActivateIme;

    // Direct TIP instantiation: see the comment above SendScriptedKey.
    // When TSF has already activated its own TIP instance for this thread
    // (nondeterministic in this minimal host), the direct instance's
    // AdviseKeyEventSink fails with E_INVALIDARG (sink slot taken); fall
    // back to routing keys through ITfKeystrokeMgr, which reaches TSF's
    // instance instead.
    tip = CreateTipFromDllPath();
    hr = tip != nullptr ? S_OK : E_FAIL;
    std::printf("TIP_DIRECT create hr=%08lx\n", static_cast<unsigned long>(hr));
    if (SUCCEEDED(hr)) {
      // ActivateEx disabled automatic TIP activation. Use the manager's
      // activated client id; a GetClientId-only id is not an active client.
      TfClientId direct_client_id = client_id;
      std::printf("TIP_DIRECT client_id=%u (host=%u)\n",
                  static_cast<unsigned>(direct_client_id),
                  static_cast<unsigned>(client_id));
      auto* direct_manager = new DirectThreadMgr(thread_mgr);
      hr = tip->Activate(direct_manager, direct_client_id);
      direct_manager->Release();
      std::printf("TIP_DIRECT activate hr=%08lx\n",
                  static_cast<unsigned long>(hr));
      tip_activated = true;
      if (FAILED(hr)) break;
      // Full TIP/langbar activation can reset this minimal host's initially
      // open compartment. Establish the same open starting condition again
      // after activation, through Windows' real compartment and event sink.
      hr = SetKeyboardOpen(thread_mgr, client_id, true);
      PrintHr("TIP_DIRECT post-activate open", hr);
      if (FAILED(hr)) break;
      if (FAILED(tip->QueryInterface(IID_ITfKeyEventSink,
                                     reinterpret_cast<void**>(&key_sink)))) {
        key_sink = nullptr;
      }
    }
    if (key_sink == nullptr) {
      hr = thread_mgr->QueryInterface(IID_ITfKeystrokeMgr,
                                      reinterpret_cast<void**>(&keystroke_mgr));
      std::printf("KEY_ROUTE fallback=keystroke_mgr hr=%08lx\n",
                  static_cast<unsigned long>(hr));
      if (FAILED(hr)) break;
    } else {
      std::printf("KEY_ROUTE direct=key_sink\n");
    }
    std::fflush(stdout);
    if (!script.empty()) {
      // Drain deferred TSF focus/activation notifications before accepting
      // input. A notification left from SetFocus can otherwise terminate
      // the composition created by the first scripted character.
      PumpMessages(500);
      ITfContext* contexts[2] = {context, context2};
      DocumentStore* stores[2] = {store, store2};
      ITfDocumentMgr* documents[2] = {doc_mgr, doc_mgr2};
      RunScript(key_sink, keystroke_mgr, thread_mgr, client_id,
                contexts, stores, documents, script);
      PrintFinalLine(store);
    }
  } while (false);

  if (key_sink != nullptr) key_sink->Release();
  if (tip_activated && tip != nullptr) tip->Deactivate();
  if (tip != nullptr) tip->Release();
  if (keystroke_mgr != nullptr) keystroke_mgr->Release();
  if (doc_mgr2 != nullptr) doc_mgr2->Pop(TF_POPF_ALL);
  if (doc_mgr != nullptr) doc_mgr->Pop(TF_POPF_ALL);
  if (context2 != nullptr) context2->Release();
  if (context != nullptr) context->Release();
  if (doc_mgr2 != nullptr) doc_mgr2->Release();
  if (doc_mgr != nullptr) doc_mgr->Release();
  if (store2 != nullptr) static_cast<ITextStoreACP*>(store2)->Release();
  if (store != nullptr) static_cast<ITextStoreACP*>(store)->Release();
  if (thread_mgr_activated && thread_mgr != nullptr) thread_mgr->Deactivate();
  if (thread_mgr != nullptr) thread_mgr->Release();
  if (hwnd != nullptr) DestroyWindow(hwnd);
  if (co_initialized) CoUninitialize();

  return 0;
}
