// GPL-3.0-or-later
#pragma once
#include <windows.h>
#include <string>
#include <cstddef>
// Sumi v1 stays byte-for-byte compatible, including its section size.
// Ownership lives in a separate host/core mapping, outside the core ABI.
struct NativeStateMirror {
  volatile LONG sequence;
  char line[8192];
};
struct NativeStateOwner {
  volatile LONG local_owner;
  volatile LONG requested_owner; // random per-Store cookie; zero means provider
};
static_assert(offsetof(NativeStateMirror, line) == 4 && sizeof(NativeStateMirror) == 8196);
inline std::wstring NativeStateMirrorName(const std::wstring& pipe) {
  if (pipe == L"\\\\.\\pipe\\ddskk-ime-v1") return L"Local\\ddskk-ime-state-v1";
  auto suffix = pipe;
  for (auto& c : suffix) if (c == L'\\' || c == L'/') c = L'_';
  return L"Local\\ddskk-ime-state-v1-" + suffix;
}
// A zero-time kernel-mutex acquisition never waits for a stalled writer.
// Abandoned ownership is recoverable, unlike an odd seqlock left by a crash.
inline bool TryOwnStateMirror(NativeStateMirror* view, LONG* sequence, HANDLE writer) {
  if (!writer) return false;
  const DWORD acquired = WaitForSingleObject(writer, 0);
  if (acquired != WAIT_OBJECT_0 && acquired != WAIT_ABANDONED) return false;
  *sequence = view->sequence;
  // Windows mutexes are recursive; reject an active same-thread writer too.
  if (acquired == WAIT_OBJECT_0 && (*sequence & 1)) { ReleaseMutex(writer); return false; }
  if (*sequence & 1) *sequence = static_cast<LONG>(static_cast<ULONG>(*sequence) + 1);
  InterlockedExchange(&view->sequence, static_cast<LONG>(static_cast<ULONG>(*sequence) + 1));
  return true;
}
inline void ReleaseStateMirror(NativeStateMirror* view, LONG sequence, HANDLE writer) {
  MemoryBarrier();
  InterlockedExchange(&view->sequence, static_cast<LONG>(static_cast<ULONG>(sequence) + 2));
  ReleaseMutex(writer);
}
