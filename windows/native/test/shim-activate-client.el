;;; shim-activate-client.el --- Activate/Deactivate test client for the S3d shim  -*- lexical-binding: t; -*-

;;; Commentary:

;; Builds shim-activate-<mode>.exe, an STA host on wine's real msctf that
;; drives the native shim (ddskk-shim.el) built with NELISP_SHIM_TEST_EXPORTS=1
;; and the stub core (stub-core.el).  Two modes:
;;
;;   proxy  CoCreateInstance(CLSID_TF_ThreadMgr), ThreadMgr::Activate, load the
;;          shim like tsf_host.cpp (DDSKK_HARNESS_DLL_PATH, DllGetClassObject),
;;          and pass a DirectThreadMgr proxy to ITfTextInputProcessor::Activate.
;;          The proxy answers QI(ITfKeystrokeMgr) with a recording key-stroke
;;          manager (AdviseKeyEventSink / UnadviseKeyEventSink are counted and
;;          the sink is AddRef'd / Release'd like msctf does) and forwards every
;;          other QI (ITfCompartmentMgr) to the real wine thread manager.
;;   real   ActivateLanguageProfile(CLSID, GetUserDefaultLangID(), profile)
;;          through the registered class; msctf instantiates the shim itself.
;;          The sink is fetched through the test export DdskkShimStat(4).
;;
;; Both modes then call OnSetFocus / OnTestKeyDown / OnKeyDown / OnTestKeyUp /
;; OnKeyUp / OnPreservedKey on the sink directly (wine's KeystrokeMgr::KeyDown
;; is a stub), pump messages for the 50 ms timer, and Deactivate.
;;
;; Env: DDSKK_HARNESS_DLL_PATH (shim), DDSKK_STUB_CORE_PATH (stub core: the
;; client reads its counters through StubCoreCounter).

;;; Code:

(require 'cl-lib)
(require 'tsf-test-common)
(require 'ddskk-shim)

(defconst shim-activate-imports
  (append tsf-host-imports
          '(("kernel32.dll" "GetUserDefaultLangID"))))

(defun sac/stat (i) `(call-ptr ,(tsf/g 'viewo) ,i))
(defun sac/cnt (i) `(call-ptr ,(tsf/g 'ctxo) ,i))

(defun shim-activate-forms (mode)
  "Return the client forms for MODE (`proxy' or `real')."
  (let ((g #'tsf/g) (gs #'tsf/gs) (proxy (eq mode 'proxy)))
    (append
     (list (nelisp-com-wstr-blob 'w_envstub "DDSKK_STUB_CORE_PATH")
           (nelisp-com-ascii-blob 'a_stat "DdskkShimStat")
           (nelisp-com-ascii-blob 'a_cnt "StubCoreCounter")
           (nelisp-com-guid-blob 'g_profile ddskk-shim-profile-guid)
           `(data-blob px_obj ,(make-list 16 0) data ((0 px_vt 0)))
           `(data-blob km_obj ,(make-list 8 0) data ((0 km_vt 0)))
           `(data-blob kmst ,(make-list 64 0) data)
           (nelisp-com-vtable 'px_vt '(px_qi px_addref px_release))
           (nelisp-com-vtable 'km_vt '(km_qi km_addref km_release km_advise km_unadvise)))
     (nelisp-com-msctf-blobs '(IID_ITfThreadMgr CLSID_TF_ThreadMgr
                               CLSID_TF_InputProcessorProfiles
                               IID_ITfInputProcessorProfiles))
     `(;; ---- DirectThreadMgr proxy ----
       (defun px_qi (this riid ppv)
         (if (= ppv 0) ,nelisp-com-e-pointer
           (if ,(nelisp-com-guid= 'riid 'IID_ITfKeystrokeMgr)
               (seq (ptr-write-u64 ppv 0 (data-addr km_obj)) 0)
             (let ((real (ptr-read-u64 this 8)))
               ,(nelisp-com-call 'real 0 'riid 'ppv)))))
       (defun px_addref (this) 2)
       (defun px_release (this) 1)
       (defun km_qi (this riid ppv) (seq (ptr-write-u64 ppv 0 0) ,nelisp-com-e-nointerface))
       (defun km_addref (this) 2)
       (defun km_release (this) 1)
       (defun km_advise (this tid sink fg)
         (seq (atomic-fetch-add (data-addr kmst) 1)
              (ptr-write-u64 (data-addr kmst) 16 sink)
              (ptr-write-u64 (data-addr kmst) 24 tid)
              (ptr-write-u64 (data-addr kmst) 32 fg)
              ,(nelisp-com-call 'sink 1)
              0))
       (defun km_unadvise (this tid)
         (seq (atomic-fetch-add (+ (data-addr kmst) 8) 1)
              (if (= (ptr-read-u64 (data-addr kmst) 16) 0)
                  ,nelisp-com-e-invalidarg
                (let ((sk (ptr-read-u64 (data-addr kmst) 16)))
                  (seq (ptr-write-u64 (data-addr kmst) 16 0)
                       ,(nelisp-com-call 'sk 2)
                       0)))))
       ;; ---- reporting ----
       (defun p_kv (name v) (seq (ob_s name) (ob_hex v)))
       (defun report_counters ()
         (seq ,(tsf/p "CORE create=") (ob_hex ,(sac/cnt 0))
              ,(tsf/p " destroy=") (ob_hex ,(sac/cnt 1))
              ,(tsf/p " activate=") (ob_hex ,(sac/cnt 2))
              ,(tsf/p " deactivate=") (ob_hex ,(sac/cnt 3))
              ,(tsf/p " ops=") (ob_hex ,(sac/cnt 4)) (ob_ch 44) (ob_hex ,(sac/cnt 5))
              (ob_ch 44) (ob_hex ,(sac/cnt 6)) (ob_ch 44) (ob_hex ,(sac/cnt 7))
              (ob_ch 44) (ob_hex ,(sac/cnt 8)) (ob_ch 44) (ob_hex ,(sac/cnt 9))
              ,(tsf/p " eaten=") (ob_hex ,(sac/cnt 24))
              (ob_nl)))
       (defun report_activate_facts ()
         (seq ,(tsf/p "CORE tm_nonnull=") (ob_hex ,(sac/cnt 21))
              ,(tsf/p " cb_valid=") (ob_hex ,(sac/cnt 23))
              ,(tsf/p " pubseq=") (ob_hex ,(sac/cnt 25))
              ,(tsf/p " query_sink=") (ob_hexn ,(sac/cnt 26) 8)
              ,(tsf/p " tm_addref_ok=") (ob_hex (if (> ,(sac/cnt 27) 1) 1 0))
              (ob_nl)))
       (defun report_win (ticks_needed)
         (seq ,(tsf/p "WIN created=") (ob_hex ,(sac/stat 0))
              ,(tsf/p " destroyed=") (ob_hex ,(sac/stat 1))
              ,(tsf/p " timer=") (ob_hex (if (> ,(sac/stat 2) 0) 1 0))
              (ob_nl)))
       ;; One sink call: slot 4 TestKeyDown, 5 TestKeyUp, 6 KeyDown, 7 KeyUp.
       (defun kstep (sink slot vk)
         (seq (ptr-write-u32 (data-addr tmpbuf) 32 3735928559)
              (let ((hr (call-ptr (ptr-read-u64 (ptr-read-u64 sink 0) (* 8 slot))
                                  sink 0 vk 1 (+ (data-addr tmpbuf) 32))))
                (seq ,(tsf/p "KEY slot=") (ob_hex slot) ,(tsf/p " vk=") (ob_hexn vk 2)
                     ,(tsf/p " hr=") (ob_hexn hr 8)
                     ,(tsf/p " eaten=") (ob_hexn (ptr-read-u32 (data-addr tmpbuf) 32) 8)
                     ,(tsf/p " pair=") (ob_hex ,(sac/stat 3))
                     (ob_nl)))))
       (defun run_keys (sink)
         (seq
          (let ((hr ,(nelisp-com-call 'sink 3 1)))
            (seq ,(tsf/p "FOCUS hr=") (ob_hexn hr 8) (ob_nl)))
          (kstep sink 4 65) (kstep sink 6 65) (kstep sink 5 65)
          (kstep sink 4 65) (kstep sink 7 65)
          (kstep sink 4 49) (kstep sink 6 49) (kstep sink 5 49)
          (ptr-write-u32 (data-addr tmpbuf) 32 3735928559)
          (let ((hr ,(nelisp-com-call 'sink 8 0 '(data-addr g_clsid_tip)
                                      '(+ (data-addr tmpbuf) 32))))
            (seq ,(tsf/p "PRESERVED hr=") (ob_hexn hr 8)
                 ,(tsf/p " eaten=") (ob_hexn (ptr-read-u32 (data-addr tmpbuf) 32) 8) (ob_nl)))
          0))
       ;; Pump messages for about N*20 ms so the 50 ms timer fires.
       (defun pump_for (n)
         (let ((i 0)) (while (< i n) (seq (pump) (extern-call Sleep 20) (setq i (+ i 1))))))
       (defun resolve ()
         (seq (let ((m (extern-call LoadLibraryW (data-addr pathbuf))))
                ,(funcall gs 'viewo '(extern-call GetProcAddress m (data-addr a_stat))))
              (if (> (extern-call GetEnvironmentVariableW (data-addr w_envstub) (data-addr pathbuf) 520) 0)
                  (let ((m (extern-call LoadLibraryW (data-addr pathbuf))))
                    ,(funcall gs 'ctxo '(extern-call GetProcAddress m (data-addr a_cnt))))
                0)
              0))
       (defun fail (n hr)
         (seq ,(tsf/p "FAIL step=") (ob_hex n) ,(tsf/p " hr=") (ob_hexn hr 8) (ob_nl)
              (ob_flush) (extern-call ExitProcess n)))
       (defun st (n hr) (if (/= (logand hr 2147483648) 0) (fail n hr) 0))
       (defun _start ()
         (seq
          (if (/= (buf_init) 0) (extern-call ExitProcess 2) 0)
          (st 1 (extern-call CoInitializeEx 0 2))
          (st 2 (extern-call CoCreateInstance (data-addr CLSID_TF_ThreadMgr) 0 1
                             (data-addr IID_ITfThreadMgr) ,(tsf/ga 'tmp)))
          (let ((tm ,(funcall g 'tmp)))
            (seq ,(funcall gs 'tm 'tm)
                 (st 3 ,(nelisp-com-call 'tm 3 (tsf/ga 'tid)))
                 ,(if proxy
                      `(seq (ptr-write-u64 (data-addr px_obj) 8 tm)
                            (let ((tip (load_tip)))
                              (if (= tip 0) (seq ,(tsf/p "FAIL no TIP loaded") (ob_nl) (ob_flush) (extern-call ExitProcess 3))
                                (seq (resolve)
                                     (let ((hr ,(nelisp-com-call 'tip 3 '(data-addr px_obj) (tsf/g 'tid))))
                                       (seq ,(tsf/p "HR Activate=") (ob_hexn hr 8) (ob_nl)
                                            (if ,(nelisp-com-failed 'hr)
                                                (seq (report_win 0)
                                                     ,(tsf/p "KM advise=") (ob_hex (ptr-read-u64 (data-addr kmst) 0)) (ob_nl))
                                              (proxy_run tip))
                                            (let ((hrd ,(nelisp-com-call 'tip 4)))
                                              (seq ,(tsf/p "HR Deactivate=") (ob_hexn hrd 8) (ob_nl)
                                                   (if ,(nelisp-com-failed 'hr) 0
                                                     (seq (report_win 1) (report_counters)
                                                          ,(tsf/p "KM unadvise=")
                                                          (ob_hex (ptr-read-u64 (data-addr kmst) 8))
                                                          (ob_nl)))))
                                            (let ((n ,(nelisp-com-call 'tip 2)))
                                              (seq ,(tsf/p "REL tip=") (ob_hex n) (ob_nl)))
                                            (ob_flush)
                                            (extern-call ExitProcess 0)))))))
                    `(real_run tm)))))))
     `(;; proxy mode body once Activate succeeded
       (defun proxy_run (tip)
         (seq (report_activate_facts)
              (report_win 0)
              ,(tsf/p "KM advise=") (ob_hex (ptr-read-u64 (data-addr kmst) 0))
              ,(tsf/p " fg=") (ob_hex (ptr-read-u64 (data-addr kmst) 32))
              ,(tsf/p " tid_match=")
              (ob_hex (if (= (ptr-read-u64 (data-addr kmst) 24) ,(funcall g 'tid)) 1 0))
              ,(tsf/p " sink_is_tip=")
              (ob_hex (if (= (ptr-read-u64 (data-addr kmst) 16) (+ tip 16)) 1 0))
              (ob_nl)
              ,(tsf/p "WIN compartment=") (ob_hex ,(sac/stat 5)) (ob_nl)
              (let ((hr2 ,(nelisp-com-call 'tip 3 '(data-addr px_obj) (tsf/g 'tid))))
                (seq ,(tsf/p "HR Activate2=") (ob_hexn hr2 8) (ob_nl)))
              (let ((hr3 ,(nelisp-com-call 'tip 0 '(data-addr IID_ITfKeyEventSink)
                                           '(+ (data-addr tmpbuf) 16))))
                (if ,(nelisp-com-failed 'hr3) ,(tsf/p "FAIL no ITfKeyEventSink")
                  (let ((sink (ptr-read-u64 (data-addr tmpbuf) 16)))
                    (seq (run_keys sink)
                         (pump_for 15)
                         (report_win 1)
                         (report_counters)
                         ,(nelisp-com-call 'sink 2)
                         0))))
              0))
       (defun real_run (tm)
         (seq
          (st 10 (extern-call CoCreateInstance (data-addr CLSID_TF_InputProcessorProfiles) 0 1
                              (data-addr IID_ITfInputProcessorProfiles) ,(tsf/ga 'tmp)))
          (let ((pr ,(funcall g 'tmp)))
            (let ((hr ,(nelisp-com-call 'pr 10 '(data-addr g_clsid_tip)
                                        '(logand (extern-call GetUserDefaultLangID) 65535)
                                        '(data-addr g_profile))))
              (seq ,(tsf/p "HR ActivateLanguageProfile=") (ob_hexn hr 8) (ob_nl)
                   ,(nelisp-com-call 'pr 2)
                   (extern-call GetEnvironmentVariableW (data-addr w_envdll) (data-addr pathbuf) 520)
                   (resolve)
                   (let ((i 0))
                     (while (and (< i 100) (= ,(sac/cnt 2) 0))
                       (seq (pump) (extern-call Sleep 20) (setq i (+ i 1)))))
                   ,(tsf/p "REAL core_activate=") (ob_hex ,(sac/cnt 2)) (ob_nl)
                   (pump_for 5)
                   ,(tsf/p "ADVISE hr=") (ob_hexn ,(sac/stat 6) 8) (ob_nl)
                   (report_counters)
                   (report_win 0)
                   (let ((sink ,(sac/stat 4)))
                     (if (= sink 0) (seq ,(tsf/p "REAL no sink: Activate was rolled back") (ob_nl))
                       (seq ,(nelisp-com-call 'sink 1)
                            (report_activate_facts)
                            (report_win 0)
                            (run_keys sink)
                            (pump_for 15)
                            (report_win 1)
                            (report_counters)
                            ,(nelisp-com-call 'sink 2)
                            0)))
                   (let ((hrd ,(nelisp-com-call 'tm 4)))
                     (seq ,(tsf/p "HR ThreadMgr::Deactivate=") (ob_hexn hrd 8) (ob_nl)))
                   (pump_for 10)
                   (report_win 1)
                   (report_counters)
                   (ob_flush)
                   (extern-call ExitProcess 0))))))))))

(defun shim-activate-client-build (path mode)
  "Build the client PATH for MODE (`proxy' or `real')."
  (let ((tsf--lits nil))
    (let ((forms (append (tsf/core-forms) (shim-activate-forms mode))))
      (setq max-lisp-eval-depth (max max-lisp-eval-depth 100000))
      (nelisp-com-build-exe path (append (tsf/lit-blobs) forms) shim-activate-imports))))

(provide 'shim-activate-client)
;;; shim-activate-client.el ends here
