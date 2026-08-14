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

#include <cassert>
#include <cstdlib>
#include <oleauto.h>

#ifdef NDEBUG
#undef assert
#define assert(condition) ((condition) ? static_cast<void>(0) : std::abort())
#endif

class Handler final : public CandidateUIHandler {
 public:
  HRESULT SelectCandidate(UINT index) override { selected = index; return S_OK; }
  HRESULT FinalizeCandidate() override { finalized = true; return S_OK; }
  HRESULT AbortCandidate() override { aborted = true; return S_OK; }
  UINT selected = 99;
  bool finalized = false;
  bool aborted = false;
};

int main() {
  Handler handler;
  auto* ui = new CandidateUI(&handler);
  ddskk::EngineState state;
  state.candidate_index = 1;
  state.candidates = {L"仮名", L"かな"};
  ui->Update(state, nullptr);
  UINT count = 0, selection = 0, pages = 0, page_index = 99;
  assert(SUCCEEDED(ui->GetCount(&count)) && count == 2);
  assert(SUCCEEDED(ui->GetSelection(&selection)) && selection == 1);
  BSTR value = nullptr;
  assert(SUCCEEDED(ui->GetString(0, &value)) &&
         std::wstring(value, SysStringLen(value)) == L"仮名");
  SysFreeString(value);
  assert(SUCCEEDED(ui->GetPageIndex(&page_index, 1, &pages)) &&
         pages == 1 && page_index == 0);
  assert(SUCCEEDED(ui->SetSelection(0)) && handler.selected == 0);
  assert(SUCCEEDED(ui->Finalize()) && handler.finalized);
  assert(SUCCEEDED(ui->Abort()) && handler.aborted);
  ui->Release();
}
