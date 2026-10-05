// SPDX-License-Identifier: GPL-3.0-or-later
// Independent native test oracle; production rules policy lives in NeLisp.
#include <gtk/gtk.h>
#include <glib/gstdio.h>
#include <windows.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include "settings.h"
#include "text-settings.h"
#include "rules-settings.h"
static int count, failures;
static void check(gboolean ok,const char *label) { count++; failures+=!ok; printf("%s %s\n",ok?"PASS":"FAIL",label); }
static RulesRow *find(RulesDoc *d,int section,const char *key) {
 for(guint i=0;i<d->rows->len;i++){ RulesRow*r=g_ptr_array_index(d->rows,i); if(r->section==section && !strcmp(r->key,key))return r;} return NULL;
}
static GtkWidget *make_editor(void) {
 GtkWidget *w=gtk_window_new(); g_object_ref_sink(w);
 gtk_window_set_child(GTK_WINDOW(w),rules_build(w)); return w;
}
static gboolean isolated(void) {
 wchar_t key[512]; settings_registry_path(key,512);
 return (!wcsncmp(key,L"Software\\NativeIME-Tests\\",25) || !wcsncmp(key,L"Software\\NativeIME-test-",24)) && getenv("NELISP_IME_INPUT_RULES") && *getenv("NELISP_IME_INPUT_RULES");
}
static char *base64(const char *s) { return g_base64_encode((const guchar*)s,strlen(s)); }
int rules_parse_selftest(void) {
 if(!isolated())return 2;
 wchar_t path[32768]; extern gboolean rules_config_path(wchar_t*);
 if(!rules_config_path(path))return 2;
 char *text=read_text(path);if(!text)return 2;
 RulesDoc*d=rules_parse(text);g_free(text);
 printf("OPTIONS width=%lld pair=%lld\n",(long long)d->width,(long long)d->pair);
 char *error=base64(d->errors->str);printf("ERROR %s\n",error);g_free(error);
 for(guint i=0;i<d->rows->len;i++) {
  RulesRow*r=g_ptr_array_index(d->rows,i);
  char*k=base64(r->key),*v=base64(r->value),*c=base64(r->closer);
  printf("ROW %lld %s %s %s\n",(long long)r->section,k,v,c);
  g_free(k);g_free(v);g_free(c);
 }
 rules_free(d);return 0;
}
// Used only by the private end-to-end harness; runs the same GTK callbacks as a user edit.
int rules_apply_selftest(void) {
 if(!isolated()){fprintf(stderr,"Private NativeIME-Tests key and rules override required\n");return 2;}
 gtk_init(); GtkWidget*w=make_editor(); RulesEditor*e=g_object_get_data(G_OBJECT(w),"rules-editor");
 gtk_drop_down_set_selected(GTK_DROP_DOWN(e->table),0);
 gtk_editable_set_text(GTK_EDITABLE(e->key),".");
 gtk_editable_set_text(GTK_EDITABLE(e->value),"SUMI ");
 rules_apply_clicked(NULL,e); rules_save_clicked(NULL,e);
 gboolean ok=!e->dirty && find(e->doc,0,".") && !strcmp(find(e->doc,0,".")->value,"SUMI ");
 printf("%s private-sumi-gtk-edit-and-save hooks=0 SendInput=0\n",ok?"PASS":"FAIL");
 gtk_window_destroy(GTK_WINDOW(w)); g_object_unref(w); return ok?0:1;
}
int rules_selftest(void) {
 char*dir=g_dir_make_tmp("sumi-rules-XXXXXX",NULL); if(!dir)return 2;
 char*name=g_build_filename(dir,"input-rules.conf",NULL);
 wchar_t*path=(wchar_t*)g_utf8_to_utf16(name,-1,NULL,NULL,NULL);
 g_setenv("NELISP_IME_INPUT_RULES",name,TRUE);
 const char *fixture="\xef\xbb\xbf# keep comment\r\nwidth = hankaku # width\r\nauto-pair = yes\r\n[symbols-hankaku]\r\n  . = \". \"  # row comment\r\n";
 check(atomic_write(path,fixture),"private-fixture");
 RulesDoc*d=rules_parse(fixture);
 check(d->rows->len==35 && d->errors->len==0 && d->width==0 && d->pair==1,"default-35-rows-and-options");
 char*s=rules_set(d,0,".",".  ","",0);
 check(strstr(s,"  \".\" = \".  \"  # row comment\r\n") && !strncmp(s,fixture,3) && strstr(s,"# keep comment"),"edit-keeps-BOM-CRLF-comments-indent");
 HANDLE old=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,0,NULL);
 BY_HANDLE_FILE_INFORMATION before={0},after={0};GetFileInformationByHandle(old,&before);
 check(rules_save(path,fixture,s)==1,"save-atomic");
 HANDLE now=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,0,NULL);
 GetFileInformationByHandle(now,&after);char bytes[1024]={0};DWORD got=0;ReadFile(old,bytes,sizeof(bytes)-1,&got,NULL);
 check(!strcmp(bytes,fixture) && (before.nFileIndexLow!=after.nFileIndexLow || before.nFileIndexHigh!=after.nFileIndexHigh),"atomic-old-handle-and-file-identity");
 CloseHandle(old);CloseHandle(now);
 check(rules_save(path,fixture,s)==-1,"external-change-conflict");
 old=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ,NULL,OPEN_EXISTING,0,NULL);
 check(rules_save(path,s,s)==1,"noop-no-write-while-locked");
 check(rules_save(path,s,fixture)==0,"failed-replace-preserves-source");CloseHandle(old);
 char*current=read_text(path);check(current && !strcmp(current,s),"failed-replace-retains-current");g_free(current);
 rules_free(d);d=rules_parse(s);g_free(s);
 s=rules_set(d,0,"#","hash # ","",0);RulesDoc*added=rules_parse(s);
 check(added->rows->len==36 && !strcmp(find(added,0,"#")->value,"hash # "),"add-quoted-hash-row");
 char*deleted=rules_set(added,0,"#","","",1);RulesDoc*removed=rules_parse(deleted);
 check(removed->rows->len==35 && !find(removed,0,"#"),"delete-custom-row");
 rules_free(added);rules_free(removed);g_free(deleted);g_free(s);rules_free(d);
 const struct {const char *text,*error;} cases[]={
 {"bad\n","line 1: expected key = value\n"},
 {"width = bad\n","line 1: invalid width\n"},
 {"auto-pair = bad\n","line 1: invalid auto-pair\n"},
 {"width = yes no\n","line 1: expected one option value\n"},
 {"wat = yes\n","line 1: unknown option wat\n"},
 {"[wat]\na = \"x\"\n","line 1: unknown section wat\nline 2: unknown section wat\n"},
 {"[symbols-hankaku]\na = \"x\" \"y\"\n","line 2: wrong number of quoted values\n"},
 {"[symbols-hankaku]\na = x\n","line 2: values must be quoted\n"},
 {"[symbols-hankaku]\n\"\" = \"x\"\n","line 2: empty key\n"},
 {"[symbols-hankaku]\nあ = \"x\"\n","line 2: symbol keys must be ASCII\n"},
 {"[pairs]\na = \"\" \"x\"\n","line 2: empty opener or closer\n"},
 {"a = \"x\\","line 1: unfinished escape\n"},
 {"a = \"x\\n\"\n","line 1: unsupported escape\n"},
 {"a = \"x\n","line 1: unterminated string\n"}};
 for(size_t i=0;i<G_N_ELEMENTS(cases);i++){d=rules_parse(cases[i].text);check(!strcmp(d->errors->str,cases[i].error),cases[i].error);rules_free(d);}
 d=rules_parse("[symbols-hankaku]\n. = \"first\"\n. = \"last\"\n");
 check(!strcmp(find(d,0,".")->value,"last"),"duplicate-last-wins");rules_free(d);
 d=rules_parse("[symbols-hankaku]\ncustom = \"first\" # first\ncustom = \"last\" # last\n");
 s=rules_delete(d,0,"custom");added=rules_parse(s);
 check(!find(added,0,"custom") && strstr(s,"# first") && strstr(s,"# last"),"delete-all-duplicates-keeps-comments");
 rules_free(d);rules_free(added);g_free(s);
 s=rules_option_set(g_strdup("width = hankaku # first\nwidth = \"hankaku\" # last\n[pairs]\n"),"width","zenkaku");
 d=rules_parse(s);check(d->width==1 && d->errors->len==0 && strstr(s,"width = zenkaku # last"),"last-quoted-option-patched");rules_free(d);g_free(s);
 s=rules_option_set(g_strdup("\"[pairs]\"\n"),"auto-pair","no");d=rules_parse(s);
 check(!d->pair && !d->errors->len,"insert-option-before-quoted-section");rules_free(d);g_free(s);
 atomic_write(path,fixture);gtk_init();GtkWidget*w=make_editor();RulesEditor*e=g_object_get_data(G_OBJECT(w),"rules-editor");
 check(!gtk_widget_get_visible(w),"editor-hidden-no-hooks");
 gtk_drop_down_set_selected(GTK_DROP_DOWN(e->width),1);gtk_check_button_set_active(GTK_CHECK_BUTTON(e->pair),FALSE);
 check(e->doc->width==1 && !e->doc->pair && e->dirty,"gtk-width-and-auto-pair");
 gtk_drop_down_set_selected(GTK_DROP_DOWN(e->table),0);
 gtk_editable_set_text(GTK_EDITABLE(e->key),"#");gtk_editable_set_text(GTK_EDITABLE(e->value),"hash # ");
 rules_apply_clicked(NULL,e);check(e->doc->rows->len==36,"gtk-add");rules_save_clicked(NULL,e);
 check(!e->dirty && strstr(e->baseline,"# keep comment"),"gtk-save-comment-preserved");
 gtk_editable_set_text(GTK_EDITABLE(e->key),"#");rules_delete_clicked(NULL,e);check(e->doc->rows->len==35,"gtk-delete");
 gtk_drop_down_set_selected(GTK_DROP_DOWN(e->table),4);
 gtk_editable_set_text(GTK_EDITABLE(e->key),"custom-pair");gtk_editable_set_text(GTK_EDITABLE(e->value),"<");gtk_editable_set_text(GTK_EDITABLE(e->closer),">");
 rules_apply_clicked(NULL,e);check(find(e->doc,4,"custom-pair") && !strcmp(find(e->doc,4,"custom-pair")->closer,">"),"gtk-add-bracket-pair");
 gtk_editable_set_text(GTK_EDITABLE(e->key),"custom-pair");gtk_editable_set_text(GTK_EDITABLE(e->value),"{");gtk_editable_set_text(GTK_EDITABLE(e->closer),"}");
 rules_apply_clicked(NULL,e);check(!strcmp(find(e->doc,4,"custom-pair")->value,"{") && !strcmp(find(e->doc,4,"custom-pair")->closer,"}"),"gtk-edit-bracket-pair");
 gtk_editable_set_text(GTK_EDITABLE(e->key),"custom-pair");rules_delete_clicked(NULL,e);check(!find(e->doc,4,"custom-pair"),"gtk-delete-bracket-pair");
 atomic_write(path,"width = hankaku\ninvalid\n");rules_watch(e);check(e->conflict && e->dirty,"gtk-dirty-external-conflict");rules_save_clicked(NULL,e);check(e->dirty,"gtk-conflict-save-rejected");
 rules_reload_clicked(NULL,e);check(!e->dirty && e->doc->width==0 && strstr(e->doc->errors->str,"line 2:"),"gtk-reload-validation");
 atomic_write(path,"width = zenkaku\n");rules_watch(e);check(e->doc->width==1 && !e->dirty,"gtk-clean-external-auto-reload");
 gtk_window_destroy(GTK_WINDOW(w));g_object_unref(w);
 while(g_main_context_iteration(NULL,FALSE)){}
 g_remove(name);g_rmdir(dir);g_free(path);g_free(name);g_free(dir);
 printf("RULES-SELFTEST-%s checks=%d failures=%d hooks=0 SendInput=0\n",failures?"FAIL":"PASS",count,failures);return failures?1:0;
}
