;;; ddskk-core.el --- native core DLL skeleton (ddskk-ime-core.dll)  -*- lexical-binding: t; -*-

;;; Commentary:

;; Sub-stage S3h of the native TSF DLL project.  AOT forms (restricted NeLisp
;; subset, COM DSL) for the core side of the shim/core split of
;; windows/src/core_abi.h + core_entry.cpp + text_service.cpp:
;;
;;   NativeImeGetCoreApi         exported; fills the NativeImeCoreApi table
;;   ts_create / ts_destroy      core_entry.cpp Create / Destroy
;;   ts_activate / ts_deactivate TextService::Activate / Deactivate (shim path)
;;   ts_invoke                   core_entry.cpp Invoke (NativeImeOperation)
;;   ts_follow_settings          FollowSettings (uses ddskk-core-settings.el)
;;   ts_read_open                ReadKeyboardOpen
;;   ts_apply_open_change        ApplyKeyboardOpenChange
;;   ts_would_claim              WouldClaimKey
;;   ts_on_test_key_down         OnTestKeyDown
;;   ts_translate                TranslateKey (GetKeyboardState + ToUnicodeEx)
;;   select engine / engine id / mode label  SelectInputEngine, SelectEngineId, ...
;;
;; State struct `DdskkTs' holds the TextService fields S3h needs; the settings
;; object of ddskk-core-settings.el carries last_engine_mode_ (its `last_mode'),
;; the published open/composing state and the engine id string.
;;
;; Deliberate differences from the C++ source:
;;  * Activate does not advise the key sink or the open/close compartment: with
;;    a shim (shim_.query_service is mandatory in Create) the C++ core returns
;;    before AdviseKeyEventSink / AdviseOpenCloseCompartment, because the stable
;;    shim owns both and forwards NI_COMPARTMENT.  Those C++ paths are dead for
;;    the core DLL and are not ported.
;;  * No engine client yet (S3f): every engine round trip is a hook that
;;    defaults to "engine unavailable" (Connect false, SelectEngine false,
;;    Reset/SendKey/SendControl nullopt).  OnTestKeyDown therefore behaves as
;;    the C++ code does with an unreachable engine.
;;  * Hooks (process-global table `core_hooks', slots listed in
;;    `ddskk-core-hook-slots'; install with the :hooks keyword of
;;    `ddskk-core-forms'):  wide-latin / preedit / set-input-mode /
;;    realtime-load for the realtime frontend (S3g), engine-connect /
;;    engine-select for the engine client (S3f), on-key-down for S3j.
;;
;; Fields deferred to later stages (not in `DdskkTs'): ref_count_ (the core is
;; owned by the shim), engine_ (S3f), realtime_frontend_ (S3g), provider_* /
;; deferred_provider_keys_ / provider_window_ / last_host_spawn_ (S3k),
;; ending_compositions_ (S3i), candidate_ui_* / candidate_context_ /
;; candidate_index_ / candidate_count_ (S3l), mode_indicator_* /
;; last_mode_label_ / last_caret_* / indicator_* (S3n), settings_button_ /
;; input_mode_button_ (langbar, S3o), debug_log_ (settings object), registration
;; commit state (S3j), open_close_cookie_ (shim), engine_roundtrip_failed_.
;; `composition_', `active_context_' and `registration_range_' exist as
;; pointers but only the release paths are ported (S3i fills them).
;;
;; Deferred operations: NI_COMPOSITION_END (S3i; returns S_OK without effect),
;; NI_PALETTE (S3n; E_NOTIMPL), NI_SETTINGS (S3o; S_OK no-op), NI_RELOAD (S3f,
;; needs an engine control connection; S_OK no-op), the engine parts of
;; NI_TOGGLE / NI_MODE / SelectInputEngine (hooks), OnKeyDown proper (S3j; the
;; placeholder runs the C++ prologue and returns *eaten = FALSE).
;;
;; Build hooks of `ddskk-core-build-from-env':
;;   NELISP_CORE_BAD_ABI=1       report ABI version 999
;;   NELISP_CORE_TEST_EXPORTS=1  add the CoreProbe* exports
;;   NELISP_CORE_MUTANT=vk-table|open-inverted   negative-control mutants

;;; Code:

(require 'cl-lib)
(require 'ddskk-shim)
(require 'ddskk-core-settings)

(defconst ddskk-core-hook-slots
  '(wide-latin preedit set-input-mode realtime-load engine-connect
    engine-select on-key-down on-composition-end)
  "Hook slot names; slot N is word N of the `core_hooks' table.")

(defconst ddskk-core-imports
  (let ((extra '(("kernel32.dll" "GetProcessHeap" "HeapAlloc" "HeapFree")
                 ("user32.dll" "GetKeyState" "GetAsyncKeyState" "GetKeyboardState"
                  "ToUnicodeEx" "GetKeyboardLayout" "CharLowerBuffW")
                 ("oleaut32.dll" "VariantClear")))
        (out nil))
    (dolist (entry (append ddskk-core-settings-imports extra))
      (let ((cell (assoc (car entry) out)))
        (if cell
            (dolist (n (cdr entry)) (unless (member n (cdr cell)) (nconc cell (list n))))
          (push (cons (car entry) (copy-sequence (cdr entry))) out))))
    (nreverse out))
  "Imports of the core DLL.")

(defconst ddskk-core-exports '("NativeImeGetCoreApi"))
(defconst ddskk-core-test-exports
  '("CoreProbe" "CoreProbeTranslate" "CoreProbeEngineId"
    "CoreProbeLabel" "CoreProbeReadOpen"))

(nelisp-com-defstruct NativeImeSnapshot
  (size u32) (version u32) (open u32) (kana u32) (closed_kana u32)
  (needs_resync u32) (mode (array u16 32)) (closed_mode (array u16 32))
  (session (bytes 96 1)) (engine_pipe u64))

(nelisp-com-defstruct DdskkTs
  (tm ptr) (cb ptr) (settings ptr) (watcher ptr) (composition ptr)
  (active_context ptr) (registration_range ptr) (closed_mode ptr)
  (p1 ptr) (p2 ptr) (hk u64)
  (client_id u32) (keyboard_open u32) (kana_mode u32) (closed_kana u32)
  (ddskk_engine u32) (engine_kind u32) (engine_pending u32)
  (registration_mode u32) (provider_active u32) (tested_ctrl u32)
  (needs_resync u32) (wide_latin u32) (n_open_change u32) (n_load u32)
  (ctrl_override u32) (shift_override u32)
  (variant (bytes 24 8)) (idw (array u16 40)) (kbstate (bytes 256 8))
  (tbuf (array u16 8)))

(defun ct--f (p f) (nelisp-com-field p 'DdskkTs f))
(defun ct--s (p f v) (nelisp-com-set-field p 'DdskkTs f v))
(defun ct--a (p f) (nelisp-com-field-addr p 'DdskkTs f))

(defun ct--hook-index (slot)
  (or (cl-position slot ddskk-core-hook-slots) (error "Unknown hook slot %S" slot)))

(defun ct--hook (slot default &rest args)
  "Form calling hook SLOT with ARGS, or evaluating DEFAULT when unset."
  `(let ((h (ptr-read-u64 (data-addr core_hooks) ,(* 8 (ct--hook-index slot)))))
     (if (= h 0) ,default (call-ptr h ,@args))))

(defconst ct--u32 4294967295)
(defconst ct--e-pending 2147483658)

(defun ct--blobs ()
  (append
   (nelisp-com-msctf-blobs '(IID_ITfCompartmentMgr GUID_COMPARTMENT_KEYBOARD_OPENCLOSE))
   (cl-loop for (name str) in
            '((w_ct_lattice "lattice") (w_ct_dictionary "dictionary")
              (w_ct_candidate "candidate") (w_ct_widelatin "wide-latin")
              (w_ct_abbrev "abbrev") (w_ct_kana "かな")
              (w_ct_katakana "カナ") (w_ct_skk "SKK")
              (w_ct_wide "全英") (w_ct_abbrevlbl "Abbrev")
              (w_ct_closed "--"))
            collect (nelisp-com-wstr-blob name str))
   (list (nelisp-com-ascii-blob 'a_ct_diag "ddskk-core-nelisp s3h")
         (nelisp-com-ascii-blob 'a_ct_ddskk "ddskk")
         (nelisp-com-ascii-blob 'a_ct_lattice "lattice")
         (nelisp-com-ascii-blob 'a_ct_dictionary "dictionary")
         (nelisp-com-ascii-blob 'a_ct_passthrough "passthrough")
         (nelisp-com-zero-blob 'core_hooks 64)
         (nelisp-com-zero-blob 'core_last 8))))

(defun ddskk-core--hook-installer (hooks)
  `(defun ct_install_hooks ()
     (seq ,@(cl-loop for (slot . fn) in hooks
                     collect `(ptr-write-u64 (data-addr core_hooks)
                                             ,(* 8 (ct--hook-index slot)) (addr-of ,fn)))
          0)))

(defun ddskk-core--util-forms ()
  `((defun ct_narrow_is (p lit)
      (let ((i 0) (r 1) (go 1))
        (seq (while (= go 1)
               (let ((a (ptr-read-u8 p i)) (b (ptr-read-u8 lit i)))
                 (seq (if (= a b) 0 (setq r 0))
                      (if (or (= a 0) (= b 0)) (setq go 0) (setq i (+ i 1))))))
             r)))
    (defun ct_ctrl_down (ts)
      (let ((o ,(ct--f 'ts 'ctrl_override)))
        (if (/= o 0) (if (= o 2) 1 0)
          (let ((k (logand (extern-call GetKeyState 17) 65535)))
            (if (/= (logand k 32768) 0) 1
              (let ((a (logand (extern-call GetAsyncKeyState 17) 65535)))
                (if (/= (logand a 32768) 0) 1 0)))))))
    (defun ct_shift_down (ts)
      (let ((o ,(ct--f 'ts 'shift_override)))
        (if (/= o 0) (if (= o 2) 1 0)
          (let ((k (logand (extern-call GetKeyState 16) 65535)))
            (if (/= (logand k 32768) 0) 1 0)))))
    ;; The wide-latin / preedit queries of the realtime frontend (S3g).
    (defun ct_wide_latin (ts)
      ,(ct--hook 'wide-latin (ct--f 'ts 'wide_latin) 'ts))
    (defun ct_rt_preedit (ts) ,(ct--hook 'preedit 0 'ts))
    (defun ct_last_mode_is (ts lit)
      (let ((lm ,(nelisp-com-field (ct--f 'ts 'settings) 'DdskkSettings 'last_mode)))
        (if (= lm 0) 0 (wbuf_eq_w lm lit))))
    (defun ct_set_last_mode (ts lit)
      (seq (cs_wassign ,(nelisp-com-field-addr (ct--f 'ts 'settings) 'DdskkSettings 'last_mode)
                       lit (wbuf_wcslen lit))
           0))
    (defun ct_queue (ts comp)
      (let ((s ,(ct--f 'ts 'settings)))
        (seq ,(cs--s 's 'open (ct--f 'ts 'keyboard_open))
             (cs_queue s comp)
             0)))))

;;; ---- settings, FollowSettings --------------------------------------------

(defun ddskk-core--settings-forms ()
  `((defun ct_engine_kind (ts)
      (let ((e ,(cs--a (ct--f 'ts 'settings) 'engine)))
        (if (= (cs_weq e (data-addr w_cs_ddskk)) 1) 0
          (if (= (cs_weq e (data-addr w_ct_lattice)) 1) 1
            (if (= (cs_weq e (data-addr w_ct_dictionary)) 1) 2
              (if (= (cs_weq e (data-addr w_cs_passthrough)) 1) 3 4))))))
    ;; LoadSettings (the registry reads live in cs_load).
    (defun ct_load_settings (ts)
      (let ((s ,(ct--f 'ts 'settings)))
        (seq (cs_load s)
             ,(ct--s 'ts 'ddskk_engine (cs--f 's 'ddskk))
             ,(ct--s 'ts 'engine_kind '(ct_engine_kind ts))
             ,(ct--s 'ts 'kana_mode (cs--f 's 'kana))
             ,(ct--s 'ts 'engine_pending 0)
             ,(ct--s 'ts 'provider_active 0)
             ,(ct--s 'ts 'n_load `(+ ,(ct--f 'ts 'n_load) 1))
             ,(ct--hook 'realtime-load 0 'ts)
             0)))
    ;; FollowSettings: reload only when idle and the watcher flagged a change.
    (defun ct_follow_settings (ts)
      (if (or (/= ,(ct--f 'ts 'composition) 0) (/= ,(ct--f 'ts 'engine_pending) 0)
              (/= ,(ct--f 'ts 'registration_mode) 0) (/= ,(ct--f 'ts 'provider_active) 0)
              (/= (ct_rt_preedit ts) 0))
          0
        (if (= (cs_wk_take ,(ct--f 'ts 'watcher)) 0) 0
          (seq (ct_load_settings ts)
               ,(ct--s 'ts 'needs_resync 1)
               (ct_queue ts 99)
               0))))
    (defun ct_publishes_or_open_mode (ts)
      (let ((s ,(ct--f 'ts 'settings)))
        (if (/= ,(cs--f 's 'publish) 0) 1
          (if (= (cs_weq (wbuf_ptr ,(cs--f 's 'open_mode)) (data-addr w_cs_restore)) 1) 0 1))))))

;;; ---- keyboard open/close -------------------------------------------------

(defun ddskk-core--open-forms (mutant)
  (ignore mutant)
  `((defun ct_read_open (ts fallback)
      (let ((tm ,(ct--f 'ts 'tm)) (open fallback) (var ,(ct--a 'ts 'variant)))
        (if (= tm 0) fallback
          (seq
           (cs_zero var 24)
           ,(ct--s 'ts 'p1 0) ,(ct--s 'ts 'p2 0)
           (if ,(nelisp-com-succeeded
                 (nelisp-com-call 'tm 0 '(data-addr IID_ITfCompartmentMgr) (ct--a 'ts 'p1)))
               (let ((mgr ,(ct--f 'ts 'p1)))
                 (seq
                  (if ,(nelisp-com-succeeded
                        (nelisp-com-call 'mgr 3 '(data-addr GUID_COMPARTMENT_KEYBOARD_OPENCLOSE)
                                         (ct--a 'ts 'p2)))
                      (let ((c ,(ct--f 'ts 'p2)))
                        (seq
                         (if ,(nelisp-com-succeeded (nelisp-com-call 'c 4 'var))
                             (if (= (logand (ptr-read-u16 var 0) 65535) 3)
                                 (setq open (if (/= (logand (ptr-read-u32 var 8) ,ct--u32) 0) 1 0))
                               0)
                           0)
                         (extern-call VariantClear var)
                         ,(nelisp-com-call 'c 2)
                         0))
                    0)
                  ,(nelisp-com-call 'mgr 2)
                  0))
             0)
           open))))
    ;; ApplyKeyboardOpenChange.  The engine Reset / SendKey / SendControl calls
    ;; of the C++ source are unavailable without the engine client (S3f), so the
    ;; "engine returned no state" branches run.
    (defun ct_apply_open_change (ts)
      (seq
       ,(ct--s 'ts 'n_open_change `(+ ,(ct--f 'ts 'n_open_change) 1))
       (if (/= (ct_publishes_or_open_mode ts) 0) (ct_follow_settings ts) 0)
       (let ((open (ct_read_open ts ,(ct--f 'ts 'keyboard_open))))
         (if (= open ,(ct--f 'ts 'keyboard_open)) 0
           (seq
            (if (= open 0)
                (seq ,(ct--s 'ts 'closed_kana (ct--f 'ts 'kana_mode))
                     (let ((lm ,(cs--f (ct--f 'ts 'settings) 'last_mode)))
                       (wbuf_clear ,(ct--f 'ts 'closed_mode))
                       (if (= lm 0) 0 (wbuf_append_w ,(ct--f 'ts 'closed_mode) (wbuf_ptr lm)))
                       0))
              0)
            ,(ct--s 'ts 'keyboard_open 'open)
            (if (and (= open 0)
                     (or (/= ,(ct--f 'ts 'engine_pending) 0)
                         (/= ,(ct--f 'ts 'registration_mode) 0)
                         (/= ,(ct--f 'ts 'composition) 0)))
                (seq (ct_release_ptr ,(ct--a 'ts 'registration_range))
                     ,(ct--s 'ts 'registration_mode 0)
                     ,(ct--s 'ts 'engine_pending 0)
                     ,(ct--s 'ts 'provider_active 0)
                     (ct_release_ptr ,(ct--a 'ts 'composition))
                     0)
              (if (/= open 0)
                  (seq ,(ct--s 'ts 'kana_mode (ct--f 'ts 'closed_kana))
                       (ct_set_last_mode_wbuf ts ,(ct--f 'ts 'closed_mode))
                       (if (and (= (ct_open_mode_is_restore ts) 0) (/= ,(ct--f 'ts 'ddskk_engine) 0))
                           (seq ,(ct--hook 'set-input-mode 0 'ts
                                           `(wbuf_ptr ,(cs--f (ct--f 'ts 'settings) 'open_mode)))
                                ,(ct--s 'ts 'needs_resync 1)
                                ,(ct--s 'ts 'kana_mode
                                        `(if (= (cs_weq (wbuf_ptr ,(cs--f (ct--f 'ts 'settings) 'open_mode))
                                                        (data-addr w_cs_latin)) 1) 0 1))
                                0)
                         0)
                       0)
                0))
            (if (= open 0) ,(cs--s (ct--f 'ts 'settings) 'composing 0) 0)
            (ct_queue ts 99)
            0)))))
    (defun ct_open_mode_is_restore (ts)
      (cs_weq (wbuf_ptr ,(cs--f (ct--f 'ts 'settings) 'open_mode)) (data-addr w_cs_restore)))
    (defun ct_set_last_mode_wbuf (ts w)
      (seq (cs_wassign ,(cs--a (ct--f 'ts 'settings) 'last_mode) (wbuf_ptr w) (wbuf_len w)) 0))
    (defun ct_release_ptr (slot)
      (let ((p (ptr-read-u64 slot 0)))
        (if (= p 0) 0
          (seq (ptr-write-u64 slot 0 0)
               ,(nelisp-com-call 'p 2)
               0))))))

;;; ---- key claim ------------------------------------------------------------

(defun ddskk-core--key-forms (mutant)
  (let ((z (if (eq mutant 'vk-table) 89 90))
        (open-bad (eq mutant 'open-inverted)))
    `((defun ct_would_claim (ts wp composing)
        (let ((ctl (if (/= ,(ct--f 'ts 'tested_ctrl) 0) 1 (ct_ctrl_down ts))))
          (if (/= ,(ct--f 'ts 'registration_mode) 0)
              (if (and (= wp 71) (= ctl 1)) 1
                (if (= ctl 1) 0
                  (if (or (and (>= wp 65) (<= wp ,z)) (and (>= wp 48) (<= wp 57))
                          (and (>= wp 186) (<= wp 223)) (= wp 226) (= wp 32) (= wp 8)
                          (= wp 46) (= wp 13) (= wp 27) (= wp 37) (= wp 39) (= wp 38)
                          (= wp 40) (= wp 36) (= wp 35) (= wp 117) (= wp 118))
                      1 0)))
            (if (and (= wp 71) (= ctl 1)) composing
              (if (= ctl 1) 0
                (let ((kind ,(ct--f 'ts 'engine_kind)))
                  (if (or (and (>= wp 65) (<= wp ,z)) (and (>= wp 48) (<= wp 57))
                          (and (>= wp 186) (<= wp 192)) (and (>= wp 219) (<= wp 223))
                          (= wp 226)
                          (and (= wp 32) (or (/= composing 0) (/= (ct_wide_latin ts) 0)))
                          (and (= kind 1) (/= composing 0)
                               (or (= wp 37) (= wp 39) (and (>= wp 117) (<= wp 121))))
                          (and (= kind 0) (/= composing 0)
                               (or (and (or (= wp 37) (= wp 39)) (= (ct_shift_down ts) 0))
                                   (= wp 117) (= wp 118)))
                          (and (/= composing 0) (or (= wp 8) (= wp 13) (= wp 27))))
                      1 0)))))))
      (defun ct_set_eaten (pe v) (seq (ptr-write-u32 pe 0 v) 0))
      (defun ct_on_test_key_down (ts ctx wp lp pe)
        (if (= pe 0) ,nelisp-com-e-pointer
          (seq
           (ct_follow_settings ts)
           ,(ct--s 'ts 'tested_ctrl '(ct_ctrl_down ts))
           (let ((ctrl_j (if (and (= wp 74) (/= ,(ct--f 'ts 'tested_ctrl) 0)) 1 0))
                 (rt (if (and (= ,(ct--f 'ts 'provider_active) 0)
                              (= (ct_last_mode_is ts (data-addr w_ct_candidate)) 0)
                              (= ,(ct--f 'ts 'registration_mode) 0))
                         1 0)))
             (if (or (= ,(ct--f 'ts 'ddskk_engine) 0)
                     ,(if open-bad `(/= ,(ct--f 'ts 'keyboard_open) 0)
                        `(= ,(ct--f 'ts 'keyboard_open) 0)))
                 (ct_set_eaten pe 0)
               (if (and (= ctrl_j 1) (= ,(ct--f 'ts 'registration_mode) 0) (= rt 1))
                   (ct_set_eaten pe 1)
                 (if (and (= ctrl_j 1) (= ,(ct--f 'ts 'registration_mode) 0))
                     (ct_set_eaten pe ,(ct--hook 'engine-connect 0 'ts))
                   (if (= ,(ct--f 'ts 'kana_mode) 0)
                       (ct_set_eaten pe 0)
                     (let ((composing (if (or (/= ,(ct--f 'ts 'composition) 0)
                                              (/= ,(ct--f 'ts 'engine_pending) 0))
                                          1 0)))
                       (if (= (ct_would_claim ts wp composing) 0)
                           (ct_set_eaten pe 0)
                         (if (= rt 1)
                             (ct_set_eaten pe 1)
                           ;; Connect failure would call EnsureEngineHost (S3f);
                           ;; the key is claimed either way.
                           (seq ,(ct--hook 'engine-connect 0 'ts)
                                (ct_set_eaten pe 1)))))))))
             )
           0)))
      (defun ct_on_test_key_up (ts pe)
        (if (= pe 0) ,nelisp-com-e-pointer
          (seq ,(ct--s 'ts 'tested_ctrl 0) (ct_set_eaten pe 0) 0)))
      (defun ct_on_preserved (ts pe)
        (if (= pe 0) ,nelisp-com-e-pointer (seq (ct_set_eaten pe 0) 0)))
      ;; OnKeyDown placeholder (S3j): C++ prologue (FollowSettings, null checks,
      ;; active-context switch), then the on-key-down hook or eaten = FALSE.
      (defun ct_on_key_down (ts ctx wp lp pe)
        (seq
         (ct_follow_settings ts)
         (if (= pe 0) ,nelisp-com-e-pointer
           (seq
            (ct_set_eaten pe 0)
            (if (= ctx 0) ,nelisp-com-e-invalidarg
              (seq
               (if (/= ,(ct--f 'ts 'active_context) ctx)
                   (seq (ct_release_ptr ,(ct--a 'ts 'active_context))
                        ,(nelisp-com-call 'ctx 1)
                        ,(ct--s 'ts 'active_context 'ctx)
                        0)
                 0)
               ,(ct--hook 'on-key-down 0 'ts 'ctx 'wp 'lp 'pe)
               0))))))
      ;; TranslateKey: 0xFFFFFFFF = std::nullopt, else the code point.
      (defun ct_translate (ts wp lp)
        (let ((kb ,(ct--a 'ts 'kbstate)) (tb ,(ct--a 'ts 'tbuf)))
          (if (= (logand (extern-call GetKeyboardState kb) ,ct--u32) 0) ,ct--u32
            (let ((layout (extern-call GetKeyboardLayout 0)))
              (let ((n (logand (extern-call ToUnicodeEx (logand wp ,ct--u32)
                                            (logand (/ lp 65536) 255) kb tb 4 0 layout)
                               ,ct--u32)))
                (if (= n 1) (ptr-read-u16 tb 0)
                  (if (and (= n 2) (>= (ptr-read-u16 tb 0) 55296) (<= (ptr-read-u16 tb 0) 56319)
                           (>= (ptr-read-u16 tb 2) 56320) (<= (ptr-read-u16 tb 2) 57343))
                      (+ 65536 (+ (* (- (ptr-read-u16 tb 0) 55296) 1024)
                                  (- (ptr-read-u16 tb 2) 56320)))
                    ,ct--u32))))))))))

;;; ---- engine / mode selection ---------------------------------------------

(defun ddskk-core--select-forms ()
  `(;; SelectInputEngine(ddskk): the engine's SelectEngine call must succeed
    ;; (hook engine-select, default failure) before any state changes.
    (defun ct_select_engine (ts ddskk)
      (let ((target (if (/= ddskk 0) ,(ct--f 'ts 'engine_kind) 3)))
        (if (= ,(ct--hook 'engine-select 0 'ts 'target) 0) 0
          (let ((was ,(ct--f 'ts 'ddskk_engine)))
            (seq
             ,(ct--s 'ts 'ddskk_engine
                     `(if (and (/= ddskk 0) (/= ,(ct--f 'ts 'engine_kind) 3)) 1 0))
             (if (= ddskk 0)
                 (seq ,(ct--s 'ts 'kana_mode 0)
                      (ct_set_last_mode ts (data-addr w_cs_latin))
                      ,(ct--s 'ts 'engine_pending 0)
                      ,(ct--s 'ts 'provider_active 0)
                      0)
               0)
             (ct_queue ts 99)
             0)))))
    ;; SelectEngineId: Engine registry value + watcher dirty + FollowSettings.
    (defun ct_select_engine_id (ts narrow)
      (if (= narrow 0) 0
        (let ((kind (if (= (ct_narrow_is narrow (data-addr a_ct_ddskk)) 1) 1
                      (if (= (ct_narrow_is narrow (data-addr a_ct_lattice)) 1) 1
                        (if (= (ct_narrow_is narrow (data-addr a_ct_dictionary)) 1) 1
                          (if (= (ct_narrow_is narrow (data-addr a_ct_passthrough)) 1) 1 0))))))
          (if (= kind 0) 0
            (let ((idw ,(ct--a 'ts 'idw)) (i 0) (kw (cs_regkey)))
              (seq
               (while (< i 32)
                 (let ((c (ptr-read-u8 narrow i)))
                   (seq (ptr-write-u16 idw (* 2 i) c)
                        (if (= c 0) (setq i 32) (setq i (+ i 1))))))
               (ptr-write-u16 idw 62 0)
               (if (= kw 0) 0
                 (seq
                  (if (= (logand (extern-call RegCreateKeyExW ,nelisp-com-hkey-current-user
                                              (wbuf_ptr kw) 0 0 0 2 0 ,(ct--a 'ts 'hk) 0)
                                 ,ct--u32)
                         0)
                      (seq (if (= (logand (extern-call RegSetValueExW ,(ct--f 'ts 'hk)
                                                       (data-addr w_cs_engine) 0 1 idw
                                                       (* 2 (+ 1 (wbuf_wcslen idw))))
                                          ,ct--u32)
                                  0)
                               (ptr-write-u64 ,(nelisp-com-field-addr (ct--f 'ts 'watcher)
                                                                      'DdskkWatcher 'dirty)
                                              0 1)
                             0)
                           (extern-call RegCloseKey ,(ct--f 'ts 'hk))
                           (ct_follow_settings ts)
                           0)
                    0)
                  (wbuf_free kw)
                  0))
               0))))))
    ;; CurrentModeLabel into LABEL (array u16 32).
    (defun ct_label (ts dst)
      (let ((src (data-addr w_ct_kana)))
        (seq
         (if (= ,(ct--f 'ts 'keyboard_open) 0) (setq src (data-addr w_ct_closed))
           (if (= ,(ct--f 'ts 'kana_mode) 0) (setq src (data-addr w_ct_skk))
             (if (= (ct_last_mode_is ts (data-addr w_cs_hiragana)) 1) (setq src (data-addr w_ct_kana))
               (if (= (ct_last_mode_is ts (data-addr w_cs_katakana)) 1) (setq src (data-addr w_ct_katakana))
                 (if (= (ct_last_mode_is ts (data-addr w_cs_latin)) 1) (setq src (data-addr w_ct_skk))
                   (if (= (ct_last_mode_is ts (data-addr w_ct_widelatin)) 1) (setq src (data-addr w_ct_wide))
                     (if (= (ct_last_mode_is ts (data-addr w_ct_abbrev)) 1) (setq src (data-addr w_ct_abbrevlbl))
                       0)))))))
         (cs_wcopy dst src 32)
         0)))))

;;; ---- lifecycle and Invoke -------------------------------------------------

(defun ddskk-core--life-forms ()
  `((defun ts_create (cb pstate)
      (if (or (= cb 0) (= pstate 0)) ,nelisp-com-e-invalidarg
        (seq
         (ptr-write-u64 pstate 0 0)
         (if (or (/= ,(nelisp-com-field 'cb 'NativeImeCallbacks 'size)
                     ,(nelisp-com-struct-size 'NativeImeCallbacks))
                 (/= ,(nelisp-com-field 'cb 'NativeImeCallbacks 'version) 1)
                 (= ,(nelisp-com-field 'cb 'NativeImeCallbacks 'query_service) 0))
             ,nelisp-com-e-invalidarg
           (let ((hp (extern-call GetProcessHeap)))
             (let ((ts (DdskkTs_alloc)) (cbc (extern-call HeapAlloc hp 8 80))
                   (cm (wbuf_new 64)) (s (cs_new)) (w (cs_wk_new 0)))
               (if (or (= ts 0) (= cbc 0) (= cm 0) (= s 0) (= w 0))
                   (seq (if (= w 0) 0 (seq (cs_wk_stop w) (DdskkWatcher_free w)))
                        (if (= s 0) 0 (cs_free s))
                        (wbuf_free cm)
                        (if (= cbc 0) 0 (extern-call HeapFree hp 0 cbc))
                        (if (= ts 0) 0 (DdskkTs_free ts))
                        ,nelisp-com-e-outofmemory)
                 (let ((i 0))
                   (seq
                    (while (< i 72)
                      (seq (ptr-write-u64 cbc i (ptr-read-u64 cb i)) (setq i (+ i 8))))
                    (wbuf_append_w cm (data-addr w_cs_hiragana))
                    ,(cs--s 's 'cb 'cbc)
                    ,(ct--s 'ts 'cb 'cbc) ,(ct--s 'ts 'settings 's) ,(ct--s 'ts 'watcher 'w)
                    ,(ct--s 'ts 'closed_mode 'cm)
                    ,(ct--s 'ts 'keyboard_open 1) ,(ct--s 'ts 'closed_kana 1)
                    ,(ct--s 'ts 'ddskk_engine 1)
                    (ct_install_hooks)
                    (ptr-write-u64 (data-addr core_last) 0 ts)
                    (ptr-write-u64 pstate 0 ts)
                    0)))))))))
    (defun ts_destroy (ts)
      (if (= ts 0) 0
        (let ((s ,(ct--f 'ts 'settings)) (w ,(ct--f 'ts 'watcher)) (hp (extern-call GetProcessHeap)))
          (seq
           (cs_remove s)
           (cs_wk_stop w)
           (ct_release_ptr ,(ct--a 'ts 'active_context))
           (ct_release_ptr ,(ct--a 'ts 'registration_range))
           (ct_release_ptr ,(ct--a 'ts 'composition))
           (ct_release_ptr ,(ct--a 'ts 'tm))
           (DdskkWatcher_free w)
           (cs_free s)
           (wbuf_free ,(ct--f 'ts 'closed_mode))
           (extern-call HeapFree hp 0 ,(ct--f 'ts 'cb))
           (if (= (ptr-read-u64 (data-addr core_last) 0) ts) (ptr-write-u64 (data-addr core_last) 0 0) 0)
           (DdskkTs_free ts)
           0))))
    ;; Activate for the shim path (shim_.query_service is always set).
    (defun ts_activate (ts tm id)
      (if (= tm 0) ,nelisp-com-e-invalidarg
        (let ((s ,(ct--f 'ts 'settings)))
          (seq
           (ct_release_ptr ,(ct--a 'ts 'tm))
           ,(nelisp-com-call 'tm 1)
           ,(ct--s 'ts 'tm 'tm)
           ,(ct--s 'ts 'client_id '(logand id 4294967295))
           ;; CreateProviderWindow / EnsureEngineHost / warm-up thread: S3k, S3f.
           ,(cs--s 's 'activated 1)
           (ct_load_settings ts)
           ,(cs--s 's 'active 1)
           (cs_wk_start ,(ct--f 'ts 'watcher))
           (ct_follow_settings ts)
           ,(ct--s 'ts 'keyboard_open '(ct_read_open ts 1))
           (ct_queue ts 99)
           ,(ct--s 'ts 'needs_resync 1)
           0))))
    (defun ts_deactivate (ts)
      (let ((s ,(ct--f 'ts 'settings)))
        (seq
         (cs_remove s)
         (cs_wk_stop ,(ct--f 'ts 'watcher))
         (if (or (/= ,(ct--f 'ts 'engine_pending) 0) (/= ,(ct--f 'ts 'registration_mode) 0)
                 (/= ,(ct--f 'ts 'composition) 0))
             ;; ResetAbandonedComposition (engine part: S3f/S3j)
             (seq ,(ct--s 'ts 'engine_pending 0) ,(ct--s 'ts 'registration_mode 0)
                  ,(ct--s 'ts 'provider_active 0)
                  (ct_release_ptr ,(ct--a 'ts 'composition))
                  0)
           0)
         (ct_release_ptr ,(ct--a 'ts 'active_context))
         (ct_release_ptr ,(ct--a 'ts 'tm))
         ,(ct--s 'ts 'client_id 4294967295)
         0)))
    (defun ts_quiescent (ts)
      (if (or (/= ,(ct--f 'ts 'composition) 0) (/= ,(ct--f 'ts 'engine_pending) 0)
              (/= ,(ct--f 'ts 'registration_mode) 0) (/= ,(ct--f 'ts 'provider_active) 0)
              (/= (ct_rt_preedit ts) 0))
          0 1))
    (defun ts_export (ts snap)
      (if (or (= snap 0)
              (/= ,(nelisp-com-field 'snap 'NativeImeSnapshot 'size)
                  ,(nelisp-com-struct-size 'NativeImeSnapshot))
              (/= ,(nelisp-com-field 'snap 'NativeImeSnapshot 'version) 1))
          ,nelisp-com-e-invalidarg
        (if (= (ts_quiescent ts) 0) ,ct--e-pending
          (seq ,(nelisp-com-set-field 'snap 'NativeImeSnapshot 'open (ct--f 'ts 'keyboard_open))
               ,(nelisp-com-set-field 'snap 'NativeImeSnapshot 'kana (ct--f 'ts 'kana_mode))
               ,(nelisp-com-set-field 'snap 'NativeImeSnapshot 'closed_kana (ct--f 'ts 'closed_kana))
               ,(nelisp-com-set-field 'snap 'NativeImeSnapshot 'needs_resync (ct--f 'ts 'needs_resync))
               (cs_zero ,(nelisp-com-field-addr 'snap 'NativeImeSnapshot 'mode) 128)
               (cs_wcopy ,(nelisp-com-field-addr 'snap 'NativeImeSnapshot 'mode)
                         (wbuf_ptr ,(cs--f (ct--f 'ts 'settings) 'last_mode)) 32)
               (cs_wcopy ,(nelisp-com-field-addr 'snap 'NativeImeSnapshot 'closed_mode)
                         (wbuf_ptr ,(ct--f 'ts 'closed_mode)) 32)
               (ptr-write-u8 ,(nelisp-com-field-addr 'snap 'NativeImeSnapshot 'session) 0 0)
               ,(nelisp-com-set-field 'snap 'NativeImeSnapshot 'engine_pipe 0)
               0))))
    (defun ts_import (ts snap)
      (if (or (= snap 0)
              (/= ,(nelisp-com-field 'snap 'NativeImeSnapshot 'size)
                  ,(nelisp-com-struct-size 'NativeImeSnapshot))
              (/= ,(nelisp-com-field 'snap 'NativeImeSnapshot 'version) 1))
          ,nelisp-com-e-invalidarg
        (seq ,(ct--s 'ts 'keyboard_open `(if (/= ,(nelisp-com-field 'snap 'NativeImeSnapshot 'open) 0) 1 0))
             ,(ct--s 'ts 'kana_mode `(if (/= ,(nelisp-com-field 'snap 'NativeImeSnapshot 'kana) 0) 1 0))
             ,(ct--s 'ts 'closed_kana `(if (/= ,(nelisp-com-field 'snap 'NativeImeSnapshot 'closed_kana) 0) 1 0))
             (ct_set_last_mode ts ,(nelisp-com-field-addr 'snap 'NativeImeSnapshot 'mode))
             (wbuf_clear ,(ct--f 'ts 'closed_mode))
             (wbuf_append_w ,(ct--f 'ts 'closed_mode)
                            ,(nelisp-com-field-addr 'snap 'NativeImeSnapshot 'closed_mode))
             ,(ct--hook 'set-input-mode 0 'ts
                        (nelisp-com-field-addr 'snap 'NativeImeSnapshot 'mode))
             (ct_queue ts 99)
             0)))
    (defun ts_invoke (ts op call)
      (if (or (= ts 0) (= call 0)) ,nelisp-com-e-pointer
        (let ((ctx ,(nelisp-com-field 'call 'NativeImeCall 'context))
              (wp ,(nelisp-com-field 'call 'NativeImeCall 'wparam))
              (lp ,(nelisp-com-field 'call 'NativeImeCall 'lparam))
              (pe ,(nelisp-com-field 'call 'NativeImeCall 'eaten))
              (g ,(nelisp-com-field 'call 'NativeImeCall 'guid)))
          (if (= op 0) (seq (ct_follow_settings ts) 0)
            (if (= op 1) (ct_on_test_key_down ts ctx wp lp pe)
              (if (= op 2) (ct_on_key_down ts ctx wp lp pe)
                (if (or (= op 3) (= op 4)) (ct_on_test_key_up ts pe)
                  (if (= op 5) (ct_on_preserved ts pe)
                    (if (= op 6) ,(ct--hook 'on-composition-end 0 'ts 'wp 'ctx)
                      (if (= op 7)
                          (seq (if (and (/= g 0) ,(nelisp-com-guid= 'g 'GUID_COMPARTMENT_KEYBOARD_OPENCLOSE))
                                   (ct_apply_open_change ts) 0)
                               0)
                        (if (= op 8) (seq (ct_select_engine ts wp) 0)
                          (if (= op 9) (seq (ct_select_engine_id ts ,(nelisp-com-field 'call 'NativeImeCall 'narrow)) 0)
                            (if (or (= op 10) (= op 12)) 0
                              (if (or (= op 11) (= op 13))
                                  ;; ToggleInputMode / SelectInputMode: guarded engine round trip
                                  ;; (S3f); without an engine the C++ returns early.
                                  0
                                (if (= op 14) (seq (ct_label ts ,(nelisp-com-field-addr 'call 'NativeImeCall 'label)) 0)
                                  (if (= op 15) ,nelisp-com-e-notimpl
                                    ,nelisp-com-e-invalidarg))))))))))))))))))

(defun ddskk-core--api-forms (bad-abi)
  (let ((api-size (nelisp-com-struct-size 'NativeImeCoreApi)) (u32 ct--u32))
    `((defun NativeImeGetCoreApi (abi size out)
        (if (or (/= (logand abi ,u32) 1) (< (logand size ,u32) ,api-size) (= out 0))
            ,nelisp-com-e-invalidarg
          (seq ,(nelisp-com-set-field 'out 'NativeImeCoreApi 'size api-size)
               ,(nelisp-com-set-field 'out 'NativeImeCoreApi 'version (if bad-abi 999 1))
               ,(nelisp-com-set-field 'out 'NativeImeCoreApi 'diagnostic_version '(data-addr a_ct_diag))
               ,@(cl-loop for (f fn) in '((create ts_create) (destroy ts_destroy)
                                          (activate ts_activate) (deactivate ts_deactivate)
                                          (invoke ts_invoke) (quiescent ts_quiescent)
                                          (export_state ts_export) (import_state ts_import)
                                          (can_unload ts_can_unload) (prepare_unload ts_prepare_unload))
                          collect (nelisp-com-set-field 'out 'NativeImeCoreApi f `(addr-of ,fn)))
               0)))
      ;; Module lifetime (g_object_count) is tracked by the shim's loader cache here.
      (defun ts_can_unload () 1)
      (defun ts_prepare_unload () 0))))

(defun ddskk-core--probe-forms ()
  `((defun CoreProbe (idx)
      (let ((ts (ptr-read-u64 (data-addr core_last) 0)))
        (if (= ts 0) 4294967295
          (if (>= idx 4096) (ct_probe_set_enc ts idx)
          (if (= idx 0) ,(ct--f 'ts 'keyboard_open)
            (if (= idx 1) ,(ct--f 'ts 'kana_mode)
              (if (= idx 2) ,(ct--f 'ts 'closed_kana)
                (if (= idx 3) ,(ct--f 'ts 'ddskk_engine)
                  (if (= idx 4) ,(ct--f 'ts 'engine_kind)
                    (if (= idx 5) ,(ct--f 'ts 'n_open_change)
                      (if (= idx 6) ,(ct--f 'ts 'n_load)
                        (if (= idx 7) ,(ct--f 'ts 'engine_pending)
                          (if (= idx 8) ,(ct--f 'ts 'needs_resync)
                            (if (= idx 9) (ct_last_mode_is ts (data-addr w_ct_candidate))
                              (if (= idx 10) (ct_last_mode_is ts (data-addr w_cs_hiragana))
                                (if (= idx 11) ,(ct--f 'ts 'tested_ctrl)
                                  (if (= idx 12) (ct_quiescent_probe ts)
                                    (if (= idx 13) (if (= ,(ct--f 'ts 'tm) 0) 0 1)
                                      4294967294))))))))))))))))))
    (defun ct_quiescent_probe (ts) (ts_quiescent ts))
    ;; idx: 0 kana 1 engine_pending 2 registration_mode 3 provider_active
    ;; 4 wide_latin 5 last_mode=candidate(1)/hiragana(0) 6 ctrl override
    ;; 7 shift override 8 closed_kana 9 engine_kind
    (defun ct_probe_set_enc (ts idx)
      (let ((f 0) (r idx))
        (seq (while (>= r 8192) (seq (setq r (- r 4096)) (setq f (+ f 1))))
             (ct_probe_set ts f (- r 4096)))))
    (defun ct_probe_set (ts idx v)
      (seq
           (if (= idx 0) ,(ct--s 'ts 'kana_mode '(logand v 1))
             (if (= idx 1) ,(ct--s 'ts 'engine_pending '(logand v 1))
               (if (= idx 2) ,(ct--s 'ts 'registration_mode '(logand v 1))
                 (if (= idx 3) ,(ct--s 'ts 'provider_active '(logand v 1))
                   (if (= idx 4) ,(ct--s 'ts 'wide_latin '(logand v 1))
                     (if (= idx 5)
                         (ct_set_last_mode ts (if (= v 1) (data-addr w_ct_candidate) (data-addr w_cs_hiragana)))
                       (if (= idx 6) ,(ct--s 'ts 'ctrl_override '(logand v 3))
                         (if (= idx 7) ,(ct--s 'ts 'shift_override '(logand v 3))
                           (if (= idx 8) ,(ct--s 'ts 'closed_kana '(logand v 1))
                             (if (= idx 9) ,(ct--s 'ts 'engine_kind '(logand v 7))
                               0))))))))))
           0))
    (defun CoreProbeTranslate (vk)
      (let ((ts (ptr-read-u64 (data-addr core_last) 0)))
        (if (= ts 0) 4294967295 (ct_translate ts vk 0))))
    (defun CoreProbeEngineId (narrow)
      (let ((ts (ptr-read-u64 (data-addr core_last) 0)))
        (if (= ts 0) 1 (seq (ct_select_engine_id ts narrow) 0))))
    (defun CoreProbeLabel (i)
      (let ((ts (ptr-read-u64 (data-addr core_last) 0)))
        (if (= ts 0) 65535
          (seq (ct_label ts ,(ct--a 'ts 'idw))
               (ptr-read-u16 ,(ct--a 'ts 'idw) (* 2 (logand i 31)))))))
    (defun CoreProbeReadOpen (fallback)
      (let ((ts (ptr-read-u64 (data-addr core_last) 0)))
        (if (= ts 0) 4294967295 (ct_read_open ts fallback))))))

(cl-defun ddskk-core-forms (&key test-exports bad-abi mutant hooks)
  "Return the AOT forms of the core DLL.
TEST-EXPORTS adds the CoreProbe* functions, BAD-ABI reports ABI version 999,
MUTANT is nil, `vk-table' or `open-inverted' (negative controls), HOOKS is an
alist (SLOT . FUNCTION-SYMBOL) installed at ts_create."
  (append
   (nelisp-com-wstr-lib-forms)
   (ddskk-core-settings-forms)
   (ct--blobs)
   (nelisp-com-struct-forms 'DdskkTs)
   (list (ddskk-core--hook-installer hooks))
   (ddskk-core--util-forms)
   (ddskk-core--settings-forms)
   (ddskk-core--open-forms mutant)
   (ddskk-core--key-forms mutant)
   (ddskk-core--select-forms)
   (ddskk-core--life-forms)
   (ddskk-core--api-forms bad-abi)
   (and test-exports (ddskk-core--probe-forms))))

(cl-defun ddskk-core-build (path &key test-exports bad-abi mutant hooks)
  "Build the core DLL PATH."
  (setq max-lisp-eval-depth (max max-lisp-eval-depth 100000))
  (nelisp-com-build-dll
   path (cl-subst 'ct_mod '% (ddskk-core-forms :test-exports test-exports :bad-abi bad-abi
                                               :mutant mutant :hooks hooks))
   :exports (sort (append ddskk-core-exports (and test-exports ddskk-core-test-exports)) #'string<)
   :imports ddskk-core-imports
   :dll-name (file-name-nondirectory path))
  path)

(defun ddskk-core-build-from-env (path)
  "Build the core DLL PATH, taking the build hooks from the environment."
  (ddskk-core-build path
                    :test-exports (equal (getenv "NELISP_CORE_TEST_EXPORTS") "1")
                    :bad-abi (equal (getenv "NELISP_CORE_BAD_ABI") "1")
                    :mutant (let ((m (getenv "NELISP_CORE_MUTANT")))
                              (and m (not (string-empty-p m)) (intern m)))))

(provide 'ddskk-core)
;;; ddskk-core.el ends here
