;;; shim-reg-client.el --- TSF registration checker EXE for the S3c shim  -*- lexical-binding: t; -*-

;;; Commentary:

;; Builds shim-reg-client.exe, a nelisp-built COM client that inspects the TSF
;; registration of CLSID_DdskkTextService through the platform's msctf:
;;
;;   present mode  CoCreateInstance(CLSID_TF_InputProcessorProfiles),
;;                 EnumLanguageProfiles(0x0411) must list our CLSID with
;;                 langid 0x0411 and GUID_DdskkProfile,
;;                 GetLanguageProfileDescription must be L"NeLisp IME",
;;                 ITfCategoryMgr::EnumCategoriesInItem(our CLSID) must list the
;;                 six categories, and CoCreateInstance(our CLSID,
;;                 ITfTextInputProcessor) must work (Activate/Deactivate S_OK,
;;                 the Ex alias must resolve).
;;   absent mode   CoCreateInstance(our CLSID) must fail with
;;                 REGDB_E_CLASSNOTREG and no profile / category may remain.
;;
;; Every step prints "Tnn XXXXXXXX" (tag, hex value) and the exit code names
;; the first failing check (0 = all good):
;;   10 profiles CoCreate   11 EnumLanguageProfiles   20 profile not listed
;;   21 wrong langid        22 wrong profile GUID     23 description call
;;   24 description text    30 category mgr CoCreate  31 EnumCategoriesInItem
;;   32..37 category 1..6 missing   40 TIP CoCreate   41 Activate/Deactivate
;;   42 Ex alias QI         60 class still creatable  61 profile still listed
;;   62 category still listed

;;; Code:

(require 'cl-lib)
(require 'ddskk-shim)

(defconst shim-reg-client-imports
  '(("kernel32.dll" "ExitProcess" "GetStdHandle" "WriteFile")
    ("ole32.dll" "CoInitializeEx" "CoCreateInstance")))

(defun shim-reg-client--chain (steps)
  "Nest STEPS (forms returning 0 on success or a failure code)."
  (let ((i 0))
    (cl-labels ((go (ss)
                  (if (null (cdr ss)) (car ss)
                    (let ((v (intern (format "r%d" (setq i (1+ i))))))
                      `(let ((,v ,(car ss)))
                         (if (/= ,v 0) ,v ,(go (cdr ss))))))))
      (go steps))))

(defun shim-reg-client--enum-guid-loop (var-en fetched-var buf-var on-item)
  "Loop IEnumGUID::Next (slot 3) over VAR-EN calling ON-ITEM (a form)."
  `(let ((more 1))
     (while (= more 1)
       (seq (ptr-write-u64 (data-addr cl_fetch) 0 0)
            ,(nelisp-com-call var-en 3 1 buf-var fetched-var)
            (if (= (ptr-read-u64 ,fetched-var 0) 1)
                ,on-item
              (setq more 0))))))

(defun shim-reg-client-forms (mode)
  "Return the client forms for MODE (`present' or `absent')."
  (let* ((cats ddskk-shim-categories)
         (cat-check
          (lambda (i c)
            `(if (and (= (ptr-read-u64 (data-addr cl_tf) 0)
                         (ptr-read-u64 (data-addr ,c) 0))
                      (= (ptr-read-u64 (data-addr cl_tf) 8)
                         (ptr-read-u64 (data-addr ,c) 8)))
                 (ptr-write-u64 (data-addr cl_mask) 0
                                (logior (ptr-read-u64 (data-addr cl_mask) 0)
                                        ,(ash 1 i)))
               0)))
         (mask-all (1- (ash 1 (length cats)))))
    (append
     (nelisp-com-msctf-blobs
      (append '(CLSID_TF_InputProcessorProfiles IID_ITfInputProcessorProfiles
                CLSID_TF_CategoryMgr IID_ITfCategoryMgr
                IID_ITfTextInputProcessor IID_ITfTextInputProcessorEx)
              cats))
     (list (nelisp-com-guid-blob 'g_clsid ddskk-shim-clsid)
           (nelisp-com-guid-blob 'g_profile ddskk-shim-profile-guid)
           (nelisp-com-wstr-blob 'w_desc ddskk-shim-description)
           (nelisp-com-zero-blob 'cl_out 16)
           (nelisp-com-zero-blob 'cl_written 8)
           (nelisp-com-zero-blob 'cl_obj 8)
           (nelisp-com-zero-blob 'cl_en 8)
           (nelisp-com-zero-blob 'cl_fetch 8)
           (nelisp-com-zero-blob 'cl_mask 8)
           (nelisp-com-zero-blob 'cl_bstr 8)
           (nelisp-com-zero-blob 'cl_tf 64))
     `((defun pr (tag v)
         (let ((b (data-addr cl_out)) (i 7) (x v))
           (seq (ptr-write-u8 b 0 84)
                (ptr-write-u8 b 1 (+ 48 (/ tag 10)))
                (ptr-write-u8 b 2 (+ 48 (mod tag 10)))
                (ptr-write-u8 b 3 32)
                (while (>= i 0)
                  (seq (ptr-write-u8 b (+ 4 i)
                                     (if (< (mod x 16) 10) (+ 48 (mod x 16))
                                       (+ 87 (mod x 16))))
                       (setq x (/ x 16))
                       (setq i (- i 1))))
                (ptr-write-u8 b 12 10)
                (extern-call WriteFile (extern-call GetStdHandle 4294967285)
                             b 13 (data-addr cl_written) 0)
                0)))
       (defun weq (a b)
         (let ((i 0) (r 2))
           (seq (while (= r 2)
                  (let ((x (ptr-read-u16 (+ a (* 2 i)) 0))
                        (y (ptr-read-u16 (+ b (* 2 i)) 0)))
                    (if (/= x y) (setq r 0)
                      (if (= x 0) (setq r 1) (setq i (+ i 1))))))
                r)))
       (defun mk_profiles ()
         (let ((hr (extern-call CoCreateInstance
                                (data-addr CLSID_TF_InputProcessorProfiles) 0 1
                                (data-addr IID_ITfInputProcessorProfiles)
                                (data-addr cl_obj))))
           (seq (pr 1 hr)
                (if ,(nelisp-com-failed 'hr) 0 (ptr-read-u64 (data-addr cl_obj) 0)))))
       ;; Returns found-flags: bit0 listed, bit1 langid ok, bit2 profile guid ok,
       ;; 65536 when EnumLanguageProfiles itself failed.
       (defun scan_profiles (p)
         (let ((hr ,(nelisp-com-call 'p 16 ddskk-shim-langid '(data-addr cl_en)))
               (flags 0))
           (seq (pr 2 hr)
                (if ,(nelisp-com-failed 'hr) 65536
                  (let ((en (ptr-read-u64 (data-addr cl_en) 0)) (more 1))
                    (seq
                     (while (= more 1)
                       (seq (ptr-write-u64 (data-addr cl_fetch) 0 0)
                            ,(nelisp-com-call 'en 4 1 '(data-addr cl_tf)
                                              '(data-addr cl_fetch))
                            (if (= (ptr-read-u64 (data-addr cl_fetch) 0) 1)
                                (seq (pr 3 (ptr-read-u32 (data-addr cl_tf) 0))
                                     (pr 4 (ptr-read-u16 (data-addr cl_tf) 16))
                                     (if (and (= (ptr-read-u64 (data-addr cl_tf) 0)
                                                 (ptr-read-u64 (data-addr g_clsid) 0))
                                              (= (ptr-read-u64 (data-addr cl_tf) 8)
                                                 (ptr-read-u64 (data-addr g_clsid) 8)))
                                         (seq (setq flags (logior flags 1))
                                              (if (= (ptr-read-u16 (data-addr cl_tf) 16)
                                                     ,ddskk-shim-langid)
                                                  (setq flags (logior flags 2)) 0)
                                              (if (and (= (ptr-read-u64 (data-addr cl_tf) 40)
                                                          (ptr-read-u64 (data-addr g_profile) 0))
                                                       (= (ptr-read-u64 (data-addr cl_tf) 48)
                                                          (ptr-read-u64 (data-addr g_profile) 8)))
                                                  (setq flags (logior flags 4)) 0))
                                       0))
                              (setq more 0))))
                     ,(nelisp-com-call 'en 2)
                     flags))))))
       (defun scan_categories (cm)
         (let ((hr ,(nelisp-com-call 'cm 5 '(data-addr g_clsid) '(data-addr cl_en))))
           (seq (pr 6 hr)
                (ptr-write-u64 (data-addr cl_mask) 0 0)
                (if ,(nelisp-com-failed 'hr) (if (= hr 2147500033) 65537 65536)   ; 65537: wine E_NOTIMPL
                  (let ((en (ptr-read-u64 (data-addr cl_en) 0)))
                    (seq ,(shim-reg-client--enum-guid-loop
                           'en '(data-addr cl_fetch) '(data-addr cl_tf)
                           `(seq (pr 7 (ptr-read-u32 (data-addr cl_tf) 0))
                                 ,@(cl-loop for c in cats for i from 0
                                            collect (funcall cat-check i c))))
                         ,(nelisp-com-call 'en 2)
                         (ptr-read-u64 (data-addr cl_mask) 0)))))))
       (defun mk_catmgr ()
         (let ((hr (extern-call CoCreateInstance (data-addr CLSID_TF_CategoryMgr) 0 1
                                (data-addr IID_ITfCategoryMgr) (data-addr cl_obj))))
           (seq (pr 5 hr)
                (if ,(nelisp-com-failed 'hr) 0 (ptr-read-u64 (data-addr cl_obj) 0)))))
       (defun present_profiles ()
         (let ((p (mk_profiles)))
           (if (= p 0) 10
             (let ((f (scan_profiles p)))
               (if (= f 65536) (seq ,(nelisp-com-call 'p 2) 11)
                 (if (= (logand f 1) 0) (seq ,(nelisp-com-call 'p 2) 20)
                   (if (= (logand f 2) 0) (seq ,(nelisp-com-call 'p 2) 21)
                     (if (= (logand f 4) 0) (seq ,(nelisp-com-call 'p 2) 22)
                       (let ((hd ,(nelisp-com-call 'p 12 '(data-addr g_clsid)
                                                   ddskk-shim-langid '(data-addr g_profile)
                                                   '(data-addr cl_bstr))))
                         (seq (pr 8 hd)
                              (let ((rc (if (= hd 2147500033) 0     ; wine: Description E_NOTIMPL (registry checked by the script)
                                          (if ,(nelisp-com-failed 'hd) 23
                                            (if (= (weq (ptr-read-u64 (data-addr cl_bstr) 0)
                                                        (data-addr w_desc))
                                                   1)
                                                0 24)))))
                                (seq ,(nelisp-com-call 'p 2) rc))))))))))))
       (defun present_categories ()
         (let ((cm (mk_catmgr)))
           (if (= cm 0) 30
             (let ((m (scan_categories cm)))
               (seq ,(nelisp-com-call 'cm 2)
                    (if (= m 65536) 31
                      (if (= m 65537) 0   ; wine: registry checked by the script
                      ,(cl-labels ((go (i)
                                     (if (= i (length cats)) 0
                                       `(if (= (logand m ,(ash 1 i)) 0) ,(+ 32 i)
                                          ,(go (1+ i))))))
                         (go 0)))))))))
       (defun present_tip ()
         (let ((hr (extern-call CoCreateInstance (data-addr g_clsid) 0 1
                                (data-addr IID_ITfTextInputProcessor)
                                (data-addr cl_obj))))
           (seq (pr 9 hr)
                (if ,(nelisp-com-failed 'hr) 40
                  (let ((t0 (ptr-read-u64 (data-addr cl_obj) 0)))
                    (let ((a ,(nelisp-com-call 't0 3 0 0)))
                      (seq (pr 10 a)
                           (let ((d ,(nelisp-com-call 't0 4)))
                             (seq (pr 11 d)
                                  (let ((q ,(nelisp-com-call
                                             't0 0 '(data-addr IID_ITfTextInputProcessorEx)
                                             '(data-addr cl_en))))
                                    (seq (pr 12 q)
                                         (if ,(nelisp-com-succeeded 'q)
                                             ,(nelisp-com-call '(ptr-read-u64 (data-addr cl_en) 0) 2)
                                           0)
                                         ,(nelisp-com-call 't0 2)
                                         (if (or ,(nelisp-com-failed 'a) ,(nelisp-com-failed 'd))
                                             41
                                           (if ,(nelisp-com-failed 'q) 42 0)))))))))))))
       (defun absent_class ()
         (let ((hr (extern-call CoCreateInstance (data-addr g_clsid) 0 1
                                (data-addr IID_ITfTextInputProcessor)
                                (data-addr cl_obj))))
           (seq (pr 9 hr)
                (if (= hr 2147746132) 0   ; REGDB_E_CLASSNOTREG
                  60))))
       (defun absent_profiles ()
         (let ((p (mk_profiles)))
           (if (= p 0) 0
             (let ((f (scan_profiles p)))
               (seq ,(nelisp-com-call 'p 2)
                    (if (= f 65536) 0 (if (= (logand f 1) 0) 0 61)))))))
       (defun absent_categories ()
         (let ((cm (mk_catmgr)))
           (if (= cm 0) 0
             (let ((m (scan_categories cm)))
               (seq ,(nelisp-com-call 'cm 2)
                    (if (>= m 65536) 0 (if (= m 0) 0 62)))))))
       (defun client_main ()
         (seq (extern-call CoInitializeEx 0 2)
              ,(shim-reg-client--chain
                (if (eq mode 'present)
                    '((present_profiles) (present_categories) (present_tip) 0)
                  '((absent_class) (absent_profiles) (absent_categories) 0)))))
       (defun _start () (extern-call ExitProcess (client_main)))))))

(defun shim-reg-client-build (path mode)
  "Build the checker EXE at PATH for MODE (`present' or `absent')."
  (setq max-lisp-eval-depth (max max-lisp-eval-depth 100000))
  (nelisp-com-build-exe path (shim-reg-client-forms mode) shim-reg-client-imports))

(provide 'shim-reg-client)
;;; shim-reg-client.el ends here
