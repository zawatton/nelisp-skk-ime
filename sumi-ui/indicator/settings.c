/* settings.c -- see settings.h.
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
 */

#include "settings.h"

#define WIN32_LEAN_AND_MEAN
/* RegGetValueW/RegSetKeyValueW/RegDeleteTreeW are gated behind
 * _WIN32_WINNT >= 0x0600 (Vista) in mingw64's <winreg.h>; nothing else
 * in this file needs an older target, so bump it explicitly rather than
 * rely on whatever default mingw64 gcc happens to ship. */
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0600
#endif
#include <windows.h>

#include <stdio.h>
#include <string.h>
#include <wchar.h>

/* -------------------------------------------------------------------- */
/* Key resolution. */

#define SETTINGS_DEFAULT_KEY L"Software\\NativeIME"

/* Resolves the HKCU-relative subkey path into BUF (capacity CAP wide
 * chars): DDSKK_SETTINGS_KEY if set and non-empty, else
 * SETTINGS_DEFAULT_KEY. Every registry-touching function below (load,
 * save, delete_all) calls this and only this to find its key -- the
 * single choke point that makes DDSKK_SETTINGS_KEY reliably confine all
 * I/O away from the production key during testing. */
static void settings_key_path(wchar_t *buf, size_t cap) {
  DWORD n = GetEnvironmentVariableW(L"DDSKK_SETTINGS_KEY", buf, (DWORD)cap);
  if (n == 0 || n >= cap) {
    wcsncpy(buf, SETTINGS_DEFAULT_KEY, cap - 1);
    buf[cap - 1] = L'\0';
  }
}

/* -------------------------------------------------------------------- */
/* Low-level registry helpers. All go through settings_key_path() so
 * DDSKK_SETTINGS_KEY governs every read/write uniformly. RegGetValueW/
 * RegSetKeyValueW (both available since Vista) are used instead of the
 * classic RegOpenKeyEx+RegQueryValueEx/RegCreateKeyEx+RegSetValueEx
 * pairs specifically because they collapse "open-or-fail" and "create-
 * if-missing" into one call each -- settings_save() must silently
 * create the key on first run, and settings_load() must silently treat
 * a missing key exactly like a missing value (both fall back to the
 * same per-field default), so the simpler single-call API removes an
 * entire class of "did I remember to create the key first" bugs. */

static gboolean reg_get_dword(const wchar_t *key_path, const wchar_t *value,
                              int32_t default_value, int32_t *out) {
  DWORD data = 0;
  DWORD size = sizeof(data);
  LSTATUS st = RegGetValueW(HKEY_CURRENT_USER, key_path, value,
                            RRF_RT_REG_DWORD, NULL, &data, &size);
  if (st != ERROR_SUCCESS) {
    *out = default_value;
    return TRUE;
  }
  *out = (int32_t)data;
  return TRUE;
}

static gboolean reg_get_sz(const wchar_t *key_path, const wchar_t *value,
                           const wchar_t *default_value, wchar_t *out, size_t out_cap) {
  wchar_t buf[SETTINGS_STR_LEN];
  DWORD size = sizeof(buf);
  LSTATUS st = RegGetValueW(HKEY_CURRENT_USER, key_path, value,
                            RRF_RT_REG_SZ, NULL, buf, &size);
  if (st != ERROR_SUCCESS) {
    wcsncpy(out, default_value, out_cap - 1);
    out[out_cap - 1] = L'\0';
    return TRUE;
  }
  wcsncpy(out, buf, out_cap - 1);
  out[out_cap - 1] = L'\0';
  return TRUE;
}

static gboolean reg_set_dword(const wchar_t *key_path, const wchar_t *value, int32_t v) {
  DWORD data = (DWORD)v;
  return RegSetKeyValueW(HKEY_CURRENT_USER, key_path, value, REG_DWORD,
                         &data, sizeof(data)) == ERROR_SUCCESS;
}

static gboolean reg_set_sz(const wchar_t *key_path, const wchar_t *value, const wchar_t *v) {
  return RegSetKeyValueW(HKEY_CURRENT_USER, key_path, value, REG_SZ,
                         v, (DWORD)((wcslen(v) + 1) * sizeof(wchar_t))) == ERROR_SUCCESS;
}

/* -------------------------------------------------------------------- */
/* Defaults: docs/design/sumi-indicator-settings.md's schema tables,
 * verbatim. ModeColorAbbrev's design-doc default is literally "--"
 * (undecided) -- reuses the same #808080 gray Phase 2's mode-logic.el
 * used for the same reason (see mode-logic.el's header comment); this
 * is the one field the design doc itself does not fully specify. */

void settings_defaults(Settings *s) {
  wcsncpy(s->engine, L"ddskk", SETTINGS_STR_LEN - 1);
  s->engine[SETTINGS_STR_LEN - 1] = L'\0';
  s->initial_kana_mode = 1;
  s->behavior_okuri_strictly = 0;
  s->behavior_delete_okuri_on_cancel = 0;
  s->behavior_add_katakana_cand = 0;
  s->behavior_learn_disabled = 0;

  s->mode_indicator = 1;
  s->mode_indicator_ms = 3000;
  s->mode_indicator_scale = 100;
  s->color_kana = 0xC02020;
  s->color_katakana = 0x00C000;
  s->color_wide_latin = 0x8000C0;
  s->color_latin = 0x1E5AA8;
  s->color_abbrev = 0x808080; /* design doc: undecided; see comment above */

  s->skkserv_enable = 1;
  wcsncpy(s->skkserv_host, L"127.0.0.1", SETTINGS_STR_LEN - 1);
  s->skkserv_host[SETTINGS_STR_LEN - 1] = L'\0';
  s->skkserv_port = 1179;
  wcsncpy(s->user_jisyo_path, L"%LOCALAPPDATA%\\DDSKK\\user-jisyo.utf8", SETTINGS_STR_LEN - 1);
  s->user_jisyo_path[SETTINGS_STR_LEN - 1] = L'\0';
  s->user_jisyo_batch = 10;

  s->idle_gc_ms = 800;
  s->dll_debug = 0;
}

/* -------------------------------------------------------------------- */

gboolean settings_load(Settings *s) {
  wchar_t key[512];
  settings_key_path(key, 512);
  Settings d;
  settings_defaults(&d);

  reg_get_sz(key, L"Engine", d.engine, s->engine, SETTINGS_STR_LEN);
  reg_get_dword(key, L"InitialKanaMode", d.initial_kana_mode, &s->initial_kana_mode);
  reg_get_dword(key, L"BehaviorOkuriStrictly", d.behavior_okuri_strictly, &s->behavior_okuri_strictly);
  reg_get_dword(key, L"BehaviorDeleteOkuriOnCancel", d.behavior_delete_okuri_on_cancel,
                &s->behavior_delete_okuri_on_cancel);
  reg_get_dword(key, L"BehaviorAddKatakanaCand", d.behavior_add_katakana_cand, &s->behavior_add_katakana_cand);
  reg_get_dword(key, L"BehaviorLearnDisabled", d.behavior_learn_disabled, &s->behavior_learn_disabled);

  reg_get_dword(key, L"ModeIndicator", d.mode_indicator, &s->mode_indicator);
  reg_get_dword(key, L"ModeIndicatorMs", d.mode_indicator_ms, &s->mode_indicator_ms);
  reg_get_dword(key, L"ModeIndicatorScale", d.mode_indicator_scale, &s->mode_indicator_scale);
  {
    int32_t v;
    reg_get_dword(key, L"ModeColorKana", (int32_t)d.color_kana, &v); s->color_kana = (uint32_t)v;
    reg_get_dword(key, L"ModeColorKatakana", (int32_t)d.color_katakana, &v); s->color_katakana = (uint32_t)v;
    reg_get_dword(key, L"ModeColorWideLatin", (int32_t)d.color_wide_latin, &v); s->color_wide_latin = (uint32_t)v;
    reg_get_dword(key, L"ModeColorLatin", (int32_t)d.color_latin, &v); s->color_latin = (uint32_t)v;
    reg_get_dword(key, L"ModeColorAbbrev", (int32_t)d.color_abbrev, &v); s->color_abbrev = (uint32_t)v;
  }

  reg_get_dword(key, L"SkkServEnable", d.skkserv_enable, &s->skkserv_enable);
  reg_get_sz(key, L"SkkServHost", d.skkserv_host, s->skkserv_host, SETTINGS_STR_LEN);
  reg_get_dword(key, L"SkkServPort", d.skkserv_port, &s->skkserv_port);
  reg_get_sz(key, L"UserJisyoPath", d.user_jisyo_path, s->user_jisyo_path, SETTINGS_STR_LEN);
  reg_get_dword(key, L"UserJisyoBatch", d.user_jisyo_batch, &s->user_jisyo_batch);

  reg_get_dword(key, L"IdleGcMs", d.idle_gc_ms, &s->idle_gc_ms);
  reg_get_dword(key, L"DllDebug", d.dll_debug, &s->dll_debug);
  return TRUE;
}

gboolean settings_save(const Settings *s) {
  wchar_t key[512];
  settings_key_path(key, 512);
  gboolean ok = TRUE;

  /* `engine' is deliberately NOT written -- read-only per the design
   * doc's Tab 動作 table; this UI does not own that value. */
  ok = reg_set_dword(key, L"InitialKanaMode", s->initial_kana_mode) && ok;
  ok = reg_set_dword(key, L"BehaviorOkuriStrictly", s->behavior_okuri_strictly) && ok;
  ok = reg_set_dword(key, L"BehaviorDeleteOkuriOnCancel", s->behavior_delete_okuri_on_cancel) && ok;
  ok = reg_set_dword(key, L"BehaviorAddKatakanaCand", s->behavior_add_katakana_cand) && ok;
  ok = reg_set_dword(key, L"BehaviorLearnDisabled", s->behavior_learn_disabled) && ok;

  ok = reg_set_dword(key, L"ModeIndicator", s->mode_indicator) && ok;
  ok = reg_set_dword(key, L"ModeIndicatorMs", s->mode_indicator_ms) && ok;
  ok = reg_set_dword(key, L"ModeIndicatorScale", s->mode_indicator_scale) && ok;
  ok = reg_set_dword(key, L"ModeColorKana", (int32_t)s->color_kana) && ok;
  ok = reg_set_dword(key, L"ModeColorKatakana", (int32_t)s->color_katakana) && ok;
  ok = reg_set_dword(key, L"ModeColorWideLatin", (int32_t)s->color_wide_latin) && ok;
  ok = reg_set_dword(key, L"ModeColorLatin", (int32_t)s->color_latin) && ok;
  ok = reg_set_dword(key, L"ModeColorAbbrev", (int32_t)s->color_abbrev) && ok;

  ok = reg_set_dword(key, L"SkkServEnable", s->skkserv_enable) && ok;
  ok = reg_set_sz(key, L"SkkServHost", s->skkserv_host) && ok;
  ok = reg_set_dword(key, L"SkkServPort", s->skkserv_port) && ok;
  ok = reg_set_sz(key, L"UserJisyoPath", s->user_jisyo_path) && ok;
  ok = reg_set_dword(key, L"UserJisyoBatch", s->user_jisyo_batch) && ok;

  ok = reg_set_dword(key, L"IdleGcMs", s->idle_gc_ms) && ok;
  ok = reg_set_dword(key, L"DllDebug", s->dll_debug) && ok;
  return ok;
}

gboolean settings_delete_all(void) {
  wchar_t key[512];
  settings_key_path(key, 512);
  LSTATUS st = RegDeleteTreeW(HKEY_CURRENT_USER, key);
  /* ERROR_FILE_NOT_FOUND (key already absent) counts as success -- the
   * caller wants "this key is gone", not "this key existed". */
  return st == ERROR_SUCCESS || st == ERROR_FILE_NOT_FOUND;
}

gboolean settings_equal(const Settings *a, const Settings *b) {
  return wcscmp(a->engine, b->engine) == 0 &&
         a->initial_kana_mode == b->initial_kana_mode &&
         a->behavior_okuri_strictly == b->behavior_okuri_strictly &&
         a->behavior_delete_okuri_on_cancel == b->behavior_delete_okuri_on_cancel &&
         a->behavior_add_katakana_cand == b->behavior_add_katakana_cand &&
         a->behavior_learn_disabled == b->behavior_learn_disabled &&
         a->mode_indicator == b->mode_indicator &&
         a->mode_indicator_ms == b->mode_indicator_ms &&
         a->mode_indicator_scale == b->mode_indicator_scale &&
         a->color_kana == b->color_kana &&
         a->color_katakana == b->color_katakana &&
         a->color_wide_latin == b->color_wide_latin &&
         a->color_latin == b->color_latin &&
         a->color_abbrev == b->color_abbrev &&
         a->skkserv_enable == b->skkserv_enable &&
         wcscmp(a->skkserv_host, b->skkserv_host) == 0 &&
         a->skkserv_port == b->skkserv_port &&
         wcscmp(a->user_jisyo_path, b->user_jisyo_path) == 0 &&
         a->user_jisyo_batch == b->user_jisyo_batch &&
         a->idle_gc_ms == b->idle_gc_ms &&
         a->dll_debug == b->dll_debug;
}

/* -------------------------------------------------------------------- */
/* Self-test. */

static int g_selftest_failures = 0;

static void selftest_check(gboolean cond, const char *name) {
  if (cond) {
    printf("PASS %s\n", name);
  } else {
    printf("FAIL %s\n", name);
    g_selftest_failures++;
  }
  fflush(stdout);
}

int settings_selftest(void) {
  wchar_t guard[512];
  DWORD guard_n = GetEnvironmentVariableW(L"DDSKK_SETTINGS_KEY", guard, 512);
  if (guard_n == 0) {
    fprintf(stderr,
            "settings_selftest: refusing to run -- DDSKK_SETTINGS_KEY is not "
            "set. This self-test writes, mutates and deletes a registry key; "
            "set DDSKK_SETTINGS_KEY to a disposable key (e.g. "
            "Software\\\\NativeIME-PhaseThreeTest) before running "
            "--settings-selftest so it never touches the real "
            "HKCU\\Software\\NativeIME.\n");
    return 1;
  }

  g_selftest_failures = 0;

  /* 1. Save defaults, load back, compare every field. */
  Settings defaults;
  settings_defaults(&defaults);
  selftest_check(settings_save(&defaults), "save-defaults");
  Settings loaded_defaults;
  memset(&loaded_defaults, 0, sizeof(loaded_defaults));
  selftest_check(settings_load(&loaded_defaults), "load-after-save-defaults");
  selftest_check(settings_equal(&defaults, &loaded_defaults), "defaults-roundtrip-equal");

  /* 2. Mutate every field (every registry type this schema uses: DWORD
   * bool, DWORD int, DWORD packed color, SZ string), save, reload,
   * compare -- exercises settings_save()/settings_load() for each type,
   * not just the defaults path. */
  Settings mutated = defaults;
  mutated.initial_kana_mode = 0;
  mutated.behavior_okuri_strictly = 1;
  mutated.behavior_delete_okuri_on_cancel = 1;
  mutated.behavior_add_katakana_cand = 1;
  mutated.behavior_learn_disabled = 1;
  mutated.mode_indicator = 0;
  mutated.mode_indicator_ms = 1234;
  mutated.mode_indicator_scale = 150;
  mutated.color_kana = 0x123456;
  mutated.color_katakana = 0x654321;
  mutated.color_wide_latin = 0xABCDEF;
  mutated.color_latin = 0xFEDCBA;
  mutated.color_abbrev = 0x00FF00;
  mutated.skkserv_enable = 0;
  wcsncpy(mutated.skkserv_host, L"192.168.1.1", SETTINGS_STR_LEN - 1);
  mutated.skkserv_host[SETTINGS_STR_LEN - 1] = L'\0';
  mutated.skkserv_port = 12345;
  wcsncpy(mutated.user_jisyo_path, L"C:\\selftest\\jisyo.utf8", SETTINGS_STR_LEN - 1);
  mutated.user_jisyo_path[SETTINGS_STR_LEN - 1] = L'\0';
  mutated.user_jisyo_batch = 42;
  mutated.idle_gc_ms = 5000;
  mutated.dll_debug = 1;

  selftest_check(settings_save(&mutated), "save-mutated");
  Settings loaded_mutated;
  memset(&loaded_mutated, 0, sizeof(loaded_mutated));
  selftest_check(settings_load(&loaded_mutated), "load-after-save-mutated");
  selftest_check(settings_equal(&mutated, &loaded_mutated), "mutated-roundtrip-equal");

  /* 3. Missing-value fallback: delete the whole key, then load -- every
   * field should fall back to settings_defaults(). */
  selftest_check(settings_delete_all(), "delete-key");
  Settings loaded_after_delete;
  memset(&loaded_after_delete, 0, sizeof(loaded_after_delete));
  selftest_check(settings_load(&loaded_after_delete), "load-after-delete-succeeds");
  selftest_check(settings_equal(&defaults, &loaded_after_delete), "missing-falls-back-to-defaults");

  /* Cleanup: settings_save() during step 2 recreated the key, and step
   * 3 already deleted it once, but be certain nothing is left behind
   * regardless of which checks above failed. */
  settings_delete_all();

  printf("SELFTEST-%s (%d failures)\n", g_selftest_failures == 0 ? "PASS" : "FAIL",
         g_selftest_failures);
  fflush(stdout);
  return g_selftest_failures == 0 ? 0 : 1;
}
