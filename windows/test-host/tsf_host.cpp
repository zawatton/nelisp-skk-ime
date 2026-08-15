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
//   SPACE         VK_SPACE
//   ENTER         VK_RETURN
//   BS            VK_BACK
//   ESC           VK_ESCAPE
//   CTRLJ         Ctrl+J (skk-kakutei-key)
//   WAIT500       sleep 500 ms (no key event)
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

#include <objidl.h>
#include <olectl.h>
#include <textstor.h>
#include <msctf.h>

#include "guids.h"

#include <algorithm>
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
    *phrSession = sink_->OnLockGranted(dwLockFlags);
    locked_ = false;
    current_lock_flags_ = 0;
    // Grant any lock(s) that arrived re-entrantly while we were locked,
    // now that the outer lock has released. sink_->OnLockGranted() below
    // may itself re-enter RequestLock and queue another one, so this is a
    // loop, not a single follow-up call.
    while (pending_lock_) {
      pending_lock_ = false;
      const DWORD flags = pending_lock_flags_;
      locked_ = true;
      current_lock_flags_ = flags;
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
    if (pfOk != nullptr) *pfOk = TRUE;
    composition_active_ = true;
    UpdateCompositionSpan(pComposition);
    std::printf("COMPOSITION START range=%ld,%ld\n",
                static_cast<long>(comp_start_), static_cast<long>(comp_end_));
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE OnUpdateComposition(ITfCompositionView* pComposition,
                                                ITfRange* /*pRangeNew*/) override {
    UpdateCompositionSpan(pComposition);
    std::printf("COMPOSITION UPDATE range=%ld,%ld\n",
                static_cast<long>(comp_start_), static_cast<long>(comp_end_));
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE OnEndComposition(
      ITfCompositionView* pComposition) override {
    UpdateCompositionSpan(pComposition);
    std::printf("COMPOSITION END range=%ld,%ld\n",
                static_cast<long>(comp_start_), static_cast<long>(comp_end_));
    composition_active_ = false;
    return S_OK;
  }

  // --- Test-harness accessors -------------------------------------------
  std::wstring BufferSnapshot() const { return buffer_; }
  void SelectionSnapshot(LONG* start, LONG* end) const {
    *start = sel_start_;
    *end = sel_end_;
  }
  bool CompositionActive() const { return composition_active_; }
  LONG CompositionStart() const { return comp_start_; }
  LONG CompositionEnd() const { return comp_end_; }

 private:
  static constexpr TsViewCookie kViewCookie = 1;

  bool IsReadWriteLocked() const {
    return (current_lock_flags_ & TS_LF_READWRITE) == TS_LF_READWRITE;
  }

  void NotifyTextChange(LONG start, LONG old_end, LONG new_end) {
    if (sink_ != nullptr && (sink_mask_ & TS_AS_TEXT_CHANGE)) {
      TS_TEXTCHANGE change{start, old_end, new_end};
      sink_->OnTextChange(0, &change);
    }
  }
  void NotifySelectionChange() {
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

  LONG ref_count_ = 1;
  HWND hwnd_ = nullptr;
  std::wstring buffer_;
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
  if (token == L"LEFT") { *out = KeyEvent{VK_LEFT, false, false}; return true; }
  if (token == L"RIGHT") { *out = KeyEvent{VK_RIGHT, false, false}; return true; }
  if (token == L"UP") { *out = KeyEvent{VK_UP, false, false}; return true; }
  if (token == L"DOWN") { *out = KeyEvent{VK_DOWN, false, false}; return true; }
  if (token == L"DEL") { *out = KeyEvent{VK_DELETE, false, false}; return true; }
  if (token == L"HOME") { *out = KeyEvent{VK_HOME, false, false}; return true; }
  if (token == L"END") { *out = KeyEvent{VK_END, false, false}; return true; }
  if (token.size() == 1) {
    const wchar_t ch = token[0];
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

constexpr DWORD kPumpMs = 15;

void PumpMessages(DWORD duration_ms) {
  MSG msg;
  const ULONGLONG deadline = GetTickCount64() + duration_ms;
  do {
    while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&msg);
      DispatchMessageW(&msg);
    }
    Sleep(1);
  } while (GetTickCount64() < deadline);
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
void SendScriptedKey(ITfKeyEventSink* key_sink, ITfKeystrokeMgr* keystroke_mgr,
                     ITfContext* context, const KeyEvent& key) {
  BYTE state_before[256]{};
  GetKeyboardState(state_before);
  BYTE state[256];
  memcpy(state, state_before, sizeof(state));
  if (key.shift) state[VK_SHIFT] |= 0x80;
  if (key.ctrl) state[VK_CONTROL] |= 0x80;
  SetKeyboardState(state);

  const UINT scan = MapVirtualKeyW(key.vk, MAPVK_VK_TO_VSC);
  const LPARAM lparam_down = (static_cast<LPARAM>(scan) << 16) | 1;

  // Prefer feeding the TIP's ITfKeyEventSink directly (deterministic,
  // needs no TSF-side routing); fall back to ITfKeystrokeMgr when TSF's
  // own instance already owns the key sink registration.
  const auto test_down = [&](BOOL* e) {
    return key_sink != nullptr
        ? key_sink->OnTestKeyDown(context, key.vk, lparam_down, e)
        : keystroke_mgr->TestKeyDown(key.vk, lparam_down, e);
  };
  const auto down = [&](BOOL* e) {
    return key_sink != nullptr
        ? key_sink->OnKeyDown(context, key.vk, lparam_down, e)
        : keystroke_mgr->KeyDown(key.vk, lparam_down, e);
  };

  BOOL eaten = FALSE;
  HRESULT hr = test_down(&eaten);
  if (FAILED(hr)) {
    PrintHr("TestKeyDown", hr);
  } else if (eaten) {
    eaten = FALSE;
    hr = down(&eaten);
    if (FAILED(hr)) PrintHr("KeyDown", hr);
    std::printf("KEYDOWN vk=%02X eaten=%d\n", key.vk, eaten);
  } else {
    std::printf("TESTKEYDOWN vk=%02X eaten=0 (key not claimed)\n", key.vk);
  }
  std::fflush(stdout);
  PumpMessages(kPumpMs);

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
    hr = key_sink != nullptr
        ? key_sink->OnKeyUp(context, key.vk, lparam_up, &eaten_up)
        : keystroke_mgr->KeyUp(key.vk, lparam_up, &eaten_up);
    if (FAILED(hr)) PrintHr("KeyUp", hr);
  }
  PumpMessages(kPumpMs);

  SetKeyboardState(state_before);
}

void PrintAfterLine(const std::wstring& token, const DocumentStore* store) {
  const std::wstring buf = store->BufferSnapshot();
  LONG sel_start = 0, sel_end = 0;
  store->SelectionSnapshot(&sel_start, &sel_end);
  std::wstring comp;
  if (store->CompositionActive()) {
    comp = std::to_wstring(store->CompositionStart()) + L"," +
          std::to_wstring(store->CompositionEnd());
  } else {
    comp = L"-";
  }
  const std::wstring line = L"AFTER " + token + L" BUF=[" + buf + L"] SEL=" +
                            std::to_wstring(sel_start) + L"," +
                            std::to_wstring(sel_end) + L" COMP=" + comp;
  std::printf("%s\n", Utf8FromWide(line).c_str());
  std::fflush(stdout);
}

void RunScript(ITfKeyEventSink* key_sink, ITfKeystrokeMgr* keystroke_mgr,
               ITfContext* context, DocumentStore* store,
               const std::wstring& script) {
  std::wstringstream stream(script);
  std::wstring token;
  while (stream >> token) {
    if (token == L"WAIT500") {
      Sleep(500);
    } else {
      KeyEvent key{};
      if (TokenToKey(token, &key)) {
        SendScriptedKey(key_sink, keystroke_mgr, context, key);
      } else {
        PrintHrStr("UnknownToken:" + Utf8FromWide(token), E_INVALIDARG);
      }
    }
    PrintAfterLine(token, store);
  }
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
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
  ITfContext* context = nullptr;
  ITfKeystrokeMgr* keystroke_mgr = nullptr;
  ITfTextInputProcessor* tip = nullptr;
  ITfKeyEventSink* key_sink = nullptr;
  bool tip_activated = false;
  DocumentStore* store = nullptr;
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

    hr = thread_mgr->Activate(&client_id);
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
    hr = CoCreateInstance(CLSID_DdskkTextService, nullptr, CLSCTX_INPROC_SERVER,
                          IID_ITfTextInputProcessor,
                          reinterpret_cast<void**>(&tip));
    std::printf("TIP_DIRECT create hr=%08lx\n", static_cast<unsigned long>(hr));
    if (SUCCEEDED(hr)) {
      // TSF may have auto-activated its own instance of this TIP at
      // thread-manager activation (the profile stays session-active once
      // force-activated in an earlier run), and that instance holds the
      // key-event-sink slot for its client id. Register the direct
      // instance under a separate client id so both can coexist.
      // {D3B26A70-5C11-4B41-9ED4-6E0371C9E1B3} -- harness-local, random.
      static const GUID kHarnessClientGuid = {
          0xd3b26a70, 0x5c11, 0x4b41,
          {0x9e, 0xd4, 0x6e, 0x03, 0x71, 0xc9, 0xe1, 0xb3}};
      TfClientId direct_client_id = client_id;
      ITfClientId* client_id_source = nullptr;
      if (SUCCEEDED(thread_mgr->QueryInterface(
              IID_ITfClientId, reinterpret_cast<void**>(&client_id_source)))) {
        TfClientId fresh = TF_CLIENTID_NULL;
        if (SUCCEEDED(client_id_source->GetClientId(kHarnessClientGuid,
                                                    &fresh)) &&
            fresh != TF_CLIENTID_NULL) {
          direct_client_id = fresh;
        }
        client_id_source->Release();
      }
      std::printf("TIP_DIRECT client_id=%u (host=%u)\n",
                  static_cast<unsigned>(direct_client_id),
                  static_cast<unsigned>(client_id));
      hr = tip->Activate(thread_mgr, direct_client_id);
      std::printf("TIP_DIRECT activate hr=%08lx\n",
                  static_cast<unsigned long>(hr));
      // Activate() builds all the state the key path needs (thread
      // manager, client id, settings, engine connection) BEFORE its
      // AdviseKeyEventSink call, and only that advise can fail here (TSF
      // rejects a second foreground key sink on the thread when its own
      // auto-activated instance holds one). Sink registration is
      // irrelevant to direct driving -- we call OnTestKeyDown/OnKeyDown
      // ourselves -- so proceed with the sink either way.
      tip_activated = true;
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
      RunScript(key_sink, keystroke_mgr, context, store, script);
    }
  } while (false);

  if (key_sink != nullptr) key_sink->Release();
  if (tip_activated && tip != nullptr) tip->Deactivate();
  if (tip != nullptr) tip->Release();
  if (keystroke_mgr != nullptr) keystroke_mgr->Release();
  if (doc_mgr != nullptr) doc_mgr->Pop(TF_POPF_ALL);
  if (context != nullptr) context->Release();
  if (doc_mgr != nullptr) doc_mgr->Release();
  if (store != nullptr) static_cast<ITextStoreACP*>(store)->Release();
  if (thread_mgr_activated && thread_mgr != nullptr) thread_mgr->Deactivate();
  if (thread_mgr != nullptr) thread_mgr->Release();
  if (hwnd != nullptr) DestroyWindow(hwnd);
  if (co_initialized) CoUninitialize();

  return 0;
}
