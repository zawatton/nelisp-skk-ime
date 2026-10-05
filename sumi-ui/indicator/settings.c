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
void settings_registry_path(wchar_t *buf, size_t cap) {
  DWORD n = GetEnvironmentVariableW(L"NATIVEIME_REGISTRY_KEY", buf, (DWORD)cap);
  if (!n) n = GetEnvironmentVariableW(L"DDSKK_SETTINGS_KEY", buf, (DWORD)cap);
  if (n == 0 || n >= cap) {
    wcsncpy(buf, SETTINGS_DEFAULT_KEY, cap - 1);
    buf[cap - 1] = L'\0';
  }
}

/* -------------------------------------------------------------------- */
/* Registry primitives are implemented in registry.el. Field defaults,
 * mappings and load/save orchestration are in settings-logic.el. */

gboolean reg_get_dword(const wchar_t *key_path, const wchar_t *value,
                       int32_t default_value, int32_t *out);
gboolean reg_get_sz(const wchar_t *key_path, const wchar_t *value,
                    const wchar_t *default_value, wchar_t *out, size_t out_cap);
gboolean reg_set_dword(const wchar_t *key_path, const wchar_t *value, int32_t v);
gboolean reg_set_color(const wchar_t *key_path, const wchar_t *value,
                       int32_t v, int32_t fallback);
gboolean reg_set_sz(const wchar_t *key_path, const wchar_t *value, const wchar_t *v);

/* Path of the subkey holding one engine's own settings.  Derived from
 * the same resolved base as everything else, so DDSKK_SETTINGS_KEY keeps
 * confining these writes too. */
void engine_key_path(wchar_t *buf, size_t cap, const wchar_t *engine_id) {
  wchar_t base[512];
  settings_registry_path(base, 512);
  _snwprintf(buf, cap, L"%ls\\Engines\\%ls", base,
             (engine_id && *engine_id) ? engine_id : L"ddskk");
  buf[cap - 1] = L'\0';
}

/* -------------------------------------------------------------------- */
gboolean settings_delete_all(void) {
  wchar_t key[512];
  settings_registry_path(key, 512);
  LSTATUS st = RegDeleteTreeW(HKEY_CURRENT_USER, key);
  /* ERROR_FILE_NOT_FOUND (key already absent) counts as success -- the
   * caller wants "this key is gone", not "this key existed". */
  return st == ERROR_SUCCESS || st == ERROR_FILE_NOT_FOUND;
}

gboolean settings_equal(const Settings *a, const Settings *b) {
  return wcscmp(a->engine, b->engine) == 0 &&
         a->engine_okuri_auto == b->engine_okuri_auto &&
         a->engine_candidate_limit == b->engine_candidate_limit &&
         a->engine_learning == b->engine_learning &&
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
  DWORD guard_n = GetEnvironmentVariableW(L"NATIVEIME_REGISTRY_KEY", guard, 512);
  if (!guard_n) guard_n = GetEnvironmentVariableW(L"DDSKK_SETTINGS_KEY", guard, 512);
  if (guard_n == 0 || guard_n >= 512 ||
      _wcsicmp(guard, SETTINGS_DEFAULT_KEY) == 0) {
    fprintf(stderr,
            "settings_selftest: refusing to run -- DDSKK_SETTINGS_KEY is not "
            "set. This self-test writes, mutates and deletes a registry key; "
            "set DDSKK_SETTINGS_KEY to a disposable key (e.g. "
            "Software\\\\NativeIME-PhaseThreeTest) before running "
            "--settings-selftest so it never touches the real "
            "HKCU\\Software\\NativeIME.\n");
    return 1;
  }

  wchar_t effective_key[512];
  settings_registry_path(effective_key, 512);
  if (_wcsnicmp(effective_key, L"Software\\NativeIME-", 19) != 0) {
    fprintf(stderr, "settings_selftest: resolved key is not a disposable NativeIME-* identity\n");
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
