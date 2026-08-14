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

#include <msctf.h>

class DisplayAttributeInfo final : public ITfDisplayAttributeInfo {
 public:
  DisplayAttributeInfo(REFGUID guid, const wchar_t* description,
                       const TF_DISPLAYATTRIBUTE& value);
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** object) override;
  ULONG STDMETHODCALLTYPE AddRef() override;
  ULONG STDMETHODCALLTYPE Release() override;
  HRESULT STDMETHODCALLTYPE GetGUID(GUID* guid) override;
  HRESULT STDMETHODCALLTYPE GetDescription(BSTR* description) override;
  HRESULT STDMETHODCALLTYPE GetAttributeInfo(TF_DISPLAYATTRIBUTE* value) override;
  HRESULT STDMETHODCALLTYPE SetAttributeInfo(const TF_DISPLAYATTRIBUTE* value) override;
  HRESULT STDMETHODCALLTYPE Reset() override;
 private:
  ~DisplayAttributeInfo() = default;
  LONG ref_count_ = 1;
  GUID guid_;
  const wchar_t* description_;
  TF_DISPLAYATTRIBUTE default_;
  TF_DISPLAYATTRIBUTE value_;
};

DisplayAttributeInfo* CreateDisplayAttributeInfo(REFGUID guid);
