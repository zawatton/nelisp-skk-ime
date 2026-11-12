;;; edit-part2-client.el --- S3i part 2 mock-host client: ES path, registration, caret map  -*- lexical-binding: t; -*-

;;; Commentary:

;; Builds edit-part2.exe from the pieces of edit-e2e-client.el (mock TSF host,
;; fake sink / callbacks, driver helpers) with a different script:
;;   * engine replies are real ddskk-tlv wire frames (built here from
;;     engine-tlv.md, not captured from a run) decoded by the core's TLV decoder
;;     and converted by ced_view_from_es (export CoreApplyBytes);
;;   * the registration-target branch of ApplyEngineState
;;     (exports CoreSetRegistration + the usual host-terminate);
;;   * the shared-memory caret map "Local\ddskk-ime-caret-v1" is opened by name
;;     from this process (OpenFileMappingW) and dumped after the steps.
;; Needs a core built with NELISP_CORE_TEST_EXPORTS=1 NELISP_CORE_ENGINE_CLIENT=1.

;;; Code:

(require 'cl-lib)
(require 'edit-e2e-client)

(defun p2/u16le (str)
  "UTF-16LE bytes of STR (BMP only)."
  (cl-loop for c across str append (list (logand c 255) (ash c -8))))

(defun p2/u32le (n) (list (logand n 255) (logand (ash n -8) 255) (logand (ash n -16) 255) (logand (ash n -24) 255)))

(defun p2/rec (tag bytes)
  (append (list (logand tag 255) (ash tag -8)) (p2/u32le (length bytes)) bytes))

(defun p2/frame (mode comp text &optional pend)
  "STATE frame (engine-tlv.md): header magic 'DSTV', size, version 1, kind 1."
  (let* ((recs (append (p2/rec 1 (p2/u16le mode))
                       (p2/rec 2 (p2/u32le 0))
                       (p2/rec 3 (p2/u32le (logand comp #xffffffff)))
                       (p2/rec 4 (p2/u16le text))
                       (and pend (p2/rec 5 (p2/u16le pend)))
                       (p2/rec 6 (p2/u32le 0))))
         (size (+ 12 (length recs))))
    (append (list #x44 #x53 #x54 #x56) (p2/u32le size) (list 1 1 0 0) recs)))

(defconst p2/frames
  `((p2_f1 . ,(p2/frame "hiragana" 0 "▽か" "k"))
    (p2_f2 . ,(p2/frame "candidate" 0 "▼漢字"))
    (p2_f3 . ,(p2/frame "hiragana" -1 "漢字"))
    (p2_f4 . ,(p2/frame "hiragana" 0 "▽ひ"))
    (p2_f5 . ,(p2/frame "hiragana" -1 "登録"))
    (p2_bad . ,(let ((f (p2/frame "hiragana" 0 "▽か"))) (setcar f 0) f))))

(defconst p2/imports-extra
  '(("kernel32.dll" "OpenFileMappingW" "CreateFileMappingW" "MapViewOfFile" "UnmapViewOfFile" "CloseHandle"
     "GetCurrentProcessId")))

(defun p2/imports ()
  (let ((acc (mapcar (lambda (e) (cons (car e) (copy-sequence (cdr e)))) tsf-host-imports)))
    (dolist (e p2/imports-extra acc)
      (let ((c (assoc (car e) acc)))
        (if c (dolist (n (cdr e)) (unless (member n (cdr c)) (nconc c (list n))))
          (setq acc (append acc (list e))))))))

(defun p2/script ()
  `(defun ee_script ()
     (seq
      (step_bytes ,(tsf/s "es-preedit-start") (data-addr p2_f1) ,(length (alist-get 'p2_f1 p2/frames)))
      (cmap_dump ,(tsf/s "after-1"))
      (step_bytes ,(tsf/s "es-candidate") (data-addr p2_f2) ,(length (alist-get 'p2_f2 p2/frames)))
      (step_bytes ,(tsf/s "es-commit-ends-composition") (data-addr p2_f3) ,(length (alist-get 'p2_f3 p2/frames)))
      (cmap_dump ,(tsf/s "after-3"))
      (step_bytes ,(tsf/s "es-bad-magic") (data-addr p2_bad) ,(length (alist-get 'p2_bad p2/frames)))
      (step_bytes ,(tsf/s "reg-start") (data-addr p2_f4) ,(length (alist-get 'p2_f4 p2/frames)))
      (set_reg ,(tsf/s "reg-enter-modal") 1 0)
      (host_terminate ,(tsf/s "reg-host-terminates"))
      (set_reg ,(tsf/s "reg-leave-commit-pending") 0 1)
      (step_bytes ,(tsf/s "reg-target-commit") (data-addr p2_f5) ,(length (alist-get 'p2_f5 p2/frames)))
      (cmap_dump ,(tsf/s "end"))
      ,(tsf/p "=== end ctx_refs=") (ob_hex (ptr-read-u64 ,(tsf/g 'ctxo) 8)) (ob_nl)
      0)))

(defun p2/extra-forms ()
  `((defun step_bytes (name p n)
      (seq ,(tsf/p "=== ") (ob_s name) (ob_nl)
           (let ((hr (call-ptr ,(ee/fn 5) ,(tsf/g 'tm) ,(tsf/g 'ctxo) p n)))
             (seq ,(tsf/p "  request hr=") (ob_hexn (logand hr 4294967295) 8)
                  ,(tsf/p " edit hr=") (ob_hexn (call-ptr ,(ee/fn 2) 1) 8) (ob_nl)))
           (ee_after)))
    (defun set_reg (name mode commit)
      (seq ,(tsf/p "=== ") (ob_s name) (ob_nl)
           (call-ptr ,(ee/fn 6) mode commit)
           (ee_after)))
    ;; Opens the caret map by name and prints sequence, RECT, process-id match.
    (defun cmap_dump (label)
      (seq ,(tsf/p "CMAP ") (ob_s label)
           
           (let ((h (extern-call OpenFileMappingW 4 0 (data-addr w_p2_cmap))))
             (if (= h 0) (seq ,(tsf/p " open=0") (ob_nl) 0)
               (let ((v (extern-call MapViewOfFile h 4 0 0 24)))
                 (if (= v 0) (seq ,(tsf/p " map=0") (ob_nl) 0)
                   (let ((pid (extern-call GetCurrentProcessId)))
                     (seq ,(tsf/p " seq=") (ob_hex (ptr-read-u32 v 0))
                          ,(tsf/p " rect=") (ob_hex (ptr-read-u32 v 4)) (ob_ch 44)
                          (ob_hex (ptr-read-u32 v 8)) (ob_ch 44) (ob_hex (ptr-read-u32 v 12)) (ob_ch 44)
                          (ob_hex (ptr-read-u32 v 16))
                          ,(tsf/p " pid_ok=") (ob_hex (if (= (ptr-read-u32 v 20) pid) 1 0))
                          (ob_nl)
                          (extern-call UnmapViewOfFile v)
                          (extern-call CloseHandle h)
                          0))))))))))

(defun p2/blobs ()
  (append
   (list (nelisp-com-wstr-blob 'w_p2_cmap "Local\\ddskk-ime-caret-v1")
         (nelisp-com-ascii-blob 'a_p2_bytes "CoreApplyBytes")
         (nelisp-com-ascii-blob 'a_p2_reg "CoreSetRegistration"))
   (mapcar (lambda (f) `(data-blob ,(car f) ,(cdr f) data)) p2/frames)))

(defun edit-part2-forms ()
  (let ((tsf--lits nil) (ee--wlits nil))
    (let* ((fsk (nelisp-com-class-forms
                 'fsk :interfaces `((:iid ,(nelisp-com-msctf-guid 'IID_ITfCompositionSink)
                                     :methods (fsk_term)))))
           (drv (cl-subst
                 `(seq (gp m (data-addr a_ee_sizes) 4)
                       (gp m (data-addr a_p2_bytes) 5) (gp m (data-addr a_p2_reg) 6))
                 '(gp m (data-addr a_ee_sizes) 4)
                 (cl-remove-if (lambda (f) (and (eq (car f) 'defun) (eq (nth 1 f) 'ee_script)))
                               (ee/driver-forms))
                 :test #'equal))
           (forms (append (tsf/core-forms) (hm/object-forms) fsk drv (p2/extra-forms) (list (p2/script)))))
      (append (tsf/lit-blobs)
              (mapcar (lambda (e) (nelisp-com-wstr-blob (cdr e) (car e))) (reverse ee--wlits))
              (ee/blobs) (p2/blobs)
              (cl-remove-if (lambda (b) (cl-find-if (lambda (f) (and (eq (car f) 'data-blob) (eq (nth 1 f) (nth 1 b)))) forms))
                            (nelisp-com-msctf-blobs nil))
              forms))))

(defun edit-part2-client-build (path)
  "Build the part-2 mock-host client PATH."
  (let ((tsf-host-imports (p2/imports)))
    (tsf-build-exe path (nelisp-com-dedupe-blobs (edit-part2-forms)))))

(provide 'edit-part2-client)
;;; edit-part2-client.el ends here
