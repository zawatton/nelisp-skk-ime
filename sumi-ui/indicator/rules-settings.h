#pragma once
// SPDX-License-Identifier: GPL-3.0-or-later
#include <gtk/gtk.h>
#include <windows.h>
#include <stdint.h>
#include <stddef.h>
typedef struct { int64_t section; char *key,*value,*closer; int64_t start,end,tail,line; } RulesRow;
typedef struct { char *source; GString *errors; GPtrArray *rows; int64_t width,pair; } RulesDoc;
typedef struct {
 RulesDoc *doc; char *baseline; wchar_t *path;
 GtkWidget *page,*list,*table,*key,*value,*closer,*width,*pair,*status;
 uint64_t timer,loading,dirty,conflict;
} RulesEditor;
_Static_assert(sizeof(RulesDoc)==40 && offsetof(RulesDoc,pair)==32,"AOT RulesDoc");
_Static_assert(sizeof(RulesRow)==64 && offsetof(RulesRow,line)==56,"AOT RulesRow");
_Static_assert(sizeof(RulesEditor)==128 && offsetof(RulesEditor,dirty)==112,"AOT RulesEditor");
RulesDoc *rules_parse(const char*); void rules_free(RulesDoc*);
char *rules_set(RulesDoc*,int64_t,const char*,const char*,const char*,int64_t);
char *rules_delete(RulesDoc*,int64_t,const char*);
char *rules_option_set(char*,const char*,const char*);
int64_t rules_save(const wchar_t*,const char*,const char*);
GtkWidget *rules_build(GtkWidget*); void rules_show(GtkWidget*);
void rules_apply_clicked(void*,RulesEditor*); void rules_delete_clicked(void*,RulesEditor*);
void rules_save_clicked(void*,RulesEditor*); void rules_reload_clicked(void*,RulesEditor*);
int64_t rules_watch(RulesEditor*);
gboolean atomic_write(const wchar_t*,const char*); char *read_text(const wchar_t*);
