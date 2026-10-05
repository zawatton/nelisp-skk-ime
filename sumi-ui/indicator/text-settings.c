/* UTF-8 config editing. Only top-block option values are owned by this UI. */
#include "text-settings.h"
#include "settings.h"
#include <shlobj.h>
#include <shellapi.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>
#include "text-templates.inc"

static gboolean config_path(gboolean rules, wchar_t *path) {
  DWORD n = GetEnvironmentVariableW(rules ? L"NELISP_IME_INPUT_RULES" : L"NELISP_IME_KEYMAP_FILE", path, 32768);
  if (n) return n < 32768;
  if (!rules) {
    wchar_t key[1024]; settings_registry_path(key, 1000); wcscat(key, L"\\Keymap");
    DWORD bytes = 32768 * sizeof(wchar_t);
    if (RegGetValueW(HKEY_CURRENT_USER, key, L"File", RRF_RT_REG_SZ, NULL, path, &bytes) == ERROR_SUCCESS && *path) return TRUE;
  }
  wchar_t *folder = NULL;
  if (FAILED(SHGetKnownFolderPath(&FOLDERID_RoamingAppData, 0, NULL, &folder))) return FALSE;
  _snwprintf(path, 32768, L"%ls\\NativeIME\\%ls", folder, rules ? L"input-rules.conf" : L"keymap.conf");
  CoTaskMemFree(folder);
  return TRUE;
}
static char *read_text(const wchar_t *path) {
  char *name = g_utf16_to_utf8((const gunichar2 *)path, -1, NULL, NULL, NULL), *data = NULL;
  g_file_get_contents(name, &data, NULL, NULL); g_free(name); return data;
}
/* Locate the value token without normalizing any other bytes, including BOM,
 * CRLF, trailing whitespace and inline comments. Sections terminate options. */
static gboolean option_span(const char *data, const char *key, size_t *start, size_t *end, size_t *insert) {
  const char *p = data;
  if (g_str_has_prefix(p, "\xef\xbb\xbf")) p += 3;
  *insert = strlen(data);
  while (*p) {
    const char *line_end = strchr(p, '\n'); if (!line_end) line_end = p + strlen(p);
    const char *q = p; while (q < line_end && (*q == ' ' || *q == '\t')) q++;
    if (*q == '[') { *insert = p - data; return FALSE; }
    size_t len = strlen(key);
    if ((size_t)(line_end-q) >= len && !strncmp(q, key, len)) {
      q += len; while (q < line_end && (*q == ' ' || *q == '\t')) q++;
      if (q < line_end && *q == '=') {
        q++; while (q < line_end && (*q == ' ' || *q == '\t')) q++;
        *start = q - data;
        while (q < line_end && *q != '#' && *q != '\r' && *q != ' ' && *q != '\t') q++;
        *end = q - data; return TRUE;
      }
    }
    p = *line_end ? line_end + 1 : line_end;
  }
  return FALSE;
}
static char *patch(char *data, const char *key, const char *value) {
  size_t a, b, insertion;
  gboolean found = option_span(data, key, &a, &b, &insertion);
  GString *out = g_string_new(NULL);
  if (found) {
    g_string_append_len(out, data, a); g_string_append(out, value); g_string_append(out, data+b);
  } else {
    const char *nl = strstr(data, "\r\n") ? "\r\n" : "\n";
    g_string_append_len(out, data, insertion);
    if (insertion && data[insertion-1] != '\n' && !(insertion == 3 && g_str_has_prefix(data, "\xef\xbb\xbf"))) g_string_append(out, nl);
    g_string_append_printf(out, "%s = %s%s", key, value, nl); g_string_append(out, data+insertion);
  }
  g_free(data); return g_string_free(out, FALSE);
}
static int read_option(const char *data, const char *key, const char *const *values, int fallback) {
  size_t a,b,i;
  if (data && option_span(data,key,&a,&b,&i))
    for (int v=0; values[v]; v++) if (strlen(values[v]) == b-a && !strncmp(data+a,values[v],b-a)) return v;
  return fallback;
}
static const char *const widths[] = {"hankaku","zenkaku",NULL};
static const char *const bools[] = {"no","yes",NULL};
static const char *const layouts[] = {"os","US","JIS",NULL};
void text_settings_load(TextSettings *s) {
  wchar_t path[32768]; char *data = config_path(TRUE,path) ? read_text(path) : NULL;
  s->width=read_option(data,"width",widths,0); s->auto_pair=read_option(data,"auto-pair",bools,1); g_free(data);
  data=config_path(FALSE,path) ? read_text(path) : NULL;
  s->enabled=read_option(data,"enabled",bools,0); s->layout=read_option(data,"layout",layouts,0); g_free(data);
}
static gboolean atomic_write(const wchar_t *path, const char *data) {
  wchar_t dir[32768], temp[32768]; lstrcpyW(dir,path);
  wchar_t *slash=wcsrchr(dir,L'\\'), *forward=wcsrchr(dir,L'/');
  if (!slash || (forward && forward>slash)) slash=forward;
  if (!slash) return FALSE;
  *slash=0; SHCreateDirectoryExW(NULL,dir,NULL);
  if (!GetTempFileNameW(dir,L"sui",0,temp)) return FALSE;
  HANDLE h=CreateFileW(temp,GENERIC_WRITE,0,NULL,TRUNCATE_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL);
  DWORD count=0; size_t len=strlen(data);
  gboolean ok=h!=INVALID_HANDLE_VALUE;
  if (ok) { ok=WriteFile(h,data,(DWORD)len,&count,NULL) && count==len && FlushFileBuffers(h); CloseHandle(h); }
  if (ok) {
    if (GetFileAttributesW(path)!=INVALID_FILE_ATTRIBUTES) ok=ReplaceFileW(path,temp,NULL,0,NULL,NULL);
    else ok=MoveFileExW(temp,path,MOVEFILE_WRITE_THROUGH);
  }
  if (!ok) DeleteFileW(temp);
  return ok;
}
static gboolean save_file(gboolean rules, gboolean change_a, gboolean change_b, int a, int b) {
  wchar_t path[32768]; if (!config_path(rules,path)) return FALSE;
  char *data=read_text(path);
  gboolean missing=data==NULL;
  if (data && !change_a && !change_b) { g_free(data); return TRUE; }
  if (!data) {
    DWORD attrs=GetFileAttributesW(path);
    if (attrs!=INVALID_FILE_ATTRIBUTES || (GetLastError()!=ERROR_FILE_NOT_FOUND && GetLastError()!=ERROR_PATH_NOT_FOUND)) return FALSE;
    data=g_strdup(rules ? rules_template : keymap_template);
  }
  char *original=g_strdup(data);
  if (change_a) data=patch(data,rules ? "width" : "enabled",rules ? widths[a] : bools[a]);
  if (change_b) data=patch(data,rules ? "auto-pair" : "layout",rules ? bools[b] : layouts[b]);
  gboolean ok=(!missing && !strcmp(original,data)) || atomic_write(path,data);
  g_free(original); g_free(data); return ok;
}
gboolean text_settings_save(const TextSettings *s, TextSettings *baseline) {
  gboolean r=save_file(TRUE,s->width!=baseline->width,s->auto_pair!=baseline->auto_pair,s->width,s->auto_pair);
  gboolean k=save_file(FALSE,s->enabled!=baseline->enabled,s->layout!=baseline->layout,s->enabled,s->layout);
  if (r) { baseline->width=s->width; baseline->auto_pair=s->auto_pair; }
  if (k) { baseline->enabled=s->enabled; baseline->layout=s->layout; }
  return r && k;
}
gboolean text_settings_open(gboolean rules, gboolean editor) {
  wchar_t path[32768];
  if (editor) {
    wchar_t key[1024]; settings_registry_path(key,1000); wcscat(key,L"\\Keymap"); DWORD bytes=sizeof(path);
    if (RegGetValueW(HKEY_CURRENT_USER,key,L"Executable",RRF_RT_REG_SZ,NULL,path,&bytes)!=ERROR_SUCCESS || !*path) return FALSE;
  } else {
    if (!config_path(rules,path)) return FALSE;
    if (GetFileAttributesW(path)==INVALID_FILE_ATTRIBUTES && !atomic_write(path,rules ? rules_template : keymap_template)) return FALSE;
  }
  return (INT_PTR)ShellExecuteW(NULL,L"open",path,editor ? (rules ? L"--rules" : L"--editor") : NULL,NULL,SW_SHOWNORMAL)>32;
}
char *text_settings_status(void) {
  wchar_t key[1024], status[1024]=L"", errors[8192]={0}; settings_registry_path(key,1000); wcscat(key,L"\\Keymap");
  DWORD bytes=sizeof(status); RegGetValueW(HKEY_CURRENT_USER,key,L"Status",RRF_RT_REG_SZ,NULL,status,&bytes);
  bytes=sizeof(errors); RegGetValueW(HKEY_CURRENT_USER,key,L"Errors",RRF_RT_REG_MULTI_SZ,NULL,errors,&bytes);
  errors[8190]=errors[8191]=0;
  for (size_t i=0; i<8190; i++) { if (!errors[i]) { if (!errors[i+1]) break; errors[i]=L'\n'; } }
  char *s=g_utf16_to_utf8((gunichar2 *)status,-1,NULL,NULL,NULL), *e=g_utf16_to_utf8((gunichar2 *)errors,-1,NULL,NULL,NULL);
  char *result=g_strdup_printf("Status: %s\nErrors: %s",s ? s : "",e ? e : ""); g_free(s);g_free(e);return result;
}

static int test_failures, test_count;
static void check(gboolean ok, const char *name) {
  test_count++; if (!ok) test_failures++;
  printf("%s %s\n",ok ? "PASS" : "FAIL",name);
}
static gboolean contents_equal(const wchar_t *path, const char *expected) {
  char *data=read_text(path); gboolean equal=data && !strcmp(data,expected); g_free(data); return equal;
}
static HANDLE hold_file(const wchar_t *path, DWORD sharing) {
  return CreateFileW(path,GENERIC_READ,sharing,NULL,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL);
}
int text_settings_selftest(void) {
  /* Allocate our own directory and override both paths before any settings I/O.
   * No registry or remapper process is needed by this headless test. */
  char *dir=g_dir_make_tmp("sumi-text-settings-XXXXXX",NULL);
  if (!dir) { fprintf(stderr,"Cannot create private test directory\n"); return 1; }
  wchar_t *wd=(wchar_t *)g_utf8_to_utf16(dir,-1,NULL,NULL,NULL), path[2][32768];
  for (int i=0;i<2;i++) _snwprintf(path[i],32768,L"%ls\\%ls",wd,i ? L"keymap.conf" : L"input-rules.conf");
  SetEnvironmentVariableW(L"NELISP_IME_INPUT_RULES",path[0]);
  SetEnvironmentVariableW(L"NELISP_IME_KEYMAP_FILE",path[1]);
  TextSettings base, wanted, loaded;
  text_settings_load(&base);
  check(base.width==0 && base.auto_pair==1 && base.enabled==0 && base.layout==0,"missing-defaults");
  wanted=base;
  check(text_settings_save(&wanted,&base),"create-missing-files");
  check(contents_equal(path[0],rules_template) && contents_equal(path[1],keymap_template),"shipped-templates-exact");
  for (int i=0;i<2;i++) {
    const char *fixture=i ? "\xef\xbb\xbf# comment\r\n\r\nenabled\t= no  # enable\r\nlayout = os # layout\r\nunknown = untouched\r\n[keys]\r\nlayout = JIS\r\nCapsLock = LCtrl\r\n" :
      "\xef\xbb\xbf# comment\r\n\r\nwidth\t= hankaku  # width\r\nauto-pair = yes # pair\r\nunknown = untouched\r\n[pairs]\r\nwidth = section-value\r\n[ = \"[\" \"]\"\r\n";
    const char *expected=i ? "\xef\xbb\xbf# comment\r\n\r\nenabled\t= yes  # enable\r\nlayout = JIS # layout\r\nunknown = untouched\r\n[keys]\r\nlayout = JIS\r\nCapsLock = LCtrl\r\n" :
      "\xef\xbb\xbf# comment\r\n\r\nwidth\t= zenkaku  # width\r\nauto-pair = no # pair\r\nunknown = untouched\r\n[pairs]\r\nwidth = section-value\r\n[ = \"[\" \"]\"\r\n";
    check(atomic_write(path[i],fixture),i ? "keymap-fixture" : "rules-fixture");
    text_settings_load(&base); wanted=base;
    if (i) { wanted.enabled=1; wanted.layout=2; } else { wanted.width=1; wanted.auto_pair=0; }
    HANDLE old=hold_file(path[i],FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE);
    BY_HANDLE_FILE_INFORMATION old_info={0}; GetFileInformationByHandle(old,&old_info);
    check(text_settings_save(&wanted,&base),i ? "keymap-save" : "rules-save");
    check(contents_equal(path[i],expected),i ? "keymap-preserve-bytes" : "rules-preserve-bytes");
    char buffer[1024]={0}; DWORD n=0; ReadFile(old,buffer,sizeof(buffer)-1,&n,NULL);
    HANDLE current=hold_file(path[i],FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE);
    BY_HANDLE_FILE_INFORMATION current_info={0}; GetFileInformationByHandle(current,&current_info);
    check(!strcmp(buffer,fixture) && (old_info.nFileIndexLow!=current_info.nFileIndexLow || old_info.nFileIndexHigh!=current_info.nFileIndexHigh),i ? "keymap-atomic-replacement" : "rules-atomic-replacement");
    CloseHandle(old); CloseHandle(current);
    text_settings_load(&loaded);
    check(!memcmp(&loaded,&wanted,sizeof(loaded)),i ? "keymap-roundtrip" : "rules-roundtrip");
    /* Deny deletion/writing: a no-op must succeed without trying to replace. */
    old=hold_file(path[i],FILE_SHARE_READ);
    check(text_settings_save(&wanted,&base),i ? "keymap-noop-no-write" : "rules-noop-no-write");
    if (i) wanted.enabled=0; else wanted.width=0;
    check(!text_settings_save(&wanted,&base) && contents_equal(path[i],expected),i ? "keymap-replacement-failure-preserves-original" : "rules-replacement-failure-preserves-original");
    CloseHandle(old);
    check(text_settings_save(&wanted,&base),i ? "keymap-retry-after-failure" : "rules-retry-after-failure");
    const char *missing=i ? "# missing\nunknown = x\n[keys]\nenabled = section-value\n" : "# missing\nunknown = x\n[pairs]\nwidth = section-value\n";
    check(atomic_write(path[i],missing),i ? "keymap-missing-fixture" : "rules-missing-fixture");
    text_settings_load(&base); wanted=base;
    if (i) { wanted.enabled=1; wanted.layout=1; } else { wanted.width=1; wanted.auto_pair=0; }
    check(text_settings_save(&wanted,&base),i ? "keymap-insert-save" : "rules-insert-save");
    check(contents_equal(path[i],i ? "# missing\nunknown = x\nenabled = yes\nlayout = US\n[keys]\nenabled = section-value\n" : "# missing\nunknown = x\nwidth = zenkaku\nauto-pair = no\n[pairs]\nwidth = section-value\n"),i ? "keymap-insert-before-section" : "rules-insert-before-section");
    /* Intervening hand edits to an untouched option must survive Apply. */
    text_settings_load(&base); wanted=base;
    if (i) wanted.enabled=0; else wanted.width=0;
    char *external=read_text(path[i]); external=patch(external,i ? "layout" : "auto-pair",i ? "JIS" : "yes");
    check(atomic_write(path[i],external),i ? "keymap-external-edit" : "rules-external-edit"); g_free(external);
    check(text_settings_save(&wanted,&base),i ? "keymap-merge-save" : "rules-merge-save");
    text_settings_load(&loaded);
    check(i ? loaded.layout==2 && loaded.enabled==0 : loaded.auto_pair==1 && loaded.width==0,i ? "keymap-preserve-external-edit" : "rules-preserve-external-edit");
  }
  char *patched=patch(g_strdup("# no final newline"),"width","zenkaku");
  check(!strcmp(patched,"# no final newline\nwidth = zenkaku\n"),"insert-after-no-final-newline"); g_free(patched);
  check(DeleteFileW(path[0]),"rules-cleanup");
  check(DeleteFileW(path[1]),"keymap-cleanup");
  check(RemoveDirectoryW(wd),"cleanup-no-temporary-files");
  g_free(wd);g_free(dir);
  printf("TEXT-SELFTEST-%s (%d checks, %d failures)\n",test_failures ? "FAIL" : "PASS",test_count,test_failures);
  fflush(stdout); return test_failures ? 1 : 0;
}
