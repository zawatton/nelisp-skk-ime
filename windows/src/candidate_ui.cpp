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

#include "candidate_ui.h"

#include <oleauto.h>
#include <cstdio>
#pragma comment(lib, "user32.lib")
#ifdef NATIVEIME_CORE_BUILD
extern LONG g_object_count;
#endif

namespace {
const GUID kCandidateUiGuid = {0x776fc53a, 0xba56, 0x47ec,
                              {0xa8, 0x52, 0x24, 0x5d, 0x14, 0x17, 0xe0, 0x41}};
}

CandidateUI::CandidateUI(CandidateUIHandler* handler) : handler_(handler) {
#ifdef NATIVEIME_CORE_BUILD
  InterlockedIncrement(&g_object_count);
#endif
}
CandidateUI::~CandidateUI() {
  SetInlineCaret(nullptr);
  if (document_) document_->Release();
#ifdef NATIVEIME_CORE_BUILD
  InterlockedDecrement(&g_object_count);
#endif
}
HRESULT CandidateUI::QueryInterface(REFIID iid, void** object) {
  if (!object) return E_POINTER;
  *object = nullptr;
  if (iid != IID_IUnknown && iid != IID_ITfUIElement &&
      iid != IID_ITfCandidateListUIElement &&
      iid != IID_ITfCandidateListUIElementBehavior) return E_NOINTERFACE;
  *object = static_cast<ITfCandidateListUIElementBehavior*>(this); AddRef(); return S_OK;
}
ULONG CandidateUI::AddRef() { return InterlockedIncrement(&ref_count_); }
ULONG CandidateUI::Release() { const ULONG n = InterlockedDecrement(&ref_count_); if (!n) delete this; return n; }
HRESULT CandidateUI::GetDescription(BSTR* value) { if (!value) return E_POINTER; *value = SysAllocString(L"NeLisp IME candidates"); return *value ? S_OK : E_OUTOFMEMORY; }
HRESULT CandidateUI::GetGUID(GUID* guid) { if (!guid) return E_POINTER; *guid = kCandidateUiGuid; return S_OK; }
HRESULT CandidateUI::Show(BOOL show) { shown_ = show; return S_OK; }
HRESULT CandidateUI::IsShown(BOOL* show) { if (!show) return E_POINTER; *show = shown_; return S_OK; }
HRESULT CandidateUI::GetUpdatedFlags(DWORD* flags) { if (!flags) return E_POINTER; *flags = updated_flags_; updated_flags_ = 0; return S_OK; }
HRESULT CandidateUI::GetDocumentMgr(ITfDocumentMgr** value) { if (!value) return E_POINTER; *value = document_; if (*value) (*value)->AddRef(); return S_OK; }
HRESULT CandidateUI::GetCount(UINT* count) { if (!count) return E_POINTER; *count = static_cast<UINT>(candidates_.size()); return S_OK; }
HRESULT CandidateUI::GetSelection(UINT* index) { if (!index) return E_POINTER; *index = selection_; return S_OK; }
HRESULT CandidateUI::GetString(UINT index, BSTR* text) { if (!text) return E_POINTER; *text = nullptr; if (index >= candidates_.size()) return E_INVALIDARG; *text = SysAllocStringLen(candidates_[index].data(), static_cast<UINT>(candidates_[index].size())); return *text ? S_OK : E_OUTOFMEMORY; }
HRESULT CandidateUI::GetPageIndex(UINT* indices, UINT size, UINT* count) { if (!count) return E_POINTER; *count = candidates_.empty() ? 0 : 1; if (*count && (!indices || size < 1)) return E_NOT_SUFFICIENT_BUFFER; if (*count) indices[0] = 0; return S_OK; }
HRESULT CandidateUI::SetPageIndex(UINT*, UINT) { return E_NOTIMPL; }
HRESULT CandidateUI::GetCurrentPage(UINT* page) { if (!page) return E_POINTER; *page = 0; return S_OK; }
HRESULT CandidateUI::SetSelection(UINT index) { return index < candidates_.size() && handler_ ? handler_->SelectCandidate(index) : E_INVALIDARG; }
HRESULT CandidateUI::Finalize() { return handler_ ? handler_->FinalizeCandidate() : E_UNEXPECTED; }
HRESULT CandidateUI::Abort() { return handler_ ? handler_->AbortCandidate() : E_UNEXPECTED; }
void CandidateUI::Update(const ddskk::EngineState& state, ITfDocumentMgr* document) {
  if (document != document_) { if (document_) document_->Release(); document_ = document; if (document_) document_->AddRef(); }
  candidates_ = state.candidates;
  selection_ = state.candidate_index < 0 ? 0 : static_cast<UINT>(state.candidate_index);
  updated_flags_ = TF_CLUIE_COUNT | TF_CLUIE_SELECTION | TF_CLUIE_STRING |
                   TF_CLUIE_PAGEINDEX | TF_CLUIE_CURRENTPAGE;
}

void CandidateUI::SetInlineCaret(const RECT* caret) {
  if (!caret || candidates_.empty()) {
    if (inline_window_) DestroyWindow(inline_window_);
    inline_window_ = nullptr; return;
  }
  // A non-activating standard control keeps all window procedures in user32;
  // no callbacks into an unloaded core can survive core replacement.
  if (!inline_window_)
    inline_window_ = CreateWindowExW(WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
        L"STATIC", L"", WS_POPUP | WS_BORDER | SS_LEFT,
        0, 0, 320, 80, nullptr, nullptr, nullptr, nullptr);
  if (!inline_window_) return;
  std::wstring label;
  for (size_t i = 0; i < candidates_.size() && i < 9; ++i) {
    label += i == selection_ ? L"▶ " : L"  ";
    label += std::to_wstring(i + 1) + L" " + candidates_[i] + L"\r\n";
  }
  SetWindowTextW(inline_window_, label.c_str());
  SetWindowPos(inline_window_, HWND_TOPMOST, caret->left, caret->bottom,
      320, static_cast<int>(std::min<size_t>(candidates_.size(), 9)) * 24 + 4,
      SWP_NOACTIVATE | SWP_SHOWWINDOW);
  wchar_t diagnostics[2]{};
  if (GetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS", diagnostics, 2)) {
    RECT actual{}; GetWindowRect(inline_window_, &actual);
    std::printf("INLINE_CANDIDATE x=%ld y=%ld height=%ld actual_x=%ld actual_y=%ld\n",
        caret->left, caret->top, caret->bottom - caret->top, actual.left, actual.top);
    std::fflush(stdout);
  }
}
