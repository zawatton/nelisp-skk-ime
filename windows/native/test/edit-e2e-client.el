;;; edit-e2e-client.el --- mock-host client for the S3i edit-session core  -*- lexical-binding: t; -*-

;;; Commentary:

;; Builds edit-e2e.exe: the mock TSF objects of host-mock.el (context, range,
;; composition, property, view, category manager) plus a driver that loads the
;; native core DLL (DDSKK_CORE_PATH, built with the CoreApplyState test
;; exports) through NativeImeGetCoreApi, creates the core with a fake callback
;; table and feeds scripted engine states through CoreApplyState.  Each state
;; runs inside a StateEditSession requested on the mock context (so the whole
;; trace of ApplyEngineState is the mock's method trace).
;;
;; Fake shim pieces (the real shim forwards through tip_term / cb_track, see
;; ddskk-shim.el; the stand-ins below follow ShimService::OnCompositionTerminated
;; of shim_service.cpp:232-243):
;;   cb_query    query_service: ITfCompositionSink -> the fake sink object
;;   cb_track    track_ending: identity list with an AddRef per entry
;;   fsk_term    ITfCompositionSink::OnCompositionTerminated: acknowledge a
;;               tracked composition, else invoke NI_COMPOSITION_END on the core
;; The mock composition calls the sink synchronously from EndComposition
;; (global `endsink').

;;; Code:

(require 'cl-lib)
(require 'host-mock)
(require 'ddskk-shim)

(defvar ee--wlits nil)
(defvar ee/kind 'mock "`mock' (host-mock objects) or `wine' (real msctf).")
(defun ee/w (str)
  "Form giving the address of the UTF-16 literal STR."
  (let ((e (assoc str ee--wlits)))
    (unless e
      (setq e (cons str (intern (format "w_ee_%d" (length ee--wlits)))))
      (push e ee--wlits))
    `(data-addr ,(cdr e))))

(defun ee/fn (i) `(ptr-read-u64 (data-addr ee_fn) ,(* 8 i)))

(defconst ee/exports
  '("CoreApplyState" "CoreTerminate" "CoreEditProbe" "CoreEditSizes"))

(defun ee/api (f) (nelisp-com-field '(ptr-read-u64 (data-addr hg) 288) 'NativeImeCoreApi f))

(defun ee/wine-script ()
  "Real-msctf script: a direct commit through RequestEditSession + GetSelection.
wine's ITfRange::SetText is a stub (E_NOTIMPL), so the edit session result is
E_NOTIMPL; what is verified is that the lock, the edit session and
GetSelection are reached through the real context."
  `(defun ee_script ()
     (seq
      (step ,(tsf/s "direct-commit") ,(ee/w "hiragana") (- 0 1) ,(ee/w "あ") 0 0 0 0)
      ,(tsf/p "STORE lock>0=") (ob_hex (if (> ,(tsf/g 'n-lock) 0) 1 0))
      ,(tsf/p " getsel>0=") (ob_hex (if (> ,(tsf/g 'n-getsel) 0) 1 0))
      ,(tsf/p " settext=") (ob_hex ,(tsf/g 'n-settext)) (ob_nl)
      0)))

(defun ee/driver-forms ()
  (let ((st '(ptr-read-u64 (data-addr hg) 296))
        (probe (lambda (i) `(call-ptr ,(ee/fn 2) ,i))))
    `(;; ---- fake composition sink (class fsk) ----
      (defun fsk_term (this ec comp)
        (seq ,(tsf/p "Sink::OnCompositionTerminated ec=") (ob_hex ec) ,(tsf/p " comp=") (hm_pp comp) (ob_nl)
             (let ((i (trk_find comp)))
               (if (/= i 99)
                   (seq (trk_remove i) ,(nelisp-com-call 'comp 2)
                        ,(tsf/p "SINK acknowledged ending composition") (ob_nl) 0)
                 (let ((call (extern-call HeapAlloc ,(tsf/g 'heap) 8 ,(nelisp-com-struct-size 'NativeImeCall))))
                   (seq ,(nelisp-com-set-field 'call 'NativeImeCall 'context 'comp)
                        ,(nelisp-com-set-field 'call 'NativeImeCall 'wparam 'ec)
                        (let ((hr (call-ptr ,(ee/api 'invoke) ,st 6 call)))
                          (seq ,(tsf/p "SINK forwarded NI_COMPOSITION_END hr=") (ob_hexn (logand hr 4294967295) 8) (ob_nl)
                               (extern-call HeapFree ,(tsf/g 'heap) 0 call) 0))))))))
      (defun hm_pp (p) (if (= p 0) (ob_ch 48) (ob_ch 80)))
      (data-blob ee_trk ,(make-list 64 0) data)
      (defun trk_find (comp)
        (let ((i 0) (r 99))
          (seq (while (and (/= comp 0) (< i 8))
                 (if (= (ptr-read-u64 (data-addr ee_trk) (* 8 i)) comp)
                     (seq (setq r i) (setq i 8))
                   (setq i (+ i 1))))
               r)))
      (defun trk_free ()
        (let ((i 0))
          (seq (while (and (< i 7) (/= (ptr-read-u64 (data-addr ee_trk) (* 8 i)) 0))
                 (setq i (+ i 1)))
               i)))
      (defun trk_remove (i) (seq (ptr-write-u64 (data-addr ee_trk) (* 8 i) 0) 0))
      (defun cb_track (owner comp flag)
        (seq ,(tsf/p "CB track_ending flag=") (ob_hex (logand flag 4294967295)) (ob_nl)
             (let ((i (trk_find comp)))
               (if (/= (logand flag 4294967295) 0)
                   (if (/= i 99) 0
                     (let ((free (trk_free)))
                       (seq (ptr-write-u64 (data-addr ee_trk) (* 8 free) comp)
                            ,(nelisp-com-call 'comp 1) 0)))
                 (if (= i 99) 0
                   (seq (trk_remove i) ,(nelisp-com-call 'comp 2) 0))))
             0))
      (defun cb_query (owner guid ppv)
        (if ,(nelisp-com-guid= 'guid 'IID_ITfCompositionSink)
            (let ((s ,(tsf/g 'sink)))
              (seq ,(nelisp-com-call 's 1) (ptr-write-u64 ppv 0 s) 0))
          (seq (ptr-write-u64 ppv 0 0) 2147500034)))
      (defun cb_notify (owner) 0)
      (defun cb_pubseq (owner) 1)
      (defun cb_pubdelta (owner d) 1)
      (defun cb_publock (owner l) 0)
      (defun cb_pubflushed (owner) 0)
      ;; ---- helpers ----
      (defun gp (m name idx)
        (let ((p (extern-call GetProcAddress m name)))
          (if (= p 0) (extern-call ExitProcess (+ 90 idx))
            (seq (ptr-write-u64 (data-addr ee_fn) (* 8 idx) p) 0))))
      (defun ee_after ()
        (seq ,(tsf/p "  doc=") (ob_utf8hex ,(tsf/g 'text) ,(tsf/g 'tlen))
             ,(tsf/p " mock_comp=") (ob_ch (+ 48 ,(tsf/g 'comp)))
             ,(tsf/p " core_comp=") (ob_hex ,(funcall probe 0))
             ,(tsf/p " refs=") (ob_hex ,(funcall probe 8))
             ,(tsf/p " sel=") (ob_hex ,(tsf/g 'sels)) (ob_ch 44) (ob_hex ,(tsf/g 'sele))
             ,(tsf/p " caret=") (ob_hex ,(funcall probe 2))
             (ob_ch 44) (ob_hex ,(funcall probe 3)) (ob_ch 44) (ob_hex ,(funcall probe 4))
             (ob_ch 44) (ob_hex ,(funcall probe 5)) (ob_ch 44) (ob_hex ,(funcall probe 6))
             (ob_nl) (ob_flush) 0))
      ;; spec words: mode comp_start text pend nseg sstart slen
      (defun step (name mode cs text pend nseg sstart slen)
        (let ((spec (data-addr ee_spec)))
          (seq ,(tsf/p "=== ") (ob_s name) (ob_nl)
               (ptr-write-u64 spec 0 mode) (ptr-write-u64 spec 8 cs)
               (ptr-write-u64 spec 16 text) (ptr-write-u64 spec 24 pend)
               (ptr-write-u64 spec 32 nseg) (ptr-write-u64 spec 40 sstart)
               (ptr-write-u64 spec 48 slen)
               (let ((hr (call-ptr ,(ee/fn 0) ,(tsf/g 'tm) ,(tsf/g 'ctxo) spec)))
                 (seq ,(tsf/p "  request hr=") (ob_hexn (logand hr 4294967295) 8)
                      ,(tsf/p " edit hr=") (ob_hexn ,(funcall probe 1) 8) (ob_nl)))
               (ee_after))))
      (defun term_step (name settle)
        (seq ,(tsf/p "=== ") (ob_s name) (ob_nl)
             (let ((c (call-ptr ,(ee/fn 1) ,(tsf/g 'ctxo) settle)))
               (seq ,(tsf/p "  cleared=") (ob_hex c) (ob_nl)))
             (ee_after)))
      (defun host_terminate (name)
        ;; the application ends the composition on its own
        (let ((comp ,(funcall probe 7)))
          (seq ,(tsf/p "=== ") (ob_s name) (ob_nl)
               ,(tsf/gs 'comp 0)
               (let ((sink ,(tsf/g 'sink)))
                 ,(nelisp-com-call 'sink 3 4097 'comp))
               (ee_after))))
      (defun ee_main ()
        (if (> (extern-call GetEnvironmentVariableW (data-addr w_envcore) (data-addr pathbuf) 520) 0)
            (let ((m (extern-call LoadLibraryW (data-addr pathbuf))))
              (if (= m 0) 80
                (seq (gp m (data-addr a_ee_api) 3)
                     (gp m (data-addr a_ee_apply) 0) (gp m (data-addr a_ee_term) 1)
                     (gp m (data-addr a_ee_probe) 2) (gp m (data-addr a_ee_sizes) 4)
                     (let ((api (extern-call HeapAlloc ,(tsf/g 'heap) 8 ,(nelisp-com-struct-size 'NativeImeCoreApi)))
                           (cb (extern-call HeapAlloc ,(tsf/g 'heap) 8 ,(nelisp-com-struct-size 'NativeImeCallbacks)))
                           (fsk (fsk_new)))
                       (seq
                        ,(tsf/gs 'sink 'fsk) ,(tsf/gs 'api 'api) ,(tsf/gs 'cbo 'cb)
                        ,(tsf/gs 'endsink 1)
                        (let ((hr (call-ptr ,(ee/fn 3) 1 ,(nelisp-com-struct-size 'NativeImeCoreApi) api)))
                          (if (/= hr 0) 81
                            (seq
                             ,(nelisp-com-set-field 'cb 'NativeImeCallbacks 'size (nelisp-com-struct-size 'NativeImeCallbacks))
                             ,(nelisp-com-set-field 'cb 'NativeImeCallbacks 'version 1)
                             ,(nelisp-com-set-field 'cb 'NativeImeCallbacks 'owner 'cb)
                             ,@(cl-loop for (f fn) in '((query_service cb_query) (notify_mode cb_notify)
                                                        (track_ending cb_track) (publication_sequence cb_pubseq)
                                                        (publisher_delta cb_pubdelta) (publication_lock cb_publock)
                                                        (publication_flushed cb_pubflushed))
                                        collect (nelisp-com-set-field 'cb 'NativeImeCallbacks f `(addr-of ,fn)))
                             (let ((hr2 (call-ptr ,(ee/api 'create) cb (+ (data-addr hg) 296))))
                               (if (or (/= hr2 0) (= ,st 0)) 82
                                 (seq (ee_script)
                                      (call-ptr ,(ee/api 'destroy) ,st)
                                      0)))))))))))
          83))
      (defun ee_sizes ()
        (seq ,(tsf/p "SIZES TF_SELECTION=") (ob_hex (call-ptr ,(ee/fn 4) 0))
             ,(tsf/p " TF_SELECTIONSTYLE=") (ob_hex (call-ptr ,(ee/fn 4) 1))
             ,(tsf/p " VARIANT=") (ob_hex (call-ptr ,(ee/fn 4) 2))
             ,(tsf/p " TF_DISPLAYATTRIBUTE=") (ob_hex (call-ptr ,(ee/fn 4) 3)) (ob_nl) 0))
      ,(if (eq ee/kind 'wine) (ee/wine-script) `(defun ee_script ()
        (seq
         (ee_sizes)
         (step ,(tsf/s "preedit-start") ,(ee/w "hiragana") 0 ,(ee/w "▽か") 0 0 0 0)
         (step ,(tsf/s "preedit-update") ,(ee/w "hiragana") 0 ,(ee/w "▽かん") ,(ee/w "k") 0 0 0)
         (step ,(tsf/s "candidate") ,(ee/w "candidate") 0 ,(ee/w "▼漢字") 0 0 0 0)
         (step ,(tsf/s "segments") ,(ee/w "hiragana") 0 ,(ee/w "▼漢字かな") 0 1 1 2)
         (step ,(tsf/s "commit-ends-composition") ,(ee/w "hiragana") (- 0 1) ,(ee/w "漢字かな") 0 0 0 0)
         (step ,(tsf/s "direct-commit") ,(ee/w "hiragana") (- 0 1) ,(ee/w "あ") 0 0 0 0)
         (step ,(tsf/s "cancel-start") ,(ee/w "hiragana") 0 ,(ee/w "▽ひ") 0 0 0 0)
         (step ,(tsf/s "cancel") ,(ee/w "hiragana") (- 0 1) 0 0 0 0 0)
         (step ,(tsf/s "term-start") ,(ee/w "hiragana") 0 ,(ee/w "▽か") 0 0 0 0)
         (host_terminate ,(tsf/s "host-terminates"))
         (step ,(tsf/s "settle-start") ,(ee/w "hiragana") 0 ,(ee/w "▽ふ") 0 0 0 0)
         (term_step ,(tsf/s "terminate-settle") 1)
         (step ,(tsf/s "erase-start") ,(ee/w "hiragana") 0 ,(ee/w "▽へ") 0 0 0 0)
         (term_step ,(tsf/s "terminate-erase") 0)
         ,(tsf/p "=== end ctx_refs=") (ob_hex (ptr-read-u64 ,(tsf/g 'ctxo) 8)) (ob_nl)
         0)))
      (defun _start ()
        (seq
         (if (/= (buf_init) 0) (extern-call ExitProcess 2) 0)
         (let ((tm (tm_new)) (cx (ctx_new)) (vw (view_new)))
           (if (or (= tm 0) (= cx 0) (= vw 0)) (extern-call ExitProcess 3)
             (seq ,(tsf/gs 'tm 'tm) ,(tsf/gs 'ctxo 'cx) ,(tsf/gs 'viewo 'vw)
                  (let ((rc (ee_main)))
                    (seq (ob_flush) (extern-call ExitProcess rc)))))))))))

(defun ee/blobs ()
  (append
   (list (nelisp-com-wstr-blob 'w_envcore "DDSKK_CORE_PATH")
         (nelisp-com-ascii-blob 'a_ee_api "NativeImeGetCoreApi")
         (nelisp-com-ascii-blob 'a_ee_apply "CoreApplyState")
         (nelisp-com-ascii-blob 'a_ee_term "CoreTerminate")
         (nelisp-com-ascii-blob 'a_ee_probe "CoreEditProbe")
         (nelisp-com-ascii-blob 'a_ee_sizes "CoreEditSizes")
         (nelisp-com-zero-blob 'ee_fn 64)
         (nelisp-com-zero-blob 'ee_spec 64))
   (nelisp-com-msctf-blobs '(IID_ITfCompositionSink))))

(defun edit-e2e-forms ()
  (let ((tsf--lits nil) (ee--wlits nil))
    (let* ((fsk (nelisp-com-class-forms
                 'fsk :interfaces `((:iid ,(nelisp-com-msctf-guid 'IID_ITfCompositionSink)
                                     :methods (fsk_term)))))
           (forms (append (tsf/core-forms) (hm/object-forms) fsk (ee/driver-forms))))
      (append (tsf/lit-blobs)
              (mapcar (lambda (e) (nelisp-com-wstr-blob (cdr e) (car e))) (reverse ee--wlits))
              (ee/blobs)
              (cl-remove-if (lambda (b) (cl-find-if (lambda (f) (and (eq (car f) 'data-blob) (eq (nth 1 f) (nth 1 b)))) forms))
                            (nelisp-com-msctf-blobs nil))
              forms))))

(defun edit-e2e-client-build (path)
  "Build the mock-host client PATH."
  (tsf-build-exe path (nelisp-com-dedupe-blobs (edit-e2e-forms))))

(defun edit-wine-forms ()
  (require 'host-wine)
  (let ((tsf--lits nil) (ee--wlits nil) (ee/kind 'wine))
    (let* ((fsk (nelisp-com-class-forms
                 'fsk :interfaces `((:iid ,(nelisp-com-msctf-guid 'IID_ITfCompositionSink)
                                     :methods (fsk_term)))))
           (start (cl-subst `(seq ,(tsf/gs 'ctxo '(ptr-read-u64 b 112)) (ee_main))
                            '(host_run tm (ptr-read-u64 b 104) (ptr-read-u64 b 112))
                            (hw/start-forms) :test #'equal))
           (forms (append (tsf/core-forms) (hw/store-forms) fsk
                          (cl-remove-if (lambda (f) (and (eq (car f) 'defun) (eq (nth 1 f) '_start)))
                                        (ee/driver-forms))
                          start)))
      (append (tsf/lit-blobs)
              (mapcar (lambda (e) (nelisp-com-wstr-blob (cdr e) (car e))) (reverse ee--wlits))
              (ee/blobs)
              (nelisp-com-msctf-blobs '(IID_ITfThreadMgr CLSID_TF_ThreadMgr))
              forms))))

(defun edit-wine-client-build (path)
  "Build the real-msctf client PATH."
  (tsf-build-exe path (nelisp-com-dedupe-blobs (edit-wine-forms))))

(provide 'edit-e2e-client)
;;; edit-e2e-client.el ends here
