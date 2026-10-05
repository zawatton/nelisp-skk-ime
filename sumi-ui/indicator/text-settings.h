#pragma once
#include <glib.h>
#include <windows.h>
typedef struct { int width, auto_pair, enabled, layout; } TextSettings;
void text_settings_load(TextSettings *s);
gboolean text_settings_save(const TextSettings *s, TextSettings *baseline);
gboolean text_settings_open(gboolean rules, gboolean editor);
char *text_settings_status(void);
int text_settings_selftest(void);
