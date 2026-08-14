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

#include <guiddef.h>

// Project-owned identifiers. Keep these stable after the first public release.
inline constexpr GUID CLSID_DdskkTextService =
    {0x80b44b14, 0xb866, 0x4ef4, {0xa3, 0x94, 0x4f, 0xf1, 0xd8, 0x7d, 0x51, 0x85}};
inline constexpr GUID GUID_DdskkProfile =
    {0xee0012d5, 0x8306, 0x4388, {0xb0, 0x71, 0x5c, 0x3c, 0x3e, 0x38, 0xf7, 0xce}};
inline constexpr GUID GUID_DdskkPreeditAttribute =
    {0xd20e1086, 0xbb65, 0x46c3, {0x88, 0x15, 0x44, 0x56, 0x45, 0x1b, 0xe3, 0xb4}};
inline constexpr GUID GUID_DdskkCandidateAttribute =
    {0x937f739e, 0x7bf9, 0x4860, {0x9c, 0xeb, 0x0e, 0xe3, 0xf3, 0x69, 0x16, 0xa9}};
inline constexpr GUID GUID_DdskkSettingsButton =
    {0xb38ebfd9, 0x7790, 0x45d1, {0x9b, 0x4e, 0x84, 0xe7, 0x78, 0x9f, 0x8b, 0x1c}};
