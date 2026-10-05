// SPDX-License-Identifier: GPL-3.0-or-later
// Native primitives only: GTK text buffers and Win32 physical-event transport.
#include "editor-settings.h"
#include "settings.h"
#include <gdk/win32/gdkwin32.h>
#include <stdio.h>
#include <wchar.h>
#include "editor-key-names.inc"
const char*editor_key_name(int64_t i){return i>=0 && i<(int64_t)G_N_ELEMENTS(key_names)?key_names[i].name:NULL;}
uint64_t editor_key_code(int64_t i){return key_names[i].code;}
char*editor_strip(char*s){return g_strstrip(s);}
void*editor_free_address(void){return g_free;}
void*editor_source_callback(void){return editor_source_clicked;}
void*editor_target_callback(void){return editor_target_clicked;}
void*editor_immediate_callback(void){return editor_immediate_clicked;}
gboolean config_path(gboolean,wchar_t*);
gboolean editor_config_path(wchar_t*path){
 wchar_t key[512];settings_registry_path(key,512);
 if(wcscmp(key,L"Software\\NativeIME") && (!getenv("NELISP_IME_KEYMAP_FILE") || !*getenv("NELISP_IME_KEYMAP_FILE")))return FALSE;
 return config_path(FALSE,path);
}
void editor_text_set(GtkWidget*w,const char*s){gtk_text_buffer_set_text(gtk_text_view_get_buffer(GTK_TEXT_VIEW(w)),s,-1);}
char*editor_text_get(GtkWidget*w){GtkTextIter a,b;GtkTextBuffer*t=gtk_text_view_get_buffer(GTK_TEXT_VIEW(w));gtk_text_buffer_get_bounds(t,&a,&b);return gtk_text_buffer_get_text(t,&a,&b,FALSE);}
char*editor_key_label(uint64_t code){
 unsigned vk=code&255,scan=(code>>8)&255;gboolean ext=!!(code&65536);
 if((vk>='A'&&vk<='Z')||(vk>='0'&&vk<='9'))return g_strdup_printf("%c",vk);
 if(vk>=0x70&&vk<=0x87)return g_strdup_printf("F%d",vk-0x6f);
 for(size_t i=0;i<G_N_ELEMENTS(key_names);i++)if((key_names[i].code&255)==vk)return g_strdup(key_names[i].name);
 return vk?g_strdup_printf("vk:0x%02X",vk):g_strdup_printf("sc:%s0x%02X",ext?"e0:":"",scan);
}
static HWND native_window(GtkWidget*w){GdkSurface*s=gtk_native_get_surface(GTK_NATIVE(w));return s?(HWND)gdk_win32_surface_get_handle(s):NULL;}
char*editor_native_details(GtkWidget*w,uint64_t code){
 unsigned vk=code&255,scan=(code>>8)&255;gboolean ext=!!(code&65536);HWND hwnd=native_window(w);
 HKL hkl=GetKeyboardLayout(hwnd?GetWindowThreadProcessId(hwnd,NULL):0);
 BYTE state[256]={0};wchar_t plain[16]={0},shifted[16]={0},name[128]={0};
 GetKeyNameTextW((LONG)((scan<<16)|(ext?1u<<24:0)),name,128);
 int a=ToUnicodeEx(vk,scan,state,plain,15,4,hkl);state[VK_SHIFT]=state[VK_LSHIFT]=0x80;
 int b=ToUnicodeEx(vk,scan,state,shifted,15,4,hkl);
 char*p=g_utf16_to_utf8((gunichar2*)plain,a>0?a:0,NULL,NULL,NULL);
 char*s=g_utf16_to_utf8((gunichar2*)shifted,b>0?b:0,NULL,NULL,NULL);
 char*n=g_utf16_to_utf8((gunichar2*)name,-1,NULL,NULL,NULL);
 char*out=g_strdup_printf("Scan: %s0x%02X  VK: 0x%02X %s\n文字: %s  Shift: %s",ext?"E0:":"",scan,vk,n,a<0?"dead key":p,b<0?"dead key":s);
 g_free(p);g_free(s);g_free(n);return out;
}
static HHOOK capture_hook;static KeymapEditor*owner;static HWND capture_hwnd;static guint done_idle;
static gboolean capture_idle(gpointer data){done_idle=0;editor_capture_done(data);return G_SOURCE_REMOVE;}
void editor_capture_stop(KeymapEditor*e){
 if(owner!=e)return;
 if(done_idle){g_source_remove(done_idle);done_idle=0;}
 if(capture_hook){UnhookWindowsHookEx(capture_hook);capture_hook=NULL;}
 if(capture_hwnd)RemovePropW(capture_hwnd,L"NelispImeKeymapCapture");
 capture_hwnd=NULL;owner=NULL;
}
static LRESULT CALLBACK capture_proc(int code,WPARAM wp,LPARAM lp){
 if(code!=HC_ACTION||!owner)return CallNextHookEx(capture_hook,code,wp,lp);
 KBDLLHOOKSTRUCT*k=(KBDLLHOOKSTRUCT*)lp;unsigned vk=k->vkCode;gboolean ext=!!(k->flags&LLKHF_EXTENDED);
 if(vk==VK_SHIFT)vk=k->scanCode==0x36?VK_RSHIFT:VK_LSHIFT;
 if(vk==VK_CONTROL)vk=ext?VK_RCONTROL:VK_LCONTROL;
 if(vk==VK_MENU)vk=ext?VK_RMENU:VK_LMENU;
 uint64_t packed=vk|((uint64_t)(k->scanCode&255)<<8)|(ext?65536:0);
 int64_t swallow=editor_feed(owner->capture,packed,!!(k->flags&LLKHF_UP),!!(k->flags&LLKHF_INJECTED),GetForegroundWindow()==capture_hwnd,GetTickCount());
 if(!owner->capture[0]&&!done_idle)done_idle=g_idle_add(capture_idle,owner);
 return swallow?1:CallNextHookEx(capture_hook,code,wp,lp);
}
static BOOL CALLBACK editor_find_resident(HWND w,LPARAM p){
 struct Find{DWORD pid;HWND window;};struct Find*f=(void*)p;DWORD pid=0;wchar_t cls[128];
 GetWindowThreadProcessId(w,&pid);GetClassNameW(w,cls,128);
 if(pid==f->pid&&!wcscmp(cls,L"NelispImeKeymapResident")){f->window=w;return FALSE;}return TRUE;
}
gboolean editor_capture_install(KeymapEditor*e){
 HWND hwnd=native_window(e->window);if(!hwnd||GetForegroundWindow()!=hwnd)return FALSE;
 if(owner)editor_capture_stop(owner);
 if(!SetPropW(hwnd,L"NelispImeKeymapCapture",(HANDLE)1))return FALSE;
 wchar_t key[1024];settings_registry_path(key,1000);wcscat(key,L"\\Keymap");DWORD pid=0,bytes=sizeof(pid);
 RegGetValueW(HKEY_CURRENT_USER,key,L"Pid",RRF_RT_REG_DWORD,NULL,&pid,&bytes);
 if(pid){
  struct Find{DWORD pid;HWND window;}find={pid,NULL};
  EnumWindows((WNDENUMPROC)editor_find_resident,(LPARAM)&find);
  DWORD_PTR ack=0;
  if(!find.window||!SendMessageTimeoutW(find.window,WM_APP+4,0,(LPARAM)hwnd,SMTO_ABORTIFHUNG,200,&ack)||ack!=1){RemovePropW(hwnd,L"NelispImeKeymapCapture");return FALSE;}
 }
 if(GetForegroundWindow()!=hwnd){RemovePropW(hwnd,L"NelispImeKeymapCapture");return FALSE;}
 owner=e;capture_hwnd=hwnd;capture_hook=SetWindowsHookExW(WH_KEYBOARD_LL,capture_proc,GetModuleHandleW(NULL),0);
 if(!capture_hook){editor_capture_stop(e);return FALSE;}return TRUE;
}
void editor_capture_tick(KeymapEditor*e){
 if(owner==e&&(GetForegroundWindow()!=capture_hwnd||GetTickCount()-(DWORD)e->capture[3]>=10000)){
  e->capture[0]=0;e->capture[1]=1;editor_capture_done(e);
 }
}
