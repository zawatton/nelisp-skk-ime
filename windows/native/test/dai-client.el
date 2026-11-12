;;; dai-client.el --- display attribute provider checker for the S3i shim  -*- lexical-binding: t; -*-

;;; Commentary:

;; Builds dai.exe: loads the shim like tsf_host.cpp (DDSKK_HARNESS_DLL_PATH,
;; DllGetClassObject, IClassFactory::CreateInstance(ITfDisplayAttributeProvider))
;; and exercises GetDisplayAttributeInfo / EnumDisplayAttributeInfo and the
;; returned ITfDisplayAttributeInfo (GetGUID, GetDescription with a real BSTR,
;; Get/SetAttributeInfo, Reset).  The printed trace is compared with
;; golden/dai-e2e.golden (derivation: golden/edit-e2e-part2.derivation.txt).

;;; Code:

(require 'cl-lib)
(require 'tsf-test-common)

(defun dai/imports ()
  (append (mapcar (lambda (e) (cons (car e) (copy-sequence (cdr e)))) tsf-host-imports)
          '(("oleaut32.dll" "SysStringLen" "SysFreeString"))))

(defun dai/words (buf n)
  "Form printing N u32 words at BUF as hex separated by commas."
  `(seq ,@(cl-loop for i below n
                   append (append (and (> i 0) '((ob_ch 44)))
                                  `((ob_hex (ptr-read-u32 ,buf ,(* 4 i))))))))

(defun dai/forms ()
  (let ((tsf--lits nil))
    (let* ((core (tsf/core-forms))
           (forms
            `((data-blob dai_buf ,(make-list 256 0) data)
              (defun dai_info (label guid)
                (seq ,(tsf/p "=== ") (ob_s label) (ob_nl)
                     (ptr-write-u64 (data-addr dai_buf) 0 0)
                     (let ((prov (ptr-read-u64 (data-addr dai_buf) 64)))
                       (let ((hr ,(nelisp-com-call 'prov 4 'guid '(data-addr dai_buf))))
                         (seq ,(tsf/p "  get hr=") (ob_hexn (logand hr 4294967295) 8)
                              ,(tsf/p " info=") (ob_hex (if (= (ptr-read-u64 (data-addr dai_buf) 0) 0) 0 1))
                              (ob_nl)
                              (let ((info (ptr-read-u64 (data-addr dai_buf) 0)))
                                (if (= info 0) 0
                                  (dai_methods info))))))))
              (defun dai_methods (info)
                (seq
                 (ptr-write-u64 (data-addr dai_buf) 16 0) (ptr-write-u64 (data-addr dai_buf) 24 0)
                 ,(nelisp-com-call 'info 3 '(+ (data-addr dai_buf) 16))
                 ,(tsf/p "  guid=") (ob_u8hex (+ (data-addr dai_buf) 16) 16) (ob_nl)
                 (ptr-write-u64 (data-addr dai_buf) 32 0)
                 (let ((hr ,(nelisp-com-call 'info 4 '(+ (data-addr dai_buf) 32))))
                   (let ((b (ptr-read-u64 (data-addr dai_buf) 32)))
                     (seq ,(tsf/p "  desc hr=") (ob_hexn (logand hr 4294967295) 8)
                          ,(tsf/p " len=") (ob_hex (if (= b 0) 0 (extern-call SysStringLen b)))
                          ,(tsf/p " text=") (if (= b 0) 0 (ob_wtext b (extern-call SysStringLen b)))
                          (ob_nl)
                          (if (= b 0) 0 (extern-call SysFreeString b)) 0)))
                 (let ((a (+ (data-addr dai_buf) 160)))
                   (seq
                    (let ((hr ,(nelisp-com-call 'info 5 'a)))
                      (seq ,(tsf/p "  attr hr=") (ob_hexn (logand hr 4294967295) 8) ,(tsf/p " ")
                           ,(dai/words 'a 9) (ob_nl)))
                    (ptr-write-u32 a 16 2)
                    (let ((hr ,(nelisp-com-call 'info 6 'a)))
                      (seq ,(tsf/p "  set hr=") (ob_hexn (logand hr 4294967295) 8)))
                    (ptr-write-u32 a 16 0)
                    ,(nelisp-com-call 'info 5 'a)
                    ,(tsf/p " after-set lsStyle=") (ob_hex (ptr-read-u32 a 16))
                    (let ((hr ,(nelisp-com-call 'info 7)))
                      (seq ,(tsf/p " reset hr=") (ob_hexn (logand hr 4294967295) 8)))
                    ,(nelisp-com-call 'info 5 'a)
                    ,(tsf/p " after-reset lsStyle=") (ob_hex (ptr-read-u32 a 16)) (ob_nl)))
                 ,(nelisp-com-call 'info 2)
                 0))
              (defun dai_main ()
                (if (> (extern-call GetEnvironmentVariableW (data-addr w_envdll) (data-addr pathbuf) 520) 0)
                    (let ((m (extern-call LoadLibraryW (data-addr pathbuf))))
                      (if (= m 0) 80
                        (let ((gco (extern-call GetProcAddress m (data-addr a_dgco))))
                          (if (= gco 0) 91
                            (let ((hr (call-ptr gco (data-addr g_clsid_tip) (data-addr g_iid_factory)
                                                (+ (data-addr dai_buf) 96))))
                              (let ((fac (ptr-read-u64 (data-addr dai_buf) 96)))
                                (if (or (/= hr 0) (= fac 0)) 92
                                  (let ((hr2 ,(nelisp-com-call 'fac 3 0 '(data-addr IID_ITfDisplayAttributeProvider)
                                                               '(+ (data-addr dai_buf) 64))))
                                    (let ((prov (ptr-read-u64 (data-addr dai_buf) 64)))
                                      (if (or (/= hr2 0) (= prov 0)) 93
                                        (seq
                                         (dai_all)
                                         ,(nelisp-com-call 'prov 2)
                                         ,(nelisp-com-call 'fac 2)
                                         0)))))))))))
                  83))
              (defun dai_all ()
                (seq
                 (dai_info ,(tsf/s "preedit") (data-addr g_dai_t_preedit))
                 (dai_info ,(tsf/s "candidate") (data-addr g_dai_t_candidate))
                 (dai_info ,(tsf/s "unknown-guid") (data-addr IID_ITfDisplayAttributeProvider))
                 (let ((prov (ptr-read-u64 (data-addr dai_buf) 64)))
                   (seq
                    ,(tsf/p "=== null-out") (ob_nl)
                    (let ((hr ,(nelisp-com-call 'prov 4 '(data-addr g_dai_t_preedit) 0)))
                      (seq ,(tsf/p "  get hr=") (ob_hexn (logand hr 4294967295) 8) (ob_nl)))
                    ,(tsf/p "=== enum") (ob_nl)
                    (ptr-write-u64 (data-addr dai_buf) 8 1)
                    (let ((hr ,(nelisp-com-call 'prov 3 '(+ (data-addr dai_buf) 8))))
                      (seq ,(tsf/p "  enum hr=") (ob_hexn (logand hr 4294967295) 8)
                           ,(tsf/p " out=") (ob_hex (ptr-read-u64 (data-addr dai_buf) 8)) (ob_nl)))
                    (let ((hr ,(nelisp-com-call 'prov 3 0)))
                      (seq ,(tsf/p "  enum-null hr=") (ob_hexn (logand hr 4294967295) 8) (ob_nl)))
                    0)))
                (ob_flush) 0)
              (defun _start ()
                (if (/= (buf_init) 0) (extern-call ExitProcess 2)
                  (let ((rc (dai_main))) (seq (ob_flush) (extern-call ExitProcess rc))))))))
      (append (tsf/lit-blobs)
              (list (nelisp-com-guid-blob 'g_dai_t_preedit "{d20e1086-bb65-46c3-8815-4456451be3b4}")
                    (nelisp-com-guid-blob 'g_dai_t_candidate "{937f739e-7bf9-4860-9ceb-0ee3f36916a9}"))
              (nelisp-com-msctf-blobs '(IID_ITfDisplayAttributeProvider))
              core forms))))

(defun dai-client-build (path)
  (let ((tsf-host-imports (dai/imports)))
    (tsf-build-exe path (nelisp-com-dedupe-blobs (dai/forms)))))

(provide 'dai-client)
;;; dai-client.el ends here
