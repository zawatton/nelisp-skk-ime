/* main.c -- sumi-skk-ui: CorvusSKK-style mode indicator + settings window
 * for nelisp-skk-ime.
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
 * Hand-authored GTK4/Cairo/Win32 glue for docs/design/sumi-indicator-
 * settings.md's Phase 2 "indicator MVP" and Phase 3 "settings tabs".
 * This is the "acceptable MVP simplification" the Phase 2 design brief
 * offered: a real GTK4 C program, built with the same MSYS2 toolchain
 * dev/sumi and dev/nelisp-sumi use, rather than authoring the whole
 * window in the frame-v1 restricted dialect (see sumi-ui/README.md for
 * the full rationale). All *decision logic* -- mode-to-color, mode-to-
 * label, whether/what the mode-switch menu sends -- still lives in the
 * Sumi/NeLisp AOT pattern: indicator/mode-logic.el compiles with the
 * same `nelisp-aot-compile-to-object' (:format 'coff) build-live.el and
 * build.el use, and links directly into this executable (see build.el).
 * This file owns I/O and rendering primitives (the named-pipe protocol,
 * registry settings I/O via settings.c, GTK/Cairo/Pango widgets) --
 * never a mode/color/label decision; Phase 3 extends that boundary to
 * cover *which* colors are available (read from the registry via
 * settings.c) without moving the *choice* among them out of NeLisp --
 * see mode-logic.el's header comment for the COLORS_PTR contract.
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <gtk/gtk.h>
#include <gdk/win32/gdkwin32.h>
#include <pango/pangocairo.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#include "pipe-client.h"
#include "settings.h"

/* ------------------------------------------------------------------ */
/* Decision logic, compiled from indicator/mode-logic.el by build.el's
 * `nelisp-aot-compile-to-object' call and linked in as mode-logic.o.
 * Every symbol below is a plain Win64-ABI-shaped (see nelisp-aot-
 * compiler.el: COFF/x86_64 output binds --abi to 'win64) C function
 * taking/returning int64_t, exactly like any other extern C function;
 * there is nothing NeLisp-specific about the call site here. See mode-
 * logic.el's own header comment for the full MODE/PREVIOUS_BASE/
 * COLORS_PTR contract these implement. */
extern int64_t skkui_color_for_configured(int64_t mode, int64_t previous_base,
                                          int64_t colors_ptr);
extern int64_t skkui_base_label(int64_t mode);
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

/* Names used only for the stdout transition log (verify/verify.ps1
 * reads these). Independent of the glyphs drawn on screen
 * (draw_indicator() below), which come from skkui_*_label()/UTF-8 glyph
 * tables so the NeLisp module stays the single source of truth for what
 * the user sees. */
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
 * nelisp-aot-compiler.el's `:object-mode-no-strings' gate) -- NeLisp
 * decides *which* label (an integer), main.c owns the literal glyph (a
 * rendering primitive). Labels are not registry-configurable (no such
 * column in the design doc's schema tables). */
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
/* UTF-8 <-> UTF-16 helpers for the settings window's text entries
 * (Settings' string fields are wchar_t[] for direct registry I/O;
 * GtkEditable's text is always UTF-8). Cast wchar_t* <-> gunichar2* is
 * safe on Windows: both are 16-bit UTF-16 code units there. */

static void utf8_to_wide(const char *utf8, wchar_t *out, size_t out_cap) {
  glong written = 0;
  gunichar2 *wide = g_utf8_to_utf16(utf8, -1, NULL, &written, NULL);
  if (wide) {
    size_t n = (size_t)written < out_cap - 1 ? (size_t)written : out_cap - 1;
    memcpy(out, wide, n * sizeof(wchar_t));
    out[n] = L'\0';
    g_free(wide);
  } else {
    out[0] = L'\0';
  }
}

static char *wide_to_utf8_alloc(const wchar_t *wide) {
  char *utf8 = g_utf16_to_utf8((const gunichar2 *)wide, -1, NULL, NULL, NULL);
  return utf8 ? utf8 : g_strdup("");
}

/* ------------------------------------------------------------------ */
/* App state. */

typedef struct {
  GtkApplication *gtk_app;
  GtkWidget *window;          /* the indicator pill; NULL in --settings-only mode */
  GtkWidget *drawing_area;
  GtkWidget *popover;
  GtkWidget *settings_window; /* NULL when no settings window is open */
  PipeClient pipe;
  Settings settings;
  int64_t mode;           /* last mode this process observed, incl. 7 */
  int64_t previous_base;  /* last *base* mode (never 4/5/7) */
  gboolean have_state;     /* FALSE until the first poll completes */
  gboolean settings_only;  /* TRUE when launched with --settings: no pill, no poll */
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
 * maps to MODE_UNREACHABLE -- the "pipe unreachable or ERR" bucket makes
 * no distinction between the two from the display's point of view. */
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

/* Fills OUT (7 slots, see mode-logic.el's COLORS_PTR contract) from the
 * currently loaded Settings. Slots 4/5/7 (preedit/candidate/
 * unreachable) are left at 0 -- mode-logic.el's skkui_base_color_configured
 * never reads them (preedit/candidate are redirected to previous_base
 * before indexing, and unreachable/ERR keeps its own hardcoded #808080). */
static void fill_configured_colors(const Settings *s, int64_t out[7]) {
  out[0] = s->color_kana;
  out[1] = s->color_katakana;
  out[2] = s->color_wide_latin;
  out[3] = s->color_latin;
  out[4] = 0;
  out[5] = 0;
  out[6] = s->color_abbrev;
}

static void draw_indicator(GtkDrawingArea *area, cairo_t *cr, int width,
                           int height, gpointer user_data) {
  (void)area;
  App *app = (App *)user_data;
  const int64_t mode = app->have_state ? app->mode : MODE_UNREACHABLE;
  const int64_t prev = app->previous_base;

  int64_t colors[7];
  fill_configured_colors(&app->settings, colors);
  const int64_t rgb = skkui_color_for_configured(mode, prev, (int64_t)(intptr_t)colors);
  const int64_t label_code = skkui_label_for(mode, prev);
  const int64_t marker_code = skkui_composing_marker(mode);

  set_source_from_rgb24(cr, rgb);
  cairo_paint(cr);

  /* Text color: near-white on every one of this app's default backgrounds
   * (red/green/purple/blue/gray are all dark/mid-saturation), matching
   * mode_indicator.cpp's own default for the same palette family. A
   * user-chosen pale override color from Phase 3's color pickers could
   * make white text hard to read -- unlike mode_indicator.cpp, this MVP
   * does not yet flip to dark text for pale overrides; noted in
   * README.md as a follow-up alongside ModeIndicatorScale (also not
   * wired to the drawn size yet). */
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
/* Click-to-open-menu / suppressed-while-composing. */

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
/* Settings window (Phase 3). */

typedef struct {
  App *app;
  GtkWidget *window;

  /* Tab 動作 */
  GtkWidget *engine_dropdown;
  /* One page of engine-specific controls per engine, shown by the stack
   * as the dropdown changes, so an engine's options never appear under
   * another engine. */
  GtkWidget *engine_stack;
  /* kEngineChoices indices actually offered in the dropdown, in dropdown
   * order; experimental engines are absent unless enabled.  The dropdown's
   * own selection index means nothing without this mapping. */
  guint engine_visible[8];
  guint engine_visible_count;
  GtkWidget *check_okuri_auto;      /* ddskk */
  GtkWidget *spin_candidate_limit;  /* lattice */
  GtkWidget *check_lattice_learning;/* lattice */
  GtkWidget *radio_hiragana;
  GtkWidget *radio_latin;
  GtkWidget *check_okuri_strictly;
  GtkWidget *check_delete_okuri_on_cancel;
  GtkWidget *check_add_katakana_cand;
  GtkWidget *check_learn_disabled;

  /* Tab 表示 */
  GtkWidget *check_mode_indicator;
  GtkWidget *spin_indicator_ms;
  GtkWidget *spin_indicator_scale;
  GtkWidget *color_kana;
  GtkWidget *color_katakana;
  GtkWidget *color_wide_latin;
  GtkWidget *color_latin;
  GtkWidget *color_abbrev;

  /* Tab 辞書 */
  GtkWidget *check_skkserv_enable;
  GtkWidget *entry_skkserv_host;
  GtkWidget *spin_skkserv_port;
  GtkWidget *entry_jisyo_path;
  GtkWidget *spin_jisyo_batch;

  /* Tab 調整 */
  GtkWidget *spin_idle_gc_ms;
  GtkWidget *check_dll_debug;

  GtkWidget *status_label;
} SettingsWindow;

/* The stored form is a Win32 COLORREF -- 0x00BBGGRR, blue in the high
 * byte -- because TextService::LoadSettings() hands the value straight to
 * GDI.  Packing it red-first instead swapped red and blue on screen. */
static void packed_to_rgba(int64_t packed, GdkRGBA *out) {
  out->blue = ((packed >> 16) & 0xff) / 255.0;
  out->green = ((packed >> 8) & 0xff) / 255.0;
  out->red = (packed & 0xff) / 255.0;
  out->alpha = 1.0;
}

static int64_t rgba_to_packed(GtkColorDialogButton *btn) {
  const GdkRGBA *rgba = gtk_color_dialog_button_get_rgba(btn);
  const int r = (int)(rgba->red * 255.0 + 0.5);
  const int g = (int)(rgba->green * 255.0 + 0.5);
  const int b = (int)(rgba->blue * 255.0 + 0.5);
  return ((int64_t)b << 16) | ((int64_t)g << 8) | (int64_t)r;
}

static GtkWidget *make_color_button(int64_t packed) {
  GdkRGBA rgba;
  packed_to_rgba(packed, &rgba);
  GtkWidget *btn = gtk_color_dialog_button_new(gtk_color_dialog_new());
  gtk_color_dialog_button_set_rgba(GTK_COLOR_DIALOG_BUTTON(btn), &rgba);
  return btn;
}

/* Appends a label + control row to GRID at ROW. Used for every setting
 * except the three standalone checkboxes (ModeIndicator/SkkServEnable/
 * DllDebug), whose own label text is the checkbox's own label. */
static void grid_add_row(GtkGrid *grid, int row, const char *label_text, GtkWidget *control) {
  GtkWidget *label = gtk_label_new(label_text);
  gtk_label_set_xalign(GTK_LABEL(label), 0.0);
  gtk_widget_set_hexpand(control, TRUE);
  gtk_grid_attach(grid, label, 0, row, 1, 1);
  gtk_grid_attach(grid, control, 1, row, 1, 1);
}

/* The engines the settings window offers.  The id is the wire name the
 * engine process answers to `ENGINE LIST' and the text service sends
 * back with `ENGINE SET'; it is also the registry subkey holding that
 * engine's own settings.  Adding an engine means adding a row here and a
 * page in build_engine_pages(). */
typedef struct {
  const wchar_t *id;
  const char *label;   /* UTF-8, shown in the dropdown */
  const char *note;    /* UTF-8, one line under the dropdown */
  /* TRUE while the engine cannot actually be typed with, whatever the
   * wire protocol says.  Hidden unless settings_experimental_engines().
   * `lattice' answered every request correctly and still made the IME
   * unusable: it reports each kana as a fresh composition at offset 0,
   * so the caret never advances and each keystroke overwrites the last.
   * Speaking the protocol is not the same as sharing DDSKK's input
   * model, and only the latter makes an engine selectable here. */
  gboolean experimental;
} EngineChoice;

static const EngineChoice kEngineChoices[] = {
    {L"ddskk", "DDSKK (SKK)",
     "SKK の変換規則をそのまま使います。", FALSE},
    {L"lattice", "かな漢字変換 (nelisp-ime)",
     "辞書ラティスで文全体の候補を選びます。", TRUE},
    {L"dictionary", "完全一致変換 (nelisp-ime)",
     "読みが完全一致する候補だけを出します。", TRUE},
    {L"passthrough", "パススルー (実験用)",
     "変換せずアプリへ渡します。", FALSE},
};

#define ENGINE_CHOICE_COUNT (sizeof(kEngineChoices) / sizeof(kEngineChoices[0]))

static guint engine_choice_index(const wchar_t *id) {
  for (guint i = 0; i < ENGINE_CHOICE_COUNT; i++) {
    if (wcscmp(kEngineChoices[i].id, id) == 0) return i;
  }
  return 0; /* an id this build does not know falls back to the first */
}

/* Fill sw->engine_visible with the choices to offer.  An engine already
 * selected in the registry stays visible even when experimental, so the
 * window never silently misreports which engine is configured. */
static void engine_visible_init(SettingsWindow *sw) {
  const gboolean experimental = settings_experimental_engines();
  const guint current = engine_choice_index(sw->app->settings.engine);
  sw->engine_visible_count = 0;
  for (guint i = 0; i < ENGINE_CHOICE_COUNT; i++) {
    if (kEngineChoices[i].experimental && !experimental && i != current) continue;
    sw->engine_visible[sw->engine_visible_count++] = i;
  }
}

/* Dropdown position of the choice with kEngineChoices index CHOICE. */
static guint engine_visible_position(const SettingsWindow *sw, guint choice) {
  for (guint i = 0; i < sw->engine_visible_count; i++) {
    if (sw->engine_visible[i] == choice) return i;
  }
  return 0;
}

/* Show the page belonging to the engine now selected, and reload that
 * engine's stored values into it.  Reloading matters because each
 * engine keeps its settings in its own subkey: without it the page would
 * show whatever the previously selected engine had. */
static void on_engine_changed(GObject *dropdown, GParamSpec *pspec, gpointer user_data) {
  (void)pspec;
  SettingsWindow *sw = (SettingsWindow *)user_data;
  const guint selected = gtk_drop_down_get_selected(GTK_DROP_DOWN(dropdown));
  if (selected >= sw->engine_visible_count) return;
  const guint index = sw->engine_visible[selected];
  const EngineChoice *choice = &kEngineChoices[index];

  wcsncpy(sw->app->settings.engine, choice->id, SETTINGS_STR_LEN - 1);
  sw->app->settings.engine[SETTINGS_STR_LEN - 1] = L'\0';
  settings_load_engine_scope(&sw->app->settings, choice->id);

  if (sw->check_okuri_auto) {
    gtk_check_button_set_active(GTK_CHECK_BUTTON(sw->check_okuri_auto),
                                sw->app->settings.engine_okuri_auto != 0);
  }
  if (sw->spin_candidate_limit) {
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(sw->spin_candidate_limit),
                              sw->app->settings.engine_candidate_limit);
  }
  if (sw->check_lattice_learning) {
    gtk_check_button_set_active(GTK_CHECK_BUTTON(sw->check_lattice_learning),
                                sw->app->settings.engine_learning != 0);
  }
  if (sw->engine_stack) {
    /* Pages are named by kEngineChoices index, not dropdown position:
     * the two differ as soon as an engine is hidden. */
    char name[32];
    g_snprintf(name, sizeof(name), "%u", index);
    gtk_stack_set_visible_child_name(GTK_STACK(sw->engine_stack), name);
  }
}

/* One page per engine: its description plus whatever settings only that
 * engine honors. */
static GtkWidget *build_engine_pages(SettingsWindow *sw) {
  GtkWidget *stack = gtk_stack_new();
  for (guint i = 0; i < ENGINE_CHOICE_COUNT; i++) {
    GtkWidget *page = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    GtkWidget *note = gtk_label_new(kEngineChoices[i].note);
    gtk_label_set_xalign(GTK_LABEL(note), 0.0);
    gtk_label_set_wrap(GTK_LABEL(note), TRUE);
    gtk_box_append(GTK_BOX(page), note);

    if (wcscmp(kEngineChoices[i].id, L"ddskk") == 0) {
      sw->check_okuri_auto = gtk_check_button_new_with_label(
          "\xe9\x80\x81\xe3\x82\x8a\xe4\xbb\xae\xe5\x90\x8d\xe3\x82\x92\xe8\x87\xaa\xe5\x8b\x95\xe5\x87\xa6\xe7\x90\x86\xe3\x81\x99\xe3\x82\x8b" /* 送り仮名を自動処理する */);
      gtk_check_button_set_active(GTK_CHECK_BUTTON(sw->check_okuri_auto),
                                  sw->app->settings.engine_okuri_auto != 0);
      gtk_box_append(GTK_BOX(page), sw->check_okuri_auto);
    } else if (wcscmp(kEngineChoices[i].id, L"lattice") == 0) {
      GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
      GtkWidget *label = gtk_label_new(
          "\xe5\x80\x99\xe8\xa3\x9c\xe3\x81\xae\xe8\xa1\xa8\xe7\xa4\xba\xe6\x95\xb0" /* 候補の表示数 */);
      gtk_label_set_xalign(GTK_LABEL(label), 0.0);
      sw->spin_candidate_limit = gtk_spin_button_new_with_range(1, 30, 1);
      gtk_spin_button_set_value(GTK_SPIN_BUTTON(sw->spin_candidate_limit),
                                sw->app->settings.engine_candidate_limit);
      gtk_box_append(GTK_BOX(row), label);
      gtk_box_append(GTK_BOX(row), sw->spin_candidate_limit);
      gtk_box_append(GTK_BOX(page), row);

      sw->check_lattice_learning = gtk_check_button_new_with_label(
          "\xe7\xa2\xba\xe5\xae\x9a\xe3\x81\x97\xe3\x81\x9f\xe5\x80\x99\xe8\xa3\x9c\xe3\x82\x92\xe5\xad\xa6\xe7\xbf\x92\xe3\x81\x99\xe3\x82\x8b" /* 確定した候補を学習する */);
      gtk_check_button_set_active(GTK_CHECK_BUTTON(sw->check_lattice_learning),
                                  sw->app->settings.engine_learning != 0);
      gtk_box_append(GTK_BOX(page), sw->check_lattice_learning);
    }

    char name[32];
    g_snprintf(name, sizeof(name), "%u", i);
    gtk_stack_add_named(GTK_STACK(stack), page, name);
  }
  return stack;
}

static GtkWidget *build_tab_behavior(SettingsWindow *sw) {
  GtkWidget *grid = gtk_grid_new();
  gtk_grid_set_row_spacing(GTK_GRID(grid), 6);
  gtk_grid_set_column_spacing(GTK_GRID(grid), 12);
  gtk_widget_set_margin_top(grid, 12);
  gtk_widget_set_margin_bottom(grid, 12);
  gtk_widget_set_margin_start(grid, 12);
  gtk_widget_set_margin_end(grid, 12);

  engine_visible_init(sw);
  const char *engine_labels[ENGINE_CHOICE_COUNT + 1];
  for (guint i = 0; i < sw->engine_visible_count; i++) {
    engine_labels[i] = kEngineChoices[sw->engine_visible[i]].label;
  }
  engine_labels[sw->engine_visible_count] = NULL;
  sw->engine_dropdown = gtk_drop_down_new_from_strings(engine_labels);
  gtk_drop_down_set_selected(
      GTK_DROP_DOWN(sw->engine_dropdown),
      engine_visible_position(sw, engine_choice_index(sw->app->settings.engine)));
  g_signal_connect(sw->engine_dropdown, "notify::selected",
                   G_CALLBACK(on_engine_changed), sw);
  grid_add_row(GTK_GRID(grid), 0, "エンジン" /* エンジン */, sw->engine_dropdown);

  GtkWidget *radio_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
  sw->radio_hiragana = gtk_check_button_new_with_label("\xe3\x81\x8b\xe3\x81\xaa" /* かな */);
  sw->radio_latin = gtk_check_button_new_with_label("\xe8\x8b\xb1\xe6\x95\xb0" /* 英数 */);
  gtk_check_button_set_group(GTK_CHECK_BUTTON(sw->radio_latin), GTK_CHECK_BUTTON(sw->radio_hiragana));
  gtk_check_button_set_active(
      GTK_CHECK_BUTTON(sw->app->settings.initial_kana_mode ? sw->radio_hiragana : sw->radio_latin), TRUE);
  gtk_box_append(GTK_BOX(radio_box), sw->radio_hiragana);
  gtk_box_append(GTK_BOX(radio_box), sw->radio_latin);
  grid_add_row(GTK_GRID(grid), 1, "\xe5\x88\x9d\xe6\x9c\x9f\xe5\x85\xa5\xe5\x8a\x9b\xe3\x83\xa2\xe3\x83\xbc\xe3\x83\x89" /* 初期入力モード */, radio_box);

  /* CorvusSKK-modeled behavior toggles (BehaviorOkuriStrictly/
   * BehaviorDeleteOkuriOnCancel/BehaviorAddKatakanaCand/
   * BehaviorLearnDisabled -- see settings.h). These take effect via
   * engine restart, same as every other value on this tab; the shared
   * status_label below the notebook (not tab-scoped) already shows the
   * CorvusSKK-style "反映には..." note after Apply regardless of which
   * tab is active, so no separate note is needed here. */
  int row = 2;
  sw->check_okuri_strictly = gtk_check_button_new_with_label(
      "\xe9\x80\x81\xe3\x82\x8a\xe4\xbb\xae\xe5\x90\x8d\xe3\x81\x8c\xe4\xb8\x80\xe8\x87\xb4\xe3\x81\x97\xe3\x81\x9f\xe5\x80\x99\xe8\xa3\x9c\xe3\x82\x92\xe5\x84\xaa\xe5\x85\x88\xe3\x81\x99\xe3\x82\x8b"
      /* 送り仮名が一致した候補を優先する */);
  gtk_check_button_set_active(GTK_CHECK_BUTTON(sw->check_okuri_strictly),
                              sw->app->settings.behavior_okuri_strictly != 0);
  gtk_grid_attach(GTK_GRID(grid), sw->check_okuri_strictly, 0, row++, 2, 1);

  sw->check_delete_okuri_on_cancel = gtk_check_button_new_with_label(
      "\xe5\x8f\x96\xe6\xb6\x88\xe3\x81\xae\xe3\x81\xa8\xe3\x81\x8d\xe9\x80\x81\xe3\x82\x8a\xe4\xbb\xae\xe5\x90\x8d\xe3\x82\x92\xe5\x89\x8a\xe9\x99\xa4\xe3\x81\x99\xe3\x82\x8b"
      /* 取消のとき送り仮名を削除する */);
  gtk_check_button_set_active(GTK_CHECK_BUTTON(sw->check_delete_okuri_on_cancel),
                              sw->app->settings.behavior_delete_okuri_on_cancel != 0);
  gtk_grid_attach(GTK_GRID(grid), sw->check_delete_okuri_on_cancel, 0, row++, 2, 1);

  sw->check_add_katakana_cand = gtk_check_button_new_with_label(
      "\xe5\x80\x99\xe8\xa3\x9c\xe3\x81\xab\xe7\x89\x87\xe4\xbb\xae\xe5\x90\x8d\xe5\xa4\x89\xe6\x8f\x9b\xe3\x82\x92\xe8\xbf\xbd\xe5\x8a\xa0\xe3\x81\x99\xe3\x82\x8b"
      /* 候補に片仮名変換を追加する */);
  gtk_check_button_set_active(GTK_CHECK_BUTTON(sw->check_add_katakana_cand),
                              sw->app->settings.behavior_add_katakana_cand != 0);
  gtk_grid_attach(GTK_GRID(grid), sw->check_add_katakana_cand, 0, row++, 2, 1);

  /* Engine-specific settings live on their own page, swapped by the
   * dropdown above, so an engine's options never show under another. */
  sw->engine_stack = build_engine_pages(sw);
  {
    char name[32];
    g_snprintf(name, sizeof(name), "%u",
               engine_choice_index(sw->app->settings.engine));
    gtk_stack_set_visible_child_name(GTK_STACK(sw->engine_stack), name);
  }

  sw->check_learn_disabled = gtk_check_button_new_with_label(
      "\xe5\xad\xa6\xe7\xbf\x92\xe3\x81\x97\xe3\x81\xaa\xe3\x81\x84\xef\xbc\x88\xe3\x83\x97\xe3\x83\xa9\xe3\x82\xa4\xe3\x83\x99\xe3\x83\xbc\xe3\x83\x88\xe3\x83\xa2\xe3\x83\xbc\xe3\x83\x89\xef\xbc\x89"
      /* 学習しない（プライベートモード） */);
  gtk_check_button_set_active(GTK_CHECK_BUTTON(sw->check_learn_disabled),
                              sw->app->settings.behavior_learn_disabled != 0);
  gtk_grid_attach(GTK_GRID(grid), sw->check_learn_disabled, 0, row++, 2, 1);

  return grid;
}

static GtkWidget *build_tab_display(SettingsWindow *sw) {
  GtkWidget *grid = gtk_grid_new();
  gtk_grid_set_row_spacing(GTK_GRID(grid), 6);
  gtk_grid_set_column_spacing(GTK_GRID(grid), 12);
  gtk_widget_set_margin_top(grid, 12);
  gtk_widget_set_margin_bottom(grid, 12);
  gtk_widget_set_margin_start(grid, 12);
  gtk_widget_set_margin_end(grid, 12);
  int row = 0;

  sw->check_mode_indicator = gtk_check_button_new_with_label(
      "\xe5\x85\xa5\xe5\x8a\x9b\xe3\x83\xa2\xe3\x83\xbc\xe3\x83\x89\xe3\x82\x92\xe8\xa1\xa8\xe7\xa4\xba\xe3\x81\x99\xe3\x82\x8b" /* 入力モードを表示する */);
  gtk_check_button_set_active(GTK_CHECK_BUTTON(sw->check_mode_indicator), sw->app->settings.mode_indicator != 0);
  gtk_grid_attach(GTK_GRID(grid), sw->check_mode_indicator, 0, row, 2, 1);
  row++;

  sw->spin_indicator_ms = gtk_spin_button_new_with_range(1, 60000, 100);
  gtk_spin_button_set_value(GTK_SPIN_BUTTON(sw->spin_indicator_ms), sw->app->settings.mode_indicator_ms);
  grid_add_row(GTK_GRID(grid), row++, "\xe8\xa1\xa8\xe7\xa4\xba\xe6\x99\x82\xe9\x96\x93 (ms)" /* 表示時間 (ms) */, sw->spin_indicator_ms);

  sw->spin_indicator_scale = gtk_spin_button_new_with_range(50, 300, 5);
  gtk_spin_button_set_value(GTK_SPIN_BUTTON(sw->spin_indicator_scale), sw->app->settings.mode_indicator_scale);
  grid_add_row(GTK_GRID(grid), row++, "\xe8\xa1\xa8\xe7\xa4\xba\xe5\x80\x8d\xe7\x8e\x87 (%)" /* 表示倍率 (%) */, sw->spin_indicator_scale);

  sw->color_kana = make_color_button(sw->app->settings.color_kana);
  grid_add_row(GTK_GRID(grid), row++, "\xe3\x81\x8b\xe3\x81\xaa\xe8\x89\xb2" /* かな色 */, sw->color_kana);

  sw->color_katakana = make_color_button(sw->app->settings.color_katakana);
  grid_add_row(GTK_GRID(grid), row++, "\xe3\x82\xab\xe3\x83\x8a\xe8\x89\xb2" /* カナ色 */, sw->color_katakana);

  sw->color_wide_latin = make_color_button(sw->app->settings.color_wide_latin);
  grid_add_row(GTK_GRID(grid), row++, "\xe5\x85\xa8\xe8\x8b\xb1\xe8\x89\xb2" /* 全英色 */, sw->color_wide_latin);

  sw->color_latin = make_color_button(sw->app->settings.color_latin);
  grid_add_row(GTK_GRID(grid), row++, "SKK(\xe8\x8b\xb1\xe6\x95\xb0)\xe8\x89\xb2" /* SKK(英数)色 */, sw->color_latin);

  sw->color_abbrev = make_color_button(sw->app->settings.color_abbrev);
  grid_add_row(GTK_GRID(grid), row++, "Abbrev\xe8\x89\xb2" /* Abbrev色 */, sw->color_abbrev);

  return grid;
}

static void on_jisyo_chosen(GObject *source, GAsyncResult *result, gpointer user_data) {
  GtkEntry *entry = GTK_ENTRY(user_data);
  GError *error = NULL;
  GFile *file = gtk_file_dialog_open_finish(GTK_FILE_DIALOG(source), result, &error);
  if (file) {
    char *path = g_file_get_path(file);
    if (path) {
      gtk_editable_set_text(GTK_EDITABLE(entry), path);
      g_free(path);
    }
    g_object_unref(file);
  }
  g_clear_error(&error);
}

static void on_jisyo_browse_clicked(GtkButton *button, gpointer user_data) {
  GtkEntry *entry = GTK_ENTRY(user_data);
  GtkRoot *root = gtk_widget_get_root(GTK_WIDGET(button));
  GtkFileDialog *dialog = gtk_file_dialog_new();
  gtk_file_dialog_set_title(dialog,
      "\xe3\x83\xa6\xe3\x83\xbc\xe3\x82\xb6\xe3\x83\xbc\xe8\xbe\x9e\xe6\x9b\xb8\xe3\x83\x95\xe3\x82\xa1\xe3\x82\xa4\xe3\x83\xab\xe3\x82\x92\xe9\x81\xb8\xe6\x8a\x9e" /* ユーザー辞書ファイルを選択 */);
  gtk_file_dialog_open(dialog, GTK_WINDOW(root), NULL, on_jisyo_chosen, entry);
  g_object_unref(dialog);
}

static GtkWidget *build_tab_dictionary(SettingsWindow *sw) {
  GtkWidget *grid = gtk_grid_new();
  gtk_grid_set_row_spacing(GTK_GRID(grid), 6);
  gtk_grid_set_column_spacing(GTK_GRID(grid), 12);
  gtk_widget_set_margin_top(grid, 12);
  gtk_widget_set_margin_bottom(grid, 12);
  gtk_widget_set_margin_start(grid, 12);
  gtk_widget_set_margin_end(grid, 12);
  int row = 0;

  sw->check_skkserv_enable = gtk_check_button_new_with_label(
      "\xe8\xbe\x9e\xe6\x9b\xb8\xe3\x82\xb5\xe3\x83\xbc\xe3\x83\x90\xe3\x82\x92\xe4\xbd\xbf\xe7\x94\xa8\xe3\x81\x99\xe3\x82\x8b" /* 辞書サーバを使用する */);
  gtk_check_button_set_active(GTK_CHECK_BUTTON(sw->check_skkserv_enable), sw->app->settings.skkserv_enable != 0);
  gtk_grid_attach(GTK_GRID(grid), sw->check_skkserv_enable, 0, row, 2, 1);
  row++;

  sw->entry_skkserv_host = gtk_entry_new();
  {
    char *host_utf8 = wide_to_utf8_alloc(sw->app->settings.skkserv_host);
    gtk_editable_set_text(GTK_EDITABLE(sw->entry_skkserv_host), host_utf8);
    g_free(host_utf8);
  }
  grid_add_row(GTK_GRID(grid), row++, "\xe3\x83\x9b\xe3\x82\xb9\xe3\x83\x88" /* ホスト */, sw->entry_skkserv_host);

  sw->spin_skkserv_port = gtk_spin_button_new_with_range(1, 65535, 1);
  gtk_spin_button_set_value(GTK_SPIN_BUTTON(sw->spin_skkserv_port), sw->app->settings.skkserv_port);
  grid_add_row(GTK_GRID(grid), row++, "\xe3\x83\x9d\xe3\x83\xbc\xe3\x83\x88" /* ポート */, sw->spin_skkserv_port);

  GtkWidget *jisyo_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
  sw->entry_jisyo_path = gtk_entry_new();
  gtk_widget_set_hexpand(sw->entry_jisyo_path, TRUE);
  {
    char *path_utf8 = wide_to_utf8_alloc(sw->app->settings.user_jisyo_path);
    gtk_editable_set_text(GTK_EDITABLE(sw->entry_jisyo_path), path_utf8);
    g_free(path_utf8);
  }
  GtkWidget *browse_button = gtk_button_new_with_label("\xe5\x8f\x82\xe7\x85\xa7" /* 参照 */);
  g_signal_connect(browse_button, "clicked", G_CALLBACK(on_jisyo_browse_clicked), sw->entry_jisyo_path);
  gtk_box_append(GTK_BOX(jisyo_box), sw->entry_jisyo_path);
  gtk_box_append(GTK_BOX(jisyo_box), browse_button);
  grid_add_row(GTK_GRID(grid), row++, "\xe3\x83\xa6\xe3\x83\xbc\xe3\x82\xb6\xe3\x83\xbc\xe8\xbe\x9e\xe6\x9b\xb8\xe3\x83\x91\xe3\x82\xb9" /* ユーザー辞書パス */, jisyo_box);

  sw->spin_jisyo_batch = gtk_spin_button_new_with_range(1, 100, 1);
  gtk_spin_button_set_value(GTK_SPIN_BUTTON(sw->spin_jisyo_batch), sw->app->settings.user_jisyo_batch);
  grid_add_row(GTK_GRID(grid), row++, "\xe4\xbf\x9d\xe5\xad\x98\xe9\x96\x93\xe9\x9a\x94 (\xe7\xa2\xba\xe5\xae\x9a\xe6\x95\xb0)" /* 保存間隔 (確定数) */, sw->spin_jisyo_batch);

  return grid;
}

static GtkWidget *build_tab_maintenance(SettingsWindow *sw) {
  GtkWidget *grid = gtk_grid_new();
  gtk_grid_set_row_spacing(GTK_GRID(grid), 6);
  gtk_grid_set_column_spacing(GTK_GRID(grid), 12);
  gtk_widget_set_margin_top(grid, 12);
  gtk_widget_set_margin_bottom(grid, 12);
  gtk_widget_set_margin_start(grid, 12);
  gtk_widget_set_margin_end(grid, 12);
  int row = 0;

  sw->spin_idle_gc_ms = gtk_spin_button_new_with_range(100, 60000, 100);
  gtk_spin_button_set_value(GTK_SPIN_BUTTON(sw->spin_idle_gc_ms), sw->app->settings.idle_gc_ms);
  grid_add_row(GTK_GRID(grid), row++, "\xe3\x82\xa2\xe3\x82\xa4\xe3\x83\x89\xe3\x83\xabGC\xe9\x96\x93\xe9\x9a\x94 (ms)" /* アイドルGC間隔 (ms) */, sw->spin_idle_gc_ms);

  sw->check_dll_debug = gtk_check_button_new_with_label("\xe3\x83\x87\xe3\x83\x90\xe3\x83\x83\xe3\x82\xb0\xe3\x83\xad\xe3\x82\xb0" /* デバッグログ */);
  gtk_check_button_set_active(GTK_CHECK_BUTTON(sw->check_dll_debug), sw->app->settings.dll_debug != 0);
  gtk_grid_attach(GTK_GRID(grid), sw->check_dll_debug, 0, row, 2, 1);

  return grid;
}

static void settings_read_from_widgets(SettingsWindow *sw, Settings *out) {
  *out = sw->app->settings;

  /* The engine and its own settings.  `engine' is a control now, so it is
   * read back like everything else rather than carried over untouched. */
  const guint selected = gtk_drop_down_get_selected(GTK_DROP_DOWN(sw->engine_dropdown));
  if (selected < sw->engine_visible_count) {
    wcsncpy(out->engine, kEngineChoices[sw->engine_visible[selected]].id,
            SETTINGS_STR_LEN - 1);
    out->engine[SETTINGS_STR_LEN - 1] = 0;
  }
  if (sw->check_okuri_auto) {
    out->engine_okuri_auto =
        gtk_check_button_get_active(GTK_CHECK_BUTTON(sw->check_okuri_auto)) ? 1 : 0;
  }
  if (sw->spin_candidate_limit) {
    out->engine_candidate_limit =
        gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(sw->spin_candidate_limit));
  }
  if (sw->check_lattice_learning) {
    out->engine_learning =
        gtk_check_button_get_active(GTK_CHECK_BUTTON(sw->check_lattice_learning)) ? 1 : 0;
  }

  out->initial_kana_mode = gtk_check_button_get_active(GTK_CHECK_BUTTON(sw->radio_hiragana)) ? 1 : 0;
  out->behavior_okuri_strictly = gtk_check_button_get_active(GTK_CHECK_BUTTON(sw->check_okuri_strictly)) ? 1 : 0;
  out->behavior_delete_okuri_on_cancel =
      gtk_check_button_get_active(GTK_CHECK_BUTTON(sw->check_delete_okuri_on_cancel)) ? 1 : 0;
  out->behavior_add_katakana_cand =
      gtk_check_button_get_active(GTK_CHECK_BUTTON(sw->check_add_katakana_cand)) ? 1 : 0;
  out->behavior_learn_disabled = gtk_check_button_get_active(GTK_CHECK_BUTTON(sw->check_learn_disabled)) ? 1 : 0;

  out->mode_indicator = gtk_check_button_get_active(GTK_CHECK_BUTTON(sw->check_mode_indicator)) ? 1 : 0;
  out->mode_indicator_ms = gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(sw->spin_indicator_ms));
  out->mode_indicator_scale = gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(sw->spin_indicator_scale));
  out->color_kana = rgba_to_packed(GTK_COLOR_DIALOG_BUTTON(sw->color_kana));
  out->color_katakana = rgba_to_packed(GTK_COLOR_DIALOG_BUTTON(sw->color_katakana));
  out->color_wide_latin = rgba_to_packed(GTK_COLOR_DIALOG_BUTTON(sw->color_wide_latin));
  out->color_latin = rgba_to_packed(GTK_COLOR_DIALOG_BUTTON(sw->color_latin));
  out->color_abbrev = rgba_to_packed(GTK_COLOR_DIALOG_BUTTON(sw->color_abbrev));

  out->skkserv_enable = gtk_check_button_get_active(GTK_CHECK_BUTTON(sw->check_skkserv_enable)) ? 1 : 0;
  utf8_to_wide(gtk_editable_get_text(GTK_EDITABLE(sw->entry_skkserv_host)), out->skkserv_host, SETTINGS_STR_LEN);
  out->skkserv_port = gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(sw->spin_skkserv_port));
  utf8_to_wide(gtk_editable_get_text(GTK_EDITABLE(sw->entry_jisyo_path)), out->user_jisyo_path, SETTINGS_STR_LEN);
  out->user_jisyo_batch = gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(sw->spin_jisyo_batch));

  out->idle_gc_ms = gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(sw->spin_idle_gc_ms));
  out->dll_debug = gtk_check_button_get_active(GTK_CHECK_BUTTON(sw->check_dll_debug)) ? 1 : 0;
}

/* Shows/hides the indicator pill to match the just-applied (or just-
 * loaded) ModeIndicator setting. No-op in --settings-only mode, where
 * there is no pill (app->window is NULL). */
static void app_sync_pill_visibility(App *app) {
  if (!app->window) return;
  if (app->settings.mode_indicator) {
    gtk_window_present(GTK_WINDOW(app->window));
  } else {
    gtk_widget_set_visible(app->window, FALSE);
  }
}

static void on_apply_clicked(GtkButton *button, gpointer user_data) {
  (void)button;
  SettingsWindow *sw = user_data;
  Settings s;
  settings_read_from_widgets(sw, &s);
  const gboolean ok = settings_save(&s);
  /* Reflect the just-applied values in the running app (pill color/
   * visibility, poll cadence) regardless of whether persistence fully
   * succeeded, so what the user just set is what they see immediately;
   * the status label is honest about persistence separately. */
  sw->app->settings = s;
  app_sync_pill_visibility(sw->app);
  if (sw->app->drawing_area) gtk_widget_queue_draw(sw->app->drawing_area);
  gtk_label_set_text(
      GTK_LABEL(sw->status_label),
      ok ? "\xe5\x8f\x8d\xe6\x98\xa0\xe3\x81\xab\xe3\x81\xaf IME \xe3\x81\xae\xe5\x88\x87\xe6\x9b\xbf\xef\xbc\x88\xe3\x81\xbe\xe3\x81\x9f\xe3\x81\xaf\xe3\x82\xa8\xe3\x83\xb3\xe3\x82\xb8\xe3\x83\xb3\xe5\x86\x8d\xe8\xb5\xb7\xe5\x8b\x95\xef\xbc\x89\xe3\x81\x8c\xe5\xbf\x85\xe8\xa6\x81\xe3\x81\xa7\xe3\x81\x99"
         /* 反映には IME の切替（またはエンジン再起動）が必要です */
         : "\xe4\xb8\x80\xe9\x83\xa8\xe3\x81\xae\xe8\xa8\xad\xe5\xae\x9a\xe3\x81\xae\xe4\xbf\x9d\xe5\xad\x98\xe3\x81\xab\xe5\xa4\xb1\xe6\x95\x97\xe3\x81\x97\xe3\x81\xbe\xe3\x81\x97\xe3\x81\x9f"
         /* 一部の設定の保存に失敗しました */);
}

/* windows/host/main.cpp's ServeClient() accepts a literal "SHUTDOWN"
 * request (trailing \n/\r are stripped before the comparison) from any
 * connected client, answers "OK", and tears the whole host + engine
 * child process down; the TSF DLL respawns the host lazily on its own
 * next keystroke with the (by then already-written) new registry
 * values -- see docs/design/sumi-indicator-settings.md's Architecture
 * section. This app does not need to orchestrate that respawn itself,
 * only request the shutdown. */
static void on_restart_engine_clicked(GtkButton *button, gpointer user_data) {
  (void)button;
  SettingsWindow *sw = user_data;
  char response[64];
  pipe_client_transact(&sw->app->pipe, "SHUTDOWN\n", response, sizeof(response));
  gtk_label_set_text(GTK_LABEL(sw->status_label),
                     "\xe3\x82\xa8\xe3\x83\xb3\xe3\x82\xb8\xe3\x83\xb3\xe3\x81\xab\xe5\x86\x8d\xe8\xb5\xb7\xe5\x8b\x95\xe3\x82\x92\xe8\xa6\x81\xe6\xb1\x82\xe3\x81\x97\xe3\x81\xbe\xe3\x81\x97\xe3\x81\x9f"
                     /* エンジンに再起動を要求しました */);
}

static void close_settings_window(App *app) {
  if (!app->settings_window) return;
  const gboolean settings_only = app->settings_only;
  GtkWidget *window = app->settings_window;
  app->settings_window = NULL; /* clear before destroy: destroy may re-enter via close-request */
  gtk_window_destroy(GTK_WINDOW(window));
  if (settings_only && app->gtk_app) g_application_quit(G_APPLICATION(app->gtk_app));
}

static void on_close_clicked(GtkButton *button, gpointer user_data) {
  (void)button;
  SettingsWindow *sw = user_data;
  close_settings_window(sw->app);
}

static gboolean on_settings_close_request(GtkWindow *window, gpointer user_data) {
  (void)window;
  SettingsWindow *sw = user_data;
  close_settings_window(sw->app);
  return TRUE; /* handled: suppress the default close/destroy */
}

static void open_settings_window(App *app) {
  if (app->settings_window) {
    gtk_window_present(GTK_WINDOW(app->settings_window));
    return;
  }

  SettingsWindow *sw = g_new0(SettingsWindow, 1);
  sw->app = app;

  GtkWidget *window = app->settings_only && app->gtk_app
                          ? gtk_application_window_new(app->gtk_app)
                          : gtk_window_new();
  sw->window = window;
  app->settings_window = window;
  gtk_window_set_title(GTK_WINDOW(window), "SKK \xe8\xa8\xad\xe5\xae\x9a" /* SKK 設定 */);
  gtk_window_set_default_size(GTK_WINDOW(window), 480, 360);
  g_object_set_data_full(G_OBJECT(window), "sw", sw, g_free);
  g_signal_connect(window, "close-request", G_CALLBACK(on_settings_close_request), sw);

  GtkWidget *root_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
  gtk_window_set_child(GTK_WINDOW(window), root_box);

  GtkWidget *notebook = gtk_notebook_new();
  gtk_widget_set_vexpand(notebook, TRUE);
  gtk_notebook_append_page(GTK_NOTEBOOK(notebook), build_tab_behavior(sw),
                           gtk_label_new("\xe5\x8b\x95\xe4\xbd\x9c" /* 動作 */));
  gtk_notebook_append_page(GTK_NOTEBOOK(notebook), build_tab_display(sw),
                           gtk_label_new("\xe8\xa1\xa8\xe7\xa4\xba" /* 表示 */));
  gtk_notebook_append_page(GTK_NOTEBOOK(notebook), build_tab_dictionary(sw),
                           gtk_label_new("\xe8\xbe\x9e\xe6\x9b\xb8" /* 辞書 */));
  gtk_notebook_append_page(GTK_NOTEBOOK(notebook), build_tab_maintenance(sw),
                           gtk_label_new("\xe8\xaa\xbf\xe6\x95\xb4" /* 調整 */));
  gtk_box_append(GTK_BOX(root_box), notebook);

  sw->status_label = gtk_label_new("");
  gtk_widget_set_margin_start(sw->status_label, 12);
  gtk_widget_set_margin_end(sw->status_label, 12);
  gtk_label_set_wrap(GTK_LABEL(sw->status_label), TRUE);
  gtk_box_append(GTK_BOX(root_box), sw->status_label);

  GtkWidget *button_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
  gtk_widget_set_halign(button_box, GTK_ALIGN_END);
  gtk_widget_set_margin_top(button_box, 6);
  gtk_widget_set_margin_bottom(button_box, 12);
  gtk_widget_set_margin_start(button_box, 12);
  gtk_widget_set_margin_end(button_box, 12);

  GtkWidget *restart_button = gtk_button_new_with_label(
      "\xe3\x82\xa8\xe3\x83\xb3\xe3\x82\xb8\xe3\x83\xb3\xe5\x86\x8d\xe8\xb5\xb7\xe5\x8b\x95" /* エンジン再起動 */);
  g_signal_connect(restart_button, "clicked", G_CALLBACK(on_restart_engine_clicked), sw);
  GtkWidget *apply_button = gtk_button_new_with_label("\xe9\x81\xa9\xe7\x94\xa8" /* 適用 */);
  g_signal_connect(apply_button, "clicked", G_CALLBACK(on_apply_clicked), sw);
  GtkWidget *close_button = gtk_button_new_with_label("\xe9\x96\x89\xe3\x81\x98\xe3\x82\x8b" /* 閉じる */);
  g_signal_connect(close_button, "clicked", G_CALLBACK(on_close_clicked), sw);

  gtk_box_append(GTK_BOX(button_box), restart_button);
  gtk_box_append(GTK_BOX(button_box), apply_button);
  gtk_box_append(GTK_BOX(button_box), close_button);
  gtk_box_append(GTK_BOX(root_box), button_box);

  gtk_window_present(GTK_WINDOW(window));
}

static void on_right_click_released(GtkGestureClick *gesture, int n_press, double x,
                                    double y, gpointer user_data) {
  (void)x; (void)y;
  if (n_press != 1) return;
  App *app = (App *)user_data;
  gtk_gesture_set_state(GTK_GESTURE(gesture), GTK_EVENT_SEQUENCE_CLAIMED);
  open_settings_window(app);
}

/* ------------------------------------------------------------------ */
/* Polling timer: 500 ms while the pill is shown (ModeIndicator != 0),
 * 2 s while it is hidden -- task brief: "Poll cadence may drop to 2 s
 * while hidden." Self-rescheduling (on_poll_tick always returns
 * G_SOURCE_REMOVE and arms the next tick itself) rather than a fixed
 * g_timeout_add() so the interval can change between ticks whenever
 * app->settings.mode_indicator changes (Apply, or the initial load). */

#define SKKUI_POLL_INTERVAL_MS 500
#define SKKUI_HIDDEN_POLL_INTERVAL_MS 2000

static gboolean on_poll_tick(gpointer user_data);

static void schedule_poll(App *app) {
  const guint interval = app->settings.mode_indicator ? SKKUI_POLL_INTERVAL_MS
                                                       : SKKUI_HIDDEN_POLL_INTERVAL_MS;
  g_timeout_add(interval, on_poll_tick, app);
}

static gboolean on_poll_tick(gpointer user_data) {
  App *app = (App *)user_data;
  if (pipe_client_in_backoff(&app->pipe)) {
    if (!app->have_state || app->mode != MODE_UNREACHABLE)
      app_apply_mode(app, MODE_UNREACHABLE);
    schedule_poll(app);
    return G_SOURCE_REMOVE;
  }
  char response[8192];
  if (!pipe_client_transact(&app->pipe, "STATUS\n", response, sizeof(response))) {
    app_apply_mode(app, MODE_UNREACHABLE);
    schedule_poll(app);
    return G_SOURCE_REMOVE;
  }
  app_apply_mode(app, mode_from_state_reply(response));
  schedule_poll(app);
  return G_SOURCE_REMOVE;
}

/* ------------------------------------------------------------------ */
/* Window chrome: always-on-top (GTK4 dropped the portable
 * gtk_window_set_keep_above() API; SetWindowPos(HWND_TOPMOST) on the
 * GDK win32 surface's native HWND is the Windows-specific replacement,
 * the same kind of "host-side glue" already used for the named-pipe
 * I/O) and draggable-by-drag-anywhere (GtkWindowHandle, GTK4's own
 * widget for exactly this: consumes a press-drag as an interactive
 * move, passes an undragged click through to descendants -- here, the
 * GtkGestureClick handlers on drawing_area that open the mode menu /
 * settings window). */

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

static void build_pill(App *app) {
  app->window = gtk_application_window_new(app->gtk_app);
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

  GtkGesture *right_click = gtk_gesture_click_new();
  gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(right_click), GDK_BUTTON_SECONDARY);
  g_signal_connect(right_click, "released", G_CALLBACK(on_right_click_released), app);
  gtk_widget_add_controller(app->drawing_area, GTK_EVENT_CONTROLLER(right_click));

  GtkWidget *handle = gtk_window_handle_new();
  gtk_window_handle_set_child(GTK_WINDOW_HANDLE(handle), app->drawing_area);
  gtk_window_set_child(GTK_WINDOW(app->window), handle);

  g_signal_connect(app->window, "realize", G_CALLBACK(on_realize), NULL);
}

static void on_activate(GtkApplication *gtk_app, gpointer user_data) {
  App *app = (App *)user_data;
  app->gtk_app = gtk_app;

  settings_load(&app->settings);

  if (app->settings_only) {
    /* --settings: a short-lived launcher for a future Start-menu
     * shortcut (task brief). No pill, no STATUS polling -- just the
     * settings window, and the process exits when it is closed (see
     * close_settings_window()). */
    open_settings_window(app);
    return;
  }

  build_pill(app);
  app_sync_pill_visibility(app);
  schedule_poll(app);
}

int main(int argc, char **argv) {
  /* --settings-selftest runs entirely headless, before any GTK/pipe
   * initialization, and exits immediately -- see settings.h's
   * settings_selftest() docstring for the DDSKK_SETTINGS_KEY safety
   * guard this requires the caller to set. */
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--settings-selftest") == 0) return settings_selftest();
  }

  gboolean settings_only = FALSE;
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--settings") == 0) settings_only = TRUE;
  }

  App app;
  memset(&app, 0, sizeof(app));
  pipe_client_init(&app.pipe);
  app.mode = MODE_UNREACHABLE;
  app.previous_base = MODE_HIRAGANA;
  app.have_state = FALSE;
  app.settings_only = settings_only;
  settings_defaults(&app.settings); /* overwritten by settings_load() in on_activate() */
  app.label_font = pango_font_description_from_string("Sans 14");

  /* NON_UNIQUE when opening settings: with the default GApplication
   * uniqueness, a second `sumi-skk-ui --settings` launch would merely
   * re-activate the already-running indicator instance (whose
   * settings_only is FALSE) and exit, so no settings window ever
   * appeared. The settings window is a short-lived secondary surface;
   * letting it be its own process alongside the pill is the simple,
   * correct behavior.
   *
   * DDSKK_ALLOW_MULTIPLE_INSTANCES additionally forces NON_UNIQUE for a
   * plain (non-`--settings') launch too -- default off, so ordinary use
   * keeps the single-pill behavior. Exists because GApplication
   * uniqueness is scoped to the app ID for the whole user session: a
   * second plain launch while any instance (pill OR a `--settings'
   * window, since GTK's uniqueness applies per app ID regardless of
   * which flags registered it first) is already running otherwise gets
   * silently absorbed into that pre-existing instance -- it exits
   * almost immediately with status 0 and never runs its own
   * on_activate()/STATUS-poll/logging code at all, which looks
   * indistinguishable from a hang or a crash from the outside (an empty
   * stdout log, confirmed directly: a plain launch next to an
   * already-running pill exits in under a second with no output).
   * verify/verify.ps1 sets this so it can test a freshly built exe
   * without disturbing whatever pill/settings instances a developer
   * already has open. */
  const gboolean allow_multiple = getenv("DDSKK_ALLOW_MULTIPLE_INSTANCES") != NULL;
  GtkApplication *gtk_app = gtk_application_new(
      "dev.nelisp-skk-ime.sumi-ui",
      (settings_only || allow_multiple) ? G_APPLICATION_NON_UNIQUE : G_APPLICATION_DEFAULT_FLAGS);
  g_signal_connect(gtk_app, "activate", G_CALLBACK(on_activate), &app);
  /* Do NOT hand our own flags to GTK: GApplication parses the command
   * line itself and aborts on options it does not know ("--settings は
   * 不明なオプションです"). Everything we accept was consumed above. */
  const int status = g_application_run(G_APPLICATION(gtk_app), 1, argv);
  g_object_unref(gtk_app);
  pango_font_description_free(app.label_font);
  pipe_client_disconnect(&app.pipe);
  return status;
}
