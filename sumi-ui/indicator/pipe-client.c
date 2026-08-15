/* pipe-client.c -- see pipe-client.h.
 *
 * Copyright (C) 2026 nelisp-skk-ime contributors
 *
 * This program is free software: you can redistribute it and/or
 * modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, either version 3 of
 * the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be
 * useful, but WITHOUT ANY WARRANTY; without even the implied
 * warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 * PURPOSE.  See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * Mirrors windows/src/engine_client.cpp's overlapped write-then-read
 * transaction shape (same reasons: plain blocking ReadFile/WriteFile
 * ignore any timeout, so overlapped I/O + a bounded WaitForSingleObject
 * is the only way a hung host doesn't freeze the caller) but trimmed to
 * what this app needs: STATUS polling, the two-step CONTROL CANCEL [+
 * KEY n] mode switch, and the settings window's one-off SHUTDOWN. Task
 * brief step 2 asks for this over CreateFileW + SetNamedPipeHandleState
 * directly (Windows-specific host-side code, "which is fine in the glue
 * layer -- the same place GTK signal handlers live").
 */

#include "pipe-client.h"

#include <string.h>

#define SKKUI_DEFAULT_PIPE_NAME L"\\\\.\\pipe\\ddskk-ime-v1"
#define SKKUI_TRANSACT_TIMEOUT_MS 300
/* Reconnect backoff, in poll-interval ticks: 1 tick after the first
 * failure, doubling up to a cap of 8 ticks so a host that is merely slow
 * to come up is retried quickly while a host that is genuinely gone does
 * not spin the pipe open/close cycle needlessly. "Ticks" are whatever
 * unit the caller's own poll cadence uses (main.c's on_poll_tick, at
 * either 500 ms or the 2 s ModeIndicator=0 cadence -- see main.c). */
#define SKKUI_BACKOFF_CAP_TICKS 8

void pipe_client_init(PipeClient *pc) {
  pc->handle = INVALID_HANDLE_VALUE;
  wchar_t override[512];
  const DWORD n = GetEnvironmentVariableW(L"DDSKK_PIPE_NAME", override, 512);
  if (n > 0 && n < 512) {
    wcsncpy(pc->name, override, 511);
    pc->name[511] = L'\0';
  } else {
    wcsncpy(pc->name, SKKUI_DEFAULT_PIPE_NAME, 511);
    pc->name[511] = L'\0';
  }
  pc->backoff_step_ticks = 0;
  pc->backoff_ticks_left = 0;
}

void pipe_client_disconnect(PipeClient *pc) {
  if (pc->handle != INVALID_HANDLE_VALUE) {
    CloseHandle(pc->handle);
    pc->handle = INVALID_HANDLE_VALUE;
  }
}

/* Registers a failure and (re)starts the backoff countdown. Called
 * whenever a connect or transact attempt fails; on success the caller
 * clears backoff_step_ticks back to 0 directly. */
static void pipe_client_note_failure(PipeClient *pc) {
  pipe_client_disconnect(pc);
  pc->backoff_step_ticks =
      pc->backoff_step_ticks == 0 ? 1 : pc->backoff_step_ticks * 2;
  if (pc->backoff_step_ticks > SKKUI_BACKOFF_CAP_TICKS)
    pc->backoff_step_ticks = SKKUI_BACKOFF_CAP_TICKS;
  pc->backoff_ticks_left = pc->backoff_step_ticks;
}

gboolean pipe_client_in_backoff(PipeClient *pc) {
  if (pc->backoff_ticks_left == 0) return FALSE;
  pc->backoff_ticks_left--;
  return TRUE;
}

static gboolean pipe_client_connect(PipeClient *pc) {
  if (pc->handle != INVALID_HANDLE_VALUE) return TRUE;
  HANDLE h = CreateFileW(pc->name, GENERIC_READ | GENERIC_WRITE, 0, NULL,
                         OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OVERLAPPED,
                         NULL);
  if (h == INVALID_HANDLE_VALUE) return FALSE;
  DWORD mode = PIPE_READMODE_MESSAGE;
  if (!SetNamedPipeHandleState(h, &mode, NULL, NULL)) {
    CloseHandle(h);
    return FALSE;
  }
  pc->handle = h;
  return TRUE;
}

gboolean pipe_client_transact(PipeClient *pc, const char *request,
                              char *response, size_t response_cap) {
  if (!pipe_client_connect(pc)) {
    pipe_client_note_failure(pc);
    return FALSE;
  }

  OVERLAPPED ov;
  memset(&ov, 0, sizeof(ov));
  ov.hEvent = CreateEventW(NULL, TRUE, FALSE, NULL);
  if (ov.hEvent == NULL) {
    pipe_client_note_failure(pc);
    return FALSE;
  }

  const DWORD req_len = (DWORD)strlen(request);
  DWORD written = 0;
  gboolean ok = TRUE;
  if (!WriteFile(pc->handle, request, req_len, &written, &ov) &&
      GetLastError() != ERROR_IO_PENDING) {
    ok = FALSE;
  } else if (WaitForSingleObject(ov.hEvent, SKKUI_TRANSACT_TIMEOUT_MS) != WAIT_OBJECT_0 ||
             !GetOverlappedResult(pc->handle, &ov, &written, FALSE) ||
             written != req_len) {
    CancelIoEx(pc->handle, &ov);
    DWORD ignored = 0;
    GetOverlappedResult(pc->handle, &ov, &ignored, TRUE);
    ok = FALSE;
  }

  DWORD read = 0;
  if (ok) {
    ResetEvent(ov.hEvent);
    if (!ReadFile(pc->handle, response, (DWORD)(response_cap - 1), &read, &ov) &&
        GetLastError() != ERROR_IO_PENDING) {
      ok = FALSE;
    } else if (WaitForSingleObject(ov.hEvent, SKKUI_TRANSACT_TIMEOUT_MS) != WAIT_OBJECT_0 ||
               !GetOverlappedResult(pc->handle, &ov, &read, FALSE)) {
      CancelIoEx(pc->handle, &ov);
      DWORD ignored = 0;
      GetOverlappedResult(pc->handle, &ov, &ignored, TRUE);
      ok = FALSE;
    }
  }
  CloseHandle(ov.hEvent);

  if (!ok) {
    pipe_client_note_failure(pc);
    return FALSE;
  }
  response[read] = '\0';
  pc->backoff_step_ticks = 0;
  return TRUE;
}
