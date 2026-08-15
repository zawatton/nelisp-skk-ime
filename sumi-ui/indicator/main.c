/* main.c -- sumi-skk-ui: CorvusSKK-style mode indicator for nelisp-skk-ime.
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
 * Hand-authored GTK4/Cairo/Win32 glue for the sumi-indicator-settings.md
 * Phase 2 "indicator MVP" (see docs/design/sumi-indicator-settings.md).
 * This is the "acceptable MVP simplification" the design brief itself
 * offers: a real GTK4 C program, built with the same MSYS2 toolchain
 * dev/sumi and dev/nelisp-sumi use, rather than authoring the whole
 * window in the frame-v1 restricted dialect. sumi-ui/README.md explains
 * why that full-protocol path was judged disproportionate for a ~120x40
 * status pill. All *decision logic* -- mode-to-color, mode-to-label,
 * whether/what the mode-switch menu sends -- still lives in the Sumi/
 * NeLisp AOT pattern: indicator/mode-logic.el compiles with the same
 * `nelisp-aot-compile-to-object' (:format 'coff) build-live.el and
 * build.el use, and links directly into this executable (see build.el).
 * This file owns only I/O (the named-pipe protocol, GTK/Cairo/Pango
 * rendering primitives) -- never a mode/color/label decision.
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <gtk/gtk.h>
#include <gdk/win32/gdkwin32.h>
#include <pango/pangocairo.h>

#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

/* ------------------------------------------------------------------ */
/* Decision logic, compiled from indicator/mode-logic.el by build.el's
 * `nelisp-aot-compile-to-object' call and linked in as mode-logic.o.
 * Every symbol below is a plain SysV-shaped... no -- Win64-ABI-shaped
 * (see nelisp-aot-compiler.el: COFF/x86_64 output binds --abi to
 * 'win64) C function taking/returning int64_t, exactly like any other
 * extern C function; there is nothing NeLisp-specific about the call
 * site here. See mode-logic.el's own header comment for the full
 * MODE/PREVIOUS_BASE contract these implement. */
extern int64_t skkui_base_color(int64_t mode);
extern int64_t skkui_base_label(int64_t mode);
extern int64_t skkui_color_for(int64_t mode, int64_t previous_base);
extern int64_t skkui_label_for(int64_t mode, int64_t previous_base);
extern int64_t skkui_composing_marker(int64_t mode);
extern int64_t skkui_menu_visible(int64_t mode);
extern int64_t skkui_menu_item_keycode(int64_t item);

/* ------------------------------------------------------------------ */
/* Mode encoding shared with mode-logic.el's header comment. */
enum {
  MODE_HIRAGANA = 0,
  MODE_KATAKANA = 1,
  MODE_WIDE_LATIN = 2,
  MODE_LATIN = 3,
  MODE_PREEDIT = 4,
  MODE_CANDIDATE = 5,
  MODE_ABBREV = 6,
  MODE_UNREACHABLE = 7,
};

static int64_t mode_from_token(const char *tok) {
  if (strcmp(tok, "hiragana") == 0) return MODE_HIRAGANA;
  if (strcmp(tok, "katakana") == 0) return MODE_KATAKANA;
  if (strcmp(tok, "wide-latin") == 0) return MODE_WIDE_LATIN;
  if (strcmp(tok, "latin") == 0) return MODE_LATIN;
  if (strcmp(tok, "preedit") == 0) return MODE_PREEDIT;
  if (strcmp(tok, "candidate") == 0) return MODE_CANDIDATE;
  if (strcmp(tok, "abbrev") == 0) return MODE_ABBREV;
  return MODE_UNREACHABLE;
}

static int is_base_mode(int64_t m) {
  return m != MODE_PREEDIT && m != MODE_CANDIDATE && m != MODE_UNREACHABLE;
}

/* Names used only for the stdout transition log (Phase 2 verification
 * harness reads these; see sumi-ui/verify/verify.ps1). Independent of
 * the glyphs drawn on screen (draw_indicator() below), which come from
 * skkui_*_label()/UTF-8 glyph tables so the NeLisp module stays the
 * single source of truth for what the user sees. */
static const char *mode_log_name(int64_t m) {
  switch (m) {
    case MODE_HIRAGANA: return "hiragana";
    case MODE_KATAKANA: return "katakana";
    case MODE_WIDE_LATIN: return "wide-latin";
    case MODE_LATIN: return "latin";
    case MODE_PREEDIT: return "preedit";
    case MODE_CANDIDATE: return "candidate";
    case MODE_ABBREV: return "abbrev";
    default: return "unreachable";
  }
}

/* UTF-8 glyphs for the label codes skkui_base_label()/skkui_label_for()
 * return (0..5; see mode-logic.el's header comment). Kept here, not in
 * NeLisp, because these are literal string constants and object-mode
 * AOT compilation rejects any defun body that references one (see
 * nelisp-aot-compiler.el's `:object-mode-no-strings' gate) -- exactly
 * the split the task brief calls for: NeLisp decides *which* label
 * (an integer), main.c owns the literal glyph (a rendering primitive). */
static const char *label_glyph(int64_t label_code) {
  switch (label_code) {
    case 0: return "\xe3\x81\x82";             /* U+3042 あ */
    case 1: return "\xe3\x82\xa2";             /* U+30A2 ア */
    case 2: return "\xef\xbc\xa1";             /* U+FF21 Ａ (fullwidth A) */
    case 3: return "SKK";
    case 5: return "Ab";
    default: return "\xe2\x80\x95\xe2\x80\x95"; /* U+2015 U+2015 ―― */
  }
}

static const char *marker_glyph(int64_t marker_code) {
  switch (marker_code) {
    case 1: return "\xe2\x96\xbd"; /* U+25BD ▽ preedit */
    case 2: return "\xe2\x96\xbc"; /* U+25BC ▼ candidate */
    default: return "";
  }
}

/* ------------------------------------------------------------------ */
/* Named-pipe client. Mirrors windows/src/engine_client.cpp's overlapped
 * write-then-read transaction shape (same reasons: plain blocking
 * ReadFile/WriteFile ignore any timeout, so overlapped I/O + a bounded
 * WaitForSingleObject is the only way a hung host doesn't freeze this
 * process) but trimmed to what the indicator actually needs: STATUS
 * polling and the two-step CONTROL CANCEL [+ KEY n] mode switch. Task
 * brief step 2 asks for this over CreateFileW + SetNamedPipeHandleState
 * directly (Windows-specific host-side code, "which is fine in the glue
 * layer -- the same place GTK signal handlers live"). */

#define SKKUI_DEFAULT_PIPE_NAME L"\\\\.\\pipe\\ddskk-ime-v1"
#define SKKUI_TRANSACT_TIMEOUT_MS 300
#define SKKUI_POLL_INTERVAL_MS 500
/* Reconnect backoff, in poll-interval ticks: 1 tick (500 ms) after the
 * first failure, doubling up to a cap of 8 ticks (4 s) so a host that
 * is merely slow to come up is retried quickly while a host that is
 * genuinely gone does not spin the pipe open/close cycle needlessly. */
#define SKKUI_BACKOFF_CAP_TICKS 8

typedef struct {
  HANDLE handle;
  wchar_t name[512];
  unsigned backoff_step_ticks;   /* 0 = not backed off */
  unsigned backoff_ticks_left;
} PipeClient;

static void pipe_client_init(PipeClient *pc) {
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

static void pipe_client_disconnect(PipeClient *pc) {
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

/* Returns TRUE if a connect attempt should be skipped this tick because
 * a previous failure's backoff has not yet elapsed. Always decrements
 * the countdown so it eventually reaches 0 and the next tick retries. */
static gboolean pipe_client_in_backoff(PipeClient *pc) {
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

/* One write-then-read transaction, bounded by SKKUI_TRANSACT_TIMEOUT_MS
 * in each direction. REQUEST must include its trailing "\n" (matching
 * windows/src/engine_protocol.cpp's EncodeKeyRequest/EncodeControlRequest
 * convention). Returns the reply in RESPONSE (bounded, NUL-terminated)
 * and TRUE on success; on any failure this disconnects and starts the
 * caller's backoff via pipe_client_note_failure() -- callers must not
 * call that a second time themselves. */
static gboolean pipe_client_transact(PipeClient *pc, const char *request,
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

/* ------------------------------------------------------------------ */
/* App state. */

typedef struct {
  GtkWidget *window;
  GtkWidget *drawing_area;
  GtkWidget *popover;
  PipeClient pipe;
  int64_t mode;           /* last mode this process observed, incl. 7 */
  int64_t previous_base;  /* last *base* mode (never 4/5/7) */
  gboolean have_state;     /* FALSE until the first poll completes */
  PangoFontDescription *label_font;
} App;

static void app_log_transition(App *app, int64_t new_mode) {
  if (app->have_state && new_mode == app->mode) return;
  printf("MODE %s\n", mode_log_name(new_mode));
  fflush(stdout);
}

/* Applies a freshly observed MODE (from a STATUS poll or a menu-driven
 * CONTROL/KEY reply), updating previous_base per mode-logic.el's
 * contract (only base modes 0/1/2/3/6 become the new previous_base;
 * see mode-logic.el's header comment) and logging a transition line iff
 * the mode actually changed since the last observation. */
static void app_apply_mode(App *app, int64_t new_mode) {
  app_log_transition(app, new_mode);
  if (is_base_mode(new_mode)) app->previous_base = new_mode;
  app->mode = new_mode;
  app->have_state = TRUE;
  if (app->drawing_area) gtk_widget_queue_draw(app->drawing_area);
}

/* Parses a "STATE <mode> ..." reply (windows/src/engine_protocol.cpp's
 * ParseStateResponse documents the full 8-field grammar; the indicator
 * only needs field 1). Any other reply (an "ERR ..." token, or garbage)
 * maps to MODE_UNREACHABLE -- the task brief's "pipe unreachable or ERR"
 * bucket makes no distinction between the two from the display's point
 * of view. */
static int64_t mode_from_state_reply(const char *reply) {
  if (strncmp(reply, "STATE ", 6) != 0) return MODE_UNREACHABLE;
  const char *field = reply + 6;
  const char *end = strchr(field, ' ');
  char token[64];
  size_t len = end ? (size_t)(end - field) : strlen(field);
  if (len >= sizeof(token)) len = sizeof(token) - 1;
  memcpy(token, field, len);
  token[len] = '\0';
  return mode_from_token(token);
}

/* ------------------------------------------------------------------ */
/* Rendering. */

static void set_source_from_rgb24(cairo_t *cr, int64_t rgb) {
  const double r = ((rgb >> 16) & 0xff) / 255.0;
  const double g = ((rgb >> 8) & 0xff) / 255.0;
  const double b = (rgb & 0xff) / 255.0;
  cairo_set_source_rgb(cr, r, g, b);
}

static void draw_centered_pango(cairo_t *cr, PangoFontDescription *desc,
                                const char *utf8, int width, int height,
                                double r, double g, double b) {
  if (!utf8 || utf8[0] == '\0') return;
  PangoLayout *layout = pango_cairo_create_layout(cr);
  pango_layout_set_font_description(layout, desc);
  pango_layout_set_text(layout, utf8, -1);
  int text_w = 0, text_h = 0;
  pango_layout_get_pixel_size(layout, &text_w, &text_h);
  cairo_set_source_rgb(cr, r, g, b);
  cairo_move_to(cr, (width - text_w) / 2.0, (height - text_h) / 2.0);
  pango_cairo_show_layout(cr, layout);
  g_object_unref(layout);
}

static void draw_indicator(GtkDrawingArea *area, cairo_t *cr, int width,
                           int height, gpointer user_data) {
  (void)area;
  App *app = (App *)user_data;
  const int64_t mode = app->have_state ? app->mode : MODE_UNREACHABLE;
  const int64_t prev = app->previous_base;
  const int64_t rgb = skkui_color_for(mode, prev);
  const int64_t label_code = skkui_label_for(mode, prev);
  const int64_t marker_code = skkui_composing_marker(mode);

  set_source_from_rgb24(cr, rgb);
  cairo_paint(cr);

  /* Text color: near-white on every one of this app's backgrounds (all
   * spec'd colors -- red/green/purple/blue/gray -- are dark/mid-
   * saturation), matching mode_indicator.cpp's own default for the
   * same palette family. No luminance flip is needed here (unlike
   * mode_indicator.cpp, which must also handle arbitrary user-chosen
   * override colors from the registry -- out of scope until Phase 3). */
  const char *glyph = label_glyph(label_code);
  const char *marker = marker_glyph(marker_code);

  char combined[16];
  snprintf(combined, sizeof(combined), "%s%s", glyph, marker);
  draw_centered_pango(cr, app->label_font, combined, width, height, 1.0, 1.0, 1.0);
}

/* ------------------------------------------------------------------ */
/* Mode-switch menu. */

static void send_control_cancel_and_key(App *app, int64_t item) {
  char response[8192];
  if (!pipe_client_transact(&app->pipe, "CONTROL CANCEL\n", response, sizeof(response)))
    return;
  app_apply_mode(app, mode_from_state_reply(response));

  const int64_t keycode = skkui_menu_item_keycode(item);
  if (keycode <= 0) return; /* 0 = CONTROL CANCEL alone was enough; -1 = invalid */

  char request[32];
  snprintf(request, sizeof(request), "KEY %lld\n", (long long)keycode);
  if (!pipe_client_transact(&app->pipe, request, response, sizeof(response))) return;
  app_apply_mode(app, mode_from_state_reply(response));
}

static void on_menu_item_clicked(GtkButton *button, gpointer user_data) {
  App *app = (App *)user_data;
  const int64_t item = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(button), "skkui-item"));
  gtk_popover_popdown(GTK_POPOVER(app->popover));
  send_control_cancel_and_key(app, item);
}

static GtkWidget *make_menu_button(App *app, int64_t item, const char *label) {
  GtkWidget *button = gtk_button_new_with_label(label);
  gtk_widget_set_halign(button, GTK_ALIGN_FILL);
  g_object_set_data(G_OBJECT(button), "skkui-item", GINT_TO_POINTER((int)item));
  g_signal_connect(button, "clicked", G_CALLBACK(on_menu_item_clicked), app);
  return button;
}

static void ensure_popover(App *app) {
  if (app->popover) return;
  app->popover = gtk_popover_new();
  gtk_widget_set_parent(app->popover, app->drawing_area);
  GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
  /* Order matches design doc's "Mode switching from the indicator"
   * table and mode-logic.el's skkui_menu_item_keycode item indices. */
  gtk_box_append(GTK_BOX(box), make_menu_button(app, 0, "\xe3\x81\x8b\xe3\x81\xaa"));         /* かな */
  gtk_box_append(GTK_BOX(box), make_menu_button(app, 1, "\xe3\x82\xab\xe3\x82\xbf\xe3\x82\xab\xe3\x83\x8a")); /* カタカナ */
  gtk_box_append(GTK_BOX(box), make_menu_button(app, 2, "\xe5\x85\xa8\xe8\x8b\xb1"));           /* 全英 */
  gtk_box_append(GTK_BOX(box), make_menu_button(app, 3, "SKK"));
  gtk_popover_set_child(GTK_POPOVER(app->popover), box);
}

/* ------------------------------------------------------------------ */
/* Click-to-open-menu / suppressed-while-composing (task brief step 4). */

static void on_click_released(GtkGestureClick *gesture, int n_press, double x,
                              double y, gpointer user_data) {
  (void)x; (void)y;
  if (n_press != 1) return;
  App *app = (App *)user_data;
  gtk_gesture_set_state(GTK_GESTURE(gesture), GTK_EVENT_SEQUENCE_CLAIMED);
  const int64_t mode = app->have_state ? app->mode : MODE_UNREACHABLE;
  if (!skkui_menu_visible(mode)) return; /* composing: menu is a no-op */
  ensure_popover(app);
  if (gtk_widget_get_visible(app->popover))
    gtk_popover_popdown(GTK_POPOVER(app->popover));
  else
    gtk_popover_popup(GTK_POPOVER(app->popover));
}

/* ------------------------------------------------------------------ */
/* Polling timer. */

static gboolean on_poll_tick(gpointer user_data) {
  App *app = (App *)user_data;
  if (pipe_client_in_backoff(&app->pipe)) {
    if (!app->have_state || app->mode != MODE_UNREACHABLE)
      app_apply_mode(app, MODE_UNREACHABLE);
    return G_SOURCE_CONTINUE;
  }
  char response[8192];
  if (!pipe_client_transact(&app->pipe, "STATUS\n", response, sizeof(response))) {
    app_apply_mode(app, MODE_UNREACHABLE);
    return G_SOURCE_CONTINUE;
  }
  app_apply_mode(app, mode_from_state_reply(response));
  return G_SOURCE_CONTINUE;
}

/* ------------------------------------------------------------------ */
/* Window chrome: always-on-top (GTK4 dropped the portable
 * gtk_window_set_keep_above() API; SetWindowPos(HWND_TOPMOST) on the
 * GDK win32 surface's native HWND is the Windows-specific replacement,
 * the same kind of "host-side glue" the task brief already sanctions
 * for the named-pipe I/O) and draggable-by-drag-anywhere (GtkWindowHandle,
 * GTK4's own widget for exactly this: consumes a press-drag as an
 * interactive move, passes an undragged click through to descendants --
 * here, the GtkGestureClick on drawing_area that opens the menu). */

static void apply_always_on_top(GtkWidget *window) {
  GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(window));
  if (surface == NULL || !GDK_IS_WIN32_SURFACE(surface)) return;
  HWND hwnd = gdk_win32_surface_get_handle(surface);
  if (hwnd == NULL) return;
  SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
}

static void on_realize(GtkWidget *window, gpointer user_data) {
  (void)user_data;
  apply_always_on_top(window);
}

/* ------------------------------------------------------------------ */

static void on_activate(GtkApplication *gtk_app, gpointer user_data) {
  App *app = (App *)user_data;

  app->window = gtk_application_window_new(gtk_app);
  gtk_window_set_title(GTK_WINDOW(app->window), "SKK");
  gtk_window_set_default_size(GTK_WINDOW(app->window), 120, 40);
  gtk_window_set_resizable(GTK_WINDOW(app->window), FALSE);
  gtk_window_set_decorated(GTK_WINDOW(app->window), FALSE);

  app->drawing_area = gtk_drawing_area_new();
  gtk_drawing_area_set_content_width(GTK_DRAWING_AREA(app->drawing_area), 120);
  gtk_drawing_area_set_content_height(GTK_DRAWING_AREA(app->drawing_area), 40);
  gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(app->drawing_area), draw_indicator,
                                 app, NULL);

  GtkGesture *click = gtk_gesture_click_new();
  gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(click), GDK_BUTTON_PRIMARY);
  g_signal_connect(click, "released", G_CALLBACK(on_click_released), app);
  gtk_widget_add_controller(app->drawing_area, GTK_EVENT_CONTROLLER(click));

  GtkWidget *handle = gtk_window_handle_new();
  gtk_window_handle_set_child(GTK_WINDOW_HANDLE(handle), app->drawing_area);
  gtk_window_set_child(GTK_WINDOW(app->window), handle);

  g_signal_connect(app->window, "realize", G_CALLBACK(on_realize), NULL);

  gtk_window_present(GTK_WINDOW(app->window));

  g_timeout_add(SKKUI_POLL_INTERVAL_MS, on_poll_tick, app);
}

int main(int argc, char **argv) {
  App app;
  memset(&app, 0, sizeof(app));
  pipe_client_init(&app.pipe);
  app.mode = MODE_UNREACHABLE;
  app.previous_base = MODE_HIRAGANA;
  app.have_state = FALSE;
  app.label_font = pango_font_description_from_string("Sans 14");

  GtkApplication *gtk_app =
      gtk_application_new("dev.nelisp-skk-ime.sumi-ui", G_APPLICATION_DEFAULT_FLAGS);
  g_signal_connect(gtk_app, "activate", G_CALLBACK(on_activate), &app);
  const int status = g_application_run(G_APPLICATION(gtk_app), argc, argv);
  g_object_unref(gtk_app);
  pango_font_description_free(app.label_font);
  pipe_client_disconnect(&app.pipe);
  return status;
}
