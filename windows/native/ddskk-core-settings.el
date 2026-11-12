;;; ddskk-core-settings.el --- settings, registry watcher, published state  -*- lexical-binding: t; -*-

;;; Commentary:

;; Sub-stage S3e of the native TSF DLL project.  AOT forms (restricted NeLisp
;; subset, COM DSL) for the part of windows/src/text_service.cpp that reads
;; and publishes registry state.  They belong to the CORE side of the
;; shim/core split (ddskk-ime-core.dll); the stable shim only hosts the
;; process-wide publication lock (cb_publock in ddskk-shim.el).  Test builds
;; link these forms into a probe DLL (test/settings-probe.el).
;;
;;   cs_new / cs_free            service settings object (struct DdskkSettings)
;;   cs_load (LoadSettings)      Engine, DllDebug, InitialKanaMode,
;;                               ModeIndicator{,Ms,Scale}, ModeColor* (DWORD
;;                               COLORREF overrides, as C++: the C++ has no
;;                               "#rrggbb" parser), NELISP_IME_ENGINE override,
;;                               per-engine InitialKanaMode (ReadEngineDword)
;;   cs_load_app                 LoadApplicationSettings (Apps\<lower exe name>)
;;   cs_queue / cs_flush /       QueuePublishedState / FlushPublishedState /
;;   cs_remove                   RemovePublishedState (Clients\<pid>), ordered
;;                               queue = heap ring guarded by a per-service
;;                               critical section; flush/remove also take the
;;                               process-wide writer lock (core critical
;;                               section, then the shim's publication_lock)
;;   cs_fp                       NativeImeSettingsFingerprint (FNV-1a style)
;;   cs_wk_*                     RegistryWatcher: CreateThread + stop event +
;;                               RegNotifyChangeKeyValue, atomic dirty flag
;;
;; Differences from the C++ source, all deliberate:
;;  * A registry read whose status is not ERROR_SUCCESS leaves the target
;;    unchanged (C++ passes the target buffer directly; its content after
;;    ERROR_MORE_DATA is documented as undefined).  A successful read of fewer
;;    than 4 bytes still only overwrites those bytes, like C++.
;;  * cs_queue takes the already computed composing level (0..2) of the engine
;;    state, or 99 for "no state" (nullptr); computing it is S3f work.
;;  * The "post to provider window" step is a function pointer field (`post').
;;  * Test hooks: `cs_race_yield' (Sleep(0) inside the ring push) and the
;;    trace of flushed sequences.
;;
;; Build hook: `ddskk-core-settings-forms' :no-lock makes the per-service
;; critical section a no-op (negative control for the concurrency test).

;;; Code:

(require 'cl-lib)
(require 'ddskk-shim)

(defconst ddskk-core-settings-imports
  '(("kernel32.dll" "GetProcessHeap" "HeapAlloc" "HeapFree" "HeapReAlloc"
     "GetEnvironmentVariableW" "GetModuleFileNameW" "GetCurrentProcessId"
     "CreateThread" "CreateEventW" "SetEvent" "CloseHandle"
     "WaitForSingleObject" "WaitForMultipleObjects" "Sleep"
     "InitializeCriticalSection" "EnterCriticalSection" "LeaveCriticalSection"
     "DeleteCriticalSection")
    ("advapi32.dll" "RegOpenKeyExW" "RegCloseKey" "RegQueryValueExW"
     "RegCreateKeyExW" "RegSetValueExW" "RegDeleteTreeW" "RegQueryInfoKeyW"
     "RegEnumValueW" "RegEnumKeyExW" "RegNotifyChangeKeyValue")
    ("user32.dll" "CharLowerBuffW"))
  "Imports needed by `ddskk-core-settings-forms'.")

(defconst ddskk-core-settings-u32 4294967295)
(defconst ddskk-core-settings-fnv-basis -3750763034362895579
  "FNV-1a 64-bit offset basis 14695981039346656037 as a signed 64-bit value.")
(defconst ddskk-core-settings-fnv-prime 1099511628211)
(defconst ddskk-core-settings-ring-entry 32)
(defconst ddskk-core-settings-trace-max 32)

(nelisp-com-defstruct DdskkSettings
  (kana u32) (ddskk u32) (debug u32) (ms u32) (enabled u32) (scale u32)
  (publish u32) (registered u32) (active u32) (queued u32) (activated u32)
  (open u32) (composing u32) (lp_open u32) (lp_comp u32) (q_type u32)
  (q_bytes u32) (q_val u32) (q_st u32) (trace_n u32) (colors (array u32 5))
  (q_hk u64) (open_mode ptr) (app_name ptr) (last_mode ptr) (lp_mode ptr)
  (ring ptr) (ring_cap u64) (ring_head u64) (ring_count u64)
  (cb ptr) (post ptr)
  (engine (array u16 40)) (tmpbuf (array u16 40)) (envbuf (array u16 40))
  (trace (array u32 32))
  (pubcs (bytes 40 8)))

(nelisp-com-defstruct DdskkWatcher
  (stop u64) (changed u64) (thread u64) (key u64) (dirty u64)
  (include_core u64) (fingerprint u64) (wakeups u64) (ready u64) (exited u64)
  (waits (array u64 2)))

(defun cs--f (p f) (nelisp-com-field p 'DdskkSettings f))
(defun cs--s (p f v) (nelisp-com-set-field p 'DdskkSettings f v))
(defun cs--a (p f) (nelisp-com-field-addr p 'DdskkSettings f))
(defun cs--wf (p f) (nelisp-com-field p 'DdskkWatcher f))
(defun cs--ws (p f v) (nelisp-com-set-field p 'DdskkWatcher f v))
(defun cs--wa (p f) (nelisp-com-field-addr p 'DdskkWatcher f))

(defun ddskk-core-settings-blobs ()
  "Data blobs of the settings library."
  (append
   (cl-loop for (name str) in
            '((w_cs_envkey "NATIVEIME_REGISTRY_KEY") (w_cs_envengine "NELISP_IME_ENGINE")
              (w_cs_native "Software\\NativeIME") (w_cs_apps "\\Apps\\")
              (w_cs_engines "\\Engines\\") (w_cs_clients "\\Clients\\")
              (w_cs_engine "Engine") (w_cs_dlldebug "DllDebug")
              (w_cs_kana "InitialKanaMode") (w_cs_ms "ModeIndicatorMs")
              (w_cs_ind "ModeIndicator") (w_cs_scale "ModeIndicatorScale")
              (w_cs_col0 "ModeColorKana") (w_cs_col1 "ModeColorKatakana")
              (w_cs_col2 "ModeColorLatin") (w_cs_col3 "ModeColorWideLatin")
              (w_cs_col4 "ModeColorAbbrev")
              (w_cs_openmode "OpenMode") (w_cs_pubstate "PublishState")
              (w_cs_revision "revision") (w_cs_mode "mode") (w_cs_open "open")
              (w_cs_composing "composing") (w_cs_sequence "sequence")
              (w_cs_coredll "CoreDll") (w_cs_clientsname "Clients")
              (w_cs_ddskk "ddskk") (w_cs_passthrough "passthrough")
              (w_cs_restore "restore") (w_cs_latin "latin")
              (w_cs_hiragana "hiragana") (w_cs_katakana "katakana")
              (w_cs_empty ""))
            collect (nelisp-com-wstr-blob name str))
   (list (nelisp-com-zero-blob 'cs_proc_seq 8)
         (nelisp-com-zero-blob 'cs_proc_pubs 8)
         (nelisp-com-zero-blob 'cs_proc_flushed 8)
         (nelisp-com-zero-blob 'cs_wr_flag 8)
         (nelisp-com-zero-blob 'cs_wr_cs 48)
         (nelisp-com-zero-blob 'cs_race_yield 8))))

(defun ddskk-core-settings--lock-forms (no-lock)
  (list
   `(defun cs_pub_enter (s)
      ,(if no-lock 0 `(extern-call EnterCriticalSection ,(cs--a 's 'pubcs))))
   `(defun cs_pub_leave (s)
      ,(if no-lock 0 `(extern-call LeaveCriticalSection ,(cs--a 's 'pubcs))))
   ;; Process-wide writer lock (std::mutex process_publication_writer).
   '(defun cs_wr_init ()
      (if (= (ptr-read-u64 (data-addr cs_wr_flag) 0) 2) 0
        (if (= (atomic-compare-exchange (data-addr cs_wr_flag) 0 1) 1)
            (seq (extern-call InitializeCriticalSection (data-addr cs_wr_cs))
                 (ptr-write-u64 (data-addr cs_wr_flag) 0 2)
                 0)
          (seq (while (/= (ptr-read-u64 (data-addr cs_wr_flag) 0) 2)
                 (extern-call Sleep 0))
               0))))
   '(defun cs_wr_enter ()
      (seq (cs_wr_init) (extern-call EnterCriticalSection (data-addr cs_wr_cs)) 0))
   '(defun cs_wr_leave ()
      (seq (extern-call LeaveCriticalSection (data-addr cs_wr_cs)) 0))))

(defun ddskk-core-settings--util-forms ()
  (let ((u32 ddskk-core-settings-u32))
    `((defun cs_zero (p nbytes)
        (let ((i 0)) (seq (while (< i nbytes) (seq (ptr-write-u8 p i 0) (setq i (+ i 1)))) 0)))
      ;; 1 when the NUL-terminated wide strings are equal.
      (defun cs_weq (a b)
        (let ((i 0) (r 1))
          (seq (while (= r 1)
                 (let ((x (ptr-read-u16 a (* 2 i))) (y (ptr-read-u16 b (* 2 i))))
                   (if (/= x y) (setq r 0)
                     (if (= x 0) (setq r 2) (setq i (+ i 1))))))
               (if (= r 2) 1 0))))
      (defun cs_lower (c) (if (and (>= c 65) (<= c 90)) (+ c 32) c))
      ;; ASCII case-insensitive equality (_wcsicmp(a, b) == 0 for ASCII names).
      (defun cs_wieq (a b)
        (let ((i 0) (r 1))
          (seq (while (= r 1)
                 (let ((x (cs_lower (ptr-read-u16 a (* 2 i))))
                       (y (cs_lower (ptr-read-u16 b (* 2 i)))))
                   (if (/= x y) (setq r 0)
                     (if (= x 0) (setq r 2) (setq i (+ i 1))))))
               (if (= r 2) 1 0))))
      ;; Copy at most MAXN units of the wide string SRC (with NUL) into DST.
      (defun cs_wcopy (dst src maxn)
        (let ((i 0) (go 1))
          (seq (while (and (= go 1) (< i maxn))
                 (let ((c (ptr-read-u16 src (* 2 i))))
                   (seq (ptr-write-u16 dst (* 2 i) c)
                        (if (= c 0) (setq go 0) (setq i (+ i 1))))))
               0)))
      ;; (Re)assign the wbuf stored at SLOT (address of a ptr field).
      (defun cs_wassign (slot p n)
        (let ((w (ptr-read-u64 slot 0)))
          (seq (if (= w 0)
                   (seq (setq w (wbuf_new 16)) (ptr-write-u64 slot 0 w))
                 (wbuf_clear w))
               (if (= w 0) ,nelisp-com-e-outofmemory (wbuf_append_wn w p n)))))
      (defun cs_wfree (slot)
        (seq (wbuf_free (ptr-read-u64 slot 0)) (ptr-write-u64 slot 0 0) 0))
      ;; NativeImeRegistryKey(): NATIVEIME_REGISTRY_KEY else Software\NativeIME.
      (defun cs_regkey ()
        (let ((w (wbuf_new 1024)))
          (if (= w 0) 0
            (let ((n (logand (extern-call GetEnvironmentVariableW (data-addr w_cs_envkey)
                                          (wbuf_ptr w) 1024)
                             ,u32)))
              (seq (if (and (> n 0) (< n 1024))
                       (ptr-write-u64 (+ w 8) 0 n)
                     (wbuf_append_w w (data-addr w_cs_native)))
                   w)))))
      ;; key + INFIX + TAIL as a new wbuf (TAIL may be 0).
      (defun cs_key_path (infix tail)
        (let ((w (cs_regkey)))
          (if (= w 0) 0
            (seq (wbuf_append_w w infix)
                 (if (/= tail 0) (wbuf_append_w w tail) 0)
                 w))))
      ;; RegQueryValueExW into DEST (CAP bytes); status, type/bytes in the object.
      (defun cs_rq (s hk name dest cap)
        (seq ,(cs--s 's 'q_bytes 'cap)
             (logand (extern-call RegQueryValueExW hk name 0 ,(cs--a 's 'q_type)
                                  dest ,(cs--a 's 'q_bytes))
                     ,u32)))
      ;; 4-byte read seeded with CUR; returns the new value (CUR on failure);
      ;; the status is left in q_st.
      (defun cs_rd32 (s hk name cur)
        (seq ,(cs--s 's 'q_val 'cur)
             ,(cs--s 's 'q_st `(cs_rq s hk name ,(cs--a 's 'q_val) 4))
             (if (= ,(cs--f 's 'q_st) 0) ,(cs--f 's 'q_val) cur)))
      ;; The AOT subset has no remainder operator; ring capacities are powers of two.
      (defun cs_mod (a b) (logand a (- b 1))))))

(defun ddskk-core-settings--settings-forms ()
  (let ((u32 ddskk-core-settings-u32) (hkcu nelisp-com-hkey-current-user)
        (ring ddskk-core-settings-ring-entry))
    `((defun cs_new ()
        (let ((s (DdskkSettings_alloc)))
          (if (= s 0) 0
            (seq (extern-call InitializeCriticalSection ,(cs--a 's 'pubcs))
                 (cs_wassign ,(cs--a 's 'open_mode) (data-addr w_cs_restore) 7)
                 (cs_wassign ,(cs--a 's 'last_mode) (data-addr w_cs_hiragana) 8)
                 (cs_wcopy ,(cs--a 's 'engine) (data-addr w_cs_ddskk) 32)
                 ,(cs--s 's 'kana 1) ,(cs--s 's 'ddskk 1) ,(cs--s 's 'ms 3000)
                 ,(cs--s 's 'enabled 1) ,(cs--s 's 'scale 100)
                 s))))
      (defun cs_ring_clear (s)
        (let ((i 0) (n ,(cs--f 's 'ring_count)) (cap ,(cs--f 's 'ring_cap))
              (h ,(cs--f 's 'ring_head)) (r ,(cs--f 's 'ring)))
          (seq (while (< i n)
                 (seq (wbuf_free (ptr-read-u64 r (+ (* ,ring (% (+ h i) cap)) 16)))
                      (setq i (+ i 1))))
               ,(cs--s 's 'ring_count 0) ,(cs--s 's 'ring_head 0)
               0)))
      (defun cs_free (s)
        (if (= s 0) 0
          (seq (cs_ring_clear s)
               (if (/= ,(cs--f 's 'ring) 0)
                   (extern-call HeapFree (extern-call GetProcessHeap) 0 ,(cs--f 's 'ring))
                 0)
               (cs_wfree ,(cs--a 's 'open_mode)) (cs_wfree ,(cs--a 's 'app_name))
               (cs_wfree ,(cs--a 's 'last_mode)) (cs_wfree ,(cs--a 's 'lp_mode))
               (extern-call DeleteCriticalSection ,(cs--a 's 'pubcs))
               (DdskkSettings_free s)
               0)))
      ;; ---- ReadEngineDword (text_service.cpp / registry_settings.h) ----
      (defun cs_read_engine_dword (s engine name fallback)
        (if (= (ptr-read-u16 engine 0) 0) fallback
          (let ((p (cs_key_path (data-addr w_cs_engines) engine)))
            (if (= p 0) fallback
              (let ((r fallback))
                (seq
                 (if (= (logand (extern-call RegOpenKeyExW ,hkcu (wbuf_ptr p) 0 131097
                                              ,(cs--a 's 'q_hk))
                                ,u32)
                        0)
                     (let ((hk ,(cs--f 's 'q_hk)))
                       (seq ,(cs--s 's 'q_val 0)
                            (let ((st (cs_rq s hk name ,(cs--a 's 'q_val) 4)))
                              (if (and (= st 0) (= ,(cs--f 's 'q_type) 4)
                                       (= ,(cs--f 's 'q_bytes) 4))
                                  (setq r ,(cs--f 's 'q_val))
                                0))
                            (extern-call RegCloseKey hk)))
                   0)
                 (wbuf_free p)
                 r))))))
      ;; ---- LoadApplicationSettings (text_service.cpp 1467-1500) ----
      (defun cs_load_app (s)
        (let ((mw (wbuf_new 32768)))
          (if (= mw 0) 0
            (seq
             (let ((n (logand (extern-call GetModuleFileNameW 0 (wbuf_ptr mw) 32768) ,u32)))
               (ptr-write-u64 (+ mw 8) 0 (if (< n 32768) n 0)))
             (let ((i (- (wbuf_len mw) 1)) (p (wbuf_ptr mw)) (go 1))
               (seq (while (= go 1)
                      (if (< i 0) (setq go 0)
                        (if (= (wbuf_is_sep (ptr-read-u16 p (* 2 i))) 1) (setq go 0)
                          (setq i (- i 1)))))
                    (cs_wassign ,(cs--a 's 'app_name) (+ p (* 2 (+ i 1)))
                                (- (wbuf_len mw) (+ i 1)))))
             (wbuf_free mw)
             (let ((an ,(cs--f 's 'app_name)))
               (extern-call CharLowerBuffW (wbuf_ptr an) (wbuf_len an)))
             (cs_wassign ,(cs--a 's 'open_mode) (data-addr w_cs_restore) 7)
             (let ((path (cs_key_path (data-addr w_cs_apps) (wbuf_ptr ,(cs--f 's 'app_name))))
                   (enabled 0))
               (seq
                (if (= path 0) 0
                  (seq
                   (if (= (logand (extern-call RegOpenKeyExW ,hkcu (wbuf_ptr path) 0 1
                                                ,(cs--a 's 'q_hk))
                                  ,u32)
                          0)
                       (let ((hk ,(cs--f 's 'q_hk)) (mb ,(cs--a 's 'tmpbuf)))
                         (seq
                          (cs_zero mb 80)
                          (let ((st (cs_rq s hk (data-addr w_cs_openmode) mb 64)))
                            (if (and (= st 0) (= ,(cs--f 's 'q_type) 1)
                                     (>= ,(cs--f 's 'q_bytes) 2) (<= ,(cs--f 's 'q_bytes) 64)
                                     (= (ptr-read-u16 mb (* 2 (- (/ ,(cs--f 's 'q_bytes) 2) 1))) 0))
                                (if (or (= (cs_weq mb (data-addr w_cs_latin)) 1)
                                        (= (cs_weq mb (data-addr w_cs_hiragana)) 1)
                                        (= (cs_weq mb (data-addr w_cs_katakana)) 1))
                                    (cs_wassign ,(cs--a 's 'open_mode) mb (wbuf_wcslen mb))
                                  0)
                              0))
                          ,(cs--s 's 'q_val 0)
                          (let ((st2 (cs_rq s hk (data-addr w_cs_pubstate)
                                            ,(cs--a 's 'q_val) 4)))
                            (if (and (= st2 0) (= ,(cs--f 's 'q_type) 4)
                                     (= ,(cs--f 's 'q_bytes) 4) (= ,(cs--f 's 'q_val) 1))
                                (setq enabled 1)
                              0))
                          (extern-call RegCloseKey hk)))
                     0)
                   (wbuf_free path)))
                (if (and (/= ,(cs--f 's 'publish) 0) (= enabled 0)) (cs_remove s) 0)
                ,(cs--s 's 'publish 'enabled)
                (if (and (= enabled 1) (/= ,(cs--f 's 'activated) 0)
                         (= ,(cs--f 's 'registered) 0))
                    (seq (cs_pub_delta s 1)
                         ,(cs--s 's 'registered 1)
                         ,(cs--s 's 'active 1)
                         0)
                  0)
                0))))))
      ;; ---- LoadSettings (text_service.cpp 1576-1670) ----
      (defun cs_load (s)
        (let ((kana 1) (ms 3000) (ind 1) (scale 100) (dbg 0) (kw (cs_regkey))
              (col ,(cs--a 's 'colors)))
          (seq
           (cs_load_app s)
           (ptr-write-u32 col 0 #x2020C0) (ptr-write-u32 col 4 #x3B7F1B)
           (ptr-write-u32 col 8 #xC8A600) (ptr-write-u32 col 12 #xA85A1E)
           (ptr-write-u32 col 16 #x912C6A)
           (cs_zero ,(cs--a 's 'engine) 80)
           (cs_wcopy ,(cs--a 's 'engine) (data-addr w_cs_ddskk) 32)
           (if (= kw 0) 0
             (seq
              (if (= (logand (extern-call RegOpenKeyExW ,hkcu (wbuf_ptr kw) 0 131097
                                           ,(cs--a 's 'q_hk))
                             ,u32)
                     0)
                  (let ((hk ,(cs--f 's 'q_hk)) (tb ,(cs--a 's 'tmpbuf)))
                    (seq
                     (cs_zero tb 80)
                     (cs_wcopy tb ,(cs--a 's 'engine) 32)
                     (if (= (cs_rq s hk (data-addr w_cs_engine) tb 64) 0)
                         (cs_wcopy ,(cs--a 's 'engine) tb 32)
                       0)
                     (setq dbg (cs_rd32 s hk (data-addr w_cs_dlldebug) dbg))
                     (setq kana (cs_rd32 s hk (data-addr w_cs_kana) kana))
                     (setq ms (cs_rd32 s hk (data-addr w_cs_ms) ms))
                     (setq ind (cs_rd32 s hk (data-addr w_cs_ind) ind))
                     (setq scale (cs_rd32 s hk (data-addr w_cs_scale) scale))
                     ,@(cl-loop for i from 0 below 5
                                collect
                                `(let ((v (cs_rd32 s hk (data-addr ,(intern (format "w_cs_col%d" i)))
                                                   0)))
                                   (if (= ,(cs--f 's 'q_st) 0)
                                       (ptr-write-u32 col ,(* 4 i) v)
                                     0)))
                     (extern-call RegCloseKey hk)))
                0)
              (wbuf_free kw)))
           ;; NELISP_IME_ENGINE overrides the registry selection.
           (let ((eb ,(cs--a 's 'envbuf)))
             (seq (cs_zero eb 80)
                  (let ((n (logand (extern-call GetEnvironmentVariableW (data-addr w_cs_envengine)
                                                eb 32)
                                   ,u32)))
                    (if (and (> n 0) (< n 32))
                        (cs_wcopy ,(cs--a 's 'engine) eb 32)
                      0))))
           ,(cs--s 's 'ddskk `(if (= (cs_weq ,(cs--a 's 'engine) (data-addr w_cs_passthrough)) 1) 0 1))
           ,(cs--s 's 'kana
                   `(if (and (/= ,(cs--f 's 'ddskk) 0)
                             (/= (cs_read_engine_dword s ,(cs--a 's 'engine)
                                                       (data-addr w_cs_kana) kana)
                                 0))
                        1 0))
           ,(cs--s 's 'debug '(if (= dbg 1) 1 0))
           (if (< ms 1) (setq ms 1) 0)
           (if (> ms 60000) (setq ms 60000) 0)
           ,(cs--s 's 'ms 'ms)
           ,(cs--s 's 'enabled '(if (/= ind 0) 1 0))
           (if (< scale 50) (setq scale 50) 0)
           (if (> scale 300) (setq scale 300) 0)
           ,(cs--s 's 'scale 'scale)
           (cs_wassign ,(cs--a 's 'last_mode) (data-addr w_cs_hiragana) 8)
           0)))
      ;; ---- published state ----
      (defun cs_next_seq (s)
        (let ((cb ,(cs--f 's 'cb)))
          (if (/= cb 0)
              (logand (call-ptr ,(nelisp-com-field 'cb 'NativeImeCallbacks 'publication_sequence)
                                ,(nelisp-com-field 'cb 'NativeImeCallbacks 'owner))
                      ,u32)
            (logand (+ 1 (atomic-fetch-add (data-addr cs_proc_seq) 1)) ,u32))))
      (defun cs_pub_delta (s d)
        (let ((cb ,(cs--f 's 'cb)))
          (if (/= cb 0)
              (logand (call-ptr ,(nelisp-com-field 'cb 'NativeImeCallbacks 'publisher_delta)
                                ,(nelisp-com-field 'cb 'NativeImeCallbacks 'owner) d)
                      ,u32)
            (if (> d 0) (+ 1 (atomic-fetch-add (data-addr cs_proc_pubs) 1))
              (- (atomic-fetch-add (data-addr cs_proc_pubs) -1) 1)))))
      (defun cs_cb_lock (s lock)
        (let ((cb ,(cs--f 's 'cb)))
          (if (/= cb 0)
              (seq (call-ptr ,(nelisp-com-field 'cb 'NativeImeCallbacks 'publication_lock)
                             ,(nelisp-com-field 'cb 'NativeImeCallbacks 'owner) lock)
                   0)
            0)))
      (defun cs_flushed_get (s)
        (let ((cb ,(cs--f 's 'cb)))
          (if (/= cb 0)
              (logand (call-ptr ,(nelisp-com-field 'cb 'NativeImeCallbacks 'publication_flushed)
                                ,(nelisp-com-field 'cb 'NativeImeCallbacks 'owner) 0)
                      ,u32)
            (ptr-read-u64 (data-addr cs_proc_flushed) 0))))
      (defun cs_flushed_set (s v)
        (let ((cb ,(cs--f 's 'cb)))
          (if (/= cb 0)
              (seq (call-ptr ,(nelisp-com-field 'cb 'NativeImeCallbacks 'publication_flushed)
                             ,(nelisp-com-field 'cb 'NativeImeCallbacks 'owner) v)
                   0)
            (seq (ptr-write-u64 (data-addr cs_proc_flushed) 0 v) 0))))
      ;; Double the ring (caller holds the service lock).  0 on success.
      (defun cs_ring_grow (s)
        (let ((cap ,(cs--f 's 'ring_cap)))
          (let ((ncap (if (= cap 0) 8 (* cap 2))))
            (let ((nr (extern-call HeapAlloc (extern-call GetProcessHeap) 8 (* ncap ,ring))))
              (if (= nr 0) 1
                (let ((i 0) (r ,(cs--f 's 'ring)) (h ,(cs--f 's 'ring_head))
                      (n ,(cs--f 's 'ring_count)))
                  (seq (while (< i n)
                         (let ((src (+ r (* ,ring (% (+ h i) cap)))) (dst (+ nr (* ,ring i))))
                           (seq (ptr-write-u64 dst 0 (ptr-read-u64 src 0))
                                (ptr-write-u64 dst 8 (ptr-read-u64 src 8))
                                (ptr-write-u64 dst 16 (ptr-read-u64 src 16))
                                (ptr-write-u64 dst 24 (ptr-read-u64 src 24))
                                (setq i (+ i 1)))))
                       (if (/= r 0) (extern-call HeapFree (extern-call GetProcessHeap) 0 r) 0)
                       ,(cs--s 's 'ring 'nr) ,(cs--s 's 'ring_cap 'ncap)
                       ,(cs--s 's 'ring_head 0)
                       0)))))))
      ;; Queue one snapshot unless it equals the previous one; returns the
      ;; sequence number or 0 when nothing was queued.
      (defun cs_pub_push (s modep open comp)
        (seq
         (cs_pub_enter s)
         (let ((lm ,(cs--f 's 'lp_mode)) (res 0) (post 0))
           (seq
            (if (and (= (cs_weq modep (if (= lm 0) (data-addr w_cs_empty) (wbuf_ptr lm))) 1)
                     (= open ,(cs--f 's 'lp_open)) (= comp ,(cs--f 's 'lp_comp)))
                0
              (let ((sq (cs_next_seq s)) (nm (wbuf_from_w modep)))
                (if (= nm 0) 0
                  (seq
                   (cs_wassign ,(cs--a 's 'lp_mode) modep (wbuf_wcslen modep))
                   ,(cs--s 's 'lp_open 'open) ,(cs--s 's 'lp_comp 'comp)
                   (if (= ,(cs--f 's 'ring_count) ,(cs--f 's 'ring_cap))
                       (cs_ring_grow s) 0)
                   (let ((idx (% (+ ,(cs--f 's 'ring_head) ,(cs--f 's 'ring_count))
                                 ,(cs--f 's 'ring_cap))))
                     (let ((e (+ ,(cs--f 's 'ring) (* ,ring idx))))
                       (seq
                        (ptr-write-u32 e 0 sq) (ptr-write-u32 e 4 open)
                        (ptr-write-u32 e 8 comp) (ptr-write-u64 e 16 nm)
                        (if (/= (ptr-read-u64 (data-addr cs_race_yield) 0) 0)
                            (extern-call Sleep 0) 0)
                        ,(cs--s 's 'ring_count `(+ 1 ,(cs--f 's 'ring_count)))
                        (setq res sq)
                        (if (and (= ,(cs--f 's 'queued) 0) (/= ,(cs--f 's 'post) 0))
                            (setq post 1) 0)
                        0)))))))
            (cs_pub_leave s)
            (if (= post 1)
                ,(cs--s 's 'queued `(if (/= (call-ptr ,(cs--f 's 'post) s) 0) 1 0))
              0)
            res))))
      ;; QueuePublishedState; COMP-IN is the engine state's composing level
      ;; (0..2) or 99 for a null state.
      (defun cs_queue (s comp-in)
        (if (or (= ,(cs--f 's 'publish) 0) (= ,(cs--f 's 'active) 0)) 0
          (seq
           (if (<= comp-in 2) ,(cs--s 's 'composing 'comp-in) 0)
           (let ((lm ,(cs--f 's 'last_mode)))
             (let ((modep (if (or (= lm 0) (= (wbuf_len lm) 0)) (data-addr w_cs_hiragana)
                            (wbuf_ptr lm)))
                   (open (if (/= ,(cs--f 's 'open) 0) 1 0)))
               (cs_pub_push s modep open
                            (if (= open 1) ,(cs--f 's 'composing) 0)))))))
      ;; Clients\<pid> path as a new wbuf.
      (defun cs_clients_path ()
        (let ((pid (wbuf_new 32)))
          (if (= pid 0) 0
            (seq (wbuf_append_u64 pid (logand (extern-call GetCurrentProcessId) ,u32))
                 (let ((p (cs_key_path (data-addr w_cs_clients) (wbuf_ptr pid))))
                   (seq (wbuf_free pid) p))))))
      (defun cs_wdw (s hk name v)
        (seq ,(cs--s 's 'q_val 'v)
             (extern-call RegSetValueExW hk name 0 4 ,(cs--a 's 'q_val) 4)))
      ;; FlushPublishedState.
      (defun cs_flush (s)
        (seq
         ,(cs--s 's 'queued 0)
         (if (or (= ,(cs--f 's 'active) 0) (= ,(cs--f 's 'publish) 0)) 0
           (seq
            (cs_wr_enter)
            (cs_cb_lock s 1)
            (let ((path (cs_clients_path)))
              (seq
               (if (= path 0) 0
                 (if (= (logand (extern-call RegCreateKeyExW ,hkcu (wbuf_ptr path) 0 0 0 2 0
                                              ,(cs--a 's 'q_hk) 0)
                                ,u32)
                        0)
                     (let ((hk ,(cs--f 's 'q_hk)))
                       (seq
                        (cs_pub_enter s)
                        (let ((i 0) (n ,(cs--f 's 'ring_count)))
                          (while (< i n)
                            (let ((e (+ ,(cs--f 's 'ring)
                                        (* ,ring (% (+ ,(cs--f 's 'ring_head) i)
                                                    ,(cs--f 's 'ring_cap))))))
                              (let ((sq (ptr-read-u32 e 0)) (mw (ptr-read-u64 e 16)))
                                (seq
                                 (if (> sq (cs_flushed_get s))
                                     (seq
                                      (cs_wdw s hk (data-addr w_cs_revision) (- (* sq 2) 1))
                                      (extern-call RegSetValueExW hk (data-addr w_cs_mode) 0 1
                                                   (wbuf_ptr mw) (* 2 (+ 1 (wbuf_len mw))))
                                      (cs_wdw s hk (data-addr w_cs_open) (ptr-read-u32 e 4))
                                      (cs_wdw s hk (data-addr w_cs_composing) (ptr-read-u32 e 8))
                                      (cs_wdw s hk (data-addr w_cs_sequence) sq)
                                      (cs_wdw s hk (data-addr w_cs_revision) (* sq 2))
                                      (cs_flushed_set s sq)
                                      (if (< ,(cs--f 's 'trace_n) ,ddskk-core-settings-trace-max)
                                          (seq (ptr-write-u32 ,(cs--a 's 'trace)
                                                              (* 4 ,(cs--f 's 'trace_n)) sq)
                                               ,(cs--s 's 'trace_n `(+ 1 ,(cs--f 's 'trace_n)))
                                               0)
                                        0))
                                   0)
                                 (setq i (+ i 1)))))))
                        (cs_ring_clear s)
                        (cs_pub_leave s)
                        (extern-call RegCloseKey hk)))
                   0))
               (wbuf_free path)))
            (cs_cb_lock s 0)
            (cs_wr_leave)
            0))))
      ;; RemovePublishedState.
      (defun cs_remove (s)
        (seq
         ,(cs--s 's 'active 0)
         (cs_pub_enter s)
         (cs_ring_clear s)
         (cs_pub_leave s)
         ,(cs--s 's 'queued 0)
         (if (= ,(cs--f 's 'registered) 0) 0
           (seq
            ,(cs--s 's 'registered 0)
            (let ((pubs (cs_pub_delta s -1)))
              (seq
               ,(cs--s 's 'lp_open 0) ,(cs--s 's 'lp_comp 0)
               (cs_wfree ,(cs--a 's 'lp_mode))
               (cs_wr_enter)
               (cs_cb_lock s 1)
               (if (= (logand pubs ,u32) 0)
                   (let ((path (cs_clients_path)))
                     (if (= path 0) 0
                       (seq (extern-call RegDeleteTreeW ,hkcu (wbuf_ptr path))
                            (wbuf_free path)
                            0)))
                 0)
               (cs_cb_lock s 0)
               (cs_wr_leave)
               0))))
         0)))))

(defun ddskk-core-settings--watcher-forms ()
  (let ((u32 ddskk-core-settings-u32) (hkcu nelisp-com-hkey-current-user)
        (prime ddskk-core-settings-fnv-prime))
    `(;; FNV-1a style mix of N bytes at P into the hash stored at H.
      (defun cs_mix (h p n)
        (let ((i 0) (x (ptr-read-u64 h 0)))
          (seq (while (< i n)
                 (let ((b (ptr-read-u8 p i)))
                   (seq (setq x (* (- (logior x b) (logand x b)) ,prime))
                        (setq i (+ i 1)))))
               (ptr-write-u64 h 0 x)
               0)))
      ;; NativeImeSettingsFingerprint(key, root, include_core).  Context block:
      ;; +0 maxsub +4 maxname +8 maxdata +12 length +16 size +20 type
      ;; +24 hash +32 child key +40 child hash.
      (defun cs_fp (key root incl)
        (let ((ctx (extern-call HeapAlloc (extern-call GetProcessHeap) 8 64)))
          (if (= ctx 0) 0
            (seq
             (ptr-write-u64 ctx 24 ,ddskk-core-settings-fnv-basis)
             (extern-call RegQueryInfoKeyW key 0 0 0 0 (+ ctx 0) 0 0 (+ ctx 4) (+ ctx 8) 0 0)
             (let ((nchars (+ 2 (let ((a (ptr-read-u32 ctx 4)) (b (ptr-read-u32 ctx 0)))
                                  (if (> a b) a b))))
                   (dsz (+ 1 (ptr-read-u32 ctx 8))))
               (let ((name (extern-call HeapAlloc (extern-call GetProcessHeap) 8 (* 2 nchars)))
                     (data (extern-call HeapAlloc (extern-call GetProcessHeap) 8 dsz)))
                 (seq
                  (if (or (= name 0) (= data 0)) 0
                    (let ((i 0) (go 1))
                      (seq
                       (while (= go 1)
                         (seq (ptr-write-u32 ctx 12 nchars) (ptr-write-u32 ctx 16 dsz)
                              (if (/= (logand (extern-call RegEnumValueW key i name (+ ctx 12) 0
                                                           (+ ctx 20) data (+ ctx 16))
                                              ,u32)
                                      0)
                                  (setq go 0)
                                (seq
                                 (if (and (= root 1) (= incl 0)
                                          (= (cs_wieq name (data-addr w_cs_coredll)) 1))
                                     0
                                   (seq (cs_mix (+ ctx 24) name (* 2 (ptr-read-u32 ctx 12)))
                                        (cs_mix (+ ctx 24) (+ ctx 20) 4)
                                        (cs_mix (+ ctx 24) data (ptr-read-u32 ctx 16))
                                        0))
                                 (setq i (+ i 1))))))
                       (setq i 0) (setq go 1)
                       (while (= go 1)
                         (seq (ptr-write-u32 ctx 12 nchars)
                              (if (/= (logand (extern-call RegEnumKeyExW key i name (+ ctx 12)
                                                           0 0 0 0)
                                              ,u32)
                                      0)
                                  (setq go 0)
                                (seq
                                 (if (and (= root 1)
                                          (= (cs_wieq name (data-addr w_cs_clientsname)) 1))
                                     0
                                   (seq
                                    (cs_mix (+ ctx 24) name (* 2 (ptr-read-u32 ctx 12)))
                                    (if (= (logand (extern-call RegOpenKeyExW key name 0 131097
                                                                (+ ctx 32))
                                                   ,u32)
                                           0)
                                        (seq (ptr-write-u64 ctx 40 (cs_fp (ptr-read-u64 ctx 32) 0 incl))
                                             (cs_mix (+ ctx 24) (+ ctx 40) 8)
                                             (extern-call RegCloseKey (ptr-read-u64 ctx 32))
                                             0)
                                      0)
                                    0))
                                 (setq i (+ i 1))))))
                       0)))
                  (let ((h (ptr-read-u64 ctx 24)))
                    (seq (if (/= name 0) (extern-call HeapFree (extern-call GetProcessHeap) 0 name) 0)
                         (if (/= data 0) (extern-call HeapFree (extern-call GetProcessHeap) 0 data) 0)
                         (extern-call HeapFree (extern-call GetProcessHeap) 0 ctx)
                         h)))))))))
      ;; ---- RegistryWatcher ----
      (defun cs_wk_new (include_core)
        (let ((w (DdskkWatcher_alloc)))
          (seq (if (/= w 0) ,(cs--ws 'w 'include_core 'include_core) 0) w)))
      (defun cs_wk_main (w)
        (let ((key ,(cs--wf 'w 'key)) (ic ,(cs--wf 'w 'include_core))
              (waits ,(cs--wa 'w 'waits)) (go 1))
          (let ((fp (cs_fp key 1 ic)))
            (seq
             ,(cs--ws 'w 'fingerprint 'fp)
             ,(cs--ws 'w 'ready 1)
             (while (= go 1)
               (if (= (logand (extern-call WaitForMultipleObjects 2 waits 0 ,u32) ,u32) 1)
                   (let ((st (logand (extern-call RegNotifyChangeKeyValue key 1 5
                                                  ,(cs--wf 'w 'changed) 1)
                                     ,u32)))
                     (let ((next (cs_fp key 1 ic)))
                       (seq (if (/= next fp) ,(cs--ws 'w 'dirty 1) 0)
                            (setq fp next)
                            ,(cs--ws 'w 'fingerprint 'fp)
                            ,(cs--ws 'w 'wakeups `(+ 1 ,(cs--wf 'w 'wakeups)))
                            (if (/= st 0) (setq go 0) 0))))
                 (setq go 0)))
             (extern-call RegCloseKey key)
             (extern-call CloseHandle ,(cs--wf 'w 'changed))
             ,(cs--ws 'w 'exited 1)
             0))))
      ;; Stop(): signal, join (MS milliseconds, 4294967295 = INFINITE), close.
      ;; Returns the WaitForSingleObject result (0 = joined).
      (defun cs_wk_stop_ms (w ms)
        (let ((r 0))
          (seq
           (if (/= ,(cs--wf 'w 'stop) 0) (extern-call SetEvent ,(cs--wf 'w 'stop)) 0)
           (if (/= ,(cs--wf 'w 'thread) 0)
               (seq (setq r (logand (extern-call WaitForSingleObject ,(cs--wf 'w 'thread) ms) ,u32))
                    (if (= r 0)
                        (seq (extern-call CloseHandle ,(cs--wf 'w 'thread))
                             ,(cs--ws 'w 'thread 0))
                      0))
             0)
           (if (and (/= ,(cs--wf 'w 'stop) 0) (= r 0))
               (seq (extern-call CloseHandle ,(cs--wf 'w 'stop)) ,(cs--ws 'w 'stop 0))
             0)
           r)))
      (defun cs_wk_stop (w) (cs_wk_stop_ms w ,u32))
      ;; Start(): returns 1 when the thread runs.
      (defun cs_wk_start (w)
        (let ((kw (cs_regkey)) (ok 0) (nst 0))
          (seq
           (cs_wk_stop w)
           ,(cs--ws 'w 'ready 0) ,(cs--ws 'w 'exited 0) ,(cs--ws 'w 'dirty 0)
           ,(cs--ws 'w 'stop '(extern-call CreateEventW 0 1 0 0))
           ,(cs--ws 'w 'changed '(extern-call CreateEventW 0 0 0 0))
           (if (or (= ,(cs--wf 'w 'stop) 0) (= ,(cs--wf 'w 'changed) 0) (= kw 0)) 0
             (if (/= (logand (extern-call RegOpenKeyExW ,hkcu (wbuf_ptr kw) 0 131097
                                          ,(cs--wa 'w 'key))
                             ,u32)
                     0)
                 0
               (seq
                (setq nst (logand (extern-call RegNotifyChangeKeyValue ,(cs--wf 'w 'key) 1 5
                                               ,(cs--wf 'w 'changed) 1)
                                  ,u32))
                (if (/= nst 0)
                    (extern-call RegCloseKey ,(cs--wf 'w 'key))
                  (seq
                   ;; Cover a write between the initial LoadSettings and this arm.
                   ,(cs--ws 'w 'dirty 1)
                   (ptr-write-u64 ,(cs--wa 'w 'waits) 0 ,(cs--wf 'w 'stop))
                   (ptr-write-u64 ,(cs--wa 'w 'waits) 8 ,(cs--wf 'w 'changed))
                   ,(cs--ws 'w 'thread
                            '(extern-call CreateThread 0 0 (addr-of cs_wk_main) w 0 0))
                   (if (/= ,(cs--wf 'w 'thread) 0) (setq ok 1)
                     (extern-call RegCloseKey ,(cs--wf 'w 'key)))
                   0)))))
           (if (= ok 1) 0
             (seq (if (/= ,(cs--wf 'w 'changed) 0) (extern-call CloseHandle ,(cs--wf 'w 'changed)) 0)
                  ,(cs--ws 'w 'changed 0)
                  (cs_wk_stop w)
                  0))
           (wbuf_free kw)
           ok)))
      ;; dirty.exchange(false)
      (defun cs_wk_take (w)
        (atomic-compare-exchange ,(cs--wa 'w 'dirty) 1 0)))))

(cl-defun ddskk-core-settings-forms (&key no-lock)
  "Return the AOT forms of the settings library.
NO-LOCK makes the per-service publication lock a no-op (negative control)."
  (cl-subst
   'cs_mod '%
   (append (ddskk-core-settings-blobs)
          (nelisp-com-struct-forms 'DdskkSettings)
          (nelisp-com-struct-forms 'DdskkWatcher)
          (ddskk-core-settings--lock-forms no-lock)
          (ddskk-core-settings--util-forms)
          (ddskk-core-settings--settings-forms)
          (ddskk-core-settings--watcher-forms))))

(provide 'ddskk-core-settings)
;;; ddskk-core-settings.el ends here
