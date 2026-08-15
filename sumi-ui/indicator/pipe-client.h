/* pipe-client.h -- named-pipe client shared by the indicator pill and the
 * settings window's "engine restart" button.
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
 * Split out of Phase 2's main.c in Phase 3 so the settings window (which
 * needs to send a one-off "SHUTDOWN\n" for its engine-restart button) can
 * reuse the exact same overlapped-I/O transaction code the indicator pill
 * already uses for STATUS polling and menu-driven mode switches, rather
 * than duplicating it. No GTK dependency -- only <windows.h> and glib's
 * `gboolean' (already a dependency of every caller; avoids reinventing a
 * bool typedef).
 */

#pragma once

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <glib.h>

#include <stddef.h>

typedef struct {
  HANDLE handle;
  wchar_t name[512];
  unsigned backoff_step_ticks;   /* 0 = not backed off */
  unsigned backoff_ticks_left;
} PipeClient;

/* Resolves the pipe name from DDSKK_PIPE_NAME (falling back to
 * \\.\pipe\ddskk-ime-v1) and zeroes the backoff state. Does not connect. */
void pipe_client_init(PipeClient *pc);

/* Closes the handle, if open, and marks the client disconnected. */
void pipe_client_disconnect(PipeClient *pc);

/* TRUE if a connect attempt should be skipped this tick because a
 * previous failure's backoff has not yet elapsed. Always decrements the
 * countdown so it eventually reaches 0 and the next tick retries. */
gboolean pipe_client_in_backoff(PipeClient *pc);

/* One write-then-read transaction, bounded by a short timeout in each
 * direction (overlapped I/O + WaitForSingleObject, mirroring
 * windows/src/engine_client.cpp's own transaction shape -- see pipe-
 * client.c for the full rationale). REQUEST must include its trailing
 * "\n". Returns the reply in RESPONSE (bounded, NUL-terminated) and TRUE
 * on success; on any failure this disconnects and starts the reconnect
 * backoff automatically. */
gboolean pipe_client_transact(PipeClient *pc, const char *request,
                              char *response, size_t response_cap);
