;;; stub-tip.el --- minimal TIP stub DLL for the TSF test hosts  -*- lexical-binding: t; -*-

;;; Commentary:

;; Builds stub-tip.dll, a tiny text service (CLSID_DdskkTextService) with
;; ITfTextInputProcessor + ITfKeyEventSink on one object.  Activate records
;; the thread manager and client id and advises its key sink through
;; ITfKeystrokeMgr::AdviseKeyEventSink.  OnTestKeyDown eats every key;
;; OnKeyDown requests a synchronous read/write edit session (flags 7) whose
;; DoEditSession does, by MODE:
;;
;;   insert   QI ITfInsertAtSelection, InsertTextAtSelection(char)   (wine host)
;;   compose  GetSelection, QI ITfContextComposition, StartComposition,
;;            ITfRange::SetText(char), ITfComposition::EndComposition (mock host)
;;
;; The character is the pressed key's VK, lower-cased for A-Z.
;;
;; Negative-control hook (build time): NELISP_TSF_STUB_NOINSERT=1 makes
;; OnKeyDown eat the key without requesting an edit session.

;;; Code:

(require 'cl-lib)
(require 'tsf-test-common)

(defun stub-tip-forms (mode &optional noinsert)
  "Return the AOT forms of the stub TIP in MODE (`insert' or `compose')."
  (let* ((g (lambda (n) (nelisp-com-msctf-guid n)))
         (vt (lambda (o n) `(ptr-read-u64 (ptr-read-u64 ,o 0) ,n)))
         (guid-eq-ok nil))
    (ignore guid-eq-ok)
    (append
     (nelisp-com-class-forms
      'tip :state-size 64
      :interfaces `((:iid ,(funcall g 'IID_ITfTextInputProcessor)
                     :methods (tip_activate tip_deactivate))
                    (:iid ,(funcall g 'IID_ITfKeyEventSink)
                     :methods (tip_setfocus tip_testkd tip_testku tip_keydown
                                            tip_keyup tip_preserved))))
     ;; edit session; state: +24 ctx +32 char(u16)+pad +40 qi-out +48 range
     ;; +56 TF_SELECTION(16) +72 fetched +80 comp +88 cc
     (nelisp-com-class-forms
      'ses :state-size 96
      :interfaces `((:iid ,(funcall g 'IID_ITfEditSession) :methods (ses_do))
                    (:iid ,(funcall g 'IID_ITfCompositionSink) :methods (ses_term))))
     (nelisp-com-factory-forms 'tip)
     (nelisp-com-msctf-blobs '(IID_ITfKeystrokeMgr IID_ITfInsertAtSelection
                               IID_ITfContextComposition))
     (nelisp-com-server-forms
      `((:name tip :clsid ,tsf-clsid-ddskk :threading "Apartment")) :hive 'hkcu)
     `((defun tip_activate (this ptim tid)
         ;; Wine's real msctf rejects AdviseKeyEventSink (E_INVALIDARG) for a
         ;; client id that has no registered CLSID, which is the direct-load
         ;; situation of host-wine.  The stub therefore ignores the advise
         ;; result; a real TIP must decide how to treat it (see the S3d notes).
         (seq (ptr-write-u64 this 24 ptim) (ptr-write-u64 this 32 tid)
              (if (/= ,(nelisp-com-call 'ptim 0 '(data-addr IID_ITfKeystrokeMgr)
                                        '(+ this 40)) 0)
                  0
                (let ((km (ptr-read-u64 this 40)))
                  (seq ,(nelisp-com-call 'km 3 'tid '(+ this 16) 1)
                       ,(nelisp-com-call 'km 2))))
              0))
       (defun tip_deactivate (this) 0)
       (defun tip_setfocus (this fg) 0)
       (defun tip_testkd (this pic wp lp pf) (seq (ptr-write-u32 pf 0 1) 0))
       (defun tip_testku (this pic wp lp pf) (seq (ptr-write-u32 pf 0 0) 0))
       (defun tip_keyup (this pic wp lp pf) (seq (ptr-write-u32 pf 0 0) 0))
       (defun tip_preserved (this pic g pf) (seq (ptr-write-u32 pf 0 0) 0))
       (defun tip_keydown (this pic wp lp pf)
         (let ((b (- this 16)))
           (seq (ptr-write-u32 pf 0 1)
                ,(if noinsert 0
                   `(let ((s (ses_new)))
                      (if (= s 0) ,nelisp-com-e-outofmemory
                        (seq (ptr-write-u64 s 24 pic)
                             (ptr-write-u16 s 32 (if (and (>= wp 65) (<= wp 90)) (+ wp 32) wp))
                             ,(nelisp-com-call 'pic 3 '(ptr-read-u64 b 32) 's 7 '(+ b 48))
                             (ses_release s)
                             0))))
                0)))
       (defun ses_term (this ec comp) 0)
       ,(if (eq mode 'insert)
            `(defun ses_do (this ec)
               (let ((ctx (ptr-read-u64 this 24)))
                 ,(nelisp-com-try
                   `((hr ,(nelisp-com-call 'ctx 0 '(data-addr IID_ITfInsertAtSelection)
                                           '(+ this 40))))
                   `(let ((ia (ptr-read-u64 this 40)))
                      (let ((hr2 ,(nelisp-com-call 'ia 3 'ec 0 '(+ this 32) 1 '(+ this 48))))
                        (seq (if (= (ptr-read-u64 this 48) 0) 0
                               ,(nelisp-com-call '(ptr-read-u64 this 48) 2))
                             ,(nelisp-com-call 'ia 2)
                             hr2))))))
          `(defun ses_do (this ec)
             (let ((ctx (ptr-read-u64 this 24)))
               ,(nelisp-com-try
                 `((hr1 ,(nelisp-com-call 'ctx 5 'ec 4294967295 1 '(+ this 56) '(+ this 72)))
                   (hr2 ,(nelisp-com-call 'ctx 0 '(data-addr IID_ITfContextComposition)
                                          '(+ this 88)))
                   (hr3 ,(nelisp-com-call '(ptr-read-u64 this 88) 3 'ec '(ptr-read-u64 this 56)
                                          '(+ this 16) '(+ this 80)))
                   (hr4 ,(nelisp-com-call '(ptr-read-u64 this 56) 4 'ec 0 '(+ this 32) 1))
                   (hr5 ,(nelisp-com-call '(ptr-read-u64 this 80) 6 'ec)))
                 0))))))))

(defun stub-tip-build (path mode &optional noinsert)
  "Build the stub TIP DLL PATH for MODE; NOINSERT builds the negative control."
  (nelisp-com-build-dll path (stub-tip-forms mode noinsert)))

(defun stub-tip-build-from-env (path mode)
  "Build with the negative-control hook taken from NELISP_TSF_STUB_NOINSERT."
  (stub-tip-build path mode (equal (getenv "NELISP_TSF_STUB_NOINSERT") "1")))

(provide 'stub-tip)
;;; stub-tip.el ends here
