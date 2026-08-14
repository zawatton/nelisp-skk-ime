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

#include "display_attribute.h"
#include "guids.h"

#include <new>
#include <oleauto.h>

DisplayAttributeInfo::DisplayAttributeInfo(REFGUID guid,
    const wchar_t* description, const TF_DISPLAYATTRIBUTE& value)
    : guid_(guid), description_(description), default_(value), value_(value) {}
HRESULT DisplayAttributeInfo::QueryInterface(REFIID iid, void** object) {
  if (!object) return E_POINTER; *object = nullptr;
  if (iid != IID_IUnknown && iid != IID_ITfDisplayAttributeInfo) return E_NOINTERFACE;
  *object = static_cast<ITfDisplayAttributeInfo*>(this); AddRef(); return S_OK;
}
ULONG DisplayAttributeInfo::AddRef() { return InterlockedIncrement(&ref_count_); }
ULONG DisplayAttributeInfo::Release() { const ULONG n=InterlockedDecrement(&ref_count_); if(!n) delete this; return n; }
HRESULT DisplayAttributeInfo::GetGUID(GUID* guid) { if(!guid) return E_POINTER; *guid=guid_; return S_OK; }
HRESULT DisplayAttributeInfo::GetDescription(BSTR* text) { if(!text) return E_POINTER; *text=SysAllocString(description_); return *text?S_OK:E_OUTOFMEMORY; }
HRESULT DisplayAttributeInfo::GetAttributeInfo(TF_DISPLAYATTRIBUTE* value) { if(!value) return E_POINTER; *value=value_; return S_OK; }
HRESULT DisplayAttributeInfo::SetAttributeInfo(const TF_DISPLAYATTRIBUTE* value) { if(!value) return E_POINTER; value_=*value; return S_OK; }
HRESULT DisplayAttributeInfo::Reset() { value_=default_; return S_OK; }

DisplayAttributeInfo* CreateDisplayAttributeInfo(REFGUID guid) {
  TF_DISPLAYATTRIBUTE value{};
  value.crText.type = TF_CT_NONE; value.crBk.type = TF_CT_NONE;
  value.crLine.type = TF_CT_COLORREF; value.crLine.cr = RGB(70, 110, 210);
  value.lsStyle = guid == GUID_DdskkCandidateAttribute ? TF_LS_SQUIGGLE : TF_LS_SOLID;
  value.fBoldLine = guid == GUID_DdskkCandidateAttribute;
  value.bAttr = guid == GUID_DdskkCandidateAttribute ? TF_ATTR_TARGET_CONVERTED : TF_ATTR_INPUT;
  const wchar_t* description = guid == GUID_DdskkCandidateAttribute ? L"DDSKK candidate" : L"DDSKK preedit";
  return new (std::nothrow) DisplayAttributeInfo(guid, description, value);
}
