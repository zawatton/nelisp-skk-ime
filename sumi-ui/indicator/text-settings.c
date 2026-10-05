/* Win32 file/path/shell primitives and independent text-file selftests.
 * Parsing, comment-preserving merge policy and settings actions: text-logic.el. */
#include "text-settings.h"
#include "settings.h"
#include <shlobj.h>
#include <shellapi.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>
#include "text-templates.inc"

gboolean config_path(gboolean rules, wchar_t *path) {
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
char *read_text(const wchar_t *path) {
  char *name = g_utf16_to_utf8((const gunichar2 *)path, -1, NULL, NULL, NULL), *data = NULL;
  g_file_get_contents(name, &data, NULL, NULL); g_free(name); return data;
}
/* Locate the value token without normalizing any other bytes, including BOM,
 * CRLF, trailing whitespace and inline comments. Sections terminate options. */
gboolean option_span(const char *data, const char *key, size_t *start, size_t *end, size_t *insert);
char *patch(char *data, const char *key, const char *value);
int read_option(const char *data, const char *key, const char *const *values, int fallback);
static const char *const widths[] = {"hankaku","zenkaku",NULL};
static const char *const bools[] = {"no","yes",NULL};
static const char *const layouts[] = {"os","US","JIS",NULL};
void text_settings_load(TextSettings *s);
gboolean atomic_write(const wchar_t *path, const char *data) {
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
gboolean save_file(gboolean rules, gboolean change_a, gboolean change_b, int a, int b);
gboolean text_settings_save(const TextSettings *s, TextSettings *baseline);
gboolean text_settings_open(gboolean rules, gboolean editor);
char *text_settings_status(void);

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

const char *const *skkui_text_values(int64_t index) { return index == 0 ? widths : index == 1 ? bools : layouts; }
const char *skkui_text_template(int64_t rules) { return rules ? rules_template : keymap_template; }
