// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <gtk/gtk.h>
#include <stdint.h>
#include <windows.h>
#include "rules-settings.h"
typedef struct { char*source;GString*errors;GPtrArray*rows;int64_t enabled,layout,pass;GPtrArray*excludes; } EditorDoc;
typedef struct { RulesEditor prefix;GtkWidget*pass,*excludes,*details;uint64_t*capture;GtkWidget*window;uint64_t reserved; } KeymapEditor;
_Static_assert(sizeof(EditorDoc)==56 && offsetof(EditorDoc,excludes)==48,"AOT EditorDoc");
_Static_assert(sizeof(KeymapEditor)==176 && offsetof(KeymapEditor,capture)==152,"AOT KeymapEditor");
EditorDoc*editor_parse(const char*);void editor_free(EditorDoc*);
uint64_t editor_key(const char*);uint64_t*editor_chord(const char*);
char*editor_set(EditorDoc*,int64_t,const char*,const char*,int64_t);
char*editor_exclusions(const char*,const char*);
GtkWidget*editor_build(GtkWidget*);void editor_show(GtkWidget*);
void editor_edit(KeymapEditor*,int64_t);void editor_save_clicked(void*,KeymapEditor*);
void editor_reload_clicked(void*,KeymapEditor*);int64_t editor_watch(KeymapEditor*);
int64_t editor_feed(uint64_t*,uint64_t,int64_t,int64_t,int64_t,uint64_t);
void editor_capture_done(KeymapEditor*);
void editor_capture_stop(KeymapEditor*);
void editor_source_clicked(void*,KeymapEditor*);void editor_target_clicked(void*,KeymapEditor*);
void editor_immediate_clicked(void*,KeymapEditor*);
void editor_text_set(GtkWidget*,const char*);char*editor_text_get(GtkWidget*);
int editor_selftest(void);int editor_apply_selftest(void);
