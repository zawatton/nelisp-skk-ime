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

#include <cassert>
#include <cstdlib>

#ifdef NDEBUG
#undef assert
#define assert(condition) ((condition) ? static_cast<void>(0) : std::abort())
#endif

int main() {
  auto* preedit = CreateDisplayAttributeInfo(GUID_DdskkPreeditAttribute);
  auto* candidate = CreateDisplayAttributeInfo(GUID_DdskkCandidateAttribute);
  assert(preedit && candidate);
  TF_DISPLAYATTRIBUTE value{};
  assert(SUCCEEDED(preedit->GetAttributeInfo(&value)));
  assert(value.lsStyle == TF_LS_SOLID && value.bAttr == TF_ATTR_INPUT);
  assert(SUCCEEDED(candidate->GetAttributeInfo(&value)));
  assert(value.lsStyle == TF_LS_SQUIGGLE && value.fBoldLine &&
         value.bAttr == TF_ATTR_TARGET_CONVERTED);
  preedit->Release();
  candidate->Release();
}
