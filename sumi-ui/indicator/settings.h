/* settings.h -- NativeIME registry settings I/O (Phase 3).
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
 * Field-for-field mirror of docs/design/sumi-indicator-settings.md's
 * "Settings schema" tables (Tab dousa/hyouji/jisho/chousei) -- that
 * document is the authority for value names, types, and defaults; this
 * header exists so settings-window construction in main.c (and
 * settings_selftest() in settings.c) share one struct definition rather
 * than three ad hoc copies. No GTK dependency -- pure Win32 registry
 * I/O, directly testable via `sumi-skk-ui.exe --settings-selftest'
 * without a window (see settings.c's settings_selftest()).
 *
 * Registry key resolution: HKEY_CURRENT_USER + either the
 * DDSKK_SETTINGS_KEY environment variable (a path relative to HKCU,
 * e.g. "Software\\NativeIME-PhaseThreeTest") or the production default
 * "Software\\NativeIME" -- see settings.c's settings_key_path(). Every
 * function below (load/save/delete_all) resolves the key through that
 * single function, so DDSKK_SETTINGS_KEY reliably confines ALL registry
 * I/O, including verify-settings.ps1's disposable-key test, away from
 * the real HKCU\Software\NativeIME the production DLL reads.
 */

#pragma once

#include <glib.h> /* gboolean -- the only non-libc dependency; no GTK/gdk/cairo */
#include <stdint.h>
#include <wchar.h>

#define SETTINGS_STR_LEN 260 /* MAX_PATH-sized; covers host/path/engine fields */

typedef struct {
  /* Tab 動作 (behavior) */
  wchar_t engine[SETTINGS_STR_LEN];   /* Engine, SZ -- which conversion the IME uses */
  /* Settings that belong to one engine, stored under
   * <key>\\Engines\\<engine id> rather than beside the shared values,
   * so two engines can use the same name without colliding.  Loaded and
   * saved for the currently selected engine only: switching engines in
   * the UI reloads this group from the newly selected engine subkey. */
  int32_t engine_okuri_auto;          /* ddskk: OkuriAuto, DWORD 0/1 */
  int32_t engine_candidate_limit;     /* lattice: CandidateLimit, DWORD 1..30 */
  int32_t engine_learning;            /* lattice: Learning, DWORD 0/1 */
  int32_t initial_kana_mode;          /* InitialKanaMode, DWORD: 1=かな(hiragana) 0=英数(latin) */
  /* CorvusSKK-modeled behavior toggles, DWORD 0/1, default 0. These take
   * effect only via engine restart (the host bridges them to the
   * engine's env at spawn -- see engine-restart handling in main.c's
   * on_restart_engine_clicked()), same as any other registry value here;
   * they are not read live by the running engine session. */
  int32_t behavior_okuri_strictly;    /* BehaviorOkuriStrictly: 送り仮名が一致した候補を優先する */
  int32_t behavior_delete_okuri_on_cancel; /* BehaviorDeleteOkuriOnCancel: 取消のとき送り仮名を削除する */
  int32_t behavior_add_katakana_cand; /* BehaviorAddKatakanaCand: 候補に片仮名変換を追加する */
  int32_t behavior_learn_disabled;    /* BehaviorLearnDisabled: 学習しない（プライベートモード） */

  /* Tab 表示 (display) */
  int32_t mode_indicator;             /* ModeIndicator, DWORD 0/1 */
  int32_t mode_indicator_ms;          /* ModeIndicatorMs, DWORD 1..60000 */
  int32_t mode_indicator_scale;       /* ModeIndicatorScale, DWORD 50..300 */
  int64_t color_kana;                 /* ModeColorKana, DWORD packed 0xRRGGBB */
  int64_t color_katakana;             /* ModeColorKatakana */
  int64_t color_wide_latin;           /* ModeColorWideLatin */
  int64_t color_latin;                /* ModeColorLatin */
  int64_t color_abbrev;               /* ModeColorAbbrev (design doc default is undecided; see settings.c) */

  /* Tab 辞書 (dictionary) */
  int32_t skkserv_enable;             /* SkkServEnable, DWORD 0/1 */
  wchar_t skkserv_host[SETTINGS_STR_LEN]; /* SkkServHost, SZ */
  int32_t skkserv_port;               /* SkkServPort, DWORD 1..65535 */
  wchar_t user_jisyo_path[SETTINGS_STR_LEN]; /* UserJisyoPath, SZ */
  int32_t user_jisyo_batch;           /* UserJisyoBatch, DWORD 1..100 */

  /* Tab 調整 (maintenance) */
  int32_t idle_gc_ms;                 /* IdleGcMs, DWORD 100..60000 */
  int32_t dll_debug;                  /* DllDebug, DWORD 0/1 */
} Settings;

/* Fills S with docs/design/sumi-indicator-settings.md's schema-table
 * defaults. Never touches the registry. */
void settings_defaults(Settings *s);

/* Loads S from the resolved registry key, falling back field-by-field to
 * settings_defaults() for any value that is absent (first run) or of
 * the wrong registry type (corrupt). Always returns TRUE -- a missing
 * key/value is the expected first-run condition, not a failure; only a
 * true API-level error is possible to hit here and even that degrades
 * to defaults for the affected field rather than aborting the whole
 * load, so the caller always gets a fully-populated Settings back. */
gboolean settings_load(Settings *s);

/* Writes every field of S to the resolved registry key, including
 * `engine' now that the engine process hosts more than DDSKK; the
 * engine-scoped fields go under the selected engine's own subkey.
 * (Formerly `engine' was left unwritten
 * (read-only, per docs/design/sumi-indicator-settings.md's Tab 動作
 * table -- this UI never owns that value). RegSetKeyValueW creates the
 * key if it does not already exist. Returns TRUE only if every write
 * succeeded; attempts every field regardless (best-effort), so a
 * partial failure still applies whatever did succeed. */
gboolean settings_save(const Settings *s);

/* Deletes the resolved registry key and everything under it. Testing-
 * only: never called from the settings window UI, only from
 * settings_selftest()'s own cleanup and from verify-settings.ps1's
 * belt-and-suspenders cleanup. Like every other function here, goes
 * through the same DDSKK_SETTINGS_KEY-aware resolution as load/save. */
gboolean settings_delete_all(void);

/* TRUE when HKCU\...\ExperimentalEngines is a non-zero DWORD.  Engines
 * whose input model does not yet match DDSKK's are hidden from the
 * settings window unless this is on: selecting one of them broke live
 * input once (the composition never advanced, so every further keystroke
 * overwrote the last), and an engine that cannot be typed with must not
 * be offered as if it could.  Not part of Settings, so settings_save()
 * never writes it back. */
gboolean settings_experimental_engines(void);

/* Reloads only the engine-scoped fields of S from ENGINE_ID's subkey,
 * leaving every shared field untouched.  The settings window calls this
 * when the engine dropdown changes, so each engine's page shows what is
 * stored for that engine rather than the previous one's values. */
void settings_load_engine_scope(Settings *s, const wchar_t *engine_id);

/* TRUE iff every field of A and B is identical (wcscmp for the wide-
 * string fields). Used only by settings_selftest(). */
gboolean settings_equal(const Settings *a, const Settings *b);

/* Runs the full load/save round-trip self-test described in the Phase 3
 * task brief ("write defaults, read back, mutate each value type, read
 * back, print PASS/FAIL lines") against the resolved registry key, then
 * deletes it. REFUSES to run (prints an error, returns 1) unless the
 * DDSKK_SETTINGS_KEY environment variable is set to a non-empty value
 * -- a deliberate hard safety guard, independent of and in addition to
 * verify-settings.ps1 itself always setting it, so this destructive
 * self-test can never mutate or delete the production
 * HKCU\Software\NativeIME key even if invoked directly by mistake.
 * Prints "PASS <name>"/"FAIL <name>" lines and a final "SELFTEST-PASS"/
 * "SELFTEST-FAIL (N failures)" line to stdout; returns 0 iff every
 * check passed. */
int settings_selftest(void);
