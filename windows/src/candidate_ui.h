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

#pragma once

#include "engine_protocol.h"

#include <msctf.h>

class CandidateUI;
class CandidateUIHandler {
 public:
  virtual HRESULT SelectCandidate(UINT index) = 0;
  virtual HRESULT FinalizeCandidate() = 0;
  virtual HRESULT AbortCandidate() = 0;
 protected:
  ~CandidateUIHandler() = default;
};

class CandidateUI final : public ITfCandidateListUIElementBehavior {
 public:
  explicit CandidateUI(CandidateUIHandler* handler);
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** object) override;
  ULONG STDMETHODCALLTYPE AddRef() override;
  ULONG STDMETHODCALLTYPE Release() override;
  HRESULT STDMETHODCALLTYPE GetDescription(BSTR* description) override;
  HRESULT STDMETHODCALLTYPE GetGUID(GUID* guid) override;
  HRESULT STDMETHODCALLTYPE Show(BOOL show) override;
  HRESULT STDMETHODCALLTYPE IsShown(BOOL* show) override;
  HRESULT STDMETHODCALLTYPE GetUpdatedFlags(DWORD* flags) override;
  HRESULT STDMETHODCALLTYPE GetDocumentMgr(ITfDocumentMgr** document) override;
  HRESULT STDMETHODCALLTYPE GetCount(UINT* count) override;
  HRESULT STDMETHODCALLTYPE GetSelection(UINT* index) override;
  HRESULT STDMETHODCALLTYPE GetString(UINT index, BSTR* text) override;
  HRESULT STDMETHODCALLTYPE GetPageIndex(UINT* indices, UINT size,
                                         UINT* page_count) override;
  HRESULT STDMETHODCALLTYPE SetPageIndex(UINT* indices, UINT page_count) override;
  HRESULT STDMETHODCALLTYPE GetCurrentPage(UINT* page) override;
  HRESULT STDMETHODCALLTYPE SetSelection(UINT index) override;
  HRESULT STDMETHODCALLTYPE Finalize() override;
  HRESULT STDMETHODCALLTYPE Abort() override;
  void Update(const ddskk::EngineState& state, ITfDocumentMgr* document);

 private:
  ~CandidateUI();
  LONG ref_count_ = 1;
  BOOL shown_ = TRUE;
  DWORD updated_flags_ = TF_CLUIE_COUNT | TF_CLUIE_SELECTION |
                         TF_CLUIE_STRING | TF_CLUIE_PAGEINDEX |
                         TF_CLUIE_CURRENTPAGE;
  UINT selection_ = 0;
  std::vector<std::wstring> candidates_;
  ITfDocumentMgr* document_ = nullptr;
  CandidateUIHandler* handler_;
};
