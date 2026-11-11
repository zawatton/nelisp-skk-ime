;;; host-wine.el --- real-msctf TSF test host (STA) built with nelisp  -*- lexical-binding: t; -*-

;;; Commentary:

;; host-wine.exe: a single-threaded-apartment host that uses the platform's
;; msctf (wine's, in the e2e): CoCreateInstance(CLSID_TF_ThreadMgr),
;; ITfThreadMgr::Activate, ITfDocumentMgr + ITfContext backed by our own
;; ITextStoreACP over an in-memory UTF-16 buffer (one selection, locks granted
;; synchronously, fixed GetTextExt rect), then the shared TIP loader/key
;; script runner of tsf-test-common.el (DDSKK_HARNESS_DLL_PATH, tokens as
;; tsf_host.cpp).  The TIP's key sink is called directly, not through
;; ITfKeystrokeMgr (same as tsf_host.cpp).
;;
;; Output: TIP_DIRECT / HR lines, one `AFTER <token> text=<hex> comp=<0|1>'
;; per token, then a COUNTERS line (store call counts; informative, filtered
;; before golden comparison by host-wine-e2e.sh).
;;
;; Known wine limits (design doc section 0): ITfRange::SetText/GetText are
;; stubs and ITfContextComposition is not exposed, so comp stays 0 here; the
;; composition path is exercised by host-mock.el instead.

;;; Code:

(require 'cl-lib)
(require 'tsf-test-common)

(defun hw/store-forms ()
  "ITextStoreACP + ITfContextOwnerCompositionSink backed by the shared buffer."
  (let ((g #'tsf/g) (gs #'tsf/gs) (ni 2147500033))
    (append
     (nelisp-com-class-forms
      'ts :state-size 0
      :interfaces
      `((:iid ,(nelisp-com-msctf-guid 'IID_ITextStoreACP)
         :methods (ts_advise ts_unadvise ts_reqlock ts_status ts_queryins ts_getsel
                   ts_setsel ts_gettext ts_settext ts_getfmt ts_getemb ts_qie
                   ts_inse ts_insat ts_insemb ts_rsa ts_raap ts_rata ts_fnat
                   ts_rra ts_getend ts_getview ts_getacp ts_gettextext ts_getscr))
        (:iid ,(nelisp-com-msctf-guid 'IID_ITfContextOwnerCompositionSink)
         :methods (cs_start cs_update cs_end))))
     (nelisp-com-msctf-blobs '(IID_ITextStoreACPSink IID_ITfThreadMgr
                               CLSID_TF_ThreadMgr))
     `((defun ts_advise (this riid punk mask)
         (let ((hr ,(nelisp-com-call 'punk 0 '(data-addr IID_ITextStoreACPSink)
                                     (tsf/ga 'tmp))))
           (seq (if (= hr 0) ,(funcall gs 'store-sink (tsf/g 'tmp)) 0)
                hr)))
       (defun ts_unadvise (this punk) 0)
       ;; Grant the lock synchronously: OnLockGranted(flags) on the sink.
       (defun ts_reqlock (this flags phr)
         (let ((s ,(funcall g 'store-sink)))
           (seq ,(tsf/ginc 'n-lock)
                (if (= s 0) (seq (ptr-write-u32 phr 0 ,nelisp-com-e-fail) 0)
                  (seq (ptr-write-u32 phr 0 ,(nelisp-com-call 's 8 'flags)) 0)))))
       (defun ts_status (this p) (seq (ptr-write-u32 p 0 0) (ptr-write-u32 p 4 0) 0))
       (defun ts_queryins (this a b n pa pb)
         (seq (ptr-write-u32 pa 0 a) (ptr-write-u32 pb 0 b) 0))
       (defun ts_getsel (this idx cnt psel pfetched)
         (seq ,(tsf/ginc 'n-getsel)
              (ptr-write-u32 psel 0 ,(funcall g 'sels)) (ptr-write-u32 psel 4 ,(funcall g 'sele))
              (ptr-write-u32 psel 8 2) (ptr-write-u32 psel 12 0)
              (ptr-write-u32 pfetched 0 1) 0))
       (defun ts_setsel (this cnt psel)
         (seq ,(funcall gs 'sels '(ptr-read-u32 psel 0)) ,(funcall gs 'sele '(ptr-read-u32 psel 4)) 0))
       ;; GetText(start,end,pchPlain,cchPlainReq,pcchPlainRet,prgRunInfo,
       ;;         cRunInfoReq,pcRunInfoRet,pacpNext)  -- 9 args after this
       (defun ts_gettext (this a b buf req pret ri rireq piret pnext)
         (let* ((len ,(funcall g 'tlen)) (e (if (< b 0) len (if (> b len) len b)))
                (s (if (> a e) e a)) (n (if (> (- e s) req) req (- e s))) (i 0))
           (seq ,(tsf/ginc 'n-gettext)
                (while (< i n)
                  (seq (ptr-write-u16 buf (* 2 i) (ptr-read-u16 ,(funcall g 'text) (* 2 (+ s i))))
                       (setq i (+ i 1))))
                (if (= pret 0) 0 (ptr-write-u32 pret 0 n))
                (if (= piret 0) 0 (ptr-write-u32 piret 0 0))
                (if (= pnext 0) 0 (ptr-write-u32 pnext 0 (+ s n)))
                0)))
       (defun ts_settext (this flags a b pch cch pchg)
         (seq ,(tsf/ginc 'n-settext)
              (if (/= (buf_replace a b pch cch) 0) ,nelisp-com-e-fail
                (seq ,(funcall gs 'sels '(+ a cch)) ,(funcall gs 'sele '(+ a cch))
                     (if (= pchg 0) 0
                       (seq (ptr-write-u32 pchg 0 a) (ptr-write-u32 pchg 4 b)
                            (ptr-write-u32 pchg 8 (+ a cch))))
                     0))))
       (defun ts_getfmt (this a b c) ,ni) (defun ts_getemb (this a b c d) ,ni)
       (defun ts_qie (this a b c d) ,ni) (defun ts_inse (this a b c d e) ,ni)
       ;; InsertTextAtSelection(flags,pch,cch,pacpStart,pacpEnd,pChange)
       (defun ts_insat (this flags pch cch pa pb pchg)
         (let ((s ,(funcall g 'sels)) (e ,(funcall g 'sele)))
           (seq ,(tsf/ginc 'n-ins)
                (if (/= (logand flags 2) 0)
                    (seq (if (= pa 0) 0 (ptr-write-u32 pa 0 s))
                         (if (= pb 0) 0 (ptr-write-u32 pb 0 e)) 0)
                  (if (/= (buf_replace s e pch cch) 0) ,nelisp-com-e-fail
                    (seq ,(funcall gs 'sels '(+ s cch)) ,(funcall gs 'sele '(+ s cch))
                         (if (= pa 0) 0 (ptr-write-u32 pa 0 s))
                         (if (= pb 0) 0 (ptr-write-u32 pb 0 (+ s cch)))
                         (if (= pchg 0) 0
                           (seq (ptr-write-u32 pchg 0 s) (ptr-write-u32 pchg 4 e)
                                (ptr-write-u32 pchg 8 (+ s cch))))
                         0))))))
       (defun ts_insemb (this a b c d e) ,ni) (defun ts_rsa (this a b c) ,ni)
       (defun ts_raap (this a b c d) ,ni) (defun ts_rata (this a b c d) ,ni)
       (defun ts_fnat (this a b c d e f g) ,ni) (defun ts_rra (this a b c) ,ni)
       (defun ts_getend (this p) (seq (ptr-write-u32 p 0 ,(funcall g 'tlen)) 0))
       (defun ts_getview (this p) (seq (ptr-write-u32 p 0 1) 0))
       (defun ts_getacp (this a b c) ,ni)
       ;; Fixed layout: rect (10,20,30,40), not clipped.
       (defun ts_gettextext (this vc a b prc pclip)
         (seq (ptr-write-u32 prc 0 10) (ptr-write-u32 prc 4 20)
              (ptr-write-u32 prc 8 30) (ptr-write-u32 prc 12 40)
              (ptr-write-u32 pclip 0 0) 0))
       (defun ts_getscr (this a) ,ni)
       ;; ITfContextOwnerCompositionSink (iface 1: this = base+16)
       (defun cs_start (this comp pok)
         (seq ,(funcall gs 'comp 1) (ptr-write-u32 pok 0 1) 0))
       (defun cs_update (this comp r) 0)
       (defun cs_end (this comp) (seq ,(funcall gs 'comp 0) 0))))))

(defun hw/start-forms ()
  `((defun fail (n hr)
      (seq ,(tsf/p "FAIL step=") (ob_hex n) ,(tsf/p " hr=") (ob_hexn hr 8) (ob_nl)
           (ob_flush) (extern-call ExitProcess n)))
    (defun st (n hr) (if (/= (logand hr 2147483648) 0) (fail n hr) 0))
    (defun _start ()
      (seq
       (if (/= (buf_init) 0) (extern-call ExitProcess 2) 0)
       (st 1 (extern-call CoInitializeEx 0 2))
       (st 2 (extern-call CoCreateInstance (data-addr CLSID_TF_ThreadMgr) 0 1
                          (data-addr IID_ITfThreadMgr) ,(tsf/ga 'tmp)))
       (let ((tm ,(tsf/g 'tmp)) (b (data-addr hg)))
         (seq
          ,(tsf/gs 'tm 'tm)
          (st 3 ,(nelisp-com-call 'tm 3 '(+ b 104)))                ; Activate(&tid)
          (st 4 ,(nelisp-com-call 'tm 5 '(+ b 264)))                ; CreateDocumentMgr(&doc)
          (let ((doc (ptr-read-u64 b 264)) (ts (ts_new)))
            (seq
             (if (= ts 0) (fail 5 ,nelisp-com-e-outofmemory) 0)
             (st 6 ,(nelisp-com-call 'doc 3 '(ptr-read-u64 b 104) 0 'ts '(+ b 112) '(+ b 256)))
             (st 7 ,(nelisp-com-call 'doc 4 '(ptr-read-u64 b 112)))  ; Push(ctx)
             ;; SetFocus is informational under wine (not asserted).
             ,(nelisp-com-call 'tm 8 'doc)
             (let ((rc (host_run tm (ptr-read-u64 b 104) (ptr-read-u64 b 112))))
               (seq ,(tsf/p "COUNTERS lock=") (ob_hex ,(tsf/g 'n-lock))
                    ,(tsf/p " getsel=") (ob_hex ,(tsf/g 'n-getsel))
                    ,(tsf/p " settext=") (ob_hex ,(tsf/g 'n-settext))
                    ,(tsf/p " ins=") (ob_hex ,(tsf/g 'n-ins)) (ob_nl)
                    (ob_flush)
                    (extern-call ExitProcess rc)))))))))))

(defun host-wine-forms ()
  (let ((tsf--lits nil))
    (let ((forms (append (tsf/core-forms) (hw/store-forms) (hw/start-forms))))
      (append (tsf/lit-blobs) forms))))

(defun host-wine-build (path)
  (tsf-build-exe path (host-wine-forms)))

(defun host-wine-build-all (dir)
  "Build host-wine.exe and stub-tip.dll (insert mode) into DIR."
  (require 'stub-tip)
  (make-directory dir t)
  (host-wine-build (expand-file-name "host-wine.exe" dir))
  (stub-tip-build-from-env (expand-file-name "stub-tip.dll" dir) 'insert))

(provide 'host-wine)
;;; host-wine.el ends here
