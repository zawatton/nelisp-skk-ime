// SPDX-License-Identifier: GPL-3.0-or-later
// Independent native oracle. The actual UI actions and capture policy are AOT.
#include "editor-settings.h"
#include "settings.h"
#include <glib/gstdio.h>
#include <stdio.h>
#include <string.h>
static int checks,failures;
static void check(gboolean ok,const char*name){checks++;if(!ok)failures++;printf("%s %s\n",ok?"PASS":"FAIL",name);}
static GtkWidget*make(void){GtkWidget*w=gtk_window_new();g_object_ref_sink(w);gtk_window_set_child(GTK_WINDOW(w),editor_build(w));return w;}
static RulesRow*find(EditorDoc*d,const char*source){for(guint i=0;i<d->rows->len;i++){RulesRow*r=g_ptr_array_index(d->rows,i);if(!g_ascii_strcasecmp(r->key,source))return r;}return NULL;}
static void source(KeymapEditor*e,const char*s,const char*t){gtk_drop_down_set_selected(GTK_DROP_DOWN(e->prefix.table),strchr(s,'+')?1:0);gtk_editable_set_text(GTK_EDITABLE(e->prefix.key),s);gtk_editable_set_text(GTK_EDITABLE(e->prefix.value),t);}

extern gboolean atomic_write(const wchar_t*,const char*);
static void capture_reset(KeymapEditor*e,gboolean target){memset(e->capture,0,640);e->capture[0]=1;e->capture[3]=100;e->capture[5]=target;}
static int64_t feed(KeymapEditor*e,unsigned vk,unsigned scan,gboolean up){return editor_feed(e->capture,vk|((uint64_t)scan<<8),up,FALSE,TRUE,101);}
int editor_apply_selftest(void){
 wchar_t key[512];settings_registry_path(key,512);
 if(wcsncmp(key,L"Software\\NativeIME-Tests\\",25)||!getenv("NELISP_IME_KEYMAP_FILE"))return 2;
 gtk_init();GtkWidget*w=make();KeymapEditor*e=g_object_get_data(G_OBJECT(w),"keymap-editor");
 source(e,"A","C");editor_edit(e,0);editor_save_clicked(NULL,e);
 gboolean ok=!e->prefix.dirty && find((EditorDoc*)e->prefix.doc,"A") && !strcmp(find((EditorDoc*)e->prefix.doc,"A")->value,"C");
 printf("%s private-sumi-keymap-edit-save hooks=0 SendInput=0\n",ok?"PASS":"FAIL");gtk_window_destroy(GTK_WINDOW(w));g_object_unref(w);return ok?0:1;
}
int editor_selftest(void){
 char*dir=g_dir_make_tmp("sumi-editor-XXXXXX",NULL);if(!dir)return 2;
 char*name=g_build_filename(dir,"keymap.conf",NULL);wchar_t*path=(wchar_t*)g_utf8_to_utf16(name,-1,NULL,NULL,NULL);
 g_setenv("NATIVEIME_REGISTRY_KEY","Software\\NativeIME-Tests\\SN4-selftest",TRUE);g_setenv("NELISP_IME_KEYMAP_FILE",name,TRUE);
 const char*fixture="\xef\xbb\xbf# fixture comment\r\nenabled = yes\r\nlayout = os\r\npass-injected = yes\r\nunknown = keep\r\n[keys]\r\nCapsLock = LCtrl # note\r\n[shortcuts]\r\nLAlt+Space = ime-toggle\r\nCtrl+Space = LWin+Space\r\n[exclude]\r\nmstsc.exe # keep exclusion\r\n";
 check(atomic_write(path,fixture),"fixture");EditorDoc*d=editor_parse(fixture);
 check(d->enabled&&d->layout==0&&d->pass&&d->rows->len==3&&d->excludes->len==1,"options-keys-shortcuts-exclusions");
 check(strstr(d->errors->str,"line 5:")!=NULL,"unknown-option-line-number");editor_free(d);
 check((editor_key("CapsLock")&255)==VK_CAPITAL,"key-name");check((editor_key("sc:e0:0x1D")&0x1ff00)==0x11d00,"extended-scan");check((editor_key("vk:0x19")&255)==0x19,"raw-vk");check(editor_key("BadKey")==0,"unknown-key-rejected");
 check(editor_key("F24")==0x87&&editor_key("F25")==0,"function-key-range");
 d=editor_parse("[shortcuts]\nA+B=C\n[keys]\nA=B\na=C\n");check(d->rows->len==1&&strstr(d->errors->str,"prefix must be a modifier")&&strstr(d->errors->str,"duplicate source"),"invalid-prefix-and-canonical-duplicate");editor_free(d);
 gtk_init();GtkWidget*w=make();KeymapEditor*e=g_object_get_data(G_OBJECT(w),"keymap-editor");
 check(!gtk_widget_get_visible(w),"hidden-editor");source(e,"A","B");editor_edit(e,0);check(((EditorDoc*)e->prefix.doc)->rows->len==4,"gtk-add");
 HANDLE old=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,0,NULL);
 BY_HANDLE_FILE_INFORMATION before={0},after={0};GetFileInformationByHandle(old,&before);
 editor_save_clicked(NULL,e);check(!e->prefix.dirty,"gtk-save");HANDLE current=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,0,NULL);GetFileInformationByHandle(current,&after);
 char bytes[2048]={0};DWORD got=0;ReadFile(old,bytes,sizeof(bytes)-1,&got,NULL);check(!strcmp(bytes,fixture)&&(before.nFileIndexLow!=after.nFileIndexLow||before.nFileIndexHigh!=after.nFileIndexHigh),"atomic-old-handle-and-file-identity");CloseHandle(old);CloseHandle(current);
 editor_reload_clicked(NULL,e);source(e,"A","C");editor_edit(e,0);editor_save_clicked(NULL,e);editor_reload_clicked(NULL,e);
 check(find((EditorDoc*)e->prefix.doc,"A")&&!strcmp(find((EditorDoc*)e->prefix.doc,"A")->value,"C"),"gtk-edit-immediate-roundtrip");
 source(e,"A","C");editor_edit(e,1);editor_save_clicked(NULL,e);editor_reload_clicked(NULL,e);check(((EditorDoc*)e->prefix.doc)->rows->len==3,"gtk-delete-roundtrip");
 check(strstr(e->prefix.baseline,"# fixture comment")&&strstr(e->prefix.baseline,"unknown = keep")&&strstr(e->prefix.baseline,"# note"),"comments-and-unknown-kept");
 source(e,"F12","ime-on");gtk_drop_down_set_selected(GTK_DROP_DOWN(e->prefix.table),1);editor_edit(e,0);
 check(!find((EditorDoc*)e->prefix.doc,"F12"),"single-key-shortcut-rejected-like-remapper");
 gtk_check_button_set_active(GTK_CHECK_BUTTON(e->prefix.width),FALSE);gtk_drop_down_set_selected(GTK_DROP_DOWN(e->prefix.pair),2);gtk_check_button_set_active(GTK_CHECK_BUTTON(e->pass),FALSE);
 editor_text_set(e->excludes,"editor.exe\neditor.exe\n");editor_save_clicked(NULL,e);
 d=(EditorDoc*)e->prefix.doc;check(!d->enabled&&d->layout==2&&!d->pass,"enabled-layout-pass-roundtrip");
 check(d->excludes->len==1&&!strcmp(g_ptr_array_index(d->excludes,0),"editor.exe")&&strstr(e->prefix.baseline,"# keep exclusion"),"exclusions-dedup-comments-kept");
 atomic_write(path,"enabled = yes\n[keys]\nB=C\n");editor_watch(e);check(find((EditorDoc*)e->prefix.doc,"B")!=NULL,"clean-external-reload");
 source(e,"A","D");editor_edit(e,0);atomic_write(path,"enabled = no\n[keys]\nB=D\n");editor_watch(e);check(e->prefix.conflict&&e->prefix.dirty,"dirty-external-conflict");editor_save_clicked(NULL,e);check(e->prefix.dirty,"conflict-not-overwritten");editor_reload_clicked(NULL,e);check(!e->prefix.dirty,"explicit-reload");
 atomic_write(path,fixture);editor_reload_clicked(NULL,e);
 capture_reset(e,FALSE);feed(e,VK_CAPITAL,0x3a,FALSE);feed(e,VK_SPACE,0x39,FALSE);feed(e,VK_SPACE,0x39,TRUE);feed(e,VK_CAPITAL,0x3a,TRUE);editor_capture_done(e);
 check(!strcmp(gtk_editable_get_text(GTK_EDITABLE(e->prefix.key)),"Ctrl+Space"),"physical-capslock-logical-modifier-shortcut");
 capture_reset(e,FALSE);check(feed(e,VK_RSHIFT,0x36,TRUE)==0,"pre-capture-release-passes");
 check(feed(e,VK_LCONTROL,0x1d,FALSE)==1,"capture-modifier-down");check(feed(e,'A',0x1e,FALSE)==1,"capture-key-down");check(feed(e,'A',0x1e,TRUE)==1,"capture-key-up");check(feed(e,VK_LCONTROL,0x1d,TRUE)==1,"capture-modifier-up");
 editor_capture_done(e);check(!g_ascii_strcasecmp(gtk_editable_get_text(GTK_EDITABLE(e->prefix.key)),"lctrl+A"),"inspector-source-chord");
 check(strstr(gtk_label_get_text(GTK_LABEL(e->details)),"Scan: 0x1E  VK: 0x41")&&strstr(gtk_label_get_text(GTK_LABEL(e->details)),"現在の登録"),"inspector-scan-vk-characters-mapping");
 capture_reset(e,TRUE);check(feed(e,'D',0x20,FALSE)==1&&feed(e,'D',0x20,TRUE)==1,"capture-target");editor_capture_done(e);check(find((EditorDoc*)e->prefix.doc,"lctrl+A")&&!strcmp(find((EditorDoc*)e->prefix.doc,"lctrl+A")->value,"D"),"direct-remap-target-saved");
 capture_reset(e,FALSE);feed(e,VK_LCONTROL,0x1d,FALSE);feed(e,VK_SPACE,0x39,FALSE);feed(e,VK_SPACE,0x39,TRUE);feed(e,VK_LCONTROL,0x1d,TRUE);editor_capture_done(e);
 check(!strcmp(gtk_editable_get_text(GTK_EDITABLE(e->prefix.key)),"Ctrl+Space"),"generic-registered-source-retained");
 source(e,"Ctrl+Space","none");editor_edit(e,0);editor_save_clicked(NULL,e);check(!strcmp(find((EditorDoc*)e->prefix.doc,"Ctrl+Space")->value,"none"),"generic-shortcut-none-edit");source(e,"Ctrl+Space","none");editor_edit(e,1);editor_save_clicked(NULL,e);check(!find((EditorDoc*)e->prefix.doc,"Ctrl+Space"),"generic-shortcut-delete");
 capture_reset(e,FALSE);check(feed(e,VK_ESCAPE,1,FALSE)==1&&e->capture[1],"capture-escape");
 capture_reset(e,FALSE);check(editor_feed(e->capture,'A',0,1,1,101)==0&&e->capture[4]==0,"injected-ignored");
 capture_reset(e,FALSE);((unsigned char*)e->capture)[368+'A']=1;check(feed(e,'A',0x1e,FALSE)==0&&feed(e,'A',0x1e,TRUE)==0,"preexisting-key-passes");
 capture_reset(e,FALSE);check(editor_feed(e->capture,'A',0,0,0,101)==0&&e->capture[1],"focus-loss-cancels");
 capture_reset(e,FALSE);check(editor_feed(e->capture,'A',0,0,1,10100)==0&&e->capture[1],"timeout-cancels");
 gtk_window_destroy(GTK_WINDOW(w));g_object_unref(w);while(g_main_context_iteration(NULL,FALSE)){}
 g_remove(name);g_rmdir(dir);g_free(path);g_free(name);g_free(dir);
 printf("EDITOR-SELFTEST-%s checks=%d failures=%d hooks=0 SendInput=0\n",failures?"FAIL":"PASS",checks,failures);return failures?1:0;
}
