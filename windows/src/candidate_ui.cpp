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
HRESULT CandidateUI::GetPageIndex(UINT* indices, UINT size, UINT* count) {
  if (!count) return E_POINTER;
  *count = static_cast<UINT>(pages_.size());
  if (*count && (!indices || size < *count)) return E_NOT_SUFFICIENT_BUFFER;
  for (UINT i = 0; i < *count; ++i) indices[i] = pages_[i];
  return S_OK;
}
HRESULT CandidateUI::SetPageIndex(UINT* indices, UINT count) {
  if (!local_pages_) return E_NOTIMPL;
  if (!indices || !count || indices[0] != 0) return E_INVALIDARG;
  for (UINT i = 0; i < count; ++i)
    if (indices[i] >= candidates_.size() || (i && indices[i] <= indices[i-1])) return E_INVALIDARG;
  pages_.assign(indices, indices + count); updated_flags_ |= TF_CLUIE_PAGEINDEX | TF_CLUIE_CURRENTPAGE;
  return S_OK;
}
HRESULT CandidateUI::GetCurrentPage(UINT* page) {
  if (!page) return E_POINTER;
  *page = 0;
  while (*page + 1 < pages_.size() && pages_[*page + 1] <= selection_) ++*page;
  return S_OK;
}
HRESULT CandidateUI::SetSelection(UINT index) { return index < candidates_.size() && handler_ ? handler_->SelectCandidate(index) : E_INVALIDARG; }
HRESULT CandidateUI::Finalize() { return handler_ ? handler_->FinalizeCandidate() : E_UNEXPECTED; }
HRESULT CandidateUI::Abort() { return handler_ ? handler_->AbortCandidate() : E_UNEXPECTED; }
void CandidateUI::Update(const ddskk::EngineState& state, ITfDocumentMgr* document, bool local) {
  if (document != document_) { if (document_) document_->Release(); document_ = document; if (document_) document_->AddRef(); }
  local_pages_ = local;
  candidates_ = state.candidates;
  pages_.clear();
  if (!candidates_.empty()) pages_.push_back(0);
  if (local) for (UINT i = 4; i < candidates_.size(); i += 7) pages_.push_back(i);
  selection_ = state.candidate_index < 0 ? 0 : static_cast<UINT>(state.candidate_index);
  updated_flags_ = TF_CLUIE_COUNT | TF_CLUIE_SELECTION | TF_CLUIE_STRING |
                   TF_CLUIE_PAGEINDEX | TF_CLUIE_CURRENTPAGE;
}
