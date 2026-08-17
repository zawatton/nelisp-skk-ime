;; registry.el --- settings.c's registry layer, in NeLisp (AOT, object mode).
;;
;; The five low-level helpers `settings.c' used to implement in C, moved
;; to NeLisp per the project's "prefer NeLisp over C" direction.  Every
;; call site in settings.c is unchanged: these compile to global symbols
;; with exactly the names and Win64 signatures the C code already calls,
;; so settings.c keeps its own public API (`settings_load' /
;; `settings_save' / ...) and only its private registry plumbing moved.
;;
;; Nothing here builds a string.  Key paths and value names arrive as
;; `const wchar_t *' from settings.c -- which still owns
;; `settings_key_path' and the DDSKK_SETTINGS_KEY override -- so this
;; module only forwards pointers to advapi32 and never needs a string
;; literal.  That matters: object-mode AOT rejects any module whose
;; rodata is non-empty (`:object-mode-no-strings' in
;; nelisp/lisp/nelisp-aot-compiler.el -- rodata vaddr baking does not
;; survive linker relocation in v1), so a port that constructed paths
;; here would not compile at all.
;;
;; The scratch cells below replace C stack locals, because object-mode
;; defuns have no stack-allocated aggregates.  That makes these
;; functions non-reentrant, which is sound here and checked rather than
;; assumed: sumi-ui creates no threads (its only scheduling is
;; `g_timeout_add' in main.c, i.e. the GTK main thread), and every
;; caller is a settings_* function invoked from that same thread.
;;
;; Win32 constants, spelled out because there are no C headers here:
;;   HKEY_CURRENT_USER    #x80000001
;;   RRF_RT_REG_SZ        #x02      RRF_RT_REG_DWORD  #x10
;;   REG_SZ               1         REG_DWORD         4
;;   ERROR_SUCCESS        0         ERROR_FILE_NOT_FOUND 2

(seq
 ;; 8-byte DWORD landing pad for RegGetValueW/RegSetKeyValueW.  Only the
 ;; low 4 bytes are ever meaningful; the extra 4 keep the cell 8-aligned
 ;; for `ptr-read-u64'-shaped access if it is ever wanted.
 (data-blob skkreg_dword "\0\0\0\0\0\0\0\0" data)
 ;; The in/out `cbData' cell RegGetValueW reads the buffer size from and
 ;; writes the byte count back into.  Reset before every call, since the
 ;; callee overwrites it.
 (data-blob skkreg_size "\0\0\0\0\0\0\0\0" data)

 ;; gboolean reg_get_dword(const wchar_t *key_path, const wchar_t *value,
 ;;                        int32_t default_value, int32_t *out)
 ;;
 ;; Always returns TRUE and always writes *out: a missing key and a
 ;; missing value are both "use the default", which is what lets
 ;; settings_load() treat first run and a half-populated key alike.
 (defun reg_get_dword (key_path value default_value out)
   (ptr-write-u32 (data-addr skkreg_size) 0 4)
   (let ((status (extern-call RegGetValueW
                              #x80000001 key_path value #x10 0
                              (data-addr skkreg_dword) (data-addr skkreg_size))))
     (if (= status 0)
         (ptr-write-u32 out 0 (ptr-read-u32 (data-addr skkreg_dword) 0))
       (ptr-write-u32 out 0 default_value))
     1))

 ;; gboolean reg_get_sz(const wchar_t *key_path, const wchar_t *value,
 ;;                     const wchar_t *default_value,
 ;;                     wchar_t *out, size_t out_cap)
 ;;
 ;; Reads straight into the caller's buffer bounded by OUT_CAP rather
 ;; than via an intermediate the C version copied out of; on any failure
 ;; the default is copied in with the same truncate-and-NUL-terminate
 ;; semantics `wcsncpy' + explicit terminator gave (lstrcpynW copies at
 ;; most CAP-1 characters and always terminates).
 (defun reg_get_sz (key_path value default_value out out_cap)
   (ptr-write-u32 (data-addr skkreg_size) 0 (* out_cap 2))
   (let ((status (extern-call RegGetValueW
                              #x80000001 key_path value #x02 0
                              out (data-addr skkreg_size))))
     (if (= status 0)
         1
       (progn
         (extern-call lstrcpynW out default_value out_cap)
         1))))

 ;; gboolean reg_set_dword(const wchar_t *key_path, const wchar_t *value,
 ;;                        int32_t v)
 (defun reg_set_dword (key_path value v)
   (ptr-write-u32 (data-addr skkreg_dword) 0 v)
   (if (= (extern-call RegSetKeyValueW
                       #x80000001 key_path value 4 (data-addr skkreg_dword) 4)
          0)
       1
     0))

 ;; gboolean reg_set_color(const wchar_t *key_path, const wchar_t *value,
 ;;                        int32_t v, int32_t fallback)
 ;;
 ;; An absent ModeColor* means "use the colour the DLL was built with",
 ;; which is not the same as writing this UI's default -- the two tables
 ;; need not agree, and writing ours unconditionally silently changed the
 ;; user's indicator colours.  So a value equal to the default is
 ;; removed, keeping "unset" expressible.  A value that was already
 ;; absent reports success (ERROR_FILE_NOT_FOUND is not a failure here).
 (defun reg_set_color (key_path value v fallback)
   (if (= v fallback)
       (let ((status (extern-call RegDeleteKeyValueW
                                  #x80000001 key_path value)))
         (if (= status 0) 1 (if (= status 2) 1 0)))
     (progn
       (ptr-write-u32 (data-addr skkreg_dword) 0 v)
       (if (= (extern-call RegSetKeyValueW
                           #x80000001 key_path value 4 (data-addr skkreg_dword) 4)
              0)
           1
         0))))

 ;; gboolean reg_set_sz(const wchar_t *key_path, const wchar_t *value,
 ;;                     const wchar_t *v)
 ;;
 ;; cbData counts the terminating NUL, in bytes: (lstrlenW(v) + 1) * 2.
 (defun reg_set_sz (key_path value v)
   (let ((bytes (* (+ (extern-call lstrlenW v) 1) 2)))
     (if (= (extern-call RegSetKeyValueW
                         #x80000001 key_path value 1 v bytes)
            0)
         1
       0))))
